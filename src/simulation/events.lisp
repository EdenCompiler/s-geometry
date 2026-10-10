(in-package #:sgeo.simulation)

(defstruct (event (:constructor %make-event)) type source payload time)
(defstruct subscription type function priority once-p active-p)
(defclass event-bus ()
  ((subscriptions :initform nil :accessor %subscriptions)
   (queue :initform nil :accessor %event-queue)
   (errors :initform nil :accessor event-bus-errors)))

(defun make-event-bus () "Cria um barramento local sem estado global." (make-instance 'event-bus))
(defun on-event (bus type function &key (priority 0) once-p)
  "Registra um handler ordenado; TYPE :ALL recebe todos os eventos."
  (unless (and (symbolp type) (functionp function) (integerp priority))
    (error "Assinatura de evento inválida."))
  (let ((item (make-subscription :type type :function function :priority priority
                                :once-p once-p :active-p t)))
    (setf (%subscriptions bus)
          (stable-sort (append (%subscriptions bus) (list item)) #'> :key #'subscription-priority))
    item))
(defun off-event (bus item)
  "Cancela inclusive uma assinatura presente no snapshot do despacho atual."
  (setf (subscription-active-p item) nil
        (%subscriptions bus) (remove item (%subscriptions bus) :test #'eq)) item)
(defun emit-event (bus type &key source payload (time 0d0))
  "Enfileira um evento; callbacks nunca são executados dentro do produtor."
  (unless (and (symbolp type) (realp time) (<= 0 time most-positive-double-float))
    (error "Tipo ou instante de evento inválido."))
  (let ((event (%make-event :type type :source source :payload payload :time time)))
    (push event (%event-queue bus)) event))
(defun clear-event-errors (bus) (setf (event-bus-errors bus) nil))
(defun dispatch-events (bus &key (on-error :continue))
  "Despacha o lote atual; eventos produzidos por handlers aguardam o próximo lote."
  (unless (member on-error '(:continue :signal)) (error "Política de erro inválida."))
  (let ((events (nreverse (%event-queue bus))) (count 0))
    (setf (%event-queue bus) nil)
    (loop for remaining on events for event = (first remaining) do
      (dolist (item (copy-list (%subscriptions bus)))
        (when (and (subscription-active-p item)
                   (or (eq :all (subscription-type item))
                       (eq (event-type event) (subscription-type item))))
          (when (subscription-once-p item) (off-event bus item))
          (handler-case (funcall (subscription-function item) event)
            (error (condition)
              (push (list event condition) (event-bus-errors bus))
              (when (eq on-error :signal)
                (setf (%event-queue bus) (append (%event-queue bus) (reverse (rest remaining))))
                (error condition))))))
      (incf count)) count))
