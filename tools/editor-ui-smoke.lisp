;;;; Exercita a interface nativa pelos handlers registrados em uma janela GLFW oculta.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples)
(asdf:load-system :sgeo/editor/opengl)

(defun ui-smoke-check (condition description)
  "Interrompe o teste quando um fluxo visível da interface falha."
  (unless condition (error "UI smoke falhou: ~A" description))
  t)

(defun ui-smoke-click (window x y &optional mods)
  "Envia movimento e clique pelos callbacks registrados pelo backend."
  (funcall (sgeo.backend.opengl::%cursor-handler window) x y)
  (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :press mods)
  (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :release mods))

(defun ui-smoke-action (window action)
  "Clica no controle visível correspondente à ação, usando suas coordenadas atuais."
  (let* ((state sgeo.editor.opengl::*active-ui-state*)
         (hit (find-if (lambda (hit)
                         (if (functionp action) (funcall action (fifth hit))
                             (equal action (fifth hit))))
                       (sgeo.editor.opengl::editor-ui-hits state))))
    (ui-smoke-check hit (format nil "controle disponível: ~S" action))
    (ui-smoke-click window (+ (first hit) (/ (third hit) 2d0))
                           (+ (second hit) (/ (fourth hit) 2d0)))))

(defun ui-smoke-menu (window label)
  "Abre o menu que contém o item identificado pelo rótulo visível."
  (ui-smoke-action window
    (lambda (action) (and (eq (first action) :popup)
                         (find label (fourth action) :key #'first :test #'string=)))))

(defun ui-smoke-key (window key &optional mods)
  "Envia uma tecla pela função registrada no GLFW."
  (funcall (sgeo.backend.opengl::%key-handler window) key 0 :press mods))

(defun ui-smoke-type (window text)
  "Envia os caracteres pelo callback Unicode registrado."
  (loop for character across text
        do (funcall (sgeo.backend.opengl::%character-handler window)
                    (char-code character))))

(defun ui-smoke-count-meshes (world)
  "Conta objetos de malha sem depender de seus nomes de apresentação."
  (labels ((walk (object)
             (+ (if (typep object 'sgeo.scene:mesh-object) 1 0)
                (reduce #'+ (sgeo.scene:scene-object-children object)
                        :key #'walk :initial-value 0))))
    (walk (sgeo.scene:world-root world))))

(defun ui-smoke-run ()
  "Valida menus, modos, inspetor, listener, linha do tempo e gizmo."
  (let* ((world (sgeo.examples:make-kernel-world))
         (object (sgeo.scene:find-object world "EditableBox"))
         (mesh-count (ui-smoke-count-meshes world))
         (mesh-count-after-menu nil)
         (position-before nil)
         (position-after nil)
         (editor nil)
         (first-failure nil)
         (gizmo-start nil)
         (gizmo-screen nil)
         (gizmo-delta nil)
         (capture (merge-pathnames "artifacts/editor-ui.ppm" *project-root*)))
    (ui-smoke-check object "a cena inicial contém a caixa editável")
    (multiple-value-bind (returned report)
        (sgeo.editor.opengl:run-editor
         world :width 1280 :height 800 :visible nil :max-frames 50
         :capture-path capture
         :frame-hook
         (lambda (active window renderer frame)
           (declare (ignore renderer))
           (setf editor active)
           (handler-case
           (case frame
             (0
              (sgeo.editor:editor-select editor object)
              (sgeo.editor:inspect-editor editor object))
             (1 (ui-smoke-menu window "Box"))
             (2 (ui-smoke-action window '(:command :create :kind :box)))
             (3
              (setf mesh-count-after-menu (ui-smoke-count-meshes world))
              (ui-smoke-check (> mesh-count-after-menu mesh-count)
                              "o menu Criar adiciona uma malha")
              (ui-smoke-action window '(:view :front)))
             (4
              (ui-smoke-check (eq (sgeo.editor:editor-view editor) :front)
                              "o botão Frente altera a vista")
              (ui-smoke-action window '(:mode :vertex)))
             (5
              (ui-smoke-check (eq (sgeo.editor:editor-selection-mode editor) :vertex)
                              "o botão Vértice altera o modo de seleção")
              (ui-smoke-menu window "Development"))
             (6 (ui-smoke-action window '(:layout :development)))
             (7
              (setf mesh-count-after-menu (ui-smoke-count-meshes world))
              (ui-smoke-check (eq (sgeo.editor:editor-layout editor) :development)
                              "o menu Workspace altera o painel")
              (funcall (sgeo.backend.opengl::%cursor-handler window) 250 135)
              (funcall (sgeo.backend.opengl::%mouse-button-handler window) :right :press nil))
             (8
              (ui-smoke-action window '(:command :create :kind :box))
              (setf object (sgeo.scene:world-selection world)))
             (9
              (ui-smoke-check (> (ui-smoke-count-meshes world) mesh-count-after-menu)
                              "o menu contextual cria uma caixa")
              ;; Posição X no inspetor, com entrada substituída por backspace.
              (ui-smoke-action window '(:inspect-field :position 0))
              (dotimes (index 24) (ui-smoke-key window :backspace))
              (ui-smoke-type window "1")
              (ui-smoke-key window :enter '(:control)))
             (10
              (setf position-after
                    (copy-seq (sgeo.math:transform-position
                               (sgeo.scene:scene-object-local-transform object))))
              (ui-smoke-check (> (aref position-after 0) 0.5d0)
                              "o controle numérico do inspetor altera a posição")
              ;; Rola até a referência Geometria e navega para a malha.
              (dotimes (index 3)
                (funcall (sgeo.backend.opengl::%scroll-handler window) 0d0 -1d0)))
             (11
              (ui-smoke-action window (list :inspect-reference (sgeo.scene:mesh-object-geometry object))))
             (12
              (ui-smoke-check (typep (sgeo.editor:editor-inspected editor)
                                    'sgeo.geometry:half-edge-mesh)
                              "a referência Geometria navega até a malha")
              (ui-smoke-action window '(:inspect-back)))
             (13
              (ui-smoke-check (eq (sgeo.editor:editor-inspected editor) object)
                              "Back retorna ao objeto inspecionado")
              (ui-smoke-action window '(:listener))
              (ui-smoke-type window "(+ 2 3)")
              (ui-smoke-key window :enter))
             (14
              (ui-smoke-key window :enter '(:control)))
             (17
              (ui-smoke-check (some (lambda (line) (search "5" line))
                                    (sgeo.editor:editor-listener-output editor))
                              "Ctrl+Enter mostra o resultado do listener")
              (ui-smoke-action window '(:command :play)))
             (18
              (ui-smoke-check (sgeo.editor:editor-playing-p editor)
                              "o botão Play inicia o relógio")
              (ui-smoke-action window '(:command :pause)))
             (19
              (ui-smoke-check (not (sgeo.editor:editor-playing-p editor))
                              "o botão Pause para o relógio")
              (ui-smoke-action window '(:mode :object))
              (ui-smoke-action window '(:view :perspective)))
             (20
              (ui-smoke-action window '(:tool :translate))
              (setf position-before
                    (copy-seq (sgeo.math:transform-position
                               (sgeo.scene:scene-object-local-transform object)))
                    gizmo-start (sgeo.math:transform-point
                                 (sgeo.scene:world-transform object)
                                 (sgeo.math:make-vec3 0d0 0d0 0d0)))
              (multiple-value-bind (x y ex ey)
                  (sgeo.editor.opengl::%gizmo-axis-points
                   sgeo.editor.opengl::*active-ui-state* object :x)
                (ui-smoke-check (and x y ex ey) "leitura da projeção do gizmo")
                (setf gizmo-screen (list (+ x (* 0.65d0 (- ex x)))
                                         (+ y (* 0.65d0 (- ey y))))
                      gizmo-delta (list (+ x (* 0.95d0 (- ex x)))
                                        (+ y (* 0.95d0 (- ey y)))))))
             (21
              (ui-smoke-check (eq (sgeo.editor:editor-tool editor) :translate)
                              "o botão Move ativa a ferramenta")
              (when gizmo-screen
                (let ((x (first gizmo-screen)) (y (second gizmo-screen)))
                  (funcall (sgeo.backend.opengl::%cursor-handler window) x y)
                  (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :press nil)
                  (ui-smoke-check (sgeo.editor.opengl::editor-ui-drag-gizmo
                                   sgeo.editor.opengl::*active-ui-state*)
                                  "o clique no eixo inicia o arraste"))))
             (22
              (when gizmo-delta
                (funcall (sgeo.backend.opengl::%cursor-handler window)
                         (first gizmo-delta) (second gizmo-delta))))
             (23
              (when gizmo-delta
                (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :release nil)))
             (24
              (setf position-after
                    (copy-seq (sgeo.math:transform-position
                               (sgeo.scene:scene-object-local-transform object))))
              (ui-smoke-check (not (equalp position-before position-after))
                              "arrastar o gizmo altera o objeto selecionado"))
             (25 (ui-smoke-menu window "Profile"))
             (26 (ui-smoke-action window '(:workspace-tool :profile)))
             (27
              (ui-smoke-check (sgeo.editor.opengl::editor-ui-profile-samples sgeo.editor.opengl::*active-ui-state*)
                              "a vista de perfil contém amostras reais")
              (sgeo.backend.opengl:capture-framebuffer-ppm window
                (merge-pathnames "artifacts/editor-profile.ppm" *project-root*))
              (ui-smoke-menu window "Debug world"))
             (28 (ui-smoke-action window '(:workspace-tool :debug)))
             (29
              (ui-smoke-check (eq :debug (sgeo.editor.opengl::editor-ui-workspace-tool sgeo.editor.opengl::*active-ui-state*))
                              "a vista de diagnóstico está ativa")
              (ui-smoke-menu window "Configure panels"))
             (30 (ui-smoke-action window '(:workspace-tool :layout)))
             (31 (ui-smoke-action window '(:workspace-size :left 20)))
             (32
              (ui-smoke-check (= 340 (third (getf (sgeo.editor.opengl::editor-ui-layout-rects
                                                  sgeo.editor.opengl::*active-ui-state*) :left)))
                              "o painel pode ser redimensionado")
              (ui-smoke-action window '(:workspace-toggle :inspector)))
             (33
              (ui-smoke-check (zerop (third (getf (sgeo.editor.opengl::editor-ui-layout-rects
                                                  sgeo.editor.opengl::*active-ui-state*) :right)))
                              "ocultar o inspetor amplia a viewport")
              (ui-smoke-action window '(:workspace-toggle :history)))
             (34
              (ui-smoke-check (not (find :replay (sgeo.editor.opengl::editor-ui-hits
                                                sgeo.editor.opengl::*active-ui-state*)
                                        :key (lambda (hit) (first (fifth hit)))))
                              "o histórico oculto não recebe cliques")
              (ui-smoke-action window '(:workspace-toggle :listener)))
             (35
              (ui-smoke-check (not (find :listener (sgeo.editor.opengl::editor-ui-hits
                                                  sgeo.editor.opengl::*active-ui-state*)
                                        :key (lambda (hit) (first (fifth hit)))))
                              "o listener oculto não recebe cliques")
              (ui-smoke-action window '(:workspace-reset)))
             (36 (ui-smoke-menu window "Timeline"))
             (37 (ui-smoke-action window '(:workspace-tool :timeline)))
             (38 (ui-smoke-action window '(:workspace-clock :step)))
             (39
              (ui-smoke-check (plusp (sgeo.editor:editor-time editor)) "Passo avança o relógio")
              (ui-smoke-action window '(:workspace-clock :faster)))
             (40
              (ui-smoke-check (> (sgeo.editor:editor-time-scale editor) 1d0) "a velocidade é editável")
              (ui-smoke-menu window "Scene hierarchy"))
             (41 (ui-smoke-action window '(:workspace-tool nil)))
             (42 (glfw:set-window-size 1024 640 (sgeo.backend.opengl::glfw-native-window window)))
             (45
              (ui-smoke-check (= 1024 (sgeo.editor.opengl::editor-ui-width sgeo.editor.opengl::*active-ui-state*))
                              "o resize nativo atualiza o layout")))
             (error (condition)
               (unless first-failure (setf first-failure (list frame condition)))
               (sgeo.platform:request-window-close window)))))
      (when first-failure
        (error "UI smoke falhou no quadro ~D: ~A" (first first-failure) (second first-failure)))
      (ui-smoke-check (eq returned editor) "run-editor retorna a instância do editor")
      (when (sgeo.runtime:runtime-report-render-error report)
        (error (sgeo.runtime:runtime-report-render-error report)))
      (ui-smoke-check (= (sgeo.runtime:runtime-report-frames report) 50)
                      "a aplicação executa os quadros previstos")
      (ui-smoke-check (null (sgeo.runtime:runtime-report-render-error report))
                      "nenhum erro de renderização ocorre")
      (ui-smoke-check (probe-file capture) "a captura de tela é gravada")
      (format t "UI_SMOKE_OK frames=~D capture=~A~%"
              (sgeo.runtime:runtime-report-frames report) capture)
      (let ((popup-capture (merge-pathnames "artifacts/editor-popup.ppm" *project-root*)))
        (multiple-value-bind (popup-editor popup-report)
            (sgeo.editor.opengl:run-editor
         (sgeo.examples:make-kernel-world) :width 1280 :height 800 :visible nil
         :max-frames 2 :capture-path popup-capture
         :frame-hook
         (lambda (active window renderer frame)
           (declare (ignore active renderer))
           (when (zerop frame)
             (funcall (sgeo.backend.opengl::%cursor-handler window) 250d0 135d0)
             (funcall (sgeo.backend.opengl::%mouse-button-handler window) :right :press nil))))
          (declare (ignore popup-editor))
          (ui-smoke-check (and (= 2 (sgeo.runtime:runtime-report-frames popup-report))
                               (null (sgeo.runtime:runtime-report-render-error popup-report)))
                          "o menu contextual é renderizado sem erro"))
        (ui-smoke-check (probe-file popup-capture) "a captura do menu contextual é gravada")
        (format t "UI_POPUP_CAPTURE=~A~%" popup-capture))
      t)))

(ui-smoke-run)
