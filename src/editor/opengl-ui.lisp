(in-package #:sgeo.editor.opengl)

(defvar *active-ui-state* nil)

(defstruct (editor-ui (:constructor %make-editor-ui))
  editor window renderer ui-renderer
  (width 1) (height 1) (scale-x 1d0) (scale-y 1d0)
  (hits nil) (popup nil) (popup-hits nil) (popup-x 0) (popup-y 0) (popup-width 198)
  (focus :viewport) (listener-string "") (field-edit nil) (field-string "")
  (mouse-x 0d0) (mouse-y 0d0) (last-x 0d0) (last-y 0d0)
  (left-down nil) (camera-motion nil) (timeline-drag nil) (drag-gizmo nil) (drag-origin nil)
  (drag-start-position nil) (drag-start-transform nil)
  (drag-start-x 0d0) (drag-start-y 0d0)
  (drag-current-x 0d0) (drag-current-y 0d0)
  (inspector-scroll 0) (history-scroll 0) (output-scroll 0)
  (workspace-tool nil) (left-width nil) (right-width nil) (bottom-height nil)
  (show-hierarchy-p t) (show-inspector-p t) (show-history-p t) (show-listener-p t)
  (profile-samples nil) (profile-last-bytes 0)
  (viewport-rect nil) (layout-rects nil) (capture-path nil)
  (render-condition nil) (frame 0) (previous-time 0d0)
  (terminal-thread nil) (terminal-stop-flag nil))

(defparameter +ui-colors+
  '(:background (0.035 0.045 0.065 1.0)
    :panel (0.075 0.091 0.12 1.0)
    :panel-raised (0.105 0.13 0.17 1.0)
    :panel-selected (0.13 0.25 0.33 1.0)
    :border (0.17 0.21 0.27 1.0)
    :text (0.86 0.9 0.95 1.0)
    :muted (0.56 0.63 0.71 1.0)
    :accent (0.13 0.63 0.81 1.0)
    :orange (0.98 0.62 0.19 1.0)
    :red (0.92 0.3 0.29 1.0)
    :green (0.31 0.77 0.47 1.0)
    :blue (0.32 0.57 0.96 1.0)))

(defun %color (name)
  (getf +ui-colors+ name))

