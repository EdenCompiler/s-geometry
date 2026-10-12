;;;; Interface pública dos campos escalares e malhas implícitas.
(defpackage #:sgeo.fields
  (:use #:cl)
  (:import-from #:sgeo.core #:sgeo-object #:touch-object #:add-invalidation-observer #:dependencies-of)
  (:import-from #:sgeo.math #:vec3 #:make-vec3 #:vx #:vy #:vz #:v+ #:v- #:v* #:dot #:cross #:vector-length #:normalize #:make-aabb #:aabb-min #:aabb-max #:transform-aabb #:inverse-mat4 #:transform-point)
  (:import-from #:sgeo.geometry #:make-half-edge-mesh #:validate-mesh)
  (:export #:scalar-field #:field-distance #:field-gradient #:field-sample #:field-parameters #:set-field-parameter
           #:sphere-field #:make-sphere-field #:box-field #:make-box-field
           #:torus-field #:make-torus-field #:capsule-field #:make-capsule-field
           #:plane-field #:make-plane-field #:field-bounds
           #:union-field #:make-union-field #:intersection-field #:make-intersection-field #:difference-field #:make-difference-field #:smooth-union-field
           #:field-transform #:make-field-transform #:sample-field-grid #:field->mesh))
(in-package #:sgeo.fields)
