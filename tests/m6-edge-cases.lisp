(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %m6-shape (kind)
  (ecase kind
    (:sphere (sgeo.physics:make-sphere-shape :radius 0.5d0))
    (:box (sgeo.physics:make-box-shape :half-extents #(0.5d0 0.5d0 0.5d0)))
    (:capsule (sgeo.physics:make-capsule-shape :radius 0.5d0 :half-height 0.5d0))))

(defun %m6-body (kind position &key (motion-type :static) (shape nil shape-p))
  (sgeo.physics:make-rigid-body
   :object (sgeo.scene:make-scene-object :position position)
   :shape (if shape-p shape (%m6-shape kind)) :motion-type motion-type))

(test m6-all-ordered-shape-pairs-return-oriented-finite-contacts
  (dolist (kind-a '(:sphere :box :capsule))
    (dolist (kind-b '(:sphere :box :capsule))
      (let* ((a (%m6-body kind-a #(0d0 0d0 0d0)))
             (b (%m6-body kind-b #(0.8d0 0d0 0d0)))
             (ab (sgeo.physics:overlap-bodies a b))
             (ba (sgeo.physics:overlap-bodies b a)))
        (is (not (null ab)))
        (is (not (null ba)))
        (when (and ab ba)
          (is (eq a (sgeo.physics:contact-body-a ab)))
          (is (eq b (sgeo.physics:contact-body-b ab)))
          (is (approximately= (sgeo.physics:contact-depth ab)
                              (sgeo.physics:contact-depth ba)))
          (is (approximately= 1d0 (sgeo.math:vector-length
                                    (sgeo.physics:contact-normal ab))))
          (is (approximately= 1d0 (sgeo.math:vector-length
                                    (sgeo.physics:contact-normal ba))))
          (is (< 0d0 (sgeo.math:vx (sgeo.physics:contact-normal ab))))
          (is (> 0d0 (sgeo.math:vx (sgeo.physics:contact-normal ba)))))))))

(test m6-enclosed-sphere-and-capsule-have-usable-separation-normals
  (let* ((large-box (%m6-body :box #(0d0 0d0 0d0)
                              :shape (sgeo.physics:make-box-shape
                                      :half-extents #(2d0 2d0 2d0))))
         (sphere (%m6-body :sphere #(0d0 0d0 0d0)))
         (capsule (%m6-body :capsule #(0d0 0d0 0d0)
                            :shape (sgeo.physics:make-capsule-shape
                                    :radius 0.25d0 :half-height 0.5d0))))
    (dolist (pair (list (list sphere large-box 2.5d0)
                        (list large-box sphere 2.5d0)
                        (list capsule large-box 1.75d0)
                        (list large-box capsule 1.75d0)))
      (let* ((contact (sgeo.physics:overlap-bodies (first pair) (second pair)))
             (normal (and contact (sgeo.physics:contact-normal contact))))
        (is (not (null contact)))
        (when contact
          (is (approximately= (third pair) (sgeo.physics:contact-depth contact)))
          (is (approximately= 1d0 (sgeo.math:vector-length normal)))
          (is (approximately= 1d0
                              (max (abs (sgeo.math:vx normal))
                                   (abs (sgeo.math:vy normal))
                                   (abs (sgeo.math:vz normal))))))))))

(test m6-capsule-box-segment-distance-does-not-use-aabb-as-narrow-phase
  (let* ((box (%m6-body :box #(0d0 0d0 0d0)))
         (touching (%m6-body :capsule #(0.59d0 0d0 0d0)
                             :shape (sgeo.physics:make-capsule-shape
                                     :radius 0.1d0 :half-height 2d0)))
         (separated (%m6-body :capsule #(0.61d0 0d0 0d0)
                              :shape (sgeo.physics:make-capsule-shape
                                      :radius 0.1d0 :half-height 2d0))))
    (is (sgeo.physics:overlap-bodies touching box))
    (is (approximately= 0.01d0
                         (sgeo.physics:contact-depth
                          (sgeo.physics:overlap-bodies touching box)) 1d-6))
    (is (null (sgeo.physics:overlap-bodies separated box)))
    (is (null (sgeo.physics:overlap-bodies box separated)))))

(test m6-capsule-ray-hits-cylinder-caps-and-inside-exit
  (let* ((world (sgeo.physics:make-physics-world :gravity #(0d0 0d0 0d0)))
         (capsule (%m6-body :capsule #(0d0 0d0 0d0)
                            :shape (sgeo.physics:make-capsule-shape
                                    :radius 0.5d0 :half-height 1d0))))
    (sgeo.physics:add-body world capsule)
    (multiple-value-bind (hit distance point normal)
        (sgeo.physics:physics-ray-cast world
                                       (sgeo.math:make-ray #(2d0 0d0 0d0) #(-1d0 0d0 0d0)))
      (is (eq hit capsule))
      (is (approximately= 1.5d0 distance))
      (is (vector-approximately= #(0.5d0 0d0 0d0) point))
      (is (vector-approximately= #(1d0 0d0 0d0) normal)))
    (multiple-value-bind (hit distance point normal)
        (sgeo.physics:physics-ray-cast world
                                       (sgeo.math:make-ray #(0d0 3d0 0d0) #(0d0 -1d0 0d0)))
      (is (eq hit capsule))
      (is (approximately= 1.5d0 distance))
      (is (vector-approximately= #(0d0 1.5d0 0d0) point))
      (is (vector-approximately= #(0d0 1d0 0d0) normal)))
    (multiple-value-bind (hit distance point normal)
        (sgeo.physics:physics-ray-cast world
                                       (sgeo.math:make-ray #(0d0 0d0 0d0) #(1d0 0d0 0d0)))
      (is (eq hit capsule))
      (is (approximately= 0.5d0 distance))
      (is (vector-approximately= #(0.5d0 0d0 0d0) point))
      (is (vector-approximately= #(1d0 0d0 0d0) normal)))))

(test m6-rotated-box-ray-and-parent-reparent-keep-world-physics-position
  (let* ((parent-a (sgeo.scene:make-scene-object :position #(10d0 0d0 0d0)
                                                   :scale #(2d0 2d0 2d0)))
         (parent-b (sgeo.scene:make-scene-object :position #(-4d0 0d0 0d0)
                                                   :scale #(2d0 2d0 2d0)))
         (object (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)
                                                :rotation (sgeo.math:make-vec3
                                                           0d0 0d0 (/ pi 4d0))))
         (body (sgeo.physics:make-rigid-body :object object
                                             :shape (sgeo.physics:make-box-shape)
                                             :motion-type :kinematic))
         (world (sgeo.physics:make-physics-world :gravity #(0d0 0d0 0d0))))
    (sgeo.scene:add-child parent-a object)
    (is (vector-approximately= #(12d0 0d0 0d0) (sgeo.physics:body-position body)))
    (sgeo.scene:reparent object parent-b :keep-world-transform t)
    (is (vector-approximately= #(12d0 0d0 0d0) (sgeo.physics:body-position body)))
    (sgeo.physics:add-body world body)
    (sgeo.physics:move-body body #(14d0 0d0 0d0))
    (is (vector-approximately= #(14d0 0d0 0d0) (sgeo.physics:body-position body)))
    (multiple-value-bind (hit distance point normal)
        (sgeo.physics:physics-ray-cast
         (let ((ray-world (sgeo.physics:make-physics-world :gravity #(0d0 0d0 0d0))))
           (sgeo.physics:add-body ray-world body)
           ray-world)
         (sgeo.math:make-ray #(16d0 0d0 0d0) #(-1d0 0d0 0d0)))
      (is (eq hit body))
      (is (approximately= (- 2d0 (sqrt 2d0)) distance 1d-6))
      (is (approximately= (+ 14d0 (sqrt 2d0)) (sgeo.math:vx point) 1d-6))
      (is (approximately= 0.7071067811865475d0 (sgeo.math:vx normal) 1d-6)))))

(test m6-dynamic-body-step-writes-world-motion-through-parent
  (let* ((parent (sgeo.scene:make-scene-object :position #(5d0 3d0 0d0)
                                                 :scale #(2d0 2d0 2d0)))
         (object (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
         (body (sgeo.physics:make-rigid-body :object object
                                             :shape (sgeo.physics:make-sphere-shape)
                                             :velocity #(2d0 0d0 0d0)))
         (world (sgeo.physics:make-physics-world :gravity #(0d0 0d0 0d0))))
    (sgeo.scene:add-child parent object)
    (sgeo.physics:add-body world body)
    (sgeo.physics:step-physics world 0.25d0)
    (is (vector-approximately= #(7.5d0 3d0 0d0) (sgeo.physics:body-position body)))
    (is (vector-approximately= #(2d0 0d0 0d0) (sgeo.physics:body-velocity body)))))

(test m6-editor-transaction-undo-redo-updates-live-body-parent-transform
  (let* ((root (sgeo.scene:make-scene-object))
         (parent (sgeo.scene:make-scene-object))
         (object (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
         (world (sgeo.scene:make-world :root root))
         (editor (sgeo.editor:make-editor :world world))
         (body (sgeo.physics:make-rigid-body :object object
                                             :shape (sgeo.physics:make-sphere-shape)
                                             :motion-type :kinematic)))
    (unwind-protect
         (progn
           (sgeo.scene:add-child root parent)
           (sgeo.scene:add-child parent object)
           (sgeo.editor:call-with-edit-transaction
            editor "mover pai" (lambda () (sgeo.scene:set-position parent #(5d0 0d0 0d0))))
           (is (vector-approximately= #(6d0 0d0 0d0) (sgeo.physics:body-position body)))
           (sgeo.editor:undo-edit editor)
           (is (vector-approximately= #(1d0 0d0 0d0) (sgeo.physics:body-position body)))
           (sgeo.editor:redo-edit editor)
           (is (vector-approximately= #(6d0 0d0 0d0) (sgeo.physics:body-position body))))
      (sgeo.editor:close-editor editor))))

(test m6-physics-public-mutators-reject-nonfinite-and-invalid-time-values
  (let* ((object (sgeo.scene:make-scene-object))
         (body (sgeo.physics:make-rigid-body :object object
                                             :shape (sgeo.physics:make-sphere-shape)))
         (world (sgeo.physics:make-physics-world)))
    (signals error (setf (sgeo.physics:body-velocity body) #(1d0 "bad" 0d0)))
    (signals error (sgeo.physics:apply-force body #(0d0 nil 0d0)))
    (signals error (sgeo.physics:make-physics-world :gravity #(0d0 0d0 "bad")))
    (signals error (sgeo.physics:step-physics world 0d0))
    (signals error (sgeo.physics:step-physics world -0.1d0))
    (signals error (sgeo.physics:physics-ray-cast
                    world (sgeo.math:make-ray #(0d0 0d0 0d0) #(1d0 0d0 0d0))
                    :max-distance -1d0))))

(sgeo.input:define-input-map m6-edge-input-game
  (:fire (:gamepad-button :south) (:key :f :mods (:shift)))
  (:alternate-fire (:gamepad-button :south))
  (:move (:gamepad-axis :left-x :positive))
  (:wheel (:scroll :x :both) (:scroll :y :both)))

(sgeo.input:define-input-map m6-edge-input-modal
  (:confirm (:key :enter))
  (:fire (:gamepad-button :south)))

(test m6-quick-tap-and-multiple-edges-survive-fixed-substep-queries
  (let ((input (sgeo.input:make-input-state :map 'm6-edge-input-game)))
    (sgeo.input:queue-input-event input :key :code :f :action :press :mods '(:shift))
    (sgeo.input:queue-input-event input :key :code :f :action :release :mods nil)
    (sgeo.input:queue-input-event input :key :code :f :action :press :mods '(:shift))
    (sgeo.input:begin-input-frame input)
    (is (sgeo.input:action-down-p input :fire))
    (is (sgeo.input:action-pressed-p input :fire))
    (is (sgeo.input:action-released-p input :fire))
    ;; Leitura repetida antes de cada passo fixo do mesmo frame é estável.
    (dotimes (i 6)
      (declare (ignore i))
      (is (sgeo.input:action-pressed-p input :fire))
      (is (sgeo.input:action-released-p input :fire)))
    (sgeo.input:end-input-frame input)
    (sgeo.input:begin-input-frame input)
    (is (sgeo.input:action-down-p input :fire))
    (is (not (sgeo.input:action-pressed-p input :fire)))
    (is (not (sgeo.input:action-released-p input :fire)))))

(test m6-duplicate-held-gamepad-polls-and-repeat-events-do-not-retrigger
  (let ((input (sgeo.input:make-input-state :map 'm6-edge-input-game)))
    (sgeo.input:queue-input-event input :gamepad-button :button :south :action :press)
    (sgeo.input:queue-input-event input :gamepad-button :button :south :action :press)
    (sgeo.input:begin-input-frame input)
    (is (sgeo.input:action-down-p input :fire))
    (is (sgeo.input:action-pressed-p input :fire))
    (is (not (sgeo.input:action-released-p input :fire)))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :gamepad-button :button :south :action :press)
    (sgeo.input:queue-input-event input :gamepad-button :button :south :action :repeat)
    (sgeo.input:begin-input-frame input)
    (is (sgeo.input:action-down-p input :fire))
    (is (not (sgeo.input:action-pressed-p input :fire)))
    (is (not (sgeo.input:action-released-p input :fire)))))

(test m6-focus-loss-emits-release-even-after-press-in-the-same-frame
  (let ((input (sgeo.input:make-input-state :map 'm6-edge-input-game)))
    (sgeo.input:queue-input-event input :gamepad-button :button :south :action :press)
    (sgeo.input:queue-input-event input :focus-lost)
    (sgeo.input:begin-input-frame input)
    (is (not (sgeo.input:action-down-p input :fire)))
    (is (sgeo.input:action-pressed-p input :fire))
    (is (sgeo.input:action-released-p input :fire))))

(test m6-context-consumption-and-context-change-with-held-control
  (let ((input (sgeo.input:make-input-state :map 'm6-edge-input-game)))
    (sgeo.input:queue-input-event input :gamepad-button :button :south :action :press)
    (sgeo.input:begin-input-frame input)
    (is (sgeo.input:action-down-p input :fire))
    (sgeo.input:end-input-frame input)
    (sgeo.input:begin-input-frame input)
    (is (not (sgeo.input:action-pressed-p input :fire)))
    (sgeo.input:end-input-frame input)
    (sgeo.input:push-input-context input 'm6-edge-input-modal :consume t)
    (is (not (sgeo.input:action-down-p input :alternate-fire)))
    (is (sgeo.input:action-down-p input :fire))
    ;; Mudanças de contexto não são eventos de hardware, mas sua ação deve
    ;; voltar a refletir o botão ainda pressionado ao retirar o modal.
    (sgeo.input:pop-input-context input 'm6-edge-input-modal)
    (is (sgeo.input:action-down-p input :alternate-fire))
    (is (sgeo.input:action-down-p input :fire))
    (is (not (sgeo.input:action-pressed-p input :fire)))
    (is (not (sgeo.input:action-released-p input :fire)))))

(test m6-modifier-chords-axis-directions-and-scroll-reset-per-frame
  (let ((input (sgeo.input:make-input-state :map 'm6-edge-input-game :deadzone 0.25d0)))
    (sgeo.input:queue-input-event input :key :code :f :action :press :mods nil)
    (sgeo.input:begin-input-frame input)
    (is (not (sgeo.input:action-down-p input :fire)))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :key :code :f :action :release :mods nil)
    (sgeo.input:queue-input-event input :key :code :f :action :press :mods '(:shift))
    (sgeo.input:begin-input-frame input)
    (is (sgeo.input:action-down-p input :fire))
    (is (sgeo.input:action-pressed-p input :fire))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :key :code :shift :action :release :mods nil)
    (sgeo.input:queue-input-event input :gamepad-axis :axis :left-x :value 0.5d0)
    (sgeo.input:queue-input-event input :scroll :x -3d0 :y 2d0)
    (sgeo.input:begin-input-frame input)
    (is (not (sgeo.input:action-down-p input :fire)))
    (is (sgeo.input:action-released-p input :fire))
    (is (approximately= (/ 1d0 3d0) (sgeo.input:action-value input :move)))
    (is (equal '(-3d0 . 2d0) (sgeo.input:input-scroll-delta input)))
    (sgeo.input:end-input-frame input)
    (sgeo.input:begin-input-frame input)
    (is (equal '(0d0 . 0d0) (sgeo.input:input-scroll-delta input)))
    (is (not (sgeo.input:action-pressed-p input :wheel)))))
