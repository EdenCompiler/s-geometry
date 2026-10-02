(defpackage #:sgeo.core
  (:use #:cl)
  (:export
   #:sgeo-object
   #:object-id #:object-name #:object-metadata #:object-revision
   #:make-object-id #:touch-object
   #:bounds #:compile-render-data #:update-object
   #:dependencies-of #:invalidate-object
   #:add-invalidation-observer #:remove-invalidation-observer
   #:sgeo-error #:validation-error #:math-error #:hierarchy-error
   #:platform-error #:render-error
   #:condition-context #:condition-message))
