;;;; Executa a aceitação limitada da cena avançada no editor nativo.
(require :asdf)
(let* ((script-directory (uiop:pathname-directory-pathname
                          (or *load-truename* *compile-file-truename*)))
       (project-root (merge-pathnames "../" script-directory)))
  (load (merge-pathnames "tools/bootstrap.lisp" project-root))
  (asdf:load-system :sgeo/examples/advanced)
  (asdf:load-system :sgeo/editor/opengl))

(defvar *m8-editor-checks* 0)
(defun m8-editor-check (condition message)
  (incf *m8-editor-checks*)
  (unless condition
    (format *error-output* "~&M8 assertion failed: ~A~%" message)
    (error "M8 editor acceptance failed: ~A" message)))

(defun m8-mesh-positions (mesh)
  (etypecase mesh
    (sgeo.geometry:half-edge-mesh
     (multiple-value-bind (positions ignored) (sgeo.geometry:mesh-polygon-data mesh)
       (declare (ignore ignored))
       (map 'vector #'copy-seq positions)))
    (sgeo.geometry:triangle-mesh (sgeo.geometry:mesh-positions mesh))))

(defun m8-nudge-mesh (mesh amount)
  (etypecase mesh
    (sgeo.geometry:half-edge-mesh
     (sgeo.geometry:set-vertex-positions
      mesh (mapcar (lambda (vertex)
                     (cons vertex
                           (sg:v+ (sgeo.geometry:vertex-position mesh vertex)
                                  (sg:vec3 0d0 amount 0d0))))
                   (sgeo.geometry:mesh-vertices mesh))))
    (sgeo.geometry:triangle-mesh
     (let ((positions (sgeo.geometry:mesh-positions mesh)))
       (loop for index from 1 below (length positions) by 3
             do (incf (aref positions index) amount))
       (sgeo.geometry:set-mesh-data mesh positions (sgeo.geometry:mesh-indices mesh)))))
  mesh)

