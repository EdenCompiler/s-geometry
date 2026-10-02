(in-package #:sgeo.runtime)

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
                             (max-frames nil) (visible t) repl capture-path frame-hook)
  "Executa o laço gráfico e devolve WORLD, o renderizador encerrado e o relatório."
  #+sb-thread
  (unless (eq sb-thread:*current-thread* (sb-thread:main-thread))
    (error 'sgeo.core:platform-error :context "thread da janela"
           :message "O loop GLFW/OpenGL precisa iniciar na thread principal."))
  (unless (and (integerp width) (plusp width) (integerp height) (plusp height)
               (or (null max-frames) (and (integerp max-frames) (plusp max-frames))))
    (error 'sgeo.core:validation-error :context "parâmetros do runtime"
           :message "Largura, altura e limite de quadros precisam ser inteiros positivos."))
  (setf *world* world
        *selection* (sgeo.scene:with-world-lock (world) (sgeo.scene:world-selection world)))
  (let* ((window nil) (renderer nil) (frame 0) (previous-time 0d0)
         (stop-flag (list nil)) (listener nil) (mouse-x 0d0) (mouse-y 0d0)
         (middle-down nil) (right-down nil) (first-cursor-p t)
         (platform-condition nil))
    (sgeo.backend.opengl:with-native-graphics-environment ()
      (unwind-protect
         (progn
           (sgeo.scene:with-world-lock (world)
             (setf (sgeo.scene:world-running-p world) t))
           (setf window (sgeo.platform:make-window :width width :height height
                                                   :title title :visible visible))
           (setf renderer (sgeo.render:create-renderer window))
           (sgeo.scene:with-world-lock (world)
             (%set-selection world *selection* title window))
           (when repl (setf listener (%start-listener world stop-flag)))
           (sgeo.platform:set-key-handler
            window
            (lambda (key scancode action mods)
              (declare (ignore scancode mods))
              (when (sgeo.platform:escape-event-p key action)
                (sgeo.platform:request-window-close window))
              (when (and (sgeo.platform:wireframe-event-p key action)
                         (not (car stop-flag)))
                (%toggle-wireframe world))))
           (sgeo.platform:set-mouse-button-handler
            window
            (lambda (button action mods)
              (declare (ignore mods))
              (let ((pressed (sgeo.platform:press-event-p action)))
                (case (sgeo.platform:mouse-button-kind button)
                  (:left
                   (when pressed (%pick-at-cursor world window title)))
                  (:middle
                   (setf middle-down pressed))
                  (:right
                   (setf right-down pressed))))))
           (sgeo.platform:set-cursor-handler
            window
            (lambda (x y)
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
              (declare (ignore x))
              (sgeo.scene:with-world-lock (world)
                (sgeo.scene:zoom-camera (sgeo.scene:world-camera world) (* y -0.1d0)))))
           (setf previous-time (sgeo.platform:window-time window))
           (loop until (or (sgeo.platform:window-should-close-p window) (car stop-flag))
                 do (sgeo.platform:poll-events window)
                    (let ((selected (sgeo.scene:with-world-lock (world)
                                      (sgeo.scene:world-selection world))))
                      (unless (eq selected *selection*)
                        (%set-selection world selected title window)))
                    (let* ((now (sgeo.platform:window-time window))
                           (dt (max 0d0 (min 0.1d0 (- now previous-time)))))
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
                      (unless (zerop fb-width)
                        (sgeo.render:render-frame renderer world fb-width fb-height))
                      (when (and capture-path
                                 (if max-frames (= (1+ frame) max-frames) (zerop frame)))
                        (handler-case
                            (sgeo.backend.opengl:capture-framebuffer-ppm window capture-path)
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
      (sgeo.scene:with-world-lock (world)
        (setf (sgeo.scene:world-running-p world) nil))
      (when listener
        (when (bt:thread-alive-p listener)
          (ignore-errors
            (bt:interrupt-thread listener
                                 (lambda () (throw 'sgeo-repl-stop nil)))))
        (ignore-errors (bt:join-thread listener)))
      (when renderer (ignore-errors (sgeo.render:destroy-renderer renderer)))
      (when window (ignore-errors (sgeo.platform:close-window window)))))))
