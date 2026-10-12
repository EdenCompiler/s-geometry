;;;; Abre a cena integrada do M8 no editor nativo.
(require :asdf)
(load (merge-pathnames "bootstrap.lisp"
                       (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/advanced)
(asdf:load-system :sgeo/editor/opengl)
(sgeo.editor.opengl:run-editor (sgeo.examples:make-advanced-world)
                                :width 1440 :height 960 :repl t
                                :context-version '(4 3))
