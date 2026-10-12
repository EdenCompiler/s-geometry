(defpackage #:sgeo.backend.opengl
  (:use #:cl)
  (:export #:make-glfw-window #:glfw-window #:glfw-native-window
           #:*opengl-context-version*
           #:capture-framebuffer-ppm #:initialize-opengl-backend
           #:check-opengl-error #:with-native-graphics-environment
           #:shutdown-opengl-backend
           #:opengl-compute-capabilities #:opengl-process-geometry
           #:opengl-geometry-result-normals #:clear-opengl-geometry-cache
           #:create-ui-renderer #:destroy-ui-renderer #:begin-ui-frame
           #:ui-rect #:ui-line #:ui-text #:finish-ui-frame #:render-viewport))
(in-package #:sgeo.backend.opengl)
