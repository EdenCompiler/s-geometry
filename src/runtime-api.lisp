;; A fachada gráfica acrescenta suas operações quando o sistema runtime é carregado.
(uiop:define-package #:sgeo
  (:use #:cl #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation #:sgeo.runtime
        #:sgeo.input #:sgeo.physics #:sgeo.audio #:sgeo.debug #:sgeo.simulation)
  (:nicknames #:sg)
  (:reexport #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation #:sgeo.runtime
             #:sgeo.input #:sgeo.physics #:sgeo.audio #:sgeo.debug #:sgeo.simulation)
  (:export #:run #:*world* #:*selection*))

;; A carga tardia do runtime preserva as exportações opcionais já instaladas.
(dolist (name '("OPEN-EDITOR" "MAKE-EDITOR" "*EDITOR*" "EXECUTE-EDITOR-COMMAND"
                "WITH-EDIT-TRANSACTION" "UNDO-EDIT" "REDO-EDIT" "EDITOR-SELECT"
                "SUBMIT-LISTENER" "INSPECT-EDITOR" "SAVE-WORLD" "LOAD-WORLD" "SCENE-DATA"))
  (let ((symbol (find-symbol name :sgeo)))
    (when symbol (export symbol :sgeo))))

(in-package #:sgeo)

(defun run (world &rest options)
  "Executa o viewport do mundo informado na thread principal."
  (apply #'sgeo.runtime:run-world world options))
