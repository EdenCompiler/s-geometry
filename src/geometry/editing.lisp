(in-package #:sgeo.geometry)

(defun mesh-polygon-data (mesh)
  "Copia posições e ciclos compactos sob o mesmo lock da malha."
  (%with-kernel-lock (mesh)
    (let* ((state (%mesh-state mesh))
           (indices (%arena-active-indices (%state-vertices state)))
           (mapping (make-hash-table)))
      (loop for index in indices for compact from 0
            do (setf (gethash index mapping) compact))
      (values
       (map 'vector (lambda (index)
                      (copy-seq (vertex-record-position
                                 (aref (%arena-items (%state-vertices state)) index)))) indices)
       (loop for index in (%arena-active-indices (%state-faces state))
             collect (mapcar (lambda (vertex) (gethash vertex mapping))
                             (face-record-vertices
                              (aref (%arena-items (%state-faces state)) index))))))))

(defun replace-half-edge-mesh (target source)
  "Publica polígonos validados na mesma malha e invalida todos os handles antigos."
  (unless (and (typep target 'half-edge-mesh) (typep source 'half-edge-mesh))
    (error 'geometry-error :context "substituição de malha" :message "Informe duas malhas half-edge."))
  (let ((candidate (%with-kernel-lock (source) (%clone-state (%mesh-state source)))))
    (%validate-operation-geometry candidate)
    (%with-kernel-lock (target)
      (let ((current (%mesh-state target)))
        (dolist (accessor '( %state-vertices %state-faces %state-edges %state-half-edges))
          (let* ((arena (funcall accessor candidate))
                 (items (%arena-items arena))
                 (generations (%arena-generations arena))
                 (old (%arena-generations (funcall accessor current))))
            (loop while (< (length items) (length old))
                  do (vector-push-extend nil items) (vector-push-extend 0 generations))
            (dotimes (index (length generations))
              (setf (aref generations index)
                    (1+ (max (aref generations index)
                             (if (< index (length old)) (aref old index) 0)))))))
        (fill (%arena-items (%state-edges candidate)) nil)
        (fill (%arena-items (%state-half-edges candidate)) nil)
        (clrhash (mesh-state-edge-identities candidate))
        (clrhash (mesh-state-half-edge-identities candidate))
        (%rebuild-topology candidate)
        (%validate-state candidate)
        (setf (%mesh-state target) candidate)
        (touch-object target :geometry-replaced)))
    target))

(defun set-vertex-positions (mesh entries)
  "Move vários vértices em uma transação única, mantendo seus identificadores."
  (%with-mesh-edit (mesh state)
    (let ((seen (make-hash-table)))
      (dolist (entry entries)
        (multiple-value-bind (record index) (%resolve-handle mesh (car entry) :vertex state)
          (when (gethash index seen)
            (error 'geometry-error :context "edição em lote" :message "Um vértice foi informado duas vezes."))
          (setf (gethash index seen) t
                (vertex-record-position record) (%operation-position (cdr entry) "edição em lote")))))
    (%validate-operation-geometry state)
    mesh))

(defun split-face (mesh face vertex-a vertex-b)
  "Insere uma diagonal entre vértices não adjacentes da mesma face."
  (%with-mesh-edit (mesh state)
    (let* ((record (%resolve-handle mesh face :face state))
           (a (nth-value 1 (%resolve-handle mesh vertex-a :vertex state)))
           (b (nth-value 1 (%resolve-handle mesh vertex-b :vertex state)))
           (cycle (face-record-vertices record))
           (ia (position a cycle)) (ib (position b cycle)))
      (unless (and ia ib (/= ia ib) (> (abs (- ia ib)) 1)
                   (< (abs (- ia ib)) (1- (length cycle))))
        (error 'geometry-edit-error :context "divisão de face" :message "A diagonal precisa ligar vértices não adjacentes da face."))
      (when (> ia ib) (rotatef ia ib))
      (setf (face-record-vertices record) (subseq cycle ia (1+ ib)))
      (let ((new (%arena-allocate (%state-faces state)
                                 (make-face-record :vertices (append (subseq cycle ib) (subseq cycle 0 (1+ ia)))))))
        (%validate-operation-geometry state)
        (%make-handle mesh :face new state)))))

(defun triangulate-mesh (mesh)
  "Substitui faces por triângulos sem trocar a identidade da malha."
  (%with-mesh-edit (mesh state)
    (dolist (index (%arena-active-indices (%state-faces state)))
      (let ((triangles (%triangulate-face state index)))
        (setf (face-record-vertices (aref (%arena-items (%state-faces state)) index)) (first triangles))
        (dolist (triangle (rest triangles))
          (%arena-allocate (%state-faces state) (make-face-record :vertices triangle)))))
    (%validate-operation-geometry state)
    mesh))

(defun flip-winding (mesh)
  "Inverte todos os ciclos, preservando consistência entre faces incidentes."
  (%with-mesh-edit (mesh state)
    (dolist (index (%arena-active-indices (%state-faces state)))
      (let ((face (aref (%arena-items (%state-faces state)) index)))
        (setf (face-record-vertices face) (reverse (face-record-vertices face)))))
    mesh))

(defun extract-connected-components (mesh)
  "Copia cada componente conectado por arestas para uma malha independente."
  (let ((remaining (mesh-faces mesh)) (components nil))
    (loop while remaining
          for region = (connected-face-region mesh (first remaining))
          do (setf remaining (set-difference remaining region :test #'equalp))
             (let* ((vertices (remove-duplicates (mapcan (lambda (face) (face-vertices mesh face)) region) :test #'equalp))
                    (mapping (make-hash-table :test #'equalp)))
               (loop for vertex in vertices for index from 0 do (setf (gethash vertex mapping) index))
               (push (make-half-edge-mesh
                      :positions (mapcar (lambda (vertex) (vertex-position mesh vertex)) vertices)
                      :faces (mapcar (lambda (face) (mapcar (lambda (vertex) (gethash vertex mapping))
                                                          (face-vertices mesh face))) region))
                     components)))
    (nreverse components)))

(defun mesh-volume (mesh)
  "Calcula volume assinado; requer malha fechada com orientação consistente."
  (when (some (lambda (edge) (boundary-edge-p mesh edge)) (mesh-edges mesh))
    (error 'geometry-error :context "volume" :message "O volume exige uma superfície fechada."))
  (%with-kernel-lock (mesh)
    (let ((origin (vertex-position mesh (first (mesh-vertices mesh)))))
      (loop for face in (mesh-faces mesh) sum
            (loop for triangle in (triangulate-face mesh face)
                  for points = (mapcar (lambda (vertex) (v- (vertex-position mesh vertex) origin)) triangle)
                  sum (/ (dot (first points) (cross (second points) (third points))) 6d0))))))
