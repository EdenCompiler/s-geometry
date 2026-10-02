(in-package #:sgeo.editor)

(defun %listener-line (editor text)
  (bt:with-recursive-lock-held ((%editor-lock editor))
    (push text (editor-listener-output editor))
    (when (> (length (editor-listener-output editor)) 300)
      (setf (editor-listener-output editor) (subseq (editor-listener-output editor) 0 300))))
  text)

(defun %listener-evaluate-form (editor form output)
  "Atualiza o contexto vivo em cada forma, inclusive após abrir outra cena."
  (let* ((selection-before (sgeo.scene:world-selection (editor-world editor)))
         (sgeo:*world* (editor-world editor)) (sgeo:*selection* selection-before)
         (values (multiple-value-list (eval form))))
    (shiftf cl:+++ cl:++ cl:+ form)
    (shiftf cl:/// cl:// cl:/ values)
    (shiftf cl:*** cl:** cl:* (first values))
    (unless (eq sgeo:*selection* selection-before)
      (editor-select editor sgeo:*selection*))
    (dolist (value values) (prin1 value output) (terpri output))))

(defun %listener-evaluate (editor source)
  "Lê e avalia formas na worker; mutadores públicos são enviados ao proprietário."
  (let ((*package* (find-package :cl-user)) (*editor* editor)
        (*mutation-dispatch-editor* editor))
    (%listener-line editor (concatenate 'string "sgeo> " source))
    (let ((text (with-output-to-string (output)
                  (let ((*standard-output* output) (*error-output* output)
                        (*trace-output* output))
                    (handler-case
                        (with-input-from-string (input source)
                          (loop with eof = (gensym "EOF")
                                for form = (read input nil eof) until (eq form eof)
                                do (%listener-evaluate-form editor form output)))
                      (error (condition) (format output "ERROR: ~A~%" condition)))))))
      (unless (zerop (length text)) (%listener-line editor text))
      text)))

(defun start-editor-listener (editor)
  "Inicia um listener persistente com histórico Lisp e fila de formulários."
  (install-editor-dispatch)
  (unless (and (%listener-thread editor) (bt:thread-alive-p (%listener-thread editor)))
    (setf (%listener-thread editor)
          (bt:make-thread
           (lambda ()
             (catch 'editor-listener-stop
               (let ((cl:* nil) (cl:** nil) (cl:*** nil) (cl:/ nil) (cl:// nil) (cl:/// nil)
                     (cl:+ nil) (cl:++ nil) (cl:+++ nil))
                 (loop
                   for source =
                     (bt:with-recursive-lock-held ((%editor-lock editor))
                       (loop while (and (not (%editor-closed-p editor)) (null (%listener-forms editor)))
                             do (bt:condition-wait (%listener-ready editor) (%editor-lock editor)))
                       (when (%editor-closed-p editor) (throw 'editor-listener-stop nil))
                       (setf (%listener-busy editor) t)
                       (pop (%listener-forms editor)))
                   do (unwind-protect (%listener-evaluate editor source)
                        (bt:with-recursive-lock-held ((%editor-lock editor))
                          (setf (%listener-busy editor) nil)))))))
           :name "sgeo editor listener")))
  editor)

(defun submit-listener (editor source)
  "Enfileira texto multilinha sem bloquear eventos ou renderização."
  (unless (stringp source) (error "O listener requer uma string."))
  (when (%editor-closed-p editor) (error "O editor foi encerrado."))
  (start-editor-listener editor)
  (bt:with-recursive-lock-held ((%editor-lock editor))
    (setf (%listener-forms editor) (nconc (%listener-forms editor) (list source)))
    (bt:condition-notify (%listener-ready editor)))
  source)

(defun listener-busy-p (editor)
  "Indica avaliação ativa ou formulários aguardando atendimento."
  (bt:with-recursive-lock-held ((%editor-lock editor))
    (not (null (or (%listener-busy editor) (%listener-forms editor))))))

(defun stop-editor-listener (editor)
  "Encerra a worker de avaliação, incluindo leituras e operações bloqueadas."
  (let ((thread (%listener-thread editor)))
    (when thread
      (bt:with-recursive-lock-held ((%editor-lock editor))
        (bt:condition-notify (%listener-ready editor)))
      (when (bt:thread-alive-p thread)
        (ignore-errors (bt:interrupt-thread thread (lambda () (throw 'editor-listener-stop nil)))))
      (unless (eq thread (bt:current-thread)) (ignore-errors (bt:join-thread thread)))
      (setf (%listener-thread editor) nil (%listener-busy editor) nil (%listener-forms editor) nil)))
  editor)

(defun start-editor-server (editor &key (backend :swank) (port 4005))
  "Inicia SLIME ou SLY opcionais na mesma imagem e mantém os mutadores na fila."
  (unless (and (integerp port) (< 0 port 65536)) (error "Porta inválida."))
  (let ((system (ecase backend (:swank :swank) (:slynk :slynk))))
    (asdf:load-system system)
    (install-editor-dispatch)
    (setf *editor* editor sgeo:*world* (editor-world editor))
    (let ((server (find-symbol "CREATE-SERVER" (string system))))
      (funcall server :port port :dont-close t))))

(defun start-editor-terminal (editor stop-flag)
  "Abre um REPL terminal na mesma imagem, com edição encaminhada ao proprietário."
  (install-editor-dispatch)
  (let ((input *standard-input*) (output *standard-output*) (query *query-io*))
    (bt:make-thread
      (lambda ()
        (catch 'editor-terminal-stop
          (let ((*standard-input* input) (*standard-output* output) (*query-io* query)
                (*package* (find-package :cl-user))
                (cl:* nil) (cl:** nil) (cl:*** nil) (cl:/ nil) (cl:// nil) (cl:/// nil)
                (cl:+ nil) (cl:++ nil) (cl:+++ nil)
                (eof (gensym "EOF")))
            (loop until (car stop-flag)
                  do (write-string "sgeo> " query) (finish-output query)
                     (handler-case
                         (let ((form (read input nil eof)))
                           (when (eq form eof) (return))
                           (when (eq form :quit) (setf (car stop-flag) t) (return))
                           (let ((text (%listener-evaluate editor (prin1-to-string form))))
                             (write-string text output) (finish-output output)))
                       (error (condition)
                         (format output "ERROR: ~A~%" condition) (finish-output output)))))))
      :name "sgeo editor terminal")))

(defun stop-editor-terminal (thread stop-flag)
  "Encerra a leitura terminal sem deixar uma thread pendente após fechar a janela."
  (setf (car stop-flag) t)
  (when (and thread (bt:thread-alive-p thread))
    (ignore-errors (bt:interrupt-thread thread (lambda () (throw 'editor-terminal-stop nil))))
    (unless (eq thread (bt:current-thread)) (ignore-errors (bt:join-thread thread))))
  nil)
