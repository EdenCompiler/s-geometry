(defpackage #:sgeo.serialization
  (:use #:cl)
  (:import-from #:sgeo.core
                #:object-id #:object-name #:object-metadata
                #:validation-error #:condition-context #:condition-message)
  (:import-from #:sgeo.math
                #:make-vec3 #:make-quaternion #:make-transform
                #:transform-position #:transform-rotation #:transform-scale)
  (:import-from #:sgeo.geometry
                #:triangle-mesh #:half-edge-mesh #:make-triangle-mesh-from-data
                #:mesh-positions #:mesh-normals #:mesh-indices
                #:make-half-edge-mesh)
  (:import-from #:sgeo.scene
                #:world #:make-world #:world-root #:world-camera #:world-selection
                #:with-world-lock #:scene-object #:scene-object-parent
                #:scene-object-children #:scene-object-local-transform
                #:scene-object-visible-p #:scene-object-enabled-p
                #:make-scene-object
                #:mesh-object #:make-mesh-object #:mesh-object-geometry
                #:mesh-object-material #:simple-material #:make-material
                #:simple-material-color #:simple-material-wireframe-p
                #:camera #:make-camera #:camera-eye #:camera-target #:camera-up
                #:camera-fov #:camera-near #:camera-far #:camera-projection-mode
                #:camera-orthographic-height #:add-child)
  (:export #:scene-data #:world-from-data #:save-world #:load-world))
