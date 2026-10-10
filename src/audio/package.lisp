(defpackage #:sgeo.audio
  (:use #:cl)
  (:import-from #:sgeo.math
                #:make-vec3 #:vx #:vy #:vz #:v+ #:v- #:v* #:dot #:vector-length
                #:normalize #:transform-point #:transform-direction)
  (:import-from #:sgeo.scene #:world-transform)
  (:export
   #:audio-resource-error
   #:audio-buffer #:make-audio-buffer #:audio-buffer-samples
   #:audio-buffer-sample-rate #:audio-buffer-channels #:audio-buffer-frame-count
   #:make-tone-buffer #:close-audio-buffer
   #:audio-stream #:make-audio-stream #:stream-queue-buffer #:stream-refill-count
   #:close-audio-stream
   #:audio-source #:make-audio-source #:audio-source-buffer #:audio-source-stream
   #:audio-source-object #:audio-source-position #:audio-source-gain #:audio-source-pitch
   #:audio-source-looping-p #:source-state #:play-source #:pause-source #:stop-source
   #:close-audio-source
   #:audio-listener #:make-listener #:mixer-listener
   #:audio-bus #:make-audio-bus #:audio-bus-gain #:audio-bus-effects
   #:add-audio-bus #:add-audio-effect #:process-audio-effect
   #:audio-mixer #:make-audio-mixer #:mixer-sample-rate #:mixer-bus
   #:add-audio-source #:remove-audio-source #:mixer-render #:close-audio-mixer
   #:write-wav))
(in-package #:sgeo.audio)
