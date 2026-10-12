(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(sgeo.procedural:define-geometry-generator procedural-test-box ((size 1d0))
  (sgeo.geometry:make-half-edge-box :size size :name "Generated box"))

(sgeo.procedural:define-geometry-generator procedural-failure-box ((size 1d0))
  (when (<= size 0d0) (error "box size must remain positive"))
  (sgeo.geometry:make-half-edge-box :size size :name "Failure-safe box"))

(test procedural-graph-caches-and-invalidates-only-consumers
  (let* ((calls 0)
         (graph (sgeo.procedural:make-dependency-graph)))
    (sgeo.procedural:add-parameter-node graph :size 1d0)
    (sgeo.procedural:define-generator
     'counted-generator nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (incf calls)
       (gethash "size" dependencies)))
    (sgeo.procedural:add-generator-node graph :consumer 'counted-generator '(:size))
    (sgeo.procedural:add-parameter-node graph :unused 17)
    (is (= 1d0 (sgeo.procedural:evaluate-node graph :consumer)))
    (is (= 1 calls))
    (is (= 1d0 (sgeo.procedural:evaluate-node graph :consumer)))
    (is (= 1 calls))
    (sgeo.procedural:set-parameter graph :unused 18)
    (is-false (sgeo.procedural:node-dirty-p graph :consumer))
    (sgeo.procedural:set-parameter graph :size 2d0)
    (is-true (sgeo.procedural:node-dirty-p graph :consumer))
    (is (= 2d0 (sgeo.procedural:evaluate-node graph :consumer)))
    (is (= 2 calls))))

(test procedural-graph-rejects-cycles-and-keeps-last-valid-value
  (let ((graph (sgeo.procedural:make-dependency-graph))
        (fail-p nil))
    (sgeo.procedural:add-parameter-node graph :source 2)
    (sgeo.procedural:define-generator
     'sometimes-failing nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (when fail-p (error "generator failed"))
       (loop for value being the hash-values of dependencies return value)))
    (sgeo.procedural:add-generator-node graph :middle 'sometimes-failing '(:source))
    (sgeo.procedural:add-generator-node graph :end 'sometimes-failing '(:middle))
    (is (= 2 (sgeo.procedural:evaluate-node graph :end)))
    (signals error (sgeo.procedural:set-generator-inputs graph :middle '(:end)))
    (setf fail-p t)
    (sgeo.procedural:set-parameter graph :source 3)
    (signals error (sgeo.procedural:evaluate-node graph :end))
    (is (= 2 (sgeo.procedural:node-value graph :end)))
    (is-true (sgeo.procedural:node-dirty-p graph :end))
    (is (typep (sgeo.procedural:node-error graph :end) 'error))))

(test procedural-generator-redefinition-updates-existing-object
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (object nil))
    (sgeo.procedural:define-geometry-generator procedural-test-box ((size 1d0))
      (sgeo.geometry:make-half-edge-box :size size :name "Generated box"))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-test-box nil)
    (setf object (sgeo.procedural:make-procedural-object graph :mesh :name "Live object"))
    (let ((object-id (sgeo.core:object-id object))
          (mesh (sgeo.scene:mesh-object-geometry object)))
      (sgeo.procedural:define-geometry-generator procedural-test-box ((size 3d0))
        (sgeo.geometry:make-half-edge-box :size (* 2d0 size) :name "Redefined box"))
      (sgeo.procedural:regenerate-procedural-object object)
      (is (= object-id (sgeo.core:object-id object)))
      (is (eq mesh (sgeo.scene:mesh-object-geometry object)))
      (is (= 24d0 (sgeo.geometry:mesh-surface-area mesh)))
      (is (eq mesh (sgeo.procedural:node-value graph :mesh))))))

(test procedural-generator-cross-type-output-stays-published
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (object nil) (world nil))
    (sgeo.procedural:define-generator
     'procedural-typed-output nil
     (lambda (parameters dependencies)
       (declare (ignore parameters dependencies))
       (sgeo.geometry:make-half-edge-box)))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-typed-output nil)
    (setf object (sgeo.procedural:make-procedural-object graph :mesh)
          world (sgeo.scene:make-world :root object))
    (let ((object-id (sgeo.core:object-id object)))
      (dolist (constructor '(sgeo.geometry:make-box sgeo.geometry:make-half-edge-box))
        (let ((make-result constructor))
          (sgeo.procedural:define-generator
           'procedural-typed-output nil
           (lambda (parameters dependencies)
             (declare (ignore parameters dependencies))
             (funcall make-result))))
        (sgeo.scene:update-world world 0d0)
        (let* ((mesh (sgeo.scene:mesh-object-geometry object))
               (revision (sgeo.core:object-revision mesh)))
          (is (typep mesh (if (eq constructor 'sgeo.geometry:make-box)
                             'sgeo.geometry:triangle-mesh 'sgeo.geometry:half-edge-mesh)))
          (is (eq mesh (sgeo.procedural:node-value graph :mesh)))
          (sgeo.scene:update-world world 0d0)
          (sgeo.scene:update-world world 0d0)
          (is (eq mesh (sgeo.scene:mesh-object-geometry object)))
          (is (= revision (sgeo.core:object-revision mesh)))
          (is (= object-id (sgeo.core:object-id object))))))))

(test procedural-failed-regeneration-retains-live-mesh-and-records-error
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (object nil))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-failure-box nil)
    (setf object (sgeo.procedural:make-procedural-object graph :mesh))
    (let* ((mesh (sgeo.scene:mesh-object-geometry object))
           (area (sgeo.geometry:mesh-surface-area mesh))
           (revision (sgeo.core:object-revision mesh)))
      (sgeo.procedural:set-generator-parameter graph :mesh :size -1d0)
      (signals error (sgeo.procedural:regenerate-procedural-object object))
      (is (eq mesh (sgeo.scene:mesh-object-geometry object)))
      (is (= area (sgeo.geometry:mesh-surface-area mesh)))
      (is (= revision (sgeo.core:object-revision mesh)))
      (is (typep (sgeo.procedural:node-error graph :mesh) 'error))
      (is-true (sgeo.procedural:node-dirty-p graph :mesh)))))

