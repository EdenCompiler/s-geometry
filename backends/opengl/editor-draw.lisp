(in-package #:sgeo.backend.opengl)

(defparameter +ui-vertex-shader+
  (format nil
          "#version 330 core~%layout(location=0) in vec2 aPosition;~%layout(location=1) in vec4 aColor;~%layout(location=2) in vec2 aUV;~%uniform vec2 uViewport;~%out vec4 vColor;~%out vec2 vUV;~%void main(){ vec2 p=vec2(2.0*aPosition.x/uViewport.x-1.0,1.0-2.0*aPosition.y/uViewport.y); gl_Position=vec4(p,0.0,1.0); vColor=aColor; vUV=aUV; }~%"))
(defparameter +ui-fragment-shader+
  (format nil
          "#version 330 core~%in vec4 vColor;~%in vec2 vUV;~%uniform sampler2D uFont;~%uniform int uText;~%out vec4 fragmentColor;~%void main(){ float coverage=(uText==0)?1.0:texture(uFont,vUV).r; fragmentColor=vec4(vColor.rgb,vColor.a*coverage); }~%"))

(defstruct ui-glyph x y width height bearing-x bearing-y advance u0 v0 u1 v1)
(defstruct (ui-renderer (:constructor %make-ui-renderer))
  (program 0) (vao 0) (vbo 0) (font-texture 0) (viewport-location -1)
  (text-location -1) (font-location -1) (glyphs (make-array 256))
  (ascender 14d0) (line-height 17d0) (width 0) (height 0)
  solid-vertices text-vertices saved-state batches batch-kind)

(defun %ui-font-pathname ()
  "Encontra a fonte distribuída junto ao sistema gráfico."
  (let* ((base (or (ignore-errors (asdf:system-source-directory :sgeo/backend/opengl))
                   (merge-pathnames "../../"
                                    (make-pathname :name nil :type nil
                                                   :defaults (or *compile-file-truename*
                                                                 *load-truename*)))))
         (path (merge-pathnames "assets/fonts/DejaVuSansMono.ttf" base)))
    (unless (probe-file path)
      (error 'sgeo.core:render-error :context "fonte da interface"
             :message (format nil "Não encontrei a fonte distribuída: ~A" path)))
    path))

(defun %ui-font-atlas ()
  "Rasteriza caracteres latinos em células de tamanho fixo com FreeType."
  (let* ((cell-width 18) (cell-height 22) (columns 16)
         (rows 16) (atlas-width (* columns cell-width))
         (atlas-height (* rows cell-height))
         (pixels (make-array (* atlas-width atlas-height)
                             :element-type '(unsigned-byte 8) :initial-element 0))
         (glyphs (make-array 256)) (ascender 14d0) (line-height 17d0))
    (freetype2:with-open-face (face (%ui-font-pathname))
      (freetype2:set-pixel-sizes face 0 16)
      (setf ascender (freetype2:face-ascender-pixels face)
            line-height (+ (freetype2:face-ascender-pixels face)
                           (freetype2:face-descender-pixels face)))
      (dotimes (code 256)
        (let ((character (code-char code)))
          (freetype2:load-char face character)
          (let* ((slot (freetype2:render-glyph face))
                 (bitmap (freetype2-types:ft-glyphslot-bitmap slot))
                 (bitmap-array (freetype2:bitmap-to-array bitmap))
                 (width (array-dimension bitmap-array 1))
                 (height (array-dimension bitmap-array 0))
                 (col (mod code columns)) (row (floor code columns))
                 (x0 (* col cell-width)) (y0 (* row cell-height))
                 (left (freetype2-types:ft-glyphslot-bitmap-left slot))
                 (top (freetype2-types:ft-glyphslot-bitmap-top slot))
                 (advance (freetype2:get-loaded-advance face nil)))
            (when (and (<= width cell-width) (<= height cell-height))
              (dotimes (y height)
                (dotimes (x width)
                  (setf (aref pixels (+ (* (+ y0 y) atlas-width) x0 x))
                        (aref bitmap-array y x))))
              (setf (aref glyphs code)
                    (make-ui-glyph :x x0 :y y0 :width width :height height
                                   :bearing-x left :bearing-y top :advance advance
                                   :u0 (/ (float x0 1f0) atlas-width)
                                   :v0 (/ (float y0 1f0) atlas-height)
                                   :u1 (/ (float (+ x0 width) 1f0) atlas-width)
                                   :v1 (/ (float (+ y0 height) 1f0) atlas-height)))))))
    (values pixels glyphs ascender line-height atlas-width atlas-height))))

(defun %ui-gl-array (values)
  (let ((array (gl:alloc-gl-array :float (length values))))
    (handler-case
        (progn
          (dotimes (index (length values))
            (setf (gl:glaref array index) (aref values index)))
          array)
      (error (condition)
        (gl:free-gl-array array)
        (error condition)))))

(defun %ui-color-components (color)
  (let ((parts (coerce color 'list)))
    (unless (member (length parts) '(3 4))
      (error 'sgeo.core:render-error :context "cor da interface"
             :message "A cor deve conter três ou quatro componentes."))
    (let ((rgba (if (= (length parts) 3) (append parts '(1d0)) parts)))
      (unless (every (lambda (component)
                       (and (realp component) (<= 0 component 1))) rgba)
        (error 'sgeo.core:render-error :context "cor da interface"
               :message "Os componentes de cor devem estar entre zero e um."))
      (mapcar (lambda (component) (coerce component 'single-float)) rgba))))

(defun %ui-vertex (buffer x y color &optional (u 0f0) (v 0f0))
  (dolist (value (list (coerce x 'single-float) (coerce y 'single-float)
                       (first color) (second color) (third color) (fourth color)
                       (coerce u 'single-float) (coerce v 'single-float)))
    (vector-push-extend value buffer)))

(defun %ui-triangle (buffer p1 p2 p3 color &optional uv1 uv2 uv3)
  (%ui-vertex buffer (first p1) (second p1) color
              (or (first uv1) 0f0) (or (second uv1) 0f0))
  (%ui-vertex buffer (first p2) (second p2) color
              (or (first uv2) 0f0) (or (second uv2) 0f0))
  (%ui-vertex buffer (first p3) (second p3) color
              (or (first uv3) 0f0) (or (second uv3) 0f0)))

(defun %ui-quad (buffer x1 y1 x2 y2 color &optional uv1 uv2 uv3 uv4)
  (let ((a (list x1 y1)) (b (list x2 y1)) (c (list x2 y2)) (d (list x1 y2)))
    (%ui-triangle buffer a b c color uv1 uv2 uv3)
    (%ui-triangle buffer a c d color uv1 uv3 uv4)))

(defun %ui-query-integer (name &optional (count 1))
  (let ((result (gl:get-integer name count)))
    (if (= count 1) (if (vectorp result) (aref result 0) result) result)))

(defun %ui-enabled-p (capability)
  (not (null (gl:get-boolean capability))))

(defun %ui-save-state ()
  (let* ((active-texture (%ui-query-integer :active-texture))
         (texture-binding (%ui-query-integer :texture-binding-2d))
         (unit-zero-binding
           (progn
             (gl:active-texture :texture0)
             (prog1 (%ui-query-integer :texture-binding-2d)
               (gl:active-texture active-texture)))))
    (list :program (%ui-query-integer :current-program)
          :vao (%ui-query-integer :vertex-array-binding)
          :array-buffer (%ui-query-integer :array-buffer-binding)
          :active-texture active-texture :texture-binding texture-binding
          :unit-zero-binding unit-zero-binding
          :blend (%ui-enabled-p :blend) :depth (%ui-enabled-p :depth-test)
          :cull (%ui-enabled-p :cull-face) :scissor (%ui-enabled-p :scissor-test)
          :blend-src-rgb (%ui-query-integer :blend-src-rgb)
          :blend-dst-rgb (%ui-query-integer :blend-dst-rgb)
          :blend-src-alpha (%ui-query-integer :blend-src-alpha)
          :blend-dst-alpha (%ui-query-integer :blend-dst-alpha)
          :viewport (%ui-query-integer :viewport 4))))

(defun %ui-restore-state (state)
  (when state
    (gl:use-program (getf state :program))
    (gl:bind-vertex-array (getf state :vao))
    (gl:bind-buffer :array-buffer (getf state :array-buffer))
    (gl:active-texture :texture0)
    (gl:bind-texture :texture-2d (getf state :unit-zero-binding))
    (gl:active-texture (getf state :active-texture))
    (gl:bind-texture :texture-2d (getf state :texture-binding))
    (gl:blend-func-separate (getf state :blend-src-rgb) (getf state :blend-dst-rgb)
                            (getf state :blend-src-alpha) (getf state :blend-dst-alpha))
    (dolist (entry '((:blend :blend) (:depth :depth-test)
                     (:cull :cull-face) (:scissor :scissor-test)))
      (if (getf state (first entry)) (gl:enable (second entry))
          (gl:disable (second entry))))
    (apply #'gl:viewport (coerce (getf state :viewport) 'list))))

(defun create-ui-renderer ()
  "Cria recursos OpenGL 3.3 para desenhar formas e texto da interface."
  (multiple-value-bind (pixels glyphs ascender line-height atlas-width atlas-height)
      (%ui-font-atlas)
    (let ((renderer (%make-ui-renderer :glyphs glyphs :ascender ascender
                                       :line-height line-height))
          (program 0) (success-p nil)
          (saved-state (%ui-save-state))
          (unpack-alignment (%ui-query-integer :unpack-alignment)))
      (unwind-protect
           (progn
             (setf program (%create-program +ui-vertex-shader+ +ui-fragment-shader+)
                   (ui-renderer-program renderer) program)
             (setf (ui-renderer-viewport-location renderer)
                   (gl:get-uniform-location program "uViewport")
                   (ui-renderer-text-location renderer)
                   (gl:get-uniform-location program "uText")
                   (ui-renderer-font-location renderer)
                   (gl:get-uniform-location program "uFont"))
             (setf (ui-renderer-vao renderer) (gl:gen-vertex-array)
                   (ui-renderer-vbo renderer) (gl:gen-buffer)
                   (ui-renderer-font-texture renderer) (gl:gen-texture))
             (gl:bind-vertex-array (ui-renderer-vao renderer))
             (gl:bind-buffer :array-buffer (ui-renderer-vbo renderer))
             (let ((empty-array (%ui-gl-array #())))
               (unwind-protect
                    (gl:buffer-data :array-buffer :stream-draw empty-array)
                 (gl:free-gl-array empty-array)))
             (gl:vertex-attrib-pointer 0 2 :float nil 32 (cffi:null-pointer))
             (gl:enable-vertex-attrib-array 0)
             (gl:vertex-attrib-pointer 1 4 :float nil 32 (cffi:make-pointer 8))
             (gl:enable-vertex-attrib-array 1)
             (gl:vertex-attrib-pointer 2 2 :float nil 32 (cffi:make-pointer 24))
             (gl:enable-vertex-attrib-array 2)
             (gl:active-texture :texture0)
             (gl:bind-texture :texture-2d (ui-renderer-font-texture renderer))
             (gl:tex-parameter :texture-2d :texture-min-filter :nearest)
             (gl:tex-parameter :texture-2d :texture-mag-filter :nearest)
             (gl:tex-parameter :texture-2d :texture-wrap-s :clamp-to-edge)
             (gl:tex-parameter :texture-2d :texture-wrap-t :clamp-to-edge)
             (gl:pixel-store :unpack-alignment 1)
             (gl:tex-image-2d :texture-2d 0 :r8 atlas-width atlas-height 0
                              :red :unsigned-byte pixels :raw t)
             (gl:use-program program)
             (gl:uniformi (ui-renderer-font-location renderer) 0)
             (check-opengl-error "criação do renderizador da interface")
             (setf success-p t)
             renderer)
        (unless success-p
          (when (plusp (ui-renderer-font-texture renderer))
            (ignore-errors (gl:delete-texture (ui-renderer-font-texture renderer))))
          (when (plusp (ui-renderer-vbo renderer))
            (ignore-errors (gl:delete-buffers (list (ui-renderer-vbo renderer)))))
          (when (plusp (ui-renderer-vao renderer))
            (ignore-errors (gl:delete-vertex-array (ui-renderer-vao renderer))))
          (when (plusp program) (ignore-errors (gl:delete-program program))))
        (ignore-errors (gl:pixel-store :unpack-alignment unpack-alignment))
        (ignore-errors (%ui-restore-state saved-state))))))

(defun destroy-ui-renderer (renderer)
  "Libera os recursos gráficos pertencentes ao renderizador da interface."
  (when renderer
    (when (plusp (ui-renderer-font-texture renderer))
      (gl:delete-texture (ui-renderer-font-texture renderer)))
    (when (plusp (ui-renderer-vbo renderer))
      (gl:delete-buffers (list (ui-renderer-vbo renderer))))
    (when (plusp (ui-renderer-vao renderer))
      (gl:delete-vertex-array (ui-renderer-vao renderer)))
    (when (plusp (ui-renderer-program renderer))
      (gl:delete-program (ui-renderer-program renderer)))
    (setf (ui-renderer-font-texture renderer) 0
          (ui-renderer-vbo renderer) 0
          (ui-renderer-vao renderer) 0
          (ui-renderer-program renderer) 0))
  nil)

(defun begin-ui-frame (renderer width height)
  "Inicia a coleta de primitivas em coordenadas de tela com origem no topo."
  (unless (and (plusp width) (plusp height))
    (error 'sgeo.core:render-error :context "quadro da interface"
           :message "A área de desenho deve ter largura e altura positivas."))
  (when (ui-renderer-saved-state renderer)
    (error 'sgeo.core:render-error :context "quadro da interface"
           :message "O quadro anterior da interface ainda não foi concluído."))
  (setf (ui-renderer-saved-state renderer) (%ui-save-state)
        (ui-renderer-width renderer) width
        (ui-renderer-height renderer) height
        (ui-renderer-batches renderer) nil
        (ui-renderer-batch-kind renderer) nil
        (ui-renderer-solid-vertices renderer)
        (make-array 0 :element-type 'single-float :fill-pointer 0 :adjustable t)
        (ui-renderer-text-vertices renderer)
        (make-array 0 :element-type 'single-float :fill-pointer 0 :adjustable t))
  (values))

(defun %ui-buffer (renderer kind)
  "Agrupa primitivas consecutivas sem perder a ordem das camadas visuais."
  (unless (ui-renderer-saved-state renderer)
    (error 'sgeo.core:render-error :context "primitiva da interface"
           :message "Chame BEGIN-UI-FRAME antes de adicionar primitivas."))
  (unless (eq kind (ui-renderer-batch-kind renderer))
    (let ((previous (ui-renderer-batch-kind renderer)))
      (when previous
        (push (list previous (if (eq previous :text)
                                 (ui-renderer-text-vertices renderer)
                                 (ui-renderer-solid-vertices renderer)))
              (ui-renderer-batches renderer))))
    (let ((buffer (make-array 0 :element-type 'single-float :fill-pointer 0 :adjustable t)))
      (if (eq kind :text) (setf (ui-renderer-text-vertices renderer) buffer)
          (setf (ui-renderer-solid-vertices renderer) buffer)))
    (setf (ui-renderer-batch-kind renderer) kind))
  (if (eq kind :text) (ui-renderer-text-vertices renderer)
      (ui-renderer-solid-vertices renderer)))

(defun ui-rect (renderer x y width height color &key (filled-p t))
  "Adiciona um retângulo preenchido ou contornado ao quadro atual."
  (let ((rgba (%ui-color-components color))
        (buffer (%ui-buffer renderer :solid)))
    (unless buffer
      (error 'sgeo.core:render-error :context "retângulo da interface"
             :message "Chame BEGIN-UI-FRAME antes de adicionar primitivas."))
    (if filled-p
        (%ui-quad buffer x y (+ x width) (+ y height) rgba)
        (progn
          (ui-line renderer x y (+ x width) y color)
          (ui-line renderer (+ x width) y (+ x width) (+ y height) color)
          (ui-line renderer (+ x width) (+ y height) x (+ y height) color)
          (ui-line renderer x (+ y height) x y color)))
    renderer))

(defun ui-line (renderer x1 y1 x2 y2 color &key (width 1d0))
  "Adiciona um segmento de espessura em pixels ao quadro atual."
  (let* ((rgba (%ui-color-components color))
         (buffer (%ui-buffer renderer :solid))
         (dx (- x2 x1)) (dy (- y2 y1))
         (length (sqrt (+ (* dx dx) (* dy dy))))
         (half (/ width 2d0)))
    (unless buffer
      (error 'sgeo.core:render-error :context "linha da interface"
             :message "Chame BEGIN-UI-FRAME antes de adicionar primitivas."))
    (unless (plusp width)
      (error 'sgeo.core:render-error :context "linha da interface"
             :message "A espessura deve ser positiva."))
    (if (< length 1d-9)
        (%ui-quad buffer (- x1 half) (- y1 half) (+ x1 half) (+ y1 half) rgba)
        (let* ((px (* (- (/ dy length)) half))
               (py (* (/ dx length) half))
               (a (list (+ x1 px) (+ y1 py)))
               (b (list (+ x2 px) (+ y2 py)))
               (c (list (- x2 px) (- y2 py)))
               (d (list (- x1 px) (- y1 py))))
          (%ui-triangle buffer a b c rgba)
          (%ui-triangle buffer a c d rgba)))
    renderer))

(defun ui-text (renderer x y string color &key (scale 1d0))
  "Adiciona texto monoespaçado; X,Y indicam o canto superior esquerdo."
  (let ((buffer (%ui-buffer renderer :text))
        (rgba (%ui-color-components color))
        (cursor-x x) (cursor-y y))
    (unless buffer
      (error 'sgeo.core:render-error :context "texto da interface"
             :message "Chame BEGIN-UI-FRAME antes de adicionar primitivas."))
    (unless (and (realp scale) (plusp scale))
      (error 'sgeo.core:render-error :context "texto da interface"
             :message "A escala do texto deve ser positiva."))
    (loop for character across string
          for code = (char-code character)
          do (cond
               ((char= character #\Newline)
                (setf cursor-x x)
                (incf cursor-y (* scale (ui-renderer-line-height renderer))))
               (t
                (let* ((index (if (< code 256) code (char-code #\?)))
                       (glyph (aref (ui-renderer-glyphs renderer) index)))
                  (when (and glyph (plusp (ui-glyph-width glyph))
                             (plusp (ui-glyph-height glyph)))
                    (let ((left (+ cursor-x (* scale (ui-glyph-bearing-x glyph))))
                          (top (+ cursor-y (* scale (- (ui-renderer-ascender renderer)
                                                        (ui-glyph-bearing-y glyph))))))
                      (%ui-quad buffer left top
                                (+ left (* scale (ui-glyph-width glyph)))
                                (+ top (* scale (ui-glyph-height glyph))) rgba
                                (list (ui-glyph-u0 glyph) (ui-glyph-v0 glyph))
                                (list (ui-glyph-u1 glyph) (ui-glyph-v0 glyph))
                                (list (ui-glyph-u1 glyph) (ui-glyph-v1 glyph))
                                (list (ui-glyph-u0 glyph) (ui-glyph-v1 glyph)))))
                  (incf cursor-x (* scale (ui-glyph-advance glyph)))))))
    renderer))

(defun %ui-draw-batch (renderer vertices text-p)
  (when (plusp (length vertices))
    (let ((array (%ui-gl-array vertices)))
      (unwind-protect
           (progn
             (gl:bind-vertex-array (ui-renderer-vao renderer))
             (gl:bind-buffer :array-buffer (ui-renderer-vbo renderer))
             (gl:buffer-data :array-buffer :stream-draw array)
             (gl:use-program (ui-renderer-program renderer))
             (gl:uniformf (ui-renderer-viewport-location renderer)
                            (coerce (ui-renderer-width renderer) 'single-float)
                            (coerce (ui-renderer-height renderer) 'single-float))
             (gl:uniformi (ui-renderer-text-location renderer) (if text-p 1 0))
             (when text-p
               (gl:active-texture :texture0)
               (gl:bind-texture :texture-2d (ui-renderer-font-texture renderer)))
             (gl:draw-arrays :triangles 0 (/ (length vertices) 8)))
        (gl:free-gl-array array)))))

(defun finish-ui-frame (renderer)
  "Desenha as primitivas coletadas e restaura o estado OpenGL anterior."
  (let ((state (ui-renderer-saved-state renderer)))
    (unless state
      (error 'sgeo.core:render-error :context "quadro da interface"
             :message "Não há quadro da interface em andamento."))
    (unwind-protect
         (progn
           (gl:viewport 0 0 (ui-renderer-width renderer) (ui-renderer-height renderer))
           (gl:disable :depth-test)
           (gl:disable :cull-face)
           (gl:disable :scissor-test)
           (gl:enable :blend)
           (gl:blend-func-separate :src-alpha :one-minus-src-alpha
                                   :one :one-minus-src-alpha)
           (let ((kind (ui-renderer-batch-kind renderer)))
             (when kind
               (push (list kind (if (eq kind :text)
                                   (ui-renderer-text-vertices renderer)
                                   (ui-renderer-solid-vertices renderer)))
                     (ui-renderer-batches renderer))))
           (dolist (batch (reverse (ui-renderer-batches renderer)))
             (%ui-draw-batch renderer (second batch) (eq (first batch) :text)))
           (check-opengl-error "desenho da interface"))
      (%ui-restore-state state)
      (setf (ui-renderer-saved-state renderer) nil
            (ui-renderer-batches renderer) nil
            (ui-renderer-batch-kind renderer) nil
            (ui-renderer-solid-vertices renderer) nil
            (ui-renderer-text-vertices renderer) nil))))
