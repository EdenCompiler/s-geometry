;;;; Exercita janelas reais, dados enviados à GPU e o REPL da mesma imagem Lisp.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples)

(defparameter *artifact-directory* (merge-pathnames "artifacts/" *project-root*))
(ensure-directories-exist *artifact-directory*)

(defun healthy-report-p (report)
  "Verifica que a execução não escondeu erros de plataforma ou de renderização."
  (and (null (sg:runtime-report-render-error report))
       (null (sg:runtime-report-platform-error report))))

(defun close-enough-matrix-p (a b)
  "Compara matrizes obtidas antes e depois da redefinição de um comportamento."
  (every (lambda (x y) (< (abs (- x y)) 1d-9)) a b))

(defun verify-triangle ()
  "Verifica M0 sem usar o gancho opcional, cobrindo o laço normal do programa."
  (let ((world (sgeo.examples:make-triangle-world)))
    (multiple-value-bind (returned renderer report)
        (sg:run world :visible nil :max-frames 3
                :capture-path (merge-pathnames "triangle.ppm" *artifact-directory*))
      (assert (eq world returned))
      (assert (healthy-report-p report) () "Relatório do triângulo: ~S" report)
      (assert (= 3 (sg:runtime-report-frames report)))
      (assert (= 1 (sg:runtime-report-uploads report)))
      (assert (= 3 (sgeo.render:renderer-frame-count renderer)))
      (assert (not (sg:world-running-p world)))
      (format t "~&M0: triângulo renderizado em 3 quadros; 1 envio de malha.~%"))))