(test procedural-editor-undo-redo-restores-graph-and-mesh-together
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (object nil) (world nil) (editor nil))
    (sgeo.procedural:add-parameter-node graph :size 1d0)
    (sgeo.procedural:define-generator
     'procedural-transaction-box nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (sgeo.geometry:make-half-edge-box :size (gethash "size" dependencies))))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-transaction-box '(:size))
    (setf object (sgeo.procedural:make-procedural-object graph :mesh)
          world (sgeo.scene:make-world :root object)
          editor (sgeo.editor:make-editor :world world))
    (let ((mesh (sgeo.scene:mesh-object-geometry object)))
      (sgeo.editor:edit-procedural-parameter editor :size 2d0)
      (is (= 24d0 (sgeo.geometry:mesh-surface-area mesh)))
      (sgeo.editor:undo-edit editor)
      (is (= 6d0 (sgeo.geometry:mesh-surface-area mesh)))
      (is (= 1d0 (sgeo.procedural:node-value graph :size)))
      (sgeo.editor:redo-edit editor)
      (is (= 24d0 (sgeo.geometry:mesh-surface-area mesh)))
      (is (= 2d0 (sgeo.procedural:node-value graph :size))))))

(test procedural-world-update-applies-live-changes-once-and-keeps-unchanged-handles
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (object nil) (world nil) (mesh nil) (vertex nil))
    (sgeo.procedural:add-parameter-node graph :size 1d0)
    (sgeo.procedural:define-generator
     'procedural-world-box nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (sgeo.geometry:make-half-edge-box :size (gethash "size" dependencies))))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-world-box '(:size))
    (setf object (sgeo.procedural:make-procedural-object graph :mesh)
          world (sgeo.scene:make-world :root object)
          mesh (sgeo.scene:mesh-object-geometry object)
          vertex (first (sgeo.geometry:mesh-vertices mesh)))
    (let ((revision (sgeo.core:object-revision mesh)))
      (sgeo.scene:update-world world 0d0)
      (sgeo.scene:update-world world 0d0)
      (is (= revision (sgeo.core:object-revision mesh)))
      (is (member vertex (sgeo.geometry:mesh-vertices mesh) :test #'equalp)))
    (sgeo.procedural:set-parameter graph :size 2d0)
    (sgeo.scene:update-world world 0d0)
    (is (= 24d0 (sgeo.geometry:mesh-surface-area mesh)))
    (is (eq mesh (sgeo.scene:mesh-object-geometry object)))
    (let ((stable-revision (sgeo.core:object-revision mesh))
          (stable-vertex (first (sgeo.geometry:mesh-vertices mesh))))
      (sgeo.scene:update-world world 0d0)
      (is (= stable-revision (sgeo.core:object-revision mesh)))
      (is (member stable-vertex (sgeo.geometry:mesh-vertices mesh) :test #'equalp)))
    (sgeo.procedural:define-generator
     'procedural-world-box nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (sgeo.geometry:make-half-edge-box :size (* 2d0 (gethash "size" dependencies)))))
    (sgeo.scene:update-world world 0d0)
    (is (= 96d0 (sgeo.geometry:mesh-surface-area mesh)))
    (is (eq mesh (sgeo.scene:mesh-object-geometry object)))))

(test procedural-external-object-revisions-invalidate-only-dependent-generators
  (let* ((source (sgeo.geometry:make-half-edge-box))
         (graph (sgeo.procedural:make-dependency-graph))
         (dependent-calls 0) (unrelated-calls 0))
    (sgeo.procedural:add-parameter-node graph :source source)
    (sgeo.procedural:define-generator
     'procedural-source-area nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (incf dependent-calls)
       (sgeo.geometry:mesh-surface-area (gethash "source" dependencies))))
    (sgeo.procedural:define-generator
     'procedural-unrelated nil
     (lambda (parameters dependencies)
       (declare (ignore parameters dependencies))
       (incf unrelated-calls)))
    (sgeo.procedural:add-generator-node graph :area 'procedural-source-area '(:source))
    (sgeo.procedural:add-generator-node graph :unrelated 'procedural-unrelated nil)
    (is (= 6d0 (sgeo.procedural:evaluate-node graph :area)))
    (sgeo.procedural:evaluate-node graph :unrelated)
    (let ((before (sgeo.procedural:node-value graph :area))
          (vertex (first (sgeo.geometry:mesh-vertices source))))
      (sgeo.geometry:set-vertex-position source vertex (sgeo.math:make-vec3 -2d0 -0.5d0 -0.5d0))
      (is-true (sgeo.procedural:node-dirty-p graph :area))
      (is-false (sgeo.procedural:node-dirty-p graph :unrelated))
      (is (/= before (sgeo.procedural:evaluate-node graph :area)))
      (is (= 2 dependent-calls))
      (is (= 1 unrelated-calls)))))

(test procedural-update-suppresses-failed-retries-until-inputs-change
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (calls 0) (object nil) (world nil) (mesh nil))
    (sgeo.procedural:add-parameter-node graph :size 1d0)
    (sgeo.procedural:define-generator
     'procedural-retry-box nil
     (lambda (parameters dependencies)
       (declare (ignore parameters))
       (incf calls)
       (let ((size (gethash "size" dependencies)))
         (when (<= size 0d0) (error "invalid size"))
         (sgeo.geometry:make-half-edge-box :size size))))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-retry-box '(:size))
    (setf object (sgeo.procedural:make-procedural-object graph :mesh)
          world (sgeo.scene:make-world :root object)
          mesh (sgeo.scene:mesh-object-geometry object))
    (sgeo.procedural:set-parameter graph :size -1d0)
    (loop repeat 4 do (sgeo.scene:update-world world 0d0))
    (is (= 2 calls))
    (is (= 6d0 (sgeo.geometry:mesh-surface-area mesh)))
    (is (typep (sgeo.procedural:node-error graph :mesh) 'error))
    (sgeo.procedural:set-parameter graph :size 2d0)
    (sgeo.scene:update-world world 0d0)
    (is (= 3 calls))
    (is (= 24d0 (sgeo.geometry:mesh-surface-area mesh)))
    (is (null (sgeo.procedural:node-error graph :mesh)))))

(test procedural-persistence-stores-data-and-resolves-registered-generator
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (object nil))
    (sgeo.procedural:define-geometry-generator procedural-test-box ((size 2d0))
      (sgeo.geometry:make-half-edge-box :size size))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-test-box nil)
    (setf object (sgeo.procedural:make-procedural-object graph :mesh))
    (let* ((data (sgeo.procedural:procedural-data object))
           (restored (sgeo.procedural:procedural-from-data data)))
      (is (typep restored 'sgeo.procedural:procedural-object))
      (is (equal :mesh (intern (string-upcase (sgeo.procedural:procedural-output restored)) :keyword)))
      (is (equal '(:sgeo-dependency-graph 1
                   ((:generator "mesh" "procedural-test-box" nil (:size 2d0))))
                 (sgeo.procedural:graph-data (sgeo.procedural:procedural-graph restored)))))))

(test procedural-scene-persistence-keeps-frozen-mesh-with-missing-generator
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (old-definition (sgeo.procedural:find-generator 'procedural-test-box))
         (object nil) (world nil) (data nil) (copy nil))
    (sgeo.procedural:define-geometry-generator procedural-test-box ((size 2d0))
      (sgeo.geometry:make-half-edge-box :size size))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-test-box nil)
    (setf object (sgeo.procedural:make-procedural-object graph :mesh)
          world (sgeo.scene:make-world :root object)
          data (sgeo.serialization:scene-data world))
    (is (= 3 (getf (rest data) :version)))
    (unwind-protect
         (progn
           (remhash "procedural-test-box" sgeo.procedural::*generator-definitions*)
           (setf copy (sgeo.serialization:world-from-data data))
           (let ((restored (sgeo.scene:world-root copy)))
             (is (typep restored 'sgeo.procedural:procedural-object))
           (is (= 24d0 (sgeo.geometry:mesh-surface-area
                          (sgeo.scene:mesh-object-geometry restored))))
             (is (typep (sgeo.procedural:node-error
                         (sgeo.procedural:procedural-graph restored) :mesh)
                        'error))
             (is-true (sgeo.procedural:node-dirty-p
                       (sgeo.procedural:procedural-graph restored) :mesh))
             (sgeo.scene:update-world copy 0d0)
             (is (= 24d0 (sgeo.geometry:mesh-surface-area
                          (sgeo.scene:mesh-object-geometry restored))))
             (is (typep (sgeo.procedural:node-error
                         (sgeo.procedural:procedural-graph restored) :mesh)
                        'error))))
      (when old-definition
        (setf (gethash "procedural-test-box" sgeo.procedural::*generator-definitions*)
              old-definition)))))

(test procedural-scene-persistence-preserves-frozen-edits-until-graph-change
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (old-definition (sgeo.procedural:find-generator 'procedural-frozen-box))
         (world nil) (data nil) (copy nil))
    (sgeo.procedural:define-geometry-generator procedural-frozen-box ((size 2d0))
      (sgeo.geometry:make-half-edge-box :size size))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-frozen-box nil)
    (let* ((object (sgeo.procedural:make-procedural-object graph :mesh))
           (mesh (sgeo.scene:mesh-object-geometry object))
           (vertex (first (sgeo.geometry:mesh-vertices mesh))))
      (sgeo.geometry:set-vertex-position mesh vertex (sgeo.math:make-vec3 -3d0 -3d0 -3d0))
      (let ((edited-area (sgeo.geometry:mesh-surface-area mesh)))
        (setf world (sgeo.scene:make-world :root object)
              data (sgeo.serialization:scene-data world))
        (unwind-protect
             (progn
               (setf copy (sgeo.serialization:world-from-data data))
               (let* ((restored (sgeo.scene:world-root copy))
                      (restored-mesh (sgeo.scene:mesh-object-geometry restored))
                      (restored-vertex (first (sgeo.geometry:mesh-vertices restored-mesh)))
                      (revision (sgeo.core:object-revision restored-mesh)))
                 (sgeo.scene:update-world copy 0d0)
                 (sgeo.scene:update-world copy 0d0)
                 (is (= edited-area (sgeo.geometry:mesh-surface-area restored-mesh)))
                 (is (= revision (sgeo.core:object-revision restored-mesh)))
                 (is (member restored-vertex (sgeo.geometry:mesh-vertices restored-mesh)
                             :test #'equalp))
                 (sgeo.procedural:set-generator-parameter
                  (sgeo.procedural:procedural-graph restored) :mesh :size 3d0)
                 (sgeo.scene:update-world copy 0d0)
                 (is (= 54d0 (sgeo.geometry:mesh-surface-area restored-mesh)))
                 (is (eq restored-mesh (sgeo.scene:mesh-object-geometry restored)))))
          (when old-definition
            (setf (gethash "procedural-frozen-box" sgeo.procedural::*generator-definitions*)
                  old-definition)))))))

(test procedural-editor-undo-redo-preserves-restored-frozen-baseline
  (let* ((graph (sgeo.procedural:make-dependency-graph))
         (old-definition (sgeo.procedural:find-generator 'procedural-frozen-history-box))
         (copy nil))
    (sgeo.procedural:define-geometry-generator procedural-frozen-history-box ((size 2d0))
      (sgeo.geometry:make-half-edge-box :size size))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-frozen-history-box nil)
    (let* ((object (sgeo.procedural:make-procedural-object graph :mesh))
           (mesh (sgeo.scene:mesh-object-geometry object))
           (vertex (first (sgeo.geometry:mesh-vertices mesh))))
      (sgeo.geometry:set-vertex-position mesh vertex (sgeo.math:make-vec3 -3d0 -3d0 -3d0))
      (let* ((edited-area (sgeo.geometry:mesh-surface-area mesh))
             (data (sgeo.serialization:scene-data (sgeo.scene:make-world :root object))))
        (unwind-protect
             (progn
               (setf copy (sgeo.serialization:world-from-data data))
               (let* ((restored (sgeo.scene:world-root copy))
                      (restored-mesh (sgeo.scene:mesh-object-geometry restored))
                      (editor (sgeo.editor:make-editor :world copy)))
                 (sgeo.editor:edit-procedural-generator-parameter
                  editor :mesh :size 3d0)
                 (is (= 54d0 (sgeo.geometry:mesh-surface-area restored-mesh)))
                 (sgeo.editor:undo-edit editor)
                 (sgeo.scene:update-world copy 0d0)
                 (is (= edited-area (sgeo.geometry:mesh-surface-area restored-mesh)))
                 (is (= 2d0
                        (getf (getf (find "mesh"
                                          (sgeo.procedural:graph-node-data
                                           (sgeo.procedural:procedural-graph restored))
                                          :key (lambda (node) (getf node :name))
                                          :test #'equal)
                                    :parameters)
                              :size)))
                 (sgeo.editor:redo-edit editor)
                 (sgeo.scene:update-world copy 0d0)
                 (is (= 54d0 (sgeo.geometry:mesh-surface-area restored-mesh)))
                 (is (eq restored-mesh (sgeo.scene:mesh-object-geometry restored)))))
          (when old-definition
            (setf (gethash "procedural-frozen-history-box"
                           sgeo.procedural::*generator-definitions*)
                  old-definition)))))))

(test procedural-safe-boolean-values-round-trip-through-scene-file
  (let* ((path (merge-pathnames "sgeo-procedural-safe-values.sgeo"
                                (uiop:temporary-directory)))
         (graph (sgeo.procedural:make-dependency-graph))
         (old-definition (sgeo.procedural:find-generator 'procedural-boolean-box)))
    (sgeo.procedural:add-parameter-node graph :enabled t)
    (sgeo.procedural:define-geometry-generator procedural-boolean-box ((enabled t))
      (sgeo.geometry:make-half-edge-box :size (if enabled 1d0 2d0)))
    (sgeo.procedural:add-generator-node graph :mesh 'procedural-boolean-box nil
                                        :parameters '(:enabled t))
    (unwind-protect
         (progn
           (sgeo.serialization:save-world
            (sgeo.scene:make-world :root (sgeo.procedural:make-procedural-object graph :mesh))
            path)
           (let* ((world (sgeo.serialization:load-world path))
                  (restored (sgeo.scene:world-root world))
                  (records (sgeo.procedural:graph-data
                            (sgeo.procedural:procedural-graph restored))))
             (is (equal '(:sgeo-dependency-graph 1
                          ((:parameter "enabled" t)
                           (:generator "mesh" "procedural-boolean-box" nil (:enabled t))))
                        records))))
      (when (probe-file path) (delete-file path))
      (if old-definition
          (setf (gethash "procedural-boolean-box"
                         sgeo.procedural::*generator-definitions*) old-definition)
          (remhash "procedural-boolean-box"
                   sgeo.procedural::*generator-definitions*)))))

(test procedural-safe-data-rejects-circular-and-complex-values
  (let ((circular (cons nil nil))
        (graph (sgeo.procedural:make-dependency-graph)))
    (setf (car circular) circular)
    (sgeo.procedural:add-parameter-node graph :circular circular)
    (signals sgeo.core:validation-error (sgeo.procedural:graph-data graph)))
  (let ((graph (sgeo.procedural:make-dependency-graph)))
    (sgeo.procedural:add-parameter-node graph :complex #c(1d0 2d0))
    (signals sgeo.core:validation-error (sgeo.procedural:graph-data graph)))
  #+sbcl
  (let ((graph (sgeo.procedural:make-dependency-graph)))
    (sgeo.procedural:add-parameter-node graph :infinite sb-ext:double-float-positive-infinity)
    (signals sgeo.core:validation-error (sgeo.procedural:graph-data graph))))
