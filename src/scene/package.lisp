(defpackage #:sgeo.scene
  (:use #:cl)
  (:import-from #:sgeo.core
                #:sgeo-object #:object-id #:object-name #:touch-object
                #:update-object #:hierarchy-error #:validation-error)
  (:import-from #:sgeo.math
                #:make-vec3 #:vx #:vy #:vz #:v+ #:v- #:v* #:dot #:cross
                #:vector-length #:normalize #:identity-mat4 #:mat* #:inverse-mat4
                #:transform-point #:transform-direction #:make-transform
                #:transform-matrix #:transform-position #:transform-rotation
                #:transform-scale #:quaternion #:make-quaternion #:ray-origin #:ray-direction
                #:quaternion-from-axis-angle #:quaternion-multiply
                #:quaternion-normalize #:ray #:make-ray)
  (:import-from #:sgeo.geometry
                #:triangle-mesh #:half-edge-mesh #:make-triangle-mesh #:mesh-positions #:mesh-indices
                #:mesh-normals #:render-mesh-data #:compile-render-data
                #:render-mesh-positions #:render-mesh-normals #:render-mesh-indices
                #:render-mesh-revision)
  (:export
   #:world #:make-world #:world-root #:world-camera #:world-selection
   #:world-running-p #:world-lock #:with-world-lock #:scene-object #:make-scene-object
   #:scene-object-parent #:scene-object-children #:scene-object-local-transform
   #:scene-object-visible-p #:scene-object-enabled-p #:scene-object-world
   #:mesh-object #:make-mesh-object #:mesh-object-geometry #:mesh-object-material
   #:simple-material #:make-material #:simple-material-color #:simple-material-wireframe-p
   #:pbr-material #:make-pbr-material #:pbr-material-data #:set-pbr-material
   #:pbr-material-metallic #:pbr-material-roughness #:pbr-material-base-color
   #:pbr-material-emissive #:pbr-material-occlusion
   #:directional-light #:make-directional-light #:directional-light-data #:set-directional-light
   #:set-material-color #:set-material-wireframe #:add-child #:remove-child #:reparent #:add-to-world
   #:remove-from-world #:find-object #:world-transform #:local->world #:world->local
   #:set-position #:translate
   #:set-rotation #:rotate #:set-scale #:scale-object #:camera #:make-camera
   #:camera-eye #:camera-target #:camera-up #:camera-fov #:camera-near #:camera-far
   #:camera-projection-mode #:camera-orthographic-height
   #:view-matrix #:projection-matrix #:set-camera-eye #:set-camera-target #:set-camera-up
   #:set-camera-projection #:set-camera-frame
   #:orbit-camera #:zoom-camera #:pan-camera #:camera-ray #:ray-cast
   #:update-world #:render-snapshot))
