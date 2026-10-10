;;;; Abre o editor sobre um personagem glTF com reprodução e linha do tempo.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/animation)
(handler-case
    (progn
      (when (uiop:command-line-arguments)
        (error "Este lançador não aceita opções; use tools/run.lisp --import para importar outro ativo."))
      (multiple-value-bind (editor report) (sgeo.examples.animation:run-animation-editor)
        (declare (ignore editor))
        (let ((failure (or (sgeo.runtime:runtime-report-platform-error report)
                           (sgeo.runtime:runtime-report-render-error report))))
          (when failure (error failure)))))
  (error (condition)
    (format *error-output* "~&Falha no editor de animação: ~A~%" condition)
    (uiop:quit 1)))
