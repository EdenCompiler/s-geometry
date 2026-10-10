(uiop:define-package #:sgeo
  (:use #:cl #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation)
  (:nicknames #:sg)
  (:reexport #:sgeo.core #:sgeo.math #:sgeo.geometry #:sgeo.scene #:sgeo.animation)
  (:export #:*world* #:*selection*)
  (:documentation "API pública do S-Geometry/CL, utilizável sem inicializar gráficos."))
(in-package #:sgeo)
(defvar *world* nil)
(defvar *selection* nil)
