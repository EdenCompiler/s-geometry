(require :asdf)
(load (merge-pathnames "bootstrap.lisp"
                       (uiop:pathname-directory-pathname
                        (or *load-truename* *compile-file-truename*))))
(asdf:load-system :sgeo/backend/opengl)
(asdf:load-system :sgeo/geometry-processing)

(defun m8-check (condition message)
  (unless condition (error "M8 GPU check failed: ~A" message)))

(defun m8-check-vector (actual expected label &optional (epsilon 2d-4))
  (m8-check (= (length actual) (length expected)) (format nil "~A size mismatch" label))
  (loop for a across actual for e across expected
        do (m8-check (<= (abs (- a e)) epsilon)
                     (format nil "~A mismatch: ~S vs ~S" label actual expected))))

(defun m8-gl-state ()
  (list (sgeo.backend.opengl::%query-integer-state #x8b8d)
        (sgeo.backend.opengl::%query-integer-state #x90d3)
        (loop for index below 3
              collect (sgeo.backend.opengl::%query-indexed-integer-state #x90d3 index))))

(defun m8-restore-gl-state (state)
  (destructuring-bind (program buffer-binding indexed-bindings) state
    (gl:use-program program)
    (loop for index below 3 for buffer in indexed-bindings
          do (%gl:bind-buffer-base #x90d2 index buffer))
    (gl:bind-buffer :shader-storage-buffer buffer-binding)))

(defun m8-seed-buffer (value)
  (let ((buffer (gl:gen-buffer)) (array nil))
    (setf array (sgeo.backend.opengl::%fill-gl-array :float (vector (coerce value 'single-float))))
    (unwind-protect
         (progn
           (gl:bind-buffer :shader-storage-buffer buffer)
           (gl:buffer-data :shader-storage-buffer :dynamic-copy array))
      (gl:free-gl-array array))
    buffer))

(defun m8-resource-checked-call (function)
  (let ((before (m8-gl-state)) (ledger nil) (outcome nil))
    (setf outcome
          (handler-case
              (list :ok
                    (let ((sgeo.backend.opengl::*opengl-compute-resource-observer*
                            (lambda (action kind identifier)
                              (push (list action kind identifier) ledger))))
                      (sgeo.backend.opengl:with-native-graphics-environment ()
                        (funcall function))))
            (error (condition) (list :error condition))))
    (m8-check (equal before (m8-gl-state)) "compute changed the caller's OpenGL program or SSBO bindings")
    (dolist (event ledger)
      (destructuring-bind (action kind identifier) event
        (when (eq action :created)
          (m8-check (member (list :deleted kind identifier) ledger :test #'equal)
                    (format nil "temporary ~A ~D was not deleted" kind identifier))
          (m8-check (not (case kind
                           (:buffer (%gl:is-buffer identifier))
                           (:program (%gl:is-program identifier))
                           (:shader (%gl:is-shader identifier))))
                    (format nil "temporary ~A ~D remains alive" kind identifier)))))
    (values outcome (nreverse ledger))))

(defun m8-source-positions (mesh)
  (etypecase mesh
    (sgeo.geometry:triangle-mesh (sgeo.geometry:mesh-positions mesh))
    (sgeo.geometry:half-edge-mesh
     (nth-value 0 (sgeo.geometry:mesh-polygon-data mesh)))))

(defun m8-flat-positions (mesh positions)
  (etypecase mesh
    (sgeo.geometry:triangle-mesh positions)
    (sgeo.geometry:half-edge-mesh
     (make-array (* 3 (length positions)) :element-type 'double-float
                 :initial-contents (loop for point across positions append (coerce point 'list))))))

(defun m8-cpu-normal-reference (mesh)
  (multiple-value-bind (positions indices) (sgeo.backend.opengl::%triangle-input mesh)
    (sgeo.geometry:mesh-normals
     (sgeo.geometry:make-triangle-mesh-from-data positions indices))))

(defun m8-check-transformed-positions (mesh source actual scale amplitude)
  (let ((translation-y 0.25d0) (frequency 1d0))
    (etypecase mesh
      (sgeo.geometry:triangle-mesh
       (loop for offset from 0 below (length source) by 3
             for x = (* (aref scale 0) (aref source offset))
             for expected-y = (+ (* (aref scale 1) (aref source (1+ offset)))
                                 translation-y (* amplitude (sin (* x frequency))))
             do (m8-check-vector
                 (subseq actual offset (+ offset 3))
                 (vector x expected-y (* (aref scale 2) (aref source (+ offset 2))))
                 "GPU transformed vertex")))
      (sgeo.geometry:half-edge-mesh
       (loop for point across source for actual-point across actual
             for x = (* (aref scale 0) (aref point 0))
             for expected-y = (+ (* (aref scale 1) (aref point 1))
                                 translation-y (* amplitude (sin (* x frequency))))
             do (m8-check-vector actual-point
                                 (vector x expected-y (* (aref scale 2) (aref point 2)))
                                 "GPU transformed vertex"))))))

(defun m8-edit-one-vertex (mesh)
  (etypecase mesh
    (sgeo.geometry:triangle-mesh
     (let ((point (subseq (sgeo.geometry:mesh-positions mesh) 0 3)))
       (incf (aref point 0) 0.01d0)
       (sgeo.geometry:set-mesh-position mesh 0 point)))
    (sgeo.geometry:half-edge-mesh
     (let* ((vertex (first (sgeo.geometry:mesh-vertices mesh)))
            (point (sgeo.geometry:vertex-position mesh vertex)))
       (incf (aref point 0) 0.01d0)
       (sgeo.geometry:set-vertex-position mesh vertex point)))))

(defun m8-check-failed-output-rolls-back (mesh)
  (let ((revision (sgeo.core:object-revision mesh))
        (positions (m8-source-positions mesh)))
    (multiple-value-bind (outcome ledger)
        (m8-resource-checked-call
         (lambda ()
           ;; Esta transformação colapsa todos os triângulos e deve falhar na validação CPU.
           (sgeo.backend.opengl:opengl-process-geometry mesh :scale #(0d0 0d0 0d0))))
      (m8-check (eq :error (first outcome)) "collapsed GPU output was accepted")
      (m8-check (some (lambda (event) (eq (first event) :created)) ledger)
                "failed GPU output did not exercise resource cleanup")
      (m8-check (= revision (sgeo.core:object-revision mesh)) "failed output advanced the CPU mesh revision")
      (m8-check (equalp positions (m8-source-positions mesh)) "failed output changed authoritative CPU positions"))))

(defun m8-check-mesh-path (mesh &key (scale #(1d0 1.5d0 1d0)) (amplitude 0.2d0))
  (let ((handles (when (typep mesh 'sgeo.geometry:half-edge-mesh)
                   (sgeo.geometry:mesh-vertices mesh)))
        (before (m8-source-positions mesh))
        (revision (sgeo.core:object-revision mesh)))
    (multiple-value-bind (outcome ledger)
        (m8-resource-checked-call
         (lambda ()
           (sgeo.backend.opengl:opengl-process-geometry
            mesh :scale scale :translation #(0d0 0.25d0 0d0)
            :amplitude amplitude :frequency 1d0 :phase 0d0)))
      (m8-check (eq :ok (first outcome)) (format nil "GPU processing raised ~A" (second outcome)))
      (m8-check (plusp (count-if (lambda (entry) (eq (first entry) :created)) ledger))
                "compute did not allocate temporary device resources")
      (m8-check (> (sgeo.core:object-revision mesh) revision) "mesh revision was not committed")
      (when handles
        (m8-check (every (lambda (handle) (member handle (sgeo.geometry:mesh-vertices mesh) :test #'equalp))
                         handles)
                  "half-edge vertex handles changed after the batch commit"))
      (let* ((result (second outcome))
             (actual (m8-source-positions mesh))
             (gpu-positions (sgeo.geometry-processing:processing-result-positions result))
             (gpu-normals (sgeo.geometry-processing:processing-result-normals result))
             (cpu-normals (m8-cpu-normal-reference mesh)))
        (m8-check (= (sgeo.geometry-processing:processing-result-source-revision result)
                     (sgeo.core:object-revision mesh))
                  "result cache revision does not match the published mesh")
        (m8-check (not (equalp before actual)) "GPU transform/deformation did not change the CPU mesh")
        (m8-check-transformed-positions mesh before actual scale amplitude)
        (m8-check-vector gpu-positions (m8-flat-positions mesh actual)
                         "readback positions" 0d0)
        (m8-check-vector gpu-normals cpu-normals "GPU normals vs CPU reference" 1d-3)
        (m8-check-vector gpu-normals
                         (sgeo.backend.opengl:opengl-geometry-result-normals mesh)
                         "cached GPU normals" 0d0)
        (m8-edit-one-vertex mesh)
        (m8-check (null (sgeo.backend.opengl:opengl-geometry-result-normals mesh))
                  "normal cache remained valid after a CPU edit")
        (m8-check-failed-output-rolls-back mesh)
        (format t "M8 GPU commit and readback OK: ~D positions, ~D normals; CPU edit invalidated cache.~%"
                (etypecase mesh
                  (sgeo.geometry:triangle-mesh (/ (length actual) 3))
                  (sgeo.geometry:half-edge-mesh (length actual)))
                (/ (length gpu-normals) 3))))))

(defun m8-run-gpu-check ()
  (glfw:initialize)
  (let ((window nil) (seeded-buffers nil) (seeded-program nil) (initial-state nil))
    (unwind-protect
         (progn
           (setf window (glfw:create-window :width 64 :height 64 :title "S-Geometry M8 compute check"
                                            :visible nil :context-version-major 4
                                            :context-version-minor 3 :opengl-profile :opengl-core-profile))
           (unless window (error "GLFW could not create an OpenGL 4.3 context."))
           (glfw:make-context-current window)
           (sgeo.backend.opengl:initialize-opengl-backend)
           (format t "M8 compute device: ~A; ~A; ~A~%"
                   (gl:get-string :version) (gl:get-string :vendor) (gl:get-string :renderer))
           (let ((capabilities (sgeo.backend.opengl:opengl-compute-capabilities)))
             (m8-check (sgeo.geometry-processing:capabilities-supported-p capabilities)
                       (sgeo.geometry-processing:capabilities-reason capabilities)))
           (setf initial-state (m8-gl-state)
                 seeded-program
                   (sgeo.backend.opengl::%create-program
                    sgeo.backend.opengl::+mesh-vertex-shader+
                    sgeo.backend.opengl::+mesh-fragment-shader+)
                 seeded-buffers (loop for value in '(1 2 3 4) collect (m8-seed-buffer value)))
           (loop for index below 3 for buffer in seeded-buffers
                 do (%gl:bind-buffer-base #x90d2 index buffer))
           (gl:bind-buffer :shader-storage-buffer (fourth seeded-buffers))
           (gl:use-program seeded-program)
           (m8-check-mesh-path (sgeo.geometry:make-box))
           (m8-check-mesh-path (sgeo.geometry:make-half-edge-box))
           (m8-check-mesh-path (sgeo.geometry:make-grid :columns 12 :rows 10))
           (sgeo.backend.opengl:clear-opengl-geometry-cache)
           (m8-restore-gl-state initial-state)
           t)
      (when window
        (when initial-state (ignore-errors (m8-restore-gl-state initial-state)))
        (when seeded-program (ignore-errors (gl:delete-program seeded-program)))
        (when seeded-buffers (ignore-errors (gl:delete-buffers seeded-buffers)))
        (ignore-errors (glfw:destroy-window window)))
      (glfw:terminate))))

(m8-run-gpu-check)
