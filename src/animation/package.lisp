(defpackage #:sgeo.animation
  (:use #:cl)
  (:export
   #:property-track #:transform-track #:skeletal-track #:event-track
   #:make-property-track #:make-event-track #:track-target #:track-path
   #:track-keys #:track-interpolation #:track-easings #:set-track-keys #:sample-track
   #:read-track-value #:write-track-value #:animation-property-accessors
   #:animation-clip #:make-animation-clip #:clip-tracks #:clip-duration
   #:animation-state #:ensure-animation-state #:animation-state-clips
   #:animation-state-players #:animation-state-time #:add-animation-clip
   #:animation-player #:player-clip #:player-time #:player-weight #:player-speed
   #:player-looping-p #:player-playing-p #:player-additive-p #:player-mask
   #:play-animation #:stop-animation #:seek-animation #:advance-animation-state
   #:evaluate-animation-state #:animate #:defanimation
   #:skeleton #:make-skeleton #:skeleton-joints #:skeleton-inverse-bind-matrices
   #:skeleton-root #:joint-palette #:solve-ik #:extract-root-motion
   #:morph-target #:make-morph-target #:morph-target-positions #:morph-target-normals
   #:deformable-mesh-object #:make-deformable-mesh-object
   #:mesh-skeleton #:mesh-joint-indices #:mesh-joint-weights
   #:mesh-morph-targets #:mesh-morph-weights #:set-morph-weights
   #:deformed-render-data))
