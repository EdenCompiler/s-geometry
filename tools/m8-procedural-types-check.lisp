;;;; Verifica mudanças de tipo em saídas procedurais no editor nativo.
(require :asdf)
(let* ((script-directory (uiop:pathname-directory-pathname
                          (or *load-truename* *compile-file-truename*)))
       (project-root (merge-pathnames "../" script-directory)))
  (load (merge-pathnames "tools/bootstrap.lisp" project-root))
  (asdf:load-system :sgeo/editor/opengl))

(defun m8-type-check (condition message)
  (unless condition
    (error "M8 procedural type check failed: ~A" message)))

(sgeo.procedural:define-generator
 'm8-procedural-type-switch nil
 (lambda (parameters dependencies)
   (declare (ignore parameters))
   (if (gethash "triangle" dependencies)
       (sgeo.geometry:make-box :size 1d0 :name "Triangle result")
       (sgeo.geometry:make-half-edge-box :size 1d0 :name "Half-edge result"))))

(multiple-value-bind (world root) (sg:make-world)
  (declare (ignore root))
  (let* ((root (sgeo.scene:world-root world))
         (graph (sgeo.procedural:make-dependency-graph))
         (object nil))
    (sgeo.procedural:add-parameter-node graph :triangle nil)
    (sgeo.procedural:add-generator-node graph :mesh 'm8-procedural-type-switch '(:triangle))
    (setf object (sgeo.procedural:make-procedural-object
                  graph :mesh :name "M8 procedural type switch"))
    (sg:add-child root object)
    (let* ((object-id (sgeo.core:object-id object))
           (initial-geometry (sgeo.scene:mesh-object-geometry object))
           (initial-revision (sgeo.core:object-revision object))
           (editor (sgeo.editor:make-editor :world world))
           (upload-baseline nil)
           (triangle-geometry nil)
           (triangle-revision nil)
           (return-upload-baseline nil)
           (finished-p nil)
           (report nil))
      (m8-type-check (typep initial-geometry 'sgeo.geometry:half-edge-mesh)
                     "the generator starts with editable half-edge geometry")
      (m8-type-check (eq initial-geometry (sgeo.procedural:evaluate-node graph "mesh"))
                     "the initial graph cache is the published geometry")
      (unwind-protect
           (multiple-value-bind (returned runtime-report)
               (sgeo.editor.opengl:run-editor
                editor :width 960 :height 720 :visible nil :max-frames 7 :repl nil
                :frame-hook
                (lambda (active-editor window renderer frame)
                  (declare (ignore window))
                  (m8-type-check (eq editor active-editor) "the same editor remains active")
                  (m8-type-check (= object-id (sgeo.core:object-id object))
                                 "the procedural scene object ID remains stable")
                  (case frame
                    ((0 1)
                     (m8-type-check (eq initial-geometry
                                        (sgeo.scene:mesh-object-geometry object))
                                    "unchanged frames retain the initial geometry")
                     (m8-type-check (eq initial-geometry
                                        (sgeo.procedural:evaluate-node graph "mesh"))
                                    "unchanged frames retain the graph cache value")
                     (m8-type-check (= initial-revision (sgeo.core:object-revision object))
                                    "unchanged frames do not advance the object revision"))
                    (2
                     (setf upload-baseline (sgeo.render:renderer-upload-count renderer))
                     (sgeo.editor:edit-procedural-parameter editor "triangle" t :object object))
                    (3
                     (setf triangle-geometry (sgeo.scene:mesh-object-geometry object)
                           triangle-revision (sgeo.core:object-revision object))
                     (m8-type-check (typep triangle-geometry 'sgeo.geometry:triangle-mesh)
                                    "the parameter switched the output to a triangle mesh")
                     (m8-type-check (not (eq initial-geometry triangle-geometry))
                                    "cross-type publication installed the new geometry")
                     (m8-type-check (eq triangle-geometry
                                        (sgeo.procedural:evaluate-node graph "mesh"))
                                    "the graph cache now points to the published triangle mesh")
                     (m8-type-check (> triangle-revision initial-revision)
                                    "the triangle publication advanced the object revision")
                     (m8-type-check (> (sgeo.render:renderer-upload-count renderer)
                                       upload-baseline)
                                    "the renderer uploaded the new triangle geometry"))
                    (4
                     (m8-type-check (eq triangle-geometry
                                        (sgeo.scene:mesh-object-geometry object))
                                    "an unchanged frame retains the triangle geometry")
                     (m8-type-check (eq triangle-geometry
                                        (sgeo.procedural:evaluate-node graph "mesh"))
                                    "an unchanged frame retains the triangle cache value")
                     (m8-type-check (= triangle-revision (sgeo.core:object-revision object))
                                    "an unchanged frame does not advance the triangle revision"))
                    (5
                     (setf return-upload-baseline
                           (sgeo.render:renderer-upload-count renderer))
                     (sgeo.editor:edit-procedural-parameter editor "triangle" nil :object object))
                    (6
                     (let ((geometry (sgeo.scene:mesh-object-geometry object)))
                       (m8-type-check (typep geometry 'sgeo.geometry:half-edge-mesh)
                                      "the parameter switched the output back to half-edge geometry")
                       (m8-type-check (not (eq triangle-geometry geometry))
                                      "cross-type publication installed the replacement geometry")
                       (m8-type-check (eq geometry (sgeo.procedural:evaluate-node graph "mesh"))
                                      "the graph cache points to the published half-edge mesh")
                       (m8-type-check (> (sgeo.core:object-revision object) triangle-revision)
                                      "the return publication advanced the object revision")
                       (m8-type-check (> (sgeo.render:renderer-upload-count renderer)
                                         return-upload-baseline)
                                      "the renderer uploaded the replacement half-edge geometry")
                       (setf finished-p t))))))
             (declare (ignore returned))
             (setf report runtime-report))
        (sgeo.editor:close-editor editor))
      (m8-type-check (and report
                          (null (sgeo.runtime:runtime-report-render-error report))
                          (null (sgeo.runtime:runtime-report-platform-error report)))
                     "seven native editor frames completed without errors")
      (m8-type-check (= 7 (sgeo.runtime:runtime-report-frames report))
                     "the editor stopped at the seven-frame bound")
      (m8-type-check finished-p "both geometry type changes were checked")
      (format t "M8 procedural type check passed: half-edge → triangle → half-edge, stable scene object ID, cache, revisions and renderer uploads.~%"))))
