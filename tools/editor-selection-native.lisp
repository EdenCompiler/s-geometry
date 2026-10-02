;;;; Confere seleção e edição pela entrada nativa real da viewport.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples)
(asdf:load-system :sgeo/editor/opengl)

(defun selection-native-check (condition description)
  "Interrompe a prova quando um gesto real da interface não produz o resultado."
  (unless condition (error "Seleção nativa falhou: ~A" description))
  t)

(defun selection-native-action (hit)
  "Retorna a ação armazenada em uma região clicável da interface."
  (fifth hit))

(defun selection-native-click (state window x y &optional mods)
  "Aciona os callbacks nativos registrados para cursor e botão esquerdo."
  (funcall (sgeo.backend.opengl::%cursor-handler window)
           (/ x (sgeo.editor.opengl::editor-ui-scale-x state))
           (/ y (sgeo.editor.opengl::editor-ui-scale-y state)))
  (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :press mods)
  (funcall (sgeo.backend.opengl::%mouse-button-handler window) :left :release mods))

(defun selection-native-key (window key &optional mods)
  "Aciona o callback nativo de teclado registrado na janela."
  (funcall (sgeo.backend.opengl::%key-handler window) key 0 :press mods))

(defun selection-native-type (window text)
  "Digita texto pelo callback de caracteres Unicode da janela."
  (loop for character across text
        do (funcall (sgeo.backend.opengl::%character-handler window)
                    (char-code character))))

(defun selection-native-find-hit (state predicate description)
  "Localiza um controle por sua ação, sem assumir coordenadas fixas de tela."
  (or (find-if (lambda (hit) (funcall predicate (selection-native-action hit)))
               (sgeo.editor.opengl::editor-ui-hits state))
      (error "Controle de interface ausente: ~A" description)))

(defun selection-native-click-hit (state window predicate description)
  "Clica no centro do controle encontrado pelo conteúdo de sua ação."
  (let ((hit (selection-native-find-hit state predicate description)))
    (selection-native-click state window (+ (first hit) (/ (third hit) 2d0))
                            (+ (second hit) (/ (fourth hit) 2d0)))
    hit))

(defun selection-native-mode (state window mode)
  "Ativa um modo pela ação do botão correspondente na barra superior."
  (selection-native-click-hit
   state window (lambda (action) (equal action (list :mode mode)))
   (format nil "modo ~S" mode)))

(defun selection-native-screen-point (state world point)
  "Projeta um ponto mundial para coordenadas nativas da janela."
  (let ((rect (sgeo.editor.opengl::editor-ui-viewport-rect state)))
    (multiple-value-bind (x y)
        (sgeo.editor:projected-position world point (third rect) (fourth rect))
      (when (and x y)
        (values (+ (first rect) x) (+ (second rect) y))))))

(defun selection-native-viewport-point-p (state x y)
  "Confirma que o ponto projetado cai dentro do retângulo da viewport."
  (sgeo.editor.opengl::%viewport-contains-p state x y))

(defun selection-native-handle-kind (elements kind)
  "Verifica se a seleção atual contém elementos da classe pedida."
  (and elements
       (every (lambda (handle) (eq (sgeo.geometry:handle-kind handle) kind)) elements)))

(defun selection-native-world-vertex (object mesh vertex)
  "Transforma a posição local de um vértice para o espaço mundial."
  (sgeo.math:transform-point
   (sgeo.scene:world-transform object)
   (sgeo.geometry:vertex-position mesh vertex)))

(defun selection-native-face-center (object mesh face)
  "Calcula o centro de uma face em coordenadas mundiais."
  (let* ((vertices (sgeo.geometry:face-vertices mesh face))
         (sum (reduce #'sgeo.math:v+ vertices
                      :key (lambda (vertex)
                             (sgeo.geometry:vertex-position mesh vertex))
                      :initial-value (sgeo.math:make-vec3 0d0 0d0 0d0)))
         (local (sgeo.math:v* (/ 1d0 (length vertices)) sum)))
    (sgeo.math:transform-point (sgeo.scene:world-transform object) local)))

