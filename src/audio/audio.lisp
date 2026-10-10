(in-package #:sgeo.audio)

;;;; Buffers, sources e mixer de áudio puro em Lisp. O módulo não abre dispositivo.

(define-condition audio-resource-error (error)
  ((resource :initarg :resource :reader %audio-resource-error-resource)
   (message :initarg :message :reader %audio-resource-error-message))
  (:report (lambda (condition stream)
             (format stream "Recurso de áudio indisponível (~A): ~A"
                     (%audio-resource-error-resource condition)
                     (%audio-resource-error-message condition)))))

(defun %audio-resource-failure (resource message)
  (error 'audio-resource-error :resource resource :message message))

(defun %finite-positive (value context)
  (unless (and (realp value) (> value 0)
               (handler-case (<= value most-positive-double-float) (error () nil)))
    (error "~A precisa ser um número real positivo e finito: ~S" context value))
  (coerce value 'double-float))

(defun %finite-number (value context)
  (unless (and (realp value)
               (handler-case (<= (abs value) most-positive-double-float) (error () nil)))
    (error "~A precisa ser um número real finito: ~S" context value))
  (coerce value 'double-float))

(defun %vec3 (value context)
  (unless (and (typep value 'sequence) (= (length value) 3)
               (every (lambda (component)
                        (and (realp component)
                             (handler-case
                                 (<= (abs component) most-positive-double-float)
                               (error () nil))))
                      value))
    (error "~A precisa ter três componentes reais e finitos." context))
  (make-vec3 (elt value 0) (elt value 1) (elt value 2)))

(defclass audio-buffer ()
  ((samples :initarg :samples :accessor audio-buffer-samples)
   (sample-rate :initarg :sample-rate :reader audio-buffer-sample-rate)
   (channels :initarg :channels :reader audio-buffer-channels)
   (released-p :initform nil :accessor %buffer-released-p)))

(defun make-audio-buffer (&key samples (sample-rate 44100) (channels 1))
  "Copia amostras PCM normalizadas, intercaladas por canal, para um buffer imutável."
  (%finite-positive sample-rate "sample-rate")
  (unless (and (integerp channels) (<= 1 channels 2))
    (error "channels deve ser 1 (mono) ou 2 (estéreo)."))
  (unless (and (typep samples 'sequence) (plusp (length samples))
               (zerop (mod (length samples) channels)))
    (error "samples deve conter quadros PCM não vazios e alinhados aos canais."))
  (make-instance 'audio-buffer
                 :samples (make-array (length samples) :element-type 'double-float
                                      :initial-contents
                                      (map 'list (lambda (sample)
                                                   (%finite-number sample "amostra PCM"))
                                           samples))
                 :sample-rate (round sample-rate) :channels channels))

(defun audio-buffer-frame-count (buffer)
  "Retorna o número de quadros ainda disponíveis no buffer."
  (if (%buffer-released-p buffer) 0
      (floor (length (audio-buffer-samples buffer)) (audio-buffer-channels buffer))))

(defun close-audio-buffer (buffer)
  "Libera as amostras mantidas pelo buffer."
  (setf (audio-buffer-samples buffer) #() (%buffer-released-p buffer) t)
  buffer)

(defun make-tone-buffer (frequency duration &key (sample-rate 44100) (channels 1)
                                              (amplitude 0.25d0) (phase 0d0))
  "Gera um tom senoidal determinístico, com amplitude e fase em radianos."
  (%finite-positive frequency "frequency")
  (%finite-positive duration "duration")
  (let* ((rate (round (%finite-positive sample-rate "sample-rate")))
         (amplitude (%finite-number amplitude "amplitude"))
         (phase (%finite-number phase "phase"))
         (frames (max 1 (round (* rate duration)))))
    (unless (and (integerp channels) (<= 1 channels 2))
      (error "channels deve ser 1 (mono) ou 2 (estéreo)."))
    (make-audio-buffer
     :sample-rate rate :channels channels
     :samples (loop for frame below frames
                    for value = (* amplitude (sin (+ phase (* 2d0 pi frequency (/ frame rate)))))
                    append (make-list channels :initial-element value)))))

(defclass audio-stream ()
  ((sample-rate :initarg :sample-rate :reader %stream-rate)
   (channels :initarg :channels :reader %stream-channels)
   (refill-function :initarg :refill-function :initform nil :reader %stream-refill-function)
   (queue :initform nil :accessor %stream-queue)
   (current :initform nil :accessor %stream-current)
   (cursor :initform 0 :accessor %stream-cursor)
   (refill-count :initform 0 :accessor stream-refill-count)
   (closed-p :initform nil :accessor %stream-closed-p)))

(defun make-audio-stream (&key (sample-rate 44100) (channels 1) refill-function buffers)
  "Cria um fluxo por demanda; REFILL-FUNCTION devolve um buffer ou NIL ao esgotar."
  (%finite-positive sample-rate "sample-rate")
  (unless (and (integerp channels) (<= 1 channels 2))
    (error "channels deve ser 1 (mono) ou 2 (estéreo)."))
  (unless (or (null refill-function) (functionp refill-function))
    (error "refill-function precisa ser uma função ou NIL."))
  (let ((stream (make-instance 'audio-stream :sample-rate (round sample-rate)
                               :channels channels :refill-function refill-function)))
    (dolist (buffer buffers) (stream-queue-buffer stream buffer))
    stream))

(defun stream-queue-buffer (stream buffer)
  "Enfileira um bloco compatível para reprodução posterior."
  (when (%stream-closed-p stream) (error "O fluxo de áudio já foi liberado."))
  (unless (and (typep buffer 'audio-buffer)
               (= (%stream-rate stream) (audio-buffer-sample-rate buffer))
               (= (%stream-channels stream) (audio-buffer-channels buffer)))
    (error "O bloco precisa ter a mesma taxa e quantidade de canais do fluxo."))
  (setf (%stream-queue stream) (nconc (%stream-queue stream) (list buffer)))
  stream)

(defun close-audio-stream (stream)
  "Descarrega a fila e impede novas recargas do fluxo."
  (setf (%stream-closed-p stream) t (%stream-queue stream) nil
        (%stream-current stream) nil)
  stream)

(defun %stream-next-sample (stream channel)
  (loop
    (when (%stream-closed-p stream) (return (values 0d0 nil)))
    (let ((current (%stream-current stream)))
      (when (and current (< (%stream-cursor stream) (audio-buffer-frame-count current)))
        (let ((sample (aref (audio-buffer-samples current)
                            (+ (* (%stream-cursor stream) (%stream-channels stream)) channel))))
          (when (= channel (1- (%stream-channels stream))) (incf (%stream-cursor stream)))
          (return (values sample t)))))
    (setf (%stream-current stream) nil (%stream-cursor stream) 0)
    (if (%stream-queue stream)
        (setf (%stream-current stream) (pop (%stream-queue stream)))
        (let ((refill (%stream-refill-function stream)))
          (unless refill (return (values 0d0 nil)))
          (let ((buffer (funcall refill stream)))
            (unless buffer (return (values 0d0 nil)))
            (incf (stream-refill-count stream))
            (stream-queue-buffer stream buffer)
            (setf (%stream-current stream) (pop (%stream-queue stream))))))))

(defclass audio-source ()
  ((buffer :initarg :buffer :initform nil :accessor audio-source-buffer)
   (stream :initarg :stream :initform nil :accessor audio-source-stream)
   (object :initarg :object :initform nil :accessor audio-source-object)
   (position :initarg :position :initform (make-vec3) :reader %source-position-offset)
   (bus :initarg :bus :initform nil :accessor %source-bus)
   (gain :initarg :gain :initform 1d0 :reader audio-source-gain)
   (pitch :initarg :pitch :initform 1d0 :reader audio-source-pitch)
   (looping-p :initarg :looping-p :initform nil :accessor audio-source-looping-p)
   (state :initform :stopped :accessor %source-state)
   (cursor :initform 0d0 :accessor %source-cursor)
   (stream-frames-read :initform 0 :accessor %source-stream-frames-read)
   (stream-last-frame :initform nil :accessor %source-stream-last-frame)
   (released-p :initform nil :accessor %source-released-p)))

(defun audio-source-position (source)
  "Devolve uma cópia do deslocamento local para evitar mutação sem validação."
  (copy-seq (%source-position-offset source)))

(defun (setf audio-source-position) (value source)
  (setf (slot-value source 'position) (%vec3 value "position")))

(defun (setf audio-source-gain) (value source)
  (let ((gain (%finite-number value "gain")))
    (when (minusp gain)
      (error "gain precisa ser não negativo."))
    (setf (slot-value source 'gain) gain)))

(defun (setf audio-source-pitch) (value source)
  (setf (slot-value source 'pitch) (%finite-positive value "pitch")))

(defun make-audio-source (&key buffer stream object (position (make-vec3)) bus
                            (gain 1d0) (pitch 1d0) looping-p)
  "Cria uma fonte ligada a buffer ou fluxo, opcionalmente ancorada a um nó da cena."
  (unless (and (or (typep buffer 'audio-buffer) (typep stream 'audio-stream))
               (not (and buffer stream)))
    (error "A fonte precisa receber exatamente um :buffer ou :stream válido."))
  (when (and buffer (%buffer-released-p buffer))
    (%audio-resource-failure "buffer" "não é possível criar uma fonte com buffer liberado"))
  (when (and stream looping-p)
    (error "Fontes de fluxo são forward-only; :looping-p só é válido com :buffer."))
  (make-instance 'audio-source :buffer buffer :stream stream :object object
                 :position (%vec3 position "position") :bus bus
                 :gain (%finite-number gain "gain") :pitch (%finite-positive pitch "pitch")
                 :looping-p (not (null looping-p))))

(defun source-state (source)
  "Devolve :STOPPED, :PLAYING, :PAUSED ou :FINISHED."
  (%source-state source))

(defun play-source (source)
  "Inicia ou retoma uma fonte; buffers finalizados recomeçam do primeiro quadro."
  (when (%source-released-p source) (error "A fonte de áudio já foi liberada."))
  (let ((buffer (audio-source-buffer source))
        (state (%source-state source)))
    (when (and buffer (%buffer-released-p buffer))
      (%audio-resource-failure "buffer" "não é possível reproduzir um buffer liberado"))
    (when (and (audio-source-stream source)
               (member state '(:finished :stopped))
               (plusp (%source-stream-frames-read source)))
      (%audio-resource-failure "stream" "o fluxo já avançou e não pode ser rebobinado"))
    (when (and buffer (eq state :finished))
      (setf (%source-cursor source) 0d0)))
  (setf (%source-state source) :playing)
  source)

(defun pause-source (source)
  "Pausa sem descartar o cursor de reprodução."
  (when (eq (%source-state source) :playing) (setf (%source-state source) :paused))
  source)

(defun stop-source (source)
  "Para a fonte e reposiciona o cursor no primeiro quadro."
  (setf (%source-state source) :stopped (%source-cursor source) 0d0)
  (when (audio-source-buffer source)
    (setf (%source-stream-frames-read source) 0
          (%source-stream-last-frame source) nil))
  source)

(defun close-audio-source (source)
  "Libera a fonte sem fechar o buffer compartilhável."
  (stop-source source)
  (setf (%source-released-p source) t)
  source)

(defclass audio-listener ()
  ((object :initarg :object :initform nil :accessor %listener-object)
   (position :initarg :position :initform (make-vec3) :accessor %listener-position)
   (forward :initarg :forward :initform (make-vec3 0d0 0d0 -1d0) :accessor %listener-forward)
   (up :initarg :up :initform (make-vec3 0d0 1d0 0d0) :accessor %listener-up)))

(defun make-listener (&key object (position (make-vec3))
                           (forward (make-vec3 0d0 0d0 -1d0))
                           (up (make-vec3 0d0 1d0 0d0)))
  "Cria listener orientado por um objeto vivo ou por uma pose independente."
  (when (and object (not (typep object 'sgeo.scene:scene-object)))
    (error "object precisa ser scene-object ou NIL."))
  (make-instance 'audio-listener :object object :position (%vec3 position "position")
                 :forward (normalize (%vec3 forward "forward"))
                 :up (normalize (%vec3 up "up"))))

(defclass audio-bus ()
  ((name :initarg :name :initform "bus" :reader %bus-name)
   (gain :initarg :gain :initform 1d0 :reader audio-bus-gain)
   (effects :initform nil :accessor audio-bus-effects)
   (released-p :initform nil :accessor %bus-released-p)))

(defun (setf audio-bus-gain) (value bus)
  (let ((gain (%finite-number value "bus gain")))
    (when (minusp gain)
      (error "bus gain precisa ser não negativo."))
    (setf (slot-value bus 'gain) gain)))

(defun make-audio-bus (&key (name "bus") (gain 1d0))
  "Cria um barramento de soma, ganho e efeitos DSP em sequência."
  (make-instance 'audio-bus :name name :gain (%finite-number gain "bus gain")))

(defgeneric process-audio-effect (effect samples channels frames sample-rate)
  (:documentation "Processa in-place um bloco PCM estéreo do barramento."))
(defmethod process-audio-effect ((effect t) samples channels frames sample-rate)
  (declare (ignore samples channels frames sample-rate))
  (error "~S não implementa PROCESS-AUDIO-EFFECT." effect))

(defun add-audio-effect (bus effect)
  "Acrescenta efeito ao final da cadeia do barramento."
  (when (%bus-released-p bus) (error "O barramento já foi liberado."))
  (setf (audio-bus-effects bus) (append (audio-bus-effects bus) (list effect)))
  bus)

(defclass audio-mixer ()
  ((sample-rate :initarg :sample-rate :reader mixer-sample-rate)
   (sources :initform nil :accessor %mixer-sources)
   (buses :initform nil :accessor %mixer-buses)
   (master :initarg :master :reader mixer-bus)
   (listener :initarg :listener :reader mixer-listener)
   (closed-p :initform nil :accessor %mixer-closed-p)))

(defun (setf mixer-listener) (value mixer)
  (unless (typep value 'audio-listener)
    (error "listener precisa ser um audio-listener."))
  (setf (slot-value mixer 'listener) value))

(defun make-audio-mixer (&key (sample-rate 44100) listener)
  "Cria mixer offline determinístico sem carregar ou abrir dispositivo de áudio."
  (when (and listener (not (typep listener 'audio-listener)))
    (error "listener precisa ser um audio-listener ou NIL."))
  (let* ((master (make-audio-bus :name "master"))
         (mixer (make-instance 'audio-mixer :sample-rate (round (%finite-positive sample-rate "sample-rate"))
                               :master master :listener (or listener (make-listener)))))
    (setf (%mixer-buses mixer) (list master))
    mixer))

(defun add-audio-bus (mixer bus)
  "Registra um barramento adicional no mixer."
  (when (%mixer-closed-p mixer) (error "O mixer já foi liberado."))
  (unless (typep bus 'audio-bus) (error "Esperava um audio-bus."))
  (pushnew bus (%mixer-buses mixer) :test #'eq)
  bus)

(defun add-audio-source (mixer source)
  "Registra uma fonte; o barramento dela também é registrado se necessário."
  (when (%mixer-closed-p mixer) (error "O mixer já foi liberado."))
  (unless (typep source 'audio-source) (error "Esperava um audio-source."))
  (let ((bus (or (%source-bus source) (mixer-bus mixer))))
    (unless (typep bus 'audio-bus) (error "O barramento da fonte precisa ser audio-bus."))
    (setf (%source-bus source) bus)
    (add-audio-bus mixer bus))
  (pushnew source (%mixer-sources mixer) :test #'eq)
  source)

(defun remove-audio-source (mixer source)
  "Remove a fonte sem alterar seu estado ou liberar seu buffer."
  (setf (%mixer-sources mixer) (delete source (%mixer-sources mixer) :test #'eq))
  source)

(defun %listener-frame (listener)
  (if (%listener-object listener)
      (let* ((matrix (world-transform (%listener-object listener)))
             (position (transform-point matrix (make-vec3)))
             (right (normalize (transform-direction matrix (make-vec3 1d0 0d0 0d0)))))
        (values position right))
      (values (%listener-position listener)
              (normalize (sgeo.math:cross (%listener-forward listener) (%listener-up listener))))))

(defun %source-position (source)
  (if (audio-source-object source)
      (transform-point (world-transform (audio-source-object source)) (audio-source-position source))
      (audio-source-position source)))

(defun %source-spatial-gains (mixer source)
  (multiple-value-bind (listener-position listener-right)
      (%listener-frame (mixer-listener mixer))
    (let* ((delta (v- (%source-position source) listener-position))
           (distance (vector-length delta))
           (pan (if (<= distance 1d-12) 0d0
                    (max -1d0 (min 1d0 (/ (dot (v* delta (/ 1d0 distance)) listener-right))))))
           ;; Atenuação inversa com raio de referência de uma unidade.
           (attenuation (/ 1d0 (max 1d0 distance)))
           (left (if (plusp pan) (- 1d0 pan) 1d0))
           (right (if (minusp pan) (+ 1d0 pan) 1d0)))
      (values (* (audio-source-gain source) attenuation left)
              (* (audio-source-gain source) attenuation right)))))

(defun %source-sample (source channel)
  (if (audio-source-buffer source)
      (let* ((buffer (audio-source-buffer source))
             (channels (audio-buffer-channels buffer))
             (frames (audio-buffer-frame-count buffer))
             (cursor (%source-cursor source)))
        (when (zerop frames) (return-from %source-sample (values 0d0 nil)))
        (when (>= cursor frames)
          (if (audio-source-looping-p source)
              (setf cursor (mod cursor frames) (%source-cursor source) cursor)
              (progn (setf (%source-state source) :finished)
                     (return-from %source-sample (values 0d0 nil)))))
        (let* ((i (floor cursor)) (fraction (- cursor i))
               (next (if (< (1+ i) frames) (1+ i)
                         (if (audio-source-looping-p source) 0 i)))
               (c (if (= channels 1) 0 channel))
               (a (aref (audio-buffer-samples buffer) (+ (* i channels) c)))
               (b (aref (audio-buffer-samples buffer) (+ (* next channels) c))))
          (values (+ a (* fraction (- b a))) t)))
      (let* ((stream (audio-source-stream source))
             (channels (%stream-channels stream))
             (target (floor (%source-cursor source))))
        ;; Fluxos avançam apenas quando o cursor cruza um quadro, então pitch abaixo
        ;; de um repete amostras e pitch acima de um descarta quadros intermediários.
        (loop while (<= (%source-stream-frames-read source) target) do
          (let ((frame (make-array channels :element-type 'double-float))
                (available t))
            (dotimes (c channels)
              (multiple-value-bind (sample sample-p) (%stream-next-sample stream c)
                (setf (aref frame c) sample)
                (unless sample-p (setf available nil))))
            (unless available
              (setf (%source-state source) :finished)
              (return-from %source-sample (values 0d0 nil)))
            (setf (%source-stream-last-frame source) frame)
            (incf (%source-stream-frames-read source))))
        (let ((frame (%source-stream-last-frame source)))
          (values (aref frame (if (= channels 1) 0 channel)) t)))))

(defun %render-source-into (mixer source samples frames)
  (unless (eq (%source-state source) :playing) (return-from %render-source-into nil))
  (when (and (audio-source-buffer source)
             (%buffer-released-p (audio-source-buffer source)))
    (setf (%source-state source) :finished)
    (%audio-resource-failure "buffer" "o buffer foi liberado durante a reprodução"))
  (let* ((buffer (audio-source-buffer source))
         (stream (audio-source-stream source))
         (source-rate (if buffer (audio-buffer-sample-rate buffer) (%stream-rate stream)))
         (source-channels (if buffer (audio-buffer-channels buffer) (%stream-channels stream)))
         (step (* (audio-source-pitch source) (/ source-rate (mixer-sample-rate mixer)))))
    (multiple-value-bind (left-gain right-gain) (%source-spatial-gains mixer source)
      (dotimes (frame frames)
        (when (eq (%source-state source) :playing)
          (let ((cursor (%source-cursor source)))
            (when (and buffer (>= cursor (audio-buffer-frame-count buffer)))
              (if (audio-source-looping-p source)
                  (setf (%source-cursor source) (mod cursor (audio-buffer-frame-count buffer)))
                  (progn (setf (%source-state source) :finished)
                         (return))))
            (if (= source-channels 1)
                (multiple-value-bind (sample available) (%source-sample source 0)
                  (if available
                      (progn (incf (aref samples (* frame 2)) (* sample left-gain))
                             (incf (aref samples (1+ (* frame 2))) (* sample right-gain))
                             (incf (%source-cursor source) step)
                             (when (and buffer (not (audio-source-looping-p source))
                                        (>= (%source-cursor source) (audio-buffer-frame-count buffer)))
                               (setf (%source-state source) :finished)))
                      (setf (%source-state source) :finished)))
                (multiple-value-bind (left left-p) (%source-sample source 0)
                  (multiple-value-bind (right right-p) (%source-sample source 1)
                    (if (and left-p right-p)
                        (progn (incf (aref samples (* frame 2)) (* left left-gain))
                               (incf (aref samples (1+ (* frame 2))) (* right right-gain))
                               (incf (%source-cursor source) step)
                               (when (and buffer (not (audio-source-looping-p source))
                                          (>= (%source-cursor source) (audio-buffer-frame-count buffer)))
                                 (setf (%source-state source) :finished)))
                        (setf (%source-state source) :finished)))))))))))

(defun mixer-render (mixer frames)
  "Renderiza FRAMES quadros estéreo PCM; limita a saída a [-1, 1]."
  (when (%mixer-closed-p mixer) (error "O mixer já foi liberado."))
  (unless (and (integerp frames) (not (minusp frames)))
    (error "frames precisa ser um inteiro não negativo."))
  (let ((buses (make-hash-table :test #'eq))
        (output (make-array (* frames 2) :element-type 'double-float :initial-element 0d0)))
    (dolist (bus (%mixer-buses mixer))
      (setf (gethash bus buses)
            (make-array (* frames 2) :element-type 'double-float :initial-element 0d0)))
    (dolist (source (%mixer-sources mixer))
      (let ((bus (%source-bus source)))
        (when (gethash bus buses)
          (%render-source-into mixer source (gethash bus buses) frames))))
    (dolist (bus (%mixer-buses mixer))
      (let ((block (gethash bus buses)))
        (dolist (effect (audio-bus-effects bus))
          (process-audio-effect effect block 2 frames (mixer-sample-rate mixer)))
        (dotimes (i (length block))
          (incf (aref output i) (* (aref block i) (audio-bus-gain bus))))))
    (dotimes (i (length output) output)
      (setf (aref output i) (max -1d0 (min 1d0 (aref output i)))))))

(defun close-audio-mixer (mixer)
  "Libera as fontes e barramentos registrados sem carregar dispositivo nativo."
  (unless (%mixer-closed-p mixer)
    (dolist (source (%mixer-sources mixer)) (close-audio-source source))
    (dolist (bus (%mixer-buses mixer)) (setf (%bus-released-p bus) t))
    (setf (%mixer-sources mixer) nil (%mixer-buses mixer) nil
          (%mixer-closed-p mixer) t))
  mixer)

(defun %write-u16le (stream value)
  (write-byte (logand value #xff) stream)
  (write-byte (logand (ash value -8) #xff) stream))
(defun %write-u32le (stream value)
  (dotimes (shift 4) (write-byte (logand (ash value (* -8 shift)) #xff) stream)))

(defun write-wav (path samples &key (sample-rate 44100) (channels 2))
  "Grava amostras PCM normalizadas como WAV PCM inteiro de 16 bits."
  (unless (and (member channels '(1 2)) (typep samples 'sequence)
               (zerop (mod (length samples) channels)))
    (error "A saída WAV precisa ter amostras alinhadas em mono ou estéreo."))
  (let* ((rate (round (%finite-positive sample-rate "sample-rate")))
         (data-size (* 2 (length samples)))
         (block-align (* channels 2)))
    (with-open-file (out path :direction :output :if-exists :supersede
                              :if-does-not-exist :create :element-type '(unsigned-byte 8))
      (dolist (char '(#\R #\I #\F #\F)) (write-byte (char-code char) out))
      (%write-u32le out (+ 36 data-size))
      (dolist (char '(#\W #\A #\V #\E #\f #\m #\t #\ )) (write-byte (char-code char) out))
      (%write-u32le out 16) (%write-u16le out 1) (%write-u16le out channels)
      (%write-u32le out rate) (%write-u32le out (* rate block-align))
      (%write-u16le out block-align) (%write-u16le out 16)
      (dolist (char '(#\d #\a #\t #\a)) (write-byte (char-code char) out))
      (%write-u32le out data-size)
      (map nil (lambda (sample)
                 (let* ((value (max -1d0 (min 1d0 (%finite-number sample "amostra WAV"))))
                        (pcm (if (minusp value) (round (* value 32768)) (round (* value 32767)))))
                   (%write-u16le out (logand pcm #xffff))))
           samples)))
  path)
