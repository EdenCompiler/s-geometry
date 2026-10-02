(in-package #:sgeo.scene)

(defclass scene-object (sgeo-object)
  ((parent :initform nil :accessor %scene-object-parent)
   (children :initform nil :accessor %scene-object-children)
   (local-transform :initarg :local-transform :initform (make-transform)
                    :accessor %scene-object-local-transform)
   (visible-p :initarg :visible-p :initform t :reader %visible-p-slot)
   (enabled-p :initarg :enabled-p :initform t :reader %enabled-p-slot)
   (world :initform nil :accessor %scene-object-world))
  (:documentation "Nó vivo da hierarquia de cena com transformação local."))

(defclass simple-material (sgeo-object)
  ((color :initarg :color :initform (make-vec3 0.8d0 0.8d0 0.85d0)
          :reader %material-color-slot)
   (wireframe-p :initarg :wireframe-p :initform nil :reader %wireframe-slot))
  (:documentation "Material básico com cor uniforme e modo de arame opcional."))

(defclass mesh-object (scene-object)
  ((geometry :initarg :geometry :reader mesh-object-geometry)
   (material :initarg :material :reader %mesh-material-slot))
  (:documentation "Objeto de cena que associa uma malha a um material."))

(defclass camera (scene-object)
  ((target :initarg :target :reader %camera-target-slot)
   (up :initarg :up :reader %camera-up-slot)
   (fov :initarg :fov :reader %camera-fov-slot)
   (near :initarg :near :reader %camera-near-slot)
   (far :initarg :far :reader %camera-far-slot)
   (projection-mode :initarg :projection-mode :initform :perspective
                     :reader %camera-projection-mode-slot)
   (orthographic-height :initarg :orthographic-height :initform 6d0
                        :reader %camera-orthographic-height-slot))
  (:documentation "Câmera em perspectiva ou ortográfica apontada para um alvo."))

(defclass world ()
  ((root :initarg :root :reader world-root)
   (camera :initarg :camera :reader world-camera)
   (running-p :initarg :running-p :initform nil :reader %world-running-p)
   (selection :initform nil :accessor %world-selection)
   (lock :initform (bt:make-recursive-lock "sgeo world") :reader world-lock))
  (:documentation "Cena compartilhada protegida por um bloqueio reentrante."))

(defun scene-object-visible-p (object)
  (%visible-p-slot object))
(defun scene-object-enabled-p (object)
  (%enabled-p-slot object))
(defun scene-object-parent (object)
  "Retorna o pai; mudanças na hierarquia passam por ADD-CHILD ou REPARENT."
  (%scene-object-parent object))
(defun scene-object-children (object)
  "Retorna uma cópia da lista de filhos, preservando suas instâncias vivas."
  (copy-list (%scene-object-children object)))
(defun scene-object-world (object)
  "Retorna o mundo proprietário, definido pelas operações da hierarquia."
  (%scene-object-world object))
(defun simple-material-color (material)
  (%vec3-copy (%material-color-slot material) "cor do material"))
(defun simple-material-wireframe-p (material)
  (%wireframe-slot material))
(defun mesh-object-material (object)
  (%mesh-material-slot object))
(defun scene-object-local-transform (object)
  "Retorna uma cópia da transformação local; edições passam pelos mutadores do objeto."
  (let ((transform (%scene-object-local-transform object)))
    (make-transform :position (transform-position transform)
                    :rotation (transform-rotation transform)
                    :scale (transform-scale transform))))
(defun camera-target (camera)
  (copy-seq (%camera-target-slot camera)))
(defun camera-up (camera)
  (copy-seq (%camera-up-slot camera)))
(defun camera-fov (camera)
  (%camera-fov-slot camera))
(defun camera-near (camera)
  (%camera-near-slot camera))
(defun camera-far (camera)
  (%camera-far-slot camera))
(defun camera-projection-mode (camera)
  (%camera-projection-mode-slot camera))
(defun camera-orthographic-height (camera)
  (%camera-orthographic-height-slot camera))

(defmacro with-world-lock (world-designator &body body)
  "Executa BODY enquanto mantém o bloqueio reentrante do mundo."
  (let ((expression (if (and (consp world-designator)
                             (= (length world-designator) 1))
                        (first world-designator)
                        world-designator)))
    `(let ((world-value ,expression))
       (bt:with-recursive-lock-held ((world-lock world-value))
         ,@body))))

(defun world-selection (world)
  (%world-selection world))

(defun world-running-p (world)
  (%world-running-p world))

(defun (setf world-running-p) (value world)
  (with-world-lock (world)
    (setf (slot-value world 'running-p) (not (null value)))))

(defun (setf world-selection) (object world)
  (with-world-lock (world)
    (when (and object (not (eq (scene-object-world object) world)))
      (error 'hierarchy-error :context "seleção do mundo"
             :message "O objeto selecionado precisa pertencer ao mundo."))
    (setf (%world-selection world) object)))

(defun %vec3-copy (value context)
  (unless (and (typep value 'sequence) (= (length value) 3)
               (every #'realp value))
    (error 'validation-error :context context
           :message "O valor precisa conter três componentes reais."))
  (make-vec3 (elt value 0) (elt value 1) (elt value 2)))

(defun %validate-camera-frame (eye target up)
  (let* ((forward (v- target eye))
         (forward-length (vector-length forward))
         (up-length (vector-length up)))
    (when (or (<= forward-length 1d-12) (<= up-length 1d-12)
              (<= (vector-length (cross forward up))
                  (* 1d-12 forward-length up-length)))
      (error 'validation-error :context "orientação da câmera"
             :message "O olho e o alvo precisam ser distintos, e o vetor para cima não pode ser nulo nem paralelo à direção de visão.")))
  t)

(defun %validate-camera-optics (fov near far)
  (unless (and (realp fov) (< 0 fov pi)
               (realp near) (plusp near)
               (realp far) (> far near))
    (error 'validation-error :context "parâmetros da câmera"
           :message "O campo de visão precisa estar entre zero e pi e os planos precisam satisfazer 0 < perto < longe."))
  t)

(defun %camera-positive-double (value context)
  (unless (and (realp value) (> value 0)
               (handler-case (<= value most-positive-double-float)
                 (error () nil)))
    (error 'validation-error :context context :message "O valor precisa ser positivo e finito."))
  (handler-case (coerce value 'double-float)
    (error () (error 'validation-error :context context
                     :message "O valor precisa ser positivo e finito."))))

(defun %coerce-rotation (value)
  (if (typep value 'quaternion)
      (sgeo.math:quaternion-normalize value)
      (let* ((angles (%vec3-copy value "rotação do objeto"))
             (qx (quaternion-from-axis-angle (make-vec3 1d0 0d0 0d0) (vx angles)))
             (qy (quaternion-from-axis-angle (make-vec3 0d0 1d0 0d0) (vy angles)))
             (qz (quaternion-from-axis-angle (make-vec3 0d0 0d0 1d0) (vz angles))))
        (quaternion-multiply qz (quaternion-multiply qy qx)))))

(defun make-scene-object (&key (name "Objeto") position rotation scale
                            (visible-p t) (enabled-p t))
  "Cria um nó de cena e aplica os componentes locais informados."
  (let ((object (make-instance 'scene-object :name name :visible-p visible-p
                               :enabled-p enabled-p)))
    (when position (set-position object position))
    (when rotation (set-rotation object rotation))
    (when scale (set-scale object scale))
    object))

(defun make-material (&key (color (make-vec3 0.8d0 0.8d0 0.85d0)) wireframe-p
                        (name "Material"))
  "Cria um material simples com cor RGB e estado de arame."
  (make-instance 'simple-material :name name :color (%vec3-copy color "cor do material")
                 :wireframe-p (not (null wireframe-p))))

(defun set-material-color (material color)
  "Altera a cor de um material e avança sua revisão."
  (setf (simple-material-color material) color)
  material)

(defun set-material-wireframe (material wireframe-p)
  "Define o modo de arame com estado booleano e avança a revisão."
  (unless (typep material 'simple-material)
    (error 'validation-error :context "modo de arame"
           :message "O valor precisa ser um material simples."))
  (unless (member wireframe-p '(nil t))
    (error 'validation-error :context "modo de arame"
           :message "O estado precisa ser T ou NIL."))
  (setf (simple-material-wireframe-p material) wireframe-p)
  material)

(defun make-mesh-object (geometry &key (name "Malha") material position rotation scale)
  "Cria um objeto de cena para uma malha e um material simples."
  (unless (typep geometry '(or triangle-mesh half-edge-mesh))
    (error 'validation-error :context "geometria do objeto"
           :message "A geometria precisa ser uma malha triangular ou half-edge."))
    (let ((object (make-instance 'mesh-object :name name :geometry geometry
                               :material (or material (make-material)))))
    (when position (set-position object position))
    (when rotation (set-rotation object rotation))
    (when scale (set-scale object scale))
    object))

(defun make-camera (&key (eye (make-vec3 4d0 3d0 6d0))
                      (target (make-vec3 0d0 0d0 0d0))
                      (up (make-vec3 0d0 1d0 0d0))
                      (fov (/ pi 3d0)) (near 0.01d0) (far 1000d0)
                      (projection-mode :perspective) (orthographic-height 6d0)
                      (name "Câmera"))
  "Cria uma câmera orientada para TARGET com projeção perspectiva ou ortográfica."
  (%validate-camera-optics fov near far)
  (unless (member projection-mode '(:perspective :orthographic))
    (error 'validation-error :context "projeção da câmera"
           :message "O modo precisa ser :PERSPECTIVE ou :ORTHOGRAPHIC."))
  (setf orthographic-height (%camera-positive-double
                             orthographic-height "altura ortográfica da câmera"))
  (let* ((eye (%vec3-copy eye "olho da câmera"))
         (target (%vec3-copy target "alvo da câmera"))
         (up (%vec3-copy up "vetor para cima")))
    (%validate-camera-frame eye target up)
    (let ((camera (make-instance 'camera :name name
                                 :target target
                                 :up (normalize up)
                                 :fov (coerce fov 'double-float)
                                 :near (coerce near 'double-float)
                                 :far (coerce far 'double-float)
                                 :projection-mode projection-mode
                                 :orthographic-height orthographic-height)))
    (set-camera-eye camera eye)
      camera)))

(defun camera-eye (camera)
  (local->world camera (make-vec3)))

(defun view-matrix (camera)
  (sgeo.math:look-at-mat4
   (camera-eye camera) (camera-target camera)
   (%camera-up-world camera)))

(defun %camera-up-world (camera)
  (let ((up (transform-direction (world-transform camera) (camera-up camera))))
    (when (<= (vector-length up) 1d-12)
      (error 'validation-error :context "orientação da câmera"
             :message "A transformação da câmera não pode colapsar o vetor para cima."))
    (normalize up)))

(defun projection-matrix (camera aspect)
  (unless (and (realp aspect) (plusp aspect))
    (error 'validation-error :context "proporção da câmera"
           :message "A proporção largura/altura precisa ser positiva."))
  (if (eq (camera-projection-mode camera) :orthographic)
      (let ((half-height (/ (camera-orthographic-height camera) 2d0))
            (half-width (/ (* (camera-orthographic-height camera) aspect) 2d0)))
        (sgeo.math:orthographic-mat4 (- half-width) half-width
                                     (- half-height) half-height
                                     (camera-near camera) (camera-far camera)))
      (sgeo.math:perspective-mat4 (camera-fov camera) aspect
                                  (camera-near camera) (camera-far camera))))

(defun set-camera-eye (camera eye)
  "Move a câmera sem alterar seu alvo."
  (%with-object-world-lock
   camera
   (lambda ()
     (let ((world-eye (%vec3-copy eye "olho da câmera")))
       (%validate-camera-frame world-eye (camera-target camera)
                               (%camera-up-world camera))
       (set-position camera
                     (if (scene-object-parent camera)
                         (transform-point
                          (inverse-mat4 (world-transform (scene-object-parent camera)))
                          world-eye)
                         world-eye)))))
  camera)

(defun set-camera-up (camera up)
  "Define o vetor para cima em coordenadas mundiais da câmera."
  (%with-object-world-lock
   camera
   (lambda ()
     (let* ((world-up (%vec3-copy up "vetor para cima"))
            (local-up (transform-direction (inverse-mat4 (world-transform camera)) world-up)))
       (%validate-camera-frame (camera-eye camera) (camera-target camera) world-up)
       (unless (equalp local-up (%camera-up-slot camera))
         (setf (slot-value camera 'up) local-up)
         (touch-object camera :camera-up-changed)))))
  camera)

(defun set-camera-frame (camera eye target up)
  "Atualiza o referencial completo da câmera em uma única revisão."
  (%with-object-world-lock
   camera
   (lambda ()
     (let* ((world-eye (%vec3-copy eye "olho da câmera"))
            (world-target (%vec3-copy target "alvo da câmera"))
            (world-up (%vec3-copy up "vetor para cima"))
            (parent (scene-object-parent camera))
            (parent-inverse (and parent (inverse-mat4 (world-transform parent))))
            (local-eye (if parent-inverse
                           (transform-point parent-inverse world-eye)
                           world-eye))
            (local-up (transform-direction (inverse-mat4 (world-transform camera)) world-up)))
       (%validate-camera-frame world-eye world-target world-up)
       (unless (and (equalp world-eye (camera-eye camera))
                    (equalp world-target (camera-target camera))
                    (equalp local-up (%camera-up-slot camera)))
         (setf (transform-position (%scene-object-local-transform camera)) local-eye
               (slot-value camera 'target) world-target
               (slot-value camera 'up) local-up)
         (touch-object camera :camera-frame-changed)))))
  camera)

(defun set-camera-projection (camera mode &key (height (camera-orthographic-height camera)))
  "Altera o tipo de projeção e, se informada, a altura ortográfica."
  (unless (member mode '(:perspective :orthographic))
    (error 'validation-error :context "projeção da câmera"
           :message "O modo precisa ser :PERSPECTIVE ou :ORTHOGRAPHIC."))
  (let ((height (%camera-positive-double height "altura ortográfica da câmera")))
    (%with-object-world-lock
     camera
     (lambda ()
       (unless (and (eq mode (%camera-projection-mode-slot camera))
                    (= height (%camera-orthographic-height-slot camera)))
         (setf (slot-value camera 'projection-mode) mode
               (slot-value camera 'orthographic-height) height)
         (touch-object camera :camera-projection-changed)))))
  camera)

(defun set-camera-target (camera target)
  "Altera o alvo para o qual a câmera aponta."
  (setf (camera-target camera) (%vec3-copy target "alvo da câmera"))
  camera)

(defun %camera-offset (camera)
  (v- (camera-eye camera) (camera-target camera)))

(defun orbit-camera (camera dx dy)
  "Orbita ao redor do alvo; DX e DY são deslocamentos angulares em radianos."
  (%with-object-world-lock
   camera
   (lambda ()
  (let* ((offset (%camera-offset camera))
         (radius (vector-length offset)))
    (when (< radius 1d-9)
      (setf offset (make-vec3 0d0 0d0 1d0) radius 1d0))
    (let* ((theta (+ (atan (vx offset) (vz offset)) (coerce dx 'double-float)))
           (phi (max 0.01d0 (min (- pi 0.01d0)
                                (+ (acos (max -1d0 (min 1d0 (/ (vy offset) radius))))
                                   (coerce dy 'double-float)))))
           (new-eye (v+ (camera-target camera)
                        (make-vec3 (* radius (sin phi) (sin theta))
                                   (* radius (cos phi))
                                   (* radius (sin phi) (cos theta))))))
      (set-camera-eye camera new-eye))))))

(defun zoom-camera (camera amount)
  "Amplia a vista ortográfica ou altera a distância da perspectiva."
  (%with-object-world-lock
   camera
   (lambda ()
  (let ((factor (exp (coerce amount 'double-float))))
    (if (eq (camera-projection-mode camera) :orthographic)
        (set-camera-projection camera :orthographic
                               :height (max 0.01d0 (* factor (camera-orthographic-height camera))))
        (let* ((offset (%camera-offset camera))
               (radius (max 0.01d0 (* factor (vector-length offset)))))
          (set-camera-eye camera (v+ (camera-target camera)
                                    (v* (normalize offset) radius)))))))))

(defun pan-camera (camera dx dy)
  "Move o olho e o alvo nos eixos horizontal e vertical da câmera."
  (%with-object-world-lock
   camera
   (lambda ()
  (let* ((forward (normalize (v- (camera-target camera) (camera-eye camera))))
         (right (normalize (cross forward (%camera-up-world camera))))
         (up (normalize (cross right forward)))
         (distance (if (eq (camera-projection-mode camera) :orthographic)
                       (camera-orthographic-height camera)
                       (vector-length (%camera-offset camera))))
         (delta (v+ (v* right (* (coerce dx 'double-float) distance))
                    (v* up (* (coerce dy 'double-float) distance)))))
    (set-camera-eye camera (v+ (camera-eye camera) delta))
    (set-camera-target camera (v+ (camera-target camera) delta))))))

(defun %descendants (object)
  (cons object (mapcan #'%descendants (copy-list (scene-object-children object)))))

(defun %set-world-recursively (object world)
  (setf (%scene-object-world object) world)
  (dolist (child (scene-object-children object))
    (%set-world-recursively child world)))

(defun %world-of-either (first second)
  (or (scene-object-world first) (scene-object-world second)))

(defun %local-matrix (object)
  (transform-matrix (%scene-object-local-transform object)))

(defun world-transform (object)
  "Calcula a matriz mundial multiplicando as transformações dos ancestrais."
  (let ((parent (scene-object-parent object)))
    (if parent
        (mat* (world-transform parent) (%local-matrix object))
        (%local-matrix object))))

(defun local->world (object point)
  "Converte um ponto local do objeto para coordenadas mundiais."
  (transform-point (world-transform object) (%vec3-copy point "ponto local")))

(defun world->local (object point)
  "Converte um ponto mundial para coordenadas locais do objeto."
  (transform-point (inverse-mat4 (world-transform object))
                   (%vec3-copy point "ponto mundial")))

(defun %rotation-matrix->quaternion (r00 r01 r02 r10 r11 r12 r20 r21 r22)
  (let ((trace (+ r00 r11 r22)))
    (cond
      ((plusp trace)
       (let* ((s (* 2d0 (sqrt (+ trace 1d0))))
              (w (/ s 4d0)) (x (/ (- r21 r12) s))
              (y (/ (- r02 r20) s)) (z (/ (- r10 r01) s)))
         (make-quaternion x y z w)))
      ((and (> r00 r11) (> r00 r22))
       (let* ((s (* 2d0 (sqrt (max 0d0 (+ 1d0 r00 (- r11) (- r22))))))
              (w (/ (- r21 r12) s)) (x (/ s 4d0))
              (y (/ (+ r01 r10) s)) (z (/ (+ r02 r20) s)))
         (make-quaternion x y z w)))
      ((> r11 r22)
       (let* ((s (* 2d0 (sqrt (max 0d0 (+ 1d0 r11 (- r00) (- r22))))))
              (w (/ (- r02 r20) s)) (x (/ (+ r01 r10) s))
              (y (/ s 4d0)) (z (/ (+ r12 r21) s)))
         (make-quaternion x y z w)))
      (t
       (let* ((s (* 2d0 (sqrt (max 0d0 (+ 1d0 r22 (- r00) (- r11))))))
              (w (/ (- r10 r01) s)) (x (/ (+ r02 r20) s))
              (y (/ (+ r12 r21) s)) (z (/ s 4d0)))
         (make-quaternion x y z w))))))

(defun %matrix-transform-components (matrix)
  (let* ((column-0 (make-vec3 (aref matrix 0) (aref matrix 1) (aref matrix 2)))
         (column-1 (make-vec3 (aref matrix 4) (aref matrix 5) (aref matrix 6)))
         (column-2 (make-vec3 (aref matrix 8) (aref matrix 9) (aref matrix 10)))
         (sx (vector-length column-0))
         (sy (vector-length column-1))
         (sz (vector-length column-2))
         (determinant (dot column-0 (cross column-1 column-2))))
    (when (or (<= sx 1d-15) (<= sy 1d-15) (<= sz 1d-15))
      (error 'hierarchy-error :context "transformação mundial"
             :message "Uma transformação singular não pode ser preservada ao alterar a hierarquia."))
    ;; A reflexão fica codificada em um eixo de escala para manter a rotação própria.
    (when (minusp determinant)
      (setf sx (- sx)))
    (let* ((r00 (/ (aref matrix 0) sx))
           (r10 (/ (aref matrix 1) sx))
           (r20 (/ (aref matrix 2) sx))
           (r01 (/ (aref matrix 4) sy))
           (r11 (/ (aref matrix 5) sy))
           (r21 (/ (aref matrix 6) sy))
           (r02 (/ (aref matrix 8) sz))
           (r12 (/ (aref matrix 9) sz))
           (r22 (/ (aref matrix 10) sz))
           (tolerance 1d-8)
           (rotation-matrix (%rotation-matrix->quaternion
                             r00 r01 r02 r10 r11 r12 r20 r21 r22)))
      (unless (and (<= (abs (dot (make-vec3 r00 r10 r20) (make-vec3 r01 r11 r21))) tolerance)
                   (<= (abs (dot (make-vec3 r00 r10 r20) (make-vec3 r02 r12 r22))) tolerance)
                   (<= (abs (dot (make-vec3 r01 r11 r21) (make-vec3 r02 r12 r22))) tolerance))
        (error 'hierarchy-error :context "transformação mundial"
               :message "A transformação resultaria em cisalhamento, que não pode ser representado por posição, rotação e escala."))
      (let* ((position (make-vec3 (aref matrix 12) (aref matrix 13) (aref matrix 14)))
             (scale (make-vec3 sx sy sz))
             (reconstructed (transform-matrix (make-transform :position position
                                                              :rotation rotation-matrix
                                                              :scale scale)))
             (matrix-magnitude (loop for index below 12
                                     maximize (abs (aref matrix index)) into maximum
                                     finally (return (max 1d-15 maximum))))
             (max-error (loop for expected across matrix
                              for actual across reconstructed
                              maximize (abs (- expected actual)) into maximum
                              finally (return maximum))))
        (when (> max-error (* tolerance matrix-magnitude))
          (error 'hierarchy-error :context "transformação mundial"
                 :message "A transformação não pode ser preservada como TRS sem cisalhamento."))
        (values position rotation-matrix scale)))))

(defun %assign-transform-components (object position rotation scale)
  (let ((transform (%scene-object-local-transform object)))
    (setf (transform-position transform) position
          (transform-rotation transform) rotation
          (transform-scale transform) scale)))

(defun %with-object-world-lock (object thunk)
  (let ((world (scene-object-world object)))
    (if world (with-world-lock (world) (funcall thunk)) (funcall thunk))))

(defun (setf scene-object-visible-p) (value object)
  "Altera visibilidade sob o bloqueio do mundo e avança a revisão."
  (%with-object-world-lock
   object
   (lambda ()
     (let ((new-value (not (null value))))
       (unless (eql new-value (slot-value object 'visible-p))
         (setf (slot-value object 'visible-p) new-value)
         (touch-object object :visibility-changed))
       new-value))))

(defun (setf scene-object-enabled-p) (value object)
  "Altera habilitação sob o bloqueio do mundo e avança a revisão."
  (%with-object-world-lock
   object
   (lambda ()
     (let ((new-value (not (null value))))
       (unless (eql new-value (slot-value object 'enabled-p))
         (setf (slot-value object 'enabled-p) new-value)
         (touch-object object :enabled-state-changed))
       new-value))))

(defun (setf simple-material-color) (color material)
  "Atualiza a cor do material e avança sua revisão."
  (let ((new-color (%vec3-copy color "cor do material")))
    (unless (equalp new-color (slot-value material 'color))
      (setf (slot-value material 'color) new-color)
      (touch-object material :material-color-changed))
    new-color))

(defun (setf simple-material-wireframe-p) (value material)
  "Atualiza o modo de arame e avança a revisão do material."
  (let ((new-value (not (null value))))
    (unless (eql new-value (slot-value material 'wireframe-p))
      (setf (slot-value material 'wireframe-p) new-value)
      (touch-object material :wireframe-changed))
    new-value))

(defun (setf mesh-object-material) (material object)
  "Substitui o material de um objeto sob o bloqueio do mundo."
  (unless (typep material 'simple-material)
    (error 'validation-error :context "material do objeto"
           :message "O material precisa ser um material simples."))
  (%with-object-world-lock
   object
   (lambda ()
     (unless (eq material (slot-value object 'material))
       (setf (slot-value object 'material) material)
       (touch-object object :material-changed))
     material)))

(defun (setf camera-target) (target camera)
  "Altera o alvo da câmera e avança sua revisão."
  (%with-object-world-lock
   camera
   (lambda ()
     (let ((new-target (%vec3-copy target "alvo da câmera")))
       (%validate-camera-frame (camera-eye camera) new-target
                               (%camera-up-world camera))
       (unless (equalp new-target (slot-value camera 'target))
         (setf (slot-value camera 'target) new-target)
         (touch-object camera :camera-target-changed))
       new-target))))

(defun (setf camera-up) (up camera)
  "Define o vetor para cima após validar o referencial da câmera."
  (%with-object-world-lock
   camera
   (lambda ()
     (let* ((new-up (%vec3-copy up "vetor para cima"))
            (world-up (transform-direction (world-transform camera) new-up)))
       (%validate-camera-frame (camera-eye camera) (camera-target camera) world-up)
       (setf new-up (normalize new-up))
       (unless (equalp new-up (slot-value camera 'up))
         (setf (slot-value camera 'up) new-up)
         (touch-object camera :camera-up-changed))
       (copy-seq new-up)))))

(defun (setf camera-fov) (fov camera)
  "Define o campo de visão e avança a revisão quando ele muda."
  (%with-object-world-lock
   camera
   (lambda ()
     (%validate-camera-optics fov (camera-near camera) (camera-far camera))
     (let ((new-fov (coerce fov 'double-float)))
       (unless (= new-fov (slot-value camera 'fov))
         (setf (slot-value camera 'fov) new-fov)
         (touch-object camera :camera-fov-changed))
       new-fov))))

(defun (setf camera-near) (near camera)
  "Define o plano próximo mantendo a ordem dos planos de recorte."
  (%with-object-world-lock
   camera
   (lambda ()
     (%validate-camera-optics (camera-fov camera) near (camera-far camera))
     (let ((new-near (coerce near 'double-float)))
       (unless (= new-near (slot-value camera 'near))
         (setf (slot-value camera 'near) new-near)
         (touch-object camera :camera-near-changed))
       new-near))))

(defun (setf camera-far) (far camera)
  "Define o plano distante mantendo a ordem dos planos de recorte."
  (%with-object-world-lock
   camera
   (lambda ()
     (%validate-camera-optics (camera-fov camera) (camera-near camera) far)
     (let ((new-far (coerce far 'double-float)))
       (unless (= new-far (slot-value camera 'far))
         (setf (slot-value camera 'far) new-far)
         (touch-object camera :camera-far-changed))
       new-far))))

(defun set-position (object position)
  "Define a posição local do objeto e avança sua revisão."
  (%with-object-world-lock
   object
   (lambda ()
     (setf (transform-position (%scene-object-local-transform object))
           (%vec3-copy position "posição do objeto"))
     (touch-object object :position-changed)))
  object)

(defun translate (object offset)
  "Desloca o objeto em seus eixos locais."
  (%with-object-world-lock
   object
   (lambda ()
     (set-position object (v+ (transform-position (%scene-object-local-transform object))
                              (%vec3-copy offset "deslocamento")))))
  object)

(defun set-rotation (object rotation)
  "Define rotação local por quaternion ou ângulos de Euler em radianos."
  (%with-object-world-lock
   object
   (lambda ()
     (setf (transform-rotation (%scene-object-local-transform object))
           (%coerce-rotation rotation))
     (touch-object object :rotation-changed)))
  object)

(defun rotate (object angles)
  "Compõe a rotação atual com ângulos de Euler em radianos."
  (%with-object-world-lock
   object
   (lambda ()
     (set-rotation object
                   (quaternion-multiply (transform-rotation (%scene-object-local-transform object))
                                        (%coerce-rotation angles)))))
  object)

(defun set-scale (object scale)
  "Define a escala local do objeto."
  (%with-object-world-lock
   object
   (lambda ()
     (setf (transform-scale (%scene-object-local-transform object))
           (%vec3-copy scale "escala do objeto"))
     (touch-object object :scale-changed)))
  object)

(defun scale-object (object factors)
  "Multiplica a escala local pelos fatores informados."
  (%with-object-world-lock
   object
   (lambda ()
     (set-scale object (v* (transform-scale (%scene-object-local-transform object))
                           (%vec3-copy factors "fatores de escala")))))
  object)

(defun %contains-descendant-p (ancestor candidate)
  (or (eq ancestor candidate)
      (some (lambda (child) (%contains-descendant-p child candidate))
            (scene-object-children ancestor))))

(defun %attach-child (parent child keep-world-transform)
  (when (eq parent child)
    (error 'hierarchy-error :context "hierarquia da cena"
           :message "Um objeto não pode ser filho de si mesmo."))
  (when (%contains-descendant-p child parent)
    (error 'hierarchy-error :context "hierarquia da cena"
           :message "A operação criaria um ciclo na hierarquia."))
  (when (and (scene-object-world parent) (scene-object-world child)
             (not (eq (scene-object-world parent) (scene-object-world child))))
    (error 'hierarchy-error :context "hierarquia da cena"
           :message "Não é permitido conectar objetos de mundos diferentes."))
  (when (and (null (scene-object-world parent)) (scene-object-world child))
    (error 'hierarchy-error :context "hierarquia da cena"
           :message "Um objeto pertencente a um mundo exige que o novo pai também pertença a esse mundo."))
  (let* ((world (or (scene-object-world parent) (scene-object-world child)))
         (old-world-matrix (and keep-world-transform (world-transform child)))
         (new-local-matrix (and old-world-matrix
                                (mat* (inverse-mat4 (world-transform parent))
                                      old-world-matrix)))
         (new-local-components (and new-local-matrix
                                    (multiple-value-list
                                     (%matrix-transform-components new-local-matrix)))))
    (when (scene-object-parent child)
      (setf (%scene-object-children (scene-object-parent child))
            (delete child (scene-object-children (scene-object-parent child)) :test #'eq)))
    (setf (%scene-object-parent child) parent)
    (pushnew child (%scene-object-children parent) :test #'eq)
    (%set-world-recursively child world)
    (when new-local-components
      (apply #'%assign-transform-components child new-local-components))
    (touch-object parent :child-added)
    (touch-object child :parent-changed)
    child))

(defun add-child (parent child &key keep-world-transform)
  "Adiciona CHILD a PARENT, rejeitando ciclos e mundos incompatíveis."
  (let ((world (%world-of-either parent child)))
    (if world
        (with-world-lock (world) (%attach-child parent child keep-world-transform))
        (%attach-child parent child keep-world-transform))))

(defun remove-child (parent child &key keep-world-transform)
  "Remove CHILD de PARENT e opcionalmente preserva sua transformação mundial."
  (unless (eq (scene-object-parent child) parent)
    (error 'hierarchy-error :context "remoção de filho"
           :message "O objeto informado não é filho desse pai."))
  (let ((world (scene-object-world parent)))
    (flet ((remove-it ()
             (let* ((matrix (and keep-world-transform (world-transform child)))
                    (components (and matrix
                                     (multiple-value-list (%matrix-transform-components matrix)))))
               (when (and world (world-selection world)
                          (%contains-descendant-p child (world-selection world)))
                 (setf (world-selection world) nil))
               (setf (%scene-object-children parent)
                     (delete child (scene-object-children parent) :test #'eq)
                     (%scene-object-parent child) nil)
               (%set-world-recursively child nil)
               (when components
                 (apply #'%assign-transform-components child components))
               (touch-object parent :child-removed)
               (touch-object child :parent-changed)
               child)))
      (if world (with-world-lock (world) (remove-it)) (remove-it)))))

(defun reparent (child new-parent &key keep-world-transform)
  "Move CHILD para um novo pai dentro do mesmo mundo."
  (if new-parent
      (add-child new-parent child :keep-world-transform keep-world-transform)
      (let ((old-parent (scene-object-parent child)))
        (when old-parent
          (remove-child old-parent child :keep-world-transform keep-world-transform))
        child)))

(defun make-world (&key root camera running-p)
  "Cria um mundo com nó raiz e câmera padrão."
  (let* ((root (or root (make-scene-object :name "Raiz")))
         (world (make-instance 'world :root root :camera (or camera (make-camera))
                               :running-p running-p)))
    (when (eq root (world-camera world))
      (error 'hierarchy-error :context "câmera do mundo"
             :message "A câmera não pode ser também a raiz da hierarquia."))
    (when (scene-object-parent root)
      (error 'hierarchy-error :context "raiz do mundo"
             :message "A raiz de um mundo não pode possuir pai."))
    (when (scene-object-world root)
      (error 'hierarchy-error :context "raiz do mundo"
             :message "A raiz já pertence a outro mundo."))
    (when (or (scene-object-world (world-camera world))
              (scene-object-parent (world-camera world)))
      (error 'hierarchy-error :context "câmera do mundo"
             :message "A câmera precisa estar fora de outra hierarquia ao criar o mundo."))
    (%set-world-recursively root world)
    (%set-world-recursively (world-camera world) world)
    world))

(defun add-to-world (world object &key parent)
  "Adiciona um objeto à raiz do mundo ou a um pai informado."
  (when (and parent (scene-object-world parent)
             (not (eq (scene-object-world parent) world)))
    (error 'hierarchy-error :context "adição ao mundo"
           :message "O pai informado pertence a outro mundo."))
  (unless (null (scene-object-world object))
    (unless (eq (scene-object-world object) world)
      (error 'hierarchy-error :context "adição ao mundo"
             :message "O objeto já pertence a outro mundo.")))
  (add-child (or parent (world-root world)) object))

(defun remove-from-world (world object)
  "Remove um objeto da hierarquia do mundo."
  (unless (eq (scene-object-world object) world)
    (error 'hierarchy-error :context "remoção do mundo"
           :message "O objeto não pertence a esse mundo."))
  (unless (scene-object-parent object)
    (error 'hierarchy-error :context "remoção do mundo"
           :message "A raiz do mundo não pode ser removida."))
  (when (and (world-selection world)
             (%contains-descendant-p object (world-selection world)))
    (setf (world-selection world) nil))
  (remove-child (scene-object-parent object) object))

(defun find-object (world name-or-id)
  "Busca um objeto pelo identificador ou nome dentro da hierarquia do mundo."
  (with-world-lock (world)
    (find-if (lambda (object)
               (if (integerp name-or-id)
                   (= (object-id object) name-or-id)
                   (string= (object-name object) name-or-id)))
             (%descendants (world-root world)))))

(defun %visible-enabled-p (object)
  (loop for current = object then (scene-object-parent current)
        while current
        always (and (scene-object-visible-p current) (scene-object-enabled-p current))))

(defun %enabled-chain-p (object)
  (loop for current = object then (scene-object-parent current)
        while current
        always (scene-object-enabled-p current)))

(defun ray-cast (world ray)
  "Retorna objeto, distância e ponto da primeira malha atingida pelo raio."
  (with-world-lock (world)
    (let ((nearest-object nil)
          (nearest-distance nil)
          (nearest-point nil))
      (dolist (object (%descendants (world-root world)))
        (when (and (typep object 'mesh-object) (%visible-enabled-p object))
          (let* ((geometry (mesh-object-geometry object))
                 (data (compile-render-data geometry))
                 (indices (render-mesh-indices data))
                 (positions (render-mesh-positions data))
                 (matrix (world-transform object)))
            (loop for offset from 0 below (length indices) by 3
                  for a-local = (make-vec3 (aref positions (* 3 (aref indices offset)))
                                           (aref positions (1+ (* 3 (aref indices offset))))
                                           (aref positions (+ 2 (* 3 (aref indices offset)))))
                  for b-local = (make-vec3 (aref positions (* 3 (aref indices (1+ offset))))
                                           (aref positions (1+ (* 3 (aref indices (1+ offset)))))
                                           (aref positions (+ 2 (* 3 (aref indices (1+ offset))))))
                  for c-local = (make-vec3 (aref positions (* 3 (aref indices (+ offset 2))))
                                           (aref positions (1+ (* 3 (aref indices (+ offset 2)))))
                                           (aref positions (+ 2 (* 3 (aref indices (+ offset 2))))))
                  for distance = (sgeo.math:ray-triangle-intersection
                                  ray (transform-point matrix a-local)
                                  (transform-point matrix b-local)
                                  (transform-point matrix c-local))
                  when (and distance (or (null nearest-distance) (< distance nearest-distance)))
                    do (setf nearest-object object nearest-distance distance
                             nearest-point (v+ (ray-origin ray)
                                               (v* (ray-direction ray) distance)))))))
      (values nearest-object nearest-distance nearest-point))))

(defun camera-ray (world-or-camera x y width height &key ndc-p)
  "Cria raio em coordenadas de janela ou, com NDC-P, em coordenadas NDC."
  (let* ((camera (if (typep world-or-camera 'world)
                     (world-camera world-or-camera)
                     world-or-camera))
         (w (coerce width 'double-float))
         (h (coerce height 'double-float)))
    (unless (and (plusp w) (plusp h))
      (error 'validation-error :context "raio da câmera"
             :message "A largura e a altura da janela precisam ser positivas."))
    (let* ((nx (if ndc-p (coerce x 'double-float)
                   (- (* 2d0 (/ (+ (coerce x 'double-float) 0.5d0) w)) 1d0)))
           (ny (if ndc-p (coerce y 'double-float)
                   (- 1d0 (* 2d0 (/ (+ (coerce y 'double-float) 0.5d0) h)))))
           (inverse-vp (inverse-mat4 (mat* (projection-matrix camera (/ w h))
                                          (view-matrix camera))))
           (near-point (transform-point inverse-vp (make-vec3 nx ny -1d0)))
           (far-point (transform-point inverse-vp (make-vec3 nx ny 1d0)))
           (origin (if (eq (camera-projection-mode camera) :orthographic)
                       near-point (camera-eye camera))))
      (make-ray origin (normalize (v- far-point origin))))))

(defun update-world (world dt)
  "Atualiza todos os objetos habilitados da hierarquia em ordem de percurso."
  (with-world-lock (world)
    (dolist (object (adjoin (world-camera world) (%descendants (world-root world)) :test #'eq))
      (when (%enabled-chain-p object)
        (update-object object world dt))))
  world)

(defun %render-entries (object parent-visible-p parent-enabled-p)
  (let ((visible (and parent-visible-p (scene-object-visible-p object)))
        (enabled (and parent-enabled-p (scene-object-enabled-p object))))
    (append
     (when (and visible enabled (typep object 'mesh-object))
       (let* ((geometry (mesh-object-geometry object))
              (data (compile-render-data geometry))
              (material (mesh-object-material object)))
         (list (list :object object :object-id (object-id object)
                     :geometry geometry :revision (render-mesh-revision data)
                     :positions (render-mesh-positions data)
                     :normals (render-mesh-normals data)
                     :indices (render-mesh-indices data)
                     :model-matrix (world-transform object)
                     :material material :color (simple-material-color material)
                     :wireframe-p (simple-material-wireframe-p material)
                     :visible-p visible))))
     (mapcan (lambda (child) (%render-entries child visible enabled))
             (copy-list (scene-object-children object))))))

(defun render-snapshot (world &optional (aspect 1d0))
  "Extrai uma visão consistente e sem recursos gráficos dos dados do mundo."
  (with-world-lock (world)
    (let ((camera (world-camera world)))
      (list :objects (%render-entries (world-root world) t t)
            :view-matrix (view-matrix camera)
            :projection-matrix (projection-matrix camera aspect)
            :camera camera
            :camera-eye (camera-eye camera)
            :camera-target (camera-target camera)
            :camera-up (camera-up camera)
            :camera-fov (camera-fov camera)
            :camera-near (camera-near camera)
            :camera-far (camera-far camera)
            :selected-object (world-selection world)))))
