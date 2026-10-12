(in-package #:sgeo.procedural)

(defstruct generator-definition name parameters function)
(defstruct graph-node name kind inputs parameters value revision dirty-p error error-signature
  function generator-name input-signatures)
(defstruct (dependency-graph (:constructor %make-dependency-graph))
  (nodes (make-hash-table :test #'equal))
  (object-observers (make-hash-table :test #'eq))
  (revision 0))

(defvar *generator-definitions* (make-hash-table :test #'equal))
(defvar *procedural-publication* nil)

(defun %name-key (name)
  (typecase name
    (string (string-downcase name))
    (symbol (string-downcase (symbol-name name)))
    (t (error 'validation-error :context "nome do nó"
              :message "O nome precisa ser um símbolo ou uma string."))))

(defun %parameter-key (name)
  (typecase name
    (keyword name)
    (symbol (intern (symbol-name name) :keyword))
    (string (intern (string-upcase name) :keyword))
    (t (error 'validation-error :context "parâmetro procedural"
              :message "O parâmetro precisa ser um símbolo, keyword ou string."))))

#+sbcl (defvar *live-graphs* (make-hash-table :test #'eq :weakness :key))
#-sbcl (defvar *live-graphs* nil)
(declaim (ftype function %descendants %invalidate))

(defun %refresh-generator-in-graph (graph key function)
  (let (changed)
    (maphash (lambda (node-name node)
               (declare (ignore node-name))
               (when (equal (graph-node-generator-name node) key)
                 (setf (graph-node-function node) function)
                 (push (graph-node-name node) changed)))
             (dependency-graph-nodes graph))
    (when changed
      (%invalidate graph
                   (append changed
                           (mapcan (lambda (node-name) (%descendants graph node-name)) changed)))))
  graph)

(defun %value-contains-object-p (value object &optional (seen (make-hash-table :test #'eq)))
  (cond ((eq value object) t)
        ((consp value)
         (unless (gethash value seen)
           (setf (gethash value seen) t)
           (or (%value-contains-object-p (car value) object seen)
               (%value-contains-object-p (cdr value) object seen))))
        ((and (vectorp value) (not (stringp value)))
         (unless (gethash value seen)
           (setf (gethash value seen) t)
           (loop for item across value thereis (%value-contains-object-p item object seen))))
        (t nil)))

(defun %source-dependent-node-names (graph object)
  (loop for name being the hash-keys of (dependency-graph-nodes graph)
          using (hash-value node)
        when (or (%value-contains-object-p (graph-node-value node) object)
                 (%value-contains-object-p (graph-node-parameters node) object))
          append (cons name (%descendants graph name))))

(defun %observe-source-object (graph object)
  (unless (gethash object (dependency-graph-object-observers graph))
    (let* ((graph-reference #+sbcl (sb-ext:make-weak-pointer graph)
                            #-sbcl graph)
           (observer nil))
      (setf observer
            (lambda (changed reason revision)
              (declare (ignore reason revision))
              (let ((live-graph #+sbcl (sb-ext:weak-pointer-value graph-reference)
                                #-sbcl graph-reference))
                (if live-graph
                    (let* ((affected (%source-dependent-node-names live-graph changed))
                           (publishing (and *procedural-publication*
                                            (eq (first *procedural-publication*) live-graph)
                                            (second *procedural-publication*))))
                      (when publishing (setf affected (remove publishing affected :test #'equal)))
                      (when affected (%invalidate live-graph (remove-duplicates affected :test #'equal))))
                    (sgeo.core:remove-invalidation-observer changed observer)))))
      (setf (gethash object (dependency-graph-object-observers graph)) observer)
      (sgeo.core:add-invalidation-observer object observer)))
  object)

(defun %observe-value-objects (graph value &optional (seen (make-hash-table :test #'eq)))
  (cond ((typep value 'sgeo.core:sgeo-object) (%observe-source-object graph value))
        ((consp value)
         (unless (gethash value seen)
           (setf (gethash value seen) t)
           (%observe-value-objects graph (car value) seen)
           (%observe-value-objects graph (cdr value) seen)))
        ((and (vectorp value) (not (stringp value)))
         (unless (gethash value seen)
           (setf (gethash value seen) t)
           (loop for item across value do (%observe-value-objects graph item seen)))))
  value)

(defun make-dependency-graph ()
  "Cria um grafo ativo vazio cujos valores calculados são armazenados em cache sob demanda."
  (let ((graph (%make-dependency-graph)))
    #+sbcl (setf (gethash graph *live-graphs*) t)
    #-sbcl (pushnew graph *live-graphs* :test #'eq)
    graph))

(defun define-generator (name parameters function)
  "Registra um gerador Lisp nomeado sem avaliar formas de código persistidas."
  (unless (and (listp parameters) (functionp function))
    (error 'validation-error :context "gerador"
           :message "Parâmetros precisam ser uma lista e o gerador uma função."))
  (let* ((key (%name-key name))
         (definition (make-generator-definition
                      :name key :parameters (copy-tree parameters) :function function)))
    (setf (gethash key *generator-definitions*) definition)
    #+sbcl (maphash (lambda (graph value)
                      (declare (ignore value))
                      (%refresh-generator-in-graph graph key function))
                    *live-graphs*)
    #-sbcl (dolist (graph *live-graphs*)
             (%refresh-generator-in-graph graph key function))
    definition))

(defmacro define-geometry-generator (name parameters &body body)
  "Define um gerador reutilizável com parâmetros léxicos nomeados e tabela de dependências."
  (let* ((parameter-table (gensym "PARAMETERS"))
         (dependency-table (gensym "DEPENDENCIES"))
         (dependency-name (intern "DEPENDENCIES" *package*))
         (bindings
           (mapcar (lambda (entry)
                     (let* ((symbol (if (consp entry) (first entry) entry))
                            (default (and (consp entry) (second entry)))
                            (key (intern (symbol-name symbol) :keyword)))
                       (list symbol `(getf ,parameter-table ,key ,default))))
                   parameters)))
    `(define-generator ',name ',parameters
       (lambda (,parameter-table ,dependency-table)
         (let* ,bindings
           (let ((,dependency-name ,dependency-table))
             (declare (ignorable ,dependency-name))
             ,@body))))))

(defun find-generator (name)
  (gethash (%name-key name) *generator-definitions*))

(defun %graph-node (graph name)
  (or (gethash (%name-key name) (dependency-graph-nodes graph))
      (error 'validation-error :context "grafo procedural"
             :message (format nil "O nó ~A não existe." name))))

(defun %ensure-unique-node (graph name)
  (let ((key (%name-key name)))
    (when (gethash key (dependency-graph-nodes graph))
      (error 'validation-error :context "grafo procedural"
             :message (format nil "O nó ~A já existe." name)))
    key))

(defun %initial-generator-parameters (definition parameters)
  (let ((result nil))
    (when definition
      (dolist (entry (generator-definition-parameters definition))
        (let* ((symbol (if (consp entry) (first entry) entry))
               (key (intern (symbol-name symbol) :keyword))
               (default (and (consp entry) (second entry))))
          (setf (getf result key) (getf parameters key default)))))
    (loop for (key value) on parameters by #'cddr
          for normalized-key = (%parameter-key key)
          unless (getf result normalized-key :sgeo-absent)
            do (setf (getf result normalized-key) value))
    result))

(defun %neighbors (graph node)
  (loop for candidate being the hash-values of (dependency-graph-nodes graph)
        when (member (graph-node-name node) (graph-node-inputs candidate) :test #'equal)
          collect candidate))

(defun %descendants (graph name)
  (let ((seen (make-hash-table :test #'equal)) (pending (list (%name-key name))) (result nil))
    (loop while pending
          for key = (pop pending)
          unless (gethash key seen)
            do (setf (gethash key seen) t)
               (dolist (node (loop for candidate being the hash-values of (dependency-graph-nodes graph)
                                   when (member key (graph-node-inputs candidate) :test #'equal)
                                     collect candidate))
                 (push (graph-node-name node) result)
                 (push (graph-node-name node) pending)))
    result))

(defun %invalidate (graph names)
  (dolist (name names)
    (let ((node (gethash name (dependency-graph-nodes graph))))
      (when node
        (setf (graph-node-dirty-p node) t
              (graph-node-error node) nil
              (graph-node-error-signature node) nil))))
  (incf (dependency-graph-revision graph)))

(defun invalidate-node (graph name)
  "Marca o nó e todos os consumidores como desatualizados; o recálculo permanece sob demanda."
  (%graph-node graph name)
  (%invalidate graph (cons (%name-key name) (%descendants graph name)))
  graph)

(defun add-parameter-node (graph name value)
  "Adiciona um nó constante de origem e o retorna."
  (let* ((key (%ensure-unique-node graph name))
         (node (make-graph-node :name key :kind :parameter :value value
                                :revision 0 :dirty-p nil)))
    (setf (gethash key (dependency-graph-nodes graph)) node)
    (%observe-value-objects graph value)
    (incf (dependency-graph-revision graph))
    node))

(defun %topological-valid-p (graph name inputs)
  (let ((visiting (make-hash-table :test #'equal)) (visited (make-hash-table :test #'equal)))
    (labels ((visit (key)
               (when (equal key name) (return-from %topological-valid-p nil))
               (when (gethash key visiting) (return-from %topological-valid-p nil))
               (unless (gethash key visited)
                 (setf (gethash key visiting) t)
                 (let ((node (gethash key (dependency-graph-nodes graph))))
                   (when node (dolist (input (graph-node-inputs node)) (visit input))))
                 (remhash key visiting)
                 (setf (gethash key visited) t))
               t))
      (every #'visit inputs))))

(defun add-generator-node (graph name generator inputs &key (parameters nil) allow-missing-p)
  "Adiciona um gerador nomeado. INPUTS são nós de entrada e PARAMETER contém valores literais."
  (let* ((key (%ensure-unique-node graph name))
         (definition (if (functionp generator) nil (find-generator generator)))
         (function (or (and definition (generator-definition-function definition))
                       (and (functionp generator) generator)
                       (and allow-missing-p
                            (lambda (&rest arguments)
                              (declare (ignore arguments))
                              (error 'validation-error :context "gerador procedural ausente"
                                     :message (format nil "O gerador ~A não está registrado."
                                                      generator))))))
         (input-keys (mapcar #'%name-key inputs)))
    (unless function
      (error 'validation-error :context "gerador procedural"
             :message (format nil "O gerador ~A não está registrado." generator)))
    (dolist (input input-keys) (%graph-node graph input))
    (unless (%topological-valid-p graph key input-keys)
      (error 'validation-error :context "grafo procedural"
             :message "A dependência criaria um ciclo."))
    (let ((node (make-graph-node :name key :kind :generator :inputs input-keys
                                 :parameters (%initial-generator-parameters definition parameters)
                                 :function function
                                 :generator-name (and definition (generator-definition-name definition))
                                 :revision 0 :dirty-p t)))
      (when (and allow-missing-p (null definition))
        (setf (graph-node-generator-name node) (%name-key generator)
              (graph-node-error node)
              (make-condition 'simple-error :format-control "O gerador ~A não está registrado."
                              :format-arguments (list generator))))
      (setf (gethash key (dependency-graph-nodes graph)) node)
      (%observe-value-objects graph (graph-node-parameters node))
      (when (and allow-missing-p (null definition))
        (setf (graph-node-error-signature node) (%graph-input-signature graph node)))
      (incf (dependency-graph-revision graph))
      node)))

(defun set-generator-inputs (graph name inputs)
  "Reconfigura as entradas de um gerador após validar referências e rejeitar ciclos."
  (let* ((node (%graph-node graph name))
         (keys (mapcar #'%name-key inputs)))
    (unless (eq (graph-node-kind node) :generator)
      (error 'validation-error :context "grafo procedural"
             :message "Apenas nós geradores podem receber dependências."))
    (dolist (key keys) (%graph-node graph key))
    (unless (%topological-valid-p graph (graph-node-name node) keys)
      (error 'validation-error :context "grafo procedural"
             :message "A dependência criaria um ciclo."))
    (unless (equal keys (graph-node-inputs node))
      (setf (graph-node-inputs node) keys)
      (%invalidate graph (cons (graph-node-name node)
                               (%descendants graph (graph-node-name node)))))
    node))

(defun set-generator-parameter (graph name parameter value)
  "Atualiza um parâmetro literal do gerador e invalida seus consumidores."
  (let ((node (%graph-node graph name))
        (key (%parameter-key parameter)))
    (unless (eq (graph-node-kind node) :generator)
      (error 'validation-error :context "grafo procedural"
             :message "Apenas nós geradores têm parâmetros editáveis."))
    (let ((old (getf (graph-node-parameters node) key :sgeo-absent)))
      (unless (equalp old value)
        (setf (getf (graph-node-parameters node) key) value)
        (%observe-value-objects graph value)
        (%invalidate graph (cons (graph-node-name node)
                                 (%descendants graph (graph-node-name node))))))
    value))

(defun remove-graph-node (graph name)
  "Remove um nó sem referências e rejeita a remoção enquanto houver consumidores."
  (let* ((key (%name-key name)) (node (%graph-node graph key)))
    (when (%neighbors graph node)
      (error 'validation-error :context "grafo procedural"
             :message "Não é possível remover um nó que ainda tem consumidores."))
    (remhash key (dependency-graph-nodes graph))
    (incf (dependency-graph-revision graph))
    graph))

(defun set-parameter (graph name value)
  "Altera um nó de parâmetro e invalida apenas seus consumidores transitivos."
  (let ((node (%graph-node graph name)))
    (unless (eq (graph-node-kind node) :parameter)
      (error 'validation-error :context "parâmetro procedural"
             :message "O nó escolhido não é um parâmetro."))
    (unless (equalp (graph-node-value node) value)
      (setf (graph-node-value node) value
            (graph-node-revision node) (1+ (graph-node-revision node)))
      (%observe-value-objects graph value)
      (%invalidate graph (%descendants graph name)))
    value))

(defun node-value (graph name)
  (graph-node-value (%graph-node graph name)))
(defun node-revision (graph name)
  (graph-node-revision (%graph-node graph name)))
(defun node-dirty-p (graph name)
  (graph-node-dirty-p (%graph-node graph name)))
(defun node-error (graph name)
  (graph-node-error (%graph-node graph name)))

(defun %value-signature (value &optional (seen (make-hash-table :test #'eq)))
  (typecase value
    (sgeo.core:sgeo-object
     (list :object (sgeo.core:object-id value) (sgeo.core:object-revision value)))
    (cons
     (if (gethash value seen)
         :circular-value
         (progn
           (setf (gethash value seen) t)
           (prog1 (cons (%value-signature (car value) seen)
                        (%value-signature (cdr value) seen))
             (remhash value seen)))))
    (vector
     (if (stringp value)
         (list :string value)
         (if (gethash value seen)
             :circular-value
             (progn
               (setf (gethash value seen) t)
               (prog1 (cons :vector (loop for item across value
                                          collect (%value-signature item seen)))
                 (remhash value seen))))))
    (t value)))

(defun %graph-input-signature (graph node)
  (%observe-value-objects graph (graph-node-parameters node))
  (list :inputs
        (loop for name in (graph-node-inputs node)
              for input = (%graph-node graph name)
              do (%observe-value-objects graph (graph-node-value input))
              collect (list (graph-node-name input) (graph-node-revision input)
                            (%value-signature (graph-node-value input))))
        :parameters (%value-signature (graph-node-parameters node))))

(defun %refresh-node-input-signatures (graph node)
  (setf (graph-node-input-signatures node) (%graph-input-signature graph node)))

(defun evaluate-node (graph name)
  "Avalia dependências e revisões de objetos de origem antes de publicar resultados em cache."
  (let ((node (%graph-node graph name)))
    (if (eq (graph-node-kind node) :parameter)
        (graph-node-value node)
        (let ((inputs (make-hash-table :test #'equal)))
          (handler-case
              (dolist (input (graph-node-inputs node))
                (setf (gethash input inputs) (evaluate-node graph input)))
            (error (condition)
              (setf (graph-node-error node) condition
                    (graph-node-error-signature node) :upstream-failure)
              (error condition)))
          (let* ((signature (%graph-input-signature graph node))
                 (dirty-p (graph-node-dirty-p node)))
            (when (and (not dirty-p)
                       (not (equalp signature (graph-node-input-signatures node))))
              (%invalidate graph
                           (cons (graph-node-name node)
                                 (%descendants graph (graph-node-name node))))
              (setf dirty-p t))
            (when (and (graph-node-error node)
                       (equalp signature (graph-node-error-signature node)))
              (error (graph-node-error node)))
            (if (not dirty-p)
                (graph-node-value node)
                (let ((next-value
                        (handler-case
                            (funcall (graph-node-function node)
                                     (copy-tree (graph-node-parameters node)) inputs)
                          (error (condition)
                            (setf (graph-node-error node) condition
                                  (graph-node-error-signature node) signature)
                            (error condition)))))
                  (setf (graph-node-value node) next-value
                        (graph-node-input-signatures node) signature
                        (graph-node-dirty-p node) nil
                        (graph-node-error node) nil
                        (graph-node-error-signature node) nil
                        (graph-node-revision node) (1+ (graph-node-revision node)))
                  (incf (dependency-graph-revision graph))
                  next-value)))))))

(defun graph-node-data (graph)
  "Retorna registros prontos para a interface a partir do grafo e do estado em cache."
  (loop for name being the hash-keys of (dependency-graph-nodes graph) using (hash-value node)
        collect (list :name name :kind (graph-node-kind node)
                      :generator (graph-node-generator-name node)
                      :inputs (copy-list (graph-node-inputs node))
                      :value (and (eq (graph-node-kind node) :parameter)
                                  (graph-node-value node))
                      :parameters (copy-tree (graph-node-parameters node))
                      :revision (graph-node-revision node)
                      :dirty-p (graph-node-dirty-p node)
                      :error (and (graph-node-error node)
                                  (princ-to-string (graph-node-error node))))
        into records
        finally (return (sort records #'string< :key (lambda (record) (getf record :name))))))

(defun graph-revision (graph) (dependency-graph-revision graph))

(defun %snapshot-dependency-graph (graph)
  "Captura o estado do grafo para transações do editor sem serializar funções."
  (list (dependency-graph-revision graph)
        (loop for name being the hash-keys of (dependency-graph-nodes graph)
                using (hash-value node)
              collect (let ((copy (copy-graph-node node)))
                        (setf (graph-node-inputs copy) (copy-list (graph-node-inputs node))
                              (graph-node-parameters copy) (copy-tree (graph-node-parameters node))
                              (graph-node-input-signatures copy)
                              (copy-tree (graph-node-input-signatures node)))
                        copy))))

(defun %restore-dependency-graph (graph snapshot)
  "Restaura um snapshot no próprio grafo para preservar sua identidade nos objetos ligados."
  (setf (dependency-graph-revision graph)
        (1+ (max (dependency-graph-revision graph) (first snapshot)))
        (dependency-graph-nodes graph) (make-hash-table :test #'equal))
  (dolist (node (second snapshot))
    (setf (gethash (graph-node-name node) (dependency-graph-nodes graph))
          (let ((copy (copy-graph-node node)))
            (setf (graph-node-inputs copy) (copy-list (graph-node-inputs node))
                  (graph-node-parameters copy) (copy-tree (graph-node-parameters node))
                  (graph-node-input-signatures copy)
                  (copy-tree (graph-node-input-signatures node)))
            copy)))
  graph)

(defun %finite-real-p (value)
  "Aceita reais finitos, rejeitando NaN e infinitos em todas as precisões comuns."
  (and (realp value)
       (or (not (floatp value))
           (progn
             #+sbcl (not (or (sb-ext:float-infinity-p value)
                             (sb-ext:float-nan-p value)))
             #-sbcl (and (= value value)
                         (handler-case (progn (rational value) t)
                           (error () nil)))))))

(defun %safe-data-p (value &optional (states (make-hash-table :test #'eq)))
  "Valida valores inertes, rejeitando listas circulares, pontuadas e escalares não finitos."
  (typecase value
    (null t)
    (symbol (or (eq value t) (keywordp value)))
    (string t)
    (number (%finite-real-p value))
    (cons
     (case (gethash value states)
       (:visiting nil)
       (:done t)
       (otherwise
        (setf (gethash value states) :visiting)
        (let ((valid (and (or (null (cdr value)) (consp (cdr value)))
                          (%safe-data-p (car value) states)
                          (%safe-data-p (cdr value) states))))
          (setf (gethash value states) (if valid :done :invalid))
          valid))))
    (t nil)))

(defun graph-data (graph)
  "Exporta dados inertes do grafo; funções executáveis e valores em cache são omitidos."
  (let ((records
          (loop for name being the hash-keys of (dependency-graph-nodes graph) using (hash-value node)
                collect
                (case (graph-node-kind node)
                  (:parameter
                   (unless (%safe-data-p (graph-node-value node))
                     (error 'validation-error :context "persistência procedural"
                            :message "Um valor de parâmetro não pode ser salvo como dado seguro."))
                   (list :parameter name (graph-node-value node)))
                  (:generator
                   (let ((definition
                           (loop for candidate being the hash-values of *generator-definitions*
                                 when (eq (generator-definition-function candidate)
                                          (graph-node-function node)) return candidate)))
                     (unless (or definition (graph-node-generator-name node))
                       (error 'validation-error :context "persistência procedural"
                              :message "Geradores anônimos não podem ser salvos."))
                     (unless (%safe-data-p (graph-node-parameters node))
                       (error 'validation-error :context "persistência procedural"
                              :message "Parâmetros do gerador não são dados seguros."))
                     (list :generator name (if definition
                                                (generator-definition-name definition)
                                                (graph-node-generator-name node))
                           (copy-list (graph-node-inputs node))
                           (copy-tree (graph-node-parameters node)))))))))
    (list :sgeo-dependency-graph 1 (sort records #'string< :key #'second))))

(defun graph-from-data (data &key allow-missing-generators)
  "Restaura apenas dados validados e nomes de geradores registrados nesta imagem Lisp."
  (unless (and (listp data) (eq (first data) :sgeo-dependency-graph)
               (eql (second data) 1) (listp (third data)))
    (error 'validation-error :context "persistência procedural"
           :message "Dados do grafo desconhecidos."))
  (let ((graph (make-dependency-graph)) (generator-records nil))
    (dolist (record (third data))
      (unless (%safe-data-p record)
        (error 'validation-error :context "persistência procedural"
               :message "O grafo contém dados não permitidos."))
      (case (first record)
        (:parameter
         (unless (= (length record) 3) (error "Registro de parâmetro inválido."))
         (add-parameter-node graph (second record) (third record)))
        (:generator
         (unless (= (length record) 5) (error "Registro de gerador inválido."))
         (push record generator-records))
        (otherwise (error 'validation-error :context "persistência procedural"
                          :message "Tipo de nó desconhecido."))))
    (loop while generator-records
          for remaining = nil
          for progress = nil
          do (dolist (record (nreverse generator-records))
               (if (every (lambda (input) (gethash (%name-key input) (dependency-graph-nodes graph)))
                          (fourth record))
                   (progn
                     (add-generator-node graph (second record) (third record) (fourth record)
                                         :parameters (fifth record)
                                         :allow-missing-p allow-missing-generators)
                     (setf progress t))
                   (push record remaining)))
             (setf generator-records (nreverse remaining))
             (unless progress
               (error 'validation-error :context "persistência procedural"
                      :message "O grafo contém referência inexistente ou ciclo.")))
    graph))

(defclass procedural-object (mesh-object)
  ((graph :initarg :graph :reader procedural-graph)
   (output :initarg :output :reader procedural-output)
   (frozen-graph-revision :initform nil :accessor %procedural-frozen-graph-revision))
  (:documentation "Malha de cena editável controlada por um grafo Lisp ativo com valores em cache."))

(defun make-procedural-object (graph output &key (name "Procedural") geometry material)
  "Cria um objeto de malha a partir da primeira avaliação bem-sucedida do nó de saída."
  (let ((geometry (or geometry (evaluate-node graph output))))
    (unless (typep geometry '(or triangle-mesh half-edge-mesh))
      (error 'validation-error :context "resultado procedural"
             :message "A saída procedural precisa produzir uma malha suportada."))
    (make-instance 'procedural-object :name name :geometry geometry
                   :material (or material (sgeo.scene:make-material)) :graph graph
                   :output (%name-key output))))

(defun regenerate-procedural-object (object)
  "Substitui atomicamente a malha do objeto após uma avaliação bem-sucedida do grafo."
  (let* ((graph (procedural-graph object))
         (node (%graph-node graph (procedural-output object)))
         (old-value (graph-node-value node))
         (geometry (evaluate-node graph (procedural-output object))))
    (handler-case
        (progn
          (unless (typep geometry '(or triangle-mesh half-edge-mesh))
            (error 'validation-error :context "resultado procedural"
                   :message "A saída procedural precisa produzir uma malha suportada."))
          (let ((current (mesh-object-geometry object)))
            (let ((*procedural-publication* (list graph (graph-node-name node))))
              (unless (eq geometry current)
                (cond
                  ((and (typep current 'half-edge-mesh) (typep geometry 'half-edge-mesh)
                        (find-symbol "REPLACE-HALF-EDGE-MESH" "SGEO.GEOMETRY"))
                   (funcall (symbol-function (find-symbol "REPLACE-HALF-EDGE-MESH" "SGEO.GEOMETRY"))
                            current geometry))
                  ((and (typep current 'triangle-mesh) (typep geometry 'triangle-mesh))
                   (sgeo.geometry:set-mesh-data current
                     (sgeo.geometry:mesh-positions geometry)
                     (sgeo.geometry:mesh-indices geometry)
                     (sgeo.geometry:mesh-normals geometry)))
                  (t (setf (slot-value object 'sgeo.scene::geometry) geometry)))
                (touch-object object :procedural-geometry-changed)
                (setf (graph-node-value node) current)
                (%refresh-node-input-signatures graph node)))
          (setf (%procedural-frozen-graph-revision object) nil)
          object))
      (error (condition)
        (setf (graph-node-value node) old-value
              (graph-node-dirty-p node) t
              (graph-node-error node) condition
              (graph-node-error-signature node) (%graph-input-signature graph node))
        (error condition)))))

(defun %frozen-procedural-object-p (object)
  "Verifica se a geometria restaurada ainda corresponde à revisão congelada."
  (let ((revision (%procedural-frozen-graph-revision object)))
    (and revision (= revision (graph-revision (procedural-graph object))))))

(defun %rebase-procedural-freeze-after-graph-restore (object)
  "Alinha a geometria congelada à revisão monotônica criada ao restaurar o grafo."
  (when (%procedural-frozen-graph-revision object)
    (setf (%procedural-frozen-graph-revision object)
          (graph-revision (procedural-graph object))))
  object)

(defmethod sgeo.core:update-object ((object procedural-object) world dt)
  (declare (ignore world dt))
  (unless (%frozen-procedural-object-p object)
    (setf (%procedural-frozen-graph-revision object) nil)
    (handler-case
        (regenerate-procedural-object object)
      (error () nil))))

(defun procedural-data (object)
  "Retorna dados seguros do grafo e a chave de saída, sem incluir o cache de malha gerado."
  (list :sgeo-procedural-object 1 (graph-data (procedural-graph object))
        (procedural-output object)))

(defun procedural-from-data (data &key (name "Procedural") geometry material)
  "Restaura um objeto procedural a partir de dados inertes e geradores registrados."
  (unless (and (listp data) (eq (first data) :sgeo-procedural-object)
               (= (second data) 1) (= (length data) 4))
    (error 'validation-error :context "persistência procedural"
           :message "Dados do objeto procedural desconhecidos."))
  (let* ((graph (graph-from-data (third data) :allow-missing-generators t))
         (object (make-procedural-object graph (fourth data) :name name
                                         :geometry geometry :material material)))
    ;; A malha serializada é a verdade visual até que o usuário altere o grafo.
    (when geometry
      (setf (%procedural-frozen-graph-revision object) (graph-revision graph)))
    object))
