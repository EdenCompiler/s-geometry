(defpackage #:sgeo.geometry-processing
  (:use #:cl)
  (:export
   #:compute-capabilities #:capabilities-supported-p #:capabilities-backend
   #:capabilities-reason #:capabilities-version #:capabilities-device
   #:geometry-processing-result #:make-geometry-processing-result
   #:processing-result-geometry #:processing-result-source-revision
   #:processing-result-positions #:processing-result-normals
   #:processing-result-operation #:processing-result-backend
   #:geometry-processing-error #:unsupported-compute-error
   #:processing-error-reason
   #:process-geometry #:processor-capabilities))
(in-package #:sgeo.geometry-processing)
