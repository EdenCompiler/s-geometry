(in-package #:sgeo.backend.opengl)

(defparameter +geometry-transform-compute-shader+
  (format nil
          "#version 430 core~%layout(local_size_x=64) in;~%layout(std430,binding=0) buffer PositionData{float values[];} positions;~%uniform uint vertexCount;~%uniform vec3 scaleValue;~%uniform vec3 translationValue;~%uniform float waveAmplitude;~%uniform float waveFrequency;~%uniform float wavePhase;~%void main(){uint i=gl_GlobalInvocationID.x;if(i>=vertexCount)return;uint o=i*3u;vec3 p=vec3(positions.values[o],positions.values[o+1u],positions.values[o+2u])*scaleValue;p+=translationValue;p.y+=waveAmplitude*sin(p.x*waveFrequency+wavePhase);positions.values[o]=p.x;positions.values[o+1u]=p.y;positions.values[o+2u]=p.z;}~%"))

(defparameter +geometry-normal-compute-shader+
  (format nil
          "#version 430 core~%layout(local_size_x=64) in;~%layout(std430,binding=0) readonly buffer PositionData{float p[];} positions;~%layout(std430,binding=1) readonly buffer IndexData{uint i[];} indices;~%layout(std430,binding=2) writeonly buffer NormalData{float n[];} normals;~%uniform uint vertexCount;~%uniform uint indexCount;~%void main(){uint v=gl_GlobalInvocationID.x;if(v>=vertexCount)return;vec3 sum=vec3(0.0);for(uint t=0u;t<indexCount;t+=3u){uint a=indices.i[t],b=indices.i[t+1u],c=indices.i[t+2u];if(a!=v&&b!=v&&c!=v)continue;vec3 pa=vec3(positions.p[a*3u],positions.p[a*3u+1u],positions.p[a*3u+2u]);vec3 pb=vec3(positions.p[b*3u],positions.p[b*3u+1u],positions.p[b*3u+2u]);vec3 pc=vec3(positions.p[c*3u],positions.p[c*3u+1u],positions.p[c*3u+2u]);sum+=cross(pb-pa,pc-pa);}float m=length(sum);vec3 normal=m>1e-20?sum/m:vec3(0.0,0.0,1.0);normals.n[v*3u]=normal.x;normals.n[v*3u+1u]=normal.y;normals.n[v*3u+2u]=normal.z;}~%"))

(defvar *opengl-geometry-normal-cache*
  #+sbcl (make-hash-table :test #'eq :weakness :key)
  #-sbcl (make-hash-table :test #'eq))
(defvar *opengl-geometry-cache-lock* (bt:make-lock "sgeo GPU geometry cache"))
(defvar *opengl-compute-resource-observer* nil)

(defun %observe-compute-resource (action kind identifier)
  (when *opengl-compute-resource-observer*
    (funcall *opengl-compute-resource-observer* action kind identifier)))

(defun clear-opengl-geometry-cache ()
  "Libera resultados GPU derivados armazenados pelo backend OpenGL."
  (bt:with-lock-held (*opengl-geometry-cache-lock*)
    (clrhash *opengl-geometry-normal-cache*))
  nil)

(defun %call-with-geometry-lock (geometry function)
  (etypecase geometry
    (sgeo.geometry:triangle-mesh
     (bt:with-recursive-lock-held ((sgeo.geometry::%mesh-data-lock geometry))
       (funcall function)))
    (sgeo.geometry:half-edge-mesh
     (sgeo.geometry::%with-kernel-lock-fn geometry function))))

(defun %query-integer-state (enum)
  (cffi:with-foreign-object (value :int)
    (%gl:get-integer-v enum value)
    (cffi:mem-ref value :int)))

(defun %query-indexed-integer-state (enum index)
  (cffi:with-foreign-object (value :int)
    (%gl:get-integer-i-v enum index value)
    (cffi:mem-ref value :int)))

(defun %geometry-version-supported-p ()
  (and (>= (gl:major-version) 4)
       (or (> (gl:major-version) 4) (>= (gl:minor-version) 3))))

(defun opengl-compute-capabilities ()
  "Informa se o contexto atual suporta compute shaders e SSBOs OpenGL 4.3."
  (let* ((version (ignore-errors (gl:get-string :version)))
         (device (ignore-errors (gl:get-string :renderer)))
         (supported (ignore-errors (%geometry-version-supported-p))))
    (sgeo.geometry-processing::%make-compute-capabilities
     :supported-p (not (null supported)) :backend :opengl
     :reason (if supported "Compute shader e SSBO OpenGL 4.3 disponíveis."
                 (format nil "Este contexto requer OpenGL 4.3 para compute/SSBO; disponível: ~A."
                         (or version "sem contexto OpenGL atual")))
     :version version :device device)))

(defmethod sgeo.geometry-processing:processor-capabilities ((processor (eql :opengl)))
  (opengl-compute-capabilities))

(defun %gpu-buffer (target values type)
  (let ((buffer (gl:gen-buffer)) (array nil) (complete nil))
    (when (zerop buffer)
      (error 'sgeo.geometry-processing:geometry-processing-error
             :reason "O driver não alocou um buffer de geometria."))
    (%observe-compute-resource :created :buffer buffer)
    (unwind-protect
         (progn
           (setf array (%fill-gl-array type values))
           (gl:bind-buffer target buffer)
           (gl:buffer-data target :dynamic-copy array)
           (check-opengl-error "alocação de buffer de compute")
           (setf complete t)
           buffer)
      (when array (gl:free-gl-array array))
      (unless complete
        (ignore-errors (gl:delete-buffers (list buffer)))
        (%observe-compute-resource :deleted :buffer buffer)))))

(defun %compute-program (source)
  (let ((shader nil) (program 0) (complete nil))
    (unwind-protect
         (progn
           (setf shader (%compile-shader :compute-shader source))
           (%observe-compute-resource :created :shader shader)
           (setf program (gl:create-program))
           (when (plusp program) (%observe-compute-resource :created :program program))
           (gl:attach-shader program shader)
           (gl:link-program program)
           (unless (gl:get-program program :link-status)
             (error 'sgeo.geometry-processing:geometry-processing-error
                    :reason (format nil "Falha ao vincular compute shader: ~A"
                                    (gl:get-program-info-log program))))
           (check-opengl-error "vínculo de compute shader")
           (setf complete t)
           program)
      (when shader
        (ignore-errors (gl:delete-shader shader))
        (%observe-compute-resource :deleted :shader shader))
      (unless complete
        (when (plusp program)
          (ignore-errors (gl:delete-program program))
          (%observe-compute-resource :deleted :program program))))))

(defun %set-compute-uniforms (program vertex-count scale translation amplitude frequency phase)
  (gl:use-program program)
  (%gl:uniform-1ui (gl:get-uniform-location program "vertexCount") vertex-count)
  (let ((location (gl:get-uniform-location program "scaleValue")))
    (gl:uniformf location (coerce (aref scale 0) 'single-float)
                 (coerce (aref scale 1) 'single-float)
                 (coerce (aref scale 2) 'single-float)))
  (let ((location (gl:get-uniform-location program "translationValue")))
    (gl:uniformf location (coerce (aref translation 0) 'single-float)
                 (coerce (aref translation 1) 'single-float)
                 (coerce (aref translation 2) 'single-float)))
  (gl:uniformf (gl:get-uniform-location program "waveAmplitude") (coerce amplitude 'single-float))
  (gl:uniformf (gl:get-uniform-location program "waveFrequency") (coerce frequency 'single-float))
  (gl:uniformf (gl:get-uniform-location program "wavePhase") (coerce phase 'single-float)))

(defun %read-float-buffer (count)
  (let ((values (make-array count :element-type 'double-float)))
    (cffi:with-foreign-object (destination :float count)
      (%gl:get-buffer-sub-data #x90d2 0 (* count (cffi:foreign-type-size :float)) destination)
      (dotimes (index count)
        (setf (aref values index) (coerce (cffi:mem-aref destination :float index) 'double-float))))
    values))

(defun %finite-vector3 (value label)
  (unless (and (typep value 'sequence) (= (length value) 3)
               (every (lambda (number)
                        (and (realp number)
                             (let ((single (ignore-errors (coerce number 'single-float))))
                               (and single (= single single)
                                    (< (abs single) most-positive-single-float)))))
                      value))
    (error 'sgeo.geometry-processing:geometry-processing-error
           :reason (format nil "~A precisa conter três valores finitos representáveis em GPU." label)))
  (map 'vector (lambda (number) (coerce number 'double-float)) value))

(defun %finite-scalar (number label)
  (unless (and (realp number)
               (let ((single (ignore-errors (coerce number 'single-float))))
                 (and single (= single single) (< (abs single) most-positive-single-float)))
               (let ((double (ignore-errors (coerce number 'double-float))))
                 (and double (= double double) (< (abs double) most-positive-double-float))))
    (error 'sgeo.geometry-processing:geometry-processing-error
           :reason (format nil "~A precisa ser finita e representável em GPU." label)))
  (coerce number 'double-float))

(defun %triangle-input (geometry)
  (etypecase geometry
    (sgeo.geometry:triangle-mesh
     (values (sgeo.geometry:mesh-positions geometry)
             (sgeo.geometry:mesh-indices geometry) nil))
    (sgeo.geometry:half-edge-mesh
     (let* ((vertices (sgeo.geometry:mesh-vertices geometry))
            (faces (sgeo.geometry:mesh-faces geometry))
            (positions (make-array (* 3 (length vertices)) :element-type 'double-float))
            (indices nil))
       (loop for vertex in vertices for vertex-index from 0
             for point = (sgeo.geometry:vertex-position geometry vertex)
             do (loop for axis below 3
                      do (setf (aref positions (+ (* vertex-index 3) axis))
                               (coerce (aref point axis) 'double-float))))
       (dolist (face faces)
         (dolist (triangle (sgeo.geometry:triangulate-face geometry face))
           (dolist (vertex triangle)
             (let ((index (position vertex vertices :test #'equalp)))
               (unless index
                 (error 'sgeo.geometry-processing:geometry-processing-error
                        :reason "A triangulação retornou um vértice que não pertence ao instantâneo."))
               (push index indices)))))
       (values positions
               (make-array (length indices) :element-type '(unsigned-byte 32)
                           :initial-contents (nreverse indices))
               vertices)))))

(defun %publish-gpu-positions (geometry positions indices vertices)
  (etypecase geometry
    (sgeo.geometry:triangle-mesh
     ;; set-mesh-data valida todos os dados antes de trocar a revisão autoritativa.
     (sgeo.geometry:set-mesh-data geometry positions indices))
    (sgeo.geometry:half-edge-mesh
     (let ((setter (find-symbol "SET-VERTEX-POSITIONS" :sgeo.geometry)))
       (unless (and setter (fboundp setter))
         (error 'sgeo.geometry-processing:geometry-processing-error
                :reason "A publicação atômica de posições em lote ainda não está disponível."))
       (funcall setter geometry
                (loop for vertex in vertices for index from 0
                      collect (cons vertex
                                    (vector (aref positions (* index 3))
                                            (aref positions (+ (* index 3) 1))
                                            (aref positions (+ (* index 3) 2))))))))))

(defun %validate-compute-input (geometry positions indices scale translation amplitude frequency phase)
  (declare (ignore geometry))
  (%finite-vector3 scale "A escala")
  (%finite-vector3 translation "A translação")
  (dolist (number (list amplitude frequency phase))
    (%finite-scalar number "Amplitude, frequência ou fase"))
  (unless (and (plusp (length positions)) (zerop (mod (length positions) 3))
               (plusp (length indices)) (zerop (mod (length indices) 3))
               (every (lambda (index) (< index (/ (length positions) 3))) indices))
    (error 'sgeo.geometry-processing:geometry-processing-error
           :reason "O instantâneo de posições ou índices não é uma malha triangular válida.")))

(defun %validate-gpu-readback (positions normals)
  (unless (and (plusp (length positions)) (= (length positions) (length normals))
               (zerop (mod (length positions) 3))
               (every (lambda (number)
                        (and (realp number) (= number number)
                             (< (abs number) most-positive-double-float)))
                      positions)
               (every (lambda (number)
                        (and (realp number) (= number number)
                             (< (abs number) most-positive-double-float)))
                      normals))
    (error 'sgeo.geometry-processing:geometry-processing-error
           :reason "A leitura de posições ou normais retornou dimensões ou valores não finitos inválidos."))
  (loop for offset from 0 below (length normals) by 3
        for x = (aref normals offset)
        for y = (aref normals (1+ offset))
        for z = (aref normals (+ offset 2))
        for magnitude = (sqrt (+ (* x x) (* y y) (* z z)))
        unless (<= (abs (- magnitude 1d0)) 1d-4)
          do (error 'sgeo.geometry-processing:geometry-processing-error
                    :reason "A leitura GPU contém uma normal não unitária."))
  t)

(defmethod sgeo.geometry-processing:process-geometry
    ((processor (eql :opengl)) geometry &key (scale #(1d0 1d0 1d0))
                                          (translation #(0d0 0d0 0d0))
                                          (amplitude 0d0) (frequency 1d0) (phase 0d0))
  (let ((capabilities (opengl-compute-capabilities)))
    (unless (sgeo.geometry-processing:capabilities-supported-p capabilities)
      (error 'sgeo.geometry-processing:unsupported-compute-error
             :reason (sgeo.geometry-processing:capabilities-reason capabilities))))
  (let* ((scale-data (%finite-vector3 scale "A escala"))
         (translation-data (%finite-vector3 translation "A translação"))
         (amplitude-data (%finite-scalar amplitude "A amplitude"))
         (frequency-data (%finite-scalar frequency "A frequência"))
         (phase-data (%finite-scalar phase "A fase")))
    (let ((snapshot
            (%call-with-geometry-lock
             geometry
             (lambda ()
               (multiple-value-bind (positions indices vertices) (%triangle-input geometry)
                 (list (sgeo.core:object-revision geometry) positions indices vertices))))))
      (destructuring-bind (revision source-positions indices vertices) snapshot
        (%validate-compute-input geometry source-positions indices scale-data translation-data
                                 amplitude-data frequency-data phase-data)
        (let* ((saved-program (%query-integer-state #x8b8d))
               (saved-buffer-binding (%query-integer-state #x90d3))
               (saved-indexed-bindings
                 (loop for index below 3 collect (%query-indexed-integer-state #x90d3 index)))
             (vertex-count (/ (length source-positions) 3))
             (position-input (map 'vector (lambda (value) (coerce value 'single-float)) source-positions))
             (position-buffer 0) (index-buffer 0) (normal-buffer 0)
             (transform-program 0) (normal-program 0)
             (output-positions nil) (output-normals nil))
        (unwind-protect
             (progn
               (setf position-buffer (%gpu-buffer :shader-storage-buffer position-input :float)
                     index-buffer (%gpu-buffer :shader-storage-buffer indices :unsigned-int)
                     normal-buffer (gl:gen-buffer))
               (when (zerop normal-buffer)
                 (error 'sgeo.geometry-processing:geometry-processing-error
                        :reason "O driver não alocou o buffer de normais."))
               (%observe-compute-resource :created :buffer normal-buffer)
               (gl:bind-buffer :shader-storage-buffer normal-buffer)
               (let ((empty-array (%fill-gl-array
                                   :float (make-array (* vertex-count 3)
                                                      :element-type 'single-float
                                                      :initial-element 0.0))))
                 (unwind-protect
                      (gl:buffer-data :shader-storage-buffer :dynamic-copy empty-array)
                   (gl:free-gl-array empty-array)))
               (setf transform-program (%compute-program +geometry-transform-compute-shader+)
                     normal-program (%compute-program +geometry-normal-compute-shader+))
               (%gl:bind-buffer-base #x90d2 0 position-buffer)
               (%set-compute-uniforms transform-program vertex-count scale-data translation-data
                                      amplitude-data frequency-data phase-data)
               (%gl:dispatch-compute (ceiling vertex-count 64) 1 1)
               (%gl:memory-barrier #x2000)
               (%gl:bind-buffer-base #x90d2 0 position-buffer)
               (%gl:bind-buffer-base #x90d2 1 index-buffer)
               (%gl:bind-buffer-base #x90d2 2 normal-buffer)
               (gl:use-program normal-program)
               (%gl:uniform-1ui (gl:get-uniform-location normal-program "vertexCount") vertex-count)
               (%gl:uniform-1ui (gl:get-uniform-location normal-program "indexCount") (length indices))
               (%gl:dispatch-compute (ceiling vertex-count 64) 1 1)
               (%gl:memory-barrier #x2200)
               (gl:bind-buffer :shader-storage-buffer position-buffer)
               (setf output-positions (%read-float-buffer (length source-positions)))
               (gl:bind-buffer :shader-storage-buffer normal-buffer)
               (setf output-normals (%read-float-buffer (* vertex-count 3)))
               (check-opengl-error "leitura do resultado de geometria compute")
               (%validate-gpu-readback output-positions output-normals)
               ;; A publicação e a revisão da cache ficam atômicas em relação a edições concorrentes.
               (%call-with-geometry-lock
                geometry
                (lambda ()
                  (unless (= revision (sgeo.core:object-revision geometry))
                    (error 'sgeo.geometry-processing:geometry-processing-error
                           :reason "A malha mudou durante o processamento; o resultado GPU foi descartado."))
                  (%publish-gpu-positions geometry output-positions indices vertices)
                  (let ((result
                          (sgeo.geometry-processing:make-geometry-processing-result
                           :geometry geometry :source-revision (sgeo.core:object-revision geometry)
                           :positions output-positions :normals output-normals
                           :operation (if (zerop amplitude-data) :transform :deform)
                           :backend :opengl)))
                    (bt:with-lock-held (*opengl-geometry-cache-lock*)
                      (setf (gethash geometry *opengl-geometry-normal-cache*) result))
                    result))))
          (gl:use-program saved-program)
          (loop for index below 3 for buffer in saved-indexed-bindings
                do (%gl:bind-buffer-base #x90d2 index buffer))
          (gl:bind-buffer :shader-storage-buffer saved-buffer-binding)
          (when (plusp transform-program)
            (ignore-errors (gl:delete-program transform-program))
            (%observe-compute-resource :deleted :program transform-program))
          (when (plusp normal-program)
            (ignore-errors (gl:delete-program normal-program))
            (%observe-compute-resource :deleted :program normal-program))
          (let ((buffers (remove 0 (list position-buffer index-buffer normal-buffer))))
            (gl:delete-buffers buffers)
            (dolist (buffer buffers) (%observe-compute-resource :deleted :buffer buffer)))))))))

(defun opengl-process-geometry (geometry &key (scale #(1d0 1d0 1d0))
                                             (translation #(0d0 0d0 0d0))
                                             (amplitude 0d0) (frequency 1d0) (phase 0d0))
  "Processa no dispositivo atual e publica posições após validar a leitura GPU."
  (sgeo.geometry-processing:process-geometry
   :opengl geometry :scale scale :translation translation :amplitude amplitude
   :frequency frequency :phase phase))

(defun opengl-geometry-result-normals (geometry)
  "Retorna normais lidas do dispositivo para a revisão CPU atual, se ainda válidas."
  (let ((result (bt:with-lock-held (*opengl-geometry-cache-lock*)
                  (gethash geometry *opengl-geometry-normal-cache*))))
    (when result
      (%call-with-geometry-lock
       geometry
       (lambda ()
         (when (= (sgeo.geometry-processing:processing-result-source-revision result)
                  (sgeo.core:object-revision geometry))
           (sgeo.geometry-processing:processing-result-normals result)))))))
