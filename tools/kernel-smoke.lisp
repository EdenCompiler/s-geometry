;;;; Demonstra edições topológicas sobre a mesma malha no viewport real.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples)

(defun same-kernel-handle-p (a b)
  "Compara a identidade lógica de identificadores retornados em leituras distintas."
  (equalp a b))

(defun run-kernel-demonstration ()
  "Exercita M2 com renderização ativa, recuperação de erro e redefinição ao vivo."
  (let* ((world (sgeo.examples:make-kernel-world))
         (object (sg:find-object world "EditableBox"))
         (mesh (sg:mesh-object-geometry object))
         (mesh-id (sg:object-id mesh))
         (split-vertex nil) (kept-vertex nil) (kept-position nil)
         (original-edge nil) (top-face nil) (redefined-face nil))
    (unwind-protect
         (multiple-value-bind (returned renderer report)
             (sg:run
              world :max-frames 9 :visible nil
              :capture-path (merge-pathnames "artifacts/kernel-scene.ppm" *project-root*)
              :frame-hook
              (lambda (active window renderer frame)
                (declare (ignore window))
                (assert (eq active world))
                (assert (sg:world-running-p active))
                (assert (sg:validate-mesh mesh))
                (assert (= frame (sgeo.render:renderer-frame-count renderer)))
                (when (plusp frame)
                  (sgeo.backend.opengl:check-opengl-error "quadro anterior do núcleo"))
                (case frame
                  (0 (setf (sg:world-selection world) object))
                  (1
                   (assert (= 1 (sgeo.render:renderer-upload-count renderer)))
                   (let* ((vertex (first (sg:mesh-vertices mesh)))
                          (position (sg:vertex-position mesh vertex)))
                     (sg:set-vertex-position mesh vertex (sg:v+ position (sg:vec3 -0.1d0 0 0)))))
                  (2
                   (assert (= 2 (sgeo.render:renderer-upload-count renderer)))
                   (setf original-edge (first (sg:mesh-edges mesh))
                         kept-vertex (first (sg:edge-vertices mesh original-edge))
                         kept-position (sg:vertex-position mesh kept-vertex)
                         split-vertex (sg:split-edge mesh original-edge)))
                  (3
                   (assert (= 3 (sgeo.render:renderer-upload-count renderer)))
                   (let ((edge (find-if
                                (lambda (edge)
                                  (let ((vertices (sg:edge-vertices mesh edge)))
                                    (and (member split-vertex vertices :test #'same-kernel-handle-p)
                                         (member kept-vertex vertices :test #'same-kernel-handle-p))))
                                (sg:mesh-edges mesh))))
                     (assert edge)
                     (sg:collapse-edge mesh edge :keep kept-vertex :position kept-position)))
                  (4
                   (assert (= 4 (sgeo.render:renderer-upload-count renderer)))
                   (let ((revision (sg:object-revision mesh)) (rejected nil)
                         (vertices (sg:mesh-vertices mesh)))
                     (handler-case
                         (sg:set-vertex-position mesh (first vertices)
                                                 (sg:vertex-position mesh (second vertices)))
                       (sg:geometry-error () (setf rejected t)))
                     (assert rejected)
                     (assert (= revision (sg:object-revision mesh))))
                   (setf top-face (find-if (lambda (face) (> (sg:vy (sg:face-normal mesh face)) 0.9d0))
                                          (sg:mesh-faces mesh)))
                   (assert top-face)
                   (sg:extrude-face mesh top-face :distance 0.3d0))
                  (5
                   (assert (= 5 (sgeo.render:renderer-upload-count renderer)))
                   (let ((neighbor (find-if
                                    (lambda (face)
                                      (< (sg:dot (sg:face-normal mesh face)
                                                 (sg:face-normal mesh top-face)) 0.9d0))
                                    (sg:face-neighbors mesh top-face))))
                     (assert neighbor)
                     (sg:extrude-face-region mesh (list top-face neighbor) :distance 0.2d0)))
                  (6
                   (assert (= 6 (sgeo.render:renderer-upload-count renderer)))
                   (eval '(defun sgeo.examples:kernel-extrude-distance () 0.12d0))
                   (setf redefined-face (first (sg:mesh-faces mesh)))
                   (sgeo.examples:extrude-demo-face mesh redefined-face))
                  (7
                   (assert (= 7 (sgeo.render:renderer-upload-count renderer)))
                   (eval '(defun sgeo.examples:kernel-extrude-distance () 0.18d0))
                   (sgeo.examples:extrude-demo-face mesh redefined-face))
                  (8
                   (assert (= 8 (sgeo.render:renderer-upload-count renderer)))
                   (assert (= mesh-id (sg:object-id mesh)))
                   (assert (eq mesh (sg:mesh-object-geometry object)))
                   (let* ((camera (sg:world-camera world))
                          (eye (sg:camera-eye camera))
                          (ray (sg:make-ray eye (sg:v- (sg:vec3) eye))))
                     (assert (eq object (sg:ray-cast world ray))))))))
           (declare (ignore renderer))
           (assert (eq returned world))
           (assert (null (sg:runtime-report-platform-error report)) () "~S" report)
           (assert (null (sg:runtime-report-render-error report)) () "~S" report)
           (assert (= 9 (sg:runtime-report-frames report)))
           (assert (= 8 (sg:runtime-report-uploads report)))
           (assert (= 1 (sg:runtime-report-gpu-meshes report)))
           (assert (not (sg:world-running-p world)))
           (format t "~&M2: 9 quadros, 8 revisões enviadas, vértices/arestas/regiões editados na mesma malha.~%"))
      (eval '(defun sgeo.examples:kernel-extrude-distance () 0.3d0)))))

(handler-case
    (progn (run-kernel-demonstration) (uiop:quit 0))
  (error (condition)
    (format *error-output* "~&Falha na demonstração M2: ~A~%" condition)
    (uiop:quit 1)))
