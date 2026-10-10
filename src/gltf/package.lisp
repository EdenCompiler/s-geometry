(defpackage #:sgeo.gltf
  (:use #:cl)
  (:import-from #:sgeo.core #:object-name #:object-metadata)
  (:import-from #:sgeo.geometry
                #:make-triangle-mesh #:mesh-positions #:mesh-normals #:mesh-indices)
  (:import-from #:sgeo.scene
                #:world #:make-world #:world-root #:scene-object #:make-scene-object
                #:scene-object-children #:scene-object-parent #:scene-object-local-transform
                #:scene-object-world #:mesh-object #:make-mesh-object #:mesh-object-geometry
                #:mesh-object-material #:make-material #:make-pbr-material #:pbr-material-data
                #:add-child #:remove-child #:add-to-world #:make-camera #:camera
                #:set-position #:set-rotation #:set-scale)
  (:export
   #:gltf-asset #:gltf-world #:gltf-scenes #:gltf-nodes #:gltf-meshes
   #:gltf-materials #:gltf-textures #:gltf-images #:gltf-skeletons
   #:gltf-clips #:gltf-metadata #:import-gltf #:export-gltf))
(in-package #:sgeo.gltf)
