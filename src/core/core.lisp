(in-package #:sgeo.core)

(define-condition sgeo-error (error)
  ((context :initarg :context :initform "geral" :type string :reader condition-context)
   (message :initarg :message :initform "Ocorreu um erro no S-Geometry." :type string :reader condition-message))
  (:report (lambda (condition stream)
             (format stream "~A: ~A"
                     (condition-context condition)
                     (condition-message condition))))
  (:documentation "Condição-base para erros reportados pelo S-Geometry."))

(define-condition validation-error (sgeo-error) ()
  (:documentation "Indica que um valor ou estado viola uma validação do S-Geometry."))
(define-condition math-error (sgeo-error) ()
  (:documentation "Indica uma operação matemática inválida ou sem resultado definido."))
(define-condition hierarchy-error (sgeo-error) ()
  (:documentation "Indica uma relação inválida na hierarquia de objetos."))
(define-condition platform-error (sgeo-error) ()
  (:documentation "Indica uma falha na integração com a plataforma."))
(define-condition render-error (sgeo-error) ()
  (:documentation "Indica uma falha na preparação ou execução da renderização."))

(defun %require-string (value context)
  (unless (stringp value)
    (error 'validation-error :context context
           :message (format nil "Esperava uma string, mas recebeu ~S." value)))
  value)

(defvar *object-id-counter* 0)
(defvar *object-id-lock* (bt:make-lock "sgeo object IDs"))

(defun make-object-id ()
  "Gera um identificador inteiro único dentro da imagem Lisp atual."
  (bt:with-lock-held (*object-id-lock*)
    (incf *object-id-counter*)))

(defclass sgeo-object ()
  ((id :initform (make-object-id) :reader object-id)
   (name :initarg :name :initform "Objeto" :accessor %object-name)
   (metadata :initarg :metadata :initform (make-hash-table :test #'equal) :accessor %object-metadata)
   (revision :initform 0 :accessor %object-revision)
   (observer-lock :initform (bt:make-lock "sgeo object observers") :reader %observer-lock)
   (observers :initform nil :accessor %observers))
  (:documentation "Objeto-base com identidade estável e revisão monotônica."))

(defmethod initialize-instance :after ((object sgeo-object) &key)
  (%require-string (%object-name object) "nome do objeto")
  (let ((metadata (%object-metadata object)))
    (cond ((null metadata)
           (setf (%object-metadata object) (make-hash-table :test #'equal)))
          ((not (hash-table-p metadata))
           (error 'validation-error :context "metadados do objeto"
                  :message "Os metadados precisam ser uma tabela hash ou NIL."))))
  object)

(defgeneric touch-object (object &optional reason)
  (:documentation "Avança a revisão do objeto e notifica observadores da invalidação."))

(defun object-name (object)
  "Retorna o nome legível do objeto."
  (%object-name object))

(defun (setf object-name) (value object)
  "Altera o nome do objeto e avança sua revisão quando houver mudança."
  (%require-string value "nome do objeto")
  (unless (equal value (%object-name object))
    (setf (%object-name object) value)
    (touch-object object :name-changed))
  value)

(defun object-metadata (object)
  "Retorna os metadados associados ao objeto."
  (%object-metadata object))

(defun (setf object-metadata) (value object)
  "Substitui a tabela de metadados e avança a revisão quando houver mudança."
  (when (null value)
    (setf value (make-hash-table :test #'equal)))
  (unless (hash-table-p value)
    (error 'validation-error :context "metadados do objeto"
           :message "Os metadados precisam ser uma tabela hash ou NIL."))
  (unless (eq value (%object-metadata object))
    (setf (%object-metadata object) value)
    (touch-object object :metadata-changed))
  value)

(defun object-revision (object)
  "Retorna a revisão monotônica atual do objeto."
  (%object-revision object))

(defmethod touch-object ((object sgeo-object) &optional (reason :modified))
  (let (new-revision observers)
    (bt:with-lock-held ((%observer-lock object))
      (setf new-revision (incf (%object-revision object))
            observers (copy-list (%observers object))))
    (dolist (observer observers)
      ;; A publicação já ocorreu; falhas de notificações não rejeitam a edição.
      (handler-case (funcall observer object reason new-revision)
        (error (condition)
          (warn "Falha no observador de invalidação do objeto ~D: ~A"
                (object-id object) condition))))
    new-revision))

(defgeneric bounds (object)
  (:documentation "Retorna os limites espaciais do objeto ou NIL quando não aplicável."))
(defgeneric compile-render-data (object &optional context)
  (:documentation "Produz a representação derivada necessária para renderizar o objeto."))
(defgeneric update-object (object world dt)
  (:documentation "Atualiza o objeto durante um passo de simulação."))
(defgeneric dependencies-of (object)
  (:documentation "Retorna os objetos dos quais este objeto depende."))
(defgeneric invalidate-object (object &optional reason)
  (:documentation "Marca o objeto e suas representações derivadas como desatualizados."))

(defmethod bounds ((object sgeo-object))
  (declare (ignore object))
  nil)
(defmethod compile-render-data ((object sgeo-object) &optional context)
  (declare (ignore object context))
  nil)
(defmethod update-object ((object sgeo-object) world dt)
  (declare (ignore object world dt))
  nil)
(defmethod dependencies-of ((object sgeo-object))
  (declare (ignore object))
  nil)
(defmethod invalidate-object ((object sgeo-object) &optional (reason :invalidated))
  (touch-object object reason))

(defun add-invalidation-observer (object observer)
  "Registra uma função chamada com objeto, motivo e revisão após invalidações."
  (unless (functionp observer)
    (error 'validation-error :context "observador de invalidação"
           :message "O observador precisa ser uma função."))
  (bt:with-lock-held ((%observer-lock object))
    (pushnew observer (%observers object) :test #'eq))
  observer)

(defun remove-invalidation-observer (object observer)
  "Remove um observador de invalidação previamente registrado."
  (bt:with-lock-held ((%observer-lock object))
    (setf (%observers object) (delete observer (%observers object) :test #'eq)))
  observer)
