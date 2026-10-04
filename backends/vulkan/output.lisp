(in-package #:sgeo.backend.vulkan)

(defun %srgb-presentation-format-p (format)
  (member format '(:b8g8r8a8-srgb :r8g8b8a8-srgb)))

(defun %presentation-proxy-format (format)
  (case format
    (:b8g8r8a8-srgb :b8g8r8a8-unorm)
    (:r8g8b8a8-srgb :r8g8b8a8-unorm)
    ((:b8g8r8a8-unorm :r8g8b8a8-unorm) nil)
    (otherwise (error "Formato de apresentação Vulkan não compatível: ~S" format))))

(defun %prepare-presentation-output (renderer extent format)
  "Prepara atomicamente uma imagem UNORM intermediária quando a swapchain é sRGB."
  (let* ((context (%renderer-context renderer))
         (width (vk:width extent))
         (height (vk:height extent))
         (proxy-format (%presentation-proxy-format format))
         (candidate
           (when proxy-format
             (let ((features
                     (vk:optimal-tiling-features
                      (vk:get-physical-device-format-properties
                       (context-physical-device context) proxy-format))))
               (unless (every (lambda (feature) (member feature features))
                              '(:blit-dst :transfer-src :transfer-dst))
                 (error "O formato proxy ~S não permite blit e cópia de saída."
                        proxy-format)))
             (make-image context width height proxy-format
                         '(:transfer-src :transfer-dst) '(:device-local)
                         :view-p nil)))
         (previous (%presentation-image renderer)))
    ;; Só substitui o recurso em uso depois que o novo buffer foi criado e
    ;; vinculado com sucesso. O chamador já aguardou a fila ociosa.
    (setf (%presentation-format renderer) format
          (%presentation-image renderer) candidate
          (%presentation-image-layout renderer) :undefined)
    (when previous
      (destroy-image previous))
    renderer))

(defun %presentation-barrier (command image old-layout new-layout
                              src-access dst-access src-stage dst-stage)
  (vk:cmd-pipeline-barrier
   command nil nil
   (list (vk:make-image-memory-barrier
          :src-access-mask src-access :dst-access-mask dst-access
          :old-layout old-layout :new-layout new-layout
          :src-queue-family-index vk:+queue-family-ignored+
          :dst-queue-family-index vk:+queue-family-ignored+
          :image image
          :subresource-range (vk:make-image-subresource-range
                              :aspect-mask '(:color) :base-mip-level 0 :level-count 1
                              :base-array-layer 0 :layer-count 1)))
   src-stage dst-stage))

(defun %blit-region (renderer extent)
  (let ((src-width (%extent-width renderer))
        (src-height (%extent-height renderer))
        (dst-width (vk:width extent))
        (dst-height (vk:height extent)))
    (vk:make-image-blit
     :src-subresource (vk:make-image-subresource-layers
                       :aspect-mask '(:color) :mip-level 0
                       :base-array-layer 0 :layer-count 1)
     :src-offsets (list (vk:make-offset-3d :x 0 :y 0 :z 0)
                        (vk:make-offset-3d :x src-width :y src-height :z 1))
     :dst-subresource (vk:make-image-subresource-layers
                       :aspect-mask '(:color) :mip-level 0
                       :base-array-layer 0 :layer-count 1)
     :dst-offsets (list (vk:make-offset-3d :x 0 :y 0 :z 0)
                        (vk:make-offset-3d :x dst-width :y dst-height :z 1)))))

(defun %record-swapchain-blit (renderer command image-index)
  "Blit UNORM diretamente ou converte o tamanho antes de uma cópia sRGB bruta."
  (let* ((context (%renderer-context renderer))
         (swapchain-image (nth image-index (context-swapchain-images context)))
         (extent (context-swapchain-extent context))
         (format (%presentation-format renderer))
         (proxy (%presentation-image renderer))
         (proxy-format (%presentation-proxy-format format)))
    (unless swapchain-image
      (error "Índice de imagem swapchain inválido: ~S" image-index))
    ;; A aquisição é sincronizada pelo semáforo cuja espera começa no estágio
    ;; TRANSFER; por isso a transição inicial também usa esse escopo.
    (%presentation-barrier command swapchain-image :undefined :transfer-dst-optimal
                            nil '(:transfer-write) '(:transfer) '(:transfer))
    (if proxy-format
        (progn
          (unless proxy
            (error "A swapchain sRGB exige a imagem proxy de saída UNORM."))
          (let* ((old-layout (%presentation-image-layout renderer))
                 (old-access (if (eq old-layout :transfer-src-optimal)
                                 '(:transfer-read) nil))
                 (old-stage (if (eq old-layout :undefined)
                                '(:top-of-pipe) '(:transfer))))
            (%presentation-barrier command (image-handle proxy)
                                    old-layout :transfer-dst-optimal
                                    old-access '(:transfer-write)
                                    old-stage '(:transfer)))
          (vk:cmd-blit-image
           command (image-handle (%output-image renderer)) :transfer-src-optimal
           (image-handle proxy) :transfer-dst-optimal
           (list (%blit-region renderer extent)) :nearest)
          ;; O blit para UNORM preserva os bytes já codificados em gama. A cópia
          ;; seguinte usa formatos compatíveis em tamanho e não transforma sRGB.
          (%presentation-barrier command (image-handle proxy)
                                  :transfer-dst-optimal :transfer-src-optimal
                                  '(:transfer-write) '(:transfer-read)
                                  '(:transfer) '(:transfer))
          (setf (%presentation-image-layout renderer) :transfer-src-optimal)
          (vk:cmd-copy-image
           command (image-handle proxy) :transfer-src-optimal
           swapchain-image :transfer-dst-optimal
           (list (vk:make-image-copy
                  :src-subresource (vk:make-image-subresource-layers
                                    :aspect-mask '(:color) :mip-level 0
                                    :base-array-layer 0 :layer-count 1)
                  :src-offset (vk:make-offset-3d :x 0 :y 0 :z 0)
                  :dst-subresource (vk:make-image-subresource-layers
                                    :aspect-mask '(:color) :mip-level 0
                                    :base-array-layer 0 :layer-count 1)
                  :dst-offset (vk:make-offset-3d :x 0 :y 0 :z 0)
                  :extent (vk:make-extent-3d :width (vk:width extent)
                                            :height (vk:height extent) :depth 1)))))
        (vk:cmd-blit-image
         command (image-handle (%output-image renderer)) :transfer-src-optimal
         swapchain-image :transfer-dst-optimal
         (list (%blit-region renderer extent)) :nearest))
    (%presentation-barrier command swapchain-image :transfer-dst-optimal :present-src-khr
                            '(:transfer-write) nil '(:transfer) '(:bottom-of-pipe))
    renderer))
