(defpackage #:sgeo.render
  (:use #:cl)
  (:export #:renderer #:create-renderer #:render-frame #:destroy-renderer
           #:renderer-frame-count #:renderer-upload-count #:renderer-last-error
           #:renderer-info))
(in-package #:sgeo.render)

(defclass renderer ()
  ((frame-count :initform 0 :accessor renderer-frame-count)
   (upload-count :initform 0 :accessor renderer-upload-count)
   (last-error :initform nil :accessor renderer-last-error)))

(defgeneric create-renderer (window))
(defgeneric render-frame (renderer world width height))
(defgeneric destroy-renderer (renderer))
(defgeneric renderer-info (renderer))
