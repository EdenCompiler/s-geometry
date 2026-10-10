;;;; Validação nativa opcional com o dispositivo null do OpenAL Soft.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/audio/openal)
(ql:quickload :fiveam :silent t)
(load (merge-pathnames "tests/package.lisp" *project-root*))
(load (merge-pathnames "tests/audio-backend.lisp" *project-root*))
(unless (sgeo.tests:run-tests) (error "Validação OpenAL falhou."))