(defun %clip-text (renderer text max-width &optional (scale 1d0))
  "Limita um rótulo à largura disponível, preservando espaço para reticências."
  (let* ((glyphs (sgeo.backend.opengl::ui-renderer-glyphs renderer))
         (glyph (aref glyphs (char-code #\M)))
         (advance (* scale (if glyph (sgeo.backend.opengl::ui-glyph-advance glyph) 10d0)))
         (count (max 0 (floor max-width (max 1d0 advance)))))
    (if (<= (length text) count) text
        (if (< count 4) (subseq text 0 count)
            (concatenate 'string (subseq text 0 (- count 3)) "...")))))

(defun %rect-contains-p (x y rect)
  (and rect (<= (first rect) x (+ (first rect) (third rect)))
       (<= (second rect) y (+ (second rect) (fourth rect)))))

(defun %ui-hit (state x y width height action)
  (push (list x y width height action) (editor-ui-hits state)))

(defun %ui-button (state x y width height label action &key selected-p (compact-p nil) (text-scale 1d0))
  (let ((renderer (editor-ui-ui-renderer state)))
    (sgeo.backend.opengl:ui-rect renderer x y width height
                                 (%color (if selected-p :panel-selected :panel-raised)))
    (sgeo.backend.opengl:ui-rect renderer x y width height (%color :border) :filled-p nil)
    (sgeo.backend.opengl:ui-text renderer (+ x (if compact-p 6 9)) (+ y 6)
                                 (%clip-text renderer label (- width (if compact-p 12 18)) text-scale)
                                 (%color :text) :scale text-scale)
    (%ui-hit state x y width height action)))

(defun %safe-ui-action (state function)
  (handler-case (funcall function)
    (error (condition)
      (setf (sgeo.editor:editor-status (editor-ui-editor state))
            (princ-to-string condition))
      nil)))

(defun %command (state name &rest arguments)
  (apply #'sgeo.editor:execute-editor-command (editor-ui-editor state) name arguments))

(defun %open-popup (state x y items)
  (%close-popup state)
  (let ((width (min (editor-ui-width state)
                    (+ 24 (* 10 (loop for item in items maximize (length (first item))))))))
    (setf (editor-ui-popup state) items (editor-ui-popup-width state) width
          (editor-ui-popup-x state) (max 0 (min x (- (editor-ui-width state) width)))
          (editor-ui-popup-y state) (max 0 (min y (- (editor-ui-height state) (* 25 (length items))))))))

(defun %close-popup (state)
  "Remove também as regiões clicáveis de um menu que deixou de estar visível."
  (setf (editor-ui-hits state)
        (set-difference (editor-ui-hits state) (editor-ui-popup-hits state) :test #'eq)
        (editor-ui-popup-hits state) nil
        (editor-ui-popup state) nil))

(defun %dispatch-action (state action)
  (let ((editor (editor-ui-editor state)))
    (%safe-ui-action
     state
     (lambda ()
       (case (first action)
         (:command (apply #'%command state (second action) (cddr action)))
         (:mode (%command state :selection-mode :mode (second action)))
         (:view (%command state :view :view (second action)))
         (:layout (%command state :layout :layout (second action)))
         (:tool (%command state :tool :tool (second action)))
         (:select
          (sgeo.editor:editor-select editor (second action))
          (sgeo.editor:inspect-editor editor (second action)))
         (:inspect-reference (sgeo.editor:inspect-editor editor (second action)))
         (:inspect-back (sgeo.editor:inspect-back editor))
         (:nudge
          (let ((object (sgeo.scene:world-selection (sgeo.editor:editor-world editor))))
            (unless object (error "Selecione um objeto para mover."))
            (let* ((position (copy-seq (sgeo.math:transform-position
                                        (sgeo.scene:scene-object-local-transform object))))
                   (axis (position (second action) '(:x :y :z))))
              (incf (aref position axis) (third action))
              (%command state :position :value position))))
         (:rotate-step
          (let ((rotation (make-array 3 :initial-element 0d0)))
            (setf (aref rotation (position (second action) '(:x :y :z))) (third action))
            (%command state :rotate :delta (coerce rotation 'list))))
         (:scale-factor
          (let ((object (sgeo.scene:world-selection (sgeo.editor:editor-world editor))))
            (unless object (error "Selecione um objeto para dimensionar."))
            (let* ((scale (copy-seq (sgeo.math:transform-scale
                                     (sgeo.scene:scene-object-local-transform object))))
                   (axis (position (second action) '(:x :y :z))))
              (setf (aref scale axis) (* (aref scale axis) (third action)))
              (%command state :scale :value scale))))
         (:inspect-field
          (let* ((field (second action)) (axis (third action))
                 (object (or (sgeo.editor:editor-inspected editor)
                             (sgeo.scene:world-selection (sgeo.editor:editor-world editor))))
                 (rows (sgeo.editor:inspect-value object))
                 (row (find field rows :key (lambda (item) (getf item :editable))))
                 (value (and row (getf row :value))))
            (setf (editor-ui-focus state) :inspector
                  (editor-ui-field-edit state) (cons field axis)
                  (editor-ui-field-string state)
                  (if (and (typep value 'sequence) (< axis (length value)))
                      (format nil "~A" (elt value axis))
                      (format nil "~A" value)))))
         (:listener (setf (editor-ui-focus state) :listener))
         (:submit (%submit-listener state))
         (:replay (sgeo.editor:replay-editor-command editor (second action)))
         (:close (sgeo.platform:request-window-close (editor-ui-window state)))
         (:popup (apply #'%open-popup state (rest action)))
         (:rename
          (let ((object (sgeo.scene:world-selection (sgeo.editor:editor-world editor))))
            (unless object (error "Selecione um objeto antes de renomear."))
            (setf (editor-ui-focus state) :inspector
                  (editor-ui-field-edit state) (cons :rename 0)
                  (editor-ui-field-string state) (sgeo.core:object-name object))))
         (:gltf-path
          (setf (editor-ui-show-inspector-p state) t
                (editor-ui-focus state) :inspector
                (editor-ui-field-edit state) (cons (second action) 0)
                (editor-ui-field-string state) (if (eq (second action) :import-gltf) "model.gltf" "scene.glb")))
         (:clear-selection (sgeo.editor:editor-select editor nil nil))
         (:gizmo (setf (editor-ui-focus state) :viewport))
         (:profile (setf (sgeo.editor:editor-layout editor) :inspection))
         (otherwise (%dispatch-workspace-action state action)))))))

(defun %submit-listener (state)
  (let* ((editor (editor-ui-editor state))
         (input (editor-ui-listener-string state)))
    (unless (string= input "")
      (%safe-ui-action state (lambda () (sgeo.editor:submit-listener editor input)))
      (setf (editor-ui-listener-string state) ""
            (sgeo.editor:editor-listener-input editor) ""))))

(defun %make-layout (state width height)
  (let* ((editor (editor-ui-editor state))
         (small-p (< width 760))
         (left-width (if (or small-p (and (not (editor-ui-show-hierarchy-p state)) (null (editor-ui-workspace-tool state)))) 0
                         (or (editor-ui-left-width state) 214)))
         (right-width (if (or small-p (not (editor-ui-show-inspector-p state))) 0
                          (or (editor-ui-right-width state) 286)))
         (top-height 66)
         (bottom-height (or (editor-ui-bottom-height state) (case (sgeo.editor:editor-layout editor)
                          (:modeling 166) (:development 220) (:inspection 116)
                          (otherwise 166))))
         (bottom-height (if (or (editor-ui-show-history-p state) (editor-ui-show-listener-p state))
                            (min bottom-height (max 24 (- height top-height 100))) 24))
         (viewport-x (+ left-width 8))
         (viewport-y top-height)
         (viewport-width (max 1 (- width left-width right-width 24)))
         (viewport-height (max 1 (- height viewport-y bottom-height 8)))
         (left (list 0 top-height left-width (- height top-height bottom-height)))
         (right (list (- width right-width) top-height right-width
                      (- height top-height bottom-height)))
         (bottom (list 0 (- height bottom-height) width bottom-height))
         (viewport (list viewport-x viewport-y viewport-width viewport-height)))
    (setf (editor-ui-viewport-rect state) viewport
          (editor-ui-layout-rects state) (list :left left :right right :bottom bottom
                                               :viewport viewport))
    (editor-ui-layout-rects state)))

(defun %draw-topbar (state)
  (let* ((ui (editor-ui-ui-renderer state)) (width (editor-ui-width state))
         (editor (editor-ui-editor state)))
    (sgeo.backend.opengl:ui-rect ui 0 0 width 32 (%color :panel))
    (sgeo.backend.opengl:ui-rect ui 0 31 width 1 (%color :border))
    (sgeo.backend.opengl:ui-text ui 11 9 "S-GEOMETRY" (%color :accent))
    (let ((x 128)
          (menus (list
                  (list "File" (list (list "Save scene" (list :command :save :path (sgeo.editor:editor-scene-path editor)))
                                     (list "Open scene" (list :command :open :path (sgeo.editor:editor-scene-path editor)))
                                     (list "Import glTF..." (list :gltf-path :import-gltf))
                                     (list "Export GLB..." (list :gltf-path :export-gltf))
                                     (list "Close editor" (list :close))))
                  (list "Create" (list (list "Box" (list :command :create :kind :box))
                                       (list "Sphere" (list :command :create :kind :sphere))
                                       (list "Cylinder" (list :command :create :kind :cylinder))
                                       (list "Grid" (list :command :create :kind :grid))
                                       (list "Torus" (list :command :create :kind :torus))))
                  (list "Edit" (list (list "Undo" (list :command :undo))
                                     (list "Redo" (list :command :redo))
                                     (list "Rename selected" (list :rename))
                                     (list "Split edge" (list :command :split))
                                     (list "Collapse edge" (list :command :collapse))
                                     (list "Extrude face / region" (list :command :extrude))
                                     (list "Delete selected" (list :command :delete))))
                  (list "View" (list (list "Perspective" (list :view :perspective))
                                     (list "Front" (list :view :front))
                                     (list "Top" (list :view :top))
                                     (list "Side" (list :view :side))))
                  (list "Workspace" (list (list "Modeling" (list :layout :modeling))
                                          (list "Development" (list :layout :development))
                                          (list "Inspection" (list :layout :inspection))
                                          (list "Debug world" (list :workspace-tool :debug))
                                          (list "Profile" (list :workspace-tool :profile))
                                          (list "Timeline" (list :workspace-tool :timeline))
                                          (list "Configure panels" (list :workspace-tool :layout))
                                          (list "Scene hierarchy" (list :workspace-tool nil)))))))
      (dolist (entry menus)
        (let ((menu-x x) (label (first entry)))
          (let ((menu-width (+ 20 (* 10 (length label)))))
          (%ui-button state menu-x 2 menu-width 27 label
                      (list :popup menu-x 32 (second entry)) :compact-p t)
          (incf x (+ menu-width 4))))))
    (let ((x 8) (y 36))
      (dolist (mode '((:object "Object") (:vertex "Vertex") (:edge "Edge")
                      (:face "Face") (:region "Region")))
        (let ((button-width (+ 18 (* 10 (length (second mode))))))
        (%ui-button state x y button-width 25 (second mode) (list :mode (first mode))
                    :selected-p (eq (first mode) (sgeo.editor:editor-selection-mode editor))
                    :compact-p t)
        (incf x (+ button-width 4))))
      (incf x 8)
      (dolist (tool '((:translate "Move") (:rotate "Rotate") (:scale "Scale")))
        (let ((button-width (+ 18 (* 10 (length (second tool))))))
        (%ui-button state x y button-width 25 (second tool) (list :tool (first tool))
                    :selected-p (eq (first tool) (sgeo.editor:editor-tool editor))
                    :compact-p t)
        (incf x (+ button-width 4))))
      (incf x 8)
      (dolist (view '((:perspective "Persp") (:front "Front") (:top "Top") (:side "Side")))
        (let ((button-width (+ 18 (* 10 (length (second view))))))
        (%ui-button state x y button-width 25 (second view) (list :view (first view))
                    :selected-p (eq (first view) (sgeo.editor:editor-view editor))
                    :compact-p t)
        (incf x (+ button-width 4)))))
    (when (> width 1000)
      (let* ((focus (editor-ui-focus state))
             (mode (sgeo.editor:editor-selection-mode editor))
             (help (if (< width 1150)
                       (cond ((eq focus :listener) "Ctrl+Enter")
                             ((eq focus :inspector) "Back: voltar")
                             ((eq mode :region) "Shift+clique")
                             (t "Alt: orbita"))
                       (cond ((eq focus :listener) "Enter: linha | Ctrl+Enter: avaliar")
                             ((eq focus :inspector) "Referência: navegar | Back: voltar")
                             ((eq mode :region) "Shift+clique: adicionar/remover")
                             (t "Alt: orbita | meio: move | roda: zoom")))))
        (sgeo.backend.opengl:ui-text ui 900 43 (%clip-text ui help (- width 908)) (%color :muted))))))

(defun %draw-hierarchy (state rect)
  (destructuring-bind (x y width height) rect
    (let* ((ui (editor-ui-ui-renderer state))
           (world (sgeo.editor:editor-world (editor-ui-editor state)))
           (selected (sgeo.scene:world-selection world))
           (row-y (+ y 32)))
      (sgeo.backend.opengl:ui-rect ui x y width height (%color :panel))
      (sgeo.backend.opengl:ui-text ui (+ x 12) (+ y 10) "SCENE HIERARCHY" (%color :muted))
      (labels ((walk (object depth)
                 (when (< row-y (+ y height -6))
                   (let* ((name (sgeo.core:object-name object))
                          (row-height 24) (row-x (+ x 6 (* depth 12)))
                          (row-width (- width 12 (* depth 12))))
                     (when (eq object selected)
                       (sgeo.backend.opengl:ui-rect ui row-x row-y row-width row-height
                                                    (%color :panel-selected)))
                     (sgeo.backend.opengl:ui-text ui (+ row-x 7) (+ row-y 4)
                                                  (%clip-text ui (format nil "~A ~A" (if (zerop depth) ">" " ") name)
                                                              (- row-width 18))
                                                  (%color (if (eq object selected) :text :muted)))
                     (%ui-hit state row-x row-y row-width row-height (list :select object))
                     (incf row-y row-height)
                     (dolist (child (sgeo.scene:scene-object-children object))
                       (walk child (1+ depth)))))))
        (walk (sgeo.scene:world-root world) 0)))))

(defun %format-inspector-value (value)
  "Formata valores limitando profundidade, tamanho e referências circulares."
  (typecase value
    (string value)
    (number (string-trim '(#\Space) (format nil "~,4G" value)))
    (symbol (string-downcase value))
    (otherwise
     (let ((*print-level* 2) (*print-length* 6) (*print-circle* t))
       (write-to-string value :readably nil)))))

(defun %draw-inspector (state rect)
  (destructuring-bind (x y width height) rect
    (let* ((ui (editor-ui-ui-renderer state))
           (editor (editor-ui-editor state))
           (object (or (sgeo.editor:editor-inspected editor)
                       (sgeo.scene:world-selection (sgeo.editor:editor-world editor))))
           (rows (and object (ignore-errors (sgeo.editor:inspect-value object))))
           (row-y (+ y (if (typep (or (sgeo.editor:editor-inspected editor)
                                      (sgeo.scene:world-selection (sgeo.editor:editor-world editor)))
                                  'sgeo.scene:scene-object) 56 37))))
      (sgeo.backend.opengl:ui-rect ui x y width height (%color :panel))
      (sgeo.backend.opengl:ui-text ui (+ x 12) (+ y 10) "INSPECTOR" (%color :muted))
      (%ui-button state (+ x width -82) (+ y 4) 70 24 "Back" '(:inspect-back) :compact-p t)
      (when (typep object 'sgeo.scene:scene-object)
        (sgeo.backend.opengl:ui-text ui (+ x 12) (+ y 30)
                                     (sgeo.core:object-name object) (%color :accent)))
      (loop for row in rows for row-index from 0
            when (>= row-index (editor-ui-inspector-scroll state))
            do
        (when (< row-y (+ y height -9))
          (let* ((label (getf row :label "Field"))
                 (field (getf row :editable))
                 (value (getf row :value))
                 (reference (getf row :reference)))
            (sgeo.backend.opengl:ui-text ui (+ x 12) row-y
                                         (%clip-text ui label (- width 24)) (%color :muted))
            (incf row-y 18)
            (if (and field (typep value 'sequence) (<= 3 (length value)))
                (loop for axis below 3
                      for component-x = (+ x 10 (* axis (floor (- width 20) 3)))
                      for component-width = (floor (- width 26) 3)
                      do (%ui-button state component-x row-y component-width 25
                                     (%format-inspector-value (elt value axis))
                                     (list :inspect-field field axis) :compact-p t))
                (progn
                  (sgeo.backend.opengl:ui-text ui (+ x 14) row-y
                                               (%clip-text ui (%format-inspector-value value)
                                                           (- width 30)) (%color :text))
                  (when field
                    (%ui-hit state (+ x 9) row-y (- width 18) 24
                             (list :inspect-field field 0)))
                  (when reference
                    (%ui-hit state (+ x 9) row-y (- width 18) 24
                             (list :inspect-reference reference)))))
            (incf row-y 31))))
      (when (editor-ui-field-edit state)
        (sgeo.backend.opengl:ui-rect ui (+ x 9) (- (+ y height) 39) (- width 18) 29
                                     (%color :panel-selected))
        (sgeo.backend.opengl:ui-text ui (+ x 15) (- (+ y height) 32)
                                     (%clip-text ui
                                       (format nil "Valor: ~A (Enter)"
                                               (editor-ui-field-string state))
                                       (- width 30)) (%color :text))))))

(defun %text-lines (text)
  "Separa texto em linhas, preservando a linha vazia ao final da entrada."
  (let ((lines (with-input-from-string (stream text)
                 (loop for line = (read-line stream nil nil) while line collect line))))
    (if (or (null lines) (and (plusp (length text)) (char= (char text (1- (length text))) #\Newline)))
        (append lines (list "")) lines)))

(defun %history-panel-width (state width)
  "Calcula a largura do histórico independentemente do painel de hierarquia."
  (if (editor-ui-show-history-p state)
      (if (editor-ui-show-listener-p state)
          (if (eq (sgeo.editor:editor-layout (editor-ui-editor state)) :development) 270 224)
          (- width 16))
      0))

(defun %draw-bottom (state rect)
  (destructuring-bind (x y width height) rect
    (let* ((ui (editor-ui-ui-renderer state))
           (editor (editor-ui-editor state))
           (history-p (editor-ui-show-history-p state))
           (listener-p (editor-ui-show-listener-p state))
           (history-width (%history-panel-width state width))
           (listener-x (+ x (if history-p (+ history-width 8) 8)))
           (listener-width (- width (- listener-x x) 8)))
      (sgeo.backend.opengl:ui-rect ui x y width height (%color :panel))
      (sgeo.backend.opengl:ui-rect ui x y width 1 (%color :border))
      (when history-p
        (sgeo.backend.opengl:ui-text ui (+ x 10) (+ y 8) "HISTORY" (%color :muted))
        (let* ((history (sgeo.editor:editor-history editor))
               (start (min (editor-ui-history-scroll state) (length history)))
               (count (max 0 (floor (- height 54) 21))))
          (loop for command in (subseq history start (min (+ start count) (length history)))
                for row from 0 for row-y = (+ y 29 (* row 21))
                do (sgeo.backend.opengl:ui-text ui (+ x 10) row-y
                     (%clip-text ui (sgeo.editor:command-label command) (- history-width 20)) (%color :text))
                   (%ui-hit state x row-y history-width 20 (list :replay command)))))
      (when listener-p
        (sgeo.backend.opengl:ui-text ui listener-x (+ y 8)
          (if (eq (sgeo.editor:editor-layout editor) :development) "LISTENER / DEVELOPMENT" "LISP LISTENER")
          (%color :muted))
        (let ((control-x (+ listener-x 245))
              (playing (sgeo.editor:editor-playing-p editor)))
          (loop for control in (list (list (if playing "Pause" "Play") (list :command (if playing :pause :play)))
                                     (list "Step" '(:command :step :dt 0.0166666666667d0))
                                     (list "0.5x" '(:command :time-scale :value 0.5d0))
                                     (list "1x" '(:command :time-scale :value 1d0))
                                     (list "2x" '(:command :time-scale :value 2d0)))
                for button-width in '(68 60 60 48 48)
                when (<= (+ control-x button-width) (+ x width))
                do (%ui-button state control-x (+ y 3) button-width 23
                       (first control) (second control) :compact-p t)
                   (incf control-x (+ button-width 4))))
        (let* ((input-height (min 76 (max 44 (floor height 2))))
               (input-y (- (+ y height) 27 input-height))
               (outputs (mapcan (lambda (entry) (reverse (%text-lines entry)))
                                (sgeo.editor:editor-listener-output editor)))
               (start (min (editor-ui-output-scroll state) (length outputs)))
               (count (max 0 (floor (- input-y y 30) 17)))
               (shown (reverse (subseq outputs start (min (+ start count) (length outputs))))))
          (loop for line in shown for row from 0
                do (sgeo.backend.opengl:ui-text ui listener-x (+ y 30 (* row 17))
                     (%clip-text ui line listener-width) (%color :text)))
          (sgeo.backend.opengl:ui-rect ui listener-x input-y listener-width input-height
            (%color (if (eq (editor-ui-focus state) :listener) :panel-selected :panel-raised)))
          (sgeo.backend.opengl:ui-text ui (+ listener-x 7) (+ input-y 4)
            (%clip-text ui "sgeo> Ctrl+Enter evaluates" (- listener-width 14)) (%color :muted))
          (let* ((lines (%text-lines (editor-ui-listener-string state)))
                 (visible-count (max 1 (floor (- input-height 24) 17)))
                 (visible (subseq lines (max 0 (- (length lines) visible-count)))))
            (loop for line in visible for row from 0
                  do (sgeo.backend.opengl:ui-text ui (+ listener-x 7) (+ input-y 22 (* row 17))
                       (%clip-text ui (if (= row (1- (length visible))) (concatenate 'string line "_") line)
                                   (- listener-width 14)) (%color :text))))
          (%ui-hit state listener-x input-y listener-width input-height '(:listener)))))))

(defun %draw-popup (state)
  (when (editor-ui-popup state)
    (let* ((ui (editor-ui-ui-renderer state))
           (items (editor-ui-popup state))
           (x (editor-ui-popup-x state)) (y (editor-ui-popup-y state))
           (width (editor-ui-popup-width state)) (height (* 25 (length items))))
      (sgeo.backend.opengl:ui-rect ui x y width height (%color :panel-raised))
      (sgeo.backend.opengl:ui-rect ui x y width height (%color :accent) :filled-p nil)
      (loop for item in items for index from 0
            for row-y = (+ y (* index 25))
            do (sgeo.backend.opengl:ui-text ui (+ x 10) (+ row-y 5)
                                            (first item) (%color :text))
               (%ui-hit state x row-y width 25 (second item))
               (push (first (editor-ui-hits state)) (editor-ui-popup-hits state))))))

(defun %draw-status (state)
  (let* ((ui (editor-ui-ui-renderer state)) (height (editor-ui-height state))
         (width (editor-ui-width state))
         (editor (editor-ui-editor state))
         (profile (sgeo.editor:editor-profile editor)))
    (sgeo.backend.opengl:ui-rect ui 0 (- height 21) width 21 (%color :background))
      (sgeo.backend.opengl:ui-text ui 9 (- height 17)
                                 (%clip-text ui (or (sgeo.editor:editor-status editor) "Ready")
                                             (- (max 250 (- width 390)) 18)) (%color :muted))
    (sgeo.backend.opengl:ui-text ui (max 250 (- width 390)) (- height 17)
                                 (format nil "~,2Fs ~A | F~A ~,1Fms | U~A"
                                         (sgeo.editor:editor-time editor)
                                         (if (sgeo.editor:editor-playing-p editor) "PLAY" "PAUSE")
                                         (or (getf profile :frames) 0)
                                         (* 1000d0 (or (getf profile :frame-time) 0d0))
                                         (or (getf profile :uploads) 0)) (%color :muted))))

(defun %draw-ui (state)
  (let* ((ui (editor-ui-ui-renderer state))
         (layout (%make-layout state (editor-ui-width state) (editor-ui-height state)))
         (left (getf layout :left)) (right (getf layout :right)) (bottom (getf layout :bottom)))
    (setf (editor-ui-hits state) nil (editor-ui-popup-hits state) nil)
    (%refresh-element-selection state)
    (sgeo.backend.opengl:begin-ui-frame ui (editor-ui-width state) (editor-ui-height state))
    (%draw-topbar state)
    (%draw-selection-overlay state)
    (when (plusp (third left))
      (if (editor-ui-workspace-tool state)
          (progn (apply #'sgeo.backend.opengl:ui-rect ui (append left (list (%color :panel))))
                 (%draw-workspace-tools state left))
          (%draw-hierarchy state left)))
    (when (plusp (third right)) (%draw-inspector state right))
    (%draw-bottom state bottom)
    (%draw-status state)
    (%draw-popup state)
    (sgeo.backend.opengl:finish-ui-frame ui)))

(defun %viewport-local-position (state x y)
  (let ((rect (editor-ui-viewport-rect state)))
    (values (- x (first rect)) (- y (second rect)))))

(defun %viewport-contains-p (state x y)
  (%rect-contains-p x y (editor-ui-viewport-rect state)))

(defun %world-origin (object)
  (sgeo.math:transform-point (sgeo.scene:world-transform object)
                             (sgeo.math:make-vec3 0d0 0d0 0d0)))

(defun %gizmo-axis-unit (object axis &optional (tool :translate))
  (let* ((unit (case axis (:x #(1d0 0d0 0d0)) (:y #(0d0 1d0 0d0))
                        (:z #(0d0 0d0 1d0))))
         (parent (sgeo.scene:scene-object-parent object)))
    (when (member tool '(:rotate :scale))
      (setf unit (sgeo.math:transform-direction
                  (sgeo.math:transform-matrix
                   (sgeo.math:make-transform :rotation
                     (sgeo.math:transform-rotation (sgeo.scene:scene-object-local-transform object)))) unit)))
    (if parent
        (sgeo.math:transform-direction (sgeo.scene:world-transform parent) unit)
        unit)))

(defun %gizmo-axis-points (state object axis)
  (let* ((origin (%world-origin object))
         (unit (%gizmo-axis-unit object axis (sgeo.editor:editor-tool (editor-ui-editor state))))
         (world-point (sgeo.math:v+ origin unit))
         (rect (editor-ui-viewport-rect state)))
    (multiple-value-bind (x y) (sgeo.editor:projected-position
                                (sgeo.editor:editor-world (editor-ui-editor state))
                                origin (third rect) (fourth rect))
      (multiple-value-bind (ex ey) (sgeo.editor:projected-position
                                    (sgeo.editor:editor-world (editor-ui-editor state))
                                    world-point (third rect) (fourth rect))
        (when (and x y ex ey)
          (values (+ (first rect) x) (+ (second rect) y)
                  (+ (first rect) ex) (+ (second rect) ey)))))))

(defun %hit-gizmo-axis (state object x y)
  (when (typep object 'sgeo.scene:scene-object)
    (loop for axis in '(:x :y :z)
          for best = nil then best
          for best-distance = 12d0 then best-distance
          do (multiple-value-bind (x1 y1 x2 y2) (%gizmo-axis-points state object axis)
               (when x1
                 (let* ((dx (- x2 x1)) (dy (- y2 y1))
                        (length-squared (+ (* dx dx) (* dy dy)))
                        (parameter (if (zerop length-squared) 0d0
                                       (max 0d0 (min 1d0 (/ (+ (* (- x x1) dx)
                                                              (* (- y y1) dy)) length-squared)))))
                        (distance (sqrt (+ (expt (- x (+ x1 (* parameter dx))) 2)
                                           (expt (- y (+ y1 (* parameter dy))) 2)))))
                   (when (and (<= distance best-distance) (> parameter 0.18d0))
                     (setf best axis best-distance distance)))))
          finally (return best))))

(defun %live-element-p (mesh handle)
  "Confere a geração do elemento antes de usá-lo em uma vista derivada."
  (and (typep mesh 'sgeo.geometry:half-edge-mesh)
       (sgeo.geometry:mesh-handle-p handle)
       (handler-case
           (progn
             (ecase (sgeo.geometry:handle-kind handle)
               (:vertex (sgeo.geometry:vertex-position mesh handle))
               (:edge (sgeo.geometry:edge-vertices mesh handle))
               (:face (sgeo.geometry:face-vertices mesh handle))
               (:half-edge (sgeo.geometry:half-edge-origin mesh handle)))
             t)
         (sgeo.geometry:stale-handle-error () nil))))

(defun %refresh-element-selection (state)
  "Descarta seleções aposentadas por edições feitas no listener ou no REPL."
  (let* ((editor (editor-ui-editor state))
         (object (sgeo.scene:world-selection (sgeo.editor:editor-world editor)))
         (mesh (and (typep object 'sgeo.scene:mesh-object)
                    (sgeo.scene:mesh-object-geometry object)))
         (old (sgeo.editor:editor-elements editor))
         (live (remove-if-not (lambda (handle) (%live-element-p mesh handle)) old))
         (inspected (sgeo.editor:editor-inspected editor)))
    (unless (equal live old)
      (setf (sgeo.editor:editor-elements editor) live))
    (when (and (consp inspected) (eq (first inspected) :element)
               (not (%live-element-p (second inspected) (third inspected))))
      (setf (sgeo.editor:editor-inspected editor) object
            (sgeo.editor::%inspect-stack editor) nil
            (editor-ui-inspector-scroll state) 0
            (editor-ui-field-edit state) nil))))

(defun %draw-selection-overlay (state)
  (let* ((ui (editor-ui-ui-renderer state))
         (editor (editor-ui-editor state))
         (world (sgeo.editor:editor-world editor))
         (object (sgeo.scene:world-selection world))
         (elements (sgeo.editor:editor-elements editor))
         (rect (editor-ui-viewport-rect state)))
    (when (typep object 'sgeo.scene:scene-object)
      (let ((geometry (and (typep object 'sgeo.scene:mesh-object)
                           (sgeo.scene:mesh-object-geometry object)))
            (matrix (sgeo.scene:world-transform object)))
        (when (typep geometry 'sgeo.geometry:half-edge-mesh)
          (dolist (element elements)
            (cond
              ((not (eq (if (eq (sgeo.editor:editor-selection-mode editor) :region)
                            :face (sgeo.editor:editor-selection-mode editor))
                        (sgeo.geometry:handle-kind element))) nil)
              ((eq (sgeo.editor:editor-selection-mode editor) :vertex)
               (let* ((point (sgeo.math:transform-point
                              matrix (sgeo.geometry:vertex-position geometry element))))
                 (multiple-value-bind (x y) (sgeo.editor:projected-position
                                             world point (third rect) (fourth rect))
                   (when x (sgeo.backend.opengl:ui-rect ui (+ (first rect) x -4)
                                                       (+ (second rect) y -4) 8 8
                                                       (%color :orange))))))
              ((eq (sgeo.editor:editor-selection-mode editor) :edge)
               (let* ((vertices (sgeo.geometry:edge-vertices geometry element))
                      (a (sgeo.math:transform-point matrix
                             (sgeo.geometry:vertex-position geometry (first vertices))))
                      (b (sgeo.math:transform-point matrix
                             (sgeo.geometry:vertex-position geometry (second vertices)))))
                 (multiple-value-bind (ax ay) (sgeo.editor:projected-position
                                               world a (third rect) (fourth rect))
                   (multiple-value-bind (bx by) (sgeo.editor:projected-position
                                                 world b (third rect) (fourth rect))
                     (when (and ax bx)
                       (sgeo.backend.opengl:ui-line ui (+ (first rect) ax) (+ (second rect) ay)
                                                    (+ (first rect) bx) (+ (second rect) by)
                                                    (%color :orange) :width 4))))))
              ((member (sgeo.editor:editor-selection-mode editor) '(:face :region))
               (let ((vertices (sgeo.geometry:face-vertices geometry element)))
                 (loop for first in vertices for second in (append (rest vertices) (list (first vertices)))
                       for a = (sgeo.math:transform-point matrix
                                (sgeo.geometry:vertex-position geometry first))
                       for b = (sgeo.math:transform-point matrix
                                (sgeo.geometry:vertex-position geometry second))
                       do (multiple-value-bind (ax ay) (sgeo.editor:projected-position
                                                         world a (third rect) (fourth rect))
                            (multiple-value-bind (bx by) (sgeo.editor:projected-position
                                                          world b (third rect) (fourth rect))
                              (when (and ax bx)
                                (sgeo.backend.opengl:ui-line ui (+ (first rect) ax) (+ (second rect) ay)
                                                             (+ (first rect) bx) (+ (second rect) by)
                                                             (%color :orange) :width 3))))))))))
        (when (and (eq (sgeo.editor:editor-selection-mode editor) :object)
                   (member (sgeo.editor:editor-tool editor) '(:translate :rotate :scale)))
          (dolist (axis '(:x :y :z))
            (multiple-value-bind (x1 y1 x2 y2) (%gizmo-axis-points state object axis)
              (when x1
                (let ((color (%color (case axis (:x :red) (:y :green) (:z :blue)))))
                  (sgeo.backend.opengl:ui-line ui x1 y1 x2 y2 color :width 3)
                  (sgeo.backend.opengl:ui-rect ui (- x2 4) (- y2 4) 8 8 color))))))))))

(defun %select-at (state x y &optional mods)
  (let* ((editor (editor-ui-editor state)) (world (sgeo.editor:editor-world editor))
         (rect (editor-ui-viewport-rect state))
         (mode (sgeo.editor:editor-selection-mode editor)))
    (multiple-value-bind (local-x local-y) (%viewport-local-position state x y)
      (multiple-value-bind (object elements)
          (sgeo.editor:pick-element world (if (eq mode :region) :face mode)
                                    local-x local-y (third rect) (fourth rect)
                                    :object (unless (eq mode :object)
                                              (sgeo.scene:world-selection world)))
        (if object
            (progn
              (let ((selected-elements
                      (if (and (eq mode :region) (%mod-p mods :shift)
                               (eq object (sgeo.scene:world-selection world)))
                          (let ((selection (copy-list (sgeo.editor:editor-elements editor))))
                            (dolist (element elements selection)
                              (if (member element selection :test #'equalp)
                                  (setf selection (remove element selection :test #'equalp))
                                  (push element selection))))
                          elements)))
                (sgeo.editor:editor-select editor object selected-elements)
                (when (and elements (not (eq mode :object)))
                  (sgeo.editor:inspect-editor
                   editor (list :element (sgeo.scene:mesh-object-geometry object) (first elements)))))
              (when (and (eq mode :object) object)
                (sgeo.editor:inspect-editor editor object)))
            (when (eq mode :object) (sgeo.editor:editor-select editor nil nil)))))))

(defun %begin-gizmo-drag (state object axis x y)
  (setf (editor-ui-drag-gizmo state) axis
        (editor-ui-drag-start-x state) x
        (editor-ui-drag-start-y state) y
        (editor-ui-drag-current-x state) x
        (editor-ui-drag-current-y state) y
        (editor-ui-drag-start-transform state)
        (sgeo.scene:scene-object-local-transform object)
        (editor-ui-drag-start-position state)
        (copy-seq (sgeo.math:transform-position (sgeo.scene:scene-object-local-transform object)))
        (editor-ui-drag-origin state) object))

(defun %gizmo-drag-amount (state)
  (let* ((axis (editor-ui-drag-gizmo state))
         (object (editor-ui-drag-origin state))
         (editor (editor-ui-editor state))
         (axis-unit (%gizmo-axis-unit object axis (sgeo.editor:editor-tool editor)))
         (origin (%world-origin object))
         (end (sgeo.math:v+ origin axis-unit))
         (rect (editor-ui-viewport-rect state)))
    (multiple-value-bind (x1 y1) (sgeo.editor:projected-position
                                  (sgeo.editor:editor-world editor) origin
                                  (third rect) (fourth rect))
      (multiple-value-bind (x2 y2) (sgeo.editor:projected-position
                                    (sgeo.editor:editor-world editor) end
                                    (third rect) (fourth rect))
        (when (and x1 x2)
          (let* ((dx (- x2 x1)) (dy (- y2 y1))
                 (distance (sqrt (+ (* dx dx) (* dy dy))))
                 (pixel-delta (+ (* (- (editor-ui-drag-current-x state)
                                      (editor-ui-drag-start-x state)) dx)
                                 (* (- (editor-ui-drag-current-y state)
                                      (editor-ui-drag-start-y state)) dy))))
            (values (ecase axis (:x #(1d0 0d0 0d0)) (:y #(0d0 1d0 0d0)) (:z #(0d0 0d0 1d0)))
                    (/ pixel-delta (max 1d-6 (* distance distance))))))))))

(defun %set-object-transform (object transform)
  (sgeo.scene:set-position object (sgeo.math:transform-position transform))
  (sgeo.scene:set-rotation object (sgeo.math:transform-rotation transform))
  (sgeo.scene:set-scale object (sgeo.math:transform-scale transform))
  object)

(defun %preview-gizmo-drag (state)
  (let* ((object (editor-ui-drag-origin state))
         (start (editor-ui-drag-start-transform state))
         (tool (sgeo.editor:editor-tool (editor-ui-editor state))))
    (when (and object start)
      (%set-object-transform object start)
      (multiple-value-bind (axis-unit amount) (%gizmo-drag-amount state)
        (when axis-unit
          (case tool
            (:translate
             (sgeo.scene:set-position
              object (sgeo.math:v+ (sgeo.math:transform-position start)
                                   (sgeo.math:v* amount axis-unit))))
            (:rotate
             (let ((rotation (make-array 3 :initial-element 0d0)))
               (setf (aref rotation (position (editor-ui-drag-gizmo state) '(:x :y :z))) amount)
               (sgeo.scene:rotate object (coerce rotation 'list))))
            (:scale
             (let* ((scale (copy-seq (sgeo.math:transform-scale start)))
                    (index (position (editor-ui-drag-gizmo state) '(:x :y :z))))
               (setf (aref scale index) (max 0.01d0 (+ (aref scale index) amount)))
               (sgeo.scene:set-scale object scale)))))))))

(defun %finish-gizmo-drag (state)
  (let* ((axis (editor-ui-drag-gizmo state))
         (object (editor-ui-drag-origin state))
         (editor (editor-ui-editor state))
         (tool (sgeo.editor:editor-tool editor))
         (start (editor-ui-drag-start-transform state)))
    (unwind-protect
    (when (and axis object)
      (%set-object-transform object start)
      (multiple-value-bind (axis-unit amount) (%gizmo-drag-amount state)
        (when (and axis-unit (> (abs amount) 1d-9))
          (case tool
            (:translate
             (%command state :position :object object :value
                       (sgeo.math:v+ (sgeo.math:transform-position start)
                                     (sgeo.math:v* amount axis-unit))))
            (:rotate
             (let ((rotation (make-array 3 :initial-element 0d0)))
               (setf (aref rotation (position axis '(:x :y :z))) amount)
               (%command state :rotate :object object :delta (coerce rotation 'list))))
            (:scale
             (let* ((scale (copy-seq (sgeo.math:transform-scale start)))
                    (index (position axis '(:x :y :z))))
               (setf (aref scale index) (max 0.01d0 (+ (aref scale index) amount)))
               (%command state :scale :object object :value scale))))))
    (setf (editor-ui-drag-gizmo state) nil
          (editor-ui-drag-origin state) nil
          (editor-ui-drag-start-transform state) nil)))))

(defun %cancel-gizmo-drag (state)
  (when (and (editor-ui-drag-origin state) (editor-ui-drag-start-transform state))
    (%set-object-transform (editor-ui-drag-origin state)
                           (editor-ui-drag-start-transform state)))
  (setf (editor-ui-drag-gizmo state) nil
        (editor-ui-drag-origin state) nil
        (editor-ui-drag-start-transform state) nil))

(defun %mouse-down (state button action mods)
  (let* ((x (editor-ui-mouse-x state)) (y (editor-ui-mouse-y state))
         (pressed (sgeo.platform:press-event-p action))
         (editor (editor-ui-editor state))
         (world (sgeo.editor:editor-world editor))
         (object (sgeo.scene:world-selection world)))
    (case (sgeo.platform:mouse-button-kind button)
      (:right
       (when pressed
         (%open-popup state x y
                      (list (list "Create box" (list :command :create :kind :box))
                            (list "Create sphere" (list :command :create :kind :sphere))
                            (list "Rename selected" (list :rename))
                            (list "Split selected edge" (list :command :split))
                            (list "Collapse selected edge" (list :command :collapse))
                            (list "Extrude selected region" (list :command :extrude))
                            (list "Move +X" (list :nudge :x 0.25d0))
                            (list "Move +Y" (list :nudge :y 0.25d0))
                            (list "Rotate Z +15" (list :rotate-step :z 0.2617993877991494d0))
                            (list "Scale 1.1x" (list :scale-factor :x 1.1d0))
                            (list "Translate" (list :tool :translate))
                            (list "Rotate" (list :tool :rotate))
                            (list "Scale" (list :tool :scale))
                            (list "Undo" (list :command :undo))
                            (list "Redo" (list :command :redo))
                            (list "Delete" (list :command :delete))))))
      (:middle (setf (editor-ui-camera-motion state) (if pressed :pan nil)))
      (:left
       (setf (editor-ui-left-down state) pressed)
       (unless pressed (setf (editor-ui-timeline-drag state) nil))
       (if pressed
           (cond
             ((editor-ui-popup state)
              (let ((hit (find-if (lambda (item) (%rect-contains-p x y item))
                                  (editor-ui-hits state))))
                (if hit
                    (progn (%close-popup state)
                           (%dispatch-action state (fifth hit)))
                    (%close-popup state))))
             (t
              (let ((hit (find-if (lambda (item) (%rect-contains-p x y item))
                                  (editor-ui-hits state))))
                (cond
                  (hit (when (eq (first (fifth hit)) :timeline-scrub)
                         (setf (editor-ui-timeline-drag state) (fifth hit)))
                       (%dispatch-action state (fifth hit)))
                  ((%viewport-contains-p state x y)
                   (if (%mod-p mods :alt)
                       (setf (editor-ui-camera-motion state) :orbit)
                       (let ((axis (and object (eq (sgeo.editor:editor-selection-mode editor) :object)
                                        (%hit-gizmo-axis state object x y))))
                         (if axis
                             (%begin-gizmo-drag state object axis x y)
                             (%select-at state x y mods)))))))))
           (progn
             (when (editor-ui-drag-gizmo state)
               (%safe-ui-action state (lambda () (%finish-gizmo-drag state))))
             (setf (editor-ui-camera-motion state) nil)))))))

(defun %mod-p (mods modifier)
  (cond ((listp mods) (member modifier mods))
        ((integerp mods)
         (logtest mods (case modifier (:shift 1) (:control 2) (:alt 4) (:super 8) (otherwise 0))))
        (t nil)))

(defun %parse-ui-number (string)
  (let ((*read-eval* nil))
    (multiple-value-bind (value position) (read-from-string string nil nil)
      (unless (and (realp value) (= position (length string)))
        (error 'sgeo.core:validation-error :context "campo numérico"
               :message "Digite um número válido."))
      value)))

(defun %commit-inspector-field (state)
  (let* ((target (editor-ui-field-edit state))
         (value (if (and target (member (car target) '(:rename :import-gltf :export-gltf)))
                    (editor-ui-field-string state)
                    (%parse-ui-number (editor-ui-field-string state)))))
    (when target
      (case (car target)
        (:rename (%command state :rename :name value))
        (:import-gltf (%command state :import-gltf :path value))
        (:export-gltf (%command state :export-gltf :path value :binary t))
        (otherwise (sgeo.editor:set-inspector-number (editor-ui-editor state) (car target) value
                                                    :axis (cdr target)))))
    (setf (editor-ui-field-edit state) nil (editor-ui-focus state) :viewport)))

(defun %key-press (state key action mods)
  (when (sgeo.platform:press-event-p action)
    (let ((editor (editor-ui-editor state)))
      (cond
        ((eq key :escape)
         (cond ((editor-ui-drag-gizmo state) (%cancel-gizmo-drag state))
               ((editor-ui-popup state) (%close-popup state))
               (t (sgeo.platform:request-window-close (editor-ui-window state)))))
        ((and (%mod-p mods :control) (eq key :enter))
         (if (eq (editor-ui-focus state) :inspector)
             (%safe-ui-action state (lambda () (%commit-inspector-field state)))
             (%submit-listener state)))
        ((and (%mod-p mods :control) (eq key :z)) (%safe-ui-action state (lambda () (%command state :undo))))
        ((and (%mod-p mods :control) (eq key :y)) (%safe-ui-action state (lambda () (%command state :redo))))
        ((and (%mod-p mods :control) (eq key :s))
         (%safe-ui-action state (lambda () (%command state :save :path (sgeo.editor:editor-scene-path editor)))))
        ((and (%mod-p mods :control) (eq key :o))
         (%safe-ui-action state (lambda () (%command state :open :path (sgeo.editor:editor-scene-path editor)))))
        ((eq key :enter)
         (cond ((eq (editor-ui-focus state) :listener)
                (setf (editor-ui-listener-string state)
                      (concatenate 'string (editor-ui-listener-string state)
                                   (string #\Newline))))
               ((eq (editor-ui-focus state) :inspector)
                (%safe-ui-action state (lambda () (%commit-inspector-field state))))))
        ((eq key :backspace)
         (case (editor-ui-focus state)
           (:listener
            (when (plusp (length (editor-ui-listener-string state)))
              (setf (editor-ui-listener-string state)
                    (subseq (editor-ui-listener-string state) 0
                            (1- (length (editor-ui-listener-string state)))))))
           (:inspector
            (when (plusp (length (editor-ui-field-string state)))
              (setf (editor-ui-field-string state)
                    (subseq (editor-ui-field-string state) 0
                            (1- (length (editor-ui-field-string state)))))))))
        ((eq key :delete)
         (when (sgeo.scene:world-selection (sgeo.editor:editor-world editor))
           (%safe-ui-action state (lambda () (%command state :delete)))))
        ((eq key :f1) (%safe-ui-action state (lambda () (%command state :view :view :perspective))))
        ((eq key :f2) (%safe-ui-action state (lambda () (%command state :view :view :front))))
        ((eq key :f3) (%safe-ui-action state (lambda () (%command state :view :view :top))))
        ((eq key :f4) (%safe-ui-action state (lambda () (%command state :view :view :side))))))))

(defun %insert-codepoint (state codepoint)
  (let ((character (and (integerp codepoint) (ignore-errors (code-char codepoint)))))
    (when (and character (graphic-char-p character))
      (case (editor-ui-focus state)
        (:listener
         (setf (editor-ui-listener-string state)
               (concatenate 'string (editor-ui-listener-string state)
                            (string character))))
        (:inspector
         (setf (editor-ui-field-string state)
               (concatenate 'string (editor-ui-field-string state)
                            (string character))))))))

(defun %cursor-moved (state x y)
  (let* ((old-x (editor-ui-mouse-x state)) (old-y (editor-ui-mouse-y state))
         (dx (- x old-x)) (dy (- y old-y)))
    (setf (editor-ui-last-x state) old-x (editor-ui-last-y state) old-y
          (editor-ui-mouse-x state) x (editor-ui-mouse-y state) y)
    (cond
      ((editor-ui-timeline-drag state)
       (%safe-ui-action state
         (lambda () (%dispatch-workspace-action state (editor-ui-timeline-drag state)))))
      ((editor-ui-drag-gizmo state)
       (setf (editor-ui-drag-current-x state) x (editor-ui-drag-current-y state) y)
       (%safe-ui-action state (lambda () (%preview-gizmo-drag state))))
      ((editor-ui-camera-motion state)
       (let* ((editor (editor-ui-editor state))
              (camera (sgeo.scene:world-camera (sgeo.editor:editor-world editor))))
         (sgeo.scene:with-world-lock ((sgeo.editor:editor-world editor))
           (ecase (editor-ui-camera-motion state)
             (:orbit (sgeo.scene:orbit-camera camera (* dx 0.005d0) (* dy 0.005d0)))
             (:pan (sgeo.scene:pan-camera camera (* dx 0.002d0) (* dy -0.002d0))))))))))

(defun %scroll (state x y)
  (declare (ignore x))
  (let* ((mx (editor-ui-mouse-x state)) (my (editor-ui-mouse-y state))
         (layout (editor-ui-layout-rects state))
         (right (getf layout :right)) (bottom (getf layout :bottom)))
    (cond
      ((and right (%rect-contains-p mx my right))
       (setf (editor-ui-inspector-scroll state)
             (max 0 (+ (editor-ui-inspector-scroll state) (if (plusp y) -2 2)))))
      ((and bottom (%rect-contains-p mx my bottom))
       (if (< mx (+ (first bottom) (%history-panel-width state (third bottom))))
           (setf (editor-ui-history-scroll state)
                 (max 0 (+ (editor-ui-history-scroll state) (if (plusp y) -1 1))))
           (setf (editor-ui-output-scroll state)
                 (max 0 (+ (editor-ui-output-scroll state) (if (plusp y) -1 1))))))
      ((%viewport-contains-p state mx my)
       (sgeo.scene:with-world-lock ((sgeo.editor:editor-world (editor-ui-editor state)))
         (sgeo.scene:zoom-camera
          (sgeo.scene:world-camera (sgeo.editor:editor-world (editor-ui-editor state)))
          (* y -0.1d0)))))))

(defun %mouse-coordinates (state x y)
  (values (* x (editor-ui-scale-x state)) (* y (editor-ui-scale-y state))))

(defun %update-profile (state frame-time &optional delta-time)
  (let* ((renderer (editor-ui-renderer state))
         (editor (editor-ui-editor state)))
    (push (* frame-time 1000d0) (editor-ui-profile-samples state))
    (when (> (length (editor-ui-profile-samples state)) 120)
      (setf (editor-ui-profile-samples state) (subseq (editor-ui-profile-samples state) 0 120)))
    (setf (sgeo.editor:editor-profile editor)
          (list :frames (sgeo.render:renderer-frame-count renderer)
                :uploads (sgeo.render:renderer-upload-count renderer)
                :gpu-meshes (getf (sgeo.render:renderer-info renderer) :gpu-meshes)
                :frame-time frame-time :delta-time delta-time
                :bytes-consed #+sbcl (sb-ext:get-bytes-consed) #-sbcl nil
                :gc-time #+sbcl (/ sb-ext:*gc-run-time* internal-time-units-per-second) #-sbcl nil))))

(defun run-editor (world-or-editor &key (width 1280) (height 800) (visible t)
                                max-frames capture-path frame-hook repl scene-path)
  "Abre a interface nativa sobre um mundo existente ou cria um editor novo."
  (let* ((editor (if (typep world-or-editor 'sgeo.editor:editor-state)
                     world-or-editor
                     (sgeo.editor:make-editor :world world-or-editor
                                              :scene-path (or scene-path "scene.sgeo"))))
         (state (%make-editor-ui :editor editor :capture-path capture-path))
         (*active-ui-state* state)
         (world (sgeo.editor:editor-world editor))
         (window nil) (renderer nil) (ui-renderer nil)
         (terminal-thread nil) (terminal-stop-flag (list nil))
         (frame 0) (report nil))
    (setf sgeo.editor:*editor* editor)
    (unless (and (integerp width) (plusp width) (integerp height) (plusp height)
                 (or (null max-frames) (and (integerp max-frames) (plusp max-frames))))
      (error 'sgeo.core:validation-error :context "janela do editor"
             :message "Largura, altura e limite de quadros devem ser inteiros positivos."))
    (sgeo.editor:install-editor-dispatch)
    (setf (sgeo.editor::%editor-owner editor) (bt:current-thread)
          (sgeo.editor::%editor-closed-p editor) nil
          (sgeo.scene:world-running-p world) t)
    (setf (sgeo.editor:editor-running-p editor) t)
    (sgeo.backend.opengl:with-native-graphics-environment ()
      (unwind-protect
           (progn
             (setf window (sgeo.platform:make-window :width width :height height
                                                     :title "S-Geometry — Editor" :visible visible)
                   renderer (sgeo.render:create-renderer window)
                   ui-renderer (sgeo.backend.opengl:create-ui-renderer)
                   (editor-ui-window state) window
                   (editor-ui-renderer state) renderer
                   (editor-ui-ui-renderer state) ui-renderer
                   (editor-ui-previous-time state) (sgeo.platform:window-time window))
             (sgeo.editor:start-editor-listener editor)
             (when repl
               (setf terminal-thread
                     (sgeo.editor:start-editor-terminal editor terminal-stop-flag)))
             (sgeo.platform:set-key-handler
              window (lambda (key scancode action mods)
                       (declare (ignore scancode)) (%key-press state key action mods)))
             (sgeo.platform:set-character-handler
              window (lambda (codepoint) (%insert-codepoint state codepoint)))
             (sgeo.platform:set-cursor-handler
              window (lambda (x y)
                       (multiple-value-bind (px py) (%mouse-coordinates state x y)
                         (%cursor-moved state px py))))
             (sgeo.platform:set-mouse-button-handler
              window (lambda (button action mods)
        (%mouse-down state button action mods)))
             (sgeo.platform:set-scroll-handler window (lambda (x y) (%scroll state x y)))
             (multiple-value-bind (window-width window-height) (sgeo.platform:window-size window)
               (multiple-value-bind (fb-width fb-height) (sgeo.platform:framebuffer-size window)
                 (setf (editor-ui-scale-x state) (/ fb-width (max 1d0 window-width))
                       (editor-ui-scale-y state) (/ fb-height (max 1d0 window-height)))))
             (loop until (or (sgeo.platform:window-should-close-p window)
                             (car terminal-stop-flag))
                   do (sgeo.platform:poll-events window)
                      (sgeo.editor:process-editor-requests editor)
                      (setf world (sgeo.editor:editor-world editor))
                      (multiple-value-bind (window-width window-height)
                          (sgeo.platform:window-size window)
                        (multiple-value-bind (fb-width fb-height)
                            (sgeo.platform:framebuffer-size window)
                          (setf (editor-ui-width state) fb-width
                                (editor-ui-height state) fb-height
                                (editor-ui-scale-x state) (/ fb-width (max 1d0 window-width))
                                (editor-ui-scale-y state) (/ fb-height (max 1d0 window-height)))
                          (let* ((now (sgeo.platform:window-time window))
                                 (dt (max 0d0 (min 0.1d0 (- now (editor-ui-previous-time state))))))
                            (setf (editor-ui-previous-time state) now)
                            (handler-case (sgeo.editor:advance-editor-time editor dt)
                              (error (condition) (setf (editor-ui-render-condition state) condition)))
                            (when (and (plusp fb-width) (plusp fb-height))
                            (let ((start now))
                              (gl:clear-color 0.025 0.03 0.045 1.0)
                              (gl:clear :color-buffer-bit :depth-buffer-bit)
                              (let* ((layout (%make-layout state fb-width fb-height))
                                     (viewport (getf layout :viewport)))
                                (when (plusp (third viewport))
                                  (sgeo.backend.opengl:render-viewport renderer world
                                                                       (first viewport)
                                                                       (- fb-height (second viewport)
                                                                          (fourth viewport))
                                                                       (third viewport) (fourth viewport))))
                              (%draw-ui state)
                              (%update-profile state (- (sgeo.platform:window-time window) start) dt))
                          (when frame-hook
                            (handler-case (funcall frame-hook editor window renderer frame)
                              (error (condition) (setf (editor-ui-render-condition state) condition))))
                          (when (and capture-path
                                     (if max-frames (= (1+ frame) max-frames) (zerop frame)))
                            (sgeo.backend.opengl:capture-framebuffer-ppm window capture-path)
                            (setf capture-path nil))
                          (sgeo.platform:swap-buffers window))))
                      (incf frame)
                      (when (and max-frames (>= frame max-frames))
                        (sgeo.platform:request-window-close window)))
             (setf report
                   (sgeo.runtime::make-runtime-report
                    :frames (sgeo.render:renderer-frame-count renderer)
                    :uploads (sgeo.render:renderer-upload-count renderer)
                    :gpu-meshes (getf (sgeo.render:renderer-info renderer) :gpu-meshes)
                    :render-error (or (sgeo.render:renderer-last-error renderer)
                                      (editor-ui-render-condition state))
                    :platform-error (sgeo.platform:window-error window))))
        (setf (sgeo.editor:editor-running-p editor) nil)
        (ignore-errors (sgeo.editor:stop-editor-terminal terminal-thread terminal-stop-flag))
        (setf (sgeo.scene:world-running-p world) nil)
        (ignore-errors (sgeo.editor:close-editor editor))
        (when ui-renderer (ignore-errors (sgeo.backend.opengl:destroy-ui-renderer ui-renderer)))
        (when renderer (ignore-errors (sgeo.render:destroy-renderer renderer)))
        (when window (ignore-errors (sgeo.platform:close-window window)))))
    (values editor report))))
