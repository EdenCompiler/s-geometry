(in-package #:sgeo.geometry)

(defun %modeling-error (context message)
  (error 'geometry-edit-error :context context :message message))

(defun %face-centroid (state vertices)
  (v* (/ 1d0 (length vertices))
      (reduce #'v+ (%face-position-list state vertices) :initial-value (make-vec3))))

(defun inset-face (mesh face &key (fraction 0.2d0))
  "Insere uma face menor e cria uma faixa de faces entre ela e o contorno original."
  (unless (and (%finite-real-p fraction) (< 0 fraction 1))
    (error 'geometry-error :context "inset de face"
           :message "A fração precisa estar estritamente entre zero e um."))
  (%with-mesh-edit (mesh state)
    (multiple-value-bind (record face-index) (%resolve-handle mesh face :face state)
      (let* ((vertices (copy-list (face-record-vertices record)))
             (center (%face-centroid state vertices))
             (arena (%state-vertices state))
             (inner (mapcar (lambda (index)
                              (%arena-allocate
                               arena
                               (make-vertex-record
                                :position
                                (v+ (vertex-record-position (aref (%arena-items arena) index))
                                    (v* (coerce fraction 'double-float)
                                        (v- center (vertex-record-position
                                                    (aref (%arena-items arena) index))))))))
                            vertices))
             (faces (%state-faces state)))
        (setf (face-record-vertices (aref (%arena-items faces) face-index)) inner)
        (loop for a in vertices for b in (append (rest vertices) (list (first vertices)))
              for ia in inner for ib in (append (rest inner) (list (first inner)))
              do (%arena-allocate faces
                                 (make-face-record :vertices (list a b ib ia))))
        (%validate-operation-geometry state)
        (%make-handle mesh :face face-index state)))))

(defun %mapping-pairs (mesh state mapping)
  (unless (and (listp mapping) mapping)
    (error 'geometry-error :context "soldagem de vértices"
           :message "Informe ao menos um par de vértices a soldar."))
  (let ((pairs nil) (sources (make-hash-table)))
    (dolist (entry mapping)
      (unless (and (consp entry) (mesh-handle-p (car entry)) (mesh-handle-p (cdr entry)))
        (error 'geometry-error :context "soldagem de vértices"
               :message "Cada mapeamento precisa ser um par (origem . destino) de identificadores."))
      (let ((source (nth-value 1 (%resolve-handle mesh (car entry) :vertex state)))
            (target (nth-value 1 (%resolve-handle mesh (cdr entry) :vertex state))))
        (when (= source target)
          (error 'geometry-error :context "soldagem de vértices"
                 :message "Origem e destino precisam ser vértices distintos."))
        (when (gethash source sources)
          (error 'geometry-error :context "soldagem de vértices"
                 :message "Um vértice de origem aparece mais de uma vez."))
        (setf (gethash source sources) t)
        (push (cons source target) pairs)))
    (setf pairs (nreverse pairs))
    (let ((source-set (make-hash-table)))
      (dolist (pair pairs) (setf (gethash (car pair) source-set) t))
      (when (some (lambda (pair) (gethash (cdr pair) source-set)) pairs)
        (error 'geometry-error :context "soldagem de vértices"
               :message "Destinos não podem também ser origens no mesmo lote.")))
    pairs))

(defun weld-vertices (mesh mapping)
  "Mapeia vértices de origem para destinos e publica somente se a malha continuar manifold."
  (%with-mesh-edit (mesh state)
    (let* ((pairs (%mapping-pairs mesh state mapping))
           (map (make-hash-table)) (faces (%state-faces state)))
      (dolist (pair pairs) (setf (gethash (car pair) map) (cdr pair)))
      (dolist (face-index (%arena-active-indices faces))
        (let* ((face (aref (%arena-items faces) face-index))
               (mapped (mapcar (lambda (index) (gethash index map index))
                               (face-record-vertices face)))
               (cleaned (%remove-adjacent-duplicates mapped)))
          (when (/= (length cleaned) (length (remove-duplicates cleaned)))
            (%modeling-error "soldagem de vértices"
                             "A soldagem criaria vértices repetidos não consecutivos em uma face."))
          (if (< (length cleaned) 3)
              (%arena-retire faces face-index)
              (setf (face-record-vertices face) cleaned))))
      (unless (%arena-active-indices faces)
        (%modeling-error "soldagem de vértices" "A soldagem removeria todas as faces."))
      (dolist (pair pairs) (%arena-retire (%state-vertices state) (car pair)))
      (%validate-operation-geometry state)
      (mapcar (lambda (pair) (%make-handle mesh :vertex (cdr pair) state)) pairs))))

(defun %boundary-loop-indices (mesh state loop)
  (unless (and (listp loop) (>= (length loop) 3))
    (error 'geometry-error :context "ponte entre contornos"
           :message "Cada contorno precisa ter ao menos três elementos de borda."))
  (let ((indices
          (mapcar (lambda (element)
                    (if (and (mesh-handle-p element)
                             (eq (mesh-handle-kind element) :half-edge))
                        (multiple-value-bind (half-edge ignored)
                            (%resolve-handle mesh element :half-edge state)
                          (declare (ignore ignored))
                          (unless (null (half-edge-record-face half-edge))
                            (error 'geometry-error :context "ponte entre contornos"
                                   :message "Os identificadores half-edge precisam pertencer ao contorno."))
                          (half-edge-record-origin half-edge))
                        (nth-value 1 (%resolve-handle mesh element :vertex state))))
                  loop)))
    (unless (= (length indices) (length (remove-duplicates indices)))
      (error 'geometry-error :context "ponte entre contornos"
             :message "Um contorno não pode repetir vértices."))
    indices))

(defun %is-boundary-directed-edge-p (state a b)
  (loop for hi in (%arena-active-indices (%state-half-edges state))
        for he = (aref (%arena-items (%state-half-edges state)) hi)
        when (and (null (half-edge-record-face he))
                  (= a (half-edge-record-origin he))
                  (= b (half-edge-record-origin
                        (aref (%arena-items (%state-half-edges state))
                              (half-edge-record-next he))))
                  (half-edge-record-twin he)) return t))

(defun bridge-boundary-loops (mesh first-loop second-loop)
  "Conecta dois contornos de borda orientados, fechando-os com uma faixa de quads."
  (%with-mesh-edit (mesh state)
    (let* ((a (%boundary-loop-indices mesh state first-loop))
           (b (%boundary-loop-indices mesh state second-loop))
           (count (length a)) (faces (%state-faces state)))
      (unless (= count (length b))
        (error 'geometry-error :context "ponte entre contornos"
               :message "Os contornos precisam ter o mesmo número de vértices."))
      (when (or (intersection a b))
        (error 'geometry-error :context "ponte entre contornos"
               :message "Os contornos precisam ser disjuntos."))
      (loop for i below count
            for an = (nth (mod (1+ i) count) a)
            for bn = (nth (mod (1+ i) count) b)
            unless (and (%is-boundary-directed-edge-p state (nth i a) an)
                        (%is-boundary-directed-edge-p state (nth i b) bn))
              do (error 'geometry-error :context "ponte entre contornos"
                        :message "Os vértices precisam formar ciclos de borda na orientação informada."))
      (let* ((state-vertices (%state-vertices state))
             (best-offset 0) (best-cost nil))
        ;; A segunda borda é percorrida ao contrário; escolha a rotação com menor costura.
        (dotimes (offset count)
          (let ((cost
                  (loop for i below count
                        for left = (vertex-record-position
                                    (aref (%arena-items state-vertices) (nth i a)))
                        for right = (vertex-record-position
                                     (aref (%arena-items state-vertices)
                                           (nth (mod (- offset i) count) b)))
                        sum (dot (v- left right) (v- left right)))))
            (when (or (null best-cost) (< cost best-cost))
              (setf best-cost cost best-offset offset))))
        (let ((created nil))
          (loop for i below count
                for next = (mod (1+ i) count)
                for b-current = (nth (mod (- best-offset i) count) b)
                for b-next = (nth (mod (- best-offset next) count) b)
                do (push (%arena-allocate
                          faces (make-face-record
                                 :vertices (list (nth i a) (nth next a) b-next b-current)))
                         created))
          (%validate-operation-geometry state)
          (mapcar (lambda (index) (%make-handle mesh :face index state))
                  (nreverse created)))))))

(defun duplicate-face-region (mesh faces &key (offset '(0d0 0d0 1d0)))
  "Duplica uma região conectada como componente separado e retorna as novas faces."
  (%with-mesh-edit (mesh state)
    (let* ((selected (%selected-face-indices mesh state faces))
           (displacement (%operation-position offset "deslocamento da duplicação"))
           (mapping (make-hash-table)) (new-face-indices nil)
           (vertices (%state-vertices state)) (arena-faces (%state-faces state)))
      (when (zerop (vector-length displacement))
        (error 'geometry-error :context "duplicação de região"
               :message "O deslocamento precisa ser não nulo."))
      (%validate-face-region-connected state selected)
      (dolist (face-index selected)
        (dolist (vertex (face-record-vertices (aref (%arena-items arena-faces) face-index)))
          (unless (gethash vertex mapping)
            (let ((record (aref (%arena-items vertices) vertex)))
              (setf (gethash vertex mapping)
                    (%arena-allocate vertices
                                     (make-vertex-record
                                      :position (v+ (vertex-record-position record) displacement))))))))
      (dolist (face-index selected)
        (let* ((source (aref (%arena-items arena-faces) face-index))
               (new-index (%arena-allocate
                           arena-faces
                           (make-face-record :vertices
                                             (mapcar (lambda (vertex) (gethash vertex mapping))
                                                     (face-record-vertices source))))))
          (push new-index new-face-indices)))
      (%validate-operation-geometry state)
      (mapcar (lambda (index) (%make-handle mesh :face index state))
              (nreverse new-face-indices)))))

(defun create-vertex (mesh position)
  "Cria um vértice isolado; a transação só é aceita se o estado global for válido."
  (let ((point (%operation-position position "posição do vértice")))
    (%with-mesh-edit (mesh state)
      (%make-handle mesh :vertex
                    (%arena-allocate (%state-vertices state)
                                     (make-vertex-record :position point)) state))))

(defun delete-vertex (mesh vertex)
  "Remove somente vértices isolados, pois vértices incidentes exigem edição topológica."
  (%with-mesh-edit (mesh state)
    (multiple-value-bind (record index) (%resolve-handle mesh vertex :vertex state)
      (declare (ignore record))
      (when (%vertex-used-p state index)
        (%modeling-error "remoção de vértice"
                         "Remova ou edite as faces incidentes antes de remover o vértice."))
      (%arena-retire (%state-vertices state) index)
      mesh)))

(defun create-face (mesh vertices)
  "Cria uma face com vértices ordenados e valida a orientação e a manifoldidade."
  (%with-mesh-edit (mesh state)
    (unless (and (listp vertices) (>= (length vertices) 3))
      (error 'geometry-error :context "criação de face"
             :message "Informe ao menos três identificadores de vértice ordenados."))
    (let ((indices (mapcar (lambda (vertex)
                             (nth-value 1 (%resolve-handle mesh vertex :vertex state))) vertices)))
      (unless (= (length indices) (length (remove-duplicates indices)))
        (error 'geometry-error :context "criação de face"
               :message "Uma face não pode repetir vértices."))
      (let ((index (%arena-allocate (%state-faces state)
                                    (make-face-record :vertices indices))))
        (%validate-operation-geometry state)
        (%make-handle mesh :face index state)))))

(defun delete-face (mesh face)
  "Remove uma face se a malha restante ainda for manifold e tiver faces ativas."
  (%with-mesh-edit (mesh state)
    (multiple-value-bind (record index) (%resolve-handle mesh face :face state)
      (declare (ignore record))
      (%arena-retire (%state-faces state) index)
      (when (null (%arena-active-indices (%state-faces state)))
        (%modeling-error "remoção de face" "A malha precisa conservar ao menos uma face."))
      mesh)))

(defun %closed-vertex-star-p (state vertex)
  (let ((incident nil) (boundary nil) (half-edges (%state-half-edges state)))
    (dolist (hi (%arena-active-indices half-edges))
      (let ((he (aref (%arena-items half-edges) hi)))
        (when (and (half-edge-record-face he)
                   (= vertex (half-edge-record-origin he)))
          (setf incident t))
        (when (and (null (half-edge-record-face he))
                   (= vertex (half-edge-record-origin he)))
          (setf boundary t))))
    (and incident (not boundary))))

(defun %star-cap-cycle (pairs)
  (let ((next (make-hash-table)) (vertices nil))
    (dolist (pair pairs)
      (when (gethash (car pair) next)
        (%modeling-error "bevel de vértices" "A estrela selecionada não forma um único ciclo orientado."))
      (setf (gethash (car pair) next) (cdr pair))
      (pushnew (car pair) vertices))
    (unless (= (hash-table-count next) (length vertices))
      (%modeling-error "bevel de vértices" "A estrela selecionada está desconectada."))
    (let ((start (first vertices)) (cycle nil) (current (first vertices)))
      (loop repeat (1+ (length vertices))
            do (when (member current cycle)
                 (unless (eql current start)
                   (%modeling-error "bevel de vértices" "O ciclo de bevel se fecha prematuramente."))
                 (return))
               (push current cycle)
               (setf current (gethash current next))
               (unless current
                 (%modeling-error "bevel de vértices" "O ciclo de bevel não fecha.")))
      (setf cycle (nreverse cycle))
      (unless (and (eql current start) (= (length cycle) (hash-table-count next)))
        (%modeling-error "bevel de vértices" "A estrela selecionada não forma um único ciclo."))
      cycle)))

(defun %bevel-cut-vertex (state center neighbor fraction cache)
  (or (gethash (list center neighbor) cache)
      (let* ((vertices (%state-vertices state))
             (center-position (vertex-record-position (aref (%arena-items vertices) center)))
             (neighbor-position (vertex-record-position (aref (%arena-items vertices) neighbor)))
             (index (%arena-allocate
                     vertices
                     (make-vertex-record
                      :position (v+ center-position
                                    (v* (coerce fraction 'double-float)
                                        (v- neighbor-position center-position)))))))
        (setf (gethash (list center neighbor) cache) index))))

(defun bevel-vertices (mesh vertices &key (fraction 0.25d0))
  "Trunca estrelas internas fechadas ao longo das arestas e cria caps orientados."
  (unless (and (%finite-real-p fraction) (< 0 fraction 0.5d0))
    (error 'geometry-error :context "bevel de vértices"
           :message "A fração precisa estar estritamente entre zero e 0,5."))
  (%with-mesh-edit (mesh state)
    (unless (and (listp vertices) vertices)
      (error 'geometry-error :context "bevel de vértices"
             :message "Selecione ao menos um vértice."))
    (let* ((selected (mapcar (lambda (vertex)
                               (nth-value 1 (%resolve-handle mesh vertex :vertex state))) vertices))
           (selected-set (make-hash-table))
           (cut-cache (make-hash-table :test #'equal))
           (face-pairs (make-hash-table))
           (faces (%state-faces state)))
      (unless (= (length selected) (length (remove-duplicates selected)))
        (error 'geometry-error :context "bevel de vértices"
               :message "A seleção não pode repetir vértices."))
      (dolist (vertex selected)
        (unless (%closed-vertex-star-p state vertex)
          (%modeling-error "bevel de vértices" "Cada vértice selecionado precisa ter uma estrela fechada."))
        (setf (gethash vertex selected-set) t))
      ;; Registra os arcos orientados que cada novo cap deve compartilhar com faces existentes.
      (dolist (vertex selected)
        (let ((pairs nil))
          (dolist (face-index (%arena-active-indices faces))
            (let* ((face (aref (%arena-items faces) face-index))
                   (loop-vertices (face-record-vertices face))
                   (at (position vertex loop-vertices)))
              (when at
                (let* ((count (length loop-vertices))
                       (previous (nth (mod (1- at) count) loop-vertices))
                       (following (nth (mod (1+ at) count) loop-vertices))
                       (cut-previous (%bevel-cut-vertex state vertex previous fraction cut-cache))
                       (cut-following (%bevel-cut-vertex state vertex following fraction cut-cache)))
                  (push (cons cut-following cut-previous) pairs)))))
          (unless pairs
            (%modeling-error "bevel de vértices" "A estrela selecionada não possui faces."))
          (setf (gethash vertex face-pairs) pairs)))
      ;; Cada face mantém sua orientação; vértices selecionados são substituídos por dois cortes.
      (dolist (face-index (%arena-active-indices faces))
        (let* ((face (aref (%arena-items faces) face-index))
               (loop-vertices (face-record-vertices face))
               (count (length loop-vertices)) (replacement nil))
          (loop for i below count
                for current = (nth i loop-vertices)
                for previous = (nth (mod (1- i) count) loop-vertices)
                for following = (nth (mod (1+ i) count) loop-vertices)
                do (if (gethash current selected-set)
                       (progn
                         (push (%bevel-cut-vertex state current previous fraction cut-cache) replacement)
                         (push (%bevel-cut-vertex state current following fraction cut-cache) replacement))
                       (push current replacement)))
          (setf (face-record-vertices face) (nreverse replacement))))
      (let ((cap-indices nil))
        (dolist (vertex selected)
          (push (%arena-allocate
                 faces (make-face-record :vertices (%star-cap-cycle (gethash vertex face-pairs))))
                cap-indices))
        (%validate-operation-geometry state)
        (mapcar (lambda (index) (%make-handle mesh :face index state))
                (nreverse cap-indices))))))
