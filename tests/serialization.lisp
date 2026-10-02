(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(defun %serialization-fixture-world ()
  (let* ((root (sg:make-scene-object :name "Raiz" :position '(1d0 2d0 3d0)))
         (tri (sg:make-triangle-mesh-from-data
               '(0d0 0d0 0d0  1d0 0d0 0d0  0d0 1d0 0d0)
               '(0 1 2) :name "Triângulo"))
         (poly (sg:make-half-edge-mesh
                :positions '((0d0 0d0 0d0) (1d0 0d0 0d0)
                             (1d0 1d0 0d0) (0d0 1d0 0d0))
                :faces '((0 1 2 3)) :name "Quad"))
         (material (sg:make-material :name "Comum" :color '(0.2d0 0.4d0 0.6d0)
                                     :wireframe-p t))
         (triangle-object (sg:make-mesh-object tri :name "Objeto tri" :material material
                                               :position '(3d0 0d0 0d0)))
         (polygon-object (sg:make-mesh-object poly :name "Objeto quad" :material material))
         (camera (sg:make-camera :eye '(4d0 3d0 6d0) :target '(0d0 0d0 0d0)
                                 :projection-mode :orthographic :orthographic-height 9d0))
         (world (sg:make-world :root root :camera camera)))
    (setf (gethash "purpose" (sg:object-metadata root)) "fixture"
          (gethash :origin (sg:object-metadata tri)) '("persistente" 42))
    (sg:add-child root triangle-object)
    (sg:add-child triangle-object polygon-object)
    (setf (sg:world-selection world) polygon-object)
    world))

(test serialization-readable-scene-data-roundtrip
  (let* ((source (%serialization-fixture-world))
         (data (sgeo.serialization:scene-data source))
         (copy (sgeo.serialization:world-from-data data))
         (children (sg:scene-object-children (sg:world-root copy)))
         (triangle-object (first children))
         (polygon-object (first (sg:scene-object-children triangle-object))))
    (is (eq (first data) :sgeo-scene))
    (is (= (getf (rest data) :version) 1))
    (is (string= (sg:object-name (sg:world-root copy)) "Raiz"))
    (is (equal "fixture" (gethash "purpose" (sg:object-metadata (sg:world-root copy)))))
    (is (typep (sg:mesh-object-geometry triangle-object) 'sg:triangle-mesh))
    (is (typep (sg:mesh-object-geometry polygon-object) 'sg:half-edge-mesh))
    (is (eq (sg:mesh-object-material triangle-object)
            (sg:mesh-object-material polygon-object)))
    (is (sg:simple-material-wireframe-p (sg:mesh-object-material triangle-object)))
    (is (eq (sg:camera-projection-mode (sg:world-camera copy)) :orthographic))
    (is (approximately= (sg:camera-orthographic-height (sg:world-camera copy)) 9d0))
    (is (eq (sg:world-selection copy) polygon-object))))

(test serialization-file-roundtrip-and-atomic-replacement
  (let* ((path (merge-pathnames "sgeo-serialization-test.scene" (uiop:temporary-directory)))
         (world (%serialization-fixture-world)))
    (unwind-protect
         (progn
           (sgeo.serialization:save-world world path)
           (let ((loaded (sgeo.serialization:load-world path)))
             (is (string= (sg:object-name (sg:world-root loaded)) "Raiz"))
             (is (= (length (sg:scene-object-children (sg:world-root loaded))) 1)))
           ;; Uma segunda gravação deve substituir o arquivo já existente.
           (sgeo.serialization:save-world world path)
           (is (probe-file path)))
      (when (probe-file path) (delete-file path)))))

(test serialization-preserves-mesh-root-worlds
  (let* ((geometry (sg:make-half-edge-mesh
                    :positions '((0d0 0d0 0d0) (1d0 0d0 0d0) (0d0 1d0 0d0))
                    :faces '((0 1 2))))
         (root (sg:make-mesh-object geometry :name "Raiz de malha"))
         (world (sg:make-world :root root))
         (copy (sgeo.serialization:world-from-data (sgeo.serialization:scene-data world))))
    (is (string= (sg:object-name (sg:world-root copy)) "Raiz de malha"))
    (is (typep (sg:mesh-object-geometry (sg:world-root copy)) 'sg:half-edge-mesh))))

(test serialization-rejects-malformed-data-before-construction
  (let* ((data (sgeo.serialization:scene-data (%serialization-fixture-world)))
         (bad-version (copy-list data))
         (bad-reference (copy-tree data))
         (bad-cycle (copy-tree data)))
    (setf (getf (rest bad-version) :version) 77)
    (signals sg:validation-error (sgeo.serialization:world-from-data bad-version))
    (let* ((object (find-if (lambda (record) (eq (getf record :type) :mesh-object))
                            (getf (rest bad-reference) :objects))))
      (setf (getf object :geometry-id) 987654321)
      (signals sg:validation-error (sgeo.serialization:world-from-data bad-reference)))
    (let* ((objects (getf (rest bad-cycle) :objects))
           (root (first objects))
           (child (second objects)))
      (setf (getf root :parent-id) (getf child :id))
      (signals sg:validation-error (sgeo.serialization:world-from-data bad-cycle)))))

(test serialization-safe-reader-rejects-evaluation-and-extra-forms
  (let ((path (merge-pathnames "sgeo-serialization-invalid.scene" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (stream path :direction :output :if-exists :supersede)
             (write-string "#.(progn (error \"não pode avaliar\"))" stream))
           (signals sg:validation-error (sgeo.serialization:load-world path))
           (with-open-file (stream path :direction :output :if-exists :supersede)
             (write-string "(:sgeo-scene :version 1) (:segunda-forma)" stream))
           (signals sg:validation-error (sgeo.serialization:load-world path)))
      (when (probe-file path) (delete-file path)))))
