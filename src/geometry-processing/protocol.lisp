(in-package #:sgeo.geometry-processing)

(define-condition geometry-processing-error (error)
  ((reason :initarg :reason :reader processing-error-reason))
  (:report (lambda (condition stream)
             (format stream "Falha no processamento geométrico: ~A"
                     (processing-error-reason condition)))))

(define-condition unsupported-compute-error (geometry-processing-error) ())

(defstruct (compute-capabilities
            (:conc-name capabilities-)
            (:constructor %make-compute-capabilities
                (&key supported-p backend reason version device)))
  "Capacidades verificadas no dispositivo e contexto atuais."
  (supported-p nil :type boolean :read-only t)
  (backend :unknown :read-only t)
  (reason "Não verificado." :type string :read-only t)
  (version nil :read-only t)
  (device nil :read-only t))

(defstruct (geometry-processing-result
            (:conc-name %processing-result-)
            (:constructor %make-geometry-processing-result
                (&key geometry source-revision positions normals operation backend)))
  "Saída GPU lida de volta, vinculada à revisão CPU publicada que a originou."
  (geometry nil :read-only t)
  ;; Esta revisão é a publicada após o commit dos vértices, não a revisão anterior à edição.
  (source-revision 0 :type integer :read-only t)
  (positions #() :type vector :read-only t)
  (normals #() :type vector :read-only t)
  (operation :transform :read-only t)
  (backend :unknown :read-only t))

(defun make-geometry-processing-result (&key geometry source-revision positions normals operation backend)
  "Cria um resultado com cópias próprias dos vetores lidos do dispositivo."
  (%make-geometry-processing-result
   :geometry geometry :source-revision source-revision
   :positions (copy-seq positions) :normals (copy-seq normals)
   :operation operation :backend backend))

(defun processing-result-geometry (result) (%processing-result-geometry result))
(defun processing-result-source-revision (result) (%processing-result-source-revision result))
(defun processing-result-positions (result) (copy-seq (%processing-result-positions result)))
(defun processing-result-normals (result) (copy-seq (%processing-result-normals result)))
(defun processing-result-operation (result) (%processing-result-operation result))
(defun processing-result-backend (result) (%processing-result-backend result))

(defgeneric processor-capabilities (processor)
  (:documentation "Relata capacidades reais do dispositivo associado ao processador."))

(defgeneric process-geometry (processor geometry &key scale translation
                                                   amplitude frequency phase)
  (:documentation
   "Transforma/deforma geometria no dispositivo e retorna posições e normais lidas de volta."))
