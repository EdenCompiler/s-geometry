;;;; Regressão nativa do caminho de apresentação exclusivamente sRGB.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/pbr)
(asdf:load-system :sgeo/backend/vulkan)

(defun presentation-check (value description)
  (unless value (error "Apresentação Vulkan: ~A" description))
  value)

(defun presentation-check-proxy-bytes (renderer)
  "Copia a imagem proxy concluída para staging e devolve todos os bytes lidos."
  (let* ((context (sgeo.backend.vulkan::%renderer-context renderer))
         (proxy (sgeo.backend.vulkan::%presentation-image renderer))
         (width (sgeo.backend.vulkan:image-width proxy))
         (height (sgeo.backend.vulkan:image-height proxy))
         (byte-count (* width height 4))
         (staging nil))
    (unwind-protect
         (progn
           (setf staging
                 (sgeo.backend.vulkan:make-buffer
                  context byte-count '(:transfer-dst)
                  '(:host-visible :host-coherent)))
           (let ((command (sgeo.backend.vulkan:begin-command-buffer context :one-time t)))
             (unwind-protect
                  (progn
                    (vk:cmd-copy-image-to-buffer
                     command (sgeo.backend.vulkan:image-handle proxy)
                     :transfer-src-optimal
                     (sgeo.backend.vulkan:buffer-handle staging)
                    (list
                      (vk:make-buffer-image-copy
                       :buffer-offset 0 :buffer-row-length 0 :buffer-image-height 0
                       :image-subresource
                       (vk:make-image-subresource-layers
                        :aspect-mask '(:color) :mip-level 0
                        :base-array-layer 0 :layer-count 1)
                       :image-offset (vk:make-offset-3d :x 0 :y 0 :z 0)
                       :image-extent (vk:make-extent-3d
                                      :width width :height height :depth 1))))
                    (vk:cmd-pipeline-barrier
                     command nil
                     (list (vk:make-buffer-memory-barrier
                            :src-access-mask '(:transfer-write)
                            :dst-access-mask '(:host-read)
                            :src-queue-family-index vk:+queue-family-ignored+
                            :dst-queue-family-index vk:+queue-family-ignored+
                            :buffer (sgeo.backend.vulkan:buffer-handle staging)
                            :offset 0 :size byte-count))
                     nil '(:transfer) '(:host))
                    (sgeo.backend.vulkan:end-command-buffer command)
                    (sgeo.backend.vulkan:submit-command-buffer context command :wait t)
                    (vk:free-command-buffers
                     (sgeo.backend.vulkan::context-device context)
                     (sgeo.backend.vulkan::context-command-pool context)
                     (list command))
                    (setf command nil))
               (when command
                 (ignore-errors
                   (vk:free-command-buffers
                    (sgeo.backend.vulkan::context-device context)
                    (sgeo.backend.vulkan::context-command-pool context)
                    (list command))))))
           (sgeo.backend.vulkan:read-buffer staging :size byte-count))
      (when staging (sgeo.backend.vulkan:destroy-buffer staging)))))

(defun presentation-check-swizzle-expected (pixels format)
  "Ajusta apenas R/B quando a imagem proxy tem ordem BGRA."
  (let ((expected (copy-seq pixels)))
    (when (eq format :b8g8r8a8-unorm)
      (loop for offset from 0 below (length expected) by 4 do
        (rotatef (aref expected offset) (aref expected (+ offset 2)))))
    expected))

(defun run-vulkan-presentation-check ()
  "Força swapchain sRGB, injeta uma aquisição obsoleta e verifica a cópia crua."
  (let* ((package (find-package :sgeo.backend.vulkan))
         (format-symbol (find-symbol "%SWAPCHAIN-FORMAT" package))
         (acquire-symbol (find-symbol "ACQUIRE-FRAME" package))
         (original-format (symbol-function format-symbol))
         (original-acquire (symbol-function acquire-symbol))
         (format-was-filtered nil)
         (acquire-was-injected nil)
         (initial-swapchain nil)
         (initial-proxy nil)
         (recreation-verified nil)
         (bytes-verified nil)
         (expected-format nil)
         (hook-count 0)
         (world (sgeo.examples.pbr:make-pbr-world)))
    (unwind-protect
         (progn
           (setf (symbol-function format-symbol)
                 (lambda (context formats)
                   (let* ((undefined-p
                            (and (= (length formats) 1)
                                 (eq (vk:format (first formats)) :undefined)))
                          (srgb-formats
                            (if undefined-p
                                (list
                                 (vk:make-surface-format-khr
                                  :format :r8g8b8a8-srgb
                                  :color-space (vk:color-space (first formats)))
                                 (vk:make-surface-format-khr
                                  :format :b8g8r8a8-srgb
                                  :color-space (vk:color-space (first formats))))
                                (remove-if-not
                                 (lambda (surface-format)
                                   (and (eq (vk:color-space surface-format) :srgb-nonlinear-khr)
                                        (member (vk:format surface-format)
                                                '(:r8g8b8a8-srgb :b8g8r8a8-srgb))))
                                 formats))))
                     (unless srgb-formats
                       (error "A superfície não anuncia RGBA8/BGRA8 sRGB_NONLINEAR; fallback impossível."))
                     (setf format-was-filtered t)
                     (funcall original-format context srgb-formats))))
           (setf (symbol-function acquire-symbol)
                 (lambda (context &rest arguments)
                   (if acquire-was-injected
                       (apply original-acquire context arguments)
                       (progn
                         (setf acquire-was-injected t)
                         (values nil :out-of-date)))))
           (multiple-value-bind (returned renderer report)
               (sgeo.examples.pbr:run-pbr-viewer
                :world world :width 640 :height 420 :visible nil :repl nil
                :validation t :max-frames 5
                :frame-hook
                (lambda (current window active-renderer frame)
                  (declare (ignore window frame))
                  (incf hook-count)
                  (presentation-check (eq current world) "o visualizador manteve a instância da cena")
                  (let* ((info (sgeo.render:renderer-info active-renderer))
                         (context (sgeo.backend.vulkan::%renderer-context active-renderer))
                         (format (sgeo.backend.vulkan::%presentation-format active-renderer))
                         (proxy (sgeo.backend.vulkan::%presentation-image active-renderer))
                         (extent (sgeo.backend.vulkan::context-swapchain-extent context)))
                    (presentation-check (getf info :validation) "validação Vulkan habilitada")
                    (presentation-check (null (getf info :validation-messages))
                                        (format nil "mensagens de validação durante o quadro: ~S"
                                                (getf info :validation-messages)))
                    (presentation-check (member format '(:r8g8b8a8-srgb :b8g8r8a8-srgb))
                                        "formato ativo é RGBA8/BGRA8 sRGB")
                    (presentation-check proxy "imagem proxy sRGB presente")
                    (presentation-check (null (sgeo.backend.vulkan:image-view proxy))
                                        "proxy de transferência não cria image view")
                    (presentation-check (= (sgeo.backend.vulkan:image-width proxy)
                                           (vk:width extent))
                                        "largura do proxy coincide com a swapchain")
                    (presentation-check (= (sgeo.backend.vulkan:image-height proxy)
                                           (vk:height extent))
                                        "altura do proxy coincide com a swapchain")
                    (unless initial-swapchain
                      (setf initial-swapchain (sgeo.backend.vulkan::context-swapchain context)
                            initial-proxy proxy
                            expected-format format))
                    (when (and acquire-was-injected (not recreation-verified))
                      (presentation-check
                       (not (eq initial-swapchain (sgeo.backend.vulkan::context-swapchain context)))
                       "aquisição OUT_OF_DATE substituiu a swapchain")
                      (presentation-check (not (eq initial-proxy proxy))
                                          "recriação instalou um novo proxy")
                      (presentation-check (eq expected-format format)
                                          "recriação preservou o fallback sRGB")
                      (setf recreation-verified t))
                    ;; O hook antecede o render atual: frame-count positivo prova
                    ;; que já houve ao menos um quadro completo na GPU.
                    (when (and (plusp (sgeo.render:renderer-frame-count active-renderer))
                               (not bytes-verified))
                      (presentation-check
                       (eq (sgeo.backend.vulkan::%presentation-image-layout active-renderer)
                           :transfer-src-optimal)
                       "proxy terminou o quadro em TRANSFER_SRC_OPTIMAL")
                      (let* ((pixels (sgeo.backend.vulkan::%last-frame-pixels active-renderer))
                             (proxy-format
                               (sgeo.backend.vulkan::gpu-image-format proxy))
                             (staged (presentation-check-proxy-bytes active-renderer))
                             (expected (presentation-check-swizzle-expected pixels proxy-format)))
                        (presentation-check (= (length staged) (length expected))
                                            "staging e imagem renderizada têm o mesmo tamanho")
                        (presentation-check (equalp staged expected)
                                            "cópia sRGB preservou todos os bytes e canais")
                        (setf bytes-verified t))))))
             (presentation-check (eq returned world) "mundo retornado preservado")
             (presentation-check format-was-filtered "format chooser recebeu apenas formatos sRGB")
             (presentation-check acquire-was-injected "aquisição obsoleta injetada")
             (presentation-check recreation-verified "recriação por OUT_OF_DATE confirmada")
             (presentation-check bytes-verified "bytes do proxy conferidos após quadro completo")
             (presentation-check (>= (sgeo.runtime:runtime-report-frames report) 3)
                                 "quadros Vulkan reais concluídos após recuperação")
             (presentation-check (null (sgeo.runtime:runtime-report-platform-error report))
                                 (format nil "erro de callback: ~A"
                                         (sgeo.runtime:runtime-report-platform-error report)))
             (presentation-check (null (sgeo.runtime:runtime-report-render-error report))
                                 (format nil "erro do renderer: ~A"
                                         (sgeo.runtime:runtime-report-render-error report)))
             (presentation-check (null (getf (sgeo.render:renderer-info renderer)
                                             :validation-messages))
                                 "nenhuma mensagem Vulkan durante execução ou encerramento")
             (format t "Apresentação Vulkan: ~D hooks, formato ~S, recuperação OUT_OF_DATE e ~D bytes comparados sem diferenças; validação sem mensagens.~%"
                     hook-count expected-format
                     (length (sgeo.backend.vulkan::%last-frame-pixels renderer)))
             t))
      (setf (symbol-function format-symbol) original-format
            (symbol-function acquire-symbol) original-acquire))))

(handler-case (run-vulkan-presentation-check)
  (error (condition)
    (format *error-output* "~&~A~%" condition)
    (uiop:quit 1)))