(defun verify-live-scene ()
  "Verifica edição, picking, cache por revisão e redefinição com o viewport ativo."
  (let* ((world (sgeo.examples:make-live-world))
         (cube (sg:find-object world "Cube"))
         (geometry (sg:mesh-object-geometry cube))
         (original-id (sg:object-id cube))
         (frozen-matrix nil))
    (unwind-protect
         (multiple-value-bind (returned renderer report)
             (sg:run
              world :visible nil :max-frames 8
              :capture-path (merge-pathnames "live-scene.ppm" *artifact-directory*)
              :frame-hook
              (lambda (active window renderer frame)
                (declare (ignore window))
                (assert (eq world active))
                (assert (sg:world-running-p active))
                (assert (= frame (sgeo.render:renderer-frame-count renderer)))
                (assert (null (sgeo.render:renderer-last-error renderer)))
                (when (plusp frame)
                  (sgeo.backend.opengl:check-opengl-error "quadro anterior da cena"))
                (case frame
                  (0
                   (let* ((eye (sg:camera-eye (sg:world-camera world)))
                          (center (sg:local->world cube (sg:vec3)))
                          (picked (sg:ray-cast world (sg:make-ray eye (sg:v- center eye)))))
                     (assert (eq cube picked))
                     (setf (sg:world-selection world) picked)))
                  (1
                   (assert (= 2 (sgeo.render:renderer-upload-count renderer)))
                   (sg:translate cube '(0 0.2d0 0))
                   (sg:set-material-color (sg:mesh-object-material cube) '(0.3d0 0.8d0 0.65d0)))
                  (2
                   ;; Mover e recolorir não reconstrói os buffers de geometria.
                   (assert (= 2 (sgeo.render:renderer-upload-count renderer)))
                   (let ((revision (sg:object-revision geometry))
                         (positions (sg:mesh-positions geometry))
                         (rejected nil))
                     (handler-case (sg:set-mesh-position geometry 1000 '(0 0 0))
                       (sg:validation-error () (setf rejected t)))
                     (assert rejected)
                     (assert (= revision (sg:object-revision geometry)))
                     (assert (equalp positions (sg:mesh-positions geometry))))
                   (sg:set-mesh-position geometry 0 (sg:vec3 -1 -0.85d0 -0.85d0)))
                  (3
                   (assert (= 3 (sgeo.render:renderer-upload-count renderer))))
                  (4
                   (eval '(defun sgeo.examples:spin-rate () 0d0))
                   (setf frozen-matrix (sg:world-transform cube)))
                  (5
                   (assert (close-enough-matrix-p frozen-matrix (sg:world-transform cube)))
                   (eval '(defun sgeo.examples:spin-rate () 1d0)))
                  (6
                   (assert (not (close-enough-matrix-p frozen-matrix (sg:world-transform cube))))
                   (let ((worker (bt:make-thread
                                  (lambda () (sg:translate cube '(0.1d0 0 0)))
                                  :name "sgeo alteração externa durante renderização")))
                     (bt:join-thread worker)))
                  (7
                   (assert (= 3 (sgeo.render:renderer-upload-count renderer)))
                   (assert (eq geometry (sg:mesh-object-geometry cube)))
                   (assert (= original-id (sg:object-id cube)))))))
           (declare (ignore renderer))
           (assert (eq world returned))
           (assert (healthy-report-p report) () "Relatório da cena: ~S" report)
           (assert (= 8 (sg:runtime-report-frames report)))
           (assert (= 3 (sg:runtime-report-uploads report)))
           (assert (eq cube (sg:find-object world "Cube")))
           (assert (not (sg:world-running-p world)))
           (format t "~&M1: 8 quadros, picking da instância viva, edição e redefinição; 3 envios de malha.~%"))
      (eval '(defun sgeo.examples:spin-rate () 0.35d0)))))

(defun verify-external-repl ()
  "Alimenta o listener com formas multilinha e verifica recuperação após um erro."
  (let* ((world (sgeo.examples:make-triangle-world))
         (object (sg:find-object world "Triangle"))
         (error-output (make-string-output-stream))
         (output (make-string-output-stream))
         (*standard-output* output)
         (*error-output* error-output)
         (*standard-input*
           (make-string-input-stream
            ")
             (loop until (> (symbol-value (intern \"*REPL-FRAMES*\" :cl-user)) 1)
                   do (sleep 0.005d0))
             (assert (sg:world-running-p sg:*world*))
             (sg:set-position
                (sg:find-object sg:*world* \"Triangle\") '(0.25d0 0 0))
             (error \"controlled-repl-error\")
             (setf sg:*selection*
                   (sg:find-object sg:*world* \"Triangle\"))
             (values :first :second)
             (defparameter cl-user::*history-proof* (list * /))
             (defparameter cl-user::*repl-proof* :done)")))
    (setf (symbol-value (intern "*REPL-PROOF*" :cl-user)) nil)
    (setf (symbol-value (intern "*REPL-FRAMES*" :cl-user)) 0)
    (multiple-value-bind (returned renderer report)
        (sg:run world :visible nil :repl t :max-frames 50
                :frame-hook
                (lambda (active window renderer frame)
                  (declare (ignore active frame))
                  (setf (symbol-value (intern "*REPL-FRAMES*" :cl-user))
                        (sgeo.render:renderer-frame-count renderer))
                  ;; A pausa curta dá oportunidade de execução ao leitor concorrente.
                  (sleep 0.005d0)
                  (when (eq (symbol-value (intern "*REPL-PROOF*" :cl-user)) :done)
                    (sgeo.platform:request-window-close window))))
      (declare (ignore renderer))
      (assert (eq world returned))
      (assert (healthy-report-p report))
      (assert (>= (sg:runtime-report-frames report) 3))
      (assert (eq (symbol-value (intern "*REPL-PROOF*" :cl-user)) :done))
      (assert (equal (symbol-value (intern "*HISTORY-PROOF*" :cl-user))
                     '(:first (:first :second))))
      (assert (eq object (sg:world-selection world)))
      (assert (= 0.25d0 (sg:vx (sg:local->world object (sg:vec3)))))
      (let ((diagnostics (get-output-stream-string error-output)))
        (assert (search "Erro ao ler a forma" diagnostics))
        (assert (search "controlled-repl-error" diagnostics)))
      (assert (notany (lambda (thread)
                       (string= "sgeo interactive listener" (bt:thread-name thread)))
                     (bt:all-threads))))
    (format *terminal-io* "~&M1: REPL concorrente, múltiplos valores, seleção e recuperação de erro verificados.~%")))

(handler-case
    (progn (verify-triangle) (verify-live-scene) (verify-external-repl)
           (format t "~&Verificação gráfica concluída. Capturas em ~A~%" *artifact-directory*)
           (uiop:quit 0))
  (error (condition)
    (format *error-output* "~&Falha na verificação gráfica: ~A~%" condition)
    (uiop:quit 1)))
