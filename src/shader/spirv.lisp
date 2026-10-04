(in-package #:sgeo.shader)

;;;; Emissor binário SPIR-V nativo para o SGIR tipado.
;;;; Os números de opcode seguem a gramática oficial Khronos SPIR-V.

(define-condition spirv-emission-error (shader-error)
  ((context :initarg :context :reader spirv-error-context))
  (:report (lambda (condition stream)
             (format stream "Não foi possível emitir SPIR-V~@[ (~a)~]: ~a"
                     (spirv-error-context condition)
                     (slot-value condition 'message)))))

(defstruct (spirv-context (:constructor %make-spirv-context))
  (next-id 1 :type (integer 1 *))
  (capabilities nil) (extensions nil) (imports nil)
  (memory-model nil) (entry-points nil) (execution-modes nil)
  (debug nil) (annotations nil) (types-globals nil) (functions nil)
  (type-ids (make-hash-table :test #'equal))
  (constant-ids (make-hash-table :test #'equal))
  (global-ids (make-hash-table :test #'equal))
  (function-ids (make-hash-table :test #'equal))
  (function-types (make-hash-table :test #'equal))
  (ext-import-ids (make-hash-table :test #'equal))
  (metadata nil))

(defun spirv-fail (context control &rest arguments)
  (error 'spirv-emission-error :context context
         :message (apply #'format nil control arguments)))

(defun spirv-id (context)
  (prog1 (spirv-context-next-id context)
    (incf (spirv-context-next-id context))))

(defun spirv-op (opcode &rest operands)
  (cons opcode operands))

(defun spirv-op-list (opcode operands)
  (cons opcode operands))

(defun spirv-opcode-word (instruction)
  (let ((opcode (car instruction))
        (operands (cdr instruction)))
    (logior (ash (1+ (length operands)) 16) opcode)))

(defun spirv-string-words (string)
  "Codifica uma string UTF-8 terminada em NUL em palavras de 32 bits."
  (let* ((octets (sb-ext:string-to-octets string :external-format :utf-8))
         (bytes (append (coerce octets 'list) (list 0)))
         (padded (append bytes (make-list (mod (- 4 (mod (length bytes) 4)) 4)
                                          :initial-element 0))))
    (loop for tail on padded by #'cddddr
          collect (logior (first tail) (ash (second tail) 8)
                          (ash (third tail) 16) (ash (fourth tail) 24)))))

(defun spirv-string-op (opcode &rest operands-and-string)
  (let* ((string (car (last operands-and-string)))
         (operands (butlast operands-and-string)))
    (append (list opcode) operands (spirv-string-words string))))

(defun spirv-type-key (type)
  (if (consp type) (copy-tree type) type))

(defun spirv-scalar-type-id (context kind)
  (or (gethash kind (spirv-context-type-ids context))
      (let ((id (spirv-id context)))
        (setf (gethash kind (spirv-context-type-ids context)) id)
        (push (case kind
                (:void (spirv-op 19 id))
                (:bool (spirv-op 20 id))
                (:int (spirv-op 21 id 32 1))
                (:uint (spirv-op 21 id 32 0))
                (:float (spirv-op 22 id 32))
                (otherwise (spirv-fail "tipo escalar" "Tipo não suportado: ~s" kind)))
              (spirv-context-types-globals context))
        id)))

(defun spirv-type-id (context type &optional (storage 7))
  (let* ((key (spirv-type-key type))
         (cache-key (list key (if (and (consp key) (eq (first key) :pointer))
                                  storage :type))))
    (or (gethash cache-key (spirv-context-type-ids context))
        (let ((id (spirv-id context)))
          (setf (gethash cache-key (spirv-context-type-ids context)) id)
          (push
           (cond
             ((member key '(:void :bool :int :uint :float) :test #'eq)
              (case key
                (:void (spirv-op 19 id)) (:bool (spirv-op 20 id))
                (:int (spirv-op 21 id 32 1)) (:uint (spirv-op 21 id 32 0))
                (:float (spirv-op 22 id 32))))
             ((and (consp key) (eq (first key) :vector))
              (spirv-op-list 23 (list id (spirv-type-id context (second key))
                                     (third key))))
             ((and (consp key) (eq (first key) :matrix))
              (let* ((column-type (list :vector :float (third key)))
                     (column-count (second key)))
                (spirv-op 24 id (spirv-type-id context column-type) column-count)))
             ((and (consp key) (eq (first key) :array))
              (let ((length-id (spirv-constant-id context :uint (third key))))
                (spirv-op 28 id (spirv-type-id context (second key)) length-id)))
             ((and (consp key) (eq (first key) :struct))
              (let ((members (if (and (= (length key) 3) (listp (third key)))
                                 (third key) (rest (rest key)))))
                (spirv-op-list 30
                               (cons id (mapcar (lambda (member)
                                                  (spirv-type-id context
                                                                 (if (consp member)
                                                                     (second member) member)))
                                                members)))))
             ((and (consp key) (eq (first key) :image))
              ;; SGL representa imagens como (:image :2d :float); a forma
              ;; completa opcional também aceita os campos binários SPIR-V.
              (let* ((compact (member (second key) '(:1d :2d :3d :cube :rect :buffer :subpass)
                                      :test #'eq))
                     (sampled-type (if compact (third key) (second key)))
                     (dim (if compact
                              (case (second key) (:1d 0) (:2d 1) (:3d 2) (:cube 3)
                                (:rect 4) (:buffer 5) (:subpass 6))
                              (or (third key) 1)))
                     (depth (if compact 0 (or (fourth key) 0)))
                     (arrayed (if compact 0 (or (fifth key) 0)))
                     (ms (if compact 0 (or (sixth key) 0)))
                     (sampled (if compact 1 (or (seventh key) 1)))
                     (format (if compact 0 (or (eighth key) 0))))
                (spirv-op 25 id (spirv-type-id context sampled-type)
                          dim depth arrayed ms sampled format)))
             ((and (consp key) (eq (first key) :sampled-image))
              (spirv-op 27 id (spirv-type-id context (second key))))
             ((and (consp key) (eq (first key) :pointer))
              (spirv-op 32 id (or (second key) storage)
                        (spirv-type-id context (third key) (or (second key) storage))))
             (t (spirv-fail "tipo" "Tipo SGIR não suportado: ~s" key)))
           (spirv-context-types-globals context))
          id))))

(defun spirv-constant-id (context type value)
  (let* ((key (list (spirv-type-key type) value))
         (old (gethash key (spirv-context-constant-ids context))))
    (or old
        (let* ((type-id (spirv-type-id context type))
               (id (spirv-id context))
               (instruction
                 (cond
                   ((eq type :bool) (spirv-op (if value 41 42) type-id id))
                   ((eq type :float)
                    (let* ((bits (if (integerp value)
                                     (if (zerop value) 0 value)
                                     (sb-kernel:single-float-bits (coerce value 'single-float)))))
                      (spirv-op 43 type-id id (ldb (byte 32 0) bits))))
                   ((member type '(:int :uint))
                    (spirv-op 43 type-id id (ldb (byte 32 0) value)))
                   (t (spirv-fail "constante" "Constante de tipo ~s não suportada" type)))))
          (setf (gethash key (spirv-context-constant-ids context)) id)
          (push instruction (spirv-context-types-globals context))
          id))))

(defun spirv-storage-class (storage)
  (case storage
    (:uniform-constant 0) (:input 1) (:uniform 2) (:output 3)
    (:workgroup 4) (:private 6) (:function 7) (:storage-buffer 12)
    (otherwise (spirv-fail "storage" "Classe de armazenamento inválida: ~s" storage))))

(defun spirv-decoration (name)
  (case name
    (:block 2) (:builtin 11) (:flat 14) (:location 30)
    (:binding 33) (:descriptor-set 34) (:offset 35)
    (:non-writable 24) (:non-readable 25)
    (otherwise (spirv-fail "decoração" "Decoração não suportada: ~s" name))))

(defun spirv-built-in (name)
  (case name
    (:position 0) (:point-size 1) (:clip-distance 3) (:vertex-index 42)
    (:instance-index 43) (:frag-depth 22) (:front-facing 17)
    (otherwise (spirv-fail "builtin" "BuiltIn não suportado: ~s" name))))

(defun spirv-decoration-instructions (context target decorations)
  (dolist (decoration decorations)
    (let* ((name (if (consp decoration) (first decoration) decoration))
           (value (and (consp decoration) (second decoration)))
           (enum (spirv-decoration name)))
      (push (if (eq name :builtin)
                (spirv-op 71 target enum (spirv-built-in value))
                (if value (spirv-op 71 target enum value)
                    (spirv-op 71 target enum)))
            (spirv-context-annotations context)))))

(defun spirv-normalize-decorations (decorations)
  "Normaliza pares de decoração tanto em listas aninhadas quanto em plists."
  (let ((result nil)
        (cursor decorations))
    (loop while cursor do
      (let ((item (pop cursor)))
        (cond
          ((consp item) (push item result))
          ((eq item :stage) (when cursor (pop cursor)))
          ((member item '(:builtin :location :binding :descriptor-set :offset
                          :member-offsets) :test #'eq)
           (unless cursor
             (spirv-fail "decoração" "Falta valor para decoração ~s" item))
           (push (list item (pop cursor)) result))
          (t (push item result)))))
    (nreverse result)))

(defun spirv-interface-decorations* (interface)
  (let ((decorations (remove :stage
                             (spirv-normalize-decorations
                              (sgir-interface-decorations interface))
                             :key (lambda (decoration)
                                    (if (consp decoration) (first decoration) decoration))
                             :test #'eq)))
    (when (sgir-interface-location interface)
      (setf decorations (remove :location decorations
                                :key (lambda (d) (if (consp d) (first d) d))
                                :test #'eq))
      (push (list :location (sgir-interface-location interface)) decorations))
    (when (sgir-interface-binding interface)
      (setf decorations (remove :binding decorations
                                :key (lambda (d) (if (consp d) (first d) d))
                                :test #'eq))
      (push (list :binding (sgir-interface-binding interface)) decorations))
    (when (sgir-interface-set interface)
      (setf decorations (remove :descriptor-set decorations
                                :key (lambda (d) (if (consp d) (first d) d))
                                :test #'eq))
      (push (list :descriptor-set (sgir-interface-set interface)) decorations))
    decorations))

(defun spirv-instruction-attributes (instruction)
  (sgir-instruction-attributes instruction))

(defun spirv-attribute (instruction key &optional default)
  (getf (spirv-instruction-attributes instruction) key default))

(defun spirv-result-id (context instruction environment &optional
                                      (result-type (sgir-instruction-type instruction)))
  (let ((result (sgir-instruction-result instruction)))
    (when result
      (let ((id (spirv-id context)))
        (setf (gethash result environment) id)
        (setf (gethash (list :type result) environment)
              result-type)
        id))))

(defun spirv-value-type (value environment)
  (gethash (list :type value) environment))

(defun spirv-inferred-result-type (opcode declared-type operands environment)
  (if (eq opcode :fmul)
      (let* ((left (spirv-value-type (first operands) environment))
             (right (spirv-value-type (second operands) environment)))
        (cond
          ((and (consp left) (eq (first left) :matrix)
                (consp right) (eq (first right) :vector))
           (list :vector :float (third left)))
          ((and (consp left) (eq (first left) :vector)
                (consp right) (eq (first right) :matrix))
           (list :vector :float (second right)))
          ((and (consp left) (eq (first left) :matrix)
                (consp right) (eq (first right) :matrix))
           (list :matrix (second right) (third left)))
          ((and (consp left) (eq (first left) :matrix)
                (eq right :float)) left)
          ((and (consp right) (eq (first right) :matrix)
                (eq left :float)) right)
          ((and (consp left) (eq (first left) :vector)
                (eq right (second left))) left)
          ((and (consp right) (eq (first right) :vector)
                (eq left (second right))) right)
          (t declared-type)))
      declared-type))

(defun spirv-value-id (context value type environment)
  (cond
    ((integerp value)
     (or (gethash value environment)
         (spirv-fail "SSA" "Valor SSA indefinido: ~s" value)))
    ((and (symbolp value) (gethash value environment)) (gethash value environment))
    ((and (numberp value) (not (integerp value)))
     (spirv-constant-id context type value))
    ((and (member type '(:bool) :test #'eq) (member value '(t nil)))
     (spirv-constant-id context type value))
    (t (spirv-fail "valor" "Valor SGIR sem definição disponível: ~s" value))))

(defun spirv-ensure-ext-import (context set-name)
  (or (gethash set-name (spirv-context-ext-import-ids context))
      (let ((id (spirv-id context)))
        (setf (gethash set-name (spirv-context-ext-import-ids context)) id)
        (push (spirv-string-op 11 id set-name) (spirv-context-imports context))
        id)))

(defun spirv-attribute-value (instruction key default)
  (let ((value (spirv-attribute instruction key default)))
    (if (and (consp value) (eq (first value) :value)) (second value) value)))

(defun spirv-instruction-operands-ids (context instruction environment)
  (let ((type (sgir-instruction-type instruction)))
    (mapcar (lambda (operand) (spirv-value-id context operand type environment))
            (sgir-instruction-operands instruction))))

(defun spirv-broadcast-vector-arguments (context target-type operands ids environment)
  "Expande argumentos escalares para a largura vetorial exigida por uma extinst."
  (if (and (consp target-type) (eq (first target-type) :vector))
      (let ((scalar-type (second target-type))
            (prelude nil)
            (values nil))
        (loop for operand in operands for id in ids do
          (if (eq (spirv-value-type operand environment) scalar-type)
              (let ((broadcast-id (spirv-id context)))
                (push (apply #'spirv-op 80
                             (append (list (spirv-type-id context target-type) broadcast-id)
                                     (make-list (third target-type) :initial-element id)))
                      prelude)
                (push broadcast-id values))
              (push id values)))
        (values (nreverse prelude) (nreverse values)))
      (values nil ids)))

(defun spirv-emit-instruction (context instruction environment)
  (let* ((opcode (sgir-instruction-opcode instruction))
         (operands (sgir-instruction-operands instruction))
         (type (spirv-inferred-result-type opcode (sgir-instruction-type instruction)
                                           operands environment))
         (type-id (and type (spirv-type-id context type)))
         (result-id (unless (or (eq opcode :constant)
                                (and (eq opcode :load)
                                     (spirv-attribute instruction :parameter)))
                      (spirv-result-id context instruction environment type)))
         (ids (mapcar (lambda (operand)
                        (spirv-value-id context operand type environment)) operands)))
    (cond
      ((eq opcode :constant)
       ;; A constante literal já alocou seu próprio ID, portanto o resultado
       ;; da instrução SGIR passa a apontar para esse ID internado.
       (let* ((value (spirv-attribute-value instruction :value (first operands)))
              (constant (spirv-constant-id context type value)))
         (setf (gethash (sgir-instruction-result instruction) environment) constant
               (gethash (list :type (sgir-instruction-result instruction)) environment) type)
         nil))
      ((eq opcode :load)
       (let* ((interface-name (spirv-attribute instruction :interface))
              (parameter-name (spirv-attribute instruction :parameter))
              (member-name (spirv-attribute instruction :member))
              (parameter-id (and parameter-name (gethash parameter-name environment))))
         (when parameter-name
           (unless parameter-id
             (spirv-fail "parameter" "Parâmetro de função desconhecido: ~s" parameter-name))
           (setf (gethash (sgir-instruction-result instruction) environment) parameter-id
                 (gethash (list :type (sgir-instruction-result instruction)) environment) type)
           (return-from spirv-emit-instruction nil))
         (let* (
              (pointer (if interface-name
                           (gethash interface-name (spirv-context-global-ids context))
                           (first ids))))
         (unless pointer
           (spirv-fail "load" "Ponteiro de interface não encontrado: ~s" interface-name))
         (if member-name
             (let* ((interface (find interface-name
                                     (getf (spirv-context-metadata context) :interfaces)
                                     :key (lambda (entry) (getf entry :name)) :test #'equal))
                    (struct-type (getf interface :type))
                    (member-index (spirv-struct-member-index struct-type member-name))
                    (pointer-type (spirv-type-id context (list :pointer 2 type)))
                    (index-id (spirv-constant-id context :uint member-index))
                    (access-id (spirv-id context)))
               (unless member-index
                 (spirv-fail "uniform" "Campo ~s ausente em ~s" member-name interface-name))
               (list (spirv-op 65 pointer-type access-id pointer index-id)
                     (spirv-op 61 type-id result-id access-id)))
             (list (spirv-op 61 type-id result-id pointer))))))
      ((eq opcode :store)
       (let ((interface-name (spirv-attribute instruction :interface)))
         (if interface-name
             (let ((pointer (gethash interface-name
                                     (spirv-context-global-ids context))))
               (unless pointer (spirv-fail "store" "Interface não encontrada: ~s" interface-name))
               (list (spirv-op 62 pointer (first ids))))
             (list (spirv-op 62 (first ids) (second ids))))))
      ((member opcode '(:fadd :fsub :fmul :fdiv :sdiv :udiv :iadd :isub :imul
                        :sadd :ssub :smul :uadd :usub :umul :srem :frem :fnegate :fneg
                        :ineg :dot :matrix-times-vector :vector-times-matrix
                        :matrix-times-matrix :vector-times-scalar :scalar-times-vector
                        :matrix-times-scalar)
               :test #'eq)
       (let* ((left-type (spirv-value-type (first operands) environment))
              (right-type (spirv-value-type (second operands) environment))
              (left-vector (and (consp left-type) (eq (first left-type) :vector)))
              (right-vector (and (consp right-type) (eq (first right-type) :vector)))
              (left-matrix (and (consp left-type) (eq (first left-type) :matrix)))
              (right-matrix (and (consp right-type) (eq (first right-type) :matrix)))
              (matrix-vector (and (eq opcode :fmul) left-matrix right-vector))
              (vector-matrix (and (eq opcode :fmul) left-vector right-matrix))
              (matrix-matrix (and (eq opcode :fmul) left-matrix right-matrix))
              (matrix-scalar (and (eq opcode :fmul)
                                  (or (and left-matrix (eq right-type :float))
                                      (and right-matrix (eq left-type :float)))))
              (float-vector-scalar
                (and (eq opcode :fmul)
                     (or (and left-vector (eq right-type :float))
                         (and right-vector (eq left-type :float)))))
              (broadcast-operand
                (and (not matrix-scalar) (not float-vector-scalar)
                     (= (length ids) 2)
                     (or (and left-vector (not right-vector) (not right-matrix))
                         (and right-vector (not left-vector) (not left-matrix)))))
              (prelude nil)
              (actual-ids (copy-list ids))
              (op (case opcode
                    ((:iadd :sadd :uadd) 128) (:fadd 129)
                    ((:isub :ssub :usub) 130) (:fsub 131)
                    ((:imul :smul :umul) 132) (:fmul 133) (:udiv 134) (:sdiv 135)
                    (:fdiv 136) (:srem 138) (:frem 140) (:ineg 126)
                    ((:fnegate :fneg) 127)
                    (:vector-times-scalar 142) (:matrix-times-scalar 143)
                    (:vector-times-matrix 144) (:matrix-times-vector 145)
                    (:matrix-times-matrix 146) (:dot 148))))
         (cond
           (matrix-vector (setf op 145))
           (vector-matrix (setf op 144))
           (matrix-matrix (setf op 146))
           (matrix-scalar
            (setf op 143)
            (when right-matrix (setf actual-ids (reverse actual-ids))))
           (float-vector-scalar
            (setf op 142)
            (when right-vector (setf actual-ids (reverse actual-ids))))
           (broadcast-operand
            (let* ((vector-position (if left-vector 0 1))
                   (scalar-position (- 1 vector-position))
                   (vector-type (if left-vector left-type right-type))
                   (scalar-id (nth scalar-position ids))
                   (broadcast-id (spirv-id context)))
              (push (apply #'spirv-op 80
                           (append (list type-id broadcast-id)
                                   (make-list (third vector-type) :initial-element scalar-id)))
                    prelude)
              (setf (nth scalar-position actual-ids) broadcast-id))))
         (append (nreverse prelude)
                 (list (apply #'spirv-op op
                              (append (list type-id result-id) actual-ids))))))
      ((member opcode '(:equal :not-equal :less-than :less-equal :greater-than
                        :greater-equal :logical-equal :logical-not-equal
                        :logical-or :logical-and :logical-not :fequal :sequal :uequal
                        :fless-than :sless-than :uless-than :fless-equal :sless-equal
                        :uless-equal :fgreater-than :sgreater-than :ugreater-than
                        :fgreater-equal :sgreater-equal :ugreater-equal)
                :test #'eq)
       (let* ((comparison-type (spirv-value-type (first operands) environment))
              (scalar-type (if (and (consp comparison-type)
                                   (eq (first comparison-type) :vector))
                               (second comparison-type) comparison-type))
              (floating (eq scalar-type :float))
              (unsigned (eq scalar-type :uint))
              (op (case opcode
                    ((:equal :fequal :sequal :uequal) (if floating 180 170))
                    (:not-equal (if floating 182 171))
                    ((:less-than :fless-than) 184) (:sless-than 177) (:uless-than 176)
                    ((:greater-than :fgreater-than) 186) (:sgreater-than 172) (:ugreater-than 174)
                    ((:less-equal :fless-equal) 188) (:sless-equal 178) (:uless-equal 179)
                    ((:greater-equal :fgreater-equal) 190) (:sgreater-equal 173) (:ugreater-equal 175)
                    (:logical-equal 164) (:logical-not-equal 165)
                    (:logical-or 166) (:logical-and 167) (:logical-not 168))))
         (when (member opcode '(:less-than :greater-than :less-equal :greater-equal))
           (setf op (case opcode
                      (:less-than (if floating 184 (if unsigned 176 177)))
                      (:greater-than (if floating 186 (if unsigned 174 172)))
                      (:less-equal (if floating 188 (if unsigned 179 178)))
                      (:greater-equal (if floating 190 (if unsigned 175 173))))))
          (list (apply #'spirv-op op (append (list type-id result-id) ids)))))
      ((eq opcode :select)
       (list (apply #'spirv-op 169 (append (list type-id result-id) ids))))
      ((member opcode '(:construct :composite-construct) :test #'eq)
       (let ((parts
               (if (and (eq opcode :construct)
                        (consp type) (eq (first type) :vector)
                        (= (length ids) 1)
                        (eq (spirv-value-type (first operands) environment)
                            (second type)))
                   (make-list (third type) :initial-element (first ids))
                   ids)))
         (list (apply #'spirv-op 80 (append (list type-id result-id) parts)))))
      ((eq opcode :extract)
       (let ((index (spirv-attribute instruction :index)))
         (unless index (spirv-fail "extract" "Falta :index na extração"))
         (list (spirv-op 81 type-id result-id (first ids) index))))
      ((eq opcode :swizzle)
       (let* ((indices (spirv-attribute instruction :indices))
              (source (first ids)))
         (unless (and indices (<= 1 (length indices) 4))
           (spirv-fail "swizzle" "Índices de swizzle inválidos: ~s" indices))
         (if (and (= (length indices) 1)
                  (not (and (consp type) (eq (first type) :vector)))
                  (not (and (consp type) (eq (first type) :matrix))))
             (list (spirv-op 81 type-id result-id source (first indices)))
             (list (apply #'spirv-op 79
                          (append (list type-id result-id source source) indices))))))
      ((eq opcode :call)
       (let* ((callee (spirv-attribute instruction :function))
              (function-id (gethash callee (spirv-context-function-ids context))))
         (unless function-id (spirv-fail "call" "Função SGIR desconhecida: ~s" callee))
         (list (apply #'spirv-op 57 (append (list type-id result-id function-id) ids)))))
      ((eq opcode :extinst)
       (let* ((set (let ((value (spirv-attribute instruction :instruction-set)))
                     (if (member value '(:glsl-std-450 :glsl) :test #'eq)
                         "GLSL.std.450" (or value "GLSL.std.450"))))
              (ext-op (spirv-attribute instruction :instruction))
              (ext-code (if (and (eq ext-op :abs)
                                 (or (eq type :int)
                                     (and (consp type) (eq (second type) :int))))
                            5 (if (integerp ext-op) ext-op (spirv-glsl-std-450 ext-op))))
              (set-id (spirv-ensure-ext-import context set)))
         (multiple-value-bind (prelude ext-ids)
             (if (member ext-op '(:mix :clamp :min :max) :test #'eq)
                 (spirv-broadcast-vector-arguments context type operands ids environment)
                 (values nil ids))
           (append prelude
                   (list (apply #'spirv-op 12
                                (append (list type-id result-id set-id ext-code) ext-ids)))))))
      ((member opcode '(:texture-sample :sample :image-sample-implicit-lod) :test #'eq)
       (unless (= (length ids) 2)
         (spirv-fail "amostragem de textura" "Esperados imagem e coordenadas"))
       (list (spirv-op 87 type-id result-id (first ids) (second ids))))
      ((eq opcode :sampled-image)
       (list (spirv-op 86 type-id result-id (first ids) (second ids))))
      ((eq opcode :cross)
       (let* ((set-id (spirv-ensure-ext-import context "GLSL.std.450")))
         (list (spirv-op 12 type-id result-id set-id 68 (first ids) (second ids)))))
      ((member opcode '(:min :max) :test #'eq)
       (let* ((set-id (spirv-ensure-ext-import context "GLSL.std.450"))
              (scalar-type (if (and (consp type) (eq (first type) :vector))
                               (second type) type))
              (floating (eq scalar-type :float))
              (unsigned (eq scalar-type :uint))
              (ext-code (case opcode
                          (:min (if floating 37 (if unsigned 38 39)))
                          (:max (if floating 40 (if unsigned 41 42))))))
         (multiple-value-bind (prelude ext-ids)
             (spirv-broadcast-vector-arguments context type operands ids environment)
           (append prelude
                   (list (spirv-op 12 type-id result-id set-id ext-code
                                   (first ext-ids) (second ext-ids)))))))
      ((eq opcode :access-chain)
       (list (apply #'spirv-op 65 (append (list type-id result-id) ids))))
      ((eq opcode :copy) (list (spirv-op 83 type-id result-id (first ids))))
      (t (spirv-fail "instrução" "Opcode SGIR não suportado: ~s" opcode)))))

(defun spirv-glsl-std-450 (opcode)
  (or (cdr (assoc opcode
                  '((:round . 1) (:trunc . 3) (:abs . 4) (:fabs . 4)
                    (:floor . 8) (:ceil . 9) (:fract . 10) (:radians . 11)
                    (:degrees . 12) (:sin . 13) (:cos . 14) (:tan . 15)
                    (:asin . 16) (:acos . 17) (:atan . 18) (:sinh . 19)
                    (:cosh . 20) (:tanh . 21) (:asinh . 22) (:acosh . 23)
                    (:atanh . 24) (:atan2 . 25) (:pow . 26) (:exp . 27)
                    (:log . 28) (:exp2 . 29) (:log2 . 30) (:sqrt . 31)
                    (:inverse-sqrt . 32) (:determinant . 33) (:matrix-inverse . 34)
                    (:min . 37) (:max . 40) (:clamp . 43) (:mix . 46)
                    (:step . 48) (:smoothstep . 49) (:length . 66)
                    (:distance . 67) (:cross . 68) (:normalize . 69)
                    (:face-forward . 70) (:reflect . 71) (:refract . 72))
                  :test #'eq))
      (spirv-fail "GLSL.std.450" "Operação matemática desconhecida: ~s" opcode)))

(defun spirv-struct-member-index (type member-name)
  (when (and (consp type) (eq (first type) :struct))
    (position member-name (third type) :key #'first :test #'spirv-name-equal)))

(defun spirv-struct-member-type (type member-name)
  (when (and (consp type) (eq (first type) :struct))
    (second (find member-name (third type) :key #'first :test #'spirv-name-equal))))

(defun spirv-name-equal (left right)
  (if (and (symbolp left) (symbolp right))
      (string-equal (symbol-name left) (symbol-name right))
      (equal left right)))

(defun spirv-decoration-value (decorations key)
  (let ((entry (find key decorations :key (lambda (item)
                                            (and (consp item) (first item)))
                     :test #'eq)))
    (and entry (second entry))))

(defun spirv-emit-terminator (context terminator environment labels return-type)
  (let* ((opcode (sgir-terminator-opcode terminator))
         (operands (sgir-terminator-operands terminator))
         (targets (sgir-terminator-targets terminator)))
    (case opcode
      (:return (list (spirv-op 253)))
      (:return-value
       (list (spirv-op 254 (spirv-value-id context (first operands) return-type environment))))
      (:branch
       (list (spirv-op 249 (gethash (first targets) labels))))
      (:branch-conditional
       (list (spirv-op 250
                       (spirv-value-id context (first operands) :bool environment)
                       (gethash (first targets) labels)
                       (gethash (second targets) labels))))
      (:kill (list (spirv-op 252)))
      (otherwise (spirv-fail "terminador" "Terminador SGIR não suportado: ~s" opcode)))))

(defun spirv-function-type-id (context function)
  (let* ((return-type (sgir-function-return-type function))
         (parameter-types (mapcar #'sgir-parameter-type
                                  (sgir-function-parameters function)))
         (key (cons return-type parameter-types)))
    (or (gethash key (spirv-context-function-types context))
        (let ((id (spirv-id context)))
          (setf (gethash key (spirv-context-function-types context)) id)
          (push (apply #'spirv-op 33 id
                       (cons (spirv-type-id context return-type)
                             (mapcar (lambda (type) (spirv-type-id context type))
                                     parameter-types)))
                (spirv-context-types-globals context))
          id))))

(defun spirv-emit-function (context function module-entry)
  (let* ((name (sgir-function-name function))
         (return-type (sgir-function-return-type function))
         (function-id (gethash name (spirv-context-function-ids context)))
         (function-type (spirv-function-type-id context function))
         (environment (make-hash-table :test #'equal))
         (blocks (sgir-function-blocks function))
         (labels (make-hash-table :test #'equal))
         (instructions nil))
    (when (and module-entry (sgir-function-parameters function))
      (spirv-fail name "A função de entrada SPIR-V não pode ter parâmetros; declare-os como interfaces"))
    (dolist (block blocks)
      (setf (gethash (sgir-block-name block) labels) (spirv-id context)))
    (push (spirv-op 54 (spirv-type-id context return-type) function-id 0 function-type)
          instructions)
    (unless module-entry
      (dolist (parameter (sgir-function-parameters function))
        (let ((id (spirv-id context)))
          (setf (gethash (sgir-parameter-name parameter) environment) id)
          (setf (gethash (list :type (sgir-parameter-name parameter)) environment)
                (sgir-parameter-type parameter))
          (push (spirv-op 55 (spirv-type-id context (sgir-parameter-type parameter)) id)
                instructions))))
    (dolist (block blocks)
      (push (spirv-op 248 (gethash (sgir-block-name block) labels)) instructions)
      (dolist (instruction (sgir-block-instructions block))
        (setf instructions (nconc (nreverse (spirv-emit-instruction context instruction environment))
                                  instructions)))
      (setf instructions
            (nconc (nreverse (spirv-emit-terminator
                              context (sgir-block-terminator block) environment labels return-type))
                   instructions)))
    (setf instructions (nreverse instructions))
    (setf (spirv-context-functions context)
          (nconc (spirv-context-functions context)
                 (append instructions (list (spirv-op 56)))))))

(defun spirv-prepare-interfaces (context module entry-function)
  (let ((entry-interface-ids nil)
        (metadata nil))
    (dolist (interface (sgir-module-interfaces module))
      (let* ((storage (sgir-interface-storage interface))
             (type (sgir-interface-type interface))
             (spirv-storage (if (and (eq storage :uniform) (consp type)
                                    (eq (first type) :sampled-image))
                               :uniform-constant storage))
             (storage-enum (spirv-storage-class spirv-storage))
             (type-id (spirv-type-id context type storage-enum))
             (pointer-id (spirv-type-id context (list :pointer storage-enum type)))
             (id (spirv-id context)))
        (setf (gethash (sgir-interface-name interface) (spirv-context-global-ids context)) id)
        (push (spirv-string-op 5 id (princ-to-string (sgir-interface-name interface)))
              (spirv-context-debug context))
        (push (spirv-op 59 pointer-id id storage-enum) (spirv-context-types-globals context))
        (let ((decorations (spirv-interface-decorations* interface)))
          (if (and (member storage '(:uniform :storage-buffer) :test #'eq)
                   (consp type) (eq (first type) :struct))
              (progn
                (when (member :block decorations)
                  (push (spirv-op 71 type-id 2) (spirv-context-annotations context)))
                (dolist (offset (spirv-decoration-value decorations :member-offsets))
                  (let ((index (spirv-struct-member-index type (first offset))))
                    (unless index
                      (spirv-fail "uniform" "Campo de offset desconhecido: ~s" (first offset)))
                    (push (spirv-op 72 type-id index 35 (second offset))
                          (spirv-context-annotations context))
                    (when (and (consp (spirv-struct-member-type type (first offset)))
                               (eq (first (spirv-struct-member-type type (first offset))) :matrix))
                      (push (spirv-op 72 type-id index 5) ; ColMajor
                            (spirv-context-annotations context))
                      (push (spirv-op 72 type-id index 7 16) ; MatrixStride
                            (spirv-context-annotations context)))))
                (spirv-decoration-instructions
                 context id (remove-if (lambda (decoration)
                                         (member (if (consp decoration)
                                                     (first decoration) decoration)
                                                 '(:block :std140 :member-offsets)))
                                       decorations))
                ;; Vulkan exige offsets explícitos nos membros dos UBOs.
                (when (and (null (spirv-decoration-value decorations :member-offsets))
                           (third type))
                  (spirv-fail "uniform" "UBO ~s requer :member-offsets explícitos"
                              (sgir-interface-name interface))))
              (spirv-decoration-instructions context id decorations)))
        (when (member spirv-storage '(:input :output)) (push id entry-interface-ids))
        (push (list :name (sgir-interface-name interface) :storage storage
                    :spirv-storage spirv-storage :type type
                    :location (sgir-interface-location interface)
                    :set (sgir-interface-set interface) :binding (sgir-interface-binding interface)
                    :id id :type-id type-id)
              metadata)))
    (setf (spirv-context-metadata context)
          (list :name (sgir-module-name module) :stage (sgir-module-stage module)
                :entry-point (sgir-module-entry-point module)
                :interfaces (nreverse metadata)
                :entry-function (sgir-function-name entry-function)))
    (nreverse entry-interface-ids)))

(defun spirv-build-entry-point (context module function-id interface-ids)
  (let ((model (case (sgir-module-stage module)
                 (:vertex 0) (:fragment 4)
                 (otherwise (spirv-fail "stage" "Estágio Vulkan não suportado: ~s"
                                         (sgir-module-stage module))))))
    (push (append (list 15 model function-id)
                  (spirv-string-words (princ-to-string (sgir-module-entry-point module)))
                  interface-ids)
          (spirv-context-entry-points context))
    (when (= model 4)
      (push (spirv-op 16 function-id 7) (spirv-context-execution-modes context)))))

(defun spirv-flatten-instructions (instructions)
  (loop for instruction in instructions append
        (cons (spirv-opcode-word instruction) (rest instruction))))

(defun spirv-module-words (context)
  (let* ((declarations (nreverse (spirv-context-types-globals context)))
         ;; Declarações criadas enquanto os corpos são emitidos ainda precisam
         ;; preceder variáveis globais, que encerram a seção de tipos/valores.
         (instructions
           (append (list (spirv-op 17 1)) ; OpCapability Shader
                   (nreverse (spirv-context-extensions context))
                   (nreverse (spirv-context-imports context))
                   (list (spirv-op 14 0 1)) ; Logical, GLSL450
                   (nreverse (spirv-context-entry-points context))
                   (nreverse (spirv-context-execution-modes context))
                   (nreverse (spirv-context-debug context))
                   (nreverse (spirv-context-annotations context))
                   (remove-if (lambda (instruction) (= (car instruction) 59)) declarations)
                   (remove-if-not (lambda (instruction) (= (car instruction) 59)) declarations)
                   (spirv-context-functions context))))
    (coerce (append (list #x07230203 #x00010300 0
                          (spirv-context-next-id context) 0)
                    (spirv-flatten-instructions instructions))
            '(vector (unsigned-byte 32)))))

(defun spirv-words-to-octets (words)
  (let ((result (make-array (* 4 (length words)) :element-type '(unsigned-byte 8))))
    (loop for word across words for offset from 0 by 4 do
      (setf (aref result offset) (ldb (byte 8 0) word)
            (aref result (+ offset 1)) (ldb (byte 8 8) word)
            (aref result (+ offset 2)) (ldb (byte 8 16) word)
            (aref result (+ offset 3)) (ldb (byte 8 24) word)))
    result))

(defun compile-shader-to-spirv (shader-or-sgir)
  "Emite SGIR tipado para uma sequência binária SPIR-V little-endian.

Retorna os octetos e, como segundo valor, metadados para criação de layouts Vulkan."
  (let* ((module (if (sgir-module-p shader-or-sgir)
                     shader-or-sgir
                     (shader-definition-sgir shader-or-sgir)))
         (functions (sgir-module-functions module))
         (entry-name (sgir-module-entry-point module))
         (entry-function (find entry-name functions :key #'sgir-function-name :test #'equal))
         (context (%make-spirv-context)))
    (unless entry-function (spirv-fail "entry point" "Função de entrada não encontrada: ~s" entry-name))
    (dolist (function functions)
      (setf (gethash (sgir-function-name function) (spirv-context-function-ids context))
            (spirv-id context)))
    (let ((interfaces (spirv-prepare-interfaces context module entry-function)))
      (spirv-build-entry-point context module
                               (gethash entry-name (spirv-context-function-ids context))
                               interfaces))
    (dolist (function functions)
      (spirv-emit-function context function (eq function entry-function)))
    (values (spirv-words-to-octets (spirv-module-words context))
            (spirv-context-metadata context))))

(defun write-shader-spirv (shader-or-sgir pathname)
  "Emite SGIR e grava o módulo SPIR-V binário em PATHNAME."
  (multiple-value-bind (octets metadata) (compile-shader-to-spirv shader-or-sgir)
    (with-open-file (stream pathname :direction :output :if-exists :supersede
                            :if-does-not-exist :create
                            :element-type '(unsigned-byte 8))
      (write-sequence octets stream))
    (values pathname metadata)))

(defun spirv-module-metadata (shader-or-sgir)
  "Devolve as interfaces Vulkan sem serializar novamente o módulo."
  (nth-value 1 (compile-shader-to-spirv shader-or-sgir)))
