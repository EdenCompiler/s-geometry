(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(test openal-pcm16-is-signed-and-accepts-lists-without-a-device
  (is (equalp #(-32768 -16384 0 16384 32767 -32768 32767 0)
              (sgeo.audio.openal::%prepare-pcm16-block
               '(-1d0 -0.5d0 0d0 0.5d0 1d0 -2d0 2d0 0d0))))
  (signals sgeo.audio.openal:openal-output-error
    (sgeo.audio.openal::%prepare-pcm16-block #(0d0 :invalid)))
  (signals sgeo.audio.openal:openal-output-error
    (sgeo.audio.openal::%prepare-pcm16-block #(0d0))))

(test openal-null-output-queues-bounded-pcm-and-releases-resources
  #+sbcl
  (let ((previous-driver (sb-ext:posix-getenv "ALSOFT_DRIVERS"))
        (output nil))
    (unwind-protect
         (progn
           ;; O dispositivo null do OpenAL Soft valida a API sem acessar áudio real.
           (sb-posix:setenv "ALSOFT_DRIVERS" "null" 1)
           (setf output (sgeo.audio.openal:make-openal-output
                         :sample-rate 22050 :queue-limit 2))
           (let ((before (sgeo.audio.openal:audio-output-info output)))
             (signals sgeo.audio.openal:openal-output-error
               (sgeo.audio.openal:submit-audio output #(0d0 :invalid)))
             (is (equal before (sgeo.audio.openal:audio-output-info output))))
           (let ((block (make-array (* 2 220500) :element-type 'double-float
                                    :initial-element -0.01d0)))
             (sgeo.audio.openal:submit-audio output (coerce block 'list))
             (loop repeat 2 do
               (sgeo.audio.openal:submit-audio output block)))
           (let ((info (sgeo.audio.openal:audio-output-info output)))
             (is (= (getf info :queued-buffers) 2))
             (is (zerop (getf info :free-buffers)))
             (is (= (getf info :dropped-frames) 220500)))
           (sgeo.audio.openal:close-audio-output output)
           (sgeo.audio.openal:close-audio-output output)
           (is (getf (sgeo.audio.openal:audio-output-info output) :closed-p)))
      (when output (sgeo.audio.openal:close-audio-output output))
      (if previous-driver
          (sb-posix:setenv "ALSOFT_DRIVERS" previous-driver 1)
          (sb-posix:unsetenv "ALSOFT_DRIVERS"))))
  #-sbcl
  (skip "O teste com o driver OpenAL null usa a API de ambiente do SBCL."))

(test openal-null-device-rejects-missing-device
  #+sbcl
  (let ((previous-driver (sb-ext:posix-getenv "ALSOFT_DRIVERS")))
    (unwind-protect
         (progn
           (sb-posix:setenv "ALSOFT_DRIVERS" "null" 1)
           (signals sgeo.audio.openal:openal-output-error
             (sgeo.audio.openal:make-openal-output
              :device "sgeo-audio-device-that-does-not-exist")))
      (if previous-driver
          (sb-posix:setenv "ALSOFT_DRIVERS" previous-driver 1)
          (sb-posix:unsetenv "ALSOFT_DRIVERS"))))
  #-sbcl
  (skip "O teste com o driver OpenAL null usa a API de ambiente do SBCL."))