(defun selection-native-visible-face-p (state world object x y face)
  "Usa a projeção da câmera para evitar candidatos ocluídos na busca visual."
  (let ((rect (sgeo.editor.opengl::editor-ui-viewport-rect state)))
    (multiple-value-bind (hit-object elements)
        (sgeo.editor:pick-element world :face
                                  (- x (first rect)) (- y (second rect))
                                  (third rect) (fourth rect) :object object)
      (and (eq hit-object object) (member face elements :test #'equalp)))))

(defun selection-native-click-visible-vertex (state window world object mesh)
  "Clica projeções reais até a viewport selecionar um vértice visível."
  (loop for vertex in (sgeo.geometry:mesh-vertices mesh)
        for point = (selection-native-world-vertex object mesh vertex)
        do (multiple-value-bind (x y) (selection-native-screen-point state world point)
             (when (and x y (selection-native-viewport-point-p state x y))
               (selection-native-click state window x y)
               (when (selection-native-handle-kind
                      (sgeo.editor:editor-elements (sgeo.editor.opengl::editor-ui-editor state))
                      :vertex)
                 (return-from selection-native-click-visible-vertex
                   (first (sgeo.editor:editor-elements
                           (sgeo.editor.opengl::editor-ui-editor state)))))))
        finally (error "Nenhum clique projetado selecionou um vértice visível.")))

(defun selection-native-edit-vertex-through-inspector (state window mesh vertex)
  "Edita a componente X clicando no campo visível do inspetor."
  (let* ((editor (sgeo.editor.opengl::editor-ui-editor state))
         (before (sgeo.geometry:vertex-position mesh vertex))
         (next-value (+ (aref before 0) 0.375d0)))
    (selection-native-check
     (equal (second (sgeo.editor:editor-inspected editor)) mesh)
     "o inspetor está mostrando a malha do vértice selecionado")
    (selection-native-click-hit
     state window
     (lambda (action)
       (and (consp action) (eq (first action) :inspect-field)
            (eq (second action) :vertex-position) (eql (third action) 0)))
     "componente X da posição do vértice")
    (loop repeat (length (sgeo.editor.opengl::editor-ui-field-string state))
          do (selection-native-key window :backspace))
    (selection-native-type window (format nil "~,6F" next-value))
    (selection-native-key window :enter '(:control))
    (selection-native-check
     (> (abs (- (aref (sgeo.geometry:vertex-position mesh vertex) 0) (aref before 0)))
        0.3d0)
     "a edição numérica do inspetor move o vértice selecionado")))

(defun selection-native-click-visible-edge (state window world object mesh)
  "Clica no ponto médio projetado até a viewport selecionar uma aresta."
  (loop for edge in (sgeo.geometry:mesh-edges mesh)
        for vertices = (sgeo.geometry:edge-vertices mesh edge)
        for a = (selection-native-world-vertex object mesh (first vertices))
        for b = (selection-native-world-vertex object mesh (second vertices))
        for midpoint = (sgeo.math:v* 0.5d0 (sgeo.math:v+ a b))
        do (multiple-value-bind (x y) (selection-native-screen-point state world midpoint)
             (when (and x y (selection-native-viewport-point-p state x y))
               (selection-native-click state window x y)
               (when (selection-native-handle-kind
                      (sgeo.editor:editor-elements (sgeo.editor.opengl::editor-ui-editor state))
                      :edge)
                 (return-from selection-native-click-visible-edge
                   (first (sgeo.editor:editor-elements
                           (sgeo.editor.opengl::editor-ui-editor state)))))))
        finally (error "Nenhum clique projetado selecionou uma aresta visível.")))

(defun selection-native-open-split-command (state window)
  "Abre Edit e ativa Split edge pelos itens de menu desenhados."
  (selection-native-click-hit
   state window
   (lambda (action)
     (and (consp action) (eq (first action) :popup)
          (some (lambda (item) (search "Split edge" (first item))) (fourth action))))
   "menu Edit com Split edge"))

(defun selection-native-click-visible-face (state window world object mesh)
  "Clica nos centros projetados até selecionar uma face visível."
  (loop for face in (sgeo.geometry:mesh-faces mesh)
        for center = (selection-native-face-center object mesh face)
        do (multiple-value-bind (x y) (selection-native-screen-point state world center)
             (when (and x y (selection-native-viewport-point-p state x y))
               (selection-native-click state window x y)
               (let ((elements (sgeo.editor:editor-elements
                                (sgeo.editor.opengl::editor-ui-editor state))))
                 (when (selection-native-handle-kind elements :face)
                   (return-from selection-native-click-visible-face
                     (values (first elements) x y))))))
        finally (error "Nenhum clique projetado selecionou uma face visível.")))

(defun selection-native-region-toggle (state window world object mesh first-face)
  "Adiciona uma face adjacente com Shift e remove a mesma com outro clique."
  (let ((added nil)
        (neighbors
          (handler-case (sgeo.geometry:face-neighbors mesh first-face)
            (error (condition)
              (error "A semente de região não é face viva (kind=~S handle-mesh=~D mesh-id=~D): ~A"
                     (sgeo.geometry:handle-kind first-face)
                     (sgeo.geometry:handle-mesh-id first-face)
                     (sgeo.core:object-id mesh) condition)))))
    (dolist (neighbor neighbors)
      (multiple-value-bind (nx ny)
          (selection-native-screen-point state world
                                         (selection-native-face-center object mesh neighbor))
        (when (and nx ny (selection-native-viewport-point-p state nx ny)
                   (selection-native-visible-face-p state world object nx ny neighbor))
          (selection-native-click state window nx ny '(:shift))
          (let ((elements (sgeo.editor:editor-elements
                           (sgeo.editor.opengl::editor-ui-editor state))))
            (when (and (= (length elements) 2)
                       (member first-face elements :test #'equalp)
                       (member neighbor elements :test #'equalp))
              (setf added neighbor)
              (selection-native-click state window nx ny '(:shift))
              (selection-native-check
               (and (= (length (sgeo.editor:editor-elements
                                (sgeo.editor.opengl::editor-ui-editor state))) 1)
                    (equalp first-face
                            (first (sgeo.editor:editor-elements
                                    (sgeo.editor.opengl::editor-ui-editor state)))))
               "Shift-clique na mesma face remove somente essa face da região")
              (return))))))
    (selection-native-check added
                            "Shift-clique em face adjacente adiciona à região")))

(defun selection-native-split-edge-through-listener (editor mesh edge)
  "Executa split-edge público na worker e atende a fila no thread proprietário."
  (sgeo.editor:submit-listener
   editor
   "(let* ((object (sgeo.scene:world-selection sgeo:*world*)) (mesh (sgeo.scene:mesh-object-geometry object)) (edge (first (sgeo.editor:editor-elements sgeo.editor:*editor*)))) (sgeo.geometry:split-edge mesh edge))")
  (let ((deadline (+ (get-internal-real-time) (* 5 internal-time-units-per-second))))
    (loop while (sgeo.editor:listener-busy-p editor)
          do (sgeo.editor:process-editor-requests editor)
             (when (> (get-internal-real-time) deadline)
               (error "O split-edge do listener não concluiu no prazo da prova."))
             (sleep 0.001d0)))
  (selection-native-check
   (handler-case
       (progn (sgeo.geometry:edge-vertices mesh edge) nil)
     (sgeo.geometry:stale-handle-error () t))
   "split-edge público aposenta o identificador selecionado")
  t)

(defun run-editor-selection-native ()
  "Prova interação de seleção em uma janela OpenGL nativa oculta."
  (let* ((world (sgeo.examples:make-kernel-world))
         (object (sgeo.scene:find-object world "EditableBox"))
         (mesh (sgeo.scene:mesh-object-geometry object))
         (editor nil) (state nil) (vertex nil) (edge nil) (face nil)
         (face-x nil) (face-y nil) (listener-edge nil) (failure nil) (frames 7))
    (multiple-value-bind (returned report)
        (sgeo.editor.opengl:run-editor
         world :width 1280 :height 800 :visible nil :max-frames frames
         :frame-hook
         (lambda (active window renderer frame)
           (declare (ignore renderer))
           (setf editor active
                 state sgeo.editor.opengl::*active-ui-state*)
           (unless failure
             (handler-case
               (case frame
                 (0
                  (let ((point (sgeo.math:transform-point
                                 (sgeo.scene:world-transform object)
                                 (sgeo.math:make-vec3 0d0 0d0 0d0))))
                    (multiple-value-bind (x y)
                        (selection-native-screen-point state world point)
                      (selection-native-check
                       (and x y (selection-native-viewport-point-p state x y))
                       "o centro do objeto cai dentro da viewport")
                    (selection-native-click state window x y))
                    (selection-native-check
                     (eq (sgeo.scene:world-selection world) object)
                     "clique nativo seleciona o objeto vivo")
                    (selection-native-mode state window :vertex)
                    (setf vertex (selection-native-click-visible-vertex
                                  state window world object mesh))
                    (selection-native-check
                     (eq (sgeo.geometry:handle-kind vertex) :vertex)
                     "clique nativo seleciona vértice visível")))
                 (1
                  (selection-native-edit-vertex-through-inspector state window mesh vertex)
                  (selection-native-mode state window :edge)
                  (setf edge (selection-native-click-visible-edge
                              state window world object mesh))
                  (selection-native-check
                   (eq (sgeo.geometry:handle-kind edge) :edge)
                   "clique nativo seleciona aresta" )
                  (selection-native-open-split-command state window))
                 (2
                  (let ((before-count (length (sgeo.geometry:mesh-vertices mesh))))
                    (selection-native-click-hit
                     state window
                     (lambda (action)
                       (and (consp action) (eq (first action) :command)
                            (eq (second action) :split)))
                     "item Split edge aberto no menu Edit")
                    (selection-native-check
                     (= (length (sgeo.geometry:mesh-vertices mesh)) (1+ before-count))
                     "comando Edit > Split divide a aresta escolhida")))
                 (3
                  (selection-native-mode state window :face)
                  (multiple-value-bind (selected x y)
                      (selection-native-click-visible-face state window world object mesh)
                    (setf face selected face-x x face-y y))
                  (selection-native-check
                   (eq (sgeo.geometry:handle-kind face) :face)
                   "clique nativo seleciona face visível")
                  (selection-native-mode state window :region)
                  (selection-native-click state window face-x face-y)
                  (setf face (first (sgeo.editor:editor-elements editor)))
                  (selection-native-check
                   (and (= (length (sgeo.editor:editor-elements editor)) 1)
                        (eq (sgeo.geometry:handle-kind face) :face))
                   "clique em Region começa com uma face"))
                 (4
                  (selection-native-region-toggle state window world object mesh face))
                 (5
                  (selection-native-mode state window :edge)
                  (setf listener-edge
                        (selection-native-click-visible-edge state window world object mesh))
                  (selection-native-split-edge-through-listener editor mesh listener-edge))
                 (6
                  (selection-native-check
                   (null (sgeo.editor:editor-elements editor))
                   "a UI limpa a seleção de aresta aposentada no quadro seguinte")
                  (selection-native-check
                   (eq (sgeo.editor:editor-inspected editor) object)
                   "o inspetor volta ao objeto após a aresta ser aposentada"))
                 (otherwise nil))
               (error (condition)
                 (setf failure (list frame condition)))))))
      (selection-native-check (eq returned editor) "run-editor retorna o editor dirigido")
      (when failure (error "Falha no gesto nativo no quadro ~D: ~A"
                           (first failure) (second failure)))
      (selection-native-check (= (sgeo.runtime:runtime-report-frames report) frames)
                              "a janela executa os quadros da sequência")
      (selection-native-check (null (sgeo.runtime:runtime-report-render-error report))
                              "a renderização nativa conclui sem erro")
      (format t "EDITOR_SELECTION_NATIVE_OK objeto, vértice/inspetor, aresta/split, face e região~%")
      t)))

(handler-case
    (progn (run-editor-selection-native) (uiop:quit 0))
  (error (condition)
    (format *error-output* "Falha na prova de seleção nativa: ~A~%" condition)
    (uiop:quit 1)))
