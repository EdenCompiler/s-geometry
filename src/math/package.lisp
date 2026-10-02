(defpackage #:sgeo.math
  (:use #:cl #:sgeo.core)
  (:export
   #:vec2 #:vec3 #:vec4 #:make-vec2 #:make-vec3 #:make-vec4
   #:vx #:vy #:vz #:vw #:v+ #:v- #:v* #:v+! #:v-! #:v*! #:dot #:cross
   #:vector-length #:normalize
   #:mat4 #:make-mat4 #:identity-mat4 #:translation-mat4 #:scaling-mat4
   #:quaternion #:make-quaternion #:quaternion-from-axis-angle
   #:quaternion-multiply #:quaternion-normalize #:quaternion->mat4
   #:rotation-x-mat4 #:rotation-y-mat4 #:rotation-z-mat4
   #:mat* #:inverse-mat4 #:transform-point #:transform-direction
   #:perspective-mat4 #:orthographic-mat4 #:look-at-mat4
   #:transform #:make-transform #:transform-position #:transform-rotation
   #:transform-scale #:transform-matrix
   #:ray #:make-ray #:ray-origin #:ray-direction
   #:aabb #:make-aabb #:aabb-min #:aabb-max #:aabb-union #:transform-aabb
   #:ray-aabb-intersection #:ray-triangle-intersection))