(defun m8-publish-regenerated-mesh (target generated)
  (etypecase target
    (sgeo.geometry:half-edge-mesh
     (unless (typep generated 'sgeo.geometry:half-edge-mesh)
       (error "Regenerated output changed the target mesh kind."))
     (sgeo.geometry:replace-half-edge-mesh target generated))
    (sgeo.geometry:triangle-mesh
     (unless (typep generated 'sgeo.geometry:triangle-mesh)
       (error "Regenerated output changed the target mesh kind."))
     (sgeo.geometry:set-mesh-data target
       (sgeo.geometry:mesh-positions generated)
       (sgeo.geometry:mesh-indices generated))))
  target)

(defun m8-generator-inputs (graph name)
  (getf (find name (sgeo.procedural:graph-node-data graph)
              :key (lambda (node) (getf node :name)) :test #'equal)
        :inputs))

(defun m8-click-node-hit (window state predicate label)
  (let* ((hit (find-if (lambda (entry) (funcall predicate (fifth entry)))
                       (sgeo.editor.opengl::editor-ui-hits state))))
    (m8-editor-check hit (format nil "visible Nodes control: ~A" label))
    (funcall (sgeo.backend.opengl::%cursor-handler window)
             (+ (first hit) (/ (third hit) 2d0))
             (+ (second hit) (/ (fourth hit) 2d0)))
    (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :press nil)
    (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :release nil)
    hit))

(defun m8-ui-enter-number (state value)
  (loop repeat (length (sgeo.editor.opengl::editor-ui-field-string state))
        do
    (sgeo.editor.opengl::%key-press state :backspace :press nil))
  (loop for character across value
        do (sgeo.editor.opengl::%insert-codepoint state (char-code character)))
  (sgeo.editor.opengl::%key-press state :enter :press nil))

(defun m8-write-form (path form)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede
                          :if-does-not-exist :create)
    (let ((*print-readably* t) (*print-circle* nil) (*package* (find-package :keyword)))
      (prin1 form stream)
      (terpri stream))))

(defun m8-restore-original-generator ()
  (sgeo.procedural:define-generator
   'advanced-scene-box nil
   (lambda (parameters dependencies)
     (declare (ignore parameters))
     (let ((size (or (gethash "size" dependencies)
                     (gethash "alternate-size" dependencies))))
       (when (> size 1.75d0) (error "Advanced scene box rejects sizes above 1.75."))
       (sg:make-half-edge-box :size size :name "Procedural box result")))))

(let* ((script-directory (uiop:pathname-directory-pathname *load-truename*))
       (project-root (merge-pathnames "../" script-directory))
       (artifacts (merge-pathnames "artifacts/" project-root))
       (scene-path (merge-pathnames "m8-advanced-scene.sgeo" artifacts))
       (expected-path (merge-pathnames "m8-advanced-scene.expected.lisp" artifacts))
       (capture-path (merge-pathnames "m8-advanced-scene.ppm" artifacts)))
  (ensure-directories-exist scene-path)
  (multiple-value-bind (world scene-state) (sgeo.examples:make-advanced-world)
    (let* ((gpu-mesh (getf scene-state :gpu-geometry))
           (gpu-object (getf scene-state :gpu-object))
           (procedural (getf scene-state :procedural))
           (graph (getf scene-state :graph))
           (editor (sgeo.editor:make-editor :world world :scene-path scene-path))
           (gpu-identity gpu-mesh)
           (initial-procedural-geometry (sgeo.scene:mesh-object-geometry procedural))
           (initial-procedural-positions (m8-mesh-positions initial-procedural-geometry))
           (gpu-upload-baseline nil) (gpu-result nil) (edited-positions nil)
           (advanced-mesh-baseline nil) (procedural-manual-positions nil)
           (procedural-manual-revision nil)
           (saved-p nil) (finished-frames nil) (report nil))
      (m8-editor-check (eq gpu-mesh (sgeo.scene:mesh-object-geometry gpu-object))
                       "GPU object and scene-state share one geometry instance")
      (m8-editor-check (eq initial-procedural-geometry (sgeo.scene:mesh-object-geometry procedural))
                       "procedural object starts with its own authoritative mesh")
      (unwind-protect
           (multiple-value-bind (returned runtime-report)
               (sgeo.editor.opengl:run-editor
                editor :width 1440 :height 960 :visible nil :max-frames 15 :repl nil
                :context-version '(4 3)
                :capture-path capture-path
                :frame-hook
                (lambda (active-editor window renderer frame)
                  (let ((state sgeo.editor.opengl::*active-ui-state*))
                    (m8-editor-check (eq editor active-editor) "same editor task across frames")
                    (case frame
                      (0
                       (format t "M8 OpenGL device: version=~A vendor=~A renderer=~A~%"
                               (gl:get-string :version)
                               (gl:get-string :vendor)
                               (gl:get-string :renderer))
                       (sgeo.editor:editor-select editor procedural)
                       (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-tool :nodes)))
                      (1
                       ;; Usa o controle visível e o teclado, sem alterar o grafo por atalho.
                       (m8-click-node-hit window state
                         (lambda (action) (and (eq (first action) :procedural-edit-parameter)
                                               (equal (second action) "size")))
                         "edit source parameter")
                       (m8-ui-enter-number state "1.3d0")
                       (m8-editor-check (= 1.3d0 (sgeo.procedural:node-value graph "size"))
                                        "Nodes workspace edited the size source")
                       (m8-editor-check (eq initial-procedural-geometry
                                            (sgeo.scene:mesh-object-geometry procedural))
                                        "parameter edit preserved the live mesh identity")
                       (m8-editor-check (not (equalp initial-procedural-positions
                                                     (m8-mesh-positions initial-procedural-geometry)))
                                        "parameter edit changed geometry on the same mesh"))
                      (2
                       (m8-click-node-hit window state
                         (lambda (action) (and (eq (first action) :procedural-evaluate)
                                               (eq (second action) procedural)))
                         "evaluate output")
                       (m8-editor-check (equal "mesh"
                                               (sgeo.procedural:procedural-output procedural))
                                        "visible graph output evaluation completed"))
                      (3
                       (let ((before (m8-mesh-positions initial-procedural-geometry))
                             (revision (sgeo.core:object-revision initial-procedural-geometry)))
                         (sgeo.procedural:define-generator
                          'advanced-scene-box nil
                          (lambda (parameters dependencies)
                            (declare (ignore parameters))
                            (let ((size (or (gethash "size" dependencies)
                                            (gethash "alternate-size" dependencies))))
                              (when (> size 1.75d0)
                                (error "Redefined generator rejects sizes above 1.75."))
                              (sg:make-half-edge-box :size (+ size 0.15d0)
                                                     :name "Redefined procedural result"))))
                         (sgeo.procedural:regenerate-procedural-object procedural)
                         (m8-editor-check (eq initial-procedural-geometry
                                              (sgeo.scene:mesh-object-geometry procedural))
                                          "generator redefinition retained the live mesh")
                         (m8-editor-check (> (sgeo.core:object-revision initial-procedural-geometry)
                                             revision)
                                          "generator redefinition published a mesh revision")
                         (m8-editor-check (not (equalp before
                                                      (m8-mesh-positions initial-procedural-geometry)))
                                          "generator redefinition changed visible geometry")))
                      (4
                       (let ((before (m8-mesh-positions initial-procedural-geometry))
                             (revision (sgeo.core:object-revision initial-procedural-geometry)))
                         (sgeo.procedural:set-parameter graph "size" 2d0)
                         (m8-editor-check
                          (handler-case (progn
                                          (sgeo.procedural:regenerate-procedural-object procedural)
                                          nil)
                            (error () t))
                          "invalid redefined generator reports failure")
                         (m8-editor-check (equalp before
                                                 (m8-mesh-positions initial-procedural-geometry))
                                          "failed generator kept authoritative geometry")
                         (m8-editor-check (= revision
                                             (sgeo.core:object-revision initial-procedural-geometry))
                                          "failed generator did not publish a revision")
                         (m8-editor-check (getf (find "mesh" (sgeo.procedural:graph-node-data graph)
                                                      :key (lambda (node) (getf node :name))
                                                      :test #'equal)
                                               :error)
                                          "failed generator state is visible in the graph")))
                      (5
                       (sgeo.procedural:set-parameter graph "size" 1d0)
                       (m8-restore-original-generator)
                       (sgeo.procedural:regenerate-procedural-object procedural)
                       (m8-editor-check (eq initial-procedural-geometry
                                            (sgeo.scene:mesh-object-geometry procedural))
                                        "generator recovery preserved mesh identity")
                       (m8-editor-check (equalp initial-procedural-positions
                                               (m8-mesh-positions initial-procedural-geometry))
                                        "generator recovery restored equivalent source geometry"))
                      (6
                       (setf gpu-upload-baseline (sgeo.render:renderer-upload-count renderer))
                       (setf gpu-result
                             (sgeo.backend.opengl:opengl-process-geometry
                              gpu-mesh :scale #(1d0 1.5d0 1d0)
                              :translation #(0d0 0.25d0 0d0)
                              :amplitude 0.2d0 :frequency 1d0 :phase 0d0))
                       (m8-editor-check (eq gpu-identity
                                            (sgeo.scene:mesh-object-geometry gpu-object))
                                        "GPU commit retained the scene's mesh object")
                       (m8-editor-check (= (sgeo.geometry-processing:processing-result-source-revision gpu-result)
                                           (sgeo.core:object-revision gpu-mesh))
                                        "GPU result is cached for its published mesh revision")
                       (m8-editor-check (equalp (sgeo.geometry-processing:processing-result-normals gpu-result)
                                               (sgeo.backend.opengl:opengl-geometry-result-normals gpu-mesh))
                                        "GPU normal cache is live for the scene mesh"))
                      (7
                       (m8-editor-check (> (sgeo.render:renderer-upload-count renderer)
                                           gpu-upload-baseline)
                                        "GPU-edited scene mesh reached the viewport renderer")
                       (let* ((before (m8-mesh-positions gpu-mesh))
                              (vertex (first (sg:mesh-vertices gpu-mesh)))
                              (updated (sg:v+ (sg:vertex-position gpu-mesh vertex)
                                              (sg:vec3 0.015d0 0d0 0d0))))
                         (sgeo.editor:with-edit-transaction (editor "M8 edit same GPU mesh")
                           (sg:set-vertex-positions gpu-mesh (list (cons vertex updated))))
                         (setf edited-positions (m8-mesh-positions gpu-mesh))
                         (m8-editor-check (not (equalp before edited-positions))
                                          "transaction edited the same GPU mesh")
                         (m8-editor-check (null (sgeo.backend.opengl:opengl-geometry-result-normals gpu-mesh))
                                          "CPU transaction invalidated GPU normal cache")
                         (sgeo.editor:undo-edit editor)
                         (m8-editor-check (equalp before (m8-mesh-positions gpu-mesh))
                                          "undo restored GPU mesh positions")
                         (sgeo.editor:redo-edit editor)
                         (m8-editor-check (equalp edited-positions (m8-mesh-positions gpu-mesh))
                                          "redo restored edited GPU mesh positions")
                         (m8-editor-check (null (sgeo.backend.opengl:opengl-geometry-result-normals gpu-mesh))
                                          "undo and redo leave derived GPU normals stale"))
                       (setf gpu-result
                             (sgeo.backend.opengl:opengl-process-geometry gpu-mesh
                               :scale #(1d0 1d0 1d0) :amplitude 0.03d0))
                       (m8-editor-check (= (sgeo.geometry-processing:processing-result-source-revision gpu-result)
                                           (sgeo.core:object-revision gpu-mesh))
                                        "second GPU pass refreshed the derived cache"))
                      (8
                       (let ((before (m8-mesh-positions initial-procedural-geometry))
                             (revision (sgeo.core:object-revision initial-procedural-geometry)))
                         (m8-click-node-hit window state
                           (lambda (action) (and (eq (first action) :procedural-rewire)
                                                 (equal (second action) "mesh")))
                           "rewire generator input")
                         (m8-editor-check (equal '("alternate-size")
                                                  (m8-generator-inputs graph "mesh"))
                                          "Nodes workspace rewired the generator input")
                         (m8-editor-check (eq initial-procedural-geometry
                                              (sgeo.scene:mesh-object-geometry procedural))
                                          "input rewiring retained the live mesh identity")
                         (m8-editor-check (> (sgeo.core:object-revision initial-procedural-geometry)
                                             revision)
                                          "input rewiring regenerated the live mesh")
                         (m8-editor-check (not (equalp before
                                                      (m8-mesh-positions initial-procedural-geometry)))
                                          "alternate source changed the generated geometry")))
                      (9
                       (m8-click-node-hit window state
                         (lambda (action) (and (eq (first action) :procedural-rewire)
                                               (equal (second action) "mesh")))
                         "rewire generator input back")
                       (m8-editor-check (equal '("size") (m8-generator-inputs graph "mesh"))
                                        "Nodes workspace restored the original generator input")
                       (m8-editor-check (eq initial-procedural-geometry
                                            (sgeo.scene:mesh-object-geometry procedural))
                                        "rewiring back retained the live mesh identity"))
                      (10
                       (setf gpu-upload-baseline (sgeo.render:renderer-upload-count renderer)
                             advanced-mesh-baseline
                             (loop for (key name) in '((:subdivision "Catmull-Clark subdivision")
                                                       (:csg-union "CSG union")
                                                       (:csg-difference "CSG difference")
                                                       (:sdf-mesh "SDF union")
                                                       (:surface "Bezier surface")
                                                       (:sweep "Curve sweep"))
                                   for mesh = (getf scene-state key)
                                   for object = (sgeo.scene:find-object world name)
                                   collect (list object mesh (sgeo.core:object-revision mesh))))
                       (sgeo.fields:set-field-parameter (getf scene-state :sdf-sphere)
                                                        :radius 0.9d0)
                       (m8-nudge-mesh (getf scene-state :subdivision-source) 0.01d0)
                       (m8-publish-regenerated-mesh
                        (getf scene-state :subdivision)
                        (sgeo.advanced:subdivide-mesh (getf scene-state :subdivision-source)
                                                     :levels 1))
                       (m8-nudge-mesh (getf scene-state :csg-right) 0.01d0)
                       (sgeo.advanced:csg-union (getf scene-state :csg-left)
                                                (getf scene-state :csg-right)
                                                :target (getf scene-state :csg-union))
                       (sgeo.advanced:csg-difference (getf scene-state :csg-left)
                                                     (getf scene-state :csg-right)
                                                     :target (getf scene-state :csg-difference))
                       (m8-publish-regenerated-mesh
                        (getf scene-state :sdf-mesh)
                        (sgeo.fields:field->mesh
                         (sgeo.fields:make-union-field (getf scene-state :sdf-sphere)
                                                       (getf scene-state :sdf-box))
                         :bounds (sg:make-aabb (sg:vec3 -1.1d0 -1.1d0 -1.1d0)
                                               (sg:vec3 1.1d0 1.1d0 1.1d0))
                         :resolution 12))
                       (let* ((surface (getf scene-state :surface-definition))
                              (point (aref (sgeo.curves:surface-control-grid surface) 1 1)))
                         (sgeo.curves:set-surface-control-point
                          surface 1 1 (sg:v+ point (sg:vec3 0d0 0.18d0 0d0)))
                         (m8-publish-regenerated-mesh
                          (getf scene-state :surface)
                          (sgeo.curves:tessellate-surface surface :u-segments 8 :v-segments 8)))
                       (let* ((path (getf scene-state :sweep-path))
                              (point (aref (sgeo.curves:curve-control-points path) 1)))
                         (sgeo.curves:set-curve-control-point
                          path 1 (sg:v+ point (sg:vec3 0d0 0d0 0.2d0)))
                         (m8-publish-regenerated-mesh
                          (getf scene-state :sweep)
                          (sgeo.curves:sweep-curve path (getf scene-state :sweep-profile)
                                                   :path-segments 12))))
                      (11
                       (m8-editor-check (> (sgeo.render:renderer-upload-count renderer)
                                           gpu-upload-baseline)
                                        "edited generated meshes uploaded to the renderer")
                       (dolist (entry advanced-mesh-baseline)
                         (destructuring-bind (object mesh revision) entry
                           (m8-editor-check (eq mesh (sgeo.scene:mesh-object-geometry object))
                                            "regeneration preserved each scene mesh identity")
                           (m8-editor-check (> (sgeo.core:object-revision mesh) revision)
                                            "subdivision, CSG, SDF and curve algorithms regenerated live meshes"))))
                      (12
                       (let ((before (m8-mesh-positions initial-procedural-geometry)))
                         (sgeo.editor:with-edit-transaction (editor "Freeze procedural mesh edit")
                           (m8-nudge-mesh initial-procedural-geometry 0.035d0))
                         (m8-editor-check (eq initial-procedural-geometry
                                              (sgeo.scene:mesh-object-geometry procedural))
                                          "manual procedural edit retained mesh identity")
                         (m8-editor-check (not (equalp before
                                                      (m8-mesh-positions initial-procedural-geometry)))
                                          "manual edit changed procedural geometry in place")
                         (setf procedural-manual-positions
                               (m8-mesh-positions initial-procedural-geometry)
                               procedural-manual-revision
                               (sgeo.core:object-revision initial-procedural-geometry))))
                      (13
                       (m8-editor-check
                        (and (= procedural-manual-revision
                                (sgeo.core:object-revision initial-procedural-geometry))
                             (equalp procedural-manual-positions
                                     (m8-mesh-positions initial-procedural-geometry)))
                        "next editor update kept the manually edited procedural mesh")
                       (sgeo.editor:execute-editor-command editor :save :path scene-path)
                       (m8-write-form expected-path (sgeo.serialization:scene-data world))
                       (setf saved-p t))
                      (14
                       (m8-editor-check saved-p "scene save completed")
                       (m8-editor-check (equalp procedural-manual-positions
                                                (m8-mesh-positions initial-procedural-geometry))
                                        "saved procedural mesh retained the manual edit")
                       (m8-editor-check (>= (getf (sgeo.render:renderer-info renderer) :gpu-meshes) 1)
                                        "renderer retained uploaded scene geometry")
                       (setf finished-frames t))))))
             (declare (ignore returned))
             (setf report runtime-report))
        (sgeo.editor:close-editor editor))
      (when report
        (format t "~&M8 runtime: ~D frames, ~D uploads; render=~A; platform=~A~%"
                (sgeo.runtime:runtime-report-frames report)
                (sgeo.runtime:runtime-report-uploads report)
                (sgeo.runtime:runtime-report-render-error report)
                (sgeo.runtime:runtime-report-platform-error report)))
      (m8-editor-check (and report
                            (null (sgeo.runtime:runtime-report-render-error report))
                            (null (sgeo.runtime:runtime-report-platform-error report)))
                       "bounded native editor frames completed without runtime errors")
      (m8-editor-check (= 15 (sgeo.runtime:runtime-report-frames report))
                       "editor stopped at the fifteen-frame bound")
      (m8-editor-check finished-frames "all scripted acceptance frames ran")
      (m8-editor-check (and saved-p (probe-file scene-path) (probe-file expected-path)
                            (probe-file capture-path))
                       "scene, expected data and viewport capture were saved")
      (let ((checker (merge-pathnames "tools/m8-editor-reopen-check.lisp" project-root)))
        (multiple-value-bind (output errors code)
            (uiop:run-program
             (list "sbcl" "--script" (namestring checker)
                   (namestring scene-path) (namestring expected-path))
             :output :string :error-output :string :ignore-error-status t)
          (write-string output)
          (m8-editor-check (zerop code)
                           (format nil "fresh process reopen: ~A" errors))))
      (format t "M8 editor: ~D checks, 15 bounded frames; subdivision, CSG, SDF, curves/surface, Nodes edits/rewiring, generator recovery, GPU same-mesh commit/cache, undo/redo, frozen live geometry, save and fresh-process reopen passed.~%"
              *m8-editor-checks*))))
