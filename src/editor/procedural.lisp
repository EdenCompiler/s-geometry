(in-package #:sgeo.editor)

(defun %procedural-editor-object (editor object)
  (let ((target (or object (editor-inspected editor))))
    (unless (typep target 'sgeo.procedural:procedural-object)
      (error 'sgeo.core:validation-error :context "vista procedural"
             :message "Selecione um objeto procedural para abrir seus nós."))
    target))

(defun editor-procedural-node-view (editor &optional object)
  "Retorna os nós e as conexões do grafo ativo do objeto selecionado."
  (let* ((target (%procedural-editor-object editor object))
         (graph (sgeo.procedural:procedural-graph target))
         (nodes (sgeo.procedural:graph-node-data graph)))
    (list :object target :graph-revision (sgeo.procedural:graph-revision graph)
          :output (sgeo.procedural:procedural-output target)
          :nodes nodes
          :edges (loop for node in nodes
                       append (loop for input in (getf node :inputs)
                                    collect (cons input (getf node :name)))))))

(defun edit-procedural-parameter (editor node-name value &key object)
  "Edita e avalia um parâmetro de origem em uma única transação reversível do editor."
  (call-with-edit-transaction
   editor (format nil "Editar parâmetro procedural ~A" node-name)
   (lambda ()
     (let* ((target (%procedural-editor-object editor object))
            (graph (sgeo.procedural:procedural-graph target)))
       (sgeo.procedural:set-parameter graph node-name value)
       (handler-case
           (progn (sgeo.procedural:regenerate-procedural-object target) value)
         (error (condition)
           ;; A entrada com erro permanece editável; o grafo mantém a malha anterior e registra a falha.
           (setf (editor-status editor) (princ-to-string condition))
           nil))))))

(defun edit-procedural-generator-parameter (editor node-name parameter value &key object)
  "Edita e avalia um argumento do gerador em uma única transação reversível do editor."
  (call-with-edit-transaction
   editor (format nil "Editar nó procedural ~A" node-name)
   (lambda ()
     (let* ((target (%procedural-editor-object editor object))
            (graph (sgeo.procedural:procedural-graph target)))
       (sgeo.procedural:set-generator-parameter graph node-name parameter value)
       (handler-case
           (progn (sgeo.procedural:regenerate-procedural-object target) value)
         (error (condition)
           (setf (editor-status editor) (princ-to-string condition))
           nil))))))

(defun evaluate-procedural-node (editor node-name &key object)
  "Avalia um nó e publica a malha quando ele corresponde à saída do objeto."
  (call-with-edit-transaction
   editor (format nil "Avaliar nó procedural ~A" node-name)
   (lambda ()
     (let* ((target (%procedural-editor-object editor object))
            (graph (sgeo.procedural:procedural-graph target))
            (value (sgeo.procedural:evaluate-node graph node-name))
            (node-key (string-downcase
                       (if (symbolp node-name) (symbol-name node-name) node-name))))
       (when (equal node-key (sgeo.procedural:procedural-output target))
         (sgeo.procedural:regenerate-procedural-object target))
       (setf (editor-status editor) (format nil "Nó ~A atualizado" node-name))
       value))))

(defun rewire-procedural-input (editor node-name inputs &key object)
  "Reconfigura um gerador em uma edição reversível; ciclos inválidos não alteram o grafo."
  (call-with-edit-transaction
   editor (format nil "Reconfigurar nó procedural ~A" node-name)
   (lambda ()
     (let* ((target (%procedural-editor-object editor object))
            (graph (sgeo.procedural:procedural-graph target)))
       (sgeo.procedural:set-generator-inputs graph node-name inputs)
       (handler-case
           (progn (sgeo.procedural:regenerate-procedural-object target) t)
         (error (condition)
           (setf (editor-status editor) (princ-to-string condition))
           nil))))))
