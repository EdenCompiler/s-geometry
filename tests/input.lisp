(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(sgeo.input:define-input-map input-test-gameplay
  (:move-forward (:key :w) (:gamepad-axis :left-y :positive))
  (:fire (:mouse-button :left) (:gamepad-button :right-trigger))
  (:zoom-in (:scroll :y :positive)))

(sgeo.input:define-input-map input-test-overlay
  (:menu-confirm (:key :enter))
  (:menu-fire (:mouse-button :left)))

(test input-events-have-frame-stable-transitions
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay)))
    (sgeo.input:queue-input-event input :key :code :w :action :press :mods nil)
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-down-p input :move-forward))
    (is-true (sgeo.input:action-pressed-p input :move-forward))
    ;; A repeat mantém a tecla pressionada sem gerar uma segunda borda.
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :key :code :w :action :repeat :mods nil)
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-down-p input :move-forward))
    (is-false (sgeo.input:action-pressed-p input :move-forward))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :key :code :w :action :release :mods nil)
    (sgeo.input:begin-input-frame input)
    (is-false (sgeo.input:action-down-p input :move-forward))
    (is-true (sgeo.input:action-released-p input :move-forward))))

(test input-quick-taps-preserve-both-transition-edges
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay)))
    (sgeo.input:queue-input-event input :key :code :w :action :press :mods nil)
    (sgeo.input:queue-input-event input :key :code :w :action :release :mods nil)
    (sgeo.input:begin-input-frame input)
    (is-false (sgeo.input:action-down-p input :move-forward))
    (is-true (sgeo.input:action-pressed-p input :move-forward))
    (is-true (sgeo.input:action-released-p input :move-forward))))

(test repeated-gamepad-polls-do-not-repeat-pressed-edges
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay)))
    (sgeo.input:queue-input-event input :gamepad-button :code :right-trigger :action :press)
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-pressed-p input :fire))
    (sgeo.input:end-input-frame input)
    ;; O backend pode enviar :PRESS em cada poll enquanto o botão fica mantido.
    (sgeo.input:queue-input-event input :gamepad-button :code :right-trigger :action :press)
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-down-p input :fire))
    (is-false (sgeo.input:action-pressed-p input :fire))))

(test input-contexts-capture-lower-priority-bindings
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay)))
    (sgeo.input:push-input-context input 'input-test-overlay)
    (is (equal '(input-test-overlay input-test-gameplay)
               (sgeo.input:active-input-contexts input)))
    (sgeo.input:queue-input-event input :mouse-button :button :left :action :press)
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-down-p input :menu-fire))
    (is-false (sgeo.input:action-down-p input :fire))
    (sgeo.input:pop-input-context input 'input-test-overlay)
    (is (equal '(input-test-gameplay) (sgeo.input:active-input-contexts input)))
    (is-true (sgeo.input:action-down-p input :fire))))

(test input-rebinding-and-modifier-chords
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay)))
    (sgeo.input:bind-action input :fire '((:key :f :mods (:shift))))
    (sgeo.input:queue-input-event input :key :code :f :action :press :mods nil)
    (sgeo.input:begin-input-frame input)
    (is-false (sgeo.input:action-down-p input :fire))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :key :code :f :action :release :mods nil)
    (sgeo.input:queue-input-event input :key :code :f :action :press :mods '(:shift))
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-down-p input :fire))
    (is-true (sgeo.input:action-pressed-p input :fire))
    (sgeo.input:unbind-action input :fire)
    (is-false (sgeo.input:action-down-p input :fire))))

(test input-axis-deadzone-direction-and-cursor-scroll
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay :deadzone 0.2d0)))
    (sgeo.input:queue-input-event input :gamepad-axis :code :left-y :value 0.1d0)
    (sgeo.input:begin-input-frame input)
    (is-false (sgeo.input:action-down-p input :move-forward))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :gamepad-axis :code :left-y :value 0.6d0)
    (sgeo.input:queue-input-event input :cursor :x 10 :y 20)
    (sgeo.input:queue-input-event input :scroll :x 0 :y 2)
    (sgeo.input:begin-input-frame input)
    (is (approximately= 0.5d0 (sgeo.input:action-value input :move-forward)))
    (is (equal '(10 . 20) (sgeo.input:input-cursor-position input)))
    (is (equal '(0d0 . 2d0) (sgeo.input:input-scroll-delta input)))
    (is-true (sgeo.input:action-pressed-p input :zoom-in))))

(test focus-loss-releases-all-held-actions
  (let ((input (sgeo.input:make-input-state :map 'input-test-gameplay)))
    (sgeo.input:queue-input-event input :gamepad-button :button :right-trigger :action :press)
    (sgeo.input:begin-input-frame input)
    (is-true (sgeo.input:action-down-p input :fire))
    (sgeo.input:end-input-frame input)
    (sgeo.input:queue-input-event input :focus :focused-p nil)
    (sgeo.input:begin-input-frame input)
    (is-false (sgeo.input:action-down-p input :fire))
    (is-true (sgeo.input:action-released-p input :fire))))
