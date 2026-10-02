;;;; A suíte headless não carrega bibliotecas de janela ou de GPU.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(handler-case
    (progn
      (asdf:test-system :sgeo)
      (assert (not (find-package :glfw)))
      (assert (not (find-package :gl)))
      (format t "~&Núcleo headless verificado: nenhum pacote GLFW/OpenGL carregado.~%")
      (uiop:quit 0))
  (error (condition)
    (format *error-output* "~&Falha nos testes: ~A~%" condition)
    (uiop:quit 1)))
