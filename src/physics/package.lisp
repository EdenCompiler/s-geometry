(defpackage #:sgeo.physics
  (:use #:cl)
  (:import-from #:sgeo.math
                #:make-vec3 #:vx #:vy #:vz #:v+ #:v- #:v* #:dot #:cross
                #:vector-length #:normalize #:transform-point #:transform-direction
                #:inverse-mat4 #:make-ray #:ray-origin #:ray-direction #:aabb
                #:make-aabb #:aabb-min #:aabb-max #:ray-aabb-intersection)
  (:import-from #:sgeo.scene
                #:scene-object #:world-transform #:set-position #:world->local
                #:scene-object-parent)
  (:export
   #:physics-world #:make-physics-world #:physics-world-gravity
   #:physics-contact-handler
   #:rigid-body #:make-rigid-body #:body-object #:body-shape #:body-motion-type
   #:body-mass #:body-inverse-mass #:body-velocity #:body-angular-velocity
   #:body-position #:body-bounds #:body-restitution #:body-friction
   #:body-sensor-p #:body-trigger-p
   #:sphere-shape #:make-sphere-shape #:sphere-radius
   #:box-shape #:make-box-shape #:box-half-extents
   #:capsule-shape #:make-capsule-shape #:capsule-radius #:capsule-half-height
   #:add-body #:remove-body #:physics-bodies #:step-physics
   #:apply-force #:apply-impulse #:move-body #:sync-body-from-object
   #:physics-contacts #:contact #:contact-body-a #:contact-body-b
   #:contact-normal #:contact-depth #:contact-point #:contact-event
   #:overlap-bodies #:physics-ray-cast #:query-aabb))
