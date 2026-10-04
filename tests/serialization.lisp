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

(test serialization-base-strings-ignore-hostile-printer-state
  (let* ((path (merge-pathnames "sgeo-base-string-printer-test.scene" (uiop:temporary-directory)))
         (object-name (format nil "Object ~D" 42))
         (material-name (format nil "Copper ~,2F" 0.8d0))
         (metadata-key (format nil "label ~D" 3))
         (metadata-value (format nil "value ~D" 9))
         (material (sg:make-pbr-material :name material-name :metallic 0.8d0 :roughness 0.2d0))
         (object (sg:make-mesh-object (sg:make-half-edge-box) :name object-name :material material))
         (world (sg:make-world :root object)))
    (setf (gethash metadata-key (sg:object-metadata object)) metadata-value
          (gethash metadata-key (sg:object-metadata material)) metadata-value)
    (is (typep object-name '(simple-array base-char (*))))
    (is (typep material-name '(simple-array base-char (*))))
    (unwind-protect
         (let ((*print-readably* nil) (*print-escape* nil) (*print-array* t)
               (*print-base* 16) (*print-radix* t) (*print-circle* t)
               (*print-gensym* nil) (*print-pretty* t) (*print-case* :downcase)
               (*print-level* 1) (*print-length* 2) (*print-lines* 1)
               (*package* (find-package :cl-user)))
           (sgeo.serialization:save-world world path)
           (let* ((text (uiop:read-file-string path))
                  (loaded (sgeo.serialization:load-world path))
                  (loaded-object (sg:world-root loaded))
                  (loaded-material (sg:mesh-object-material loaded-object)))
             (is (search (format nil "\"~A\"" material-name) text))
             (is (not (search "#A" text)))
             (is (string= object-name (sg:object-name loaded-object)))
             (is (string= material-name (sg:object-name loaded-material)))
             (is (string= metadata-value
                          (gethash metadata-key (sg:object-metadata loaded-object))))
             (is (string= metadata-value
                          (gethash metadata-key (sg:object-metadata loaded-material))))))
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

(defun %serialization-hierarchy-names (root)
  "Retorna nomes em pré-ordem, respeitando a ordem dos irmãos."
  (labels ((visit (object)
             (cons (sg:object-name object)
                   (mapcan #'visit (sg:scene-object-children object)))))
    (visit root)))

(test serialization-preserves-sibling-order-and-first-light
  (let* ((root (sg:make-scene-object :name "Raiz"))
         (box-a (sg:make-mesh-object (sg:make-half-edge-box) :name "Caixa A"))
         (branch (sg:make-scene-object :name "Ramo"))
         (nested-box (sg:make-mesh-object (sg:make-half-edge-box :size 0.5d0)
                                          :name "Caixa interna"))
         (branch-note (sg:make-scene-object :name "Nota do ramo"))
         (sun-first (sg:make-directional-light :name "Sol principal"
                                              :direction #(0d0 -1d0 0d0) :intensity 4d0))
         (box-b (sg:make-mesh-object (sg:make-half-edge-box :size 2d0) :name "Caixa B"))
         (sun-second (sg:make-directional-light :name "Sol secundário"
                                               :direction #(1d0 -1d0 0d0) :intensity 9d0))
         (world (sg:make-world :root root)))
    ;; A anexação insere no início, então monta a cena na ordem de leitura desejada.
    (dolist (child (list sun-second box-b sun-first branch box-a))
      (sg:add-child root child))
    (dolist (child (list branch-note nested-box))
      (sg:add-child branch child))
    (let* ((data (sgeo.serialization:scene-data world))
           (copy (sgeo.serialization:world-from-data data))
           (source-names (%serialization-hierarchy-names root))
           (copy-names (%serialization-hierarchy-names (sg:world-root copy)))
           (source-frame (sgeo.render:modern-scene-snapshot world))
           (copy-frame (sgeo.render:modern-scene-snapshot copy)))
      (is (equal '("Raiz" "Caixa A" "Ramo" "Caixa interna" "Nota do ramo"
                   "Sol principal" "Caixa B" "Sol secundário") source-names))
      (is (equal source-names copy-names))
      (is (equal '("Caixa A" "Caixa interna" "Caixa B")
                 (mapcar (lambda (entry) (sg:object-name (getf entry :object)))
                         (getf source-frame :objects))))
      (is (equal (mapcar (lambda (entry) (sg:object-name (getf entry :object)))
                         (getf source-frame :objects))
                 (mapcar (lambda (entry) (sg:object-name (getf entry :object)))
                         (getf copy-frame :objects))))
      (is (equalp (sg:directional-light-data sun-first) (getf source-frame :light)))
      (is (equalp (getf source-frame :light) (getf copy-frame :light))))))

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
