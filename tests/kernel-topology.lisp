(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(test half-edge-mesh-explicit-boundary-cycles
  (let* ((mesh (sg:make-half-edge-mesh
                :positions (vector (sg:vec3 0 0 0) (sg:vec3 2 0 0)
                                   (sg:vec3 2 2 0) (sg:vec3 0 2 0))
                :faces '((0 1 2 3))))
         (counts (sg:mesh-counts mesh))
         (face (first (sg:mesh-faces mesh)))
         (loop (first (sg:boundary-loops mesh))))
    (is (sg:validate-mesh mesh))
    (is (= 4 (getf counts :vertices)))
    (is (= 4 (getf counts :edges)))
    (is (= 1 (getf counts :faces)))
    (is (= 8 (getf counts :half-edges)))
    (is (= 4 (getf counts :boundary-edges)))
    (is (= 4 (length (sg:face-half-edges mesh face))))
    (is (= 4 (length loop)))
    (is (every (lambda (half-edge) (sg:boundary-half-edge-p mesh half-edge)) loop))
    (is (every (lambda (half-edge)
                 (sg:boundary-half-edge-p mesh (sg:half-edge-twin mesh half-edge)))
               (sg:face-half-edges mesh face)))))

(test half-edge-mesh-closed-tetrahedron-has-no-boundary
  (let ((mesh (sg:make-half-edge-mesh
               :positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0)
                                  (sg:vec3 0 1 0) (sg:vec3 0 0 1))
               :faces '((0 2 1) (0 1 3) (1 2 3) (2 0 3)))))
    (is (sg:validate-mesh mesh))
    (is (= 6 (getf (sg:mesh-counts mesh) :edges)))
    (is (= 12 (getf (sg:mesh-counts mesh) :half-edges)))
    (is (= 0 (getf (sg:mesh-counts mesh) :boundary-edges)))
    (is (null (sg:boundary-loops mesh)))
    (is (= 3 (length (sg:vertex-neighbors mesh (first (sg:mesh-vertices mesh))))))))

(test half-edge-mesh-rejects-invalid-topology
  (let ((positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0)
                           (sg:vec3 0 1 0) (sg:vec3 0 -1 0)
                           (sg:vec3 0 0 1) (sg:vec3 -1 0 0))))
    (signals sg:topology-error
      (sg:make-half-edge-mesh :positions positions :faces '((0 1 2) (1 0 3) (0 1 4))))
    (signals sg:topology-error
      (sg:make-half-edge-mesh :positions positions :faces '((0 1 2) (0 3 5))))
    (signals sg:topology-error
      (sg:make-half-edge-mesh :positions positions :faces '((0 1 2) (0 2 1))))
    (signals sg:topology-error
      (sg:make-half-edge-mesh :positions positions :faces '((0 1 2) (0 3 4))))))

(defun %topology-same-handle-p (a b)
  (and (sg:mesh-handle-p a) (sg:mesh-handle-p b)
       (eq (sg:handle-kind a) (sg:handle-kind b))
       (= (sg:handle-index a) (sg:handle-index b))
       (= (sg:handle-generation a) (sg:handle-generation b))
       (= (sg:handle-mesh-id a) (sg:handle-mesh-id b))))

(defun %topology-edge-between (mesh a b)
  (find-if (lambda (edge)
             (let ((ends (sg:edge-vertices mesh edge)))
               (or (and (%topology-same-handle-p (first ends) a)
                        (%topology-same-handle-p (second ends) b))
                   (and (%topology-same-handle-p (first ends) b)
                        (%topology-same-handle-p (second ends) a)))))
           (sg:mesh-edges mesh)))

(defun %topology-half-edge-between (mesh a b)
  (find-if (lambda (half-edge)
             (and (%topology-same-handle-p (sg:half-edge-origin mesh half-edge) a)
                  (%topology-same-handle-p (sg:half-edge-destination mesh half-edge) b)))
           (sg:mesh-half-edges mesh)))

(defun %topology-outgoing-invariants-hold-p (mesh)
  (sgeo.geometry::%with-kernel-lock (mesh)
    (let* ((state (sgeo.geometry::%mesh-state mesh))
           (vertices (sgeo.geometry::%state-vertices state))
           (half-edges (sgeo.geometry::%state-half-edges state)))
      (every (lambda (vertex-index)
               (let* ((vertex (aref (sgeo.geometry::%arena-items vertices) vertex-index))
                      (outgoing (sgeo.geometry::vertex-record-outgoing vertex))
                      (has-outgoing
                        (loop for half-edge-index in (sgeo.geometry::%arena-active-indices half-edges)
                              thereis (= vertex-index
                                         (sgeo.geometry::half-edge-record-origin
                                          (aref (sgeo.geometry::%arena-items half-edges)
                                                half-edge-index))))))
                 (if has-outgoing
                     (and (sgeo.geometry::%active-slot-p half-edges outgoing)
                          (= vertex-index
                             (sgeo.geometry::half-edge-record-origin
                              (aref (sgeo.geometry::%arena-items half-edges) outgoing))))
                     (null outgoing))))
             (sgeo.geometry::%arena-active-indices vertices)))))

(test half-edge-independent-components-have-independent-boundary-cycles
  (let* ((mesh (sg:make-half-edge-mesh
                :positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0)
                                   (sg:vec3 1 1 0) (sg:vec3 0 1 0)
                                   (sg:vec3 3 0 0) (sg:vec3 4 0 0)
                                   (sg:vec3 4 1 0) (sg:vec3 3 1 0))
                :faces '((0 1 2 3) (4 5 6 7))))
         (faces (sg:mesh-faces mesh))
         (loops (sg:boundary-loops mesh)))
    (is (sg:validate-mesh mesh))
    (is (= 2 (length loops)))
    (is (every (lambda (cycle) (= 4 (length cycle))) loops))
    (is (= 1 (length (sg:connected-face-region mesh (first faces)))))
    (is (null (sg:face-neighbors mesh (first faces))))))

(test nearby-edit-preserves-unaffected-edge-and-half-edge-handles
  (let* ((mesh (sg:make-half-edge-mesh
                :positions (vector (sg:vec3 0 0 0) (sg:vec3 2 0 0)
                                   (sg:vec3 2 2 0) (sg:vec3 0 2 0))
                :faces '((0 1 2 3))))
         (vertices (sg:mesh-vertices mesh))
         (split-edge (%topology-edge-between mesh (first vertices) (second vertices)))
         (split-half-edge (%topology-half-edge-between mesh (first vertices) (second vertices)))
         (unaffected-edge (%topology-edge-between mesh (third vertices) (fourth vertices)))
         (unaffected-half-edge (%topology-half-edge-between mesh (third vertices) (fourth vertices)))
         new-vertex)
    (is (not (null unaffected-edge)))
    (is (not (null unaffected-half-edge)))
    (setf new-vertex (sg:split-edge mesh split-edge :parameter 0.5d0))
    (is (%topology-outgoing-invariants-hold-p mesh))
    (is (sg:validate-mesh mesh))
    (let ((replacement-edges
            (list (%topology-edge-between mesh (first vertices) new-vertex)
                  (%topology-edge-between mesh new-vertex (second vertices)))))
      (is (some (lambda (edge)
                  (and (= (sg:handle-index edge) (sg:handle-index split-edge))
                       (= (sg:handle-generation edge)
                          (1+ (sg:handle-generation split-edge)))))
                replacement-edges)))
    (is (%topology-same-handle-p
         unaffected-edge
         (find-if (lambda (edge) (%topology-same-handle-p edge unaffected-edge))
                  (sg:mesh-edges mesh))))
    (is (%topology-same-handle-p
         (sg:half-edge-origin mesh unaffected-half-edge) (third vertices)))
    (is (%topology-same-handle-p
         (sg:half-edge-destination mesh unaffected-half-edge) (fourth vertices)))
    (signals sg:stale-handle-error (sg:edge-vertices mesh split-edge))
    (signals sg:stale-handle-error (sg:half-edge-origin mesh split-half-edge))))

(test retired-vertex-slot-reuse-increments-generation
  (let* ((mesh (sg:make-half-edge-mesh
                :positions (vector (sg:vec3 0 0 0) (sg:vec3 2 0 0)
                                   (sg:vec3 2 2 0) (sg:vec3 0 2 0))
                :faces '((0 1 2 3))))
         (vertices (sg:mesh-vertices mesh))
         (first-split (sg:split-edge
                       mesh (%topology-edge-between mesh (first vertices) (second vertices))))
         (first-generation (sg:handle-generation first-split)))
    (sg:collapse-edge mesh (%topology-edge-between mesh (first vertices) first-split)
                      :keep (first vertices) :position (sg:vec3 0 0 0))
    (signals sg:stale-handle-error (sg:vertex-position mesh first-split))
    (let* ((current-vertices (sg:mesh-vertices mesh))
           (second-split (sg:split-edge
                          mesh (%topology-edge-between mesh (third current-vertices)
                                                       (fourth current-vertices)))))
      (is (= (sg:handle-index first-split) (sg:handle-index second-split)))
      (is (= (1+ first-generation) (sg:handle-generation second-split)))
      (signals sg:stale-handle-error (sg:vertex-position mesh first-split)))))

(test malformed-foreign-and-stale-handles-are-rejected
  (let* ((mesh (sg:make-half-edge-mesh
                :positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0) (sg:vec3 0 1 0))
                :faces '((0 1 2))))
         (other (sg:make-half-edge-mesh
                 :positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0) (sg:vec3 0 1 0))
                 :faces '((0 1 2))))
         (vertex (first (sg:mesh-vertices mesh)))
         (edge (first (sg:mesh-edges mesh)))
         (foreign (first (sg:mesh-vertices other)))
         (forged-index (sgeo.geometry::%make-mesh-handle
                        (sg:handle-mesh-id vertex) :vertex -1
                        (sg:handle-generation vertex)))
         (forged-generation (sgeo.geometry::%make-mesh-handle
                             (sg:handle-mesh-id vertex) :vertex
                             (sg:handle-index vertex) (1+ (sg:handle-generation vertex))))
         (forged-kind (sgeo.geometry::%make-mesh-handle
                       (sg:handle-mesh-id vertex) :edge
                       (sg:handle-index vertex) (sg:handle-generation vertex))))
    (signals sg:stale-handle-error (sg:vertex-position mesh foreign))
    (signals sg:stale-handle-error (sg:vertex-position mesh edge))
    (signals sg:stale-handle-error (sg:vertex-position mesh forged-index))
    (signals sg:stale-handle-error (sg:vertex-position mesh forged-generation))
    (signals sg:stale-handle-error (sg:vertex-position mesh forged-kind))))

(test non-finite-position-is-rejected
  (let ((positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0)
                           (vector 0 1 (expt 10 10000)))))
    (signals sg:geometry-error
      (sg:make-half-edge-mesh :positions positions :faces '((0 1 2))))))

(test concurrent-kernel-readers-and-edits
  (let* ((mesh (sg:make-half-edge-mesh
                :positions (vector (sg:vec3 0 0 0) (sg:vec3 1 0 0)
                                   (sg:vec3 1 1 0) (sg:vec3 0 1 0))
                :faces '((0 1 2 3))))
         (vertices (sg:mesh-vertices mesh))
         (errors nil)
         (error-lock (bt:make-lock "topology test errors"))
         (threads nil))
    (flet ((record-error (condition)
             (bt:with-lock-held (error-lock) (push condition errors))))
      (setf threads
            (list
             (bt:make-thread
              (lambda ()
                (handler-case
                    (dotimes (iteration 12)
                      (sg:set-vertex-position
                       mesh (first vertices)
                       (sg:vec3 (- 0.05d0 (* 0.005d0 (mod iteration 2))) 0 0)))
                  (error (condition) (record-error condition))))
              :name "topology writer one")
             (bt:make-thread
              (lambda ()
                (handler-case
                    (dotimes (iteration 12)
                      (sg:set-vertex-position
                       mesh (third vertices)
                       (sg:vec3 1 (+ 1d0 (* 0.005d0 (mod iteration 2))) 0)))
                  (error (condition) (record-error condition))))
              :name "topology writer two")
             (bt:make-thread
              (lambda ()
                (handler-case
                    (dotimes (iteration 100)
                      (unless (= 4 (getf (sg:mesh-counts mesh) :vertices))
                        (error "A leitura observou uma arena de vértices incompleta."))
                      (unless (= 1 (length (sg:boundary-loops mesh)))
                        (error "A leitura observou ciclos de borda incompletos."))
                      (unless (every #'sg:mesh-handle-p (sg:vertex-neighbors mesh (first vertices)))
                        (error "A leitura recebeu um identificador de vizinho inválido.")))
                  (error (condition) (record-error condition))))
              :name "topology reader")))
      (mapc #'bt:join-thread threads)
      (is (null errors))
      (is (= 24 (sg:object-revision mesh)))
      (is (sg:validate-mesh mesh)))))
