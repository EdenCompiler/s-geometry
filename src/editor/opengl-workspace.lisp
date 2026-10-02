(in-package #:sgeo.editor.opengl)

(defun %workspace-text (state rect row text &optional (color (%color :text)))
  "Desenha uma linha de diagnóstico limitada à área do painel."
  (let* ((renderer (editor-ui-ui-renderer state))
         (x (+ (first rect) 10))
         (y (+ (second rect) 34 (* row 19)))
         (width (max 0 (- (third rect) 20))))
    (when (< y (+ (second rect) (fourth rect)))
      (sgeo.backend.opengl:ui-text renderer x y (%clip-text renderer text width) color))))

(defun %workspace-heading (state rect title)
  (let ((renderer (editor-ui-ui-renderer state)))
    (sgeo.backend.opengl:ui-rect renderer (first rect) (second rect)
                                 (third rect) 27 (%color :panel-raised))
    (sgeo.backend.opengl:ui-text renderer (+ (first rect) 10) (+ (second rect) 7)
                                 (%clip-text renderer title (- (third rect) 20))
                                 (%color :accent))))

(defun %workspace-number (value)
  (if (realp value) (format nil "~,3F" value) (princ-to-string value)))

(defun %workspace-object-description (object)
  (if object
      (format nil "~A  #~D" (sgeo.core:object-name object)
              (sgeo.core:object-id object))
      "Nenhum"))

(defun %draw-workspace-debug (state rect)
  (let* ((editor (editor-ui-editor state))
         (world (sgeo.editor:editor-world editor))
         (root (sgeo.scene:world-root world))
         (camera (sgeo.scene:world-camera world))
         (selection (sgeo.scene:world-selection world))
         (objects (sgeo.editor:editor-objects editor))
         (mesh (and (typep selection 'sgeo.scene:mesh-object)
                    (sgeo.scene:mesh-object-geometry selection)))
         (mesh-p (and mesh (typep mesh 'sgeo.geometry:half-edge-mesh)))
         (counts (and mesh-p (sgeo.geometry:mesh-counts mesh)))
         (transform (and selection (sgeo.scene:scene-object-local-transform selection)))
         (position (and transform (sgeo.math:transform-position transform)))
         (row 0))
    (%workspace-heading state rect "Diagnóstico da cena")
    (flet ((line (text &optional (color (%color :text)))
             (%workspace-text state rect row text color)
             (incf row)))
      (line (format nil "Mundo: ~A" (%workspace-object-description root)))
      (line (format nil "Nós: ~D   Seleção: ~A" (length objects)
                    (%workspace-object-description selection)))
      (line (format nil "Vista: ~A   Ferramenta: ~A   Modo: ~A"
                    (sgeo.editor:editor-view editor) (sgeo.editor:editor-tool editor)
                    (sgeo.editor:editor-selection-mode editor)) (%color :muted))
      (when selection
        (line (format nil "Pai: ~A" (%workspace-object-description
                                      (sgeo.scene:scene-object-parent selection))))
        (line (format nil "Visível: ~A   Ativo: ~A"
                      (sgeo.scene:scene-object-visible-p selection)
                      (sgeo.scene:scene-object-enabled-p selection)))
        (when position
          (line (format nil "Posição local: ~A, ~A, ~A"
                        (%workspace-number (aref position 0))
                        (%workspace-number (aref position 1))
                        (%workspace-number (aref position 2)))))
        (when mesh-p
          (line (format nil "Topologia: ~D vértices · ~D arestas · ~D faces"
                        (getf counts :vertices) (getf counts :edges) (getf counts :faces)))
          (line (format nil "Meias-arestas: ~D   Contorno: ~D"
                        (getf counts :half-edges) (getf counts :boundary-edges)))
          (line (format nil "Elementos selecionados: ~D"
                        (length (sgeo.editor:editor-elements editor))))))
      (let ((eye (sgeo.math:transform-position (sgeo.scene:scene-object-local-transform camera)))
            (target (sgeo.scene:camera-target camera)))
        (line (format nil "Câmera ~A · olho ~A, ~A, ~A"
                      (sgeo.scene:camera-projection-mode camera)
                      (%workspace-number (aref eye 0)) (%workspace-number (aref eye 1))
                      (%workspace-number (aref eye 2))))
        (line (format nil "Alvo: ~A, ~A, ~A"
                      (%workspace-number (aref target 0)) (%workspace-number (aref target 1))
                      (%workspace-number (aref target 2))))
        (line (format nil "FOV ~A · planos ~A / ~A"
                      (%workspace-number (sgeo.scene:camera-fov camera))
                      (%workspace-number (sgeo.scene:camera-near camera))
                      (%workspace-number (sgeo.scene:camera-far camera))))))))

(defun %workspace-runtime-metrics ()
  "Retorna métricas de alocação do SBCL quando o runtime as disponibiliza."
  (let* ((package (find-package "SB-EXT"))
         (bytes-symbol (and package (find-symbol "GET-BYTES-CONSED" package)))
         (gc-symbol (and package (find-symbol "*GC-RUN-TIME*" package)))
         (bytes (and bytes-symbol (fboundp bytes-symbol)
                     (ignore-errors (funcall bytes-symbol))))
         (gc-time (and gc-symbol (boundp gc-symbol)
                       (ignore-errors (symbol-value gc-symbol)))))
    (values bytes gc-time)))

(defun %draw-workspace-profile (state rect)
  (let* ((editor (editor-ui-editor state))
         (profile (sgeo.editor:editor-profile editor))
         (samples (editor-ui-profile-samples state))
         (renderer (editor-ui-ui-renderer state))
         (bytes nil) (gc-time nil))
    (multiple-value-setq (bytes gc-time) (%workspace-runtime-metrics))
    (%workspace-heading state rect "Perfil de execução")
    (%workspace-text state rect 0
                     (format nil "Quadros: ~D   Uploads: ~D"
                             (or (getf profile :frames) 0)
                             (or (getf profile :uploads) 0)))
    (%workspace-text state rect 1
                     (format nil "Quadro recente: ~A ms   Malhas GPU: ~A"
                             (%workspace-number (* 1000d0 (or (getf profile :frame-time) 0d0)))
                             (or (getf profile :gpu-meshes) "N/D")) (%color :muted))
    (when bytes
      (let* ((last-bytes (editor-ui-profile-last-bytes state))
             (delta (and (numberp last-bytes) (<= last-bytes bytes)
                         (- bytes last-bytes))))
        (%workspace-text state rect 2
                         (format nil "Memória alocada: ~D MB~@[   +~D KB recente~]"
                                 (floor bytes (* 1024 1024))
                                 (and delta (floor delta 1024))))
        (setf (editor-ui-profile-last-bytes state) bytes)))
    (when gc-time
      (%workspace-text state rect 3 (format nil "Coleta de memória: ~A ms"
                                             (%workspace-number
                                              (* 1000d0 (/ gc-time internal-time-units-per-second))))
                       (%color :muted)))
    (let* ((chart-x (+ (first rect) 10))
           (chart-y (+ (second rect) 130))
           (chart-width (max 1 (- (third rect) 20)))
           (chart-height (max 32 (min 180 (- (fourth rect) 174))))
           (samples (subseq samples 0 (min 120 (length samples))))
           (maximum (max 1d-9 (reduce #'max samples :initial-value 0d0)))
           (count (length samples))
           (point-width (/ chart-width (max 1 count))))
      (sgeo.backend.opengl:ui-rect renderer chart-x chart-y chart-width chart-height
                                   (%color :panel-raised))
      (when (> count 1)
        (loop for (a b) on samples while b for index from 0
              for x1 = (+ chart-x (* index point-width))
              for x2 = (+ chart-x (* (1+ index) point-width))
              for y1 = (- (+ chart-y chart-height)
                          (* chart-height (/ (min maximum a) maximum)))
              for y2 = (- (+ chart-y chart-height)
                          (* chart-height (/ (min maximum b) maximum)))
              do (sgeo.backend.opengl:ui-line renderer x1 y1 x2 y2 (%color :accent) :width 2d0)))
      (sgeo.backend.opengl:ui-text renderer chart-x (+ chart-y chart-height 5)
                                   "Amostras recentes em ms" (%color :muted)))))

(defun %draw-workspace-timeline (state rect)
  (let* ((editor (editor-ui-editor state))
         (renderer (editor-ui-ui-renderer state))
         (x (+ (first rect) 10)) (y (+ (second rect) 38))
         (width (max 1 (- (third rect) 20)))
         (time (sgeo.editor:editor-time editor))
         (maximum (max 10d0 (* 1d0 (ceiling time 10d0))))
         (fraction (min 1d0 (/ time maximum))))
    (%workspace-heading state rect "Relógio da cena")
    (%workspace-text state rect 0 (format nil "Tempo: ~A s   Velocidade: ~Ax"
                                          (%workspace-number time)
                                          (%workspace-number (sgeo.editor:editor-time-scale editor))))
    (%workspace-text state rect 1
                     (if (sgeo.editor:editor-playing-p editor)
                         "Estado: em reprodução" "Estado: pausado")
                     (%color :muted))
    (%ui-button state x (+ y 42) 62 26 "Play"
                (list :workspace-clock :play)
                :selected-p (sgeo.editor:editor-playing-p editor) :compact-p t)
    (%ui-button state (+ x 65) (+ y 42) 62 26 "Pausa"
                (list :workspace-clock :pause) :compact-p t)
    (%ui-button state (+ x 130) (+ y 42) 62 26 "Passo"
                (list :workspace-clock :step) :compact-p t)
    (%ui-button state x (+ y 71) 90 26 "Lento"
                (list :workspace-clock :slower) :compact-p t)
    (%ui-button state (+ x 94) (+ y 71) 90 26 "Rápido"
                (list :workspace-clock :faster) :compact-p t)
    (sgeo.backend.opengl:ui-rect renderer x (+ y 104) width 12 (%color :panel-raised))
    (sgeo.backend.opengl:ui-rect renderer x (+ y 104) (* width fraction) 12 (%color :accent))
    (sgeo.backend.opengl:ui-text renderer x (+ y 122)
                                 "A posição acompanha o relógio da cena." (%color :muted))))

(defun %draw-workspace-layout (state rect)
  (let* ((x (+ (first rect) 10)) (y (+ (second rect) 40))
         (ui (editor-ui-ui-renderer state)))
    (%workspace-heading state rect "Painéis e espaço de trabalho")
    (dolist (entry `(("Hierarquia" :hierarchy ,(editor-ui-show-hierarchy-p state))
                     ("Inspector" :inspector ,(editor-ui-show-inspector-p state))
                     ("Histórico" :history ,(editor-ui-show-history-p state))
                     ("Listener" :listener ,(editor-ui-show-listener-p state))))
      (let ((label (first entry)) (key (second entry)) (visible (third entry)))
        (%ui-button state x y (- (third rect) 20) 26
                    (format nil "~A: ~A" label (if visible "visível" "oculto"))
                    (list :workspace-toggle key) :selected-p visible)
        (incf y 31)))
    (incf y 8)
    (dolist (entry `(("Painel esquerdo" :left ,(or (editor-ui-left-width state) 214))
                     ("Painel direito" :right ,(or (editor-ui-right-width state) 286))
                     ("Painel inferior" :bottom ,(or (editor-ui-bottom-height state) 166))))
      (let ((label (first entry)) (key (second entry)) (size (third entry)))
        (sgeo.backend.opengl:ui-text ui x y
                                     (%clip-text ui (format nil "~A: ~D px" label size)
                                                 (- (third rect) 120)) (%color :text))
        (%ui-button state (- (+ (first rect) (third rect)) 94) (- y 4) 36 24 "-"
                    (list :workspace-size key -20) :compact-p t)
        (%ui-button state (- (+ (first rect) (third rect)) 52) (- y 4) 36 24 "+"
                    (list :workspace-size key 20) :compact-p t)
        (incf y 32)))
    (%ui-button state x y (- (third rect) 20) 26 "Restaurar padrão"
                (list :workspace-reset))))

(defun %draw-workspace-tools (state rect)
  "Desenha a ferramenta escolhida no painel esquerdo do workspace."
  (case (editor-ui-workspace-tool state)
    (:debug (%draw-workspace-debug state rect))
    (:profile (%draw-workspace-profile state rect))
    (:timeline (%draw-workspace-timeline state rect))
    (:layout (%draw-workspace-layout state rect))
    (otherwise nil)))

(defun %dispatch-workspace-action (state action)
  "Aplica uma ação de ferramenta e informa se ela pertence a este módulo."
  (let ((editor (editor-ui-editor state)))
    (case (first action)
      (:workspace-tool
       (setf (editor-ui-workspace-tool state) (second action))
       (when (second action)
         (setf (editor-ui-show-hierarchy-p state) t
               (editor-ui-left-width state)
               (max 320 (or (editor-ui-left-width state) 214))))
       t)
      (:workspace-toggle
       (case (second action)
         (:hierarchy (setf (editor-ui-show-hierarchy-p state)
                           (not (editor-ui-show-hierarchy-p state))))
         (:inspector (setf (editor-ui-show-inspector-p state)
                           (not (editor-ui-show-inspector-p state))))
         (:history (setf (editor-ui-show-history-p state)
                         (not (editor-ui-show-history-p state))))
         (:listener (setf (editor-ui-show-listener-p state)
                          (not (editor-ui-show-listener-p state))))
         (otherwise (return-from %dispatch-workspace-action nil)))
       t)
      (:workspace-size
       (let* ((key (second action)) (delta (third action))
              (accessor (ecase key (:left #'editor-ui-left-width)
                                  (:right #'editor-ui-right-width)
                                  (:bottom #'editor-ui-bottom-height)))
              (current (or (funcall accessor state)
                           (ecase key (:left 214) (:right 286)
                                      (:bottom (case (sgeo.editor:editor-layout editor)
                                                 (:development 220) (:inspection 116)
                                                 (otherwise 166))))))
              (minimum (if (eq key :bottom) 78 120))
              (maximum (if (eq key :bottom) (max 78 (floor (editor-ui-height state) 2))
                           (max 120 (floor (editor-ui-width state) 2)))))
         (case key
           (:left (setf (editor-ui-left-width state)
                        (min maximum (max minimum (+ current delta)))))
           (:right (setf (editor-ui-right-width state)
                         (min maximum (max minimum (+ current delta)))))
           (:bottom (setf (editor-ui-bottom-height state)
                          (min maximum (max minimum (+ current delta)))))))
       t)
      (:workspace-reset
       (setf (editor-ui-left-width state) nil
             (editor-ui-right-width state) nil
             (editor-ui-bottom-height state) nil
             (editor-ui-show-hierarchy-p state) t
             (editor-ui-show-inspector-p state) t
             (editor-ui-show-history-p state) t
             (editor-ui-show-listener-p state) t
             (editor-ui-workspace-tool state) nil)
       t)
      (:workspace-clock
       (case (second action)
         (:play (sgeo.editor:execute-editor-command editor :play))
         (:pause (sgeo.editor:execute-editor-command editor :pause))
         (:step (sgeo.editor:execute-editor-command editor :step :dt (/ 1d0 60d0)))
         (:slower (sgeo.editor:execute-editor-command
                   editor :time-scale :value
                   (max 0.125d0 (/ (sgeo.editor:editor-time-scale editor) 2d0))))
         (:faster (sgeo.editor:execute-editor-command
                   editor :time-scale :value
                   (min 16d0 (* 2d0 (sgeo.editor:editor-time-scale editor)))))
         (otherwise (return-from %dispatch-workspace-action nil)))
       t)
      (otherwise nil))))
