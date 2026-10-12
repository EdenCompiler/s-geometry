(in-package #:sgeo.advanced)

;; Predicados e interseções usam racionais exatos das coordenadas de entrada.
;; Só a publicação final converte as construções de volta ao formato do núcleo.
(defun %r+ (a b) (mapcar #'+ a b))
(defun %r- (a b) (mapcar #'- a b))
(defun %r* (s a) (mapcar (lambda (x) (* s x)) a))
(defun %rdot (a b) (reduce #'+ (mapcar #'* a b)))
(defun %rcross (a b)
  (list (- (* (second a) (third b)) (* (third a) (second b)))
        (- (* (third a) (first b)) (* (first a) (third b)))
        (- (* (first a) (second b)) (* (second a) (first b)))))
(defstruct (%csg-plane (:constructor %plane (normal distance))) normal distance)
(defstruct (%csg-polygon (:constructor %polygon (vertices plane owner))) vertices plane owner)
(defstruct (%csg-node (:constructor %node ())) plane polygons front back)
(defvar *boolean-input-resolution* nil)

(defun %publication-cycles (polygons cycles points)
  "Conforma construções exatas à precisão double do núcleo antes de publicar."
  (let* ((span (loop for axis below 3 maximize
                    (- (loop for p in points maximize (nth axis p))
                       (loop for p in points minimize (nth axis p)))))
         (magnitude (loop for p in points maximize (reduce #'max p :key #'abs)))
         ;; A margem cobre arredondamento das construções; entradas pequenas a limitam.
         (epsilon (min (or (and *boolean-input-resolution* (* 1d-6 *boolean-input-resolution*))
                           most-positive-double-float)
                       (max (* 64 double-float-epsilon (coerce span 'double-float))
                            (* 2 double-float-epsilon (coerce magnitude 'double-float)))))
         (threshold (rational epsilon))
         (grid (make-hash-table :test #'equal))
         (mapping (make-hash-table :test #'equal))
         (clean-cycles nil) (owners nil))
    (when (zerop threshold)
      (error 'sgeo.geometry:geometry-error :context "precisão booleana"
             :message "As construções não cabem na precisão do núcleo."))
    (dolist (point points)
      (let* ((cell (mapcar (lambda (x) (floor (/ x threshold))) point))
             (representative
               (loop for dx from -1 to 1 thereis
                 (loop for dy from -1 to 1 thereis
                   (loop for dz from -1 to 1 thereis
                     (find-if (lambda (candidate)
                                (every (lambda (a b) (<= (abs (- a b)) threshold)) point candidate))
                              (gethash (%r+ cell (list dx dy dz)) grid)))))))
        (setf (gethash point mapping) (or representative point))
        (unless representative (push point (gethash cell grid)))))
    (loop for cycle in cycles for polygon in polygons
          for merged = (sgeo.geometry::%remove-adjacent-duplicates
                        (mapcar (lambda (p) (gethash p mapping)) cycle))
          when (and (>= (length merged) 3) (%points-plane merged))
            do (push merged clean-cycles) (push (%csg-polygon-owner polygon) owners))
    (unless clean-cycles
      (error 'sgeo.geometry:geometry-edit-error :context "precisão booleana"
             :message "Um resultado não vazio colapsaria ao ser convertido ao formato do núcleo."))
    (values (nreverse clean-cycles) (nreverse owners))))

(defun %points-plane (vertices)
  (let* ((origin (first vertices))
         (normal (loop for i from 1 below (1- (length vertices))
                       for n = (%rcross (%r- (nth i vertices) origin)
                                        (%r- (nth (1+ i) vertices) origin))
                       unless (every #'zerop n) return n)))
    (when normal (%plane normal (%rdot normal origin)))))
(defun %plane-distance (plane point)
  (- (%rdot (%csg-plane-normal plane) point) (%csg-plane-distance plane)))
(defun %reverse-polygon (polygon)
  (%polygon (reverse (%csg-polygon-vertices polygon))
            (%plane (%r* -1 (%csg-plane-normal (%csg-polygon-plane polygon)))
                    (- (%csg-plane-distance (%csg-polygon-plane polygon))))
            (%csg-polygon-owner polygon)))

(defun %split-polygon (plane polygon)
  "Separa ciclos com classificação exata e mantém a orientação original."
  (let* ((vertices (%csg-polygon-vertices polygon))
         (distances (mapcar (lambda (point) (%plane-distance plane point)) vertices))
         (front (some #'plusp distances)) (back (some #'minusp distances)))
    (cond
      ((and (not front) (not back))
       (if (plusp (%rdot (%csg-plane-normal plane)
                        (%csg-plane-normal (%csg-polygon-plane polygon))))
           (values :coplanar-front (list polygon) nil)
           (values :coplanar-back nil (list polygon))))
      ((not back) (values :front (list polygon) nil))
      ((not front) (values :back nil (list polygon)))
      (t
       (let ((front-points nil) (back-points nil))
         (loop for a in vertices for b in (append (rest vertices) (list (first vertices)))
               for da in distances for db in (append (rest distances) (list (first distances)))
               do (unless (minusp da) (push a front-points))
                  (unless (plusp da) (push a back-points))
                  (when (minusp (* da db))
                    (let ((point (%r+ a (%r* (/ da (- da db)) (%r- b a)))))
                      (push point front-points) (push point back-points))))
         (values :spanning
                 (when (>= (length front-points) 3)
                   (list (%polygon (nreverse front-points) (%csg-polygon-plane polygon) (%csg-polygon-owner polygon))))
                 (when (>= (length back-points) 3)
                   (list (%polygon (nreverse back-points) (%csg-polygon-plane polygon) (%csg-polygon-owner polygon))))))))))

(defun %bsp-build (node polygons)
  (when polygons
    (unless (%csg-node-plane node) (setf (%csg-node-plane node) (%csg-polygon-plane (first polygons))))
    (let ((front nil) (back nil))
      (dolist (polygon polygons)
        (multiple-value-bind (kind fp bp) (%split-polygon (%csg-node-plane node) polygon)
          (if (member kind '(:coplanar-front :coplanar-back))
              (push polygon (%csg-node-polygons node))
              (setf front (nconc fp front) back (nconc bp back)))))
      (when front
        (unless (%csg-node-front node) (setf (%csg-node-front node) (%node)))
        (%bsp-build (%csg-node-front node) front))
      (when back
        (unless (%csg-node-back node) (setf (%csg-node-back node) (%node)))
        (%bsp-build (%csg-node-back node) back))))
  node)
(defun %bsp-polygons (node)
  (when node (append (%csg-node-polygons node)
                     (%bsp-polygons (%csg-node-front node)) (%bsp-polygons (%csg-node-back node)))))
(defun %bsp-invert (node)
  (when node
    (setf (%csg-node-polygons node) (mapcar #'%reverse-polygon (%csg-node-polygons node)))
    (when (%csg-node-plane node)
      (let ((plane (%csg-node-plane node)))
        (setf (%csg-node-plane node) (%plane (%r* -1 (%csg-plane-normal plane)) (- (%csg-plane-distance plane))))))
    (%bsp-invert (%csg-node-front node)) (%bsp-invert (%csg-node-back node))
    (rotatef (%csg-node-front node) (%csg-node-back node)))
  node)
(defun %bsp-clip-polygons (node polygons)
  (if (or (null node) (null (%csg-node-plane node))) polygons
      (let ((front nil) (back nil))
        (dolist (polygon polygons)
          (multiple-value-bind (kind fp bp) (%split-polygon (%csg-node-plane node) polygon)
            (declare (ignore kind))
            (setf front (nconc fp front) back (nconc bp back))))
        (setf front (if (%csg-node-front node) (%bsp-clip-polygons (%csg-node-front node) front) front)
              back (when (%csg-node-back node) (%bsp-clip-polygons (%csg-node-back node) back)))
        (nconc front back))))
(defun %bsp-clip-to (node other)
  (when node
    (setf (%csg-node-polygons node) (%bsp-clip-polygons other (%csg-node-polygons node)))
    (%bsp-clip-to (%csg-node-front node) other) (%bsp-clip-to (%csg-node-back node) other))
  node)

(defun solid-mesh-p (mesh)
  "Verifica a topologia fechada e o volume orientado de um sólido poligonal."
  (and (typep mesh 'sgeo.geometry:half-edge-mesh)
       (handler-case
           (sgeo.geometry::%with-kernel-lock (mesh)
             (sgeo.geometry:validate-mesh mesh)
             (and (not (some (lambda (edge) (sgeo.geometry:boundary-edge-p mesh edge))
                             (sgeo.geometry:mesh-edges mesh)))
                  (let ((origin (map 'list #'rational
                                     (sgeo.geometry:vertex-position mesh (first (sgeo.geometry:mesh-vertices mesh))))))
                    (plusp
                     (loop for face in (sgeo.geometry:mesh-faces mesh) sum
                           (loop for triangle in (sgeo.geometry:triangulate-face mesh face)
                                 for points = (mapcar (lambda (v)
                                                       (%r- (map 'list #'rational (sgeo.geometry:vertex-position mesh v)) origin))
                                                     triangle)
                                 sum (%rdot (first points) (%rcross (second points) (third points)))))))))
         (error () nil))))

(defun %mesh-polygons (mesh owner)
  (unless (solid-mesh-p mesh)
    (error 'sgeo.geometry:geometry-error :context "booleano de malha"
           :message "Os operandos precisam ser superfícies fechadas orientadas para fora."))
  (%validate-solid-embedding mesh)
  (loop for face in (sgeo.geometry:mesh-faces mesh) append
        (loop for triangle in (sgeo.geometry:triangulate-face mesh face)
              for points = (mapcar (lambda (vertex)
                                     (map 'list #'rational (sgeo.geometry:vertex-position mesh vertex))) triangle)
              collect (%polygon points (%points-plane points) owner))))

(defun %point-on-segment-parameter (point a b)
  (let* ((delta (%r- b a)) (axis (position-if-not #'zerop delta)))
    (when axis
      (let ((parameter (/ (- (nth axis point) (nth axis a)) (nth axis delta))))
        (when (and (< 0 parameter 1) (equal point (%r+ a (%r* parameter delta))))
          parameter)))))

(defun %boolean-edge-pairs (edge members cycles)
  "Emparelha folhas pelo setor material ao redor da aresta, inclusive em contatos."
  (let* ((direction (%r- (second edge) (first edge)))
         (axis (find-if (lambda (candidate) (not (every #'zerop (%rcross direction candidate))))
                       '((1 0 0) (0 1 0) (0 0 1))))
         (u (%rcross direction axis)) (v (%rcross direction u))
         (rays
           (loop for fi in members
                 for cycle = (nth fi cycles)
                 for forward = (loop for a in cycle for b in (append (rest cycle) (list (first cycle)))
                                     when (and (equal a (first edge)) (equal b (second edge))) return t)
                 for normal = (%csg-plane-normal (%points-plane cycle))
                 for radial = (%rcross normal (%r* (if forward 1 -1) direction))
                 collect (list fi forward (%rdot radial u) (%rdot radial v)))))
    (labels ((upper (ray) (or (plusp (fourth ray))
                             (and (zerop (fourth ray)) (not (minusp (third ray))))))
             (less-angle (a b)
               (cond ((not (eql (upper a) (upper b))) (upper a))
                     (t (let ((turn (- (* (third a) (fourth b)) (* (fourth a) (third b)))))
                          (if (zerop turn) (< (first a) (first b)) (plusp turn)))))))
      (setf rays (sort rays #'less-angle))
      (loop for position below (length rays)
            for ray = (nth position rays)
            unless (second ray) collect
              (let ((next (nth (mod (1+ position) (length rays)) rays)))
                (unless (second next)
                  (error 'sgeo.geometry:geometry-edit-error :context "folhas booleanas"
                         :message "Os setores materiais não alternam ao redor de uma aresta."))
                (list (first ray) (first next)))))))

(defun %polygons-to-mesh (polygons)
  "Repara junções em T por construção exata e separa contatos entre componentes."
  (when (null polygons) (return-from %polygons-to-mesh nil))
  (let* ((points (remove-duplicates (mapcan (lambda (p) (copy-list (%csg-polygon-vertices p))) polygons) :test #'equal))
         (cycles (mapcar
                  (lambda (polygon)
                    (loop for a in (%csg-polygon-vertices polygon)
                          for b in (append (rest (%csg-polygon-vertices polygon)) (list (first (%csg-polygon-vertices polygon))))
                          append (cons a (mapcar #'cdr
                                                (sort (loop for point in points
                                                            for parameter = (%point-on-segment-parameter point a b)
                                                            when parameter collect (cons parameter point))
                                                      #'< :key #'car)))))
                  polygons))
         (edge-faces (make-hash-table :test #'equal))
         (owners nil)
         (parents nil)
         (vertices (make-array 0 :adjustable t :fill-pointer 0))
         (mapping (make-hash-table :test #'equal))
         (faces nil))
    (multiple-value-setq (cycles owners) (%publication-cycles polygons cycles points))
    (setf parents (make-array (length cycles)))
    (dotimes (i (length cycles)) (setf (aref parents i) i))
    (labels ((root (i) (if (= i (aref parents i)) i (setf (aref parents i) (root (aref parents i)))))
             (join (a b) (setf (aref parents (root b)) (root a)))
             (key (a b) (if (string< (prin1-to-string a) (prin1-to-string b)) (list a b) (list b a))))
      (loop for cycle in cycles for fi from 0 do
        (loop for a in cycle for b in (append (rest cycle) (list (first cycle)))
              do (push fi (gethash (key a b) edge-faces))))
      (maphash (lambda (key members)
                 (if (= (length members) 2)
                     (join (first members) (second members))
                     (dolist (pair (%boolean-edge-pairs key members cycles))
                       (join (first pair) (second pair)))))
               edge-faces)
      (loop for cycle in cycles for fi from 0 do
        (push (loop for point in cycle for key = (list (root fi) point)
                    collect (or (gethash key mapping)
                                (setf (gethash key mapping)
                                      (vector-push-extend (map 'vector (lambda (x) (coerce x 'double-float)) point) vertices))))
              faces)))
    (let ((mesh (sgeo.geometry:make-half-edge-mesh :positions vertices :faces (nreverse faces))))
      (sgeo.geometry:validate-mesh mesh)
      (unless (solid-mesh-p mesh)
        (error 'sgeo.geometry:geometry-edit-error :context "resultado booleano"
               :message "O resultado não pode ser publicado como sólido manifold."))
      (%validate-solid-embedding mesh)
      mesh)))

(defun %boolean-operand (mesh)
  "Valida uma cópia coerente; o resultado nunca compartilha estado com a entrada."
  (when mesh
    (unless (typep mesh 'sgeo.geometry:half-edge-mesh)
      (error 'sgeo.geometry:geometry-error :context "operando booleano"
             :message "Informe uma malha half-edge ou NIL para o conjunto vazio."))
    (multiple-value-bind (positions faces) (sgeo.geometry:mesh-polygon-data mesh)
      (let ((copy (sgeo.geometry:make-half-edge-mesh :positions positions :faces faces)))
        (unless (solid-mesh-p copy)
          (error 'sgeo.geometry:geometry-error :context "operando booleano"
                 :message "O operando precisa ser um sólido fechado orientado para fora."))
        (%validate-solid-embedding copy)
        copy))))

(defun boolean-mesh (operation a b &key target)
  "Calcula CSG com predicados exatos e publicação double; NIL representa vazio."
  (unless (member operation '(:union :intersection :difference))
    (error 'validation-error :context "booleano" :message "Operação CSG desconhecida."))
  (when (and target (not (typep target 'sgeo.geometry:half-edge-mesh)))
    (error 'sgeo.geometry:geometry-error :context "destino booleano"
           :message "O destino precisa ser uma malha half-edge."))
  (let* ((target-revision (when target (sgeo.core:object-revision target)))
         (a (%boolean-operand a)) (b (%boolean-operand b))
         (*boolean-input-resolution*
           (let ((lengths
                   (loop for mesh in (remove nil (list a b)) append
                         (loop for edge in (sgeo.geometry:mesh-edges mesh)
                               for vertices = (sgeo.geometry:edge-vertices mesh edge)
                               collect (vector-length
                                        (v- (sgeo.geometry:vertex-position mesh (first vertices))
                                            (sgeo.geometry:vertex-position mesh (second vertices))))))))
             (when lengths (reduce #'min lengths))))
         (result
          (cond ((null a) (when (eq operation :union) b))
                ((null b) (unless (eq operation :intersection) a))
                (t
                 (let ((left (%bsp-build (%node) (%mesh-polygons a 0)))
                       (right (%bsp-build (%node) (%mesh-polygons b 1))))
                   (ecase operation
                     (:union (%bsp-clip-to left right) (%bsp-clip-to right left)
                             (%bsp-invert right) (%bsp-clip-to right left) (%bsp-invert right)
                             (%bsp-build left (%bsp-polygons right)))
                     (:difference (%bsp-invert left) (%bsp-clip-to left right)
                                  (%bsp-clip-to right left) (%bsp-invert right)
                                  (%bsp-clip-to right left) (%bsp-invert right)
                                  (%bsp-build left (%bsp-polygons right)) (%bsp-invert left))
                     (:intersection (%bsp-invert left) (%bsp-clip-to right left)
                                    (%bsp-invert right) (%bsp-clip-to left right)
                                    (%bsp-clip-to right left) (%bsp-build left (%bsp-polygons right))
                                    (%bsp-invert left)))
                   (%polygons-to-mesh (%bsp-polygons left)))))))
    (if target
        (sgeo.geometry::%with-kernel-lock (target)
          (unless (= target-revision (sgeo.core:object-revision target))
            (error 'sgeo.geometry:geometry-edit-error :context "publicação booleana"
                   :message "A malha de destino mudou durante o cálculo; o resultado foi descartado."))
          (if result (sgeo.geometry:replace-half-edge-mesh target result)
              (error 'sgeo.geometry:geometry-edit-error :context "resultado booleano"
                     :message "O conjunto vazio não substitui uma malha não vazia; retire o objeto da cena explicitamente.")))
        result)))

(defun csg-union (a b &key target) (boolean-mesh :union a b :target target))
(defun csg-intersection (a b &key target) (boolean-mesh :intersection a b :target target))
(defun csg-difference (a b &key target) (boolean-mesh :difference a b :target target))
