(defpackage #:sgeo.audio.openal
  (:use #:cl)
  (:export #:openal-output-error #:make-openal-output #:submit-audio
           #:pump-audio #:audio-output-info #:close-audio-output))
(in-package #:sgeo.audio.openal)

;;;; Saída OpenAL opcional. A biblioteca só é carregada ao abrir uma saída.

(define-condition openal-output-error (error)
  ((message :initarg :message :reader %openal-error-message))
  (:report (lambda (condition stream)
             (write-string (%openal-error-message condition) stream))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; CFFI precisa conhecer a biblioteca antes da macroexpansão de DEFCFUN.
  (cffi:define-foreign-library %openal-library
    (:unix (:or "libopenal.so.1" "libopenal.so"))
    (:darwin (:framework "OpenAL"))
    (:windows "OpenAL32.dll")
    (t "libopenal.so.1")))

;; As definições CFFI podem existir sem carregar libopenal.so.1. A carga é
;; atrasada até MAKE-OPENAL-OUTPUT para que o restante do engine siga headless.
(cffi:defcfun ("alcOpenDevice" %alc-open-device :library %openal-library)
    :pointer (name :pointer))
(cffi:defcfun ("alcCreateContext" %alc-create-context :library %openal-library)
    :pointer (device :pointer) (attributes :pointer))
(cffi:defcfun ("alcMakeContextCurrent" %alc-make-context-current :library %openal-library)
    :uchar (context :pointer))
(cffi:defcfun ("alcDestroyContext" %alc-destroy-context :library %openal-library)
    :void (context :pointer))
(cffi:defcfun ("alcCloseDevice" %alc-close-device :library %openal-library)
    :uchar (device :pointer))
(cffi:defcfun ("alGenSources" %al-gen-sources :library %openal-library)
    :void (count :int) (sources :pointer))
(cffi:defcfun ("alDeleteSources" %al-delete-sources :library %openal-library)
    :void (count :int) (sources :pointer))
(cffi:defcfun ("alGenBuffers" %al-gen-buffers :library %openal-library)
    :void (count :int) (buffers :pointer))
(cffi:defcfun ("alDeleteBuffers" %al-delete-buffers :library %openal-library)
    :void (count :int) (buffers :pointer))
(cffi:defcfun ("alBufferData" %al-buffer-data :library %openal-library)
    :void (buffer :uint) (format :int) (data :pointer) (size :int) (sample-rate :int))
(cffi:defcfun ("alSourceQueueBuffers" %al-source-queue-buffers :library %openal-library)
    :void (source :uint) (count :int) (buffers :pointer))
(cffi:defcfun ("alSourceUnqueueBuffers" %al-source-unqueue-buffers :library %openal-library)
    :void (source :uint) (count :int) (buffers :pointer))
(cffi:defcfun ("alGetSourcei" %al-get-source-i :library %openal-library)
    :void (source :uint) (parameter :int) (value :pointer))
(cffi:defcfun ("alSourcePlay" %al-source-play :library %openal-library)
    :void (source :uint))
(cffi:defcfun ("alSourceStop" %al-source-stop :library %openal-library)
    :void (source :uint))
(cffi:defcfun ("alGetError" %al-get-error :library %openal-library) :int)

(defconstant +al-format-stereo16+ #x1103)
(defconstant +al-source-state+ #x1010)
(defconstant +al-playing+ #x1012)
(defconstant +al-buffers-queued+ #x1015)
(defconstant +al-buffers-processed+ #x1016)

(defclass openal-output ()
  ((device :initform (cffi:null-pointer) :accessor %output-device)
   (context :initform (cffi:null-pointer) :accessor %output-context)
   (source :initform 0 :accessor %output-source)
   (buffers :initform nil :accessor %output-buffers)
   (free-buffers :initform nil :accessor %output-free-buffers)
   (queued-count :initform 0 :accessor %output-queued-count)
   (sample-rate :initarg :sample-rate :reader %output-sample-rate)
   (queue-limit :initarg :queue-limit :reader %output-queue-limit)
   (dropped-frames :initform 0 :accessor %output-dropped-frames)
   (closed-p :initform nil :accessor %output-closed-p)))

(defun %openal-error (message)
  (error 'openal-output-error :message message))

(defun %ensure-openal-loaded ()
  (handler-case
      (cffi:load-foreign-library '%openal-library)
    (error (condition)
      (%openal-error (format nil "Não foi possível carregar OpenAL: ~A" condition)))))

(defun %require-current (output)
  (when (%output-closed-p output)
    (%openal-error "A saída OpenAL já foi fechada."))
  (unless (= (%alc-make-context-current (%output-context output)) 1)
    (%openal-error "Não foi possível ativar o contexto OpenAL.")))

(defun %check-al (operation)
  (let ((code (%al-get-error)))
    (unless (zerop code)
      (%openal-error (format nil "OpenAL reportou erro ~X durante ~A." code operation)))))

(defun %foreign-uint-array (values)
  (let ((pointer (cffi:foreign-alloc :uint :count (length values))))
    (loop for value in values for index from 0
          do (setf (cffi:mem-aref pointer :uint index) value))
    pointer))

(defun %delete-id-array (function ids)
  (when ids
    (let ((pointer (%foreign-uint-array ids)))
      (unwind-protect (funcall function (length ids) pointer)
        (cffi:foreign-free pointer)))))

(defun %source-integer (source parameter)
  (cffi:with-foreign-object (value :int)
    (%al-get-source-i source parameter value)
    (cffi:mem-ref value :int)))

(defun %destroy-partial-output (output)
  "Desfaz cada recurso criado, inclusive quando a construção falha no meio."
  (let ((context (%output-context output)) (device (%output-device output)))
    (unless (cffi:null-pointer-p context)
      (ignore-errors (%alc-make-context-current context))
      (when (plusp (%output-source output))
        (ignore-errors
          (%al-source-stop (%output-source output))
          (let ((queued (%source-integer (%output-source output) +al-buffers-queued+)))
            (when (plusp queued)
              (cffi:with-foreign-object (ids :uint queued)
                (%al-source-unqueue-buffers (%output-source output) queued ids)))))
        (ignore-errors (%delete-id-array #'%al-delete-sources (list (%output-source output)))))
      (when (%output-buffers output)
        (ignore-errors (%delete-id-array #'%al-delete-buffers
                                         (remove 0 (%output-buffers output)))))
      (ignore-errors (%alc-make-context-current (cffi:null-pointer)))
      (ignore-errors (%alc-destroy-context context)))
    (unless (cffi:null-pointer-p device)
      (ignore-errors (%alc-close-device device)))
    (setf (%output-device output) (cffi:null-pointer)
          (%output-context output) (cffi:null-pointer)
          (%output-source output) 0
          (%output-buffers output) nil
          (%output-free-buffers output) nil
          (%output-queued-count output) 0
          (%output-closed-p output) t))
  output)

(defun make-openal-output (&key (sample-rate 44100) device (queue-limit 8))
  "Abre um dispositivo OpenAL e prepara uma fila limitada de blocos PCM estéreo."
  (unless (and (integerp sample-rate) (plusp sample-rate))
    (%openal-error "sample-rate precisa ser um inteiro positivo."))
  (unless (and (integerp queue-limit) (plusp queue-limit))
    (%openal-error "queue-limit precisa ser um inteiro positivo."))
  (unless (or (null device) (stringp device))
    (%openal-error "device precisa ser nome de dispositivo ou NIL para o padrão."))
  (%ensure-openal-loaded)
  (let ((output (make-instance 'openal-output :sample-rate sample-rate
                               :queue-limit queue-limit))
        (device-name (and device (cffi:foreign-string-alloc device))))
    (unwind-protect
         (handler-case
             (progn
               (setf (%output-device output) (%alc-open-device
                                              (or device-name (cffi:null-pointer))))
               (when (cffi:null-pointer-p (%output-device output))
                 (%openal-error "OpenAL não abriu o dispositivo solicitado."))
               (setf (%output-context output)
                     (%alc-create-context (%output-device output) (cffi:null-pointer)))
               (when (cffi:null-pointer-p (%output-context output))
                 (%openal-error "OpenAL não conseguiu criar o contexto do dispositivo."))
               (%require-current output)
               (cffi:with-foreign-object (source :uint)
                 (%al-gen-sources 1 source)
                 (setf (%output-source output) (cffi:mem-aref source :uint 0)))
               (%check-al "criação da fonte")
               (let ((ids (make-list queue-limit :initial-element 0)))
                 (cffi:with-foreign-object (buffers :uint queue-limit)
                   (%al-gen-buffers queue-limit buffers)
                   (setf ids (loop for index below queue-limit
                                   collect (cffi:mem-aref buffers :uint index))))
                 (setf (%output-buffers output) ids
                       (%output-free-buffers output) (copy-list ids)))
               (%check-al "criação dos buffers")
               output)
           (error (condition)
             (%destroy-partial-output output)
             (if (typep condition 'openal-output-error)
                 (error condition)
                 (%openal-error (format nil "Falha ao preparar saída OpenAL: ~A" condition)))))
      (when device-name (cffi:foreign-string-free device-name)))))

(defun pump-audio (output)
  "Devolve buffers já processados à fila livre e reinicia uma fonte parada."
  (%require-current output)
  (let ((processed (min (%output-queued-count output)
                        (max 0 (%source-integer (%output-source output)
                                                +al-buffers-processed+)))))
    (when (plusp processed)
      (cffi:with-foreign-object (ids :uint processed)
        (%al-source-unqueue-buffers (%output-source output) processed ids)
        (dotimes (index processed)
          (push (cffi:mem-aref ids :uint index) (%output-free-buffers output)))
        (decf (%output-queued-count output) processed)))
    (%check-al "retirada de buffers processados")
    (when (and (plusp (%output-queued-count output))
               (/= (%source-integer (%output-source output) +al-source-state+)
                   +al-playing+))
      (%al-source-play (%output-source output))
      (%check-al "retomada da reprodução")))
  output)

(defun %pcm16 (sample)
  (let* ((value (max -1d0 (min 1d0 (sgeo.audio::%finite-number sample "amostra PCM OpenAL"))))
         (signed (if (minusp value) (round (* value 32768)) (round (* value 32767)))))
    signed))

(defun %prepare-pcm16-block (stereo-samples)
  "Valida e converte uma sequência estéreo sem tocar na saída OpenAL."
  (unless (and (typep stereo-samples 'sequence)
               (zerop (mod (length stereo-samples) 2)))
    (%openal-error "submit-audio espera amostras estéreo intercaladas."))
  (handler-case
      (map 'vector #'%pcm16 stereo-samples)
    (error (condition)
      (if (typep condition 'openal-output-error)
          (error condition)
          (%openal-error (format nil "Bloco PCM inválido: ~A" condition))))))

(defun submit-audio (output stereo-samples)
  "Enfileira amostras estéreo normalizadas; descarta bloco se a fila estiver cheia."
  ;; Converter tudo primeiro: uma amostra inválida não consome buffer livre nem
  ;; avança a fila nativa. MAP aceita vetores, listas e as demais sequências CL.
  (let ((pcm-samples (%prepare-pcm16-block stereo-samples)))
  (%require-current output)
  (pump-audio output)
  (let ((frames (/ (length pcm-samples) 2)))
    (when (plusp frames)
      (if (null (%output-free-buffers output))
          (incf (%output-dropped-frames output) frames)
          (let ((buffer (pop (%output-free-buffers output))))
            (cffi:with-foreign-object (pcm :short (length pcm-samples))
              (loop for sample across pcm-samples for index from 0
                    do (setf (cffi:mem-aref pcm :short index) sample))
              (%al-buffer-data buffer +al-format-stereo16+ pcm
                               (* 2 (length pcm-samples)) (%output-sample-rate output)))
            (%check-al "envio de dados PCM")
            (cffi:with-foreign-object (id :uint)
              (setf (cffi:mem-aref id :uint 0) buffer)
              (%al-source-queue-buffers (%output-source output) 1 id))
            (%check-al "enfileiramento do buffer")
            (incf (%output-queued-count output))
            (when (/= (%source-integer (%output-source output) +al-source-state+)
                      +al-playing+)
              (%al-source-play (%output-source output))
              (%check-al "início da reprodução")))))))
  output)

(defun audio-output-info (output)
  "Retorna estado simples da fila, útil para telemetria e testes headless."
  (list :sample-rate (%output-sample-rate output)
        :queue-limit (%output-queue-limit output)
        :queued-buffers (%output-queued-count output)
        :free-buffers (length (%output-free-buffers output))
        :dropped-frames (%output-dropped-frames output)
        :closed-p (%output-closed-p output)))

(defun close-audio-output (output)
  "Para a fonte, apaga buffers e fecha contexto/dispositivo; operação idempotente."
  (unless (%output-closed-p output)
    (%destroy-partial-output output))
  output)
