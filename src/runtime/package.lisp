(defpackage #:sgeo.runtime
  (:use #:cl)
  (:import-from #:sgeo #:*world* #:*selection*)
  (:export #:run-world #:*world* #:*selection* #:*renderer* #:runtime-report
           #:runtime-report-frames #:runtime-report-uploads #:runtime-report-gpu-meshes
           #:runtime-report-render-error #:runtime-report-platform-error))
(in-package #:sgeo.runtime)

(defvar *world* nil)
(defvar *selection* nil)
(defvar *renderer* nil)
(defstruct runtime-report frames uploads gpu-meshes render-error platform-error)
