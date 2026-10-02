(in-package #:sgeo.geometry)

(defun %positive-finite-double (value context)
  (unless (%finite-real-p value)
    (error 'validation-error :context context :message "O valor precisa ser real e finito."))
  (let ((number (coerce value 'double-float)))
    (unless (and (> number 0d0) (<= number most-positive-double-float))
      (error 'validation-error :context context :message "O valor precisa ser positivo e finito."))
    number))

(defun %positive-integer (value context minimum)
  (unless (and (integerp value) (>= value minimum))
    (error 'validation-error :context context
           :message (format nil "O valor precisa ser um inteiro maior ou igual a ~D." minimum)))
  value)

(defun %make-position-list (positions)
  (coerce positions 'vector))

(defun make-half-edge-box (&key (size 1d0) (name "Caixa topológica") metadata)
  "Cria uma caixa fechada com oito vértices e seis faces quadrilaterais."
  (let* ((dimensions (if (realp size) (list size size size)
                         (if (and (typep size 'sequence) (= (length size) 3))
                             (coerce size 'list) nil)))
         (dimensions (and dimensions (mapcar (lambda (v) (%positive-finite-double v "tamanho da caixa")) dimensions))))
    (unless dimensions
      (error 'validation-error :context "tamanho da caixa"
             :message "O tamanho precisa ser um número ou uma sequência com três componentes."))
    (let* ((hx (/ (first dimensions) 2d0)) (hy (/ (second dimensions) 2d0)) (hz (/ (third dimensions) 2d0))
           (positions (list (list (- hx) (- hy) (- hz)) (list hx (- hy) (- hz))
                            (list hx hy (- hz)) (list (- hx) hy (- hz))
                            (list (- hx) (- hy) hz) (list hx (- hy) hz)
                            (list hx hy hz) (list (- hx) hy hz)))
           (faces '((0 3 2 1) (4 5 6 7) (0 1 5 4) (1 2 6 5) (2 3 7 6) (3 0 4 7))))
      (make-half-edge-mesh :positions (%make-position-list positions) :faces faces :name name :metadata metadata))))

(defun make-sphere (&key (radius 1d0) (segments 16) (rings 8) (name "Esfera") metadata)
  "Cria uma esfera UV com vértices únicos nos polos e sem costura duplicada."
  (let ((radius (%positive-finite-double radius "raio da esfera")))
    (%positive-integer segments "segmentos da esfera" 3)
    (%positive-integer rings "anéis da esfera" 2)
    (let ((positions (list (list 0d0 radius 0d0))) (faces nil))
      (loop for ring from 1 below rings
            for phi = (* pi (/ ring rings))
            do (loop for segment below segments
                     for theta = (* 2d0 pi (/ segment segments))
                     do (push (list (* radius (sin phi) (cos theta))
                                    (* radius (cos phi))
                                    (* radius (sin phi) (sin theta))) positions)))
      (setf positions (nreverse positions))
      (let ((bottom (length positions))) (setf positions (append positions (list (list 0d0 (- radius) 0d0))))
        (loop for segment below segments
              for current = (1+ segment)
              for next = (1+ (mod (1+ segment) segments))
              do (push (list 0 next current) faces))
        (loop for ring from 0 below (- rings 2) do
          (let ((upper-start (1+ (* ring segments))) (lower-start (+ 1 (* (1+ ring) segments))))
            (loop for segment below segments
                  for next = (mod (1+ segment) segments)
                  for a = (+ upper-start segment) for b = (+ upper-start next)
                  for c = (+ lower-start next) for d = (+ lower-start segment)
                  do (push (list a b c d) faces))))
        (let ((last-ring-start (+ 1 (* (- rings 2) segments))))
          (loop for segment below segments
                for next = (mod (1+ segment) segments)
                do (push (list (+ last-ring-start segment) (+ last-ring-start next) bottom) faces)))
        (make-half-edge-mesh :positions (%make-position-list positions) :faces (nreverse faces)
                             :name name :metadata metadata)))))

(defun make-cylinder (&key (radius 1d0) (height 2d0) (segments 16) (capped-p t)
                        (name "Cilindro") metadata)
  "Cria cilindro no eixo Y, com tampas poligonais opcionais."
  (let ((radius (%positive-finite-double radius "raio do cilindro"))
        (height (%positive-finite-double height "altura do cilindro")))
    (%positive-integer segments "segmentos do cilindro" 3)
    (unless (member capped-p '(nil t))
      (error 'validation-error :context "tampas do cilindro" :message "capped-p precisa ser verdadeiro ou falso."))
    (let* ((half (/ height 2d0))
           (positions (loop for y in (list (- half) half) append
                            (loop for segment below segments
                                  for theta = (* 2d0 pi (/ segment segments))
                                  collect (list (* radius (cos theta)) y (* radius (sin theta))))))
           (faces nil))
      (loop for segment below segments
            for next = (mod (1+ segment) segments)
            do (push (list segment (+ segments segment) (+ segments next) next) faces))
      (when capped-p
        (push (loop for segment below segments collect segment) faces)
        (push (loop for segment downfrom (1- segments) to 0 collect (+ segments segment)) faces))
      (make-half-edge-mesh :positions (%make-position-list positions) :faces (nreverse faces)
                           :name name :metadata metadata))))

(defun make-grid (&key (width 2d0) (depth 2d0) (columns 2) (rows 2)
                    (name "Grade") metadata)
  "Cria uma grade aberta no plano XZ, orientada para +Y."
  (let ((width (%positive-finite-double width "largura da grade"))
        (depth (%positive-finite-double depth "profundidade da grade")))
    (%positive-integer columns "colunas da grade" 2)
    (%positive-integer rows "linhas da grade" 2)
    (let* ((positions (loop for row below rows append
                            (loop for column below columns
                                  collect (list (- (* width (/ column (1- columns))) (/ width 2d0))
                                                0d0
                                                (- (* depth (/ row (1- rows))) (/ depth 2d0))))))
           (faces (loop for row below (1- rows) append
                        (loop for column below (1- columns)
                              for current = (+ column (* row columns))
                              collect (list current (+ current columns) (+ current columns 1) (+ current 1))))))
      (make-half-edge-mesh :positions (%make-position-list positions) :faces faces :name name :metadata metadata))))

(defun make-torus (&key (major-radius 2d0) (minor-radius 0.5d0) (segments 16) (sides 8)
                     (name "Toro") metadata)
  "Cria toro fechado com índices periódicos compartilhados e gênero um."
  (let ((major-radius (%positive-finite-double major-radius "raio maior do toro"))
        (minor-radius (%positive-finite-double minor-radius "raio menor do toro")))
    (unless (> major-radius minor-radius)
      (error 'validation-error :context "raios do toro" :message "O raio maior precisa superar o raio menor."))
    (%positive-integer segments "segmentos do toro" 3)
    (%positive-integer sides "lados do toro" 3)
    (let* ((positions (loop for segment below segments append
                            (loop for side below sides
                                  for u = (* 2d0 pi (/ segment segments))
                                  for v = (* 2d0 pi (/ side sides))
                                  for radial = (+ major-radius (* minor-radius (cos v)))
                                  collect (list (* radial (cos u)) (* minor-radius (sin v)) (* radial (sin u))))))
           (faces (loop for segment below segments append
                        (loop for side below sides
                              for next-segment = (mod (1+ segment) segments)
                              for next-side = (mod (1+ side) sides)
                              for a = (+ (* segment sides) side)
                              for b = (+ (* next-segment sides) side)
                              for c = (+ (* next-segment sides) next-side)
                              for d = (+ (* segment sides) next-side)
                              collect (list a d c b)))))
      (make-half-edge-mesh :positions (%make-position-list positions) :faces faces :name name :metadata metadata))))
