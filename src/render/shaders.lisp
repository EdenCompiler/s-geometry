(in-package #:sgeo.render)

(eval-when (:compile-toplevel :load-toplevel :execute)
 (defparameter *frame-declaration*
  '(frame (:struct (:model :mat4) (:normal-matrix :mat4) (:view-projection :mat4)
                   (:light-view-projection :mat4) (:camera-eye :vec4)
                   (:light-direction :vec4) (:light-color :vec4) (:base-color :vec4)
                   (:material :vec4) (:emissive :vec4) (:environment :vec4) (:tone :vec4))
          :uniform :set 0 :binding 0 :std140)))

(defmacro %frame-shader (stage name inputs &body body)
  "Compartilha a interface std140 entre os passes sem duplicar GLSL."
  `(sgeo.shader:defshader ,stage ,name (,@inputs ,*frame-declaration*) ,@body))

(sgeo.shader:defgpu-function fresnel-schlick ((cos-theta :float) (f0 :vec3))
  (+ f0 (* (- 1.0 f0) (pow (- 1.0 cos-theta) 5.0))))

(sgeo.shader:defgpu-function %ggx-distribution ((nh :float) (roughness :float))
  (let* ((a (* roughness roughness)) (a2 (* a a))
         (d (+ (* nh nh (- a2 1.0)) 1.0)))
    (/ a2 (max (* 3.14159265 d d) 0.00001))))

(sgeo.shader:defgpu-function %smith-geometry ((nv :float) (nl :float) (roughness :float))
  (let* ((r (+ roughness 1.0)) (k (/ (* r r) 8.0)))
    (* (/ nv (+ (* nv (- 1.0 k)) k))
       (/ nl (+ (* nl (- 1.0 k)) k)))))

(%frame-shader :vertex pbr-vertex
  ((position :vec3 :location 0) (normal :vec3 :location 1))
  (let ((world (* (field frame model) (vec4 position 1.0))))
    (values (:position (* (field frame view-projection) world))
            (:world-position (swizzle world xyz))
            (:world-normal (normalize (swizzle (* (field frame normal-matrix) (vec4 normal 0.0)) xyz)))
            (:shadow-clip (* (field frame light-view-projection) world)))))

(%frame-shader :vertex shadow-vertex ((position :vec3 :location 0))
  (:position (* (field frame light-view-projection) (field frame model) (vec4 position 1.0))))

(%frame-shader :fragment pbr-fragment
  ((world-position :vec3 :location 0) (world-normal :vec3 :location 1)
   (shadow-clip :vec4 :location 2) (shadow-map :sampler2d :uniform :set 0 :binding 1))
  (let* ((base (swizzle (field frame base-color) xyz))
         (metal (swizzle (field frame material) x))
         (rough (max (swizzle (field frame material) y) 0.04))
         (ao (swizzle (field frame material) z))
         (n (normalize world-normal))
         (v (normalize (- (swizzle (field frame camera-eye) xyz) world-position)))
         (l (normalize (swizzle (field frame light-direction) xyz)))
         (h (normalize (+ v l)))
         (nv (max (dot n v) 0.0001)) (nl (max (dot n l) 0.0))
         (nh (max (dot n h) 0.0)) (hv (max (dot h v) 0.0))
         (f0 (mix (vec3 0.04) base metal))
         (f (fresnel-schlick hv f0))
         (d (%ggx-distribution nh rough))
         (g (%smith-geometry nv nl rough))
         (spec (/ (* f d g) (max (* 4.0 nv nl) 0.0001)))
         (diffuse (/ (* (- 1.0 f) (- 1.0 metal) base) 3.14159265))
         (sc (/ (swizzle shadow-clip xyz) (swizzle shadow-clip w)))
         (uv (+ (* (swizzle sc xy) 0.5) (vec2 0.5)))
         (bias (swizzle (field frame tone) y))
         (step (swizzle (field frame tone) z))
         (depth (- (swizzle sc z) bias))
         (s0 (if (<= depth (swizzle (texture shadow-map (+ uv (vec2 (- step) (- step)))) x)) 1.0 0.0))
         (s1 (if (<= depth (swizzle (texture shadow-map (+ uv (vec2 step (- step)))) x)) 1.0 0.0))
         (s2 (if (<= depth (swizzle (texture shadow-map (+ uv (vec2 (- step) step))) x)) 1.0 0.0))
         (s3 (if (<= depth (swizzle (texture shadow-map (+ uv (vec2 step step))) x)) 1.0 0.0))
         (visibility (* (+ s0 s1 s2 s3) 0.25))
         (inside (* (if (< (swizzle uv x) 0.0) 0.0 1.0)
                    (if (> (swizzle uv x) 1.0) 0.0 1.0)
                    (if (< (swizzle uv y) 0.0) 0.0 1.0)
                    (if (> (swizzle uv y) 1.0) 0.0 1.0)
                    (if (< (swizzle sc z) 0.0) 0.0 1.0)
                    (if (> (swizzle sc z) 1.0) 0.0 1.0)))
         (shadow (mix 1.0 visibility (* inside (swizzle (field frame material) w))))
         (radiance (* (swizzle (field frame light-color) xyz)
                      (swizzle (field frame light-direction) w)))
         (direct (* (+ diffuse spec) radiance nl shadow))
         (ambient (* base (- 1.0 metal) (swizzle (field frame environment) xyz)
                     (swizzle (field frame environment) w) ao))
         (color (+ direct ambient (swizzle (field frame emissive) xyz))))
    (:color (vec4 color (swizzle (field frame base-color) w)))))

(sgeo.shader:defshader :vertex tone-vertex ((position :vec2 :location 0))
  (values (:position (vec4 position 0.0 1.0)) (:uv (+ (* position 0.5) (vec2 0.5)))))

(%frame-shader :fragment tone-fragment
  ((uv :vec2 :location 0) (hdr-map :sampler2d :uniform :set 0 :binding 1))
  (let* ((hdr (* (swizzle (texture hdr-map uv) xyz) (swizzle (field frame tone) x)))
         (mapped (/ hdr (+ hdr (vec3 1.0))))
         (display (pow (max mapped (vec3 0.0)) (vec3 0.45454545))))
    (:color (vec4 display 1.0))))

(defun standard-shader-sources (&optional (kind :pbr))
  "Captura as definições atuais para recompilação assíncrona consistente."
  (ecase kind
    (:pbr (list :vertex (sgeo.shader:shader-definition-by-name 'pbr-vertex)
                :fragment (sgeo.shader:shader-definition-by-name 'pbr-fragment)))
    (:shadow (list :vertex (sgeo.shader:shader-definition-by-name 'shadow-vertex)))
    (:tone (list :vertex (sgeo.shader:shader-definition-by-name 'tone-vertex)
                 :fragment (sgeo.shader:shader-definition-by-name 'tone-fragment)))))

(defun %graphics-definition (source)
  (etypecase source
    (sgeo.shader:shader-definition
     (sgeo.shader:compile-shader-form
      (sgeo.shader:shader-definition-name source) (sgeo.shader:shader-definition-stage source)
      (sgeo.shader:shader-definition-declarations source) (sgeo.shader:shader-definition-source source)))
    (symbol (%graphics-definition (or (sgeo.shader:shader-definition-by-name source)
                                     (error "Shader desconhecido: ~S." source))))
    (list (destructuring-bind (stage name declarations &rest body) source
            (sgeo.shader:compile-shader-form name stage declarations body)))))

(defun compile-graphics-program (source)
  "Compila estágios SGL e devolve octetos SPIR-V com reflexão das interfaces."
  (let* ((vertex (%graphics-definition (getf source :vertex)))
         (fragment (and (getf source :fragment) (%graphics-definition (getf source :fragment)))))
    (unless (eq (sgeo.shader:shader-definition-stage vertex) :vertex)
      (error "O estágio de vértice é inválido."))
    (when fragment (sgeo.shader:link-shaders vertex fragment))
    (multiple-value-bind (vertex-code vertex-meta) (sgeo.shader:compile-shader-to-spirv vertex)
      (multiple-value-bind (fragment-code fragment-meta)
          (if fragment (sgeo.shader:compile-shader-to-spirv fragment) (values nil nil))
        (list :vertex vertex-code :fragment fragment-code :vertex-metadata vertex-meta
              :fragment-metadata fragment-meta :vertex-definition vertex :fragment-definition fragment)))))
