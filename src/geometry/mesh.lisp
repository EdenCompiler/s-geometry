(in-package #:sgeo.geometry)

(defstruct (render-mesh-data
            (:constructor %make-render-mesh-data (positions normals indices revision &optional (source-faces #())))
            (:conc-name render-mesh-))
  "Dados planos prontos para o backend, copiados de uma revisão coerente da malha."
  (positions #() :type vector :read-only t)
  (normals #() :type vector :read-only t)
  (indices #() :type vector :read-only t)
  (revision 0 :type integer :read-only t)
  (source-faces #() :type vector :read-only t))

(defclass triangle-mesh (sgeo-object)
  ((positions :initarg :positions :reader %mesh-raw-positions)
   (normals :initarg :normals :reader %mesh-raw-normals)
   (indices :initarg :indices :reader %mesh-raw-indices)
   (bounds :initform nil :reader %mesh-raw-bounds)
   (data-lock :initform (bt:make-recursive-lock "sgeo mesh data") :reader %mesh-data-lock))
  (:documentation "Malha triangular indexada com dados CPU como fonte autoritativa."))

(defun %numeric-vector (data context)
  (let ((sequence (coerce data 'vector)))
    (unless (every #'realp sequence)
      (error 'validation-error :context context
             :message "Todos os componentes precisam ser números reais."))
    (make-array (length sequence) :element-type 'double-float
                :initial-contents (map 'list (lambda (value) (coerce value 'double-float)) sequence))))

(defun %index-vector (data)
  (let ((sequence (coerce data 'vector)))
    (unless (every (lambda (index) (and (integerp index) (<= 0 index #xffffffff))) sequence)
      (error 'validation-error :context "índices da malha"
             :message "Os índices precisam ser inteiros não negativos de 32 bits."))
    (make-array (length sequence) :element-type '(unsigned-byte 32)
                :initial-contents (map 'list #'identity sequence))))

(defun %array-vector3 (values index)
  (let ((offset (* 3 index)))
    (make-vec3 (aref values offset)
               (aref values (1+ offset))
               (aref values (+ offset 2)))))

(defun %compute-normals (positions indices)
  (let* ((normals (make-array (length positions) :element-type 'double-float :initial-element 0d0))
         (count (length indices)))
    (loop for offset from 0 below count by 3
          for ia = (aref indices offset)
          for ib = (aref indices (1+ offset))
          for ic = (aref indices (+ offset 2))
          for a = (%array-vector3 positions ia)
          for b = (%array-vector3 positions ib)
          for c = (%array-vector3 positions ic)
          for face-normal = (cross (v- b a) (v- c a))
          do (loop for index in (list ia ib ic)
                   for base = (* 3 index)
                   do (incf (aref normals base) (vx face-normal))
                      (incf (aref normals (1+ base)) (vy face-normal))
                      (incf (aref normals (+ base 2)) (vz face-normal)))
          finally (return nil))
    (loop for offset from 0 below (length normals) by 3
          for accumulated = (make-vec3 (aref normals offset)
                                       (aref normals (1+ offset))
                                       (aref normals (+ offset 2)))
          for normal = (if (> (vector-length accumulated) 1d-15)
                           (normalize accumulated)
                           (make-vec3))
          do (setf (aref normals offset) (vx normal)
                   (aref normals (1+ offset)) (vy normal)
                   (aref normals (+ offset 2)) (vz normal)))
    normals))

(defun %validate-mesh-data (positions indices normals)
  (unless (and (plusp (length positions)) (zerop (mod (length positions) 3)))
    (error 'validation-error :context "posições da malha"
           :message "A malha precisa de ao menos um vértice com três componentes."))
  (unless (and (plusp (length indices)) (zerop (mod (length indices) 3)))
    (error 'validation-error :context "triângulos da malha"
           :message "A lista de índices precisa conter ao menos um triângulo completo."))
  (let ((vertex-count (/ (length positions) 3)))
    (unless (every (lambda (index) (< index vertex-count)) indices)
      (error 'validation-error :context "índices da malha"
             :message "Um índice aponta para fora da lista de vértices.")))
  (loop for offset from 0 below (length indices) by 3
        for a = (%array-vector3 positions (aref indices offset))
        for b = (%array-vector3 positions (aref indices (1+ offset)))
        for c = (%array-vector3 positions (aref indices (+ offset 2)))
        for ab = (v- b a)
        for ac = (v- c a)
        for bc = (v- c b)
        for scale = (max (vector-length ab) (vector-length ac) (vector-length bc))
        for twice-area = (vector-length (cross ab ac))
        when (or (<= scale 0d0) (<= twice-area (* 1d-12 scale scale)))
          do (error 'validation-error :context "triângulos da malha"
                    :message "A malha contém um triângulo degenerado."))
  (when (and normals (/= (length normals) (length positions)))
    (error 'validation-error :context "normais da malha"
           :message "A lista de normais precisa ter três componentes por vértice."))
  (values positions indices (or normals (%compute-normals positions indices))))

(defun %compute-bounds (positions)
  (let ((minimum (make-vec3 (aref positions 0) (aref positions 1) (aref positions 2)))
        (maximum (make-vec3 (aref positions 0) (aref positions 1) (aref positions 2))))
    (loop for offset from 3 below (length positions) by 3
          do (setf minimum (make-vec3 (min (vx minimum) (aref positions offset))
                                      (min (vy minimum) (aref positions (1+ offset)))
                                      (min (vz minimum) (aref positions (+ offset 2))))
                   maximum (make-vec3 (max (vx maximum) (aref positions offset))
                                      (max (vy maximum) (aref positions (1+ offset)))
                                      (max (vz maximum) (aref positions (+ offset 2))))))
    (make-aabb minimum maximum)))

(defun make-triangle-mesh (&key positions indices normals (name "Malha triangular") metadata)
  "Cria uma malha indexada e valida seus dados antes de publicá-los."
  (make-triangle-mesh-from-data positions indices :normals normals :name name :metadata metadata))

(defun make-triangle-mesh-from-data (positions indices &key normals (name "Malha triangular") metadata)
  "Cria uma malha a partir de vetores planos de posições, normais e índices."
  (let* ((position-data (%numeric-vector positions "posições da malha"))
         (index-data (%index-vector indices))
         (normal-data (when normals (%numeric-vector normals "normais da malha"))))
    (%validate-mesh-data position-data index-data normal-data)
    (make-instance 'triangle-mesh :name name :metadata metadata
                   :positions position-data
                   :normals (or normal-data (%compute-normals position-data index-data))
                   :indices index-data)))

(defmethod initialize-instance :after ((mesh triangle-mesh) &key)
  (setf (slot-value mesh 'bounds) (%compute-bounds (%mesh-raw-positions mesh))))

(defun mesh-positions (mesh)
  "Retorna uma cópia das posições da malha."
  (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
    (copy-seq (%mesh-raw-positions mesh))))

(defun mesh-normals (mesh)
  "Retorna uma cópia das normais da malha."
  (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
    (copy-seq (%mesh-raw-normals mesh))))

(defun mesh-indices (mesh)
  "Retorna uma cópia dos índices da malha."
  (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
    (copy-seq (%mesh-raw-indices mesh))))

(defmethod bounds ((mesh triangle-mesh))
  (mesh-bounds mesh))

(defun mesh-bounds (mesh)
  "Retorna uma cópia dos limites alinhados aos eixos da malha."
  (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
    (let ((bounds (%mesh-raw-bounds mesh)))
      (make-aabb (aabb-min bounds) (aabb-max bounds)))))

(defmethod compile-render-data ((mesh triangle-mesh) &optional context)
  (declare (ignore context))
  (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
    (%make-render-mesh-data (copy-seq (%mesh-raw-positions mesh))
                            (copy-seq (%mesh-raw-normals mesh))
                            (copy-seq (%mesh-raw-indices mesh))
                            (sgeo.core:object-revision mesh))))

(defun set-mesh-data (mesh positions indices &optional normals)
  "Substitui os dados da malha atomicamente e avança sua revisão."
  (let* ((position-data (%numeric-vector positions "posições da malha"))
         (index-data (%index-vector indices))
         (normal-data (when normals (%numeric-vector normals "normais da malha"))))
    (%validate-mesh-data position-data index-data normal-data)
    (let ((computed-normals (or normal-data (%compute-normals position-data index-data)))
          (computed-bounds (%compute-bounds position-data)))
    (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
      (setf (slot-value mesh 'positions) position-data
            (slot-value mesh 'normals) computed-normals
            (slot-value mesh 'indices) index-data
            (slot-value mesh 'bounds) computed-bounds)
      (touch-object mesh :mesh-data-changed))
    mesh)))

(defun set-mesh-position (mesh vertex-index position)
  "Move um vértice, recalcula as normais e os limites da malha."
  (let ((point (%numeric-vector position "posição do vértice")))
    (unless (= (length point) 3)
      (error 'validation-error :context "posição do vértice"
             :message "A posição precisa ter três componentes."))
    (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
      (unless (and (integerp vertex-index) (<= 0 vertex-index)
                   (< vertex-index (/ (length (%mesh-raw-positions mesh)) 3)))
        (error 'validation-error :context "posição do vértice"
               :message "O índice do vértice está fora dos limites."))
      (let ((positions (copy-seq (%mesh-raw-positions mesh)))
            (indices (%mesh-raw-indices mesh)))
        (replace positions point :start1 (* 3 vertex-index))
        (%validate-mesh-data positions indices nil)
        (let ((normals (%compute-normals positions indices))
              (bounds (%compute-bounds positions)))
          (setf (slot-value mesh 'positions) positions
                (slot-value mesh 'normals) normals
                (slot-value mesh 'bounds) bounds))
        (touch-object mesh :vertex-position-changed)))
  mesh))

(defun make-box (&key (size 1d0) (name "Caixa") metadata)
  "Cria uma caixa fechada triangulada centrada na origem."
  (let ((dimensions (if (realp size)
                        (make-vec3 size size size)
                        (if (and (typep size 'sequence) (= (length size) 3))
                            (make-vec3 (elt size 0) (elt size 1) (elt size 2))
                            nil))))
  (unless (and dimensions (every (lambda (value) (and (realp value) (> value 0))) dimensions))
    (error 'validation-error :context "tamanho da caixa"
           :message "As dimensões precisam ser números positivos."))
  (let* ((half (map 'vector (lambda (value) (/ (coerce value 'double-float) 2d0)) dimensions))
         (corners #((-1 -1 -1) (-1 1 -1) (1 1 -1) (1 -1 -1)
                    (-1 -1 1) (1 -1 1) (1 1 1) (-1 1 1)
                    (-1 -1 -1) (-1 -1 1) (-1 1 1) (-1 1 -1)
                    (1 -1 -1) (1 1 -1) (1 1 1) (1 -1 1)
                    (-1 -1 -1) (1 -1 -1) (1 -1 1) (-1 -1 1)
                    (-1 1 -1) (-1 1 1) (1 1 1) (1 1 -1)))
         (positions (make-array 72 :element-type 'double-float))
         (indices (make-array 36 :element-type '(unsigned-byte 32))))
    (dotimes (vertex 24)
      (dotimes (axis 3)
        (setf (aref positions (+ (* vertex 3) axis))
              (* (aref half axis) (nth axis (aref corners vertex))))))
    (dotimes (face 6)
      (let ((base (* 4 face)) (index-base (* 6 face)))
        (setf (aref indices index-base) base
              (aref indices (+ index-base 1)) (1+ base)
              (aref indices (+ index-base 2)) (+ base 2)
              (aref indices (+ index-base 3)) base
              (aref indices (+ index-base 4)) (+ base 2)
              (aref indices (+ index-base 5)) (+ base 3))))
    (make-triangle-mesh :positions positions :indices indices :name name :metadata metadata))))

(defun ray-intersect-mesh (mesh ray)
  "Retorna a menor distância não negativa atingida pelo raio em um triângulo."
  (let ((nearest nil))
    (bt:with-recursive-lock-held ((%mesh-data-lock mesh))
      (let ((positions (%mesh-raw-positions mesh))
            (indices (%mesh-raw-indices mesh)))
      (loop for offset from 0 below (length indices) by 3
            for a = (%array-vector3 positions (aref indices offset))
            for b = (%array-vector3 positions (aref indices (1+ offset)))
            for c = (%array-vector3 positions (aref indices (+ offset 2)))
            for distance = (ray-triangle-intersection ray a b c)
            when (and distance (or (null nearest) (< distance nearest)))
              do (setf nearest distance))))
    nearest))
