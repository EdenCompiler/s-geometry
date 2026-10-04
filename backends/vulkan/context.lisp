(in-package #:sgeo.backend.vulkan)

(defclass vulkan-window (sgeo.platform:platform-window)
  ((native :initarg :native :reader %vulkan-window-native)
   (closed-p :initform nil :accessor %vulkan-window-closed-p)
   (key-handler :initform nil :accessor %vulkan-key-handler)
   (cursor-handler :initform nil :accessor %vulkan-cursor-handler)
   (scroll-handler :initform nil :accessor %vulkan-scroll-handler)
   (mouse-button-handler :initform nil :accessor %vulkan-mouse-button-handler)
   (character-handler :initform nil :accessor %vulkan-character-handler)
   (close-handler :initform nil :accessor %vulkan-close-handler)))

(defvar *vulkan-glfw-lock* (bt:make-lock "sgeo Vulkan GLFW"))
(defvar *vulkan-glfw-users* 0)
(defvar *vulkan-glfw-initialized-p* nil)
(defvar *vulkan-windows* (make-hash-table :test #'eql))
(defvar *vulkan-validation-buckets* (make-hash-table :test #'eql))
(defvar *vulkan-validation-lock* (bt:make-lock "sgeo Vulkan validation"))

(cffi:defcallback %vulkan-validation-callback :uint32
    ((severity :uint32) (message-type :uint32) (callback-data :pointer) (user-data :pointer))
  (declare (ignore severity message-type))
  (let ((message (handler-case
                    (cffi:foreign-slot-value
                     callback-data '(:struct %vk:debug-utils-messenger-callback-data-ext)
                     '%vk::p-message)
                  (error (condition)
                    (format nil "Falha ao ler mensagem de validação Vulkan: ~A" condition))))
        (key (and user-data (cffi:pointer-address user-data))))
    (when message
      (bt:with-lock-held (*vulkan-validation-lock*)
        (let ((bucket (and key (gethash key *vulkan-validation-buckets*))))
          (when bucket (push message (car bucket)))))))
  0)

(defun vulkan-window-native (window) (%vulkan-window-native window))

(defun %window-key (native)
  (cffi:pointer-address native))

(defun %acquire-vulkan-glfw ()
  (bt:with-lock-held (*vulkan-glfw-lock*)
    (unless *vulkan-glfw-initialized-p*
      (glfw:initialize)
      (setf *vulkan-glfw-initialized-p* t))
    (incf *vulkan-glfw-users*)))

(defun %dispatch-window-callback (native accessor arguments)
  (let* ((window (bt:with-lock-held (*vulkan-glfw-lock*)
                  (gethash (%window-key native) *vulkan-windows*)))
         (function (and window (funcall accessor window))))
    (when (and window function (not (%vulkan-window-closed-p window)))
      (handler-case (apply function arguments)
        (error (condition)
          (setf (sgeo.platform:window-error window) condition))))))

(glfw:def-key-callback %vulkan-key-callback (native key scancode action mods)
  (%dispatch-window-callback native #'%vulkan-key-handler
                             (list key scancode action mods)))
(glfw:def-cursor-pos-callback %vulkan-cursor-callback (native x y)
  (%dispatch-window-callback native #'%vulkan-cursor-handler (list x y)))
(glfw:def-scroll-callback %vulkan-scroll-callback (native x y)
  (%dispatch-window-callback native #'%vulkan-scroll-handler (list x y)))
(glfw:def-mouse-button-callback %vulkan-mouse-button-callback (native button action mods)
  (%dispatch-window-callback native #'%vulkan-mouse-button-handler
                             (list button action mods)))
(glfw:def-char-callback %vulkan-character-callback (native codepoint)
  (%dispatch-window-callback native #'%vulkan-character-handler (list codepoint)))
(glfw:def-window-close-callback %vulkan-close-callback (native)
  (%dispatch-window-callback native #'%vulkan-close-handler nil))

(defun %register-vulkan-window (window)
  (let ((native (%vulkan-window-native window)))
    (bt:with-lock-held (*vulkan-glfw-lock*)
      (setf (gethash (%window-key native) *vulkan-windows*) window))
    (glfw:set-key-callback '%vulkan-key-callback native)
    (glfw:set-cursor-position-callback '%vulkan-cursor-callback native)
    (glfw:set-scroll-callback '%vulkan-scroll-callback native)
    (glfw:set-mouse-button-callback '%vulkan-mouse-button-callback native)
    (glfw:set-window-close-callback '%vulkan-close-callback native)
    (glfw:set-char-callback '%vulkan-character-callback native))
  window)

(defstruct (vulkan-context (:constructor %make-vulkan-context))
  "Recursos compartilhados pelo dispositivo Vulkan deste backend."
  instance physical-device device queue present-queue queue-family
  present-queue-family command-pool memory-properties window surface
  swapchain swapchain-images swapchain-image-views swapchain-extent extension-loader
  validation-messenger (validation-messages nil) validation-user-data
  (closed-p nil))

(defun context-instance (context) (vulkan-context-instance context))
(defun context-physical-device (context) (vulkan-context-physical-device context))
(defun context-device (context) (vulkan-context-device context))
(defun context-queue (context) (vulkan-context-queue context))
(defun context-present-queue (context) (vulkan-context-present-queue context))
(defun context-queue-family (context) (vulkan-context-queue-family context))
(defun context-present-queue-family (context) (vulkan-context-present-queue-family context))
(defun context-command-pool (context) (vulkan-context-command-pool context))
(defun context-memory-properties (context) (vulkan-context-memory-properties context))
(defun context-window (context) (vulkan-context-window context))
(defun context-surface (context) (vulkan-context-surface context))
(defun context-swapchain (context) (vulkan-context-swapchain context))
(defun context-swapchain-images (context) (vulkan-context-swapchain-images context))
(defun context-swapchain-image-views (context) (vulkan-context-swapchain-image-views context))
(defun context-swapchain-extent (context) (vulkan-context-swapchain-extent context))
(defun context-extension-loader (context) (vulkan-context-extension-loader context))
(defun context-validation-messages (context)
  (bt:with-lock-held (*vulkan-validation-lock*)
    (let ((bucket (vulkan-context-validation-messages context)))
      (nreverse (copy-list (and bucket (car bucket)))))))

(defun make-vulkan-window (&key (width 960) (height 640)
                                (title "S-Geometry") (visible t))
  "Cria uma janela GLFW sem contexto gráfico implícito."
  (%acquire-vulkan-glfw)
  (handler-case
      (progn
        (unless (glfw:vulkan-supported-p)
          (error "GLFW ou o driver não oferece suporte a Vulkan."))
        (let* ((native (glfw:create-window :width width :height height :title title
                                           :visible visible :client-api :no-api))
               (window (make-instance 'vulkan-window :native native :title title
                                      :visible-p visible)))
          (%register-vulkan-window window)
          window))
    (error (condition)
      (%release-vulkan-glfw)
      (error condition))))

(defun %release-vulkan-glfw ()
  (bt:with-lock-held (*vulkan-glfw-lock*)
    (when (plusp *vulkan-glfw-users*)
      (decf *vulkan-glfw-users*))
    (when (and *vulkan-glfw-initialized-p* (zerop *vulkan-glfw-users*))
      (glfw:terminate)
      (setf *vulkan-glfw-initialized-p* nil)
      (clrhash *vulkan-windows*))))

(defun destroy-vulkan-window (window)
  "Fecha a janela e libera a instância GLFW criada por MAKE-VULKAN-WINDOW."
  (when (and window (not (%vulkan-window-closed-p window)))
    (let ((native (%vulkan-window-native window)))
      (bt:with-lock-held (*vulkan-glfw-lock*)
        (remhash (%window-key native) *vulkan-windows*))
      (setf (%vulkan-window-closed-p window) t)
      (glfw:destroy-window native)
      (%release-vulkan-glfw)))
  nil)

(defun %window-native (window)
  (typecase window
    (vulkan-window (vulkan-window-native window))
    (cffi:foreign-pointer window)
    (null nil)
    (t (error "Janela Vulkan precisa ser sgeo.backend.vulkan:vulkan-window ou ponteiro GLFW: ~S" window))))

(defmethod sgeo.platform:create-platform-window ((backend (eql :vulkan))
                                                  &key (width 960) (height 640)
                                                    (title "S-Geometry") (visible t))
  (declare (ignore backend))
  (make-vulkan-window :width width :height height :title title :visible visible))

(defmethod sgeo.platform:poll-events ((window vulkan-window))
  (declare (ignore window))
  (glfw:poll-events))

(defmethod sgeo.platform:window-size ((window vulkan-window))
  (values-list (glfw:get-window-size (vulkan-window-native window))))
(defmethod sgeo.platform:framebuffer-size ((window vulkan-window))
  (values-list (glfw:get-framebuffer-size (vulkan-window-native window))))
(defmethod sgeo.platform:window-should-close-p ((window vulkan-window))
  (glfw:window-should-close-p (vulkan-window-native window)))
(defmethod sgeo.platform:request-window-close ((window vulkan-window))
  (glfw:set-window-should-close (vulkan-window-native window) t)
  window)
(defmethod sgeo.platform:swap-buffers ((window vulkan-window)) window)
(defmethod sgeo.platform:close-window ((window vulkan-window))
  (destroy-vulkan-window window))
(defmethod sgeo.platform:set-window-title ((window vulkan-window) title)
  (glfw:set-window-title title (vulkan-window-native window)))
(defmethod sgeo.platform:set-key-handler ((window vulkan-window) function)
  (setf (%vulkan-key-handler window) function))
(defmethod sgeo.platform:set-cursor-handler ((window vulkan-window) function)
  (setf (%vulkan-cursor-handler window) function))
(defmethod sgeo.platform:set-scroll-handler ((window vulkan-window) function)
  (setf (%vulkan-scroll-handler window) function))
(defmethod sgeo.platform:set-mouse-button-handler ((window vulkan-window) function)
  (setf (%vulkan-mouse-button-handler window) function))
(defmethod sgeo.platform:set-character-handler ((window vulkan-window) function)
  (setf (%vulkan-character-handler window) function))
(defmethod sgeo.platform:set-close-handler ((window vulkan-window) function)
  (setf (%vulkan-close-handler window) function))
(defmethod sgeo.platform:window-time ((window vulkan-window))
  (declare (ignore window)) (glfw:get-time))
(defmethod sgeo.platform:window-cursor-position ((window vulkan-window))
  (values-list (glfw:get-cursor-position (vulkan-window-native window))))
(defmethod sgeo.platform:escape-event-p (key action)
  (and (eq key :escape) (eq action :press)))
(defmethod sgeo.platform:press-event-p (action) (eq action :press))
(defmethod sgeo.platform:mouse-button-kind (button)
  (case button ((:left :1) :left) ((:3) :middle) ((:right :2) :right)))
(defmethod sgeo.platform:wireframe-event-p (key action)
  (and (eq key :w) (eq action :press)))

(defun %find-queue-family (physical-device window instance)
  (loop for properties in (vk:get-physical-device-queue-family-properties physical-device)
        for index from 0
        when (and (plusp (vk:queue-count properties))
                  (member :graphics (vk:queue-flags properties))
                  (or (null window)
                      (glfw:physical-device-presentation-support-p
                       (vk:raw-handle instance) (vk:raw-handle physical-device) index)))
          return index))

(defun %select-physical-device (instance window)
  (loop for physical-device in (vk:enumerate-physical-devices instance)
        for queue-family = (%find-queue-family physical-device window instance)
        when queue-family
          do (return-from %select-physical-device
               (values physical-device queue-family)))
  (error "Nenhum dispositivo Vulkan tem fila gráfica apta para esta execução."))

(defun create-context (&key window (application-name "S-Geometry")
                            (validation nil))
  "Cria instância, dispositivo, fila gráfica, command pool e, se pedida, superfície GLFW."
  (let* ((native-window (%window-native window))
         (instance nil) (surface nil) (device nil) (command-pool nil)
         (context nil) (validation-messenger nil) (validation-user-data nil)
         (validation-bucket nil))
    (handler-case
        (progn
          (when validation
            (setf validation-user-data (cffi:foreign-alloc :uint8)
                  validation-bucket (list nil))
            (bt:with-lock-held (*vulkan-validation-lock*)
              (setf (gethash (cffi:pointer-address validation-user-data)
                             *vulkan-validation-buckets*) validation-bucket)))
          (setf instance
                (vk:create-instance
                 (vk:make-instance-create-info
                  :next (when validation
                          (vk:make-validation-features-ext
                           :enabled-validation-features '(:synchronization-validation-ext)))
                  :application-info
                  (vk:make-application-info
                   :application-name application-name
                   :engine-name "S-Geometry/CL"
                   :api-version vk:+api-version-1-2+)
                  :enabled-layer-names
                  (if validation
                      (list "VK_LAYER_KHRONOS_validation") nil)
                  :enabled-extension-names
                  (append (when native-window (glfw:get-required-instance-extensions))
                          (when validation (list vk:+ext-debug-utils-extension-name+
                                                 vk:+ext-validation-features-extension-name+))))))
          (let ((extension-loader (vk:make-extension-loader :instance instance)))
            (let ((vk:*default-extension-loader* extension-loader))
              (when validation
                (setf validation-messenger
                      (vk:create-debug-utils-messenger-ext
                       instance
                       (vk:make-debug-utils-messenger-create-info-ext
                        :message-severity '(:warning :error)
                        :message-type '(:general :validation :performance)
                        :pfn-user-callback (cffi:callback %vulkan-validation-callback)
                        :user-data validation-user-data))))
              (when native-window
                (setf surface
                      (vk:make-surface-khr-wrapper
                       (glfw:create-window-surface
                        (vk:raw-handle instance) native-window))))))
          (multiple-value-bind (physical-device queue-family)
              (%select-physical-device instance native-window)
            (let* ((extensions (if surface (list vk:+khr-swapchain-extension-name+) nil))
                   (queue-info (vk:make-device-queue-create-info
                                :queue-family-index queue-family
                                :queue-priorities '(1.0f0)))
                   (device-info (vk:make-device-create-info
                                 :queue-create-infos (list queue-info)
                                 :enabled-extension-names extensions)))
              (setf device (vk:create-device physical-device device-info))
              (setf command-pool
                    (vk:create-command-pool
                     device
                     (vk:make-command-pool-create-info
                      :flags '(:reset-command-buffer)
                      :queue-family-index queue-family)))
              (setf context
                    (%make-vulkan-context
                     :instance instance :physical-device physical-device
                     :device device :queue (vk:get-device-queue device queue-family 0)
                     :present-queue (vk:get-device-queue device queue-family 0)
                     :queue-family queue-family :present-queue-family queue-family
                     :command-pool command-pool
                     :memory-properties
                     (vk:get-physical-device-memory-properties physical-device)
                     :window window :surface surface
                     :validation-messenger validation-messenger
                     :validation-messages validation-bucket
                     :validation-user-data validation-user-data
                     :extension-loader
                     ;; VK antigo trata um ponteiro nulo de GET-DEVICE-PROC-ADDR
                     ;; como resultado válido e não tenta o comando de instância.
                     ;; O loader de instância também resolve comandos do dispositivo.
                     (vk:make-extension-loader :instance instance)))
              context)))
      (error (condition)
        (when command-pool (ignore-errors (vk:destroy-command-pool device command-pool)))
        (when device (ignore-errors (vk:destroy-device device)))
        (when surface
          (let ((vk:*default-extension-loader*
                  (vk:make-extension-loader :instance instance)))
            (ignore-errors (vk:destroy-surface-khr instance surface))))
        (when validation-messenger
          (let ((vk:*default-extension-loader* (vk:make-extension-loader :instance instance)))
            (ignore-errors (vk:destroy-debug-utils-messenger-ext instance validation-messenger))))
        (when validation-user-data
          (bt:with-lock-held (*vulkan-validation-lock*)
            (remhash (cffi:pointer-address validation-user-data) *vulkan-validation-buckets*))
          (ignore-errors (cffi:foreign-free validation-user-data)))
        (when instance (ignore-errors (vk:destroy-instance instance)))
        (error condition)))))

(defun destroy-context (context)
  "Espera a GPU e destrói os objetos do contexto na ordem exigida pela API."
  (unless (vulkan-context-closed-p context)
    (setf (vulkan-context-closed-p context) t)
    (ignore-errors (vk:device-wait-idle (context-device context)))
    (dolist (view (context-swapchain-image-views context))
      (ignore-errors (vk:destroy-image-view (context-device context) view)))
    (let ((vk:*default-extension-loader*
            (vulkan-context-extension-loader context)))
      (when (context-swapchain context)
        (ignore-errors (vk:destroy-swapchain-khr (context-device context)
                                                 (context-swapchain context)))))
    (when (context-command-pool context)
      (ignore-errors (vk:destroy-command-pool (context-device context)
                                               (context-command-pool context))))
    (when (context-device context)
      (ignore-errors (vk:destroy-device (context-device context))))
    (when (context-surface context)
      (let ((vk:*default-extension-loader*
              (vulkan-context-extension-loader context)))
        (ignore-errors (vk:destroy-surface-khr (context-instance context)
                                                (context-surface context)))))
    (when (vulkan-context-validation-messenger context)
      (let ((vk:*default-extension-loader*
              (vk:make-extension-loader :instance (context-instance context))))
        (ignore-errors
          (vk:destroy-debug-utils-messenger-ext
           (context-instance context) (vulkan-context-validation-messenger context)))))
    (when (vulkan-context-validation-user-data context)
      (let ((pointer (vulkan-context-validation-user-data context)))
        (bt:with-lock-held (*vulkan-validation-lock*)
          (remhash (cffi:pointer-address pointer) *vulkan-validation-buckets*))
        (cffi:foreign-free pointer)))
    (when (context-instance context)
      (ignore-errors (vk:destroy-instance (context-instance context))))
    (when (and (context-window context)
               (typep (context-window context) 'vulkan-window))
      (destroy-vulkan-window (context-window context))))
  nil)
