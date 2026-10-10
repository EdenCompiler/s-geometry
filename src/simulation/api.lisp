(uiop:define-package #:sgeo
  (:use #:cl #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation
        #:sgeo.input #:sgeo.physics #:sgeo.audio #:sgeo.debug #:sgeo.simulation)
  (:nicknames #:sg)
  (:reexport #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation
             #:sgeo.input #:sgeo.physics #:sgeo.audio #:sgeo.debug #:sgeo.simulation)
  (:export #:*world* #:*selection*))
;; A extensão opcional preserva operações gráficas que já estavam disponíveis.
(dolist (package-name '("SGEO.RUNTIME" "SGEO.EDITOR"))
  (let ((package (find-package package-name)))
    (when package
      (dolist (name '("RUN" "OPEN-EDITOR" "MAKE-EDITOR" "*EDITOR*" "EXECUTE-EDITOR-COMMAND"))
        (multiple-value-bind (symbol status) (find-symbol name package)
          (when (eq status :external) (import symbol :sgeo) (export symbol :sgeo)))))))
