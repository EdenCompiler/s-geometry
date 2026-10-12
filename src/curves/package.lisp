;;;; Curvas e superfícies paramétricas com tesselação para topologia editável.
(defpackage #:sgeo.curves
  (:use #:cl)
  (:import-from #:sgeo.core #:sgeo-object)
  (:import-from #:sgeo.math #:vec2 #:vec3 #:make-vec2 #:make-vec3 #:vx #:vy #:vz #:v+ #:v- #:v* #:dot #:cross #:normalize #:vector-length)
  (:import-from #:sgeo.geometry #:make-half-edge-mesh #:validate-mesh)
  (:export #:curve #:polyline-curve #:make-polyline-curve #:bezier-curve #:make-bezier-curve #:bspline-curve #:make-bspline-curve
           #:curve-point #:curve-derivative #:curve-tangent #:curve-sample #:curve-control-points #:set-curve-control-point
           #:surface #:parametric-surface #:make-parametric-surface #:bezier-surface #:make-bezier-surface
           #:surface-point #:surface-derivatives #:surface-control-grid #:set-surface-control-point #:tessellate-surface
           #:sweep-curve #:lathe-surface))
(in-package #:sgeo.curves)
