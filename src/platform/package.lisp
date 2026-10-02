(defpackage #:sgeo.platform
  (:use #:cl)
  (:export #:platform-window #:make-window #:poll-events #:window-size
           #:framebuffer-size #:window-should-close-p #:request-window-close
           #:swap-buffers #:close-window #:window-title #:set-window-title
           #:set-key-handler #:set-cursor-handler #:set-scroll-handler
           #:set-mouse-button-handler #:set-character-handler #:set-close-handler #:window-time
           #:window-error #:window-visible-p #:window-cursor-position
           #:escape-event-p #:press-event-p #:mouse-button-kind #:wireframe-event-p))
(in-package #:sgeo.platform)

(defclass platform-window ()
  ((title :initarg :title :reader window-title)
   (visible-p :initarg :visible-p :reader window-visible-p)
   (last-error :initform nil :accessor window-error)))

(defgeneric make-window (&key width height title visible))
(defgeneric poll-events (window))
(defgeneric window-size (window))
(defgeneric framebuffer-size (window))
(defgeneric window-should-close-p (window))
(defgeneric request-window-close (window))
(defgeneric swap-buffers (window))
(defgeneric close-window (window))
(defgeneric set-window-title (window title))
(defgeneric set-key-handler (window function))
(defgeneric set-cursor-handler (window function))
(defgeneric set-scroll-handler (window function))
(defgeneric set-mouse-button-handler (window function))
(defgeneric set-close-handler (window function))
(defgeneric set-character-handler (window function))
(defgeneric window-time (window))
(defgeneric window-cursor-position (window))
(defgeneric escape-event-p (key action))
(defgeneric press-event-p (action))
(defgeneric mouse-button-kind (button))
(defgeneric wireframe-event-p (key action))
