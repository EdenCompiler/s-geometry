(in-package #:sgeo.geometry)

(defun %operation-position (position context)
  (unless (and (typep position 'sequence) (= (length position) 3)
               (every #'%finite-real-p position))
    (error 'geometry-error :context context
           :message "A posição precisa conter três números reais finitos."))
  (map 'vector (lambda (value) (coerce value 'double-float)) position))

(defun %face-position-list (state vertices)
  (let ((arena (%state-vertices state)))
    (mapcar (lambda (index)
              (vertex-record-position (aref (%arena-items arena) index)))
            vertices)))

(defun %operation-face-area-vector (state vertices)
  "Calcula o vetor de área orientado de um ciclo poligonal."
  (let* ((points (%face-position-list state vertices))
         (origin (first points)) (sum (make-vec3)))
    (loop for a in points for b in (append (rest points) (list (first points)))
          do (setf sum (v+ sum (cross (v- a origin) (v- b origin)))))
    (v* 0.5d0 sum)))

(defun %vertex-used-p (state vertex-index)
  (some (lambda (face-index)
          (member vertex-index
                  (face-record-vertices
                   (aref (%arena-items (%state-faces state)) face-index))))
        (%arena-active-indices (%state-faces state))))

(defun %validate-operation-geometry (state)
  "Valida a área de cada face antes da topologia candidata ser publicada."
  (dolist (face-index (%arena-active-indices (%state-faces state)))
    (%triangulate-face state face-index))
  t)

(defun set-vertex-position (mesh vertex position)
  "Move um vértice da malha e valida a edição antes de publicá-la."
  (let ((point (%operation-position position "posição do vértice")))
    (%with-mesh-edit (mesh state)
      (multiple-value-bind (record index) (%resolve-handle mesh vertex :vertex state)
        (declare (ignore record))
        (setf (vertex-record-position
               (aref (%arena-items (%state-vertices state)) index)) point))
      (%validate-operation-geometry state)
      mesh)))

(defun split-edge (mesh edge &key (parameter 0.5d0))
  "Divide uma aresta e insere o novo vértice em todas as faces incidentes."
  (unless (and (%finite-real-p parameter) (< 0 parameter 1))
    (error 'geometry-error :context "divisão de aresta"
           :message "O parâmetro precisa estar estritamente entre zero e um."))
  (let ((t-value (coerce parameter 'double-float)))
    (%with-mesh-edit (mesh state)
      (multiple-value-bind (edge-record edge-index)
          (%resolve-handle mesh edge :edge state)
        (declare (ignore edge-index))
        (let* ((half-edges (%state-half-edges state))
               (half-edge-index (edge-record-half-edge edge-record))
               (half-edge (aref (%arena-items half-edges) half-edge-index))
               (a (half-edge-record-origin half-edge))
               (b (half-edge-record-origin
                   (aref (%arena-items half-edges)
                         (half-edge-record-next half-edge))))
               (position (v+ (vertex-record-position
                             (aref (%arena-items (%state-vertices state)) a))
                            (v* t-value
                                (v- (vertex-record-position
                                     (aref (%arena-items (%state-vertices state)) b))
                                    (vertex-record-position
                                     (aref (%arena-items (%state-vertices state)) a))))))
               (new-index (%arena-allocate (%state-vertices state)
                                           (make-vertex-record :position position))))
          (dolist (face-index (%arena-active-indices (%state-faces state)))
            (let* ((face (aref (%arena-items (%state-faces state)) face-index))
                   (vertices (face-record-vertices face))
                   (result nil))
              (loop for from in vertices
                    for to in (append (rest vertices) (list (first vertices)))
                    do (push from result)
                       (when (or (and (= from a) (= to b))
                                 (and (= from b) (= to a)))
                         (push new-index result)))
              (setf (face-record-vertices face) (nreverse result))))
          (%validate-operation-geometry state)
          (%make-handle mesh :vertex new-index state))))))

(defun %remove-adjacent-duplicates (vertices)
  (let ((result nil))
    (dolist (vertex vertices)
      (unless (eql vertex (first result)) (push vertex result)))
    (setf result (nreverse result))
    (when (and (> (length result) 1) (eql (first result) (car (last result))))
      (setf result (butlast result)))
    result))

(defun collapse-edge (mesh edge &key keep position)
  "Colapsa uma aresta em uma das pontas, validando toda a malha candidata."
  (%with-mesh-edit (mesh state)
    (multiple-value-bind (edge-record edge-index)
        (%resolve-handle mesh edge :edge state)
      (declare (ignore edge-index))
      (let* ((half-edges (%state-half-edges state))
             (half-edge (aref (%arena-items half-edges) (edge-record-half-edge edge-record)))
             (a (half-edge-record-origin half-edge))
             (b (half-edge-record-origin
                 (aref (%arena-items half-edges) (half-edge-record-next half-edge))))
             (keep-index (if keep
                             (nth-value 1 (%resolve-handle mesh keep :vertex state))
                             a))
             (remove-index (cond ((= keep-index a) b)
                                 ((= keep-index b) a)
                                 (t (error 'geometry-error :context "colapso de aresta"
                                           :message "O vértice mantido precisa ser uma ponta da aresta."))))
             (kept-position (if position
                                (%operation-position position "posição do colapso")
                                (v* 0.5d0
                                    (v+ (vertex-record-position
                                         (aref (%arena-items (%state-vertices state)) a))
                                        (vertex-record-position
                                         (aref (%arena-items (%state-vertices state)) b)))))))
        (setf (vertex-record-position
               (aref (%arena-items (%state-vertices state)) keep-index)) kept-position)
        (dolist (face-index (%arena-active-indices (%state-faces state)))
          (let* ((face (aref (%arena-items (%state-faces state)) face-index))
                 (vertices (mapcar (lambda (index) (if (= index remove-index) keep-index index))
                                  (face-record-vertices face)))
                 (cleaned (%remove-adjacent-duplicates vertices)))
            (when (/= (length cleaned) (length (remove-duplicates cleaned)))
              (error 'geometry-edit-error :context "colapso de aresta"
                     :message "O colapso criaria vértices repetidos não consecutivos em uma face."))
            (if (< (length cleaned) 3)
                (%arena-retire (%state-faces state) face-index)
                (setf (face-record-vertices face) cleaned))))
        (unless (%arena-active-indices (%state-faces state))
          (error 'geometry-edit-error :context "colapso de aresta"
                 :message "O colapso removeria a última face da malha."))
        (%arena-retire (%state-vertices state) remove-index)
        (%validate-operation-geometry state)
        (%make-handle mesh :vertex keep-index state)))))

(defun %selected-face-indices (mesh state faces)
  (unless (and (listp faces) faces)
    (error 'geometry-error :context "extrusão de região"
           :message "A região precisa conter ao menos uma face."))
  (let ((indices (mapcar (lambda (face)
                           (nth-value 1 (%resolve-handle mesh face :face state)))
                         faces)))
    (unless (= (length indices) (length (remove-duplicates indices)))
      (error 'geometry-error :context "extrusão de região"
             :message "A região não pode repetir faces."))
    indices))

(defun %region-boundary-edges (state selected)
  (let ((counts (make-hash-table :test #'equal)) (oriented (make-hash-table :test #'equal)))
    (dolist (face-index selected)
      (let ((vertices (face-record-vertices
                       (aref (%arena-items (%state-faces state)) face-index))))
        (loop for a in vertices for b in (append (rest vertices) (list (first vertices)))
              for key = (%edge-key a b)
              do (incf (gethash key counts 0))
                 (setf (gethash key oriented) (list a b)))))
    (loop for key being the hash-keys of counts using (hash-value count)
          when (= count 1) collect (gethash key oriented))))

(defun %validate-face-region-connected (state indices)
  (let ((selected (make-hash-table)) (seen (make-hash-table)) (queue (list (first indices))))
    (dolist (index indices) (setf (gethash index selected) t))
    (let ((edges (make-hash-table :test #'equal)))
      (dolist (face-index indices)
        (let ((vertices (face-record-vertices
                         (aref (%arena-items (%state-faces state)) face-index))))
          (loop for a in vertices for b in (append (rest vertices) (list (first vertices)))
                do (push face-index (gethash (%edge-key a b) edges)))))
      (loop while queue for current = (pop queue) unless (gethash current seen)
            do (setf (gethash current seen) t)
               (let ((vertices (face-record-vertices
                                (aref (%arena-items (%state-faces state)) current))))
                 (loop for a in vertices for b in (append (rest vertices) (list (first vertices)))
                       do (dolist (neighbor (gethash (%edge-key a b) edges))
                            (when (and (gethash neighbor selected) (not (gethash neighbor seen)))
                              (push neighbor queue)))))))
    (unless (= (hash-table-count seen) (length indices))
      (error 'geometry-error :context "extrusão de região"
             :message "As faces selecionadas precisam formar uma região conectada por arestas."))))

(defun %region-offsets (state selected distance offset)
  (let ((explicit-offset (and offset (%operation-position offset "deslocamento da extrusão")))
        (vertex-sums (make-hash-table)) (vertex-offsets (make-hash-table)))
    (when (and explicit-offset (zerop (vector-length explicit-offset)))
      (error 'geometry-error :context "extrusão" :message "O deslocamento não pode ser zero."))
    (when (and (null explicit-offset) (or (not (%finite-real-p distance)) (zerop distance)))
      (error 'geometry-error :context "extrusão" :message "A distância precisa ser um número real não nulo."))
    (dolist (face-index selected)
      (let* ((vertices (face-record-vertices
                        (aref (%arena-items (%state-faces state)) face-index)))
             (area (%operation-face-area-vector state vertices)))
        (when (zerop (vector-length area))
          (error 'geometry-edit-error :context "extrusão"
                 :message "Uma face degenerada não pode ser extrudida."))
        (dolist (vertex vertices)
          (setf (gethash vertex vertex-sums)
                (v+ (gethash vertex vertex-sums (make-vec3)) area)))))
    (maphash
     (lambda (vertex sum)
       (setf (gethash vertex vertex-offsets)
             (or explicit-offset
                 (let ((length (vector-length sum)))
                   (when (zerop length)
                     (error 'geometry-edit-error :context "extrusão"
                            :message "As normais da região se anulam em um vértice."))
                   (v* (/ (coerce distance 'double-float) length) sum)))))
     vertex-sums)
    vertex-offsets))

(defun %extrude-region-in-state (mesh state face-handles distance offset)
  (let* ((selected (%selected-face-indices mesh state face-handles)))
    (%validate-face-region-connected state selected)
    (let* ((vertex-offsets (%region-offsets state selected distance offset))
           (duplicate-map (make-hash-table))
           (boundary (%region-boundary-edges state selected)) (faces (%state-faces state))
           (vertices (%state-vertices state)))
      (maphash (lambda (old-index displacement)
                 (let* ((old (aref (%arena-items vertices) old-index))
                        (new-position (v+ (vertex-record-position old) displacement)))
                   (setf (gethash old-index duplicate-map)
                         (%arena-allocate vertices (make-vertex-record :position new-position)))))
               vertex-offsets)
      ;; Os identificadores das faces escolhidas continuam representando o topo.
      (dolist (face-index selected)
        (let ((face (aref (%arena-items faces) face-index)))
          (setf (face-record-vertices face)
                (mapcar (lambda (index) (gethash index duplicate-map))
                        (face-record-vertices face)))))
      ;; Uma parede fecha cada aresta entre a região e seu complemento (ou borda aberta).
      (dolist (edge boundary)
        (destructuring-bind (a b) edge
          (%arena-allocate faces
                           (make-face-record :vertices
                                             (list a b (gethash b duplicate-map)
                                                   (gethash a duplicate-map))))))
      ;; Vértices originais internos à região podem ser retirados após todas as faces mudarem.
      (dolist (old-index (loop for index being the hash-keys of duplicate-map collect index))
        (unless (%vertex-used-p state old-index)
          (%arena-retire vertices old-index)))
      (%validate-operation-geometry state)
      (mapcar (lambda (index) (%make-handle mesh :face index state)) selected))))

(defun extrude-face (mesh face &key (distance 1d0) offset)
  "Extrude uma face, preservando seu identificador como a face do topo."
  (%with-mesh-edit (mesh state)
    (first (%extrude-region-in-state mesh state (list face) distance offset))))

(defun extrude-face-region (mesh faces &key (distance 1d0) offset)
  "Extrude uma região conectada e cria paredes somente em seu contorno."
  (%with-mesh-edit (mesh state)
    (%extrude-region-in-state mesh state faces distance offset)))
