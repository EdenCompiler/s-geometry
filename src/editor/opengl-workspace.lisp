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
  "Desenha clipes e chaves vivos; o cursor amostra os mesmos objetos de animação."
  (let* ((editor (editor-ui-editor state))
         (renderer (editor-ui-ui-renderer state))
         (data (sgeo.editor:timeline-data editor))
         (clip (getf data :clip)) (track (getf data :track))
         (x (+ (first rect) 10)) (y (+ (second rect) 35))
         (width (max 1 (- (third rect) 20)))
         (duration (max 0.001d0 (getf data :duration)))
         (time (getf data :time)) (tracks (getf data :tracks)))
    (%workspace-heading state rect "Animation timeline")
    (sgeo.backend.opengl:ui-text renderer x y
      (%clip-text renderer (if clip (princ-to-string (or (slot-value clip 'sgeo.animation::name) "Clip"))
                              "No animation clips") width) (%color :accent))
    (%ui-button state x (+ y 21) 50 25 "Play" '(:workspace-clock :play) :compact-p t :text-scale 0.8d0
                :selected-p (sgeo.editor:editor-playing-p editor))
    (%ui-button state (+ x 53) (+ y 21) 60 25 "Pause" '(:workspace-clock :pause) :compact-p t :text-scale 0.8d0)
    (%ui-button state (+ x 116) (+ y 21) 50 25 "Step" '(:workspace-clock :step) :compact-p t :text-scale 0.8d0)
    (%ui-button state x (+ y 50) 58 25 "0.5x" '(:workspace-clock :slower)
                :compact-p t :text-scale 0.8d0)
    (%ui-button state (+ x 61) (+ y 50) 58 25 "2x" '(:workspace-clock :faster)
                :compact-p t :text-scale 0.8d0)
    (sgeo.backend.opengl:ui-text renderer (+ x 124) (+ y 56)
      (format nil "~,1Fx" (sgeo.editor:editor-time-scale editor)) (%color :muted) :scale 0.8d0)
    (if (null clip)
        (progn
          (%ui-button state x (+ y 82) width 26 "Animate position"
                      '(:command :animation-create))
          (sgeo.backend.opengl:ui-text renderer x (+ y 117) "File: Import glTF" (%color :muted)))
        (let* ((ruler-y (+ y 115)) (rows-y (+ ruler-y 27))
               (count (max 1 (floor (- (fourth rect) 238) 27)))
               (selected (or (position track tracks) 0))
               (start (* count (floor selected count)))
               (player (getf data :player)))
          (%ui-button state x (+ y 78) 48 25 "Clip" '(:timeline-next-clip) :compact-p t :text-scale 0.8d0)
          (%ui-button state (+ x 50) (+ y 78) 48 25 "Key+" '(:command :animation-record) :compact-p t :text-scale 0.8d0)
          (%ui-button state (+ x 100) (+ y 78) 40 25 "Del" '(:command :animation-delete) :compact-p t :text-scale 0.8d0)
          (%ui-button state (+ x 142) (+ y 78) 48 25 "Loop" '(:timeline-loop) :compact-p t :text-scale 0.8d0
                      :selected-p (and player (sgeo.animation:player-looping-p player)))
          (sgeo.backend.opengl:ui-rect renderer x ruler-y width 20 (%color :panel-raised))
          (%ui-hit state x ruler-y width 20 (list :timeline-scrub x width duration))
          (dotimes (i 3)
            (let ((tick-x (+ x (* width (/ i 2d0)))))
              (sgeo.backend.opengl:ui-line renderer tick-x ruler-y tick-x (+ ruler-y 5) (%color :muted))
              (sgeo.backend.opengl:ui-text renderer (min (+ x width -30) tick-x) (+ ruler-y 6)
                 (format nil "~,1F" (* duration (/ i 2d0))) (%color :muted) :scale 0.8d0)))
          (loop for item in (subseq tracks start (min (length tracks) (+ start count)))
                for row from 0 for row-y = (+ rows-y (* row 27)) do
             (sgeo.backend.opengl:ui-rect renderer x row-y width 24
                (%color (if (eq item track) :panel-selected :panel-raised)))
             (%ui-hit state x row-y width 24 (list :timeline-track item))
             (when (typep item 'sgeo.animation:property-track)
               (sgeo.backend.opengl:ui-text renderer x row-y
                  (%clip-text renderer (format nil "~A ~S"
                     (let ((target (sgeo.animation:track-target item)))
                       (if (typep target 'sgeo.core:sgeo-object) (sgeo.core:object-name target)
                           (princ-to-string (class-name (class-of target)))))
                     (sgeo.animation:track-path item)) width) (%color :muted))
               (loop for key in (sgeo.animation:track-keys item) for index from 0
                     for key-x = (+ x (* width (/ (first key) duration))) do
                  (sgeo.backend.opengl:ui-rect renderer (- key-x 3) (+ row-y 16) 7 7
                     (%color (if (and (eq item track) (eql index (getf data :key))) :accent :text)))
                  (%ui-hit state (- key-x 5) (+ row-y 13) 11 11 (list :timeline-key item index))))
             (sgeo.backend.opengl:ui-line renderer (+ x (* width (min 1d0 (/ time duration)))) row-y
                (+ x (* width (min 1d0 (/ time duration)))) (+ row-y 24) (%color :accent)))
          (let ((controls-y (+ rows-y (* count 27) 4)))
            (%ui-button state x controls-y 32 24 "<" '(:timeline-track-step -1) :compact-p t :text-scale 0.8d0)
            (%ui-button state (+ x 35) controls-y 32 24 ">" '(:timeline-track-step 1) :compact-p t :text-scale 0.8d0)
            (%ui-button state (+ x 70) controls-y 56 24 "-0.1" '(:timeline-key-step -0.1d0) :compact-p t :text-scale 0.8d0)
            (%ui-button state (+ x 129) controls-y 56 24 "+0.1" '(:timeline-key-step 0.1d0) :compact-p t :text-scale 0.8d0)
            (sgeo.backend.opengl:ui-text renderer x (+ controls-y 29)
               (format nil "~,3F / ~,3F s" time duration) (%color :muted)))))))

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
      (:timeline-next-clip
       (let* ((clips (getf (sgeo.editor:timeline-data editor) :clips))
              (index (or (position (sgeo.editor:editor-animation-clip editor) clips) 0)))
         (when clips (sgeo.editor:select-animation-clip editor (nth (mod (1+ index) (length clips)) clips)))) t)
      (:timeline-track
       (setf (sgeo.editor:editor-animation-track editor) (second action)
             (sgeo.editor:editor-animation-key editor) nil
             (sgeo.editor:editor-inspected editor) (second action)) t)
      (:timeline-key
       (let* ((track (second action)) (index (third action))
              (key (nth index (sgeo.animation:track-keys track))))
         (setf (sgeo.editor:editor-animation-track editor) track
               (sgeo.editor:editor-animation-key editor) index)
         (sgeo.editor:scrub-animation editor (first key))) t)
      (:timeline-scrub
       (destructuring-bind (kind x width duration) action
         (declare (ignore kind))
         (sgeo.editor:scrub-animation editor (* duration (max 0d0 (min 1d0 (/ (- (editor-ui-mouse-x state) x) width)))))) t)
      (:timeline-loop
       (let ((player (sgeo.editor:editor-animation-player editor)))
         (when player (setf (sgeo.animation:player-looping-p player)
                            (not (sgeo.animation:player-looping-p player))))) t)
      (:timeline-track-step
       (let* ((tracks (getf (sgeo.editor:timeline-data editor) :tracks))
              (index (or (position (sgeo.editor:editor-animation-track editor) tracks) 0)))
         (when tracks (setf (sgeo.editor:editor-animation-track editor)
                            (nth (mod (+ index (second action)) (length tracks)) tracks)
                            (sgeo.editor:editor-animation-key editor) nil))) t)
      (:timeline-key-step
       (let* ((track (sgeo.editor:editor-animation-track editor))
              (index (sgeo.editor:editor-animation-key editor)))
         (when (and track index)
           (sgeo.editor:move-animation-key editor
             (max 0d0 (+ (first (nth index (sgeo.animation:track-keys track))) (second action)))))) t)
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
