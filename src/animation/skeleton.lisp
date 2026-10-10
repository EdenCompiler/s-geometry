(in-package #:sgeo.animation)

(defclass skeleton ()
  ((name :initarg :name :reader %skeleton-name)
   (joints :initarg :joints :reader %skeleton-joints)
   (inverse-bind-matrices :initarg :inverse-bind-matrices
                          :reader %skeleton-inverse-bind-matrices)
   (root :initarg :root :reader %skeleton-root))
  (:documentation "Esqueleto vivo com nós de articulação e matrizes de vínculo."))

(defun %skeleton-finite-real-p (value)
  (and (realp value)
       (handler-case (<= (abs value) most-positive-double-float)
         (error () nil))))

(defun %copy-mat4 (matrix context)
  (unless (and (typep matrix 'array) (= (array-rank matrix) 1)
               (= (length matrix) 16)
               (loop for value across matrix always (%skeleton-finite-real-p value)))
    (error 'sgeo.core:validation-error :context context
           :message "A matriz precisa conter 16 valores reais e finitos."))
  (sgeo.math:make-mat4 matrix))

(defun %skeleton-sequence-vector (value context)
  (handler-case
      (if (typep value 'sequence)
          (coerce value 'vector)
          (error 'type-error))
    (error ()
      (error 'sgeo.core:validation-error :context context
             :message "O valor precisa ser uma sequência válida."))))

(defun skeleton-joints (skeleton)
  "Retorna uma cópia do vetor de articulações vivas do esqueleto."
  (copy-seq (%skeleton-joints skeleton)))
(defun skeleton-inverse-bind-matrices (skeleton)
  "Retorna cópias das matrizes de vínculo inverso."
  (map 'vector #'copy-seq (%skeleton-inverse-bind-matrices skeleton)))
(defun skeleton-root (skeleton) (%skeleton-root skeleton))

(defun make-skeleton (&key (name "Esqueleto") joints inverse-bind-matrices root)
  "Cria esqueleto e copia/valida os nós e as matrizes de vínculo inverso."
  (let* ((joint-vector (%skeleton-sequence-vector joints "articulações do esqueleto"))
         (count (length joint-vector)))
    (unless (and (plusp count)
                 (every (lambda (joint) (typep joint 'sgeo.scene:scene-object)) joint-vector))
      (error 'sgeo.core:validation-error :context "articulações do esqueleto"
             :message "O esqueleto precisa conter nós de cena válidos."))
    (let ((matrices (if inverse-bind-matrices
                        (%skeleton-sequence-vector inverse-bind-matrices "matrizes de vínculo inverso")
                        (make-array count :initial-element (sgeo.math:identity-mat4)))))
      (unless (= (length matrices) count)
        (error 'sgeo.core:validation-error :context "matrizes de vínculo inverso"
               :message "É necessária uma matriz para cada articulação."))
      (setf matrices (map 'vector (lambda (matrix) (%copy-mat4 matrix "matriz de vínculo inverso")) matrices))
      (unless (or (null root) (typep root 'sgeo.scene:scene-object))
        (error 'sgeo.core:validation-error :context "raiz do esqueleto"
               :message "A raiz precisa ser um nó de cena."))
      (make-instance 'skeleton :name name :joints (copy-seq joint-vector)
                     :inverse-bind-matrices matrices
                     :root (or root (aref joint-vector 0))))))

(defun joint-palette (skeleton &optional mesh-object)
  "Calcula matrizes para deformação local; sem malha usa o espaço mundial."
  (let* ((joints (%skeleton-joints skeleton))
         (binds (%skeleton-inverse-bind-matrices skeleton))
         (mesh-inverse (if mesh-object
                           (sgeo.math:inverse-mat4 (sgeo.scene:world-transform mesh-object))
                           (sgeo.math:identity-mat4))))
    (map 'vector (lambda (joint bind)
                   (sgeo.math:mat* mesh-inverse
                     (sgeo.math:mat* (sgeo.scene:world-transform joint) bind)))
         joints binds)))

(defclass morph-target ()
  ((positions :initarg :positions :reader %morph-target-positions)
   (normals :initarg :normals :reader %morph-target-normals))
  (:documentation "Deslocamentos planos de posição e, opcionalmente, normal."))

(defun morph-target-positions (target) (copy-seq (%morph-target-positions target)))
(defun morph-target-normals (target)
  (when (%morph-target-normals target) (copy-seq (%morph-target-normals target))))

(defun %numeric-flat-vector (values context &optional required-length)
  (let ((sequence (%skeleton-sequence-vector values context)))
    (unless (and (or (null required-length) (= (length sequence) required-length))
                 (loop for value across sequence always (%skeleton-finite-real-p value)))
      (error 'sgeo.core:validation-error :context context
             :message "Os dados precisam ter o tamanho esperado e conter apenas números finitos."))
    (make-array (length sequence) :element-type 'double-float
                :initial-contents (loop for value across sequence collect (coerce value 'double-float)))))

(defun make-morph-target (&key positions normals)
  "Cria alvo morfológico com deslocamentos planos de vec3."
  (let ((positions (%numeric-flat-vector positions "deslocamentos de posição")))
    (unless (and (plusp (length positions)) (zerop (mod (length positions) 3)))
      (error 'sgeo.core:validation-error :context "deslocamentos de posição"
             :message "Os deslocamentos precisam conter três componentes por vértice."))
    (let ((normals (when normals (%numeric-flat-vector normals "deslocamentos de normal" (length positions)))))
      (make-instance 'morph-target :positions positions :normals normals))))

(defclass deformable-mesh-object (sgeo.scene:mesh-object)
  ((skeleton :initarg :skeleton :reader mesh-skeleton)
   (joint-indices :initarg :joint-indices :reader %mesh-joint-indices)
   (joint-weights :initarg :joint-weights :reader %mesh-joint-weights)
   (morph-targets :initarg :morph-targets :reader %mesh-morph-targets)
   (morph-weights :initarg :morph-weights :accessor %mesh-morph-weights)
   (deformation-lock :initform (bt:make-recursive-lock "sgeo deformable mesh") :reader %deformation-lock)
   (cached-key :initform nil :accessor %deformed-cache-key)
   (cached-data :initform nil :accessor %deformed-cache-data)
   (deformation-revision :initform 0 :accessor %deformation-revision))
  (:documentation "Malha que deriva dados deformados sem alterar sua geometria-fonte."))

(defun mesh-joint-indices (object)
  "Retorna cópia profunda dos índices de articulação por vértice."
  (map 'vector #'copy-seq (%mesh-joint-indices object)))
(defun mesh-joint-weights (object)
  "Retorna cópia profunda dos pesos por vértice."
  (map 'vector #'copy-seq (%mesh-joint-weights object)))
(defun mesh-morph-targets (object)
  "Retorna cópia do vetor de alvos morfológicos."
  (copy-seq (%mesh-morph-targets object)))
(defun mesh-morph-weights (object) (copy-seq (%mesh-morph-weights object)))

(defun %vertex-influence-data (values vertex-count joint-count context
                               &key (allow-empty-p nil))
  (setf values (%skeleton-sequence-vector values (if (eq context :indices)
                                                     "índices de articulação"
                                                     "pesos de articulação")))
  (unless (= (length values) vertex-count)
    (error 'sgeo.core:validation-error :context context
           :message "É necessário um vetor de influências por vértice."))
  (map 'vector
       (lambda (influences)
         (let ((items (%skeleton-sequence-vector influences
                                                  (if (eq context :indices)
                                                      "índices de articulação"
                                                      "pesos de articulação"))))
           (unless (or allow-empty-p (plusp (length items)))
             (error 'sgeo.core:validation-error :context context
                    :message "Cada vértice precisa de ao menos uma influência."))
           (map 'vector
                (lambda (value)
                  (if (eq context :indices)
                      (progn
                        (unless (and (integerp value) (<= 0 value) (< value joint-count))
                          (error 'sgeo.core:validation-error :context "índices de articulação"
                                 :message "Um índice de articulação está fora do esqueleto."))
                        value)
                      (progn
                        (unless (and (%skeleton-finite-real-p value) (not (minusp value)))
                          (error 'sgeo.core:validation-error :context "pesos de articulação"
                                 :message "Os pesos precisam ser números finitos não negativos."))
                        (coerce value 'double-float)))) items))) values))

(defun make-deformable-mesh-object (&key (name "Malha deformável") geometry material skeleton
                                        joint-indices joint-weights morph-targets morph-weights
                                        position rotation scale local-transform (visible-p t) (enabled-p t))
  "Cria malha com skinning por CPU e alvos morfológicos."
  (unless (and geometry (or (null skeleton) (typep skeleton 'skeleton)))
    (error 'sgeo.core:validation-error :context "malha deformável"
           :message "A geometria é obrigatória e o esqueleto, quando informado, precisa ser válido."))
  (unless (typep geometry '(or sgeo.geometry:triangle-mesh sgeo.geometry:half-edge-mesh))
    (error 'sgeo.core:validation-error :context "geometria deformável"
           :message "A geometria precisa ser uma malha suportada."))
  (let* ((base (sgeo.core:compile-render-data geometry))
         (vertex-count (/ (length (sgeo.geometry:render-mesh-positions base)) 3))
         (targets (%skeleton-sequence-vector morph-targets "alvos morfológicos"))
         (weights (if morph-weights (%skeleton-sequence-vector morph-weights "pesos morfológicos")
                      (make-array (length targets) :initial-element 0d0))))
    (unless (and (= (length targets) (length weights))
                 (every (lambda (target) (typep target 'morph-target)) targets))
      (error 'sgeo.core:validation-error :context "alvos morfológicos"
             :message "Cada alvo morfológico precisa ter um peso correspondente."))
    (dolist (target (coerce targets 'list))
      (unless (= (length (%morph-target-positions target)) (* 3 vertex-count))
        (error 'sgeo.core:validation-error :context "alvo morfológico"
               :message "O alvo precisa corresponder aos vértices da malha-base.")))
    (unless (every #'%skeleton-finite-real-p weights)
      (error 'sgeo.core:validation-error :context "pesos morfológicos"
             :message "Os pesos morfológicos precisam ser finitos."))
    (let* ((joint-count (if skeleton (length (%skeleton-joints skeleton)) 0))
           (indices (%vertex-influence-data (or joint-indices
                                                (make-array vertex-count
                                                  :initial-element (if skeleton #(0) #())))
                                            vertex-count joint-count :indices
                                            :allow-empty-p (null skeleton)))
           (influences (%vertex-influence-data (or joint-weights
                                                   (make-array vertex-count
                                                     :initial-element (if skeleton #(1d0) #())))
                                               vertex-count joint-count :weights
                                               :allow-empty-p (null skeleton))))
      (unless (loop for i below vertex-count always (= (length (aref indices i))
                                                        (length (aref influences i))))
        (error 'sgeo.core:validation-error :context "influências de skinning"
               :message "Os vetores de índices e pesos precisam ter o mesmo tamanho por vértice."))
      (when (and (null skeleton)
                 (or (some (lambda (row) (plusp (length row))) indices)
                     (some (lambda (row) (plusp (length row))) influences)))
        (error 'sgeo.core:validation-error :context "influências de skinning"
               :message "Influências de articulação exigem um esqueleto."))
      (let ((object (make-instance 'deformable-mesh-object :name name :geometry geometry
                                   :material (or material (sgeo.scene:make-material))
                                   :local-transform (or local-transform (sgeo.math:make-transform))
                                   :visible-p visible-p :enabled-p enabled-p
                                   :skeleton skeleton :joint-indices indices
                                   :joint-weights influences :morph-targets (copy-seq targets)
                                   :morph-weights (map 'vector (lambda (weight) (coerce weight 'double-float)) weights))))
        (when position (sgeo.scene:set-position object position))
        (when rotation (sgeo.scene:set-rotation object rotation))
        (when scale (sgeo.scene:set-scale object scale))
        object))))

(defun set-morph-weights (object weights)
  "Define todos os pesos morfológicos após validar quantidade e valores finitos."
  (let ((copy (%numeric-flat-vector weights "pesos morfológicos"
                                   (length (mesh-morph-targets object))))
        (world (sgeo.scene:scene-object-world object)))
    (flet ((change ()
             (bt:with-recursive-lock-held ((%deformation-lock object))
               (unless (equalp copy (%mesh-morph-weights object))
                 (setf (%mesh-morph-weights object) copy
                       (%deformed-cache-key object) nil)
                 (sgeo.core:touch-object object :morph-weights-changed)))))
      (if world (sgeo.scene:with-world-lock (world) (change)) (change)))
    object))

(defun %mat3-normal (matrix normal)
  "Aplica a inversa-transposta da parte linear de MATRIX a NORMAL."
  (let* ((a (aref matrix 0)) (b (aref matrix 4)) (c (aref matrix 8))
         (d (aref matrix 1)) (e (aref matrix 5)) (f (aref matrix 9))
         (g (aref matrix 2)) (h (aref matrix 6)) (i (aref matrix 10))
         (c00 (- (* e i) (* f h))) (c01 (- (* f g) (* d i)))
         (c02 (- (* d h) (* e g))) (c10 (- (* c h) (* b i)))
         (c11 (- (* a i) (* c g))) (c12 (- (* b g) (* a h)))
         (c20 (- (* b f) (* c e))) (c21 (- (* c d) (* a f)))
         (c22 (- (* a e) (* b d)))
         (det (+ (* a c00) (* b c01) (* c c02))))
    (when (<= (abs det) 1d-15)
      (error 'sgeo.core:validation-error :context "normais de skinning"
             :message "Uma transformação de articulação singular não pode deformar normais."))
    ;; Cofatores divididos pelo determinante formam a inversa-transposta.
    (sgeo.math:make-vec3
     (/ (+ (* c00 (sgeo.math:vx normal)) (* c01 (sgeo.math:vy normal)) (* c02 (sgeo.math:vz normal))) det)
     (/ (+ (* c10 (sgeo.math:vx normal)) (* c11 (sgeo.math:vy normal)) (* c12 (sgeo.math:vz normal))) det)
     (/ (+ (* c20 (sgeo.math:vx normal)) (* c21 (sgeo.math:vy normal)) (* c22 (sgeo.math:vz normal))) det))))

(defun %flat-vec3 (values index)
  (let ((offset (* 3 index)))
    (sgeo.math:make-vec3 (aref values offset) (aref values (1+ offset)) (aref values (+ offset 2)))))

(defun %deform-key (object base)
  (list (sgeo.core:object-revision (sgeo.scene:mesh-object-geometry object))
        (copy-seq (%mesh-morph-weights object))
        (copy-seq (sgeo.scene:world-transform object))
        (if (mesh-skeleton object)
            (map 'vector (lambda (joint) (copy-seq (sgeo.scene:world-transform joint)))
                 (%skeleton-joints (mesh-skeleton object)))
            #())
        (sgeo.geometry:render-mesh-revision base)))

(defun %deform-render-data-locked (object)
  (let* ((base (sgeo.core:compile-render-data
                (sgeo.scene:mesh-object-geometry object)))
         (key (%deform-key object base)))
    (if (equalp key (%deformed-cache-key object))
        (%deformed-cache-data object)
        (let* ((base-positions (sgeo.geometry:render-mesh-positions base))
               (base-normals (sgeo.geometry:render-mesh-normals base))
               (vertex-count (/ (length base-positions) 3))
               (positions (copy-seq base-positions))
               (normals (copy-seq base-normals))
               (targets (%mesh-morph-targets object))
               (weights (%mesh-morph-weights object))
               (palette (when (mesh-skeleton object)
                          (joint-palette (mesh-skeleton object) object))))
          (unless (and (= vertex-count (length (%mesh-joint-indices object)))
                       (= vertex-count (length (%mesh-joint-weights object)))
                       (every (lambda (target)
                                (= (length (%morph-target-positions target))
                                   (length base-positions)))
                              targets))
            (error 'sgeo.core:validation-error :context "dados de deformação"
                   :message "A geometria foi alterada para uma topologia incompatível com skinning ou morph."))
          ;; Morphs são somados à malha-base antes do skinning.
          (loop for target across targets for weight across weights
                unless (zerop weight)
                  do (let ((deltas (%morph-target-positions target))
                           (normal-deltas (%morph-target-normals target)))
                       (dotimes (i (length positions))
                         (incf (aref positions i) (* weight (aref deltas i))))
                       (when normal-deltas
                         (dotimes (i (length normals))
                           (incf (aref normals i) (* weight (aref normal-deltas i)))))))
          ;; Normaliza também morphs sem skin e vértices de skinning sem pesos.
          (dotimes (vertex vertex-count)
            (let* ((offset (* 3 vertex))
                   (normal (%flat-vec3 normals vertex))
                   (length (sgeo.math:vector-length normal)))
              (when (> length 1d-15)
                (dotimes (component 3)
                  (setf (aref normals (+ offset component))
                        (/ (aref normal component) length))))))
          (when palette
           (dotimes (vertex vertex-count)
            (let* ((p (%flat-vec3 positions vertex))
                   (n (%flat-vec3 normals vertex))
                   (out-p (sgeo.math:make-vec3))
                   (out-n (sgeo.math:make-vec3))
                   (indices (aref (%mesh-joint-indices object) vertex))
                   (influences (aref (%mesh-joint-weights object) vertex))
                   (largest (reduce #'max influences :initial-value 0d0)))
              ;; Normais usam a inversa-transposta da matriz LBS já misturada.
              (unless (zerop largest)
                (let ((blended (sgeo.math:make-mat4))
                      (scaled-sum (loop for weight across influences
                                        sum (/ weight largest) double-float)))
                  (loop for joint-index across indices
                        for weight across influences
                        unless (zerop weight)
                          do (let ((matrix (aref palette joint-index))
                                   (factor (/ (/ weight largest) scaled-sum)))
                               (dotimes (i 16)
                                 (incf (aref blended i) (* factor (aref matrix i))))))
                  (setf out-p (sgeo.math:transform-point blended p)
                        out-n (%mat3-normal blended n)))
                (when (> (sgeo.math:vector-length out-n) 1d-15)
                  (setf out-n (sgeo.math:normalize out-n)))
                (setf p out-p n out-n))
              (dotimes (component 3)
                (setf (aref positions (+ (* 3 vertex) component)) (aref p component)
                      (aref normals (+ (* 3 vertex) component)) (aref n component))))))
          (incf (%deformation-revision object))
          (let ((data (sgeo.geometry::%make-render-mesh-data
                       positions normals
                       (copy-seq (sgeo.geometry:render-mesh-indices base))
                       (%deformation-revision object)
                       (copy-seq (sgeo.geometry:render-mesh-source-faces base)))))
            (setf (%deformed-cache-key object) key
                  (%deformed-cache-data object) data)
            data)))))

(defun deformed-render-data (object)
  "Retorna dados renderizáveis derivados e armazenados em cache por instância."
  (let ((world (sgeo.scene:scene-object-world object)))
    (flet ((run ()
             (bt:with-recursive-lock-held ((%deformation-lock object))
               (%deform-render-data-locked object))))
      ;; A ordem é sempre bloqueio do mundo e depois bloqueio da malha.
      (if world (sgeo.scene:with-world-lock (world) (run)) (run)))))

(defmethod sgeo.scene:render-data-for-object ((object deformable-mesh-object))
  (deformed-render-data object))
(defmethod sgeo.scene:render-cache-key ((object deformable-mesh-object))
  ;; Cada instância tem pose e cache próprios, mesmo compartilhando geometria.
  object)

(defmethod sgeo.core:bounds ((object deformable-mesh-object))
  "Calcula limites locais a partir da mesma pose derivada usada ao renderizar."
  (let* ((positions (sgeo.geometry:render-mesh-positions
                     (deformed-render-data object)))
         (minimum nil) (maximum nil))
    (loop for offset from 0 below (length positions) by 3
          for point = (sgeo.math:make-vec3 (aref positions offset)
                                           (aref positions (1+ offset))
                                           (aref positions (+ offset 2)))
          do (unless minimum
               (setf minimum (copy-seq point) maximum (copy-seq point)))
             (dotimes (axis 3)
               (setf (aref minimum axis) (min (aref minimum axis) (aref point axis))
                     (aref maximum axis) (max (aref maximum axis) (aref point axis))))
          finally (return (when minimum (sgeo.math:make-aabb minimum maximum))))))

(defun %skeleton-quaternion-conjugate (q)
  (sgeo.math:make-quaternion (- (aref (sgeo.math::quaternion-data q) 0))
                             (- (aref (sgeo.math::quaternion-data q) 1))
                             (- (aref (sgeo.math::quaternion-data q) 2))
                             (aref (sgeo.math::quaternion-data q) 3)))

(declaim (ftype function %world-rotation))

(defun %apply-ik-world-delta (joint delta)
  (let* ((parent (sgeo.scene:scene-object-parent joint))
         (parent-rotation (if parent (%world-rotation parent)
                              (sgeo.math:make-quaternion)))
         (local (sgeo.math:transform-rotation
                 (sgeo.scene:scene-object-local-transform joint)))
         (new-local (sgeo.math:quaternion-multiply
                     (%skeleton-quaternion-conjugate parent-rotation)
                     (sgeo.math:quaternion-multiply delta
                       (sgeo.math:quaternion-multiply parent-rotation local)))))
    (sgeo.scene:set-rotation joint new-local)))

(defun %world-rotation (object)
  (let* ((matrix (sgeo.scene:world-transform object))
         (x (sgeo.math:make-vec3 (aref matrix 0) (aref matrix 1) (aref matrix 2)))
         (y (sgeo.math:make-vec3 (aref matrix 4) (aref matrix 5) (aref matrix 6)))
         (z (sgeo.math:make-vec3 (aref matrix 8) (aref matrix 9) (aref matrix 10))))
    (when (or (<= (sgeo.math:vector-length x) 1d-15)
              (<= (sgeo.math:vector-length y) 1d-15)
              (<= (sgeo.math:vector-length z) 1d-15))
      (error 'sgeo.core:validation-error :context "IK"
             :message "A transformação de uma articulação não pode ser singular."))
    (sgeo.scene::%rotation-matrix->quaternion
     (/ (aref matrix 0) (sgeo.math:vector-length x))
     (/ (aref matrix 4) (sgeo.math:vector-length y))
     (/ (aref matrix 8) (sgeo.math:vector-length z))
     (/ (aref matrix 1) (sgeo.math:vector-length x))
     (/ (aref matrix 5) (sgeo.math:vector-length y))
     (/ (aref matrix 9) (sgeo.math:vector-length z))
     (/ (aref matrix 2) (sgeo.math:vector-length x))
     (/ (aref matrix 6) (sgeo.math:vector-length y))
     (/ (aref matrix 10) (sgeo.math:vector-length z)))))

(defun solve-ik (skeleton chain target &key (iterations 24) (tolerance 1d-4) pole)
  "Resolve cadeia articulada por CCD e retorna T quando chega ao alvo."
  (let* ((nodes (%skeleton-sequence-vector chain "cadeia de IK"))
         (target (if (and (typep target 'array) (= (length target) 3)
                          (loop for value across target always (%skeleton-finite-real-p value)))
                     (sgeo.math:make-vec3 (aref target 0) (aref target 1) (aref target 2))
                     (error 'sgeo.core:validation-error :context "alvo de IK"
                            :message "O alvo precisa ser um vec3 finito.")))
         (pole (when pole
                 (if (and (typep pole 'array) (= (length pole) 3)
                          (loop for value across pole always (%skeleton-finite-real-p value)))
                     (sgeo.math:make-vec3 (aref pole 0) (aref pole 1) (aref pole 2))
                     (error 'sgeo.core:validation-error :context "polo de IK"
                            :message "O polo precisa ser um vec3 finito.")))))
    (unless (and (typep skeleton 'skeleton) (>= (length nodes) 2)
                 (every (lambda (node) (and (typep node 'sgeo.scene:scene-object)
                                            (find node (%skeleton-joints skeleton) :test #'eq))) nodes)
                 (and (integerp iterations) (plusp iterations))
                 (%skeleton-finite-real-p tolerance) (plusp tolerance))
      (error 'sgeo.core:validation-error :context "cadeia de IK"
             :message "A cadeia precisa ter ao menos duas articulações do esqueleto e parâmetros válidos."))
    (loop for index from 1 below (length nodes)
          unless (eq (sgeo.scene:scene-object-parent (aref nodes index))
                     (aref nodes (1- index)))
            do (error 'sgeo.core:validation-error :context "cadeia de IK"
                      :message "As articulações precisam estar na ordem pai-filho."))
    (let* ((world (sgeo.scene:scene-object-world (aref nodes 0)))
           (end (aref nodes (1- (length nodes))))
           (run (lambda ()
                  (loop repeat iterations
                        do (loop for index downfrom (- (length nodes) 2) to 0
                                 for joint = (aref nodes index)
                                 for joint-pos = (sgeo.scene:local->world joint (sgeo.math:make-vec3))
                                 for end-pos = (sgeo.scene:local->world end (sgeo.math:make-vec3))
                                 for from = (sgeo.math:v- end-pos joint-pos)
                                 for to = (sgeo.math:v- target joint-pos)
                                 for axis-raw = (sgeo.math:cross from to)
                                 for axis = (if (and pole (<= (sgeo.math:vector-length axis-raw) 1d-12)
                                                    (minusp (sgeo.math:dot from to)))
                                                (sgeo.math:cross from (sgeo.math:v- pole joint-pos)) axis-raw)
                                 for from-length = (sgeo.math:vector-length from)
                                 for to-length = (sgeo.math:vector-length to)
                                 do (when (and (> (sgeo.math:vector-length axis) 1d-12)
                                               (> from-length 1d-12) (> to-length 1d-12))
                                        (let* ((angle (acos (max -1d0 (min 1d0
                                                     (/ (sgeo.math:dot from to)
                                                        (* from-length to-length))))))
                                             (delta (sgeo.math:quaternion-from-axis-angle axis angle))
                                             )
                                        (%apply-ik-world-delta joint delta)))))
                  ;; A rotação em torno da linha raiz-extremidade preserva o alvo.
                  (when (and pole (> (length nodes) 2))
                    (let* ((root (aref nodes 0))
                           (root-pos (sgeo.scene:local->world root (sgeo.math:make-vec3)))
                           (end-pos (sgeo.scene:local->world end (sgeo.math:make-vec3)))
                           (axis-delta (sgeo.math:v- end-pos root-pos))
                           (axis-length (sgeo.math:vector-length axis-delta))
                           (axis (when (> axis-length 1d-12)
                                   (sgeo.math:v* (/ 1d0 axis-length) axis-delta)))
                           (middle (aref nodes 1))
                           (middle-offset (sgeo.math:v- (sgeo.scene:local->world middle (sgeo.math:make-vec3)) root-pos))
                           (pole-offset (sgeo.math:v- pole root-pos))
                           (middle-plane (when axis
                                           (sgeo.math:v- middle-offset
                                             (sgeo.math:v* (sgeo.math:dot middle-offset axis) axis))))
                           (pole-plane (when axis
                                         (sgeo.math:v- pole-offset
                                           (sgeo.math:v* (sgeo.math:dot pole-offset axis) axis)))))
                      (when (and axis
                                 (> (sgeo.math:vector-length middle-plane) 1d-12)
                                 (> (sgeo.math:vector-length pole-plane) 1d-12))
                        (let ((angle (atan (sgeo.math:dot axis
                                                   (sgeo.math:cross middle-plane pole-plane))
                                           (sgeo.math:dot middle-plane pole-plane))))
                          (%apply-ik-world-delta root
                            (sgeo.math:quaternion-from-axis-angle axis angle))))))
                  (<= (sgeo.math:vector-length
                       (sgeo.math:v- (sgeo.scene:local->world end (sgeo.math:make-vec3)) target))
                      tolerance))))
      (if world (sgeo.scene:with-world-lock (world) (funcall run)) (funcall run)))))

(defun extract-root-motion (root previous-time current-time &key (looping-p nil) duration)
  "Retorna deslocamento entre amostras de posição do nó raiz.

ROOT é uma função que devolve a posição vec3 da raiz para um tempo de clipe;
quando há looping, considera a posição embrulhada e o deslocamento de cada ciclo."
  (unless (and (functionp root) (%skeleton-finite-real-p previous-time)
               (%skeleton-finite-real-p current-time)
               (or (null duration) (and (%skeleton-finite-real-p duration) (plusp duration))))
    (error 'sgeo.core:validation-error :context "extração de movimento raiz"
           :message "Informe ROOT, tempos finitos e uma duração positiva quando usada."))
  (labels ((sample (time)
             (let ((position (funcall root time)))
               (unless (and (typep position 'array) (= (array-rank position) 1)
                            (= (length position) 3)
                            (loop for value across position
                                  always (%skeleton-finite-real-p value)))
                 (error 'sgeo.core:validation-error :context "extração de movimento raiz"
                        :message "ROOT precisa devolver posições vec3 finitas."))
               (sgeo.math:make-vec3 (aref position 0) (aref position 1) (aref position 2)))))
    (let* ((sample-from (if (and looping-p duration) (mod previous-time duration) previous-time))
           (sample-to (if (and looping-p duration) (mod current-time duration) current-time))
           (start (sample sample-from))
           (end (sample sample-to))
           (delta (sgeo.math:v- end start)))
      (if (and looping-p duration)
          (let ((cycles (- (floor current-time duration) (floor previous-time duration))))
            (sgeo.math:v+ delta
              (sgeo.math:v* cycles
                (sgeo.math:v- (sample duration) (sample 0d0)))))
          delta))))
