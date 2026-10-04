(in-package #:sgeo.backend.vulkan)

(defstruct (gpu-buffer (:constructor %make-gpu-buffer))
  "Buffer Vulkan e memória alocada a partir das propriedades pedidas."
  context handle memory size allocation-size memory-properties)

(defstruct (gpu-image (:constructor %make-gpu-image))
  "Imagem 2D Vulkan, memória e vista principal."
  context handle memory view width height format aspect)

(defstruct (gpu-sampler (:constructor %make-gpu-sampler))
  "Sampler Vulkan para texturas e mapas de sombra."
  context handle)

(defstruct (gpu-shader-module (:constructor %make-gpu-shader-module))
  "Módulo SPIR-V pronto para uso em pipelines Vulkan."
  context handle)

(defun buffer-handle (buffer) (gpu-buffer-handle buffer))
(defun buffer-memory (buffer) (gpu-buffer-memory buffer))
(defun buffer-size (buffer) (gpu-buffer-size buffer))
(defun image-handle (image) (gpu-image-handle image))
(defun image-memory (image) (gpu-image-memory image))
(defun image-view (image) (gpu-image-view image))
(defun image-width (image) (gpu-image-width image))
(defun image-height (image) (gpu-image-height image))
(defun sampler-handle (sampler) (gpu-sampler-handle sampler))
(defun shader-module-handle (module) (gpu-shader-module-handle module))

(defun %memory-type-selection (context type-bits flags)
  (loop for memory-type in (vk:memory-types (context-memory-properties context))
        for index from 0
        when (and (logbitp index type-bits)
                  (every (lambda (flag)
                           (member flag (vk:property-flags memory-type)))
                         flags))
          return (values index (vk:property-flags memory-type))
        finally (error "Não há tipo de memória Vulkan com as propriedades ~S." flags)))

(defun %memory-type-index (context type-bits flags)
  (nth-value 0 (%memory-type-selection context type-bits flags)))

(defun %allocate-memory (context requirements flags)
  (multiple-value-bind (index properties)
      (%memory-type-selection context (vk:memory-type-bits requirements) flags)
    (values
     (vk:allocate-memory
      (context-device context)
      (vk:make-memory-allocate-info
       :allocation-size (vk:size requirements)
       :memory-type-index index))
     (vk:size requirements)
     properties)))

(defun make-buffer (context size usage memory-properties &key initial-data)
  "Aloca buffer e memória Vulkan; INITIAL-DATA, se presente, é vetor de bytes."
  (unless (and (integerp size) (plusp size))
    (error "Tamanho de buffer precisa ser positivo: ~S" size))
  (let ((device (context-device context))
        (handle nil)
        (memory nil)
        (allocation-size nil)
        (actual-properties nil)
        (resource nil))
    (handler-case
        (progn
          (setf handle
                (vk:create-buffer
                 device (vk:make-buffer-create-info
                         :size size :usage usage :sharing-mode :exclusive)))
          (multiple-value-setq (memory allocation-size actual-properties)
            (%allocate-memory context
                              (vk:get-buffer-memory-requirements device handle)
                              memory-properties))
          (vk:bind-buffer-memory device handle memory 0)
          (setf resource (%make-gpu-buffer :context context :handle handle
                                           :memory memory :size size
                                           :allocation-size allocation-size
                                           :memory-properties actual-properties))
          (when initial-data (write-buffer resource initial-data))
          resource)
      (error (condition)
        ;; O buffer precisa ser destruído antes da memória vinculada.
        (when handle (ignore-errors (vk:destroy-buffer device handle)))
        (when memory (ignore-errors (vk:free-memory device memory)))
        (error condition)))))

(defun %mapped-memory (buffer offset size function &key (operation :read))
  (let* ((context (gpu-buffer-context buffer))
         (device (context-device context))
         (memory (gpu-buffer-memory buffer))
         (properties (gpu-buffer-memory-properties buffer)))
    (unless (member :host-visible properties)
      (error "A memória do buffer não é host-visible."))
    (when (zerop size)
      (return-from %mapped-memory (funcall function (cffi:null-pointer))))
    (cffi:with-foreign-object (mapped-pointer :pointer)
      ;; Mapear a alocação inteira mantém o início alinhado e permite usar
      ;; VK_WHOLE_SIZE nas operações de cache não coerente.
      (vk:map-memory device memory 0 #xffffffffffffffff mapped-pointer)
      (let ((pointer (cffi:mem-ref mapped-pointer :pointer)))
        (unwind-protect
             (progn
               (when (and (eq operation :read)
                          (not (member :host-coherent properties)))
                 (vk:invalidate-mapped-memory-ranges
                  device (list (vk:make-mapped-memory-range
                                :memory memory :offset 0
                                :size #xffffffffffffffff))))
               (funcall function (cffi:inc-pointer pointer offset))
               (when (and (eq operation :write)
                          (not (member :host-coherent properties)))
                 (vk:flush-mapped-memory-ranges
                  device (list (vk:make-mapped-memory-range
                                :memory memory :offset 0
                                :size #xffffffffffffffff))))
               buffer)
          (vk:unmap-memory device memory))))))

(defun write-buffer (buffer data &key (offset 0))
  "Copia bytes para memória host-visible; memória não coerente é descarregada."
  (unless (typep data '(simple-array (unsigned-byte 8) (*)))
    (error "WRITE-BUFFER recebe um vetor simples de octetos."))
  (let ((byte-count (length data)))
    (unless (and (integerp offset)
                 (<= 0 offset (+ offset byte-count) (gpu-buffer-size buffer)))
      (error "Escrita fora dos limites do buffer."))
    (unless (zerop byte-count)
      (%mapped-memory buffer offset byte-count
                      (lambda (pointer)
                        (dotimes (index byte-count)
                          (setf (cffi:mem-aref pointer :uint8 index)
                                (aref data index))))
                      :operation :write))
    buffer))

(defun read-buffer (buffer &key (offset 0) (size (- (gpu-buffer-size buffer) offset)))
  "Lê bytes de memória host-visible depois que a GPU terminou o trabalho."
  (unless (and (integerp offset) (integerp size)
               (<= 0 offset (+ offset size) (gpu-buffer-size buffer)))
    (error "Leitura fora dos limites do buffer."))
  (let ((data (make-array size :element-type '(unsigned-byte 8))))
    (unless (zerop size)
      (%mapped-memory buffer offset size
                      (lambda (pointer)
                        (dotimes (index size)
                          (setf (aref data index)
                                (cffi:mem-aref pointer :uint8 index))))
                      :operation :read))
    data))

(defun destroy-buffer (buffer)
  "Libera buffer antes de sua memória Vulkan."
  (when buffer
    (let ((device (context-device (gpu-buffer-context buffer))))
      (vk:destroy-buffer device (gpu-buffer-handle buffer))
      (vk:free-memory device (gpu-buffer-memory buffer))))
  nil)

(defun make-image (context width height format usage memory-properties
                   &key (aspect '(:color)) (view-type :2d) (view-p t))
  "Cria imagem ótima 2D com alocação de memória e uma vista principal."
  (unless (and (integerp width) (plusp width) (integerp height) (plusp height))
    (error "Dimensões da imagem Vulkan precisam ser inteiros positivos."))
  (let ((device (context-device context))
        (handle nil)
        (memory nil)
        (resource nil))
    (handler-case
        (progn
          (setf handle
                (vk:create-image
                 device
                 (vk:make-image-create-info
                  :image-type :2d :format format
                  :extent (vk:make-extent-3d :width width :height height :depth 1)
                  :mip-levels 1 :array-layers 1 :samples :1
                  :tiling :optimal :usage usage :sharing-mode :exclusive
                  :initial-layout :undefined)))
          (setf memory (%allocate-memory context
                                         (vk:get-image-memory-requirements device handle)
                                         memory-properties))
          (vk:bind-image-memory device handle memory 0)
          (setf resource (%make-gpu-image :context context :handle handle
                                          :memory memory :width width :height height
                                          :format format :aspect aspect))
          (when view-p
            (setf (gpu-image-view resource) (make-image-view resource :aspect aspect
                                                              :view-type view-type)))
          resource)
      (error (condition)
        (when (and resource (gpu-image-view resource))
          (ignore-errors (vk:destroy-image-view device (gpu-image-view resource))))
        (when handle (ignore-errors (vk:destroy-image device handle)))
        (when memory (ignore-errors (vk:free-memory device memory)))
        (error condition)))))

(defun make-image-view (image &key (aspect (gpu-image-aspect image))
                                   (view-type :2d))
  "Cria uma vista para uma imagem, permitindo vistas alternativas de sub-recursos."
  (vk:create-image-view
   (context-device (gpu-image-context image))
   (vk:make-image-view-create-info
    :image (gpu-image-handle image) :view-type view-type
    :format (gpu-image-format image)
    :components (vk:make-component-mapping :r :identity :g :identity :b :identity :a :identity)
    :subresource-range
    (vk:make-image-subresource-range :aspect-mask aspect
                                     :base-mip-level 0 :level-count 1
                                     :base-array-layer 0 :layer-count 1))))

(defun destroy-image (image)
  "Libera vista, imagem e memória na ordem Vulkan exigida."
  (when image
    (let ((device (context-device (gpu-image-context image))))
      (when (gpu-image-view image)
        (vk:destroy-image-view device (gpu-image-view image)))
      (vk:destroy-image device (gpu-image-handle image))
      (vk:free-memory device (gpu-image-memory image))))
  nil)

(defun make-sampler (context &key (filter :linear) (address-mode :repeat)
                                (compare-enable nil) (compare-op :less-or-equal))
  "Cria sampler com filtro e endereçamento selecionáveis."
  (%make-gpu-sampler
   :context context
   :handle
   (vk:create-sampler
    (context-device context)
    (vk:make-sampler-create-info
     :mag-filter filter :min-filter filter :mipmap-mode :linear
     :address-mode-u address-mode :address-mode-v address-mode
     :address-mode-w address-mode :mip-lod-bias 0.0f0
     :anisotropy-enable nil :max-anisotropy 1.0f0
     :compare-enable compare-enable :compare-op compare-op
     :min-lod 0.0f0 :max-lod 0.0f0 :border-color :float-transparent-black
     :unnormalized-coordinates nil))))

(defun destroy-sampler (sampler)
  "Destrói o sampler de GPU."
  (when sampler
    (vk:destroy-sampler (context-device (gpu-sampler-context sampler))
                        (gpu-sampler-handle sampler)))
  nil)

(defun make-shader-module (context binary)
  "Cria VkShaderModule a partir de bytes SPIR-V ou vetor de words uint32."
  (%make-gpu-shader-module
   :context context
   :handle
   (vk:create-shader-module
    (context-device context)
    (vk:make-shader-module-create-info :code (shader-words binary)))))

(defun destroy-shader-module (module)
  "Libera módulo SPIR-V depois da criação dos pipelines dependentes."
  (when module
    (vk:destroy-shader-module
     (context-device (gpu-shader-module-context module))
     (gpu-shader-module-handle module)))
  nil)

(defun begin-command-buffer (context &key one-time)
  "Aloca e inicia um command buffer primário."
  (let ((command-buffer
          (first
           (vk:allocate-command-buffers
            (context-device context)
            (vk:make-command-buffer-allocate-info
             :command-pool (context-command-pool context)
             :level :primary :command-buffer-count 1)))))
    (vk:begin-command-buffer
     command-buffer
     (vk:make-command-buffer-begin-info
      :flags (if one-time '(:one-time-submit) nil)))
    command-buffer))

(defun end-command-buffer (command-buffer)
  "Finaliza gravação de comandos."
  (vk:end-command-buffer command-buffer)
  command-buffer)

(defun submit-command-buffer (context command-buffer &key wait)
  "Envia comandos à fila gráfica e opcionalmente espera sua conclusão."
  (vk:queue-submit
   (context-queue context)
   (list (vk:make-submit-info :command-buffers (list command-buffer))))
  (when wait (vk:queue-wait-idle (context-queue context)))
  command-buffer)

(defun submit-and-wait (context command-buffer)
  "Finaliza, envia, aguarda a GPU e libera o command buffer temporário."
  (unwind-protect
       (progn (end-command-buffer command-buffer)
              (submit-command-buffer context command-buffer :wait t))
    (vk:free-command-buffers (context-device context)
                             (context-command-pool context)
                             (list command-buffer)))
  nil)

(defun %layout-access-stage (layout)
  (case layout
    (:undefined (values nil '(:top-of-pipe)))
    (:transfer-dst-optimal (values '(:transfer-write) '(:transfer)))
    (:transfer-src-optimal (values '(:transfer-read) '(:transfer)))
    (:shader-read-only-optimal (values '(:shader-read) '(:fragment-shader)))
    (:depth-stencil-read-only-optimal (values '(:shader-read) '(:fragment-shader)))
    (:depth-stencil-attachment-optimal
     (values '(:depth-stencil-attachment-read :depth-stencil-attachment-write)
             '(:early-fragment-tests :late-fragment-tests)))
    (:color-attachment-optimal
     (values '(:color-attachment-read :color-attachment-write)
             '(:color-attachment-output)))
    (:present-src-khr (values nil '(:bottom-of-pipe)))
    (otherwise (error "Transição de layout sem máscara definida: ~S" layout))))

(defun transition-image-layout (context command-buffer image old-layout new-layout
                               &key (aspect (gpu-image-aspect image)))
  "Grava uma barreira Vulkan entre layouts usuais de textura e attachment."
  (declare (ignore context))
  (multiple-value-bind (src-access src-stage) (%layout-access-stage old-layout)
    (multiple-value-bind (dst-access dst-stage) (%layout-access-stage new-layout)
      (vk:cmd-pipeline-barrier
       command-buffer nil nil
       (list (vk:make-image-memory-barrier
              :src-access-mask src-access :dst-access-mask dst-access
              :old-layout old-layout :new-layout new-layout
              :src-queue-family-index vk:+queue-family-ignored+
              :dst-queue-family-index vk:+queue-family-ignored+
              :image (gpu-image-handle image)
              :subresource-range
              (vk:make-image-subresource-range
               :aspect-mask aspect :base-mip-level 0 :level-count 1
               :base-array-layer 0 :layer-count 1)))
       src-stage dst-stage))))

(defun shader-words (binary)
  "Converte SPIR-V em octetos little-endian para vetor de uint32 Vulkan."
  (cond
    ((and (vectorp binary) (not (typep binary '(array (unsigned-byte 8) (*))))
          (every (lambda (word) (and (integerp word) (<= 0 word #xffffffff))) binary))
     (map '(vector (unsigned-byte 32)) #'identity binary))
    ((typep binary '(array (unsigned-byte 8) (*)))
     (unless (zerop (mod (length binary) 4))
       (error "Tamanho de SPIR-V precisa ser múltiplo de quatro bytes."))
     (let ((words (make-array (/ (length binary) 4)
                              :element-type '(unsigned-byte 32))))
       (dotimes (index (length words) words)
         (let ((byte-index (* index 4)))
           (setf (aref words index)
                 (logior (aref binary byte-index)
                         (ash (aref binary (+ byte-index 1)) 8)
                         (ash (aref binary (+ byte-index 2)) 16)
                         (ash (aref binary (+ byte-index 3)) 24)))))))
    (t (error "SPIR-V deve ser vetor de octetos ou de words uint32."))))
