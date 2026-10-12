(sgeo::%extend-public-api :sgeo.input :sgeo.physics :sgeo.audio :sgeo.debug :sgeo.simulation)
;; A extensão opcional preserva operações gráficas que já estavam disponíveis.
(dolist (package-name '("SGEO.RUNTIME" "SGEO.EDITOR"))
  (let ((package (find-package package-name)))
    (when package
      (dolist (name '("RUN" "OPEN-EDITOR" "MAKE-EDITOR" "*EDITOR*" "EXECUTE-EDITOR-COMMAND"))
        (multiple-value-bind (symbol status) (find-symbol name package)
          (when (eq status :external) (import symbol :sgeo) (export symbol :sgeo)))))))
