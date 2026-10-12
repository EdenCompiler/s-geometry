(uiop:define-package #:sgeo
  (:use #:cl #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation
        #:sgeo.advanced #:sgeo.fields #:sgeo.curves #:sgeo.procedural #:sgeo.geometry-processing)
  (:nicknames #:sg)
  (:reexport #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation
             #:sgeo.advanced #:sgeo.fields #:sgeo.curves #:sgeo.procedural #:sgeo.geometry-processing)
  (:export #:*world* #:*selection*)
  (:documentation "API pública do S-Geometry/CL, utilizável sem inicializar gráficos."))
(in-package #:sgeo)
(defvar *world* nil)
(defvar *selection* nil)

(defun %extend-public-api (&rest packages)
  "Acrescenta exportações opcionais sem remover as interfaces já carregadas."
  (dolist (name packages)
    (do-external-symbols (symbol (find-package name))
      (import symbol :sgeo)
      (export symbol :sgeo))))
