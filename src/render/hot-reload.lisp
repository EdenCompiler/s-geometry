(in-package #:sgeo.render)

(defclass shader-program ()
  ((name :initarg :name :reader %program-name)
   (compiler :initarg :compiler :reader %program-compiler)
   (builder :initarg :builder :reader %program-builder)
   (destroyer :initarg :destroyer :reader %program-destroyer)
   (active :initform nil :reader shader-program-active)
   (compiled :initform nil :reader shader-program-compiled)
   (generation :initform 0 :reader shader-program-generation)
   (requested :initform 0 :accessor %program-requested)
   (ready :initform nil :accessor %program-ready)
   (workers :initform nil :accessor %program-workers)
   (retired :initform nil :accessor %program-retired)
   (last-error :initform nil :reader shader-program-last-error)
   (closed-p :initform nil :accessor %program-closed-p)
   (lock :initform (bt:make-lock "sgeo shader program") :reader %program-lock)))

(defun make-shader-program (name compiler builder destroyer source)
  "Compila e cria o primeiro pipeline na thread gráfica chamadora."
  (let* ((program (make-instance 'shader-program :name name :compiler compiler
                                 :builder builder :destroyer destroyer))
         (compiled (funcall compiler source))
         (active (funcall builder compiled)))
    (unless active (error "O construtor não devolveu um pipeline."))
    (setf (slot-value program 'active) active (slot-value program 'compiled) compiled)
    program))

(defun request-shader-reload (program source)
  "Compila no trabalhador; recursos gráficos são criados apenas na instalação."
  (bt:with-lock-held ((%program-lock program))
    (when (%program-closed-p program) (error "O programa foi encerrado."))
    (let ((generation (incf (%program-requested program))))
      (setf (%program-ready program) nil
            (slot-value program 'last-error) nil
            (%program-workers program)
            (remove-if-not #'bt:thread-alive-p (%program-workers program)))
      (push (bt:make-thread
             (lambda ()
               (let (compiled failure)
                 (handler-case (setf compiled (funcall (%program-compiler program) source))
                   (error (condition) (setf failure condition)))
                 (bt:with-lock-held ((%program-lock program))
                   (when (and (not (%program-closed-p program))
                              (= generation (%program-requested program)))
                     (setf (%program-ready program) (list generation compiled failure))))))
             :name (format nil "sgeo compile ~A/~D" (%program-name program) generation))
            (%program-workers program))
      generation)))

(defun shader-program-pending-p (program)
  (bt:with-lock-held ((%program-lock program))
    (or (%program-ready program) (some #'bt:thread-alive-p (%program-workers program)))))

(defun install-pending-shader (program frame)
  "Constrói o candidato, troca atomicamente e aposenta o pipeline anterior."
  (let ((ready (bt:with-lock-held ((%program-lock program))
                 (prog1 (%program-ready program) (setf (%program-ready program) nil)))))
    (when ready
      (destructuring-bind (generation compiled failure) ready
        (when failure
          (bt:with-lock-held ((%program-lock program))
            (when (= generation (%program-requested program))
              (setf (slot-value program 'last-error) failure)))
          (return-from install-pending-shader nil))
        (let ((candidate nil))
          (handler-case
              (setf candidate (funcall (%program-builder program) compiled))
            (error (condition)
              (bt:with-lock-held ((%program-lock program))
                (when (= generation (%program-requested program))
                  (setf (slot-value program 'last-error) condition)))
              (return-from install-pending-shader nil)))
          (unless candidate
            (let ((condition (make-condition 'simple-error
                                              :format-control "O construtor não devolveu um pipeline.")))
              (bt:with-lock-held ((%program-lock program))
                (when (= generation (%program-requested program))
                  (setf (slot-value program 'last-error) condition)))
              (return-from install-pending-shader nil)))
          (let ((installed
                  (bt:with-lock-held ((%program-lock program))
                    (unless (or (%program-closed-p program)
                                (/= generation (%program-requested program)))
                      (push (cons frame (shader-program-active program)) (%program-retired program))
                      (setf (slot-value program 'active) candidate
                            (slot-value program 'compiled) compiled
                            (slot-value program 'generation) generation
                            (slot-value program 'last-error) nil)
                      t))))
            ;; O destrutor pode consultar o programa sem tentar adquirir o mesmo bloqueio.
            (unless installed (funcall (%program-destroyer program) candidate))
            installed))))))

(defun collect-retired-shaders (program completed-frame)
  "Libera pipelines somente depois da conclusão dos comandos que os usaram."
  (let ((garbage nil))
    (bt:with-lock-held ((%program-lock program))
      (setf (%program-retired program)
            (remove-if (lambda (pair)
                         (when (<= (car pair) completed-frame) (push (cdr pair) garbage) t))
                       (%program-retired program))))
    (dolist (resource garbage) (funcall (%program-destroyer program) resource))
    (length garbage)))

(defun destroy-shader-program (program)
  "Encerra trabalhadores e libera cada pipeline uma única vez."
  (let (workers garbage)
    (bt:with-lock-held ((%program-lock program))
      (when (%program-closed-p program) (return-from destroy-shader-program nil))
      (setf (%program-closed-p program) t workers (%program-workers program)
            garbage (cons (shader-program-active program) (mapcar #'cdr (%program-retired program)))
            (%program-ready program) nil (%program-retired program) nil
            (slot-value program 'active) nil))
    (dolist (worker workers) (bt:join-thread worker))
    (dolist (resource garbage) (when resource (funcall (%program-destroyer program) resource)))
    t))
