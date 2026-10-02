(in-package #:sgeo.editor)

(defvar *mutation-dispatch-editor* nil)

(defclass editor-state ()
  ((world :initarg :world :accessor editor-world)
   (owner :initform (bt:current-thread) :accessor %editor-owner)
   (running-p :initform nil :accessor editor-running-p)
   (closed-p :initform nil :accessor %editor-closed-p)
   (lock :initform (bt:make-recursive-lock "sgeo editor") :reader %editor-lock)
   (requests :initform nil :accessor %editor-requests)
   (selection-mode :initform :object :accessor editor-selection-mode)
   (elements :initform nil :accessor editor-elements)
   (view :initform :perspective :accessor editor-view)
   (layout :initform :modeling :accessor editor-layout)
   (tool :initform :translate :accessor editor-tool)
   (inspected :initform nil :accessor editor-inspected)
   (inspect-stack :initform nil :accessor %inspect-stack)
   (status :initform "Ready" :accessor editor-status)
   (history :initform nil :accessor editor-history)
   (undo-stack :initform nil :accessor editor-undo-stack)
   (redo-stack :initform nil :accessor editor-redo-stack)
   (transaction-depth :initform 0 :accessor %transaction-depth)
   (scene-path :initarg :scene-path :initform "scene.sgeo" :accessor editor-scene-path)
   (listener-input :initform "" :accessor editor-listener-input)
   (listener-output :initform nil :accessor editor-listener-output)
   (listener-thread :initform nil :accessor %listener-thread)
   (listener-forms :initform nil :accessor %listener-forms)
   (listener-ready :initform (bt:make-condition-variable) :reader %listener-ready)
   (listener-busy :initform nil :accessor %listener-busy)
   (profile :initform nil :accessor editor-profile)
   (time :initform 0d0 :accessor editor-time)
   (playing-p :initform nil :accessor editor-playing-p)
   (time-scale :initform 1d0 :accessor editor-time-scale))
  (:documentation "Vistas, comandos e histórico sobre o mesmo mundo Lisp vivo."))
(defstruct editor-request function result condition done-p
  (lock (bt:make-lock "sgeo owner request"))
  (ready (bt:make-condition-variable)))
(defstruct (editor-command (:conc-name command-)) name arguments label form before after)
(defstruct editor-snapshot root camera selection records meshes materials)

(defun make-editor (&key world (scene-path "scene.sgeo"))
  "Cria o estado do editor sem carregar bibliotecas gráficas."
  (let ((editor (make-instance 'editor-state :world (or world (sgeo.scene:make-world))
                               :scene-path scene-path)))
    (setf (editor-inspected editor) (sgeo.scene:world-root (editor-world editor)))
    editor))

(defun editor-objects (editor)
  "Retorna a hierarquia na ordem de exibição, incluindo a raiz."
  (sgeo.scene:with-world-lock ((editor-world editor))
    (labels ((walk (object)
               (cons object (mapcan #'walk (sgeo.scene:scene-object-children object)))))
      (walk (sgeo.scene:world-root (editor-world editor))))))

(defun call-in-editor (editor function)
  "Executa uma operação no proprietário ou aguarda sua passagem pela fila."
  (when (%editor-closed-p editor)
    (error 'sgeo.core:validation-error :context "editor encerrado"
           :message "O editor foi encerrado antes da operação."))
  (if (eq (bt:current-thread) (%editor-owner editor))
      (funcall function)
      (let ((request (make-editor-request :function function)))
        (bt:with-recursive-lock-held ((%editor-lock editor))
          (when (%editor-closed-p editor) (error "O editor foi encerrado."))
          (setf (%editor-requests editor) (nconc (%editor-requests editor) (list request))))
        (bt:with-lock-held ((editor-request-lock request))
          (loop until (editor-request-done-p request)
                do (bt:condition-wait (editor-request-ready request) (editor-request-lock request)))
          (when (editor-request-condition request) (error (editor-request-condition request)))
          (values-list (editor-request-result request))))))

(defun process-editor-requests (editor)
  "Publica operações enfileiradas somente na thread proprietária."
  (unless (eq (bt:current-thread) (%editor-owner editor))
    (error "A fila precisa ser atendida pelo proprietário do editor."))
  (let ((requests (bt:with-recursive-lock-held ((%editor-lock editor))
                    (prog1 (%editor-requests editor) (setf (%editor-requests editor) nil)))))
    (dolist (request requests)
      (let (result condition)
        (handler-case (setf result
                             (let ((*editor* editor) (*mutation-dispatch-editor* editor)
                                   (sgeo:*world* (editor-world editor))
                                   (sgeo:*selection* (sgeo.scene:world-selection (editor-world editor))))
                               (multiple-value-list (funcall (editor-request-function request)))))
          (error (error) (setf condition error)))
        (bt:with-lock-held ((editor-request-lock request))
          (setf (editor-request-result request) result (editor-request-condition request) condition
                (editor-request-done-p request) t)
          (bt:condition-notify (editor-request-ready request)))))
    (length requests)))

(defvar *dispatch-wrappers* (make-hash-table :test #'equal))

(defun install-editor-dispatch ()
  "Intermedeia mutadores públicos; chamadas sem editor continuam diretas."
  (dolist (name '(sgeo.geometry:set-mesh-data sgeo.geometry:set-mesh-position
                  sgeo.geometry:set-vertex-position sgeo.geometry:split-edge
                  sgeo.geometry:collapse-edge sgeo.geometry:extrude-face sgeo.geometry:extrude-face-region
                  sgeo.scene:set-position sgeo.scene:translate sgeo.scene:set-rotation
                  sgeo.scene:rotate sgeo.scene:set-scale sgeo.scene:scale-object
                  sgeo.scene:add-child sgeo.scene:remove-child sgeo.scene:reparent
                  sgeo.scene:add-to-world sgeo.scene:remove-from-world
                  sgeo.scene:set-material-color sgeo.scene:set-material-wireframe
                  sgeo.scene:set-camera-eye sgeo.scene:set-camera-target sgeo.scene:set-camera-up
                  sgeo.scene:set-camera-projection sgeo.scene:set-camera-frame
                  sgeo.scene:orbit-camera sgeo.scene:pan-camera sgeo.scene:zoom-camera
                  (setf sgeo.core:object-name) (setf sgeo.core:object-metadata)
                  (setf sgeo.scene:world-selection) (setf sgeo.scene:scene-object-visible-p)
                  (setf sgeo.scene:scene-object-enabled-p) (setf sgeo.scene:mesh-object-material)
                  (setf sgeo.scene:simple-material-color) (setf sgeo.scene:simple-material-wireframe-p)
                  (setf sgeo.scene:camera-target) (setf sgeo.scene:camera-up) (setf sgeo.scene:camera-fov)
                  (setf sgeo.scene:camera-near) (setf sgeo.scene:camera-far)))
    (when (and (fboundp name) (not (eq (fdefinition name) (gethash name *dispatch-wrappers*))))
      (let* ((original (fdefinition name)) (function-name name)
             (wrapper (lambda (&rest arguments)
                        (let ((editor (or *mutation-dispatch-editor*
                                          (and *editor* (editor-running-p *editor*) *editor*))))
                          (if (and editor (not (eq (bt:current-thread) (%editor-owner editor))))
                              (call-in-editor editor (lambda () (%api-history-step editor original function-name arguments)))
                              (apply original arguments))))))
        (setf (fdefinition name) wrapper (gethash name *dispatch-wrappers*) wrapper))))
  t)

(defun close-editor (editor)
  "Acorda clientes pendentes e encerra o listener sem abandonar pedidos."
  (let ((requests (bt:with-recursive-lock-held ((%editor-lock editor))
                    (setf (%editor-closed-p editor) t (editor-running-p editor) nil)
                    (prog1 (%editor-requests editor) (setf (%editor-requests editor) nil)))))
    (dolist (request requests)
      (bt:with-lock-held ((editor-request-lock request))
        (setf (editor-request-condition request) (make-condition 'simple-error
                                         :format-control "O editor foi encerrado." :format-arguments nil)
              (editor-request-done-p request) t)
        (bt:condition-notify (editor-request-ready request)))))
  (stop-editor-listener editor)
  editor)

(defun editor-select (editor object &optional elements)
  "Seleciona a instância viva e seus elementos geométricos."
  (call-in-editor editor
    (lambda ()
      (setf (sgeo.scene:world-selection (editor-world editor)) object
            (editor-elements editor) (copy-list elements))
      (setf sgeo:*selection* object)
      (when object (setf (editor-inspected editor) object))
      object)))

(defun set-editor-view (editor view)
  "Alterna a vista, mantendo a mesma câmera e o mesmo mundo."
  (call-in-editor editor
    (lambda ()
      (editor-view-camera (editor-world editor) view)
      (setf (editor-view editor) view))))

(defun set-editor-layout (editor layout)
  "Alterna entre áreas de modelagem, inspeção e desenvolvimento."
  (unless (member layout '(:modeling :development :inspection))
    (error 'sgeo.core:validation-error :context "layout" :message "Layout desconhecido."))
  (call-in-editor editor (lambda () (setf (editor-layout editor) layout))))

(defun %editor-time-number (value &optional positive-p)
  "Valida um intervalo ou fator finito antes de alterar o relógio."
  (unless (and (sgeo.geometry::%finite-real-p value)
               (if positive-p (> value 0) (>= value 0)))
    (error 'sgeo.core:validation-error :context "relógio do editor"
           :message "O intervalo deve ser finito e não negativo; a velocidade deve ser positiva."))
  (coerce value 'double-float))

(defun advance-editor-time (editor dt &key force)
  "Atualiza o mundo e o relógio quando a reprodução está ativa ou em passo único."
  (let ((dt (%editor-time-number dt)))
    (call-in-editor editor
      (lambda ()
        (when (or force (editor-playing-p editor))
          (let ((scaled (* dt (%editor-time-number (editor-time-scale editor) t))))
            (handler-case
                (progn (sgeo.scene:update-world (editor-world editor) scaled)
                       (incf (editor-time editor) scaled))
              (error (condition)
                (setf (editor-playing-p editor) nil
                      (editor-status editor) (format nil "Update failed: ~A" condition))
                (error condition)))))
        (editor-time editor)))))

(defun open-editor (&optional world &rest arguments)
  "Abre o editor nativo; o núcleo headless permanece independente da plataforma."
  (asdf:load-system :sgeo/editor/opengl)
  (apply (symbol-function (find-symbol "RUN-EDITOR" :sgeo.editor.opengl)) world arguments))
