(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %game-frame (world &optional (dt (/ 1d0 60d0)))
  (sg:update-world world dt))

(defun %game-advance (world seconds)
  (loop repeat (ceiling (* seconds 60d0)) do (%game-frame world)))

(defun %game-move-player (game position)
  (sg:set-position (sgeo.examples.simulation:game-player game) position))

(defun %game-press (game key)
  (sg:queue-input-event (sgeo.examples.simulation:game-input game) :key
                        :code key :action :press)
  (%game-frame (sgeo.examples.simulation::game-state-world game))
  (sg:queue-input-event (sgeo.examples.simulation:game-input game) :key
                        :code key :action :release)
  (%game-frame (sgeo.examples.simulation::game-state-world game)))

(test game-builds-live-scene-and-physics-and-accepts-runtime-tuning
  (multiple-value-bind (world game) (sgeo.examples.simulation:make-game-world)
    (unwind-protect
         (progn
           (is (eq (sgeo.examples.simulation:game-simulation game)
                   (sg:world-simulation-state world)))
           (is (eq (sgeo.examples.simulation:game-player game)
                   (sg:body-object (sgeo.examples.simulation:game-player-body game))))
           (is (>= (length (sg:physics-bodies (sgeo.examples.simulation:game-physics game))) 10))
           (is (sgeo.examples.simulation:game-door-locked-p game))
           (is (eq :playing (sgeo.examples.simulation:game-status game)))
           (setf (sgeo.examples.simulation:game-speed game) 7d0)
           (is (approximately= 7d0 (sgeo.examples.simulation:game-speed game)))
           (%game-advance world 0.5d0)
           (is (<= (sg:vy (sg:body-position (sgeo.examples.simulation:game-player-body game)))
                   0.4d0))
           (let ((before (sg:body-position (sgeo.examples.simulation:game-player-body game))))
             (sg:queue-input-event (sgeo.examples.simulation:game-input game) :key
                                   :code :d :action :press)
             (%game-advance world 0.15d0)
             (sg:queue-input-event (sgeo.examples.simulation:game-input game) :key
                                   :code :d :action :release)
             (%game-frame world)
             (is (> (sg:vx (sg:body-position (sgeo.examples.simulation:game-player-body game)))
                    (sg:vx before))
                 "A held movement action advances the dynamic player.")))
      (sg:detach-simulation world :close-audio t))))

(test game-collects-trigger-coins-jumps-opens-door-and-wins
  (multiple-value-bind (world game) (sgeo.examples.simulation:make-game-world)
    (unwind-protect
         (progn
           ;; Assenta a esfera no piso antes de testar o salto e os sensores.
           (%game-advance world 0.5d0)
           (%game-move-player game #( -2d0 0.45d0 0d0))
           (%game-frame world)
           (is (= 1 (sgeo.examples.simulation:game-score game)))
           (is (sgeo.examples.simulation:game-door-locked-p game))
           (%game-move-player game #(0d0 0.45d0 0d0))
           (%game-frame world)
           (is (= 2 (sgeo.examples.simulation:game-score game)))
           (is (not (sgeo.examples.simulation:game-door-locked-p game)))
           ;; O terceiro sensor conta separadamente e libera a condição de saída.
           (%game-move-player game #(3d0 0.45d0 0d0))
           (%game-frame world)
           (is (= 3 (sgeo.examples.simulation:game-score game)))
           ;; Interagir perto da porta inicia a animação da cena e abre o vão após 0,7 s.
           (%game-move-player game #(0d0 0.45d0 0d0))
           (%game-frame world)
           (%game-press game :e)
           (%game-advance world 0.75d0)
           (is (sgeo.examples.simulation:game-door-open-p game))
           ;; Pular depois de tocar o chão deve aplicar impulso vertical positivo.
           (%game-advance world 0.2d0)
           (sg:queue-input-event (sgeo.examples.simulation:game-input game) :key
                                 :code :space :action :press)
           (%game-frame world)
           (is (> (sg:vy (sg:body-velocity (sgeo.examples.simulation:game-player-body game))) 0d0))
           (sg:queue-input-event (sgeo.examples.simulation:game-input game) :key
                                 :code :space :action :release)
           (%game-frame world)
           (%game-move-player game #(5.5d0 0.45d0 0d0))
           (%game-frame world)
           (is (eq :won (sgeo.examples.simulation:game-status game)))
           (sgeo.examples.simulation:restart-game game)
           (is (= 0 (sgeo.examples.simulation:game-score game)))
           (is (eq :playing (sgeo.examples.simulation:game-status game)))
           (is (sgeo.examples.simulation:game-door-locked-p game))
           (is (not (sgeo.examples.simulation:game-door-open-p game)))
           (is (vector-approximately= #(-4d0 0.4d0 0d0)
                                      (sg:body-position (sgeo.examples.simulation:game-player-body game)))))
      (sg:detach-simulation world :close-audio t))))
