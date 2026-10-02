;;;; Verifica a primeira entrega do editor em uma janela OpenGL nativa.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples)
(asdf:load-system :sgeo/editor/opengl)

(defparameter *acceptance-scene-path*
  (merge-pathnames "artifacts/editor-acceptance.sgeo" *project-root*))
(defparameter *acceptance-data-path*
  (merge-pathnames "artifacts/editor-acceptance.expected.lisp" *project-root*))

(defun acceptance-check (test description)
  "Interrompe a demonstração quando uma condição verificável falha."
  (unless test (error "M3 acceptance falhou: ~A" description))
  t)

(defun acceptance-command (editor name &rest arguments)
  "Executa um comando pela mesma entrada pública usada pela interface."
  (apply #'sgeo.editor:execute-editor-command editor name arguments))

(defun acceptance-write-data (path data)
  "Grava dados de comparação legíveis para a verificação em processo novo."
  (with-open-file (stream path :direction :output :if-exists :supersede
                          :if-does-not-exist :create :external-format :utf-8)
    (let ((*print-readably* t) (*print-circle* nil) (*print-pretty* t)
          (*print-case* :upcase) (*package* (find-package :keyword)))
      (prin1 data stream)
      (terpri stream))))

(defun acceptance-first-face (mesh)
  "Retorna a primeira face ativa da malha."
  (or (first (sg:mesh-faces mesh)) (error "A malha não possui faces.")))

(defun acceptance-adjacent-face-pair (mesh)
  "Retorna uma face e uma vizinha que formam uma região conectada."
  (loop for face in (sg:mesh-faces mesh)
        for neighbor = (first (sg:face-neighbors mesh face))
        when neighbor return (list face neighbor)
        finally (error "A malha não possui duas faces adjacentes.")))

(defun acceptance-neighbor-edge (mesh vertex other-vertex)
  "Localiza a aresta recém-dividida entre o vértice inserido e o preservado."
  (or (find-if (lambda (edge)
                 (let ((vertices (sg:edge-vertices mesh edge)))
                   (and (member vertex vertices :test #'equalp)
                        (member other-vertex vertices :test #'equalp))))
               (sg:mesh-edges mesh))
      (error "A divisão não produziu a aresta esperada.")))

(defun acceptance-save-expected-data (world)
  "Confirma a versão do esquema e grava o snapshot para a imagem nova."
  (let ((data (sgeo.serialization:scene-data world)))
    (acceptance-check (= (getf (rest data) :version) 1) "versão do esquema")
    (acceptance-write-data *acceptance-data-path* data)))

(defun acceptance-run-reopen-check ()
  "Abre o arquivo salvo em outro SBCL e compara o conteúdo da cena."
  (let ((checker (merge-pathnames "tools/editor-reopen-check.lisp" *project-root*)))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (list "sbcl" "--script" (namestring checker)
                                (namestring *acceptance-scene-path*)
                                (namestring *acceptance-data-path*))
                          :output :string :error-output :string :ignore-error-status t)
      (unless (zerop exit-code)
        (error "A verificação em SBCL novo falhou (~D):~%~A~%~A"
               exit-code output error-output))
      (write-string output)
      t)))

(defun run-editor-acceptance ()
  "Dirige operações M3 no editor nativo e valida persistência entre processos."
  (let* ((world (sgeo.examples:make-kernel-world))
         (object (sg:find-object world "EditableBox"))
         (mesh (sg:mesh-object-geometry object))
         (editor nil) (split-handle nil) (split-original nil)
         (listener-start-revision nil) (listener-done-p nil)
         (saved-p nil) (frames 28))
    (acceptance-check object "objeto inicial")
    (multiple-value-bind (returned report)
        (sgeo.editor.opengl:run-editor
         world :width 1280 :height 800 :visible nil :repl t
         :capture-path (merge-pathnames "artifacts/editor-acceptance.ppm" *project-root*)
         :scene-path *acceptance-scene-path* :max-frames frames
         :frame-hook
         (lambda (active window renderer frame)
           (declare (ignore window renderer))
           (setf editor active)
           (acceptance-check (eq (sgeo.editor:editor-world editor) world)
                             "o editor preserva a instância do mundo")
           (case frame
             (0
              (sgeo.editor:editor-select editor object)
              (setf (sgeo.editor:editor-selection-mode editor) :vertex))
             (1
              (let* ((vertex (first (sg:mesh-vertices mesh)))
                     (position (sg:vertex-position mesh vertex)))
                (acceptance-command editor :move-vertex :object object
                                    :index (sg:handle-index vertex)
                                    :position (sg:v+ position (sg:vec3 0d0 0.05d0 0d0)))))
             (2
              (setf (sgeo.editor:editor-selection-mode editor) :edge)
              (let* ((edge (first (sg:mesh-edges mesh)))
                     (vertices (sg:edge-vertices mesh edge)))
                (setf split-original (first vertices)
                      split-handle
                      (acceptance-command editor :split :object object
                                          :index (sg:handle-index edge)))
                (acceptance-check (sg:mesh-handle-p split-handle) "divisão de aresta")))
             (3
              (let* ((edge (acceptance-neighbor-edge mesh split-handle split-original))
                     (position (sg:vertex-position mesh split-original)))
                (acceptance-command editor :collapse :object object
                                    :index (sg:handle-index edge)
                                    :keep (sg:handle-index split-original)
                                    :position position)))
             (4
              (let* ((vertices (sg:mesh-vertices mesh))
                     (before-data (sgeo.serialization:scene-data world))
                     (second-position (sg:vertex-position mesh (second vertices)))
                     (rejected nil))
                (handler-case
                    (acceptance-command editor :move-vertex :object object
                                        :index (sg:handle-index (first vertices))
                                        :position second-position)
                  (error () (setf rejected t)))
                (acceptance-check rejected "uma edição inválida é rejeitada")
                (acceptance-check (equalp before-data (sgeo.serialization:scene-data world))
                                  "a cena mantém o snapshot anterior")
                (setf (sgeo.editor:editor-selection-mode editor) :face)
                (let ((face (acceptance-first-face mesh)))
                  (acceptance-command editor :extrude :object object
                                      :index (sg:handle-index face) :distance 0.2d0))))
             (5
              (let ((faces (acceptance-adjacent-face-pair mesh)))
                (acceptance-command editor :extrude :object object
                                    :indices (mapcar #'sg:handle-index faces)
                                    :distance 0.15d0)))
             (6
              (setf listener-start-revision (sg:object-revision mesh))
              (sgeo.editor:submit-listener
               editor
               "(defun sgeo.examples:kernel-extrude-distance () 0.12d0) (let* ((object (sg:find-object sgeo:*world* \"EditableBox\")) (mesh (sg:mesh-object-geometry object)) (face (first (sg:mesh-faces mesh)))) (sgeo.examples:extrude-demo-face mesh face))"))
             (7
              ;; Cede tempo à worker do listener; o dono atende a fila em cada quadro.
              (sleep 0.01d0)
              (when (not (sgeo.editor:listener-busy-p editor))
                (let ((output (format nil "~{~A~%~}" (sgeo.editor:editor-listener-output editor))))
                  (acceptance-check (not (search "ERROR:" output)) "listener sem erro")
                  (acceptance-check (> (sg:object-revision mesh) listener-start-revision)
                                    "a operação redefinida alterou a malha viva")
                  (setf listener-done-p t))))
             (8
              ;; A worker pode concluir o formulário logo após a fila do editor ser atendida.
              (let ((deadline (+ (get-internal-real-time) (* 5 internal-time-units-per-second))))
                (loop while (sgeo.editor:listener-busy-p editor)
                      do (sgeo.editor:process-editor-requests editor)
                         (when (> (get-internal-real-time) deadline)
                           (error "O listener não concluiu no prazo da demonstração."))
                         (sleep 0.001d0)))
              (when (not listener-done-p)
                (let ((output (format nil "~{~A~%~}" (sgeo.editor:editor-listener-output editor))))
                  (acceptance-check (not (search "ERROR:" output)) "listener sem erro")
                  (acceptance-check (> (sg:object-revision mesh) listener-start-revision)
                                    "a operação redefinida alterou a malha viva")
                  (setf listener-done-p t)))
              (acceptance-check listener-done-p "o listener conclui a redefinição ao vivo")
              (let ((old-handle (first (sg:mesh-vertices mesh))))
                (acceptance-command editor :split :object object
                                    :index (sg:handle-index (first (sg:mesh-edges mesh))))
                (setf split-handle (first (sgeo.editor:editor-elements editor)))
                (sgeo.editor:undo-edit editor)
                (handler-case
                    (progn (sg:vertex-position mesh old-handle)
                           (error "A undo preservou um handle obsoleto."))
                  (sg:stale-handle-error () t))
                (sgeo.editor:redo-edit editor)
                (handler-case
                    (progn (sg:vertex-position mesh split-handle)
                           (error "A redo preservou um handle obsoleto."))
                  (sg:stale-handle-error () t))))
             (9
              (sgeo.editor:inspect-editor editor object)
              (acceptance-check (sgeo.editor:inspect-value object) "inspeção do objeto")
              (acceptance-command editor :rename :object object :name "EditableBox replay")
              (let ((command (first (sgeo.editor:editor-history editor))))
                (acceptance-check (eq (sgeo.editor:command-name command) :rename)
                                  "registro do comando para replay")
                (sgeo.editor:replay-editor-command editor command)
                (acceptance-check (string= (sg:object-name object) "EditableBox replay")
                                  "replay mantém o comando")))
             (10
              (acceptance-command editor :save :path *acceptance-scene-path*)
              (acceptance-check (probe-file *acceptance-scene-path*) "arquivo de cena versionado")
              (acceptance-save-expected-data world)
              (setf saved-p t))
             (11 (unless saved-p (error "O salvamento não foi concluído."))))))
      (acceptance-check (eq returned editor) "o editor retorna sua instância")
      (acceptance-check (null (sgeo.runtime:runtime-report-platform-error report))
                        "execução da plataforma")
      (acceptance-check (null (sgeo.runtime:runtime-report-render-error report))
                        "renderização e frame-hook")
      (acceptance-check (= frames (sgeo.runtime:runtime-report-frames report))
                        "quantidade de quadros")
      (acceptance-check (sg:validate-mesh mesh) "validade final da malha")
      (acceptance-check saved-p "cena salva")
      (sgeo.editor:close-editor editor))
    (acceptance-run-reopen-check)
    (format t "M3 modelagem: ~D quadros nativos; edição, listener, histórico, inspeção/replay e reabertura verificados.~%"
            frames)
    t))

(handler-case
    (progn (run-editor-acceptance) (uiop:quit 0))
  (error (condition)
    (format *error-output* "Falha na aceitação M3: ~A~%" condition)
    (uiop:quit 1)))
