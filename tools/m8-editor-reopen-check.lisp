;;;; Valida a equivalência da cena serializada em um novo processo Lisp.
(require :asdf)
(let* ((script-directory (uiop:pathname-directory-pathname
                          (or *load-truename* *compile-file-truename*)))
       (project-root (merge-pathnames "../" script-directory)))
  (load (merge-pathnames "tools/bootstrap.lisp" project-root))
  (asdf:load-system :sgeo/examples/advanced)
  (asdf:load-system :sgeo/assets/importers))

(defun m8-reopen-check (condition message)
  (unless condition (error "M8 reopen check failed: ~A" message)))

(let* ((arguments (uiop:command-line-arguments))
       (scene-path (first arguments))
       (expected-path (second arguments)))
  (unless (and scene-path expected-path)
    (error "Usage: m8-editor-reopen-check.lisp SCENE EXPECTED"))
  (let* ((world (sgeo.serialization:load-world scene-path))
         (reopened (sgeo.serialization:scene-data world))
         (expected (with-open-file (stream expected-path :direction :input)
                     (let ((*read-eval* nil)) (read stream nil nil)))))
    ;; IDs de sessão são novos; a comparação canônica preserva conteúdo e referências.
    (m8-reopen-check (equalp (sgeo.assets::%canonical-scene-data expected)
                            (sgeo.assets::%canonical-scene-data reopened))
                     "scene data differs after fresh-process reopen")
    (dolist (name '("Catmull-Clark subdivision" "CSG union" "CSG difference"
                    "SDF union" "Bezier surface" "Curve sweep" "Live GPU mesh"
                    "Procedural live mesh"))
      (let ((object (sgeo.scene:find-object world name)))
        (m8-reopen-check object (format nil "missing scene object ~A" name))
        (m8-reopen-check (typep (sgeo.scene:mesh-object-geometry object)
                                'sgeo.geometry:half-edge-mesh)
                         (format nil "~A did not reopen as editable half-edge geometry" name))))
    (let* ((procedural (sgeo.scene:find-object world "Procedural live mesh"))
           (graph (sgeo.procedural:procedural-graph procedural))
           (geometry (sgeo.scene:mesh-object-geometry procedural))
           (positions (sgeo.geometry:vertex-position
                       geometry (first (sgeo.geometry:mesh-vertices geometry)))))
      (m8-reopen-check (typep procedural 'sgeo.procedural:procedural-object)
                       "procedural scene object type was not restored")
      (m8-reopen-check (equal "mesh" (sgeo.procedural:procedural-output procedural))
                       "procedural output name was not restored")
      (m8-reopen-check (= 3 (length (sgeo.procedural:graph-node-data graph)))
                       "procedural parameter and generator nodes were not restored")
      (sgeo.scene:update-world world 0d0)
      (m8-reopen-check (equalp positions
                               (sgeo.geometry:vertex-position
                                geometry (first (sgeo.geometry:mesh-vertices geometry))))
                       "first restored update replaced the manually edited frozen mesh")
      (m8-reopen-check (equalp reopened (sgeo.serialization:scene-data world))
                       "scene data changed after the first restored world update"))
    (m8-reopen-check (and (not (find-package :glfw)) (not (find-package :gl)))
                     "fresh geometry session loaded graphics packages")
    (format t "M8 reopen: all eight advanced objects and serialized scene data match in a fresh SBCL process.~%")))
