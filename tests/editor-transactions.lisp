(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(test editor-undo-and-redo-keep-world-object-and-parent-identities
  (let* ((root (sg:make-scene-object :name "Raiz"))
         (child (sg:make-scene-object :name "Filho" :position '(1d0 2d0 3d0)))
         (world (sg:make-world :root root))
         (editor (sgeo.editor:make-editor :world world))
         (root-children-before (sg:scene-object-children root)))
    (unwind-protect
         (progn
           (sg:add-child root child)
           (sgeo.editor:execute-editor-command editor :position :object child
                                               :value #(7d0 8d0 9d0))
           (is (eq (sgeo.editor:editor-world editor) world))
           (is (eq (sg:scene-object-parent child) root))
           (is (eq (first (sg:scene-object-children root)) child))
           (sgeo.editor:undo-edit editor)
           (is (eq (sgeo.editor:editor-world editor) world))
           (is (eq (sg:scene-object-parent child) root))
           (is (eq (first (sg:scene-object-children root)) child))
           (is (vector-approximately= (sgeo.math:transform-position
                                       (sg:scene-object-local-transform child))
                                      #(1d0 2d0 3d0)))
           (sgeo.editor:redo-edit editor)
           (is (eq (sgeo.editor:editor-world editor) world))
           (is (eq (sg:scene-object-parent child) root))
           (is (vector-approximately= (sgeo.math:transform-position
                                       (sg:scene-object-local-transform child))
                                      #(7d0 8d0 9d0)))
           (is (null root-children-before)))
      (sgeo.editor:close-editor editor))))

(test editor-undo-resurrects-deleted-object-instance-and-redo-detaches-it
  (let* ((root (sg:make-scene-object :name "Raiz"))
         (child (sg:make-scene-object :name "Descartável"))
         (world (sg:make-world :root root))
         (editor (sgeo.editor:make-editor :world world)))
    (unwind-protect
         (progn
           (sg:add-child root child)
           (sgeo.editor:execute-editor-command editor :delete :object child)
           (is (null (sg:scene-object-parent child)))
           (sgeo.editor:undo-edit editor)
           (is (eq (sgeo.scene:world-root world) root))
           (is (eq (sg:scene-object-parent child) root))
           (is (eq (first (sg:scene-object-children root)) child))
           (is (eq (sg:scene-object-world child) world))
           (sgeo.editor:redo-edit editor)
           (is (null (sg:scene-object-parent child)))
           (is (null (sg:scene-object-world child))))
      (sgeo.editor:close-editor editor))))

(test editor-undo-redo-never-resurrect-old-half-edge-handles
  (let* ((mesh (sg:make-half-edge-box))
         (object (sg:make-mesh-object mesh))
         (world (sg:make-world :root object))
         (editor (sgeo.editor:make-editor :world world))
         (old-vertex (first (sg:mesh-vertices mesh)))
         (old-position (sg:vertex-position mesh old-vertex))
         (edge (first (sg:mesh-edges mesh))))
    (unwind-protect
         (progn
           (sgeo.editor:execute-editor-command editor :split :object object
                                               :index (sg:handle-index edge))
           (let ((split-vertex (first (sgeo.editor:editor-elements editor))))
             (is (sg:mesh-handle-p split-vertex))
             (sgeo.editor:undo-edit editor)
             (signals sg:stale-handle-error (sg:vertex-position mesh old-vertex))
             (let ((undo-vertex (first (sg:mesh-vertices mesh))))
               (is (vector-approximately= (sg:vertex-position mesh undo-vertex)
                                          old-position))
               (sgeo.editor:redo-edit editor)
               (signals sg:stale-handle-error (sg:vertex-position mesh undo-vertex))
               (signals sg:stale-handle-error (sg:vertex-position mesh split-vertex))
               (is (= (getf (sg:mesh-counts mesh) :vertices) 9))))
      (sgeo.editor:close-editor editor)))))

(test editor-failed-transaction-restores-scene-atomically
  (let* ((root (sg:make-scene-object :name "Raiz" :position '(1d0 2d0 3d0)))
         (child (sg:make-scene-object :name "Filho" :position '(4d0 5d0 6d0)))
         (world (sg:make-world :root root))
         (editor (sgeo.editor:make-editor :world world))
         (revision (sg:object-revision child)))
    (sg:add-child root child)
    (setf revision (sg:object-revision child))
    (unwind-protect
         (progn
           (signals simple-error
             (sgeo.editor:call-with-edit-transaction editor "falha intencional"
               (lambda ()
                 (sg:set-position child #(20d0 30d0 40d0))
                 (error "interromper a transação"))))
           (is (eq (sgeo.editor:editor-world editor) world))
           (is (eq (sg:scene-object-parent child) root))
           (is (eq (first (sg:scene-object-children root)) child))
           (is (vector-approximately= (sgeo.math:transform-position
                                       (sg:scene-object-local-transform child))
                                      #(4d0 5d0 6d0)))
           (is (> (sg:object-revision child) revision))
           (is (null (sgeo.editor:editor-undo-stack editor))))
      (sgeo.editor:close-editor editor))))

(test editor-command-replay-reexecutes-captured-object-edit
  (let* ((root (sg:make-scene-object :name "Raiz"))
         (child (sg:make-scene-object :name "Filho"))
         (world (sg:make-world :root root))
         (editor (sgeo.editor:make-editor :world world)))
    (unwind-protect
         (progn
           (sg:add-child root child)
           (sgeo.editor:execute-editor-command editor :position :object child
                                               :value #(7d0 8d0 9d0))
           (let ((command (first (sgeo.editor:editor-undo-stack editor))))
             (sgeo.editor:undo-edit editor)
             (is (vector-approximately= (sgeo.math:transform-position
                                         (sg:scene-object-local-transform child))
                                        #(0d0 0d0 0d0)))
             (sgeo.editor:replay-editor-command editor command)
             (is (vector-approximately= (sgeo.math:transform-position
                                         (sg:scene-object-local-transform child))
                                        #(7d0 8d0 9d0)))))
      (sgeo.editor:close-editor editor))))

(test editor-command-replay-is-stable-for-duplicate-names-and-renames
  (let* ((root (sg:make-scene-object :name "Raiz"))
         (first-child (sg:make-scene-object :name "Mesmo nome"))
         (second-child (sg:make-scene-object :name "Mesmo nome"))
         (world (sg:make-world :root root))
         (editor (sgeo.editor:make-editor :world world)))
    (unwind-protect
         (progn
           (sg:add-child root first-child)
           (sg:add-child root second-child)
           (sgeo.editor:execute-editor-command editor :position :object second-child
                                               :value #(3d0 4d0 5d0))
           (let ((command (first (sgeo.editor:editor-undo-stack editor))))
             (sgeo.editor:undo-edit editor)
             (sgeo.editor:replay-editor-command editor command)
             (is (vector-approximately= (sgeo.math:transform-position
                                         (sg:scene-object-local-transform first-child))
                                        #(0d0 0d0 0d0)))
             (is (vector-approximately= (sgeo.math:transform-position
                                         (sg:scene-object-local-transform second-child))
                                        #(3d0 4d0 5d0))))
           (sgeo.editor:execute-editor-command editor :rename :object second-child :name "Renamed")
           (let ((command (first (sgeo.editor:editor-undo-stack editor))))
             (sgeo.editor:undo-edit editor)
             (is (string= "Mesmo nome" (sg:object-name second-child)))
             (sgeo.editor:replay-editor-command editor command)
             (is (string= "Renamed" (sg:object-name second-child)))))
      (sgeo.editor:close-editor editor))))

(test editor-no-op-failure-does-not-restore-or-invalidate-kernel
  (let* ((mesh (sg:make-half-edge-box))
         (object (sg:make-mesh-object mesh))
         (editor (sgeo.editor:make-editor :world (sg:make-world :root object)))
         (vertex (first (sg:mesh-vertices mesh)))
         (revision (sg:object-revision mesh))
         (position (sg:vertex-position mesh vertex)))
    (unwind-protect
         (progn
           (signals simple-error
             (sgeo.editor:call-with-edit-transaction editor "falha sem alterações"
               (lambda () (error "sem alterações"))))
           (is (= revision (sg:object-revision mesh)))
           (is (vector-approximately= position (sg:vertex-position mesh vertex)))
           (is (null (sgeo.editor:editor-undo-stack editor))))
      (sgeo.editor:close-editor editor))))

(test editor-open-rejection-preserves-world-and-history
  (let* ((root (sg:make-scene-object :name "Raiz"))
         (child (sg:make-scene-object :name "Filho"))
         (world (sg:make-world :root root))
         (editor (sgeo.editor:make-editor :world world))
         (path (merge-pathnames (format nil "sgeo-invalid-open-~D.sgeo" (get-universal-time))
                                (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (sg:add-child root child)
           (sgeo.editor:execute-editor-command editor :position :object child :value #(1d0 2d0 3d0))
           (let ((undo-before (copy-list (sgeo.editor:editor-undo-stack editor))))
             (with-open-file (stream path :direction :output :if-exists :supersede)
               (write-string "(:sgeo-scene :version 999)" stream))
             (signals error (sgeo.editor:execute-editor-command editor :open :path path))
             (is (eq world (sgeo.editor:editor-world editor)))
             (is (equal undo-before (sgeo.editor:editor-undo-stack editor)))
             (is (eq root (sg:scene-object-parent child)))
             (is (vector-approximately= (sgeo.math:transform-position
                                         (sg:scene-object-local-transform child))
                                        #(1d0 2d0 3d0)))))
      (when (probe-file path) (delete-file path))
      (sgeo.editor:close-editor editor))))

(test editor-successful-open-replaces-world-and-clears-transient-state
  (let* ((old-root (sg:make-scene-object :name "Antiga"))
         (old-child (sg:make-scene-object :name "Filho antigo"))
         (world (sg:make-world :root old-root))
         (new-world (sg:make-world :root (sg:make-scene-object :name "Nova")))
         (editor (sgeo.editor:make-editor :world world))
         (path (merge-pathnames (format nil "sgeo-open-~D.sgeo" (get-universal-time))
                                (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (sg:add-child old-root old-child)
           (sgeo.editor:execute-editor-command editor :position :object old-child :value #(1d0 0d0 0d0))
           (sgeo.editor:editor-select editor old-child)
           (sgeo.editor:execute-editor-command editor :selection-mode :mode :vertex)
           (sgeo.serialization:save-world new-world path)
           (sgeo.editor:execute-editor-command editor :open :path path)
           (is (not (eq world (sgeo.editor:editor-world editor))))
           (is (string= "Nova" (sg:object-name (sg:world-root (sgeo.editor:editor-world editor)))))
           (is (null (sgeo.editor:editor-undo-stack editor)))
           (is (null (sgeo.editor:editor-redo-stack editor)))
           (is (null (sgeo.editor:editor-elements editor)))
           (is (eq (sg:world-root (sgeo.editor:editor-world editor))
                   (sgeo.editor:editor-inspected editor)))
           (is (eq :object (sgeo.editor:editor-selection-mode editor))))
      (when (probe-file path) (delete-file path))
      (sgeo.editor:close-editor editor))))

(test editor-undo-keeps-shared-mesh-and-material-references
  (let* ((mesh (sg:make-half-edge-box))
         (material (sg:make-material :color #(0.2d0 0.3d0 0.4d0)))
         (first-object (sg:make-mesh-object mesh :material material :name "Primeiro"))
         (second-object (sg:make-mesh-object mesh :material material :name "Segundo"))
         (world (sg:make-world :root first-object))
         (editor (sgeo.editor:make-editor :world world))
         (edge (first (sg:mesh-edges mesh))))
    (unwind-protect
         (progn
           (sg:add-child first-object second-object)
           (sgeo.editor:execute-editor-command editor :split :object first-object
                                               :index (sg:handle-index edge))
           (is (eq mesh (sg:mesh-object-geometry second-object)))
           (is (= 9 (getf (sg:mesh-counts mesh) :vertices)))
           (sgeo.editor:undo-edit editor)
           (is (eq mesh (sg:mesh-object-geometry first-object)))
           (is (eq mesh (sg:mesh-object-geometry second-object)))
           (is (= 8 (getf (sg:mesh-counts mesh) :vertices)))
           (sgeo.editor:execute-editor-command editor :material :object second-object :color #(0.8d0 0.7d0 0.6d0))
           (is (eq material (sg:mesh-object-material first-object)))
           (is (eq material (sg:mesh-object-material second-object)))
           (sgeo.editor:undo-edit editor)
           (is (eq material (sg:mesh-object-material first-object)))
           (is (eq material (sg:mesh-object-material second-object)))
           (is (vector-approximately= (sg:simple-material-color material) #(0.2d0 0.3d0 0.4d0))))
      (sgeo.editor:close-editor editor))))

(test editor-nested-transactions-form-one-undo-step
  (let* ((object (sg:make-scene-object :name "Nó"))
         (world (sg:make-world :root object))
         (editor (sgeo.editor:make-editor :world world)))
    (unwind-protect
         (progn
           (sgeo.editor:call-with-edit-transaction editor "edição composta"
             (lambda ()
               (sg:set-position object #(2d0 3d0 4d0))
               (sgeo.editor:call-with-edit-transaction editor "transação interna"
                 (lambda () (sg:set-scale object #(3d0 4d0 5d0))))))
           (is (= 1 (length (sgeo.editor:editor-undo-stack editor))))
           (sgeo.editor:undo-edit editor)
           (is (vector-approximately= (sgeo.math:transform-position
                                       (sg:scene-object-local-transform object))
                                      #(0d0 0d0 0d0)))
           (is (vector-approximately= (sgeo.math:transform-scale
                                       (sg:scene-object-local-transform object))
                                      #(1d0 1d0 1d0))))
      (sgeo.editor:close-editor editor))))
