(defpackage #:sgeo.geometry
  (:use #:cl)
  (:import-from #:sgeo.core
                #:sgeo-object #:touch-object #:bounds #:compile-render-data
                #:validation-error #:condition-context #:condition-message)
  (:import-from #:sgeo.math
                #:vec3 #:make-vec2 #:make-vec3 #:vx #:vy #:vz #:v+ #:v- #:v* #:dot #:cross
                #:vector-length #:normalize #:make-aabb #:aabb-min #:aabb-max
                #:ray #:ray-origin #:ray-direction #:ray-triangle-intersection)
  (:export
   #:triangle-mesh #:make-triangle-mesh #:make-triangle-mesh-from-data
   #:mesh-positions #:mesh-normals #:mesh-indices #:mesh-bounds
   #:set-mesh-data #:set-mesh-position #:make-box
   #:render-mesh-data #:render-mesh-positions #:render-mesh-normals
   #:render-mesh-indices #:render-mesh-revision #:render-mesh-source-faces #:ray-intersect-mesh
   #:half-edge-mesh #:make-half-edge-mesh #:mesh-handle #:mesh-handle-p
   #:handle-kind #:handle-index #:handle-generation #:handle-mesh-id
   #:geometry-error #:topology-error #:stale-handle-error #:geometry-edit-error
   #:mesh-vertices #:mesh-edges #:mesh-faces #:mesh-half-edges #:mesh-counts
   #:validate-mesh #:vertex-position #:face-vertices #:face-half-edges
   #:edge-vertices #:edge-half-edges #:half-edge-origin #:half-edge-destination
   #:half-edge-next #:half-edge-previous #:half-edge-twin #:half-edge-edge #:half-edge-face
   #:vertex-neighbors #:vertex-edges #:vertex-faces #:face-neighbors
   #:connected-face-region #:boundary-edge-p #:boundary-half-edge-p #:boundary-loops
   #:face-normal #:face-area #:vertex-normal #:mesh-surface-area
   #:triangulate-face #:closest-point-on-mesh #:mesh-ray-intersection
   #:set-vertex-position #:split-edge #:collapse-edge #:extrude-face #:extrude-face-region
   #:make-half-edge-box #:make-sphere #:make-cylinder #:make-grid #:make-torus))
