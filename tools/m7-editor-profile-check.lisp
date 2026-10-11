;;;; Aceita o perfilamento nativo do editor e exporta relatórios e captura.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/editor/opengl)

(defun editor-profile-check (condition description)
  "Interrompe a aceitação quando uma medição esperada não foi produzida."
  (unless condition (error "Verificação de perfil do editor falhou: ~A" description))
  t)

;; Exercita o formato vetorial do snapshot sem inicializar janela ou dispositivo.
(multiple-value-bind (top top-allocator)
    (sgeo.editor.opengl::%profile-aggregate-display-data
     #((:function "slow" :inclusive-ns 100 :allocated-bytes 10)
       (:function "allocator" :inclusive-ns 50 :allocated-bytes 30)
       (:function "third" :inclusive-ns 25 :allocated-bytes 5)
       (:function "fourth" :inclusive-ns 10 :allocated-bytes 2)))
  (editor-profile-check (and (listp top) (= 3 (length top)))
                        "ranking de CPU recebe agregados vetoriais")
  (editor-profile-check (equal "slow" (getf (first top) :function))
                        "ranking de CPU ordenado por tempo inclusivo")
  (editor-profile-check (equal "allocator" (getf top-allocator :function))
                        "maior alocador selecionado do vetor"))

(let* ((profiler (sgeo.diagnostics:make-profiler :timeline-limit 64))
       (world (sgeo.scene:make-world))
       (box (sgeo.scene:make-mesh-object
             (sgeo.geometry:make-half-edge-box :name "Profile acceptance box")
             :name "Profile acceptance box"))
       (renderer nil) (editor nil) (report nil)
       (profile-panel-active nil) (profile-panel-rendered nil) (box-edited nil)
       (json-path (merge-pathnames "artifacts/m7-editor-profile.json" *project-root*))
       (trace-path (merge-pathnames "artifacts/m7-editor-profile-trace.json" *project-root*))
       (capture-path (merge-pathnames "artifacts/m7-editor-profile.ppm" *project-root*)))
  (sgeo.scene:add-to-world world box)
  (unwind-protect
       (multiple-value-setq (editor report)
         (sgeo.editor.opengl:run-editor
          world :width 1280 :height 800 :visible nil :max-frames 12 :repl nil
          :profiler profiler :capture-path capture-path
          :frame-hook
          (lambda (active-editor window active-renderer frame)
            (declare (ignore window))
            (setf renderer active-renderer)
            (cond
              ((zerop frame)
               (editor-profile-check
                (sgeo.editor.opengl::%dispatch-workspace-action
                 sgeo.editor.opengl::*active-ui-state* '(:workspace-tool :profile))
                "Profile workspace activation")
               (setf profile-panel-active t))
              ((= frame 1)
               (let ((state sgeo.editor.opengl::*active-ui-state*))
                 (editor-profile-check
                  (eq :profile (sgeo.editor.opengl::editor-ui-workspace-tool state))
                  "Profile workspace remains selected")
                 ;; Esse campo só é atualizado pelo desenho do painel de perfil.
                 (editor-profile-check
                  (plusp (sgeo.editor.opengl::editor-ui-profile-last-bytes state))
                  "Profile workspace was drawn"))
               (setf profile-panel-rendered t))
              ((= frame 3)
               (sgeo.editor:execute-editor-command
                active-editor :translate :object box :delta #(0.25d0 0d0 0d0))
               (setf box-edited t))))))
    ;; Mantém os artefatos disponíveis mesmo se uma verificação posterior falhar.
    (sgeo.diagnostics:write-profile-report profiler json-path :format :json)
    (sgeo.diagnostics:write-profile-report profiler trace-path :format :chrome-trace))
  (editor-profile-check (and report
                             (null (sgeo.runtime:runtime-report-render-error report))
                             (null (sgeo.runtime:runtime-report-platform-error report)))
                        "janela e renderizador concluíram sem erro")
  (editor-profile-check (= 12 (sgeo.runtime:runtime-report-frames report))
                        "limite de doze quadros nativos")
  (editor-profile-check (and profile-panel-active profile-panel-rendered)
                        "painel Profile ativado e desenhado")
  (editor-profile-check box-edited "edição do objeto box no callback de quadro")
  (editor-profile-check (equal "Profile acceptance box"
                                (sgeo.core:object-name
                                 (sgeo.scene:find-object (sgeo.editor:editor-world editor)
                                                         "Profile acceptance box")))
                        "box editado permanece na cena")
  (let* ((snapshot (sgeo.diagnostics:profiler-snapshot profiler))
         (aggregates (getf snapshot :aggregates))
         (timeline (getf snapshot :timeline))
         (gpu-samples (remove-if-not (lambda (entry) (equal "gpu-sample" (getf entry :kind)))
                                     timeline)))
    (dolist (function '("editor/update" "editor/viewport" "editor/ui"))
      (editor-profile-check
       (find function aggregates :key (lambda (entry) (getf entry :function)) :test #'equal)
       (format nil "CPU scope ~A" function)))
    (editor-profile-check (<= (length timeline) 64) "histórico limitado a 64 registros")
    (editor-profile-check (plusp (length gpu-samples)) "consultas GPU reais registradas")
    (editor-profile-check
     (every (lambda (entry)
              (and (numberp (getf entry :duration-ns))
                   (>= (getf entry :duration-ns) 0)
                   (equal "gpu-query" (getf entry :clock-origin))))
            gpu-samples)
     "duração de GPU em nanossegundos e domínio próprio")
    (when (sgeo.diagnostics:profiler-metrics-available-p profiler)
      (editor-profile-check
       (some (lambda (entry) (numberp (getf entry :allocated-bytes))) aggregates)
       "alocação disponível para o painel de principais alocadores"))
    (editor-profile-check (probe-file json-path) "relatório JSON exportado")
    (editor-profile-check (probe-file trace-path) "trace Chrome exportado")
    (editor-profile-check (probe-file capture-path) "captura PPM exportada")
    (editor-profile-check (null (sgeo.backend.opengl::%profile-queries renderer))
                          "consultas OpenGL liberadas no encerramento")
    (editor-profile-check (not (sgeo.scene:world-running-p world))
                          "mundo desconectado do laço do editor")
    (editor-profile-check (not (sgeo.editor:editor-running-p editor))
                          "editor encerrado")
    (format t "~&M7 editor profiling: 12 hidden frames, ~D GPU samples, bounded timeline, capture and reports exported.~%"
            (length gpu-samples))))
