(in-package #:sgeo.backend.vulkan)

(defun %format-supports-blit-dst-p (context format)
  (let ((features
          (vk:optimal-tiling-features
           (vk:get-physical-device-format-properties
            (context-physical-device context) format))))
    (and (member :blit-dst features)
         (member :transfer-dst features)
         (member :color-attachment features))))

(defun %swapchain-format (context formats)
  (let* ((undefined-p (and (= (length formats) 1)
                           (eq (vk:format (first formats)) :undefined)))
         (candidates
           (if undefined-p
               (list (vk:make-surface-format-khr
                      :format :b8g8r8a8-unorm
                      :color-space (vk:color-space (first formats)))
                     (vk:make-surface-format-khr
                      :format :r8g8b8a8-unorm
                      :color-space (vk:color-space (first formats))))
               formats))
         (unorm-priority '(:b8g8r8a8-unorm :r8g8b8a8-unorm))
         (srgb-priority '(:b8g8r8a8-srgb :r8g8b8a8-srgb)))
    (or (loop for wanted in unorm-priority
              thereis (find-if (lambda (candidate)
                                 (and (eq (vk:format candidate) wanted)
                                      (eq (vk:color-space candidate) :srgb-nonlinear-khr)
                                      (%format-supports-blit-dst-p context wanted)))
                               candidates))
        (loop for wanted in srgb-priority
              thereis (find-if (lambda (candidate)
                                 (and (eq (vk:format candidate) wanted)
                                      (eq (vk:color-space candidate) :srgb-nonlinear-khr)
                                      (%format-supports-blit-dst-p context wanted)))
                               candidates))
        (error "A superfície não oferece BGRA/RGBA8 UNORM ou sRGB_NONLINEAR com suporte a blit-dst."))))

(defun %swapchain-extent (capabilities width height)
  (let ((current (vk:current-extent capabilities)))
    (if (< (vk:width current) #xffffffff)
        current
        (vk:make-extent-2d
         :width (max (vk:width (vk:min-image-extent capabilities))
                     (min (vk:width (vk:max-image-extent capabilities)) width))
         :height (max (vk:height (vk:min-image-extent capabilities))
                      (min (vk:height (vk:max-image-extent capabilities)) height))))))

(defun %make-swapchain-view (context image format)
  (vk:create-image-view
   (context-device context)
   (vk:make-image-view-create-info
    :image image :view-type :2d :format format
    :components (vk:make-component-mapping :r :identity :g :identity
                                           :b :identity :a :identity)
    :subresource-range
    (vk:make-image-subresource-range :aspect-mask '(:color)
                                     :base-mip-level 0 :level-count 1
                                     :base-array-layer 0 :layer-count 1))))

(defun %destroy-swapchain-state (context)
  (let ((device (context-device context)))
    (dolist (view (context-swapchain-image-views context))
      (ignore-errors (vk:destroy-image-view device view)))
    (when (context-swapchain context)
      (ignore-errors (vk:destroy-swapchain-khr device (context-swapchain context)))))
  (setf (vulkan-context-swapchain context) nil
        (vulkan-context-swapchain-images context) nil
        (vulkan-context-swapchain-image-views context) nil
        (vulkan-context-swapchain-extent context) nil)
  nil)

(defun %presentation-result-status (result)
  (cond ((or (eq result :success) (eql result 0)) :success)
        ((or (eq result :suboptimal-khr)
             (eql result (cffi:foreign-enum-value 'vk:result :suboptimal-khr)))
         :suboptimal)
        ((or (eq result :error-out-of-date-khr)
             (eql result (cffi:foreign-enum-value 'vk:result :error-out-of-date-khr)))
         :out-of-date)
        ((or (eq result :timeout)
             (eql result (cffi:foreign-enum-value 'vk:result :timeout)))
         :timeout)
        ((or (eq result :not-ready)
             (eql result (cffi:foreign-enum-value 'vk:result :not-ready)))
         :not-ready)
        (t result)))

(defun recreate-swapchain (context width height)
  "Cria a swapchain candidata e só publica seus handles após montar as vistas."
  (unless (context-surface context)
    (error "O contexto não tem uma superfície de apresentação."))
  (when (or (zerop width) (zerop height))
    (return-from recreate-swapchain nil))
  (vk:device-wait-idle (context-device context))
  (let* ((vk:*default-extension-loader* (context-extension-loader context))
         (capabilities
           (vk:get-physical-device-surface-capabilities-khr
            (context-physical-device context) (context-surface context)))
         (formats
           (vk:get-physical-device-surface-formats-khr
            (context-physical-device context) (context-surface context)))
         (present-modes
           (vk:get-physical-device-surface-present-modes-khr
            (context-physical-device context) (context-surface context)))
         (old-swapchain (context-swapchain context))
         (old-views (context-swapchain-image-views context))
         (surface-format nil)
         (extent nil)
         (count nil)
         (swapchain nil)
         (images nil)
         (views nil))
    (unless formats
      (error "A superfície não anunciou formatos de imagem."))
    (setf surface-format (%swapchain-format context formats)
          extent (%swapchain-extent capabilities width height)
          count (1+ (vk:min-image-count capabilities)))
    (when (or (zerop (vk:width extent)) (zerop (vk:height extent)))
      (return-from recreate-swapchain nil))
    (when (and (plusp (vk:max-image-count capabilities))
               (> count (vk:max-image-count capabilities)))
      (setf count (vk:max-image-count capabilities)))
    (unless (every (lambda (usage)
                     (member usage (vk:supported-usage-flags capabilities)))
                   '(:color-attachment :transfer-dst))
      (error "A superfície Vulkan não permite os usos color-attachment e transfer-dst."))
    (handler-case
        (progn
          (setf swapchain
                (vk:create-swapchain-khr
                 (context-device context)
                 (vk:make-swapchain-create-info-khr
                  :surface (context-surface context)
                  :min-image-count count
                  :image-format (vk:format surface-format)
                  :image-color-space (vk:color-space surface-format)
                  :image-extent extent :image-array-layers 1
                  :image-usage '(:color-attachment :transfer-dst)
                  :image-sharing-mode :exclusive
                  :pre-transform (vk:current-transform capabilities)
                  :composite-alpha
                  (if (member :opaque (vk:supported-composite-alpha capabilities))
                      :opaque (first (vk:supported-composite-alpha capabilities)))
                  :present-mode (if (member :mailbox-khr present-modes)
                                    :mailbox-khr :fifo-khr)
                  :clipped t :old-swapchain old-swapchain)))
          (setf images (vk:get-swapchain-images-khr (context-device context) swapchain))
          (dolist (image images)
            (push (%make-swapchain-view context image (vk:format surface-format)) views))
          (setf views (nreverse views))
          ;; Uma chamada bem-sucedida aposentou oldSwapchain. Com a candidata
          ;; totalmente pronta, publique-a e então descarte a cadeia antiga.
          (setf (vulkan-context-swapchain context) swapchain
                (vulkan-context-swapchain-images context) images
                (vulkan-context-swapchain-image-views context) views
                (vulkan-context-swapchain-extent context) extent)
          (setf swapchain nil views nil)
          (dolist (view old-views)
            (ignore-errors (vk:destroy-image-view (context-device context) view)))
          (when old-swapchain
            (ignore-errors (vk:destroy-swapchain-khr (context-device context)
                                                     old-swapchain)))
          (values extent (vk:format surface-format)))
      (error (condition)
        (dolist (view views)
          (ignore-errors (vk:destroy-image-view (context-device context) view)))
        (when swapchain
          (ignore-errors (vk:destroy-swapchain-khr (context-device context) swapchain))
          ;; Se a candidata foi criada, a cadeia antiga já não aceita aquisições.
          (when old-swapchain
            (%destroy-swapchain-state context)))
        (error condition)))))

(defun acquire-frame (context &key semaphore fence (timeout #xffffffffffffffff))
  "Retorna índice e estado (:SUCCESS, :SUBOPTIMAL, :OUT-OF-DATE, :TIMEOUT ou :NOT-READY).
É obrigatório fornecer semaphore, fence ou ambos."
  (unless (context-swapchain context)
    (error "A swapchain ainda não foi criada."))
  (unless (or semaphore fence)
    (error "ACQUIRE-FRAME exige semaphore, fence ou ambos."))
  (let ((vk:*default-extension-loader* (context-extension-loader context)))
    (handler-case
        (multiple-value-bind (image-index result)
            (cond ((and semaphore fence)
                   (vk:acquire-next-image-khr (context-device context)
                                              (context-swapchain context) timeout semaphore fence))
                  (semaphore
                   (vk:acquire-next-image-khr (context-device context)
                                              (context-swapchain context) timeout semaphore))
                  (t
                   ;; Preserve a posição opcional do semaphore sem passar NIL
                   ;; explicitamente ao conversor de handles do binding.
                   (vk:acquire-next-image-khr
                    (context-device context) (context-swapchain context) timeout
                    (vk:make-semaphore-wrapper (cffi:null-pointer)) fence)))
          (let ((status (%presentation-result-status result)))
            (values (if (member status '(:success :suboptimal)) image-index nil)
                    status)))
      (vk-error:error-out-of-date-khr () (values nil :out-of-date)))))

(defun present-frame (context image-index &key wait-semaphores)
  "Enfileira a apresentação e retorna :SUCCESS, :SUBOPTIMAL ou :OUT-OF-DATE."
  (let ((vk:*default-extension-loader* (context-extension-loader context)))
    (handler-case
        (let ((result
                (vk:queue-present-khr
                 (context-present-queue context)
                 (vk:make-present-info-khr
                  :wait-semaphores wait-semaphores
                  :swapchains (list (context-swapchain context))
                  :image-indices (list image-index)))))
          (%presentation-result-status result))
      (vk-error:error-out-of-date-khr () :out-of-date))))
