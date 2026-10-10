;;;; Confirma que a simulação e os desenhos temporários funcionam no Vulkan real.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/runtime/vulkan)
(asdf:load-system :sgeo/examples/simulation)

(defun m6-vulkan-check (condition message)
  (unless condition (error "M6 Vulkan: ~A" message)))

(defun m6-vulkan-game-controls ()
  "Confirma que reiniciar a partida não aciona os atalhos do visualizador."
  (multiple-value-bind (world game) (sgeo.examples.simulation:make-game-world)
    (let ((reload (symbol-function 'sgeo.render:reload-renderer-shaders))
          (reloads 0) (finished nil)
          (player (sgeo.examples.simulation:game-player game)))
      (unwind-protect
           (progn
             (setf (symbol-function 'sgeo.render:reload-renderer-shaders)
                   (lambda (&rest arguments) (incf reloads) (apply reload arguments)))
             (multiple-value-bind (returned renderer report)
                 (sgeo.runtime:run-world world :backend :vulkan :controls :game
                   :validation t :visible nil :repl nil :frame-dt (/ 1d0 60d0)
                   :max-frames 4 :width 640 :height 420
                   :frame-hook
                   (lambda (current window renderer frame)
                     (declare (ignore current))
                     (m6-vulkan-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages)) "validação do jogo")
                     (case frame
                       (0 (setf (sgeo.examples.simulation:game-score game) 2)
                          (funcall (sgeo.backend.vulkan::%vulkan-key-handler window) :r 0 :press nil)
                          (funcall (sgeo.backend.vulkan::%vulkan-key-handler window) :r 0 :release nil))
                       (1 (m6-vulkan-check (zerop (sgeo.examples.simulation:game-score game)) "tecla R reinicia o jogo")
                          (m6-vulkan-check (zerop reloads) "R do jogo não recarrega shaders")
                          (m6-vulkan-check (eq player (sgeo.examples.simulation:game-player game)) "reinício preserva o jogador")
                          (funcall (sgeo.backend.vulkan::%vulkan-key-handler window) :d 0 :press nil)
                          (cffi:foreign-funcall-pointer
                           (cffi:callback sgeo.backend.vulkan::%vulkan-focus-callback) nil
                           :pointer (sgeo.backend.vulkan::%vulkan-window-native window) :int 0 :void))
                       (2 (m6-vulkan-check (not (sgeo.input:action-down-p (sgeo.examples.simulation:game-input game) :move-right)) "perda de foco libera ação Vulkan")
                          (m6-vulkan-check (not (sgeo.backend.vulkan::%vulkan-focused-p window)) "callback registra perda de foco")
                          (m6-vulkan-check (null (sgeo.platform:window-gamepad-state window)) "controle suspenso enquanto sem foco")
                          (setf finished t)))))
               (declare (ignore returned))
               (m6-vulkan-check finished "controles de jogo exercitados")
               (m6-vulkan-check (null (sgeo.runtime:runtime-report-platform-error report)) "erro nos controles")
               (m6-vulkan-check (null (sgeo.runtime:runtime-report-render-error report)) "renderização do jogo")
               (m6-vulkan-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages)) "validação após jogo")
               (format t "~&M6 jogo Vulkan: ~D quadros; reinício, contexto de entrada e validação verificados.~%"
                       (sgeo.runtime:runtime-report-frames report))))
        (setf (symbol-function 'sgeo.render:reload-renderer-shaders) reload)
        (sgeo.simulation:detach-simulation world :close-audio t)))))
(handler-case
    (multiple-value-bind (world flock) (sgeo.examples.simulation:make-boids-world :count 12 :mode :packed)
      (let ((pixels nil) (finished nil) (peak nil)
            (boid (aref (sgeo.examples.simulation:flock-boids flock) 0)))
        (multiple-value-bind (returned renderer report)
            (sgeo.runtime:run-world world :backend :vulkan :validation t :visible nil :repl nil
              :frame-dt (/ 1d0 60d0) :max-frames 8 :width 640 :height 420
              :frame-hook
              (lambda (current window renderer frame)
                (declare (ignore current window))
                (m6-vulkan-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages)) "mensagens de validação")
                (case frame
                  (1 (setf pixels (copy-seq (sgeo.backend.vulkan::%last-frame-pixels renderer)))
                     (sgeo.debug:debug-sphere world #(0d0 2d0 0d0) 1d0 :color #(1d0 0.1d0 0.7d0) :duration 0.035d0)
                     (setf (sgeo.examples.simulation:boid-max-speed boid) 0.3d0))
                  (2 (setf peak (getf (sgeo.render:renderer-info renderer) :gpu-meshes)))
                  (6 (m6-vulkan-check (not (equalp pixels (sgeo.backend.vulkan::%last-frame-pixels renderer))) "movimento alterou pixels")
                     (m6-vulkan-check (< (sgeo.math:vector-length (sgeo.examples.simulation:boid-velocity boid)) 0.301d0) "parâmetro vivo aplicado")
                     (m6-vulkan-check (< (getf (sgeo.render:renderer-info renderer) :gpu-meshes) peak) "cache temporário liberado")
                     (setf finished t)))))
          (declare (ignore returned))
          (m6-vulkan-check finished "demonstração completa")
          (m6-vulkan-check (null (sgeo.runtime:runtime-report-render-error report)) "erro de renderização")
          (m6-vulkan-check (null (sgeo.runtime:runtime-report-platform-error report)) (format nil "erro de janela: ~A" (sgeo.runtime:runtime-report-platform-error report)))
          (m6-vulkan-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages)) "validação após encerramento")
          (format t "~&M6 Vulkan: ~D quadros, ~D uploads; simulação, desenho temporário e limpeza sem mensagens de validação.~%"
                  (sgeo.runtime:runtime-report-frames report) (sgeo.runtime:runtime-report-uploads report)))
        (sgeo.simulation:detach-simulation world))
      (m6-vulkan-game-controls)
      (uiop:quit 0))
  (error (condition) (format *error-output* "~&Falha no teste Vulkan M6: ~A~%" condition) (uiop:quit 1)))
