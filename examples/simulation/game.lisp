(in-package #:sgeo.examples.simulation)

(sgeo.input:define-input-map game-controls
  (:move-left (:key :a) (:key :left) (:gamepad-axis :left-x :negative))
  (:move-right (:key :d) (:key :right) (:gamepad-axis :left-x :positive))
  (:move-forward (:key :w) (:key :up) (:gamepad-axis :left-y :negative))
  (:move-backward (:key :s) (:key :down) (:gamepad-axis :left-y :positive))
  (:jump (:key :space) (:gamepad-button :a))
  (:interact (:key :e) (:mouse-button :left) (:gamepad-button :x))
  (:pause (:key :p))
  (:restart (:key :r))
  (:debug (:key :f1)))

(defstruct (game-coin (:constructor %make-game-coin))
  object sensor-object body collected-p)

(defstruct (game-state (:constructor %make-game-state))
  world player player-body physics simulation input
  (score 0) (status :playing) (speed 4.5d0)
  (door-locked-p t) (door-open-p nil) door door-body
  (door-opening-p nil) (door-opening-time 0d0) door-player
  coins obstacles grounded-p debug-p mixer collect-source door-source)

(defvar *game* nil
  "Estado do último jogo criado, disponível para inspeção no REPL.")

(defun game-player (game) (game-state-player game))
(defun game-player-body (game) (game-state-player-body game))
(defun game-score (game) (game-state-score game))
(defun (setf game-score) (value game)
  (unless (and (integerp value) (>= value 0)) (error "score precisa ser inteiro não negativo."))
  (setf (game-state-score game) value))
(defun game-status (game) (game-state-status game))
(defun (setf game-status) (value game)
  (unless (member value '(:playing :paused :won)) (error "Estado de jogo desconhecido: ~S" value))
  (setf (game-state-status game) value))
(defun game-speed (game) (game-state-speed game))
(defun (setf game-speed) (value game)
  (unless (and (realp value) (> value 0)
               (handler-case (<= value most-positive-double-float) (error () nil)))
    (error "speed precisa ser positivo e finito."))
  (setf (game-state-speed game) (coerce value 'double-float)))
(defun game-door-locked-p (game) (game-state-door-locked-p game))
(defun (setf game-door-locked-p) (value game)
  (setf (game-state-door-locked-p game) (not (null value))))
(defun game-door-open-p (game) (game-state-door-open-p game))
(defun game-door (game) (game-state-door game))
(defun game-input (game) (game-state-input game))
(defun game-physics (game) (game-state-physics game))
(defun game-simulation (game) (game-state-simulation game))
(defun game-debug-p (game) (game-state-debug-p game))
(defun (setf game-debug-p) (value game)
  (setf (game-state-debug-p game) (not (null value))))

(defparameter +game-player-start+ (sgeo.math:vec3 -4d0 0.4d0 0d0))
(defparameter +game-door-position+ (sgeo.math:vec3 1d0 1d0 0d0))
(defparameter +game-coin-positions+
  (list (sgeo.math:vec3 -2d0 0.45d0 0d0)
        (sgeo.math:vec3 0d0 0.45d0 0d0)
        (sgeo.math:vec3 3d0 0.45d0 0d0)))

(defun %game-box-object (name position dimensions color)
  (sgeo.scene:make-mesh-object
   (sgeo.geometry:make-box :size 1d0 :name name)
   :name name :position position :scale dimensions
   :material (sgeo.scene:make-material :name (format nil "~A color" name) :color color)))

(defun %game-sphere-object (name position radius color)
  (sgeo.scene:make-mesh-object
   (sgeo.geometry:make-sphere :radius radius :segments 16 :rings 8 :name name)
   :name name :position position
   :material (sgeo.scene:make-material :name (format nil "~A color" name) :color color)))

(defun %add-visual (world object)
  (sgeo.scene:add-to-world world object)
  object)

(defun %add-static-box (world physics name position dimensions color)
  (let* ((object (%game-box-object name position dimensions color))
         (body (sgeo.physics:make-rigid-body
                :object object
                :shape (sgeo.physics:make-box-shape :half-extents (sgeo.math:vec3 0.5d0 0.5d0 0.5d0))
                :motion-type :static :friction 0.85d0)))
    (%add-visual world object)
    (sgeo.physics:add-body physics body)
    (values object body)))

(defun %near-door-p (game)
  (let* ((player (sgeo.physics:body-position (game-state-player-body game)))
         (door (sgeo.math:transform-point (sgeo.scene:world-transform (game-state-door game))
                                          (sgeo.math:vec3)))
         (dx (- (sgeo.math:vx player) (sgeo.math:vx door)))
         (dz (- (sgeo.math:vz player) (sgeo.math:vz door))))
    (<= (+ (* dx dx) (* dz dz)) (* 1.4d0 1.4d0))))

(defun %play-game-sound (source &optional (pitch 1d0))
  (setf (sgeo.audio:audio-source-pitch source) pitch)
  (sgeo.audio:play-source source))

(defun %collect-coin (game coin)
  (unless (game-coin-collected-p coin)
    (setf (game-coin-collected-p coin) t)
    (incf (game-state-score game))
    (sgeo.physics:remove-body (game-state-physics game) (game-coin-body coin))
    (dolist (object (list (game-coin-object coin) (game-coin-sensor-object coin)))
      (when (sgeo.scene:scene-object-world object)
        (sgeo.scene:remove-from-world (game-state-world game) object)))
    (when (>= (game-state-score game) 2)
      (setf (game-state-door-locked-p game) nil))
    (%play-game-sound (game-state-collect-source game) (+ 0.9d0 (* 0.1d0 (game-state-score game))))))

(defun %handle-physics-event (game event)
  (when (eq (sgeo.simulation:event-type event) :begin)
    (let ((contact (sgeo.simulation:event-payload event))
          (player-body (game-state-player-body game)))
      (when (or (eq (sgeo.physics:contact-body-a contact) player-body)
                (eq (sgeo.physics:contact-body-b contact) player-body))
        (dolist (coin (game-state-coins game))
          (let ((coin-body (game-coin-body coin)))
            (when (and coin-body
                       (or (eq (sgeo.physics:contact-body-a contact) coin-body)
                           (eq (sgeo.physics:contact-body-b contact) coin-body)))
              (%collect-coin game coin))))))))

(defun %grounded-p (game)
  (let ((player (game-state-player-body game)))
    (some (lambda (contact)
            (cond ((eq (sgeo.physics:contact-body-b contact) player)
                   (> (sgeo.math:vy (sgeo.physics:contact-normal contact)) 0.5d0))
                  ((eq (sgeo.physics:contact-body-a contact) player)
                   (< (sgeo.math:vy (sgeo.physics:contact-normal contact)) -0.5d0))
                  (t nil)))
          (sgeo.physics:physics-contacts (game-state-physics game)))))

(defun %restart-state (game)
  (let* ((world (game-state-world game)) (physics (game-state-physics game))
         (door (game-state-door game)) (door-body (game-state-door-body game)))
    (when (game-state-door-player game)
      (sgeo.animation:stop-animation (game-state-door-player game)))
    (when door-body
      (unless (member door-body (sgeo.physics:physics-bodies physics) :test #'eq)
        (sgeo.physics:add-body physics door-body)))
    (sgeo.scene:set-position (game-state-player game) +game-player-start+)
    (setf (sgeo.physics:body-velocity (game-state-player-body game)) (sgeo.math:vec3)
          (game-state-score game) 0
          (game-state-status game) :playing
          (game-state-door-locked-p game) t
          (game-state-door-open-p game) nil
          (game-state-door-opening-p game) nil
          (game-state-door-opening-time game) 0d0
          (game-state-door-player game) nil
          (game-state-grounded-p game) nil
          (sgeo.simulation:simulation-paused-p (game-state-simulation game)) nil)
    (sgeo.scene:set-position door +game-door-position+)
    (sgeo.scene:set-rotation door (sgeo.math:vec3))
    (dolist (coin (game-state-coins game))
      (setf (game-coin-collected-p coin) nil)
      (dolist (object (list (game-coin-object coin) (game-coin-sensor-object coin)))
        (unless (sgeo.scene:scene-object-world object) (sgeo.scene:add-to-world world object)))
      (unless (member (game-coin-body coin) (sgeo.physics:physics-bodies physics) :test #'eq)
        (sgeo.physics:add-body physics (game-coin-body coin))))
    (sgeo.input:clear-input-state (game-state-input game))
    (sgeo.audio:stop-source (game-state-collect-source game))
    (sgeo.audio:stop-source (game-state-door-source game))
    (sgeo.debug:clear-debug-draw world)
    game))

(defun restart-game (&optional (game *game*))
  "Reinicia partida, transforma, entrada, moedas, porta e relógio fixo."
  (unless (typep game 'game-state) (error "restart-game precisa de um game-state."))
  (%restart-state game)
  (game-state-world game))

(defun %pre-update (world simulation dt game)
  (declare (ignore world dt))
  (let ((input (game-state-input game)))
    (when (sgeo.input:action-pressed-p input :restart)
      (%restart-state game)
      (return-from %pre-update nil))
    (when (sgeo.input:action-pressed-p input :debug)
      (setf (game-state-debug-p game) (not (game-state-debug-p game))))
    (when (sgeo.input:action-pressed-p input :pause)
      (let ((paused (not (sgeo.simulation:simulation-paused-p simulation))))
        (setf (sgeo.simulation:simulation-paused-p simulation) paused
              (game-state-status game) (if paused :paused :playing))))
    (when (and (not (sgeo.simulation:simulation-paused-p simulation))
               (eq (game-state-status game) :playing)
               (sgeo.input:action-pressed-p input :jump)
               (game-state-grounded-p game))
      (let ((velocity (sgeo.physics:body-velocity (game-state-player-body game))))
        (setf (aref velocity 1) 5.5d0
              (sgeo.physics:body-velocity (game-state-player-body game)) velocity
              (game-state-grounded-p game) nil)))
    (when (and (not (sgeo.simulation:simulation-paused-p simulation))
               (eq (game-state-status game) :playing)
               (sgeo.input:action-pressed-p input :interact))
      (cond
        ((and (not (game-state-door-locked-p game))
              (not (game-state-door-open-p game))
              (not (game-state-door-opening-p game))
              (%near-door-p game))
         (setf (game-state-door-opening-p game) t
               (game-state-door-opening-time game) 0d0
               (game-state-door-player game)
               (sgeo.animation:play-animation
                (game-state-world game)
                (sgeo.animation:animate (game-state-door game) :rotation
                                        :from (sgeo.math:vec3)
                                        :to (sgeo.math:vec3 0d0 (/ pi 2d0) 0d0)
                                        :duration 0.7d0 :name "abrir-porta")
                :looping-p nil)))
        ((game-state-door-locked-p game)
         (sgeo.debug:debug-text (game-state-world game) (sgeo.math:vec3 -3d0 3d0 0d0)
                                "PORTA TRANCADA: PEGUE 2 MOEDAS"
                                :color #(1d0 0.3d0 0.2d0) :height 0.38d0 :duration 1d0))))))

(defun %fixed-update (world simulation dt game)
  (declare (ignore world simulation))
  (when (eq (game-state-status game) :playing)
    (let* ((input (game-state-input game))
           (x (max -1d0 (min 1d0 (- (sgeo.input:action-value input :move-right)
                                     (sgeo.input:action-value input :move-left)))))
           (z (max -1d0 (min 1d0 (- (sgeo.input:action-value input :move-backward)
                                     (sgeo.input:action-value input :move-forward)))))
           (length (sqrt (+ (* x x) (* z z))))
           (velocity (sgeo.physics:body-velocity (game-state-player-body game))))
      (when (> length 1d0) (setf x (/ x length) z (/ z length)))
      (setf (aref velocity 0) (* x (game-state-speed game))
            (aref velocity 2) (* z (game-state-speed game))
            (sgeo.physics:body-velocity (game-state-player-body game)) velocity))
    (when (game-state-door-opening-p game)
      (incf (game-state-door-opening-time game) dt)
      (when (>= (game-state-door-opening-time game) 0.7d0)
        (when (game-state-door-body game)
          (sgeo.physics:remove-body (game-state-physics game) (game-state-door-body game)))
        (setf (game-state-door-opening-p game) nil
              (game-state-door-open-p game) t)
        (%play-game-sound (game-state-door-source game) 1.15d0)))
    (when (and (game-state-door-open-p game)
               (>= (game-state-score game) 3)
               (> (sgeo.math:vx (sgeo.physics:body-position (game-state-player-body game))) 5d0))
      (setf (game-state-status game) :won)
      (setf (sgeo.physics:body-velocity (game-state-player-body game)) (sgeo.math:vec3)))))

(defun %post-physics (world simulation dt game)
  (declare (ignore world simulation dt))
  (setf (game-state-grounded-p game) (%grounded-p game)))

(defun %post-update (world simulation dt game)
  (declare (ignore simulation dt))
  (sgeo.debug:clear-debug-draw world)
  (sgeo.debug:debug-text world (sgeo.math:vec3 -6d0 5d0 0d0)
                         (format nil "MOEDAS ~D/3   PORTA ~A   ~A"
                                 (game-state-score game)
                                 (cond ((game-state-door-open-p game) "ABERTA")
                                       ((game-state-door-locked-p game) "TRANCADA")
                                       (t "LIBERADA"))
                                 (string-upcase (symbol-name (game-state-status game))))
                         :color #(1d0 1d0 1d0) :height 0.38d0 :duration 0.1d0)
  (sgeo.debug:debug-text world (sgeo.math:vec3 -6d0 4.35d0 0d0)
                         "WASD/SETAS: ANDAR  ESPACO: PULAR  E: INTERAGIR  P: PAUSAR  R: REINICIAR"
                         :color #(0.8d0 0.85d0 0.9d0) :height 0.27d0 :duration 0.1d0)
  (when (and (game-state-debug-p game) (eq (game-state-status game) :playing))
    (sgeo.debug:debug-sphere world (sgeo.physics:body-position (game-state-player-body game))
                             0.35d0 :color #(0.2d0 0.9d0 1d0) :duration 0.1d0)
    (sgeo.debug:debug-aabb world (sgeo.physics:body-bounds (game-state-player-body game))
                           :color #(0.2d0 1d0 0.3d0) :duration 0.1d0)))

(defun make-game-world ()
  "Cria o jogo tridimensional e retorna WORLD; o segundo valor é seu estado REPL."
  (let* ((world (sgeo.scene:make-world
                 :camera (sgeo.scene:make-camera :eye (sgeo.math:vec3 0d0 11d0 12d0)
                                                 :target (sgeo.math:vec3 0d0 0d0 0d0))))
         (physics (sgeo.physics:make-physics-world :gravity (sgeo.math:vec3 0d0 -9.81d0 0d0)))
         (input (sgeo.input:make-input-state :map 'game-controls))
         (door nil) (door-body nil) (obstacles nil)
         (coins nil) (player nil) (player-body nil))
    ;; Piso, limites e obstáculos usam uma única malha unitária com escala na cena.
    (%add-static-box world physics "Piso" (sgeo.math:vec3 0d0 -0.25d0 0d0)
                     (sgeo.math:vec3 14d0 0.5d0 10d0) #(0.18d0 0.22d0 0.27d0))
    (dolist (spec (list
                   (list "Parede norte" (sgeo.math:vec3 0d0 1.25d0 -4.8d0) (sgeo.math:vec3 14d0 2.5d0 0.4d0))
                   (list "Parede sul" (sgeo.math:vec3 0d0 1.25d0 4.8d0) (sgeo.math:vec3 14d0 2.5d0 0.4d0))
                   (list "Parede oeste" (sgeo.math:vec3 -7.3d0 1.25d0 0d0) (sgeo.math:vec3 0.4d0 2.5d0 9.2d0))
                   (list "Parede leste" (sgeo.math:vec3 7.3d0 1.25d0 0d0) (sgeo.math:vec3 0.4d0 2.5d0 9.2d0))
                   (list "Obstáculo azul" (sgeo.math:vec3 -1.0d0 0.65d0 -1.65d0) (sgeo.math:vec3 1.3d0 1.3d0 1.4d0))
                   (list "Obstáculo verde" (sgeo.math:vec3 2.4d0 0.65d0 -1.35d0) (sgeo.math:vec3 1.1d0 1.3d0 1.5d0))
                   (list "Obstáculo âmbar" (sgeo.math:vec3 4.0d0 0.8d0 1.3d0) (sgeo.math:vec3 0.9d0 1.6d0 1.8d0))))
      (multiple-value-bind (object body)
          (%add-static-box world physics (first spec) (second spec) (third spec)
                           (if (search "azul" (first spec)) #(0.15d0 0.35d0 0.75d0)
                               (if (search "verde" (first spec)) #(0.2d0 0.58d0 0.32d0)
                                   #(0.78d0 0.42d0 0.12d0))))
        (push (cons object body) obstacles)))
    (setf door (%game-box-object "Porta" +game-door-position+ (sgeo.math:vec3 0.36d0 2d0 6d0)
                                #(0.55d0 0.2d0 0.14d0)))
    (%add-visual world door)
    (setf door-body (sgeo.physics:make-rigid-body
                     :object door :shape (sgeo.physics:make-box-shape)
                     :motion-type :static :friction 0.8d0))
    (sgeo.physics:add-body physics door-body)
    (dolist (position +game-coin-positions+)
      (let* ((object (%game-sphere-object "Moeda" position 0.18d0 #(0.98d0 0.72d0 0.12d0)))
             (sensor (sgeo.scene:make-scene-object :name "Sensor de moeda" :position position))
             (body (sgeo.physics:make-rigid-body :object sensor
                                                 :shape (sgeo.physics:make-sphere-shape :radius 0.45d0)
                                                 :motion-type :static :trigger-p t)))
        (%add-visual world object)
        (%add-visual world sensor)
        (sgeo.physics:add-body physics body)
        (push (%make-game-coin :object object :sensor-object sensor :body body) coins)))
    (setf player (%game-sphere-object "Jogador" +game-player-start+ 0.35d0 #(0.12d0 0.72d0 0.92d0)))
    (%add-visual world player)
    (setf player-body (sgeo.physics:make-rigid-body
                       :object player :shape (sgeo.physics:make-sphere-shape :radius 0.35d0)
                       :motion-type :dynamic :mass 1d0 :friction 0.8d0 :restitution 0d0))
    (sgeo.physics:add-body physics player-body)
    (let* ((mixer (sgeo.audio:make-audio-mixer :listener (sgeo.audio:make-listener :object player)))
           (tone (sgeo.audio:make-tone-buffer 880d0 0.09d0))
           (collect-source (sgeo.audio:make-audio-source :buffer tone :object player :gain 0.28d0))
           (door-source (sgeo.audio:make-audio-source :buffer tone :object player :gain 0.2d0))
           (simulation (sgeo.simulation:attach-simulation world :input input :physics physics :audio mixer))
           (game (%make-game-state :world world :player player :player-body player-body
                                   :physics physics :simulation simulation :input input
                                   :score 0 :status :playing :speed 4.5d0
                                   :door-locked-p t :door-open-p nil :door door :door-body door-body
                                   :door-opening-p nil :coins (nreverse coins) :obstacles (nreverse obstacles)
                                   :grounded-p nil :debug-p nil :mixer mixer
                                   :collect-source collect-source :door-source door-source)))
      (sgeo.audio:add-audio-source mixer collect-source)
      (sgeo.audio:add-audio-source mixer door-source)
      (sgeo.simulation:add-phase-hook simulation :pre-update
                                      (lambda (w s dt) (%pre-update w s dt game)))
      (sgeo.simulation:add-phase-hook simulation :fixed-update
                                      (lambda (w s dt) (%fixed-update w s dt game)))
      (sgeo.simulation:add-phase-hook simulation :post-physics
                                      (lambda (w s dt) (%post-physics w s dt game)))
      (sgeo.simulation:add-phase-hook simulation :post-update
                                      (lambda (w s dt) (%post-update w s dt game)))
      (sgeo.simulation:on-event (sgeo.simulation:simulation-events simulation) :begin
                                (lambda (event) (%handle-physics-event game event)))
      (setf *game* game)
      (values world game))))

(defun run-game (&key (width 1280) (height 800) (visible t) (repl t)
                   max-frames capture-path)
  "Abre a partida com controles de jogo e sem chamadas diretas ao áudio nativo."
  (let ((world (make-game-world)))
    (uiop:symbol-call :sgeo.runtime :run-world world :controls :game :width width :height height
                      :visible visible :repl repl :max-frames max-frames
                      :capture-path capture-path :title "S-Geometry: Moedas e Porta")))
