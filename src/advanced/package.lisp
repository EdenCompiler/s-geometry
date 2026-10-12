(defpackage #:sgeo.advanced
  (:use #:cl #:sgeo.math)
  (:import-from #:sgeo.core #:validation-error)
  (:export #:subdivide-mesh #:csg-union #:csg-intersection #:csg-difference
           #:boolean-mesh #:solid-mesh-p))
