;;;; Boids em Lisp; o modo empacotado usa vetores numéricos para o estado do bando.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(load (merge-pathnames "simulation-options.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/simulation/opengl)
(handler-case
    (multiple-value-bind (visible repl frames capture audio packed count)
        (simulation-options (uiop:command-line-arguments))
      (when audio (error "--audio é uma opção do lançador do jogo."))
      (multiple-value-bind (world renderer report)
          (sgeo.examples.simulation:run-boids :visible visible :repl repl :max-frames frames
            :capture-path capture :mode (if packed :packed :objects) :count count)
        (declare (ignore world renderer))
        (when (or (sgeo.runtime:runtime-report-render-error report) (sgeo.runtime:runtime-report-platform-error report))
          (error "Falha no exemplo Boids: ~S" report))
        (format t "Boids: ~D quadros, modo ~A.~%" (sgeo.runtime:runtime-report-frames report) (if packed :packed :objects))))
  (error (condition) (format *error-output* "~&Falha em Boids: ~A~%" condition) (uiop:quit 1)))
