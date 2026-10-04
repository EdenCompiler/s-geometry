(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(sgeo.shader:defgpu-function shader-square ((value :float)) (* value value))
(sgeo.shader:defgpu-function shader-mix-scalar-first ((scalar :float) (color :vec3))
  (mix scalar color 0.5))
(sgeo.shader:defgpu-function shader-let-product ((value :float))
  (let* ((square (* value value)) (shifted (+ square 1.0)))
    (* square shifted)))
(sgeo.shader:defgpu-function shader-fresnel ((cos-theta :float) (f0 :vec3))
  (+ f0 (* (- 1.0 cos-theta) (pow (- 1.0 cos-theta) 5.0))))
(sgeo.shader:defgpu-function shader-tinted ((base :vec3) (tint :vec3))
  (let* ((weight (max 0.25 0.75))
         (blend (mix base tint weight)))
    (clamp blend 0.0 1.0)))
(sgeo.shader:defgpu-function shader-triple-product ((base :vec3) (a :float) (b :float))
  (* base a b))
(sgeo.shader:defshader :fragment shader-language-macro-check
    ((uv :vec2 :location 0))
  (:color (vec4 (swizzle uv :xy) 0.0 1.0)))

(test shader-lisp-produces-typed-ast-and-sgir
  (let* ((definition
           (sgeo.shader:compile-shader-form
            'typed-shadow-vertex :vertex
            '((position :vec3 :location 0)
              (normal :vec3 :location 1)
              (uv :vec2 :location 2)
              (frame (:struct (:model :mat4) (:normal-matrix :mat4)
                              (:view-projection :mat4) (:light-view-projection :mat4))
                     :uniform :binding 0 :std140))
            '((values
               (:position (* (field frame view-projection)
                             (* (field frame model) (vec4 position 1.0))))
               (:world-normal (swizzle (* (field frame normal-matrix) (vec4 normal 0.0)) xyz))
               (:uv uv)))))
         (module (sgeo.shader:shader-definition-sgir definition))
         (interfaces (sgeo.shader:sgir-module-interfaces module)))
    (is (eq :vertex (sgeo.shader:shader-definition-stage definition)))
    (is (equal '((position :vec3 :location 0)
                 (normal :vec3 :location 1)
                 (uv :vec2 :location 2)
                 (frame (:struct (:model :mat4) (:normal-matrix :mat4)
                                 (:view-projection :mat4) (:light-view-projection :mat4))
                        :uniform :binding 0 :std140))
               (sgeo.shader:shader-definition-declarations definition)))
    (is (eq :position (sgeo.shader:shader-output-name (first (sgeo.shader:shader-definition-outputs definition)))))
    (is (equal '(:struct frame ((:model (:matrix 4 4)) (:normal-matrix (:matrix 4 4))
                                 (:view-projection (:matrix 4 4)) (:light-view-projection (:matrix 4 4))))
               (sgeo.shader:shader-parameter-type
                (fourth (sgeo.shader:shader-definition-parameters definition)))))
    (is (equal '(:block :std140 :member-offsets ((:model 0) (:normal-matrix 64)
                                                (:view-projection 128) (:light-view-projection 192)))
               (sgeo.shader:sgir-interface-decorations (fourth interfaces))))
    (is (null (sgeo.shader:sgir-function-parameters
               (first (sgeo.shader:sgir-module-functions module)))))
    (is (member :matrix-times-vector
                  (mapcar #'sgeo.shader:sgir-instruction-opcode
                          (sgeo.shader:sgir-block-instructions
                           (first (sgeo.shader:sgir-function-blocks
                                   (first (sgeo.shader:sgir-module-functions module))))))))
    (is (stringp (sgeo.shader:emit-glsl definition)))))

(test shader-lisp-fragment-samples-texture-and-links-varyings
  (let* ((vertex (sgeo.shader:compile-shader-form
                  'link-vertex :vertex
                  '((position :vec3 :location 0) (uv :vec2 :location 1))
                  '((values (:position (vec4 position 1.0)) (:uv uv)))))
         (fragment (sgeo.shader:compile-shader-form
                    'link-fragment :fragment
                    '((uv :vec2 :location 0) (albedo :sampler2d :uniform :binding 1))
                    '((let ((sample (texture albedo uv)))
                        (values (:color (* sample (vec4 (max 0.05 1.0) 1.0 1.0 1.0)))))))))
    (is (sgeo.shader:link-shaders vertex fragment))
    (is (equal '(:sampled-image (:image :2d :float))
               (sgeo.shader:shader-parameter-type (second (sgeo.shader:shader-definition-parameters fragment)))))
    (is (find :texture-sample
              (mapcar #'sgeo.shader:sgir-instruction-opcode
                      (sgeo.shader:sgir-block-instructions
                       (first (sgeo.shader:sgir-function-blocks
                               (first (sgeo.shader:sgir-module-functions
                                       (sgeo.shader:shader-definition-sgir fragment)))))))))))

