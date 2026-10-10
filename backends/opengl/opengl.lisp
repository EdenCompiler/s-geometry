(in-package #:sgeo.backend.opengl)

(defparameter +mesh-vertex-shader+
  (format nil "#version 330 core~%layout(location=0) in vec3 aPosition;~%layout(location=1) in vec3 aNormal;~%uniform mat4 uProjection;~%uniform mat4 uView;~%uniform mat4 uModel;~%out vec3 vNormal;~%void main(){ vec4 worldPosition=uModel*vec4(aPosition,1.0); vNormal=normalize(transpose(inverse(mat3(uModel)))*aNormal); gl_Position=uProjection*uView*worldPosition; }~%"))
(defparameter +mesh-fragment-shader+
  (format nil "#version 330 core~%in vec3 vNormal;~%uniform vec3 uColor;~%uniform int uSelected;~%out vec4 fragmentColor;~%void main(){ vec3 n=normalize(vNormal); vec3 l=normalize(vec3(0.35,0.78,0.52)); float d=max(dot(n,l),0.0); vec3 c=uColor*(0.30+0.70*d); if(uSelected!=0)c=mix(c,vec3(1.0,0.52,0.08),0.22); fragmentColor=vec4(c,1.0); }~%"))

(defstruct gpu-mesh vao vertex-buffer index-buffer index-count revision)
(defclass opengl-renderer (sgeo.render:renderer)
  ((program :accessor %program :initform 0)
   (locations :accessor %locations :initform nil)
   (mesh-cache :accessor %mesh-cache :initform (make-hash-table :test #'eq))
   (window :initarg :window :reader %renderer-window)))

(defun check-opengl-error (context)
  "Sinaliza um erro OpenGL pendente como uma condição de renderização."
  (let ((errors nil))
    (loop for error-code = (gl:get-error)
          until (member error-code '(:no-error :zero 0) :test #'eql)
          do (push error-code errors))
    (when errors
      (error 'sgeo.core:render-error :context context
             :message (format nil "OpenGL retornou ~{~A~^, ~}." (nreverse errors))))
    t))

(defun %compile-shader (kind source)
  (let ((shader (gl:create-shader kind)))
    (handler-case
        (progn
          (gl:shader-source shader source)
          (gl:compile-shader shader)
          (unless (gl:get-shader shader :compile-status)
            (error 'sgeo.core:render-error :context "compilação de shader"
                   :message (gl:get-shader-info-log shader)))
          shader)
      (error (condition)
        (when (and shader (plusp shader)) (ignore-errors (gl:delete-shader shader)))
        (error condition)))))

(defun %create-program (vertex-source fragment-source)
  (let ((vertex nil) (fragment nil) (program 0) (success-p nil))
    (unwind-protect
         (progn
           (setf vertex (%compile-shader :vertex-shader vertex-source)
                 fragment (%compile-shader :fragment-shader fragment-source)
                 program (gl:create-program))
           (gl:attach-shader program vertex)
           (gl:attach-shader program fragment)
           (gl:link-program program)
           (unless (gl:get-program program :link-status)
             (error 'sgeo.core:render-error :context "vínculo de shader"
                    :message (gl:get-program-info-log program)))
           (check-opengl-error "criação do programa OpenGL")
           (setf success-p t)
           program)
      (when vertex (ignore-errors (gl:delete-shader vertex)))
      (when fragment (ignore-errors (gl:delete-shader fragment)))
      (when (and (plusp program) (not success-p))
        (ignore-errors (gl:delete-program program))))))

(defun %uniform-location (program name)
  (gl:get-uniform-location program name))
(defun %uniform (renderer name)
  (cdr (assoc name (%locations renderer) :test #'string=)))
(defun %set-mat4 (location matrix)
  (unless (= (length matrix) 16)
    (error 'sgeo.core:render-error :context "matriz OpenGL"
           :message (format nil "Esperava 16 componentes; recebi ~D." (length matrix))))
  ;; A biblioteca recebe um vetor de matrizes; transpose NIL preserva o contrato anterior.
  (gl:uniform-matrix location 4
                     (vector (map 'vector (lambda (x) (coerce x 'single-float)) matrix))
                     nil))

(defmethod sgeo.render:create-renderer ((window sgeo.platform:platform-window))
  (let ((renderer (make-instance 'opengl-renderer :window window)))
    (handler-case
        (progn
          (setf (%program renderer)
                (%create-program +mesh-vertex-shader+ +mesh-fragment-shader+))
          (setf (%locations renderer)
                (loop for name in '("uProjection" "uView" "uModel" "uColor" "uSelected")
                      collect (cons name (%uniform-location (%program renderer) name))))
          (gl:enable :depth-test)
          (gl:depth-func :less)
          (check-opengl-error "inicialização do renderizador")
          renderer)
      (error (condition)
        (when (plusp (%program renderer))
          (ignore-errors (gl:delete-program (%program renderer))))
        (error 'sgeo.core:render-error :context "inicialização OpenGL"
               :message (princ-to-string condition))))))

(defun %flat-normals (positions indices)
  (let* ((count (/ (length positions) 3)) (acc (make-array (* count 3) :initial-element 0d0)))
    (loop for i from 0 below (length indices) by 3
          for a = (* 3 (aref indices i)) for b = (* 3 (aref indices (+ i 1)))
          for c = (* 3 (aref indices (+ i 2)))
          for ux = (- (aref positions b) (aref positions a))
          for uy = (- (aref positions (+ b 1)) (aref positions (+ a 1)))
          for uz = (- (aref positions (+ b 2)) (aref positions (+ a 2)))
          for vx = (- (aref positions c) (aref positions a))
          for vy = (- (aref positions (+ c 1)) (aref positions (+ a 1)))
          for vz = (- (aref positions (+ c 2)) (aref positions (+ a 2)))
          for nx = (- (* uy vz) (* uz vy)) for ny = (- (* uz vx) (* ux vz))
          for nz = (- (* ux vy) (* uy vx))
          do (dolist (vertex (list a b c))
               (incf (aref acc vertex) nx) (incf (aref acc (+ vertex 1)) ny)
               (incf (aref acc (+ vertex 2)) nz)))
    (loop for i from 0 below count for offset = (* i 3)
          for length = (sqrt (+ (expt (aref acc offset) 2)
                                (expt (aref acc (+ offset 1)) 2)
                                (expt (aref acc (+ offset 2)) 2)))
          do (if (> length 1d-18)
                 (loop for j below 3 do (setf (aref acc (+ offset j))
                                               (/ (aref acc (+ offset j)) length)))
                 (setf (aref acc (+ offset 2)) 1d0)))
    acc))

(defun %destroy-gpu-mesh (mesh)
  (when mesh
    (gl:delete-vertex-array (gpu-mesh-vao mesh))
    (gl:delete-buffers (list (gpu-mesh-vertex-buffer mesh)
                             (gpu-mesh-index-buffer mesh)))))

(defun %fill-gl-array (type values)
  (let ((array (gl:alloc-gl-array type (length values))))
    (handler-case
        (progn
          (dotimes (index (length values))
            (setf (gl:glaref array index) (aref values index)))
          array)
      (error (condition)
        (gl:free-gl-array array)
        (error condition)))))

(defun %upload-mesh (renderer geometry revision positions normals indices)
  (unless (and positions indices (plusp (length positions)) (plusp (length indices)))
    (error 'sgeo.core:render-error :context "malha"
           :message "A malha precisa conter posições e índices."))
  (unless (and (zerop (mod (length positions) 3))
               (every (lambda (index) (< index (/ (length positions) 3))) indices))
    (error 'sgeo.core:render-error :context "malha"
           :message "As posições ou índices da malha são inválidos."))
  (let* ((normal-values (or normals (%flat-normals positions indices)))
         (vertex-count (/ (length positions) 3))
         (interleaved (make-array (* vertex-count 6) :element-type 'single-float))
         (vao 0) (vbo 0) (ebo 0) (new-mesh nil))
    (unless (= (length normal-values) (length positions))
      (error 'sgeo.core:render-error :context "malha"
             :message "Normais e posições têm dimensões diferentes."))
    (loop for vertex below vertex-count for source = (* vertex 3) for target = (* vertex 6)
          do (loop for axis below 3
                   do (setf (aref interleaved (+ target axis))
                            (coerce (aref positions (+ source axis)) 'single-float)
                            (aref interleaved (+ target 3 axis))
                            (coerce (aref normal-values (+ source axis)) 'single-float))))
    (let ((vertex-array nil) (index-array nil))
      (handler-case
          (unwind-protect
               (progn
                 (setf vertex-array (%fill-gl-array :float interleaved)
                       index-array (%fill-gl-array :unsigned-int indices)
                       vao (gl:gen-vertex-array)
                       vbo (gl:gen-buffer)
                       ebo (gl:gen-buffer))
                 (gl:bind-vertex-array vao)
                 (gl:bind-buffer :array-buffer vbo)
                 (gl:buffer-data :array-buffer :static-draw vertex-array)
                 (gl:bind-buffer :element-array-buffer ebo)
                 (gl:buffer-data :element-array-buffer :static-draw index-array)
                 (gl:vertex-attrib-pointer 0 3 :float nil 24 (cffi:null-pointer))
                 (gl:enable-vertex-attrib-array 0)
                 (gl:vertex-attrib-pointer 1 3 :float nil 24 (cffi:make-pointer 12))
                 (gl:enable-vertex-attrib-array 1)
                 (setf new-mesh
                       (make-gpu-mesh :vao vao :vertex-buffer vbo :index-buffer ebo
                                      :index-count (length indices) :revision revision))
                 (check-opengl-error "envio da malha para OpenGL")
                 (let ((old (gethash geometry (%mesh-cache renderer))))
                   (setf (gethash geometry (%mesh-cache renderer)) new-mesh)
                   (%destroy-gpu-mesh old))
                 (incf (sgeo.render:renderer-upload-count renderer))
                 new-mesh)
            (when vertex-array (gl:free-gl-array vertex-array))
            (when index-array (gl:free-gl-array index-array)))
        (error (condition)
          (unless (eq new-mesh (gethash geometry (%mesh-cache renderer)))
            (when (plusp vao) (ignore-errors (gl:delete-vertex-array vao)))
            (gl:delete-buffers (remove 0 (list vbo ebo))))
          (error condition))))))

(defun %entry-value (entry key &optional default)
  (getf entry key default))
(defun %mesh-for-entry (renderer entry)
  (let* ((geometry (or (%entry-value entry :render-key) (%entry-value entry :geometry)))
         (revision (%entry-value entry :revision))
         (cached (and geometry (gethash geometry (%mesh-cache renderer)))))
    (if (and cached (eql revision (gpu-mesh-revision cached)))
        cached
        (%upload-mesh renderer geometry revision
                      (%entry-value entry :positions) (%entry-value entry :normals)
                      (%entry-value entry :indices)))))

(defun %set-color (location color)
  (let ((values (or color #(0.72d0 0.76d0 0.82d0))))
    (gl:uniformf location (coerce (elt values 0) 'single-float)
                 (coerce (elt values 1) 'single-float)
                 (coerce (elt values 2) 'single-float))))

(defun %draw-entry (renderer entry selected-object)
  (let* ((object (%entry-value entry :object))
         (model (%entry-value entry :model-matrix))
         (wireframe (%entry-value entry :wireframe-p))
         (mesh (%mesh-for-entry renderer entry)))
    (when (and mesh model)
      (%set-mat4 (%uniform renderer "uModel") model)
      (%set-color (%uniform renderer "uColor") (%entry-value entry :color))
      (gl:uniformi (%uniform renderer "uSelected") (if (eq object selected-object) 1 0))
      (gl:bind-vertex-array (gpu-mesh-vao mesh))
      (when wireframe (gl:polygon-mode :front-and-back :line))
      (gl:draw-elements :triangles (gl:make-null-gl-array :unsigned-int)
                        :count (gpu-mesh-index-count mesh))
      (when wireframe (gl:polygon-mode :front-and-back :fill))
      (when (eq object selected-object)
        (gl:uniformi (%uniform renderer "uSelected") 0)
        (gl:polygon-mode :front-and-back :line)
        (gl:line-width 2.0)
        (gl:draw-elements :triangles (gl:make-null-gl-array :unsigned-int)
                          :count (gpu-mesh-index-count mesh))
        (gl:polygon-mode :front-and-back :fill)))))

(defvar *render-viewport-origin* '(0 0))

(defun render-viewport (renderer world x y width height)
  "Renderiza a cena em uma região do framebuffer, com origem OpenGL inferior."
  (let ((*render-viewport-origin* (list x y)))
    (sgeo.render:render-frame renderer world width height)))

(defmethod sgeo.render:render-frame ((renderer opengl-renderer) world width height)
  (handler-case
      (let* ((safe-width (max 1 width)) (safe-height (max 1 height))
             (snapshot (sgeo.scene:render-snapshot world (/ (float safe-width 1d0) safe-height)))
             (projection (getf snapshot :projection-matrix))
             (view (getf snapshot :view-matrix))
             (entries (getf snapshot :objects))
             (selection (getf snapshot :selected-object)))
        (gl:viewport (first *render-viewport-origin*) (second *render-viewport-origin*) width height)
        (gl:clear-color 0.055 0.068 0.09 1.0)
        (gl:clear :color-buffer-bit :depth-buffer-bit)
        (gl:use-program (%program renderer))
        (%set-mat4 (%uniform renderer "uProjection") projection)
        (%set-mat4 (%uniform renderer "uView") view)
        (dolist (entry entries) (%draw-entry renderer entry selection))
        (check-opengl-error "renderização do quadro")
        (incf (sgeo.render:renderer-frame-count renderer))
        (setf (sgeo.render:renderer-last-error renderer) nil)
        t)
    (error (condition)
      (setf (sgeo.render:renderer-last-error renderer) condition)
      nil)))

(defmethod sgeo.render:destroy-renderer ((renderer opengl-renderer))
  (maphash (lambda (geometry mesh)
             (declare (ignore geometry)) (%destroy-gpu-mesh mesh))
           (%mesh-cache renderer))
  (clrhash (%mesh-cache renderer))
  (when (plusp (%program renderer))
    (gl:delete-program (%program renderer))
    (setf (%program renderer) 0))
  renderer)

(defmethod sgeo.render:renderer-info ((renderer opengl-renderer))
  (append (call-next-method)
          (list :gpu-meshes (hash-table-count (%mesh-cache renderer))
                :opengl-version (gl:get-string :version))))

(defmethod sgeo.render:capture-frame ((renderer opengl-renderer) window path)
  (declare (ignore renderer))
  (capture-framebuffer-ppm window path))

(defun capture-framebuffer-ppm (window path)
  "Grava o framebuffer atual como PPM P6, com origem no canto superior esquerdo."
  (multiple-value-bind (width height) (sgeo.platform:framebuffer-size window)
    (unless (and (plusp width) (plusp height))
      (error 'sgeo.core:render-error :context "captura de quadro"
             :message "O framebuffer precisa ter largura e altura positivas."))
    (let ((pixels (gl:read-pixels 0 0 width height :rgba :unsigned-byte)))
      (ensure-directories-exist path)
      (with-open-file (stream path :direction :output :if-exists :supersede
                                    :if-does-not-exist :create
                                    :element-type '(unsigned-byte 8))
        (write-sequence (map '(vector (unsigned-byte 8)) #'char-code
                             (format nil "P6~%~D ~D~%255~%" width height)) stream)
        (loop for y from (1- height) downto 0
              do (loop for x below width for offset = (* (+ x (* y width)) 4)
                       do (write-byte (aref pixels offset) stream)
                          (write-byte (aref pixels (+ offset 1)) stream)
                          (write-byte (aref pixels (+ offset 2)) stream)))))
    (check-opengl-error "captura do framebuffer"))
  path)
