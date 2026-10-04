(defpackage #:sgeo.render
  (:use #:cl)
  (:export #:renderer #:create-renderer #:render-frame #:destroy-renderer
           #:renderer-frame-count #:renderer-upload-count #:renderer-last-error
           #:renderer-info #:capture-frame #:reload-renderer-shaders #:*graphics-validation*
           #:render-resource #:make-render-resource #:render-resource-name
           #:render-resource-format #:render-resource-transient-p #:render-resource-external-p
           #:render-pass #:make-render-pass #:render-pass-name #:render-pass-reads
           #:render-pass-writes #:render-pass-depends-on
           #:render-graph #:make-render-graph #:compile-render-graph
           #:compiled-graph #:compiled-graph-passes #:compiled-graph-resources
           #:compiled-graph-barriers #:compiled-graph-lifetimes #:execute-render-graph
           #:make-pbr-render-graph
           #:shader-program #:make-shader-program #:request-shader-reload
           #:install-pending-shader #:collect-retired-shaders #:destroy-shader-program
           #:shader-program-active #:shader-program-generation #:shader-program-last-error
           #:shader-program-pending-p #:shader-program-compiled
           #:compile-graphics-program #:standard-shader-sources
           #:pbr-vertex #:pbr-fragment #:shadow-vertex #:tone-vertex #:tone-fragment
           #:modern-scene-snapshot #:pack-frame-uniforms #:interleave-render-mesh
           #:vulkan-projection #:fresnel-schlick))
(in-package #:sgeo.render)

(defclass renderer ()
  ((frame-count :initform 0 :accessor renderer-frame-count)
   (upload-count :initform 0 :accessor renderer-upload-count)
   (last-error :initform nil :accessor renderer-last-error)))

(defgeneric create-renderer (window))
(defgeneric render-frame (renderer world width height))
(defgeneric destroy-renderer (renderer))
(defgeneric renderer-info (renderer))
