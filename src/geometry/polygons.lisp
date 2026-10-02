(in-package #:sgeo.geometry)

(defun %face-positions (state face-index)
  (let* ((face (aref (%arena-items (%state-faces state)) face-index))
         (indices (face-record-vertices face)))
    (mapcar (lambda (index)
              (vertex-record-position
               (aref (%arena-items (%state-vertices state)) index)))
            indices)))

(defun %face-area-vector (state face-index)
  "Calcula o vetor de área de Newell; seu módulo é duas vezes a área orientada."
  (let* ((points (%face-positions state face-index))
         (origin (first points))
         (relative (mapcar (lambda (p) (v- p origin)) points))
         (sum (make-vec3)))
    (loop for point in relative
          for next in (append (cdr relative) (list (car relative)))
          do (setf sum (v+ sum (cross point next))))
    sum))

(defun %unit-vector (vector context)
  ;; Normaliza primeiro pela maior componente para não perder vetores curtos
  ;; ao elevar ao quadrado nem estourar ao somar vetores muito grandes.
  (let ((scale (loop for component across vector maximize (abs component))))
    (when (zerop scale)
      (error 'topology-error :context context :message "O vetor de área é nulo."))
    (let* ((scaled (v* (/ 1d0 scale) vector))
           (length (vector-length scaled)))
      (v* (/ 1d0 length) scaled))))

(defun %dominant-axis (normal)
  (let ((x (abs (vx normal))) (y (abs (vy normal))) (z (abs (vz normal))))
    (cond ((and (>= x y) (>= x z)) 0) ((>= y z) 1) (t 2))))

(defun %project-point (point axis)
  (case axis
    (0 (make-vec2 (vy point) (vz point)))
    (1 (make-vec2 (vz point) (vx point)))
    (otherwise (make-vec2 (vx point) (vy point)))))

(defun %cross2 (a b c)
  (- (* (- (aref b 0) (aref a 0)) (- (aref c 1) (aref a 1)))
     (* (- (aref b 1) (aref a 1)) (- (aref c 0) (aref a 0)))))

(defun %on-segment2-p (a b p epsilon)
  (and (<= (abs (%cross2 a b p)) epsilon)
       (<= (- (min (aref a 0) (aref b 0)) epsilon) (aref p 0)
           (+ (max (aref a 0) (aref b 0)) epsilon))
       (<= (- (min (aref a 1) (aref b 1)) epsilon) (aref p 1)
           (+ (max (aref a 1) (aref b 1)) epsilon))))

(defun %segments-intersect2-p (a b c d epsilon)
  (let ((ab-c (%cross2 a b c)) (ab-d (%cross2 a b d))
        (cd-a (%cross2 c d a)) (cd-b (%cross2 c d b)))
    (or (and (< (* ab-c ab-d) 0d0) (< (* cd-a cd-b) 0d0))
        (%on-segment2-p a b c epsilon) (%on-segment2-p a b d epsilon)
        (%on-segment2-p c d a epsilon) (%on-segment2-p c d b epsilon))))

(defun %polygon-simple-p (points epsilon)
  (let ((count (length points)))
    (loop for i below count always
          (let ((i-next (mod (1+ i) count)))
            (loop for j from (1+ i) below count
                  for j-next = (mod (1+ j) count)
                  always (if (or (= i-next j) (= j-next i))
                             t
                             (not (%segments-intersect2-p (nth i points) (nth i-next points)
                                                          (nth j points) (nth j-next points)
                                                          epsilon))))))))

(defun %point-in-triangle-strict-p (p a b c sign epsilon)
  (and (> (* sign (%cross2 a b p)) epsilon)
       (> (* sign (%cross2 b c p)) epsilon)
       (> (* sign (%cross2 c a p)) epsilon)))

(defun %ear-leaves-valid-triangle-p (remaining points position sign epsilon)
  (if (> (length remaining) 4)
      t
      (let* ((last-three (loop for index in remaining for offset from 0
                               unless (= offset position) collect index))
             (a (nth (first last-three) points))
             (b (nth (second last-three) points))
             (c (nth (third last-three) points)))
        (> (* sign (%cross2 a b c)) epsilon))))

(defun %triangulate-face (state face-index)
  "Triangula uma face simples por ear clipping e retorna índices globais."
  (let* ((face (aref (%arena-items (%state-faces state)) face-index))
         (vertices (copy-list (face-record-vertices face)))
         (points3 (%face-positions state face-index))
         (area-vector (%face-area-vector state face-index)))
    (when (< (length vertices) 3)
      (error 'topology-error :context "triangulação de face"
             :message "Uma face precisa de ao menos três vértices."))
    (let* ((axis (%dominant-axis area-vector))
           (raw-points (mapcar (lambda (point) (%project-point point axis)) points3))
           (origin (first raw-points))
           (points (mapcar (lambda (point) (v- point origin)) raw-points))
           (scale (loop for p in points maximize (max (abs (aref p 0)) (abs (aref p 1)))))
           (epsilon (* 1d-12 scale scale))
           (signed-area (* 0.5d0 (loop for p in points
                                      for q in (append (cdr points) (list (car points)))
                                      sum (- (* (aref p 0) (aref q 1)) (* (aref p 1) (aref q 0))) double-float)))
           (sign (if (plusp signed-area) 1d0 -1d0))
           (remaining (loop for index below (length vertices) collect index))
           (triangles nil)
           (attempts 0))
      (when (or (<= scale 0d0) (<= (abs signed-area) epsilon) (not (%polygon-simple-p points epsilon)))
        (error 'topology-error :context "triangulação de face"
               :message "A face é degenerada ou cruza a si mesma."))
      (loop while (> (length remaining) 3) do
        (let ((ear-position
                (loop for position below (length remaining)
                      for previous-position = (mod (1- position) (length remaining))
                      for next-position = (mod (1+ position) (length remaining))
                      for ia = (nth previous-position remaining)
                      for ib = (nth position remaining)
                      for ic = (nth next-position remaining)
                      for a = (nth ia points) for b = (nth ib points) for c = (nth ic points)
                      when (and (> (* sign (%cross2 a b c)) epsilon)
                                (%ear-leaves-valid-triangle-p remaining points position sign epsilon)
                                (loop for other in remaining
                                      always (or (member other (list ia ib ic))
                                                 (not (%point-in-triangle-strict-p (nth other points) a b c sign epsilon))))
                                (not (loop for other in remaining
                                           for next-other = (nth (mod (1+ (position other remaining)) (length remaining)) remaining)
                                           thereis (and (not (member other (list ia ib ic)))
                                                        (not (member next-other (list ia ib ic)))
                                                        (%segments-intersect2-p a c (nth other points) (nth next-other points) epsilon)))))
                        do (return position))))
          (unless ear-position
            (error 'topology-error :context "triangulação de face"
                   :message "Não foi possível triangula a face simples sem gerar triângulos degenerados."))
          (let* ((n (length remaining))
                 (previous (nth (mod (1- ear-position) n) remaining))
                 (current (nth ear-position remaining))
                 (next (nth (mod (1+ ear-position) n) remaining)))
            (push (list (nth previous vertices) (nth current vertices) (nth next vertices)) triangles)
            (setf remaining (loop for item in remaining for position from 0 unless (= position ear-position) collect item))))
        (incf attempts)
        (when (> attempts (* (length vertices) (length vertices)))
          (error 'topology-error :context "triangulação de face"
                 :message "A triangulação excedeu o limite de busca.")))
      (let* ((a (nth (first remaining) points)) (b (nth (second remaining) points)) (c (nth (third remaining) points)))
        (when (<= (* sign (%cross2 a b c)) epsilon)
          (error 'topology-error :context "triangulação de face"
                 :message "A face termina em um triângulo degenerado."))
        (push (mapcar (lambda (index) (nth index vertices)) remaining) triangles))
      (nreverse triangles))))

(defun triangulate-face (mesh face-handle)
  "Retorna triângulos como listas de handles de vértice da face."
  (%with-kernel-lock (mesh)
    (multiple-value-bind (face index) (%resolve-handle mesh face-handle :face)
      (declare (ignore face))
      (mapcar (lambda (triangle) (mapcar (lambda (vertex-index) (%make-handle mesh :vertex vertex-index)) triangle))
              (%triangulate-face (%mesh-state mesh) index)))))

(defun face-normal (mesh face-handle)
  "Retorna a normal unitária orientada de uma face."
  (%with-kernel-lock (mesh)
    (multiple-value-bind (face index) (%resolve-handle mesh face-handle :face)
      (declare (ignore face))
      (%unit-vector (%face-area-vector (%mesh-state mesh) index) "normal de face"))))

(defun face-area (mesh face-handle)
  "Retorna a área geométrica obtida pela triangulação da face."
  (%with-kernel-lock (mesh)
    (multiple-value-bind (face index) (%resolve-handle mesh face-handle :face)
      (declare (ignore face))
      (loop for triangle in (%triangulate-face (%mesh-state mesh) index)
            for points = (mapcar (lambda (vertex-index)
                                   (vertex-record-position (aref (%arena-items (%state-vertices (%mesh-state mesh))) vertex-index)))
                                 triangle)
            sum (%triangle-area (first points) (second points) (third points)) double-float))))

(defun %triangle-area (a b c)
  (/ (vector-length (cross (v- b a) (v- c a))) 2d0))

(defun mesh-surface-area (mesh)
  "Soma as áreas de todas as faces da malha."
  (%with-kernel-lock (mesh)
    (let* ((state (%mesh-state mesh)) (sum 0d0))
      (dolist (face-index (%arena-active-indices (%state-faces state)) sum)
        (dolist (triangle (%triangulate-face state face-index))
          (let ((points (mapcar (lambda (index) (vertex-record-position (aref (%arena-items (%state-vertices state)) index))) triangle)))
            (incf sum (%triangle-area (first points) (second points) (third points)))))))))

(defun vertex-normal (mesh vertex-handle)
  "Calcula normal por média ponderada pelos ângulos incidentes."
  (%with-kernel-lock (mesh)
    (multiple-value-bind (vertex vertex-index) (%resolve-handle mesh vertex-handle :vertex)
      (declare (ignore vertex))
      (let* ((state (%mesh-state mesh)) (accumulated (make-vec3)))
        (dolist (face-index (%arena-active-indices (%state-faces state)))
          (let* ((face (aref (%arena-items (%state-faces state)) face-index))
                 (indices (face-record-vertices face)))
            (when (member vertex-index indices)
              (let* ((normal (%unit-vector (%face-area-vector state face-index) "normal de vértice"))
                     (position (position vertex-index indices))
                     (count (length indices))
                     (p (vertex-record-position (aref (%arena-items (%state-vertices state)) vertex-index)))
                     (before (vertex-record-position (aref (%arena-items (%state-vertices state)) (nth (mod (1- position) count) indices))))
                     (after (vertex-record-position (aref (%arena-items (%state-vertices state)) (nth (mod (1+ position) count) indices))))
                     (u (%unit-vector (v- before p) "aresta da normal de vértice"))
                     (v (%unit-vector (v- after p) "aresta da normal de vértice"))
                     (small-angle (acos (max -1d0 (min 1d0 (dot u v)))))
                     (angle (if (plusp (dot (cross u v) normal))
                                (- (* 2d0 pi) small-angle)
                                small-angle)))
                (setf accumulated (v+ accumulated (v* angle normal)))))))
        (if (> (vector-length accumulated) 1d-15) (normalize accumulated) (make-vec3))))))

(defun %closest-point-segment (point a b)
  (let* ((edge (v- b a))
         (scale (loop for component across edge maximize (abs component))))
    (if (zerop scale)
        a
        (let* ((scaled-edge (v* (/ 1d0 scale) edge))
               (scaled-offset (v* (/ 1d0 scale) (v- point a)))
               (parameter (/ (dot scaled-offset scaled-edge)
                             (dot scaled-edge scaled-edge))))
          (v+ a (v* (max 0d0 (min 1d0 parameter)) edge))))))

(defun %closest-point-triangle (point a b c)
  (let* ((ab (v- b a)) (ac (v- c a)) (normal (cross ab ac))
         (normal-length-squared (dot normal normal)))
    (when (zerop normal-length-squared)
      (error 'topology-error :context "consulta geométrica" :message "A face contém um triângulo degenerado."))
    (let* ((projection (v- point (v* (/ (dot (v- point a) normal) normal-length-squared) normal)))
           (v0 ab) (v1 ac) (v2 (v- projection a))
           (d00 (dot v0 v0)) (d01 (dot v0 v1)) (d11 (dot v1 v1))
           (d20 (dot v2 v0)) (d21 (dot v2 v1))
           (denominator (- (* d00 d11) (* d01 d01)))
           (u (/ (- (* d11 d20) (* d01 d21)) denominator))
           (v (/ (- (* d00 d21) (* d01 d20)) denominator)))
      (if (and (>= u 0d0) (>= v 0d0) (<= (+ u v) 1d0))
          projection
          (let* ((candidates (list (%closest-point-segment point a b)
                                   (%closest-point-segment point b c)
                                   (%closest-point-segment point c a))))
            (first (sort candidates #'< :key (lambda (candidate)
                                               (dot (v- candidate point) (v- candidate point))))))))))

(defun closest-point-on-mesh (mesh point)
  "Retorna ponto, distância e handle da face mais próxima."
  (unless (and (vectorp point) (= (length point) 3) (every #'%finite-real-p point))
    (error 'validation-error :context "closest-point-on-mesh" :message "O ponto precisa ser um vec3."))
  (let ((point (make-vec3 (aref point 0) (aref point 1) (aref point 2)))
        (best nil) (best-distance nil) (best-handle nil))
    (%with-kernel-lock (mesh)
      (let ((state (%mesh-state mesh)))
        (dolist (face-index (%arena-active-indices (%state-faces state)))
          (dolist (triangle (%triangulate-face state face-index))
            (let* ((points (mapcar (lambda (index) (vertex-record-position (aref (%arena-items (%state-vertices state)) index))) triangle))
                   (candidate (%closest-point-triangle point (first points) (second points) (third points)))
                   (distance (vector-length (v- candidate point))))
              (when (or (null best-distance) (< distance best-distance))
                (setf best candidate best-distance distance
                      best-handle (%make-handle mesh :face face-index state))))))))
    (values (or best (make-vec3)) best-distance best-handle)))

(defun mesh-ray-intersection (mesh ray)
  "Retorna distância, handle da face e ponto do primeiro cruzamento do raio."
  (let ((nearest nil) (nearest-handle nil))
    (%with-kernel-lock (mesh)
      (let ((state (%mesh-state mesh)))
        (dolist (index (%arena-active-indices (%state-faces state)))
          (dolist (triangle (%triangulate-face state index))
            (let* ((points (mapcar (lambda (vertex-index) (vertex-record-position (aref (%arena-items (%state-vertices state)) vertex-index))) triangle))
                   (distance (ray-triangle-intersection ray (first points) (second points) (third points))))
              (when (and distance (or (null nearest) (< distance nearest)))
                (setf nearest distance nearest-handle (%make-handle mesh :face index state))))))))
    (values nearest nearest-handle
            (and nearest (v+ (ray-origin ray) (v* nearest (ray-direction ray)))))))

(defmethod bounds ((mesh half-edge-mesh))
  (%with-kernel-lock (mesh)
    (let* ((state (%mesh-state mesh))
           (vertices (%arena-active-indices (%state-vertices state))))
      (when vertices
        (let ((first-position (vertex-record-position (aref (%arena-items (%state-vertices state)) (first vertices))))
              (minimum nil) (maximum nil))
          (setf minimum (copy-seq first-position) maximum (copy-seq first-position))
          (dolist (index (rest vertices))
            (let ((position (vertex-record-position (aref (%arena-items (%state-vertices state)) index))))
              (dotimes (axis 3)
                (setf (aref minimum axis) (min (aref minimum axis) (aref position axis))
                      (aref maximum axis) (max (aref maximum axis) (aref position axis)))))
          )
          (make-aabb minimum maximum))))))

(defmethod compile-render-data ((mesh half-edge-mesh) &optional context)
  (declare (ignore context))
  (%with-kernel-lock (mesh)
    (let* ((state (%mesh-state mesh)) (positions nil) (normals nil) (indices nil)
           (source-faces nil) (render-index 0))
      (dolist (face-index (%arena-active-indices (%state-faces state)))
        (let ((normal (%unit-vector (%face-area-vector state face-index) "normal de renderização"))
              (render-vertices (make-hash-table)))
          (dolist (triangle (%triangulate-face state face-index))
            (push (%make-handle mesh :face face-index) source-faces)
            (dolist (vertex-index triangle)
              (let ((index (gethash vertex-index render-vertices)))
                (unless index
                  (let ((point (vertex-record-position (aref (%arena-items (%state-vertices state)) vertex-index))))
                    (setf index render-index
                          (gethash vertex-index render-vertices) index
                          positions (nconc positions (coerce point 'list))
                          normals (nconc normals (coerce normal 'list)))
                    (incf render-index)))
                (setf indices (nconc indices (list index))))))))
      (%make-render-mesh-data
       (make-array (length positions) :element-type 'double-float :initial-contents positions)
       (make-array (length normals) :element-type 'double-float :initial-contents normals)
       (make-array (length indices) :element-type '(unsigned-byte 32) :initial-contents indices)
       (sgeo.core:object-revision mesh)
       (coerce (nreverse source-faces) 'vector)))))
