;;;; Exercita controles nativos, jogo, áudio e Boids no mesmo mundo vivo.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/simulation/opengl)

(defvar *m6-checks* 0)
(defun m6-check (test message)
  "Registra uma evidência e interrompe a verificação quando ela falha."
  (unless test (error "Verificação M6: ~A" message))
  (incf *m6-checks*))
(defun m6-key (window key action)
  "Aciona o callback real de teclado registrado pelo runtime."
  (funcall (sgeo.backend.opengl::%key-handler window) key 0 action nil))
(defun m6-tap (window key)
  (m6-key window key :press)
  (m6-key window key :release))
(defun m6-report (report)
  (m6-check (null (sgeo.runtime:runtime-report-platform-error report))
            (format nil "janela sem erro: ~A" (sgeo.runtime:runtime-report-platform-error report)))
  (m6-check (null (sgeo.runtime:runtime-report-render-error report)) "renderização sem erro"))
(defun m6-pixels (window)
  (multiple-value-bind (width height) (sgeo.platform:framebuffer-size window)
    (gl:read-pixels 0 0 width height :rgba :unsigned-byte)))

(defun m6-game ()
  "Percorre a partida usando entrada nativa, sem teletransportar o jogador."
  (multiple-value-bind (world game) (sgeo.examples.simulation:make-game-world)
    (let* ((player (sgeo.examples.simulation:game-player game))
           (door (sgeo.examples.simulation:game-door game))
           (state (sgeo.examples.simulation:game-simulation game))
           (phase :walk) (phase-frame 0) (pause-time nil) (initial-pixels nil)
           (heard nil) (live-calls 0) (done nil)
           (behavior (symbol-function 'sgeo.examples.simulation::%fixed-update)))
      (sgeo.simulation:add-phase-hook state :audio
        (lambda (world state dt)
          (declare (ignore world dt))
          (let ((samples (sgeo.simulation:simulation-audio-samples state)))
            (when (some (lambda (sample) (> (abs sample) 0.01d0)) samples)
              (unless heard
                (sgeo.audio:write-wav (merge-pathnames "artifacts/m6-game.wav" *project-root*) samples))
              (setf heard t)))))
      (unwind-protect
           (multiple-value-bind (returned renderer report)
               (sgeo.runtime:run-world world :controls :game :visible nil :repl nil
                 :width 960 :height 640 :frame-dt (/ 1d0 60d0) :max-frames 320
                 :frame-hook
                 (lambda (current window renderer frame)
                   (m6-check (eq current world) "mesmo mundo")
                   (m6-check (eq player (sgeo.examples.simulation:game-player game)) "mesmo jogador")
                   (m6-check (eq door (sgeo.examples.simulation:game-door game)) "mesma porta")
                   (case frame
                     (0 (m6-key window :d :press))
                     (2 (setf initial-pixels (m6-pixels window))
                        (m6-check (> (length (remove-duplicates initial-pixels)) 4) "jogo visível")))
                   (case phase
                     (:walk
                      (when (and (= 2 (sgeo.examples.simulation:game-score game))
                                 (> (sgeo.math:vx (sgeo.physics:body-position
                                                   (sgeo.examples.simulation:game-player-body game))) 0.4d0))
                        (m6-check (not (sgeo.examples.simulation:game-door-locked-p game)) "duas moedas liberam a porta")
                        (m6-check (not (sgeo.examples.simulation:game-door-open-p game)) "porta bloqueia o caminho")
                        (m6-tap window :e)
                        (setf (symbol-function 'sgeo.examples.simulation::%fixed-update)
                              (lambda (&rest arguments) (incf live-calls) (apply behavior arguments)))
                        (setf phase :opening)))
                     (:opening
                      (when (sgeo.examples.simulation:game-door-open-p game)
                        (m6-check (plusp live-calls) "redefinição usada pela partida existente")
                        (m6-check (not (equalp (sg:transform-rotation (sg:scene-object-local-transform door)) (sg:make-quaternion))) "porta animada")
                        (m6-key window :w :press)
                        (setf phase :recenter)))
                     (:recenter
                      (when (< (sgeo.math:vz (sgeo.physics:body-position
                                              (sgeo.examples.simulation:game-player-body game))) 0d0)
                        (m6-key window :w :release)
                        (setf phase :finish)))
                     (:finish
                      (when (eq :won (sgeo.examples.simulation:game-status game))
                        (m6-check (= 3 (sgeo.examples.simulation:game-score game)) "três moedas e saída alcançadas")
                        (m6-check heard "efeitos de áudio misturados durante a partida")
                        (m6-check (not (equalp initial-pixels (m6-pixels window))) "partida alterou o framebuffer")
                        (setf phase :capture-won phase-frame frame)))
                     (:capture-won
                      (when (> frame phase-frame)
                        (sgeo.backend.opengl:capture-framebuffer-ppm window (merge-pathnames "artifacts/m6-game-won.ppm" *project-root*))
                        (m6-tap window :r)
                        (setf phase :reset phase-frame frame)))
                     (:reset
                      (when (> frame phase-frame)
                        (m6-check (zerop (sgeo.examples.simulation:game-score game)) "reinício restaura moedas")
                        (m6-check (sgeo.examples.simulation:game-door-locked-p game) "reinício restaura porta")
                        (setf phase :settle phase-frame frame)))
                     (:settle
                      (when (> (- frame phase-frame) 12)
                        (m6-tap window :space)
                        (setf phase :jump phase-frame frame)))
                     (:jump
                      (when (> frame phase-frame)
                        (m6-check (plusp (sgeo.math:vy (sgeo.physics:body-velocity
                                                       (sgeo.examples.simulation:game-player-body game)))) "salto pela tecla espaço")
                        (m6-key window :d :press)
                        (cffi:foreign-funcall-pointer
                         (cffi:callback sgeo.backend.opengl::%dispatch-focus-callback) nil
                         :pointer (sgeo.backend.opengl:glfw-native-window window) :int 0 :void)
                        (setf phase :focus phase-frame frame)))
                     (:focus
                      (when (> frame phase-frame)
                        (m6-check (not (sgeo.input:action-down-p (sgeo.examples.simulation:game-input game) :move-right)) "perda de foco libera movimento")
                        (m6-check (not (sgeo.backend.opengl::%focused-p window)) "callback registra perda de foco")
                        (m6-check (null (sgeo.platform:window-gamepad-state window)) "controle suspenso enquanto sem foco")
                        (m6-tap window :p)
                        (setf phase :pause phase-frame frame)))
                     (:pause
                      (when (> frame phase-frame)
                        (m6-check (sgeo.simulation:simulation-paused-p state) "pausa pelo teclado")
                        (setf pause-time (sgeo.simulation:simulation-time state) phase :paused phase-frame frame)))
                     (:paused
                      (when (> (- frame phase-frame) 3)
                        (m6-check (= pause-time (sgeo.simulation:simulation-time state)) "relógio fixo suspenso")
                        (m6-tap window :p)
                        (m6-tap window :f1)
                        (setf phase :debug phase-frame frame)))
                     (:debug
                      (when (> frame phase-frame)
                        (m6-check (not (sgeo.simulation:simulation-paused-p state)) "retomada pelo teclado")
                        (m6-check (sgeo.examples.simulation:game-debug-p game) "depuração pelo teclado")
                        (m6-check (> (sgeo.debug:debug-command-count world) 2) "colisores desenhados")
                        (sgeo.debug:debug-line world #(-4d0 2d0 0d0) #(4d0 2d0 0d0) :color #(0.9d0 0.1d0 0.7d0))
                        (setf phase :expire phase-frame frame)))
                     (:expire
                      (when (> (- frame phase-frame) 2)
                        (m6-check (<= (getf (sgeo.render:renderer-info renderer) :gpu-meshes)
                                       (length (getf (sgeo.scene:render-snapshot world) :objects))) "cache de desenho temporário removido")
                        (sgeo.backend.opengl:capture-framebuffer-ppm window (merge-pathnames "artifacts/m6-game-debug.ppm" *project-root*))
                        (setf done t)
                        (sgeo.platform:request-window-close window))))))
             (declare (ignore returned renderer))
             (m6-report report)
             (m6-check done (format nil "partida completou a demonstração; fase ~S" phase))
             (format t "~&M6 jogo: ~D quadros; vitória, reinício, salto, foco, pausa, depuração e redefinição verificados.~%"
                     (sgeo.runtime:runtime-report-frames report)))
        (setf (symbol-function 'sgeo.examples.simulation::%fixed-update) behavior)
        (sgeo.simulation:detach-simulation world :close-audio t)))))

(defun m6-boids (mode)
  "Verifica movimento e redefinição nos dois modos de armazenamento CPU."
  (multiple-value-bind (world flock) (sgeo.examples.simulation:make-boids-world :count 24 :mode mode)
    (let* ((first (aref (sgeo.examples.simulation:flock-boids flock) 0))
           (position (sg:transform-position (sg:scene-object-local-transform first)))
           (pixels nil) (calls 0) (done nil)
           (behavior (symbol-function 'sgeo.examples.simulation:update-flock)))
      (unwind-protect
           (multiple-value-bind (returned renderer report)
               (sgeo.runtime:run-world world :visible nil :repl nil :width 640 :height 420
                 :frame-dt (/ 1d0 60d0) :max-frames 12
                 :frame-hook
                 (lambda (current window renderer frame)
                   (declare (ignore renderer))
                   (m6-check (eq current world) "mesmo mundo Boids")
                   (case frame
                     (1 (setf pixels (m6-pixels window))
                        (setf (symbol-function 'sgeo.examples.simulation:update-flock)
                              (lambda (&rest arguments) (incf calls) (apply behavior arguments)))
                        (setf (sgeo.examples.simulation:boid-max-speed first) 0.4d0))
                     (10 (m6-check (plusp calls) "Boids usa função redefinida")
                         (m6-check (eq first (aref (sgeo.examples.simulation:flock-boids flock) 0)) "mesmo boid")
                         (m6-check (not (equalp position (sg:transform-position (sg:scene-object-local-transform first)))) "boid se moveu")
                         (m6-check (< (sgeo.math:vector-length (sgeo.examples.simulation:boid-velocity first)) 0.401d0) "limite de velocidade alterado ao vivo")
                         (m6-check (not (equalp pixels (m6-pixels window))) "Boids alterou o framebuffer")
                         (setf done t)))))
             (declare (ignore returned renderer))
             (m6-report report)
             (m6-check done "todos os passos Boids executados")
             (format t "~&M6 Boids ~S: ~D quadros, movimento e redefinição verificados.~%" mode (sgeo.runtime:runtime-report-frames report)))
        (setf (symbol-function 'sgeo.examples.simulation:update-flock) behavior)
        (sgeo.simulation:detach-simulation world)))))

(handler-case
    (progn (m6-game) (m6-boids :objects) (m6-boids :packed)
           (format t "~&M6 OpenGL: ~D verificações passaram.~%" *m6-checks*) (uiop:quit 0))
  (error (condition) (format *error-output* "~&Falha na aceitação M6: ~A~%" condition) (uiop:quit 1)))
