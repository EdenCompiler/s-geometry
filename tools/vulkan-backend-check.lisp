(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/backend/vulkan)

(defun check-vulkan-validation-collector (context)
  "Prova que o callback recebe mensagens reais da instância Vulkan."
  (let ((token "S-Geometry validation collector self-test")
        (vk:*default-extension-loader* (sgeo.backend.vulkan:context-extension-loader context)))
    (assert (null (sgeo.backend.vulkan:context-validation-messages context)))
    (vk:submit-debug-utils-message-ext
     (sgeo.backend.vulkan:context-instance context) :warning '(:general)
     (vk:make-debug-utils-messenger-callback-data-ext
      :message-id-name "SGEO-validation-self-test" :message token))
    (let ((messages (sgeo.backend.vulkan:context-validation-messages context)))
      (unless (and (= 1 (length messages)) (string= token (first messages)))
        (error "Callback de validação não recebeu a mensagem de teste: ~S" messages)))
    ;; Remove apenas a mensagem intencional já conferida, antes de executar comandos.
    (bt:with-lock-held (sgeo.backend.vulkan::*vulkan-validation-lock*)
      (setf (car (sgeo.backend.vulkan::vulkan-context-validation-messages context)) nil))
    (format t "Callback de validação Vulkan verificado.~%")))

(defun check-vulkan-backend-transfer ()
  "Verifica criação de recursos e caminho imagem GPU -> buffer de leitura."
  (let ((context (sgeo.backend.vulkan:create-context
                  :validation (member "--validation" (uiop:command-line-arguments) :test #'string=)))
        (image nil) (readback nil) (command-buffer nil))
    (unwind-protect
         (progn
           (when (member "--validation" (uiop:command-line-arguments) :test #'string=)
             (check-vulkan-validation-collector context))
           (setf image
                 (sgeo.backend.vulkan:make-image
                  context 8 8 :r8g8b8a8-unorm
                  '(:transfer-dst :transfer-src) '(:device-local) :view-p nil))
           (setf readback
                 (sgeo.backend.vulkan:make-buffer
                  context (* 8 8 4) '(:transfer-dst)
                  '(:host-visible :host-coherent)))
           (setf command-buffer
                 (sgeo.backend.vulkan:begin-command-buffer context :one-time t))
           (sgeo.backend.vulkan:transition-image-layout
            context command-buffer image :undefined :transfer-dst-optimal)
           (vk:cmd-clear-color-image
            command-buffer (sgeo.backend.vulkan:image-handle image)
            :transfer-dst-optimal
            (vk:make-clear-color-value :float-32 #(1.0f0 0.0f0 0.0f0 1.0f0))
            (list (vk:make-image-subresource-range
                   :aspect-mask '(:color) :base-mip-level 0 :level-count 1
                   :base-array-layer 0 :layer-count 1)))
           (sgeo.backend.vulkan:transition-image-layout
            context command-buffer image :transfer-dst-optimal :transfer-src-optimal)
           (vk:cmd-copy-image-to-buffer
            command-buffer (sgeo.backend.vulkan:image-handle image)
            :transfer-src-optimal (sgeo.backend.vulkan:buffer-handle readback)
            (list (vk:make-buffer-image-copy
                   :buffer-offset 0 :buffer-row-length 0 :buffer-image-height 0
                   :image-subresource
                   (vk:make-image-subresource-layers
                    :aspect-mask '(:color) :mip-level 0 :base-array-layer 0
                    :layer-count 1)
                   :image-offset (vk:make-offset-3d :x 0 :y 0 :z 0)
                   :image-extent (vk:make-extent-3d :width 8 :height 8 :depth 1))))
           (sgeo.backend.vulkan:submit-and-wait context command-buffer)
           (setf command-buffer nil)
           (let ((pixels (sgeo.backend.vulkan:read-buffer readback)))
             (unless (and (= (length pixels) (* 8 8 4))
                          (loop for index from 0 below (length pixels) by 4
                                always (and (= (aref pixels index) 255)
                                            (= (aref pixels (+ index 1)) 0)
                                            (= (aref pixels (+ index 2)) 0)
                                            (= (aref pixels (+ index 3)) 255))))
               (error "Readback Vulkan inesperado: ~S" (subseq pixels 0 16)))
             (format t "Vulkan buffer/image/render/readback OK (~D bytes).~%"
                     (length pixels))))
      (when command-buffer
        (ignore-errors
          (vk:free-command-buffers
           (sgeo.backend.vulkan:context-device context)
           (sgeo.backend.vulkan:context-command-pool context)
           (list command-buffer))))
      (when readback (sgeo.backend.vulkan:destroy-buffer readback))
      (when image (sgeo.backend.vulkan:destroy-image image))
      (sgeo.backend.vulkan:destroy-context context))
    (when (sgeo.backend.vulkan:context-validation-messages context)
      (error "Validação Vulkan: ~S" (sgeo.backend.vulkan:context-validation-messages context))))
  t)

(sgeo.platform:with-native-graphics-environment ()
  (check-vulkan-backend-transfer))
