(in-package #:sgeo.diagnostics)

(defvar *profiler* nil)
(defvar *scope-stack* nil)
(defvar *frame-phase* nil)

(defstruct (profiler (:constructor %make-profiler))
  (enabled-p t :type boolean)
  (lock (bt:make-lock "sgeo diagnostics") :read-only t)
  (aggregates (make-hash-table :test #'equal))
  (timeline nil)
  (timeline-count 0 :type fixnum)
  (timeline-limit 2048 :type (integer 1 *))
  (frame 0 :type integer)
  (frame-start nil)
  (frame-allocation-start nil)
  (frame-phase nil)
  (origin-ticks (get-internal-real-time) :type integer)
  (renderer-info nil)
  (errors nil)
  (recoveries nil)
  (metrics-available-p nil :type boolean)
  (gpu-metrics-available-p nil :type boolean)
  (gpu-pipeline-statistics-available-p nil :type boolean)
  (clock-rate internal-time-units-per-second :type (integer 1 *)))

(defstruct (%scope (:constructor %make-scope))
  profiler name subsystem function object-class thread frame frame-phase
  (started 0 :type integer) (children-time 0 :type integer)
  allocation-start allocation-children)

(defun make-profiler (&key (enabled t) (timeline-limit 2048) renderer-info)
  "Cria um coletor independente com histórico limitado e dados opcionais do renderer."
  (unless (and (integerp timeline-limit) (plusp timeline-limit))
    (error "TIMELINE-LIMIT deve ser um inteiro positivo."))
  (%make-profiler :enabled-p (not (null enabled))
                  :timeline-limit timeline-limit
                  :renderer-info (%safe-copy renderer-info)
                  :metrics-available-p (%allocation-metrics-available-p)))

(defun %allocation-metrics-available-p ()
  (not (null (and (find-package "SB-EXT")
                  (find-symbol "GET-BYTES-CONSED" "SB-EXT")
                  (fboundp (find-symbol "GET-BYTES-CONSED" "SB-EXT"))))))

(defun %bytes-consed ()
  (when (%allocation-metrics-available-p)
    (funcall (find-symbol "GET-BYTES-CONSED" "SB-EXT"))))

(defun %safe-label (value &optional (fallback ""))
  (handler-case
      (cond ((null value) fallback)
            ((stringp value) value)
            ((symbolp value) (string-downcase (symbol-name value)))
            ((or (numberp value) (characterp value)) (princ-to-string value))
            (t (format nil "<~A>" (type-of value))))
    (error () fallback)))

(defun %class-label (value)
  (cond ((null value) nil)
        ((stringp value) (string-downcase value))
        ((symbolp value) (string-downcase (symbol-name value)))
        (t (let ((name (ignore-errors (class-name (class-of value)))))
             (if (symbolp name) (string-downcase (symbol-name name)) "anonymous")))))

(defun %thread-label ()
  (let* ((thread (bt:current-thread))
         (name (ignore-errors (bt:thread-name thread))))
    (format nil "~A#~(~X~)" (or name "thread") (sxhash thread))))

(defmacro with-profile-scope ((name &key profiler subsystem function object-class frame-phase) &body body)
  "Mede um escopo quando existe coletor ativo; sem coletor executa o corpo diretamente."
  (let ((collector (gensym "PROFILER")) (scope (gensym "SCOPE")))
    `(let ((,collector (or ,profiler *profiler*)))
       (if (and ,collector (profiler-enabled-p ,collector))
           (let ((,scope (%begin-scope ,collector ,name ,subsystem ,function
                                        ,object-class ,frame-phase)))
             (let ((*profiler* ,collector)
                   (*scope-stack* (cons ,scope *scope-stack*)))
               (unwind-protect (progn ,@body) (%finish-scope ,scope))))
           (progn ,@body)))))

(defun %begin-scope (profiler name subsystem function object-class frame-phase)
  (let* ((frame (bt:with-lock-held ((profiler-lock profiler)) (profiler-frame profiler)))
         (phase (or frame-phase *frame-phase* (profiler-frame-phase profiler)))
         (scope (%make-scope :profiler profiler :name (%safe-label name "scope")
                             :subsystem (%safe-label subsystem)
                             :function (%safe-label function (%safe-label name "scope"))
                             :object-class (%class-label object-class)
                             :thread (%thread-label) :frame frame
                             :frame-phase (and phase (%safe-label phase))
                             :started (get-internal-real-time)
                             :allocation-start (%bytes-consed))))
    scope))

(defun %finish-scope (scope)
  (let* ((profiler (%scope-profiler scope))
         (elapsed (max 0 (- (get-internal-real-time) (%scope-started scope))))
         (allocation-end (%bytes-consed))
         (allocated (and allocation-end (%scope-allocation-start scope)
                         (max 0 (- allocation-end (%scope-allocation-start scope)))))
         (exclusive (max 0 (- elapsed (%scope-children-time scope))))
         (exclusive-allocation (and allocated
                                   (max 0 (- allocated (or (%scope-allocation-children scope) 0)))))
         (timestamp-ns (%ticks-to-ns (- (%scope-started scope)
                                         (profiler-origin-ticks profiler))
                                     (profiler-clock-rate profiler)))
         (record (list :kind "scope" :name (%scope-name scope)
                       :subsystem (%scope-subsystem scope) :function (%scope-function scope)
                       :object-class (%scope-object-class scope) :thread (%scope-thread scope)
                       :frame (%scope-frame scope) :frame-phase (%scope-frame-phase scope)
                       :timestamp-ns timestamp-ns
                       :end-timestamp-ns (+ timestamp-ns
                                            (%ticks-to-ns elapsed (profiler-clock-rate profiler)))
                       :clock-origin "host-monotonic"
                       :duration-ns (%ticks-to-ns elapsed (profiler-clock-rate profiler))
                       :exclusive-ns (%ticks-to-ns exclusive (profiler-clock-rate profiler))
                       :allocated-bytes allocated :exclusive-allocated-bytes exclusive-allocation)))
    (when (and *scope-stack* (eq scope (car *scope-stack*)) (cdr *scope-stack*)
               (eq profiler (%scope-profiler (cadr *scope-stack*))))
      (incf (%scope-children-time (cadr *scope-stack*)) elapsed)
      (when allocated
        (setf (%scope-allocation-children (cadr *scope-stack*))
              (+ (or (%scope-allocation-children (cadr *scope-stack*)) 0) allocated))))
    (bt:with-lock-held ((profiler-lock profiler))
      (%aggregate-scope profiler record)
      (%push-timeline profiler record))))

(defun %ticks-to-ns (ticks rate)
  (round (* ticks 1000000000) rate))

(defun %aggregate-scope (profiler record)
  (let* ((key (list (getf record :subsystem) (getf record :function)
                    (getf record :object-class) (getf record :thread)
                    (getf record :frame-phase)))
         (aggregate (or (gethash key (profiler-aggregates profiler))
                        (setf (gethash key (profiler-aggregates profiler))
                              (list :subsystem (first key) :function (second key)
                                    :object-class (third key) :thread (fourth key)
                                    :frame-phase (fifth key) :calls 0
                                    :inclusive-ns 0 :exclusive-ns 0
                                    :allocated-bytes (if (%getf-present-p record :allocated-bytes) 0 nil)
                                    :exclusive-allocated-bytes (if (%getf-present-p record :exclusive-allocated-bytes) 0 nil)))))
         (allocation (getf record :allocated-bytes))
         (exclusive-allocation (getf record :exclusive-allocated-bytes)))
    (incf (getf aggregate :calls))
    (incf (getf aggregate :inclusive-ns) (getf record :duration-ns))
    (incf (getf aggregate :exclusive-ns) (getf record :exclusive-ns))
    (when allocation (incf (getf aggregate :allocated-bytes) allocation))
    (when exclusive-allocation
      (incf (getf aggregate :exclusive-allocated-bytes) exclusive-allocation))))

(defun %getf-present-p (plist indicator)
  (loop for tail on plist by #'cddr thereis (eq (car tail) indicator)))

(defun %push-timeline (profiler record)
  (setf (profiler-timeline profiler)
        (%bounded-push (%safe-copy record) (profiler-timeline profiler)
                       (profiler-timeline-limit profiler)))
  (setf (profiler-timeline-count profiler) (length (profiler-timeline profiler))))

(defun %bounded-push (record records limit)
  (let ((result (cons record records)))
    (if (> (length result) limit) (subseq result 0 limit) result)))

(defun begin-frame (profiler &optional (phase "frame"))
  "Abre um frame e devolve seu identificador para END-FRAME."
  (check-type profiler profiler)
  (bt:with-lock-held ((profiler-lock profiler))
    (let ((frame (incf (profiler-frame profiler))))
      (setf (profiler-frame-start profiler) (get-internal-real-time)
            (profiler-frame-allocation-start profiler) (%bytes-consed)
            (profiler-frame-phase profiler) (%safe-label phase "frame"))
      (when (profiler-enabled-p profiler)
        (%push-timeline profiler (list :kind "frame-start" :frame frame
                                      :phase (%safe-label phase "frame")
                                      :timestamp-ns (%ticks-to-ns (- (profiler-frame-start profiler)
                                                                     (profiler-origin-ticks profiler))
                                                                 (profiler-clock-rate profiler))
                                      :clock-origin "host-monotonic"
                                      :thread (%thread-label))))
      frame)))

(defun end-frame (profiler &optional frame (phase "frame"))
  "Fecha um frame aberto, publicando sua duração e métrica de alocação."
  (check-type profiler profiler)
  (bt:with-lock-held ((profiler-lock profiler))
    (let* ((frame (or frame (profiler-frame profiler)))
           (start (profiler-frame-start profiler))
           (allocation-start (profiler-frame-allocation-start profiler))
           (allocation-end (%bytes-consed))
           (allocated (and allocation-start allocation-end
                           (max 0 (- allocation-end allocation-start))))
           (duration (and start (%ticks-to-ns (max 0 (- (get-internal-real-time) start))
                                              (profiler-clock-rate profiler))))
           (record (list :kind "frame-end" :frame frame :phase (%safe-label phase "frame")
                         :duration-ns duration
                         :allocated-bytes allocated
                         :allocation-scope (and allocated "process")
                         :timestamp-ns (%ticks-to-ns (- (get-internal-real-time)
                                                         (profiler-origin-ticks profiler))
                                                     (profiler-clock-rate profiler))
                         :clock-origin "host-monotonic" :thread (%thread-label))))
      (when (profiler-enabled-p profiler) (%push-timeline profiler record))
      (setf (profiler-frame-start profiler) nil)
      (setf (profiler-frame-allocation-start profiler) nil)
      record)))

(defun current-frame (&optional (profiler *profiler*))
  "Retorna o número do frame atual do coletor dinâmico."
  (when profiler (profiler-frame profiler)))

(defun current-profiler ()
  "Retorna o coletor ativo na ligação dinâmica atual, se houver."
  *profiler*)

(defun set-profiler-renderer-info (profiler info)
  "Atualiza dados descritivos do renderer usando apenas uma cópia segura."
  (check-type profiler profiler)
  (bt:with-lock-held ((profiler-lock profiler))
    (setf (profiler-renderer-info profiler) (%safe-copy info)))
  profiler)

(defun record-diagnostic-error (profiler condition &key phase context)
  "Registra uma condição sem reter o objeto de condição ou dados arbitrários."
  (%record-condition profiler "error" condition phase context))

(defun record-recovery (profiler description &key phase context)
  "Registra uma ação de recuperação em texto seguro."
  (let ((record (list :kind "recovery" :description (%safe-label description "recovered")
                      :phase (and phase (%safe-label phase)) :context (and context (%safe-label context))
                      :thread (%thread-label) :frame (profiler-frame profiler))))
    (bt:with-lock-held ((profiler-lock profiler))
      (setf (profiler-recoveries profiler)
            (%bounded-push record (profiler-recoveries profiler) (profiler-timeline-limit profiler)))
      (when (profiler-enabled-p profiler) (%push-timeline profiler record)))
    record))

(defun %frame-host-start-ns (profiler frame)
  "Localiza o quadro original de consultas assíncronas, sem usar o quadro corrente por engano."
  (bt:with-lock-held ((profiler-lock profiler))
    (let ((record (find-if (lambda (entry)
                             (and (equal (getf entry :kind) "frame-start")
                                  (eql (getf entry :frame) frame)))
                           (profiler-timeline profiler))))
      (getf record :timestamp-ns))))

(defun record-gpu-sample (profiler name duration-ns &key subsystem frame thread)
  "Registra duração de query GPU em nanossegundos, sem misturá-la ao relógio host."
  (check-type profiler profiler)
  (unless (and (realp duration-ns)
               (or (not (floatp duration-ns)) (%finite-float-p duration-ns))
               (not (minusp duration-ns)))
    (error "DURATION-NS deve ser um número real não negativo."))
  (let* ((frame (or frame (profiler-frame profiler)))
         (frame-host-start-ns (%frame-host-start-ns profiler frame))
         (record (list :kind "gpu-sample" :name (%safe-label name "gpu")
                       :subsystem (%safe-label subsystem)
                       :frame frame
                       :thread (or thread (%thread-label))
                       :duration-ns (if (and (floatp duration-ns) (not (%finite-float-p duration-ns)))
                                        nil duration-ns)
                       :unit "ns" :clock-origin "gpu-query"
                       :frame-host-start-ns frame-host-start-ns)))
    (bt:with-lock-held ((profiler-lock profiler))
      (setf (profiler-gpu-metrics-available-p profiler) t)
      (when (profiler-enabled-p profiler) (%push-timeline profiler record)))
    record))

(defun record-pipeline-statistics (profiler counters &key frame subsystem backend)
  "Registra contadores GPU inteiros, mantendo-os separados dos tempos host."
  (check-type profiler profiler)
  (let* ((safe-counters (%validated-counters counters))
         (frame (or frame (profiler-frame profiler)))
         (record (list :kind "gpu-pipeline-statistics"
                       :frame frame
                       :frame-host-start-ns (%frame-host-start-ns profiler frame)
                       :subsystem (%safe-label subsystem)
                       :backend (and backend (%safe-label backend))
                       :thread (%thread-label) :clock-origin "gpu-query"
                       :counters safe-counters)))
    (bt:with-lock-held ((profiler-lock profiler))
      (setf (profiler-gpu-pipeline-statistics-available-p profiler) t)
      (when (profiler-enabled-p profiler) (%push-timeline profiler record)))
    record))

(defun %validated-counters (counters)
  (let ((pairs (cond ((hash-table-p counters)
                      (loop for key being the hash-keys of counters using (hash-value value)
                            collect (cons key value)))
                     ((consp counters) (%counter-plist-pairs counters))
                     ((null counters) nil)
                     (t (error "COUNTERS deve ser uma tabela ou lista de propriedades."))))
        (result (make-hash-table :test #'equal)))
    (dolist (pair pairs)
      (unless (and (or (stringp (car pair)) (symbolp (car pair)))
                   (integerp (cdr pair)) (not (minusp (cdr pair))))
        (error "Contadores GPU exigem nomes e valores inteiros não negativos."))
      (setf (gethash (%safe-label (car pair)) result) (cdr pair)))
    result))

(defun %counter-plist-pairs (counters)
  (let ((seen (make-hash-table :test #'eq)) (pairs nil))
    (loop while (consp counters) do
      (when (gethash counters seen)
        (error "COUNTERS não pode conter uma lista cíclica."))
      (setf (gethash counters seen) t)
      (let ((key (car counters)) (tail (cdr counters)))
        (unless (consp tail)
          (error "COUNTERS deve conter pares nome/valor."))
        (push (cons key (car tail)) pairs)
        (setf counters (cdr tail))))
    (unless (null counters)
      (error "COUNTERS deve ser uma lista própria."))
    (nreverse pairs)))

(defun %record-condition (profiler kind condition phase context)
  (let ((record (list :kind kind :condition (%safe-label (type-of condition) "condition")
                      :message (%condition-message condition)
                      :phase (and phase (%safe-label phase)) :context (and context (%safe-label context))
                      :thread (%thread-label) :frame (profiler-frame profiler))))
    (bt:with-lock-held ((profiler-lock profiler))
      (setf (profiler-errors profiler)
            (%bounded-push record (profiler-errors profiler) (profiler-timeline-limit profiler)))
      (when (profiler-enabled-p profiler) (%push-timeline profiler record)))
    record))

(defun %condition-message (condition)
  (handler-case (format nil "~A" condition)
    (error () (%safe-label (type-of condition) "condition"))))

(defun clear-profiler (profiler)
  "Remove medições e registros preservando opções, número do frame e renderer."
  (bt:with-lock-held ((profiler-lock profiler))
    (clrhash (profiler-aggregates profiler))
    (setf (profiler-timeline profiler) nil (profiler-timeline-count profiler) 0
          (profiler-errors profiler) nil (profiler-recoveries profiler) nil
          (profiler-frame-start profiler) nil))
  profiler)

(defun profiler-snapshot (profiler)
  "Cria uma cópia destacada dos agregados, eventos e metadados do coletor."
  (bt:with-lock-held ((profiler-lock profiler))
    (list :schema-version 1
          :host (%host-info)
          :lisp (%lisp-info)
          :features (%feature-info)
          :renderer-info (%safe-copy (profiler-renderer-info profiler))
          :capabilities (list :cpu "available"
                              :allocation (if (profiler-metrics-available-p profiler) "available" "unavailable")
                              :allocation-scope (if (profiler-metrics-available-p profiler)
                                                    "process" "unavailable")
                              :gpu (if (profiler-gpu-metrics-available-p profiler) "available" "unavailable")
                              :gpu-pipeline-statistics
                              (if (profiler-gpu-pipeline-statistics-available-p profiler)
                                  "available" "unavailable"))
          :metrics (list :allocation (if (profiler-metrics-available-p profiler) "available" "unavailable")
                         :gpu (if (profiler-gpu-metrics-available-p profiler) "available" "unavailable"))
          :frame (profiler-frame profiler)
          :aggregates (coerce (mapcar (lambda (entry) (%safe-copy (cdr entry)))
                                      (sort (loop for key being the hash-keys of (profiler-aggregates profiler)
                                                  using (hash-value value) collect (cons key value))
                                            #'string< :key (lambda (entry) (prin1-to-string (car entry)))))
                             'vector)
          :timeline (coerce (%safe-copy (nreverse (copy-list (profiler-timeline profiler)))) 'vector)
          :errors (coerce (%safe-copy (nreverse (copy-list (profiler-errors profiler)))) 'vector)
          :recoveries (coerce (%safe-copy (nreverse (copy-list (profiler-recoveries profiler)))) 'vector))))

(defun %host-info ()
  (list :machine (or (ignore-errors (machine-instance)) "unknown")
        :machine-type (or (ignore-errors (machine-type)) "unknown")
        :machine-version (or (ignore-errors (machine-version)) "unknown")
        :software-type (or (ignore-errors (software-type)) "unknown")
        :software-version (or (ignore-errors (software-version)) "unknown")))

(defun %lisp-info ()
  (list :implementation (lisp-implementation-type)
        :version (lisp-implementation-version)
        :features (mapcar #'string-downcase (sort (mapcar #'symbol-name *features*) #'string<))))

(defun %feature-info ()
  (list :threaded (not (member :single-threaded *features*))))

(defun profile-report (profiler &key (format :json))
  "Devolve um relatório JSON ou texto humano a partir de um snapshot isolado."
  (let ((snapshot (profiler-snapshot profiler)))
    (ecase format
      (:json (%json-encode snapshot))
      (:chrome-trace (%chrome-trace snapshot))
      (:text (%human-report snapshot)))))

(defun write-profile-report (profiler destination &key (format :json))
  "Escreve um relatório em um stream ou pathname e retorna o snapshot exportado."
  (let ((report (profile-report profiler :format format)))
    (if (streamp destination)
        (write-string report destination)
        (progn
          (ensure-directories-exist destination)
          (with-open-file (stream destination :direction :output :if-exists :supersede
                                  :if-does-not-exist :create :external-format :utf-8)
            (write-string report stream))))
    report))

(defun %human-report (snapshot)
  (with-output-to-string (out)
    (format out "S-Geometry diagnostics~%Host: ~A (~A)~%Lisp: ~A ~A~%Features: ~{~A~^, ~}~%Frame: ~D~%"
            (getf (getf snapshot :host) :machine-type) (getf (getf snapshot :host) :software-type)
            (getf (getf snapshot :lisp) :implementation) (getf (getf snapshot :lisp) :version)
            (getf (getf snapshot :lisp) :features) (getf snapshot :frame))
    (format out "Metrics: CPU=available allocation=~A (~A) GPU=~A GPU pipeline statistics=~A~%"
            (getf (getf snapshot :capabilities) :allocation)
            (getf (getf snapshot :capabilities) :allocation-scope)
            (getf (getf snapshot :capabilities) :gpu)
            (getf (getf snapshot :capabilities) :gpu-pipeline-statistics))
    (when (getf snapshot :renderer-info) (format out "Renderer data: ~S~%" (getf snapshot :renderer-info)))
    (format out "~%Scopes:~%")
    (loop for entry across (getf snapshot :aggregates) do
      (format out "  ~A / ~A [~A, ~A] calls=~D inclusive=~,3F ms exclusive=~,3F ms"
              (or (getf entry :subsystem) "engine") (getf entry :function)
              (or (getf entry :object-class) "-") (or (getf entry :frame-phase) "-")
              (getf entry :calls) (/ (getf entry :inclusive-ns) 1000000d0)
              (/ (getf entry :exclusive-ns) 1000000d0))
      (when (getf entry :allocated-bytes) (format out " allocated=~D B" (getf entry :allocated-bytes)))
      (terpri out))
    (format out "~%Errors (~D):~%" (length (getf snapshot :errors)))
    (loop for entry across (getf snapshot :errors) do
      (format out "  ~A~@[ [~A]~]: ~A~%" (getf entry :condition)
              (getf entry :phase) (getf entry :message)))
    (format out "Recoveries (~D):~%" (length (getf snapshot :recoveries)))
    (loop for entry across (getf snapshot :recoveries) do
      (format out "  ~A~@[ [~A]~]~%" (getf entry :description) (getf entry :phase)))
    (format out "Timeline events: ~D~%" (length (getf snapshot :timeline)))))

(defun %chrome-trace (snapshot)
  "Exporta eventos completos Chrome, preservando domínio e aproximação GPU."
  (let ((document (make-hash-table :test #'equal)))
    (setf (gethash "traceEvents" document)
          (coerce
          (loop for record across (getf snapshot :timeline)
                for kind = (getf record :kind)
                for cpu-timestamp = (getf record :timestamp-ns)
                for timestamp = (or cpu-timestamp (getf record :frame-host-start-ns))
                when (and timestamp (member kind '("scope" "gpu-sample" "frame-end")
                                             :test #'equal)
                          (numberp (getf record :duration-ns)))
                  collect (list :name (or (getf record :name) (getf record :function)
                                          (getf record :phase) kind)
                                :cat (or (getf record :subsystem) "engine")
                                :ph "X" :ts (/ timestamp 1000d0)
                                :dur (/ (getf record :duration-ns) 1000d0)
                                :pid 1 :tid (or (getf record :thread) "engine")
                                :args (list :frame (getf record :frame)
                                            :clock-origin (getf record :clock-origin)
                                            :placement (if (equal kind "gpu-sample")
                                                           "frame-start-correlation" "measured")))
                else when (and timestamp (equal kind "gpu-pipeline-statistics"))
                       collect (list :name "GPU pipeline statistics"
                                     :cat (or (getf record :subsystem) "renderer")
                                     :ph "i" :s "t" :ts (/ timestamp 1000d0)
                                     :pid 1 :tid (or (getf record :thread) "engine")
                                     :args (list :frame (getf record :frame)
                                                 :clock-origin "gpu-query"
                                                 :backend (getf record :backend)
                                                 :counters (getf record :counters))))
                'vector)
          (gethash "displayTimeUnit" document) "ms")
    (%json-encode document)))

(defun %safe-copy (value &optional (seen (make-hash-table :test #'eq)))
  "Copia dados simples, limita ciclos e descarta referências a objetos de runtime."
  (cond ((or (null value) (eq value t) (stringp value) (characterp value) (integerp value)
             (rationalp value) (keywordp value)) value)
        ((floatp value) (if (%finite-float-p value) value nil))
        ((symbolp value) (string-downcase (symbol-name value)))
        ((consp value)
         (if (gethash value seen) "[cycle]"
             (progn (setf (gethash value seen) t)
                    (cons (%safe-copy (car value) seen)
                          (if (listp (cdr value)) (%safe-copy (cdr value) seen) "[improper-list]")))))
        ((hash-table-p value)
         (if (gethash value seen) "[cycle]"
             (progn (setf (gethash value seen) t)
                    (let ((copy (make-hash-table :test #'equal)))
                      (maphash (lambda (key item)
                                 (let ((safe-key (%safe-copy key seen)))
                                   (setf (gethash (if (stringp safe-key) safe-key (%safe-label safe-key)) copy)
                                         (%safe-copy item seen))))
                               value)
                      copy))))
        ((and (vectorp value) (not (stringp value)))
         (if (gethash value seen) "[cycle]"
             (progn (setf (gethash value seen) t)
                    (map 'vector (lambda (item) (%safe-copy item seen)) value))))
        (t (%safe-label value (format nil "<~A>" (type-of value))))))

(defun %finite-float-p (value)
  (and (= value value)
       (handler-case (<= (abs value) most-positive-double-float)
         (error () nil))))

(defun %json-encode (value)
  (with-output-to-string (out) (%json-write value out (make-hash-table :test #'eq))))

(defun %json-write (value stream seen)
  (cond ((null value) (write-string "null" stream))
        ((eq value t) (write-string "true" stream))
        ((eq value :false) (write-string "false" stream))
        ((eq value :true) (write-string "true" stream))
        ((stringp value) (%json-string value stream))
        ((integerp value) (princ value stream))
        ((rationalp value) (%json-string (format nil "~D/~D" (numerator value) (denominator value)) stream))
        ((floatp value) (if (%finite-float-p value) (%json-float value stream) (write-string "null" stream)))
        ((hash-table-p value)
         (if (gethash value seen) (%json-string "[cycle]" stream)
             (progn (setf (gethash value seen) t) (write-char #\{ stream)
                    (let ((first t) (keys nil)) (maphash (lambda (k v) (declare (ignore v)) (push k keys)) value)
                      (dolist (key (sort keys #'string< :key #'%safe-label))
                        (unless first (write-char #\, stream)) (setf first nil)
                        (%json-string (%safe-label key) stream) (write-char #\: stream)
                        (%json-write (gethash key value) stream seen)))
                    (write-char #\} stream))))
        ((and (vectorp value) (not (stringp value)))
         (if (gethash value seen) (%json-string "[cycle]" stream)
             (progn (setf (gethash value seen) t) (write-char #\[ stream)
                    (loop for item across value for first = t then nil do
                      (unless first (write-char #\, stream))
                      (%json-write item stream seen))
                    (write-char #\] stream))))
        ((and (consp value) (%plist-p value))
         (if (gethash value seen) (%json-string "[cycle]" stream)
             (progn (setf (gethash value seen) t) (write-char #\{ stream)
                    (loop for (key item) on value by #'cddr
                          for first = t then nil do
                            (unless first (write-char #\, stream))
                            (%json-string (%safe-label key) stream)
                            (write-char #\: stream)
                            (%json-write item stream seen))
                    (write-char #\} stream))))
        ((consp value)
         (if (gethash value seen) (%json-string "[cycle]" stream)
             (progn (setf (gethash value seen) t) (write-char #\[ stream)
                    (loop for tail on value for first = t then nil do
                      (unless first (write-char #\, stream))
                      (%json-write (car tail) stream seen))
                    (write-char #\] stream))))
        ((symbolp value) (%json-string (string-downcase (symbol-name value)) stream))
        (t (%json-string (%safe-label value) stream))))

(defun %plist-p (value)
  (and (listp value) (evenp (length value))
       (loop for (key item) on value by #'cddr
             always (and (symbolp key) (not (null key))))))

(defun %json-string (string stream)
  (write-char #\" stream)
  (loop for character across string for code = (char-code character) do
    (case character
      (#\" (write-string "\\\"" stream))
      (#\\ (write-string "\\\\" stream))
      (#\Backspace (write-string "\\b" stream))
      (#\Page (write-string "\\f" stream))
      (#\Newline (write-string "\\n" stream))
      (#\Return (write-string "\\r" stream))
      (#\Tab (write-string "\\t" stream))
      (otherwise (if (< code 32) (format stream "\\u~4,'0X" code) (write-char character stream)))))
  (write-char #\" stream))

(defun %json-float (value stream)
  (let* ((text (string-downcase (string-trim '(#\Space) (format nil "~,16G" value))))
         (normalized (with-output-to-string (out)
                       (loop for character across text do
                         (write-char (if (char= character #\d) #\e character) out)))))
    (write-string normalized stream)))
