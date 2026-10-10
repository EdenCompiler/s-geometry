(in-package #:sgeo.runtime)

(defun %world-input (world)
  (let ((state (sgeo.scene:world-simulation-state world)))
    (when state (sgeo.simulation:simulation-input state))))
(defun %poll-gamepad-input (window input)
  "Mapeia o primeiro controle reconhecido e libera valores após desconexão."
  (when input
    (let ((state (sgeo.platform:window-gamepad-state window)))
      (dolist (name '(:a :b :x :y :left-bumper :right-bumper :back :start :guide
                     :left-thumb :right-thumb :dpad-up :dpad-right :dpad-down :dpad-left))
        (sgeo.input:queue-input-event input :gamepad-button :code name
          :action (if (member name (getf state :buttons)) :press :release)))
      (dolist (name '(:left-x :left-y :right-x :right-y :left-trigger :right-trigger))
        (sgeo.input:queue-input-event input :gamepad-axis :code name
          :value (or (cdr (assoc name (getf state :axes))) 0d0)))
      ;; Gatilhos expõem pressão analógica e um botão semântico no limiar de 50%.
      (dolist (name '(:left-trigger :right-trigger))
        (sgeo.input:queue-input-event input :gamepad-button :code name
          :action (if (> (or (cdr (assoc name (getf state :axes))) 0d0) 0.5d0)
                      :press :release))))))

(defun %set-selection (world object base-title window)
  (setf (sgeo.scene:world-selection world) object)
  (setf *selection* object)
  (sgeo.platform:set-window-title
   window (if object
             (format nil "~A — ~A" base-title (sgeo.core:object-name object))
             base-title)))

(defun %pick-at-cursor (world window base-title)
  (multiple-value-bind (x y) (sgeo.platform:window-cursor-position window)
    (multiple-value-bind (width height) (sgeo.platform:window-size window)
      (let* ((ray (sgeo.scene:camera-ray world x y (max 1 width) (max 1 height)))
             (object (and ray (first (multiple-value-list (sgeo.scene:ray-cast world ray))))))
        (sgeo.scene:with-world-lock (world)
          (%set-selection world object base-title window))))))

(defun %toggle-wireframe (world)
  (sgeo.scene:with-world-lock (world)
    (let ((materials (make-hash-table :test #'eq)))
      (labels ((visit (object)
                 (when (typep object 'sgeo.scene:mesh-object)
                   (let ((material (sgeo.scene:mesh-object-material object)))
                     (unless (gethash material materials)
                       (setf (gethash material materials) t)
                       (sgeo.scene:set-material-wireframe
                        material (not (sgeo.scene:simple-material-wireframe-p material))))))
                 (dolist (child (sgeo.scene:scene-object-children object)) (visit child))))
        (visit (sgeo.scene:world-root world))))))

(defun %start-listener (world stop-flag)
  (let ((input *standard-input*) (output *standard-output*) (query-io *query-io*)
        (error-output *error-output*) (repl-package *package*))
  (bt:make-thread
   (lambda ()
     (catch 'sgeo-repl-stop
       (let ((*standard-input* input) (*standard-output* output)
             (*query-io* query-io) (*error-output* error-output) (*package* repl-package)
             (*world* world) (*selection* nil))
         (let* ((read-failure (gensym "READ-FAILURE"))
                (history-names '("*" "**" "***" "/" "//" "///" "+" "++" "+++"))
                (history-symbols (mapcar (lambda (name) (intern name repl-package)) history-names)))
           (progv history-symbols (make-list (length history-symbols))
             (loop until (car stop-flag)
               for form = (progn
                            (write-string "sgeo> " *query-io*)
                            (finish-output *query-io*)
                            (handler-case (read *standard-input* nil :eof)
                              (error (condition)
                                (format *error-output* "Erro ao ler a forma: ~A~%" condition)
                                (finish-output *error-output*) read-failure)))
               until (eq form :eof)
               unless (eq form read-failure)
               do (setf (symbol-value (nth 8 history-symbols))
                        (symbol-value (nth 7 history-symbols))
                        (symbol-value (nth 7 history-symbols))
                        (symbol-value (nth 6 history-symbols))
                        (symbol-value (nth 6 history-symbols)) form)
                  (if (eq form :quit)
                      (setf (car stop-flag) t)
                      (handler-case
                          (let ((selection-before
                                  (sgeo.scene:with-world-lock (world)
                                    (sgeo.scene:world-selection world))))
                            (setf *selection* selection-before)
                            (let* ((values (multiple-value-list (eval form)))
                                   (value (first values)))
                              (setf (symbol-value (nth 5 history-symbols))
                                    (symbol-value (nth 4 history-symbols))
                                    (symbol-value (nth 4 history-symbols))
                                    (symbol-value (nth 3 history-symbols))
                                    (symbol-value (nth 3 history-symbols)) values
                                    (symbol-value (nth 2 history-symbols))
                                    (symbol-value (nth 1 history-symbols))
                                    (symbol-value (nth 1 history-symbols))
                                    (symbol-value (nth 0 history-symbols))
                                    (symbol-value (nth 0 history-symbols)) value)
                              (unless (eq *selection* selection-before)
                                (sgeo.scene:with-world-lock (world)
                                  (setf (sgeo.scene:world-selection world) *selection*)))
                              (dolist (item values) (prin1 item) (terpri))
                              (finish-output)))
                        (error (condition)
                          (format *error-output* "Erro na forma; a cena continua ativa: ~A~%" condition)
                          (finish-output *error-output*))))))))
   :name "sgeo interactive listener")))))

(defun run-world (world &key (width 1024) (height 768) (title "S-Geometry")
                             (max-frames nil) (visible t) repl capture-path frame-hook (backend :opengl) validation
                             (controls :viewer) frame-dt)
  "Executa o laço gráfico e devolve WORLD, o renderizador encerrado e o relatório."
  #+sb-thread
  (unless (eq sb-thread:*current-thread* (sb-thread:main-thread))
    (error 'sgeo.core:platform-error :context "thread da janela"
           :message "O laço gráfico precisa iniciar na thread principal."))
  (unless (and (integerp width) (plusp width) (integerp height) (plusp height)
               (or (null max-frames) (and (integerp max-frames) (plusp max-frames)))
               (member controls '(:viewer :game))
               (or (null frame-dt) (and (realp frame-dt) (<= 0 frame-dt most-positive-double-float))))
    (error 'sgeo.core:validation-error :context "parâmetros do runtime"
           :message "Largura, altura e limite de quadros precisam ser inteiros positivos."))
  (setf *world* world
        *selection* (sgeo.scene:with-world-lock (world) (sgeo.scene:world-selection world)))
  (let* ((sgeo.render:*graphics-validation* validation)
         (window nil) (renderer nil) (frame 0) (previous-time 0d0)
         (stop-flag (list nil)) (listener nil) (mouse-x 0d0) (mouse-y 0d0)
         (middle-down nil) (right-down nil) (first-cursor-p t)
         (platform-condition nil) (input (%world-input world)))
    (sgeo.platform:with-native-graphics-environment ()
      (unwind-protect
         (progn
           (sgeo.scene:with-world-lock (world)
             (setf (sgeo.scene:world-running-p world) t))
           (setf window (sgeo.platform:make-window :width width :height height
                                                   :title title :visible visible :backend backend))
           (setf renderer (sgeo.render:create-renderer window) *renderer* renderer)
           (sgeo.scene:with-world-lock (world)
             (%set-selection world *selection* title window))
           (when repl (setf listener (%start-listener world stop-flag)))
           (sgeo.platform:set-key-handler
            window
            (lambda (key scancode action mods)
              (declare (ignore scancode))
              (when input (sgeo.input:queue-input-event input :key :code key :action action :mods mods))
              (when (sgeo.platform:escape-event-p key action)
                (sgeo.platform:request-window-close window))
              (when (and (eq controls :viewer) (eq backend :vulkan) (eq key :r)
                         (sgeo.platform:press-event-p action))
                (sgeo.render:reload-renderer-shaders renderer))
              (when (and (eq controls :viewer) (sgeo.platform:wireframe-event-p key action)
                         (not (car stop-flag)))
                (%toggle-wireframe world))))
           (sgeo.platform:set-mouse-button-handler
            window
            (lambda (button action mods)
              (when input (sgeo.input:queue-input-event input :mouse-button
                            :code (sgeo.platform:mouse-button-kind button) :action action :mods mods))
              (let ((pressed (sgeo.platform:press-event-p action)))
                (case (sgeo.platform:mouse-button-kind button)
                  (:left
                   (when (and pressed (eq controls :viewer)) (%pick-at-cursor world window title)))
                  (:middle
                   (setf middle-down pressed))
                  (:right
                   (setf right-down pressed))))))
           (sgeo.platform:set-cursor-handler
            window
            (lambda (x y)
              (when input (sgeo.input:queue-input-event input :cursor :x x :y y))
              (unless first-cursor-p
                (let ((dx (- x mouse-x)) (dy (- y mouse-y))
                      (camera (sgeo.scene:world-camera world)))
                  (when (or middle-down right-down)
                    (sgeo.scene:with-world-lock (world)
                      (cond
                        (right-down (sgeo.scene:orbit-camera camera (* dx 0.005d0)
                                                             (* dy 0.005d0)))
                        (middle-down (sgeo.scene:pan-camera camera (* dx 0.002d0)
                                                             (* dy -0.002d0)))))))
              (setf mouse-x x mouse-y y first-cursor-p nil))))
           (sgeo.platform:set-scroll-handler
            window
            (lambda (x y)
              (when input (sgeo.input:queue-input-event input :scroll :x x :y y))
              (sgeo.scene:with-world-lock (world)
                (sgeo.scene:zoom-camera (sgeo.scene:world-camera world) (* y -0.1d0)))))
           (sgeo.platform:set-focus-handler window
             (lambda (focused-p)
               (unless focused-p (setf middle-down nil right-down nil))
               (when input (sgeo.input:queue-input-event input :focus :focused-p focused-p))))
           (setf previous-time (sgeo.platform:window-time window))
           (loop until (or (sgeo.platform:window-should-close-p window) (car stop-flag))
                 do (let ((current (%world-input world)))
                      (unless (eq input current)
                        (when input (sgeo.input:clear-input-state input))
                        (setf input current)))
                    (sgeo.platform:poll-events window)
                    (%poll-gamepad-input window input)
                    (let ((selected (sgeo.scene:with-world-lock (world)
                                      (sgeo.scene:world-selection world))))
                      (unless (eq selected *selection*)
                        (%set-selection world selected title window)))
                    (let* ((now (sgeo.platform:window-time window))
                           (dt (if frame-dt (coerce frame-dt 'double-float)
                                   (max 0d0 (min 0.1d0 (- now previous-time))))))
                      (setf previous-time now)
                      (handler-case (sgeo.scene:update-world world dt)
                        (error (condition)
                          (setf platform-condition condition))))
                    (when frame-hook
                      (handler-case (funcall frame-hook world window renderer frame)
                        (error (condition)
                          (setf platform-condition condition))))
                    (multiple-value-bind (fb-width fb-height)
                        (sgeo.platform:framebuffer-size window)
                      (when (and (plusp fb-width) (plusp fb-height))
                        (sgeo.render:render-frame renderer world fb-width fb-height))
                      (when (and capture-path
                                 (if max-frames (= (1+ frame) max-frames) (zerop frame)))
                        (handler-case
                            (sgeo.render:capture-frame renderer window capture-path)
                          (error (condition) (setf platform-condition condition)))
                        (setf capture-path nil))
                      (sgeo.platform:swap-buffers window))
                    (incf frame)
                    (when (and max-frames (>= frame max-frames))
                      (sgeo.platform:request-window-close window)))
           (values world renderer
                   (make-runtime-report :frames (sgeo.render:renderer-frame-count renderer)
                                        :uploads (sgeo.render:renderer-upload-count renderer)
                                        :gpu-meshes (getf (sgeo.render:renderer-info renderer) :gpu-meshes)
                                        :render-error (sgeo.render:renderer-last-error renderer)
                                        :platform-error (or platform-condition
                                                            (sgeo.platform:window-error window)))))
      (setf (car stop-flag) t)
      (when input (sgeo.input:clear-input-state input))
      (setf *renderer* nil)
      (sgeo.scene:with-world-lock (world)
        (setf (sgeo.scene:world-running-p world) nil))
      (when listener
        (when (bt:thread-alive-p listener)
          (ignore-errors
            (bt:interrupt-thread listener
                                 (lambda ()
                                   ;; A thread pode estar iniciando ou já ter saído do CATCH.
                                   (handler-case (throw 'sgeo-repl-stop nil)
                                     (control-error () nil))))))
        (ignore-errors (bt:join-thread listener)))
      (unwind-protect
           (when renderer (sgeo.render:destroy-renderer renderer))
        (when window (sgeo.platform:close-window window)))))))
