(in-package #:sgeo.input)

(declaim (ftype function %validate-normalized-binding
                  push-input-context %refresh-actions))

(defvar *input-maps* (make-hash-table :test #'equal))

(defstruct (input-context (:constructor %make-input-context))
  name bindings (consume-p nil))

(defstruct (input-state (:constructor %make-input-state))
  map
  (contexts nil)
  (keys (make-hash-table :test #'equal))
  (mouse-buttons (make-hash-table :test #'equal))
  (gamepad-buttons (make-hash-table :test #'equal))
  (axes (make-hash-table :test #'equal))
  (modifiers nil)
  cursor
  (scroll-x 0d0)
  (scroll-y 0d0)
  (queued-events nil)
  (action-values (make-hash-table :test #'equal))
  (pressed-actions (make-hash-table :test #'equal))
  (released-actions (make-hash-table :test #'equal))
  (deadzone 0.15d0)
  (in-frame-p nil))

(defun %proper-plist-p (plist)
  (and (listp plist) (evenp (length plist))))

(defun %plist-value (plist key &optional default)
  (if (and (listp plist) (keywordp key))
      (getf plist key default)
      default))

(defun %validate-deadzone (value)
  (unless (and (realp value) (<= 0 value) (< value 1))
    (error "A zona morta precisa estar no intervalo [0, 1): ~S" value))
  (float value 1d0))

(defun %normalize-binding (binding)
  "Converte a forma curta do DSL em uma lista interna com propriedades."
  (unless (and (consp binding) (keywordp (first binding)))
    (error "Forma de vínculo inválida: ~S" binding))
  (let* ((kind (first binding))
         (args (rest binding))
         (required (case kind
                     ((:key :mouse-button :gamepad-button) 1)
                     (:gamepad-axis 2)
                     (:scroll 2)
                     (otherwise (error "Tipo de vínculo desconhecido: ~S" kind))))
         (positional (subseq args 0 (min required (length args))))
         (properties (nthcdr (length positional) args)))
    (when (< (length positional) required)
      (error "Faltam argumentos posicionais no vínculo: ~S" binding))
    (unless (%proper-plist-p properties)
      (error "Opções de vínculo precisam formar uma plist: ~S" binding))
    (let ((normalized
            (case kind
              (:key (list* :key :code (first positional) properties))
              (:mouse-button (list* :mouse-button :button (first positional) properties))
              (:gamepad-button (list* :gamepad-button :button (first positional) properties))
              (:gamepad-axis (list* :gamepad-axis :axis (first positional)
                                    :direction (second positional) properties))
              (:scroll (list* :scroll :axis (first positional)
                              :direction (second positional) properties)))))
      (%validate-normalized-binding normalized))))

(defun %validate-normalized-binding (binding)
  (let ((kind (first binding)) (parts (rest binding)))
    (unless (%proper-plist-p parts)
      (error "Forma de vínculo interno inválida: ~S" binding))
    (case kind
      (:key
       (unless (and (getf parts :code)
                    (or (null (getf parts :mods)) (listp (getf parts :mods))))
         (error "Vínculo de tecla inválido: ~S" binding))
       (when (and (getf parts :deadzone) (not (realp (getf parts :deadzone))))
         (error "Zona morta inválida: ~S" binding)))
      (:mouse-button
       (unless (getf parts :button) (error "Vínculo de botão inválido: ~S" binding)))
      (:gamepad-button
       (unless (getf parts :button) (error "Vínculo de gamepad inválido: ~S" binding)))
      (:gamepad-axis
       (unless (and (getf parts :axis)
                    (member (getf parts :direction) '(:positive :negative :both)))
         (error "Vínculo de eixo inválido: ~S" binding))
       (when (and (getf parts :deadzone)
                  (not (and (realp (getf parts :deadzone))
                            (<= 0 (getf parts :deadzone))
                            (< (getf parts :deadzone) 1))))
         (error "Zona morta inválida: ~S" binding)))
      (:scroll
       (unless (and (member (getf parts :axis) '(:x :y))
                    (member (getf parts :direction) '(:positive :negative :both)))
         (error "Vínculo de rolagem inválido: ~S" binding)))
      (otherwise (error "Tipo de vínculo desconhecido: ~S" kind)))
  binding))

(defun %normalize-bindings (bindings)
  (unless (listp bindings) (error "A lista de vínculos precisa ser uma lista."))
  (mapcar #'%normalize-binding bindings))

(defun %validate-map-forms (forms)
  (unless (listp forms) (error "As ações do mapa precisam ser uma lista."))
  (dolist (form forms)
    (unless (and (consp form) (symbolp (first form)))
      (error "Declaração de ação inválida: ~S" form))
    (dolist (binding (rest form)) (%normalize-binding binding)))
  forms)

(defun %register-input-map (name forms)
  (%validate-map-forms forms)
  (setf (gethash name *input-maps*)
        (let ((table (make-hash-table :test #'equal)))
          (dolist (form forms table)
            (setf (gethash (first form) table)
                  (%normalize-bindings (rest form)))))))

(defmacro define-input-map (name &body actions)
  "Registra em tempo de carregamento um mapa de ações tipadas em Lisp."
  (%validate-map-forms actions)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (%register-input-map ',name ',actions)))

(defun %copy-bindings (bindings)
  (mapcar (lambda (binding) (copy-list binding)) bindings))

(defun %map-bindings (map-name)
  (when map-name
    (or (gethash map-name *input-maps*)
        (error "Mapa de entrada não registrado: ~S" map-name))))

(defun make-input-state (&key map contexts (deadzone 0.15d0))
  "Cria estado de entrada opcionalmente inicializado por MAP e CONTEXTS."
  (let* ((base (%map-bindings map))
         (state (%make-input-state :map map :deadzone (%validate-deadzone deadzone))))
    (when base
      (setf (input-state-contexts state)
            (list (%make-input-context :name map :bindings
                                       (let ((copy (make-hash-table :test #'equal)))
                                         (maphash (lambda (action bindings)
                                                    (setf (gethash action copy)
                                                          (%copy-bindings bindings)))
                                                  base)
                                         copy)
                                       :consume-p nil))))
    (dolist (context (reverse contexts))
      (push-input-context state context))
    state))

(defun %context-bindings (context)
  (input-context-bindings context))

(defun %make-bindings-table (action-bindings)
  (unless (listp action-bindings) (error "Ações precisam ser uma lista."))
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry action-bindings table)
      (unless (and (consp entry) (symbolp (first entry)))
        (error "Vínculo de ação inválido: ~S" entry))
      (setf (gethash (first entry) table)
            (%normalize-bindings (rest entry))))))

(defun push-input-context (state context &key (consume t) (bindings nil bindings-p))
  "Ativa um contexto no topo. CONTEXT pode ser um mapa registrado ou nome."
  (let* ((name (if (input-context-p context) (input-context-name context) context))
         (source (cond (bindings-p (%make-bindings-table bindings))
                       ((input-context-p context) (%context-bindings context))
                       (t (%map-bindings name))))
         (copy (make-hash-table :test #'equal)))
    (unless (or bindings-p (input-context-p context))
      (unless source (setf source (make-hash-table :test #'equal))))
    (maphash (lambda (action items)
               (setf (gethash action copy) (%copy-bindings items))) source)
    (push (%make-input-context :name name :bindings copy :consume-p consume)
          (input-state-contexts state))
    (%refresh-actions state)
    name))

(defun pop-input-context (state &optional name)
  "Remove o contexto ativo do topo ou o primeiro contexto chamado NAME."
  (let ((contexts (input-state-contexts state)))
    (when contexts
      (let ((target (if name
                        (find name contexts :key #'input-context-name :test #'equal)
                        (first contexts))))
        (when target
          (setf (input-state-contexts state) (delete target contexts :test #'eq :count 1))
          (%refresh-actions state)
          (input-context-name target))))))

(defun active-input-contexts (state)
  "Devolve os nomes dos contextos ativos em ordem de prioridade."
  (mapcar #'input-context-name (input-state-contexts state)))

(defun bind-action (state action bindings &key context)
  "Define ou substitui os vínculos de ACTION em um contexto ativo."
  (let* ((target (if context
                     (find context (input-state-contexts state)
                           :key #'input-context-name :test #'equal)
                     (first (input-state-contexts state)))))
    (unless target (error "Não há contexto ativo para vincular ~S." action))
    (setf (gethash action (%context-bindings target)) (%normalize-bindings bindings))
    (%refresh-actions state)
    action))

(defun unbind-action (state action &key context)
  "Remove os vínculos de ACTION no contexto indicado ou no topo."
  (let ((target (if context
                    (find context (input-state-contexts state)
                          :key #'input-context-name :test #'equal)
                    (first (input-state-contexts state)))))
    (when target
      (remhash action (%context-bindings target))
      (%refresh-actions state))
    action))

(defun queue-input-event (state type &rest properties)
  "Enfileira evento bruto; sua transição ocorre na próxima fronteira do frame."
  (unless (%proper-plist-p properties)
    (error "Propriedades de evento precisam formar uma plist: ~S" properties))
  (unless (member type '(:key :mouse-button :gamepad-button :gamepad-axis
                         :cursor :mouse-move :scroll :mouse-scroll :focus-lost :focus))
    (error "Tipo de evento bruto desconhecido: ~S" type))
  (push (cons type properties) (input-state-queued-events state))
  state)

(defun input-cursor-position (state)
  "Devolve a última posição do cursor como (X . Y), ou NIL."
  (input-state-cursor state))

(defun input-scroll-delta (state)
  "Devolve a rolagem acumulada no frame como (DX . DY)."
  (cons (input-state-scroll-x state) (input-state-scroll-y state)))

(defun %modifiers-from (value)
  (cond ((null value) nil)
        ((listp value) (remove-duplicates value :test #'equal))
        ((vectorp value) (remove-duplicates (coerce value 'list) :test #'equal))
        (t (error "Modificadores precisam ser uma lista ou vetor: ~S" value))))

(defun %binding-control (binding)
  (case (first binding)
    (:key (list :key (getf (rest binding) :code)))
    (:mouse-button (list :mouse-button (getf (rest binding) :button)))
    (:gamepad-button (list :gamepad-button (getf (rest binding) :button)))
    (:gamepad-axis (list :gamepad-axis (getf (rest binding) :axis)))
    (:scroll (list :scroll (getf (rest binding) :axis)))))

(defun %all-context-actions (state)
  (let ((actions nil))
    (dolist (context (input-state-contexts state))
      (maphash (lambda (action ignored)
                 (declare (ignore ignored))
                 (pushnew action actions :test #'equal))
               (%context-bindings context)))
    actions))

(defun %capture-context-controls (context captured)
  (when (input-context-consume-p context)
    (maphash (lambda (action bindings)
               (declare (ignore action))
               (dolist (binding bindings)
                 (pushnew (%binding-control binding) captured :test #'equal)))
             (%context-bindings context)))
  captured)

(defun %axis-value (state axis)
  (gethash axis (input-state-axes state) 0d0))

(defun %selected-signed-value (value direction)
  (case direction
    (:positive (max 0d0 value))
    (:negative (max 0d0 (- value)))
    (:both value)))

(defun %apply-deadzone (value deadzone)
  (let ((magnitude (abs value)))
    (if (<= magnitude deadzone)
        0d0
        (* (if (minusp value) -1d0 1d0)
           (/ (- magnitude deadzone) (- 1d0 deadzone))))))

(defun %binding-value (state binding)
  (let* ((kind (first binding)) (parts (rest binding)))
    (case kind
      (:key
       (let ((required (%modifiers-from (getf parts :mods))))
         (if (and (gethash (getf parts :code) (input-state-keys state))
                  (every (lambda (mod) (member mod (input-state-modifiers state)
                                               :test #'equal)) required))
             1d0 0d0)))
      (:mouse-button
       (if (gethash (getf parts :button) (input-state-mouse-buttons state)) 1d0 0d0))
      (:gamepad-button
       (if (gethash (getf parts :button) (input-state-gamepad-buttons state)) 1d0 0d0))
      (:gamepad-axis
       (%apply-deadzone
        (%selected-signed-value (%axis-value state (getf parts :axis))
                                (getf parts :direction))
        (or (getf parts :deadzone) (input-state-deadzone state))))
      (:scroll
       (%selected-signed-value
        (if (eq (getf parts :axis) :x)
            (input-state-scroll-x state)
            (input-state-scroll-y state))
        (getf parts :direction))))))

(defun %action-value-in-context (state action contexts)
  (let ((captured nil))
    (dolist (context contexts 0d0)
      (let ((bindings (gethash action (%context-bindings context))))
        (when bindings
          (let ((values
                  (loop for binding in bindings
                        unless (member (%binding-control binding) captured :test #'equal)
                          collect (%binding-value state binding))))
            (when values
              (return
                (reduce (lambda (a b)
                          (if (> (abs a) (abs b)) a b)) values)))))
        (setf captured (%capture-context-controls context captured))))))

(defun %calculate-action-values (state)
  (let ((values (make-hash-table :test #'equal))
        (contexts (input-state-contexts state)))
    (dolist (action (%all-context-actions state) values)
      (setf (gethash action values) (%action-value-in-context state action contexts)))))

(defun %refresh-actions (state)
  (setf (input-state-action-values state) (%calculate-action-values state)))

(defun %record-action-edges (state old-values)
  (let ((new-values (%calculate-action-values state)))
    (dolist (action (remove-duplicates
                     (append (loop for action being the hash-keys of old-values collect action)
                             (loop for action being the hash-keys of new-values collect action))
                     :test #'equal))
      (let ((was-down (/= 0d0 (gethash action old-values 0d0)))
            (is-down (/= 0d0 (gethash action new-values 0d0))))
        (when (and (not was-down) is-down)
          (setf (gethash action (input-state-pressed-actions state)) t))
        (when (and was-down (not is-down))
          (setf (gethash action (input-state-released-actions state)) t))))
    (setf (input-state-action-values state) new-values)))

(defun %clear-physical-inputs (state)
  (clrhash (input-state-keys state))
  (clrhash (input-state-mouse-buttons state))
  (clrhash (input-state-gamepad-buttons state))
  (clrhash (input-state-axes state))
  (setf (input-state-modifiers state) nil))

(defun %event-action (properties)
  (or (%plist-value properties :action) (%plist-value properties :state)))

(defun %set-event-button (table code action)
  (case action
    (:press (setf (gethash code table) t))
    (:repeat nil)
    (:release (remhash code table))
    (otherwise (error "Ação de botão desconhecida: ~S" action))))

(defun %apply-input-event (state event)
  (let* ((type (car event)) (properties (cdr event))
         (action (%event-action properties)))
    (case type
      (:key
       (let ((code (or (%plist-value properties :code)
                       (%plist-value properties :key))))
         (unless code (error "Evento de tecla sem :CODE: ~S" properties))
         (%set-event-button (input-state-keys state) code action)
         (when (or (getf properties :mods) (member action '(:press :release)))
           (setf (input-state-modifiers state)
                 (%modifiers-from (getf properties :mods))))))
      (:mouse-button
       (let ((button (or (%plist-value properties :button)
                         (%plist-value properties :code))))
         (unless button (error "Evento de mouse sem :BUTTON: ~S" properties))
         (%set-event-button (input-state-mouse-buttons state) button action)))
      (:gamepad-button
       (let ((button (or (%plist-value properties :button)
                         (%plist-value properties :code))))
         (unless button (error "Evento de gamepad sem :BUTTON: ~S" properties))
         (%set-event-button (input-state-gamepad-buttons state) button action)))
      (:gamepad-axis
       (let* ((axis (or (%plist-value properties :axis)
                        (%plist-value properties :code)))
              (value (%plist-value properties :value)))
         (unless (and axis (realp value))
           (error "Evento de eixo precisa de :AXIS e valor numérico: ~S" properties))
         (setf (gethash axis (input-state-axes state))
               (max -1d0 (min 1d0 (float value 1d0))))))
      ((:cursor :mouse-move)
       (let ((x (%plist-value properties :x)) (y (%plist-value properties :y)))
         (unless (and (realp x) (realp y))
           (error "Evento de cursor precisa de coordenadas numéricas: ~S" properties))
         (setf (input-state-cursor state) (cons x y))))
      ((:scroll :mouse-scroll)
       (let ((x (or (%plist-value properties :x) (%plist-value properties :dx) 0d0))
             (y (or (%plist-value properties :y) (%plist-value properties :dy) 0d0)))
         (unless (and (realp x) (realp y))
           (error "Evento de rolagem precisa de valores numéricos: ~S" properties))
         (incf (input-state-scroll-x state) x)
         (incf (input-state-scroll-y state) y)))
      ((:focus-lost :focus)
       (when (or (eq type :focus-lost)
                 (not (%plist-value properties :focused-p t)))
         (%clear-physical-inputs state)))
      (otherwise (error "Tipo de evento desconhecido: ~S" type)))))

(defun begin-input-frame (state)
  "Aplica eventos enfileirados e publica bordas por um frame de renderização.

As bordas permanecem estáveis durante todos os passos fixos desse frame e só
são descartadas na próxima chamada a BEGIN-INPUT-FRAME."
  (clrhash (input-state-pressed-actions state))
  (clrhash (input-state-released-actions state))
  (setf (input-state-in-frame-p state) t
        (input-state-scroll-x state) 0d0
        (input-state-scroll-y state) 0d0)
  (%record-action-edges state (input-state-action-values state))
  (let ((events (nreverse (input-state-queued-events state))))
    (setf (input-state-queued-events state) nil)
    (dolist (event events)
      (let ((old-values (input-state-action-values state)))
        (%apply-input-event state event)
        (%record-action-edges state old-values))))
  state)

(defun clear-input-state (state)
  "Libera entradas mantidas e registra as bordas de soltura correspondentes."
  (let ((old-values (input-state-action-values state)))
    (%clear-physical-inputs state)
    (setf (input-state-scroll-x state) 0d0
          (input-state-scroll-y state) 0d0)
    (%record-action-edges state old-values))
  state)

(defun end-input-frame (state)
  "Encerra a leitura do frame; as bordas duram até a próxima fronteira."
  (setf (input-state-in-frame-p state) nil)
  state)

(defun action-value (state action)
  "Devolve o valor semântico de ACTION, em geral entre -1 e 1."
  (gethash action (input-state-action-values state) 0d0))

(defun action-down-p (state action)
  "Indica se ACTION tem valor não nulo neste frame."
  (/= 0d0 (action-value state action)))

(defun action-pressed-p (state action)
  "Indica a transição de solto para pressionado ocorrida neste frame."
  (not (null (gethash action (input-state-pressed-actions state)))))

(defun action-released-p (state action)
  "Indica a transição de pressionado para solto ocorrida neste frame."
  (not (null (gethash action (input-state-released-actions state)))))
