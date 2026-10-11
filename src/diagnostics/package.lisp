(defpackage #:sgeo.diagnostics
  (:use #:cl)
  (:export
   #:profiler #:make-profiler #:profiler-enabled-p
   #:with-profile-scope
   #:begin-frame #:end-frame #:current-frame #:current-profiler
   #:record-diagnostic-error #:record-recovery #:record-gpu-sample
   #:record-pipeline-statistics
   #:profiler-snapshot #:clear-profiler #:profile-report #:write-profile-report
   #:set-profiler-renderer-info
   #:profiler-metrics-available-p #:profiler-timeline-limit))