(test shader-lisp-rejects-type-and-interface-errors
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form 'missing-location :vertex
                                     '((position :vec3)) '((:position (vec4 position 1.0)))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form 'missing-binding :fragment
                                     '((albedo :sampler2d :uniform)) '((:color (texture albedo (vec2 0.0 0.0))))))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form 'bad-add :fragment
                                     '((position :vec3 :location 0)) '((:color (+ position :bad)))))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form 'bad-swizzle :fragment
                                     '((position :vec3 :location 0)) '((:color (vec4 (swizzle position w) 1.0 1.0 1.0)))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form 'wrong-position-stage :fragment
                                     '((uv :vec2 :location 0)) '((:position (vec4 uv 0.0 1.0)) (:color (vec4 1.0))))))

(test shader-lisp-compiles-shared-gpu-functions
  (let* ((definition (sgeo.shader:compile-shader-form
                      'helper-fragment :fragment
                      '((uv :vec2 :location 0))
                      '((:color (vec4 (shader-square 0.5) 0.0 0.0 1.0)))))
         (functions (sgeo.shader:sgir-module-functions (sgeo.shader:shader-definition-sgir definition)))
         (helper (find 'shader-square functions :key #'sgeo.shader:sgir-function-name)))
    (is (not (null helper)))
    (is (equal '(:vector :float 4)
               (sgeo.shader:shader-output-type (first (sgeo.shader:shader-definition-outputs definition)))))
    (is (find :call (mapcar #'sgeo.shader:sgir-instruction-opcode
                            (sgeo.shader:sgir-block-instructions
                             (first (sgeo.shader:sgir-function-blocks
                                     (first functions)))))))
    (let* ((let-function (find 'shader-let-product functions :key #'sgeo.shader:sgir-function-name))
           (instructions (sgeo.shader:sgir-block-instructions
                          (first (sgeo.shader:sgir-function-blocks let-function))))
           (arithmetic (remove-if-not (lambda (instruction)
                                        (member (sgeo.shader:sgir-instruction-opcode instruction)
                                                '(:fmul :fadd))) instructions)))
      (is (and arithmetic
               (every (lambda (instruction)
                        (and (sgeo.shader:sgir-instruction-result instruction)
                             (every #'integerp (sgeo.shader:sgir-instruction-operands instruction))))
                      arithmetic))))))

(test shader-lisp-defshader-registers-inspectable-source
  (let ((definition (sgeo.shader:shader-definition-by-name 'shader-language-macro-check)))
    (is (not (null definition)))
    (is (equal '((:color (vec4 (swizzle uv :xy) 0.0 1.0)))
               (sgeo.shader:shader-definition-source definition)))))

(test shader-lisp-evaluates-shared-vector-math-on-cpu
  (let ((fresnel (shader-fresnel 0.5 '(0.04 0.04 0.04)))
        (tinted (shader-tinted '(0.0 0.2 0.4) '(1.0 0.8 0.6))))
    (is (vector-approximately= '(0.055625 0.055625 0.055625) fresnel 1d-6))
    (is (vector-approximately= '(0.75 0.65 0.55) tinted 1d-6))
    (is (approximately= 0.25 (shader-square 0.5)))
    (is (approximately= 0.3125 (shader-let-product 0.5)))
    (is (vector-approximately= '(0.6 0.7 0.8)
                               (shader-mix-scalar-first 0.2 '(1.0 1.2 1.4)) 1d-6))
    (is (vector-approximately= '(0.1 0.2 0.3) (shader-triple-product '(1.0 2.0 3.0) 0.5 0.2) 1d-6))))

(test shader-lisp-lowers-matrix-vector-and-variadic-arithmetic
  (let* ((definition (sgeo.shader:compile-shader-form
                      'matrix-product-vertex :vertex
                      '((position :vec3 :location 0) (transform :mat4 :uniform :binding 0))
                      '((:position (* transform (vec4 position 1.0) 2.0)))))
         (instructions (sgeo.shader:sgir-block-instructions
                        (first (sgeo.shader:sgir-function-blocks
                                (first (sgeo.shader:sgir-module-functions
                                        (sgeo.shader:shader-definition-sgir definition)))))))
         (opcodes (mapcar #'sgeo.shader:sgir-instruction-opcode instructions)))
    (is (member :matrix-times-vector opcodes))
    (is (member :fmul opcodes))
    (is (equal '(:vector :float 4)
               (sgeo.shader:shader-output-type (first (sgeo.shader:shader-definition-outputs definition)))))))

(test shader-lisp-validates-matrix-operators-and-vector-constructors
  (is (typep (sgeo.shader:compile-shader-form
              'valid-vector-assembly :vertex
              '((position :vec3 :location 0))
              '((:position (vec4 position 1.0))))
             'sgeo.shader:shader-definition))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form
     'invalid-vector-width :fragment '((uv :vec2 :location 0))
     '((:color (vec4 (vec3 uv) 1.0)))))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form
     'matrix-add-is-unsupported :vertex '((transform :mat4 :uniform :binding 0))
     '((:position (+ transform transform)))))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form
     'matrix-divide-is-unsupported :vertex '((transform :mat4 :uniform :binding 0))
     '((:position (/ transform 2.0)))))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form
     'matrix-negate-is-unsupported :vertex '((transform :mat4 :uniform :binding 0))
     '((:position (- transform)))))
  (signals sgeo.shader:shader-type-error
    (sgeo.shader:compile-shader-form
     'matrix-vector-comparison-is-unsupported :fragment '((value :vec4 :location 0))
     '((:color (if (= value value) value value))))))

(test shader-lisp-validates-stage-interfaces-and-descriptors
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'negative-descriptor-binding :fragment '((image :sampler2d :uniform :binding -1))
     '((:color (texture image (vec2 0.0 0.0))))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'negative-descriptor-set :fragment '((image :sampler2d :uniform :set -1 :binding 0))
     '((:color (texture image (vec2 0.0 0.0))))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'duplicate-descriptor-binding :fragment
     '((first-image :sampler2d :uniform :binding 0)
       (second-image :sampler2d :uniform :binding 0))
     '((:color (texture first-image (vec2 0.0 0.0))))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'duplicate-stage-input-location :vertex
     '((position :vec3 :location 0) (normal :vec3 :location 0))
     '((:position (vec4 position 1.0)))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'non-vec4-position :vertex '((position :vec3 :location 0))
     '((:position (vec3 0.0 0.0 0.0)))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'non-vec4-fragment-color :fragment '((uv :vec2 :location 0))
     '((:color (vec3 1.0 0.0 0.0)))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'duplicate-output-location :fragment nil
     '((values (:aux (vec4 0.0 0.0 0.0 1.0))
               (:color (vec4 1.0 1.0 1.0 1.0))))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'compute-stage-is-explicitly-unsupported :compute nil '((:value 1.0)))))

(test shader-lisp-links-shared-descriptors-by-type-and-layout
  (let* ((vertex (sgeo.shader:compile-shader-form
                  'shared-block-vertex :vertex
                  '((position :vec3 :location 0)
                    (frame (:struct (:model :mat4) (:color :vec4))
                     :uniform :binding 0 :std140))
                  '((values (:position (vec4 position 1.0)) (:uv (vec2 0.0 0.0))))))
         (matching-fragment (sgeo.shader:compile-shader-form
                             'shared-block-fragment :fragment
                             '((uv :vec2 :location 0)
                               (frame (:struct (:model :mat4) (:color :vec4))
                                :uniform :binding 0 :std140))
                             '((:color (vec4 1.0 1.0 1.0 1.0)))))
         (mismatched-fragment (sgeo.shader:compile-shader-form
                               'mismatched-block-fragment :fragment
                               '((uv :vec2 :location 0)
                                 (frame (:struct (:model :mat3) (:color :vec4))
                                  :uniform :binding 0 :std140))
                               '((:color (vec4 1.0 1.0 1.0 1.0))))))
    (is (sgeo.shader:link-shaders vertex matching-fragment))
    (signals sgeo.shader:shader-interface-error
      (sgeo.shader:link-shaders vertex mismatched-fragment))))
