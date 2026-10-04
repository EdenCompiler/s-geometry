;;;; Auxiliares compartilhados pelos processos da demonstração M4.
(defun m4-check (value description)
  "Interrompe a demonstração se uma propriedade observável não for verdadeira."
  (unless value (error "M4: ~A" description)) value)

(defun m4-read-data (path)
  (with-open-file (stream path)
    (let ((*read-eval* nil)) (read stream))))

(defun m4-write-data (path data)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede)
    (let ((*print-readably* t) (*print-pretty* t)) (prin1 data stream) (terpri stream))))

(defun m4-canonical-scene (data)
  "Normaliza IDs locais sem perder as referências compartilhadas da cena."
  (let* ((result (copy-tree data)) (body (rest result))
         (objects (getf body :objects)) (geometries (getf body :geometries))
         (materials (getf body :materials))
         (object-ids (make-hash-table)) (geometry-ids (make-hash-table)) (material-ids (make-hash-table)))
    (loop for record in objects for id from 1 do (setf (gethash (getf record :id) object-ids) id))
    (loop for record in geometries for id from 1 do (setf (gethash (getf record :id) geometry-ids) id))
    (loop for record in materials for id from 1 do (setf (gethash (getf record :id) material-ids) id))
    (dolist (record objects)
      (setf (getf record :id) (gethash (getf record :id) object-ids))
      (when (getf record :parent-id) (setf (getf record :parent-id) (gethash (getf record :parent-id) object-ids)))
      (when (getf record :geometry-id) (setf (getf record :geometry-id) (gethash (getf record :geometry-id) geometry-ids)))
      (when (getf record :material-id) (setf (getf record :material-id) (gethash (getf record :material-id) material-ids))))
    (dolist (record geometries) (setf (getf record :id) (gethash (getf record :id) geometry-ids)))
    (dolist (record materials) (setf (getf record :id) (gethash (getf record :id) material-ids)))
    (setf (getf body :root-id) (gethash (getf body :root-id) object-ids)
          (getf body :camera-id) (gethash (getf body :camera-id) object-ids)
          (getf body :selection-id) (gethash (getf body :selection-id) object-ids))
    result))

(defun m4-data-equivalent-p (a b)
  "Compara dados persistidos tolerando apenas arredondamento de números reais."
  (cond ((and (realp a) (realp b)) (<= (abs (- a b)) (* 1d-8 (max 1d0 (abs a) (abs b)))))
        ((and (consp a) (consp b)) (and (m4-data-equivalent-p (car a) (car b))
                                       (m4-data-equivalent-p (cdr a) (cdr b))))
        ((and (vectorp a) (vectorp b) (not (stringp a)) (not (stringp b)))
         (and (= (length a) (length b)) (every #'m4-data-equivalent-p a b)))
        (t (equal a b))))

(defun m4-fragment-source (kind)
  "Cria fontes para substituição válida e falhas distintas do compilador/construtor."
  (let* ((sources (sgeo.render:standard-shader-sources :pbr))
         (fragment (getf sources :fragment))
         (declarations (copy-tree (sgeo.shader:shader-definition-declarations fragment)))
         (body (copy-tree (sgeo.shader:shader-definition-source fragment))))
    (labels ((tint (form)
               (cond ((and (consp form) (eq (first form) :color))
                      (list :color (list '* (second form) '(vec4 1.0 0.25 0.25 1.0))))
                     ((consp form) (mapcar #'tint form)) (t form))))
      (ecase kind
        (:tinted (setf body (mapcar #'tint body)))
        (:bad-source (setf body '((:color (unsupported-shader-operation 1.0)))))
        (:bad-stage (remf sources :fragment) (return-from m4-fragment-source sources))
        (:bad-layout
         (let ((sampler (find-if (lambda (declaration) (eq (second declaration) :sampler2d)) declarations)))
           (setf (second (member :binding (cddr sampler))) 2))))
      (setf (getf sources :fragment)
            (list* :fragment (sgeo.shader:shader-definition-name fragment) declarations body))
      sources)))
