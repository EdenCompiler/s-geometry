(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(defclass inspector-probe ()
  ((number :initarg :number :reader inspector-probe-number)
   (label :initarg :label :reader inspector-probe-label)))

(defun %inspector-row-named (rows label)
  (find label rows :key (lambda (row) (getf row :label)) :test #'string=))

(test inspector-browses-values-arrays-hashes-and-objects
  (let* ((probe (make-instance 'inspector-probe :number 17 :label "slot"))
         (object (sg:make-scene-object :name "Nó"))
         (array (vector 3 "texto"))
         (table (make-hash-table :test #'equal)))
    (setf (gethash "alvo" table) object)
    (is (= (getf (%inspector-row-named (sgeo.editor:inspect-value probe) "number") :value) 17))
    (is (string= (getf (%inspector-row-named (sgeo.editor:inspect-value probe) "label") :value) "slot"))
    (is (equal "texto" (getf (%inspector-row-named (sgeo.editor:inspect-value array) "[1]") :value)))
    (is (eq object (getf (%inspector-row-named (sgeo.editor:inspect-value table) "alvo") :reference)))
    (is (string= (getf (%inspector-row-named (sgeo.editor:inspect-value object) "Nome") :value)
                 "Nó"))))

(test inspector-navigates-mesh-topology-and-back-stack
  (let* ((mesh (sg:make-half-edge-box))
         (world (sg:make-world :root (sg:make-mesh-object mesh)))
         (editor (sgeo.editor:make-editor :world world))
         (face (first (sg:mesh-faces mesh)))
         (vertex (first (sg:face-vertices mesh face))))
    (unwind-protect
         (progn
           (is (%inspector-row-named (sgeo.editor:inspect-value mesh) "Faces"))
           (sgeo.editor:inspect-editor editor (list :element mesh face))
           (is (%inspector-row-named (sgeo.editor:inspect-value (sgeo.editor:editor-inspected editor)) "Vértices"))
           (sgeo.editor:inspect-editor editor (list :element mesh vertex))
           (is (%inspector-row-named (sgeo.editor:inspect-value (sgeo.editor:editor-inspected editor)) "Vizinhos"))
           (sgeo.editor:inspect-back editor)
           (is (eq (sgeo.geometry:handle-kind
                    (third (sgeo.editor:editor-inspected editor))) :face)))
      (sgeo.editor:close-editor editor))))

(test inspector-numeric-edits-use-commands-and-support-undo
  (let* ((mesh (sg:make-half-edge-box))
         (material (sg:make-material :color '(0.25d0 0.5d0 0.75d0)))
         (object (sg:make-mesh-object mesh :material material :position '(1d0 2d0 3d0)))
         (world (sg:make-world :root object))
         (editor (sgeo.editor:make-editor :world world))
         (vertex (first (sg:mesh-vertices mesh)))
         (old-vertex-position (sg:vertex-position mesh vertex)))
    (unwind-protect
         (progn
           (sgeo.editor:set-inspector-number editor :position 9d0 :axis 1)
           (is (approximately= (aref (sgeo.math:transform-position
                                     (sg:scene-object-local-transform object)) 1) 9d0))
           (sgeo.editor:undo-edit editor)
           (is (approximately= (aref (sgeo.math:transform-position
                                     (sg:scene-object-local-transform object)) 1) 2d0))
           (setf vertex (first (sg:mesh-vertices mesh)))
           (sgeo.editor:inspect-editor editor (list :element mesh vertex))
           (sgeo.editor:set-inspector-number editor :vertex-position
                                             (+ (aref old-vertex-position 2) 0.1d0) :axis 2)
           (is (approximately= (aref (sg:vertex-position mesh vertex) 2)
                               (+ (aref old-vertex-position 2) 0.1d0)))
           (sgeo.editor:undo-edit editor)
           (setf vertex (first (sg:mesh-vertices mesh)))
           (is (vector-approximately= (sg:vertex-position mesh vertex) old-vertex-position))
           (sgeo.editor:inspect-editor editor object)
           (sgeo.editor:set-inspector-number editor :color 0.1d0 :axis 0)
           (is (approximately= (aref (sg:simple-material-color material) 0) 0.1d0))
           (sgeo.editor:undo-edit editor)
           (is (approximately= (aref (sg:simple-material-color material) 0) 0.25d0)))
      (sgeo.editor:close-editor editor))))

(test inspector-camera-number-fields-use-camera-command
  (let* ((camera (sg:make-camera))
         (world (sg:make-world :camera camera))
         (editor (sgeo.editor:make-editor :world world)))
    (unwind-protect
         (progn
           (sgeo.editor:set-inspector-number editor :camera-fov 0.8d0)
           (is (approximately= (sg:camera-fov camera) 0.8d0))
           (sgeo.editor:undo-edit editor)
           (is (approximately= (sg:camera-fov camera) (/ pi 3d0)))
           (sgeo.editor:set-inspector-number editor :camera-orthographic-height 12d0)
           (is (approximately= (sg:camera-orthographic-height camera) 12d0)))
      (sgeo.editor:close-editor editor))))

(test inspector-material-reference-can-be-edited-without-selection
  (let* ((material (sg:make-material :color #(0.2d0 0.4d0 0.6d0)))
         (object (sg:make-mesh-object (sg:make-half-edge-box) :material material))
         (world (sg:make-world :root object))
         (editor (sgeo.editor:make-editor :world world)))
    (unwind-protect
         (progn
           (setf (sg:world-selection world) nil)
           (let* ((material-row (%inspector-row-named
                                 (sgeo.editor:inspect-value object) "Material"))
                  (reference (getf material-row :reference)))
             (is (eq material reference))
             (sgeo.editor:inspect-editor editor reference))
           (sgeo.editor:set-inspector-number editor :color 0.9d0 :axis 1)
           (is (approximately= 0.9d0 (aref (sg:simple-material-color material) 1)))
           (sgeo.editor:undo-edit editor)
           (is (vector-approximately= (sg:simple-material-color material) #(0.2d0 0.4d0 0.6d0))))
      (sgeo.editor:close-editor editor))))
