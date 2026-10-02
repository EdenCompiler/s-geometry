(in-package #:sgeo.backend.opengl)

(defclass glfw-window (sgeo.platform:platform-window)
  ((native :initarg :native :reader glfw-native-window)
   (closed-p :initform nil :accessor %closed-p)
   (key-handler :initform nil :accessor %key-handler)
   (cursor-handler :initform nil :accessor %cursor-handler)
   (scroll-handler :initform nil :accessor %scroll-handler)
   (mouse-button-handler :initform nil :accessor %mouse-button-handler)
   (character-handler :initform nil :accessor %character-handler)
   (close-handler :initform nil :accessor %close-handler)))

(defvar *glfw-lock* (bt:make-lock "sgeo GLFW"))
(defvar *glfw-users* 0)
(defvar *glfw-initialized-p* nil)
(defvar *glfw-windows* (make-hash-table :test #'eql))

(defmacro with-native-graphics-environment (() &body body)
  "Mascara e restaura armadilhas de ponto flutuante ao chamar os drivers."
  #+sbcl
  `(let ((saved-modes (sb-int:get-floating-point-modes)))
     (unwind-protect
          (progn
            (sb-int:set-floating-point-modes :traps nil)
            ,@body)
       (apply #'sb-int:set-floating-point-modes saved-modes)))
  #-sbcl
  `(progn ,@body))

(defun %native-key (native)
  (cffi:pointer-address native))

(defun %terminate-glfw-on-exit ()
  (bt:with-lock-held (*glfw-lock*)
    (when *glfw-initialized-p*
      (glfw:terminate)
      (setf *glfw-initialized-p* nil *glfw-users* 0)
      (clrhash *glfw-windows*))))

(defun shutdown-opengl-backend ()
  "Encerra GLFW explicitamente quando não há janelas abertas."
  (bt:with-lock-held (*glfw-lock*)
    (when (plusp *glfw-users*)
      (error 'sgeo.core:platform-error :context "encerramento GLFW"
             :message "Feche todas as janelas antes de encerrar o backend."))
    (when *glfw-initialized-p*
      (glfw:terminate)
      (setf *glfw-initialized-p* nil)
      (clrhash *glfw-windows*)))
  nil)

(defun %acquire-glfw ()
  (bt:with-lock-held (*glfw-lock*)
    (unless *glfw-initialized-p*
      (handler-case (glfw:initialize)
        (error (condition)
          (error 'sgeo.core:platform-error :context "inicialização GLFW"
                 :message (princ-to-string condition)))))
      (setf *glfw-initialized-p* t)
      #+sbcl (pushnew #'%terminate-glfw-on-exit sb-ext:*exit-hooks*)
    (incf *glfw-users*)))

(defun %release-glfw ()
  (bt:with-lock-held (*glfw-lock*)
    (when (plusp *glfw-users*)
      (decf *glfw-users*)
      #-sbcl
      (when (zerop *glfw-users*)
        (glfw:terminate)
        (setf *glfw-initialized-p* nil)))))

(defun %dispatch-callback (native slot arguments)
  (let* ((key (%native-key native))
         (window (bt:with-lock-held (*glfw-lock*)
                   (gethash key *glfw-windows*)))
         (function (and window (funcall slot window))))
    (when (and window function (not (%closed-p window)))
      (handler-case (apply function arguments)
        (error (condition)
          (setf (sgeo.platform:window-error window) condition)
          (when (typep condition 'sgeo.core:sgeo-error)
            (warn "Falha em callback da plataforma: ~A" condition)))))))

(glfw:def-key-callback %dispatch-key-callback (native key scancode action mods)
  (%dispatch-callback native #'%key-handler (list key scancode action mods)))
(glfw:def-cursor-pos-callback %dispatch-cursor-callback (native x y)
  (%dispatch-callback native #'%cursor-handler (list x y)))
(glfw:def-scroll-callback %dispatch-scroll-callback (native x y)
  (%dispatch-callback native #'%scroll-handler (list x y)))
(glfw:def-mouse-button-callback %dispatch-mouse-button-callback (native button action mods)
  (%dispatch-callback native #'%mouse-button-handler (list button action mods)))
(glfw:def-window-close-callback %dispatch-close-callback (native)
  (%dispatch-callback native #'%close-handler nil))
(glfw:def-char-callback %dispatch-character-callback (native codepoint)
  (%dispatch-callback native #'%character-handler (list codepoint)))

(defun %register-window-callbacks (window)
  (let ((native (glfw-native-window window)))
    (bt:with-lock-held (*glfw-lock*)
      (setf (gethash (%native-key native) *glfw-windows*) window))
    (glfw:set-key-callback '%dispatch-key-callback native)
    (glfw:set-cursor-position-callback '%dispatch-cursor-callback native)
    (glfw:set-scroll-callback '%dispatch-scroll-callback native)
    (glfw:set-mouse-button-callback '%dispatch-mouse-button-callback native)
    (glfw:set-window-close-callback '%dispatch-close-callback native))
  (glfw:set-char-callback '%dispatch-character-callback (glfw-native-window window))
  window)

(defun %unregister-window-callbacks (window)
  (bt:with-lock-held (*glfw-lock*)
    (remhash (%native-key (glfw-native-window window)) *glfw-windows*))
  window)

(defun make-glfw-window (&rest arguments)
  (apply #'sgeo.platform:make-window arguments))

(defun initialize-opengl-backend ()
  "Valida que o contexto atual exponha a versão OpenGL exigida pelo renderizador."
  (let ((version (gl:get-string :version)))
    (unless (and version (>= (gl:major-version) 3)
                 (or (> (gl:major-version) 3) (>= (gl:minor-version) 3)))
      (error 'sgeo.core:render-error :context "inicialização OpenGL"
             :message (format nil "OpenGL 3.3 ou superior é necessário; disponível: ~A." version)))
    version))

(defmethod sgeo.platform:make-window (&key (width 1024) (height 768)
                                           (title "S-Geometry") (visible t))
  (unless (and (integerp width) (plusp width) (integerp height) (plusp height))
    (error 'sgeo.core:validation-error :context "janela GLFW"
           :message "Largura e altura precisam ser inteiros positivos."))
  (%acquire-glfw)
  (let ((native nil) (window nil) (registered nil))
    (handler-case
        (progn
          (setf native
                (glfw:create-window :width width :height height :title title
                                    :visible visible :context-version-major 3
                                    :context-version-minor 3
                                    :opengl-profile :opengl-core-profile
                                    #+darwin :opengl-forward-compat #+darwin t))
          (glfw:make-context-current native)
          (glfw:swap-interval (if visible 1 0))
          (initialize-opengl-backend)
          (setf window (make-instance 'glfw-window :native native :title title
                                      :visible-p visible))
          (%register-window-callbacks window)
          (setf registered t)
          (when visible (glfw:show-window native))
          window)
      (error (condition)
        (when registered (%unregister-window-callbacks window))
        (when native (ignore-errors (glfw:destroy-window native)))
        (%release-glfw)
        (error (if (typep condition 'sgeo.core:sgeo-error)
                   condition
                   (make-condition 'sgeo.core:platform-error
                                   :context "criação da janela"
                                   :message (princ-to-string condition))))))))

(defmethod sgeo.platform:poll-events ((window glfw-window))
  (declare (ignore window))
  (glfw:poll-events))

(defmethod sgeo.platform:window-size ((window glfw-window))
  (destructuring-bind (width height) (glfw:get-window-size (glfw-native-window window))
    (values width height)))
(defmethod sgeo.platform:framebuffer-size ((window glfw-window))
  (destructuring-bind (width height) (glfw:get-framebuffer-size (glfw-native-window window))
    (values width height)))
(defmethod sgeo.platform:window-should-close-p ((window glfw-window))
  (glfw:window-should-close-p (glfw-native-window window)))
(defmethod sgeo.platform:request-window-close ((window glfw-window))
  (glfw:set-window-should-close (glfw-native-window window) t)
  window)
(defmethod sgeo.platform:swap-buffers ((window glfw-window))
  (glfw:swap-buffers (glfw-native-window window))
  window)
(defmethod sgeo.platform:set-window-title ((window glfw-window) title)
  (glfw:set-window-title title (glfw-native-window window))
  title)
(defmethod sgeo.platform:window-time ((window glfw-window))
  (declare (ignore window))
  (glfw:get-time))
(defmethod sgeo.platform:window-cursor-position ((window glfw-window))
  (destructuring-bind (x y) (glfw:get-cursor-position (glfw-native-window window))
    (values x y)))

(defmethod sgeo.platform:escape-event-p (key action)
  (and (eq key :escape) (eq action :press)))
(defmethod sgeo.platform:press-event-p (action) (eq action :press))
(defmethod sgeo.platform:mouse-button-kind (button)
  (case button
    ((:left :1) :left)
    ((:3) :middle)
    ((:right :2) :right)
    (otherwise nil)))
(defmethod sgeo.platform:wireframe-event-p (key action)
  (and (eq key :w) (eq action :press)))

(defmethod sgeo.platform:close-window ((window glfw-window))
  (unless (%closed-p window)
    (%unregister-window-callbacks window)
    (setf (%closed-p window) t)
    (unwind-protect
         (glfw:destroy-window (glfw-native-window window))
      (%release-glfw)))
  window)

(defmethod sgeo.platform:set-key-handler ((window glfw-window) function)
  (setf (%key-handler window) function)
  window)
(defmethod sgeo.platform:set-cursor-handler ((window glfw-window) function)
  (setf (%cursor-handler window) function)
  window)
(defmethod sgeo.platform:set-scroll-handler ((window glfw-window) function)
  (setf (%scroll-handler window) function)
  window)
(defmethod sgeo.platform:set-mouse-button-handler ((window glfw-window) function)
  (setf (%mouse-button-handler window) function)
  window)
(defmethod sgeo.platform:set-close-handler ((window glfw-window) function)
  (setf (%close-handler window) function)
  window)
(defmethod sgeo.platform:set-character-handler ((window glfw-window) function)
  (setf (%character-handler window) function)
  window)
