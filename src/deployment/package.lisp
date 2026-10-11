(defpackage #:sgeo.deployment
  (:use #:cl)
  (:export #:application #:define-application #:register-application #:find-application
           #:application-name #:application-version #:application-systems
           #:application-entry-point #:application-assets #:application-native-libraries
           #:application-target #:application-debug #:build-application #:package-application
           #:packaging-error #:build-error #:verify-package #:host-target
           #:*application-directory* #:application-resource-path #:write-license-notices))
