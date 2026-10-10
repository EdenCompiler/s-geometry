(defpackage #:sgeo.input
  (:use #:cl)
  (:export
   #:define-input-map
   #:make-input-state #:input-state-map
   #:bind-action #:unbind-action
   #:push-input-context #:pop-input-context #:active-input-contexts
   #:queue-input-event #:begin-input-frame #:end-input-frame #:clear-input-state
   #:action-down-p #:action-value #:action-pressed-p #:action-released-p
   #:input-cursor-position #:input-scroll-delta))
