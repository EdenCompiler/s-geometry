(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(test mesh-data-validation-and-revisions
  (let* ((mesh (sg:make-box :size 2))
         (old-data (sg:compile-render-data mesh))
         (old-positions (copy-seq (sg:mesh-positions mesh))))
    (is (= 36 (length (sg:mesh-indices mesh))))
    (is (vector-approximately= #(-1 -1 -1) (sg:aabb-min (sg:bounds mesh))))
    (is (vector-approximately= #(1 1 1) (sg:aabb-max (sg:bounds mesh))))
    (signals sg:validation-error (sg:set-mesh-position mesh 100 (sg:vec3)))
    (signals sg:validation-error (sg:set-mesh-data mesh #(0 0 0) #(0 1 2)))
    (is (= 0 (sg:object-revision mesh)))
    (is (equalp old-positions (sg:mesh-positions mesh)))
    (sg:set-mesh-position mesh 0 (sg:vec3 -2 -1 -1))
    (is (= 1 (sg:object-revision mesh)))
    (is (approximately= -2 (sg:vx (sg:aabb-min (sg:bounds mesh)))))
    ;; Os dados extraídos anteriormente continuam válidos após a publicação de uma revisão.
    (is (equalp old-positions (sg:render-mesh-positions old-data)))
    (is (not (eq (sg:render-mesh-positions old-data) (sg:mesh-positions mesh))))))

(test triangle-picking-and-invalid-edit-rollback
  (let* ((mesh (sg:make-triangle-mesh
                :positions #(-1 -1 0 1 -1 0 0 1 0) :indices #(0 1 2)))
         (positions (copy-seq (sg:mesh-positions mesh))))
    (is (approximately= 5 (sg:ray-intersect-mesh
                            mesh (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 0 -1)))))
    ;; Colapsar o terceiro vértice sobre o primeiro invalida a normal do triângulo.
    (signals sg:sgeo-error (sg:set-mesh-position mesh 2 (sg:vec3 -1 -1 0)))
    (is (= 0 (sg:object-revision mesh)))
    (is (equalp positions (sg:mesh-positions mesh)))))

(test hierarchy-transforms-and-cycle-rejection
  (let* ((world (sg:make-world))
         (parent (sg:make-scene-object :name "Parent" :position (sg:vec3 2 0 0)))
         (child (sg:make-mesh-object (sg:make-box) :name "Child"
                                     :position (sg:vec3 0 3 0))))
    (sg:add-to-world world parent)
    (sg:add-child parent child)
    (is (eq world (sg:scene-object-world child)))
    (is (eq child (sg:find-object world "Child")))
    (is (eq child (sg:find-object world (sg:object-id child))))
    (is (vector-approximately= #(2 3 0)
                               (sg:transform-point (sg:world-transform child) (sg:vec3))))
    (sg:translate parent (sg:vec3 1 0 0))
    (is (vector-approximately= #(3 3 0)
                               (sg:transform-point (sg:world-transform child) (sg:vec3))))
    (signals sg:hierarchy-error (sg:add-child child parent))
    (is (eq parent (sg:scene-object-parent child)))
    (is (eq (sg:world-root world) (sg:scene-object-parent parent)))
    (sg:reparent child (sg:world-root world) :keep-world-transform t)
    (is (vector-approximately= #(3 3 0)
                               (sg:transform-point (sg:world-transform child) (sg:vec3))))
    (sg:remove-from-world world child)
    (is (null (sg:scene-object-world child)))
    (is (null (sg:find-object world "Child")))))

(test keep-world-reparent-preserves-reflection-and-signed-scale
  (let* ((world (sg:make-world))
         (old-parent (sg:make-scene-object
                      :name "Pai antigo" :position (sg:vec3 2 -1 3)
                      :rotation (sg:vec3 0.2d0 -0.3d0 0.4d0)
                      :scale (sg:vec3 2 2 2)))
         (new-parent (sg:make-scene-object
                      :name "Pai novo" :position (sg:vec3 -4 2 1)
                      :rotation (sg:vec3 -0.1d0 0.5d0 -0.2d0)
                      :scale (sg:vec3 0.5d0 0.5d0 0.5d0)))
         (child (sg:make-scene-object
                 :name "Refletido" :position (sg:vec3 1 2 -3)
                 :rotation (sg:vec3 0.3d0 0.1d0 -0.6d0)
                 :scale (sg:vec3 -2 3 0.75d0))))
    (sg:add-to-world world old-parent)
    (sg:add-to-world world new-parent)
    (sg:add-child old-parent child)
    (let ((world-before (sg:world-transform child)))
      (sg:reparent child new-parent :keep-world-transform t)
      (is (eq new-parent (sg:scene-object-parent child)))
      (is (vector-approximately= world-before (sg:world-transform child)))
      ;; A reflexão deve continuar representada por uma escala assinada.
      (is (minusp (reduce #'* (sg:transform-scale
                               (sg:scene-object-local-transform child))))))))

(test keep-world-reparent-rejects-shear-atomically
  (let* ((world (sg:make-world))
         (old-parent (sg:make-scene-object :name "Pai atual"))
         (new-parent (sg:make-scene-object
                      :name "Pai anisotrópico"
                      :scale (sg:vec3 2 1 1)))
         (child (sg:make-scene-object
                 :name "Filho girado" :rotation (sg:vec3 0 0 0.6d0))))
    (sg:add-to-world world old-parent)
    (sg:add-to-world world new-parent)
    (sg:add-child old-parent child)
    (let ((local-before (sg:transform-matrix
                         (sg:scene-object-local-transform child)))
          (world-before (sg:world-transform child))
          (old-parent-revision (sg:object-revision old-parent))
          (new-parent-revision (sg:object-revision new-parent))
          (child-revision (sg:object-revision child)))
      (signals sg:hierarchy-error
        (sg:reparent child new-parent :keep-world-transform t))
      ;; A falha de decomposição não pode publicar nenhuma mudança na hierarquia.
      (is (eq old-parent (sg:scene-object-parent child)))
      (is (member child (sg:scene-object-children old-parent) :test #'eq))
      (is (not (member child (sg:scene-object-children new-parent) :test #'eq)))
      (is (eq world (sg:scene-object-world child)))
      (is (vector-approximately= local-before
                                 (sg:transform-matrix
                                  (sg:scene-object-local-transform child))))
      (is (vector-approximately= world-before (sg:world-transform child)))
      (is (= old-parent-revision (sg:object-revision old-parent)))
      (is (= new-parent-revision (sg:object-revision new-parent)))
      (is (= child-revision (sg:object-revision child))))))

(test camera-coincident-eye-and-target-rejections-preserve-state
  (let* ((camera (sg:make-camera :eye (sg:vec3 0 0 5)
                                 :target (sg:vec3 0 0 0)))
         (eye-before (sg:camera-eye camera))
         (target-before (sg:camera-target camera))
         (local-before (sg:transform-matrix
                        (sg:scene-object-local-transform camera)))
         (revision-before (sg:object-revision camera)))
    (signals sg:validation-error (sg:set-camera-eye camera target-before))
    (is (vector-approximately= eye-before (sg:camera-eye camera)))
    (is (vector-approximately= target-before (sg:camera-target camera)))
    (is (vector-approximately= local-before
                               (sg:transform-matrix
                                (sg:scene-object-local-transform camera))))
    (is (= revision-before (sg:object-revision camera)))
    (signals sg:validation-error (sg:set-camera-target camera eye-before))
    (is (vector-approximately= eye-before (sg:camera-eye camera)))
    (is (vector-approximately= target-before (sg:camera-target camera)))
    (is (vector-approximately= local-before
                               (sg:transform-matrix
                                (sg:scene-object-local-transform camera))))
    (is (= revision-before (sg:object-revision camera)))))

(test camera-and-transform-readers-return-defensive-copies
  (let* ((camera (sg:make-camera :eye (sg:vec3 0 0 5)
                                 :target (sg:vec3 0 0 0)
                                 :up (sg:vec3 0 2 0)))
         (object (sg:make-scene-object :position (sg:vec3 1 2 3)
                                       :scale (sg:vec3 2 3 4)))
         (camera-revision (sg:object-revision camera))
         (object-revision (sg:object-revision object))
         (eye-before (sg:camera-eye camera))
         (target-copy (sg:camera-target camera))
         (up-copy (sg:camera-up camera))
         (transform-copy (sg:scene-object-local-transform object))
         (matrix-before (sg:world-transform object)))
    (setf (aref target-copy 0) 99d0
          (aref up-copy 1) 99d0
          (aref (sg:transform-position transform-copy) 0) 99d0
          (aref (sg:transform-scale transform-copy) 1) 99d0)
    (is (vector-approximately= #(0 0 0) (sg:camera-target camera)))
    (is (vector-approximately= #(0 1 0) (sg:camera-up camera)))
    (is (vector-approximately= #(1 2 3)
                               (sg:transform-position
                                (sg:scene-object-local-transform object))))
    (is (vector-approximately= #(2 3 4)
                               (sg:transform-scale
                                (sg:scene-object-local-transform object))))
    (is (vector-approximately= eye-before (sg:camera-eye camera)))
    (is (vector-approximately= matrix-before (sg:world-transform object)))
    (is (= camera-revision (sg:object-revision camera)))
    (is (= object-revision (sg:object-revision object)))))

(test camera-public-setters-validate-atomically-and-touch-revisions
  (let* ((camera (sg:make-camera :eye (sg:vec3 0 0 5)
                                 :target (sg:vec3 0 0 0)))
         (eye-before (sg:camera-eye camera))
         (target-before (sg:camera-target camera))
         (up-before (sg:camera-up camera))
         (fov-before (sg:camera-fov camera))
         (near-before (sg:camera-near camera))
         (far-before (sg:camera-far camera))
         (revision-before (sg:object-revision camera)))
    (labels ((state-intact-p ()
             (and (vector-approximately= eye-before (sg:camera-eye camera))
                  (vector-approximately= target-before (sg:camera-target camera))
                  (vector-approximately= up-before (sg:camera-up camera))
                  (= fov-before (sg:camera-fov camera))
                  (= near-before (sg:camera-near camera))
                  (= far-before (sg:camera-far camera))
                  (= revision-before (sg:object-revision camera))))
           (reject-without-change (place setter)
             (signals sg:validation-error (funcall setter))
             (is (state-intact-p) place)))
      (reject-without-change "campo de visão nulo"
                             (lambda () (setf (sg:camera-fov camera) 0)))
      (reject-without-change "campo de visão fora do intervalo"
                             (lambda () (setf (sg:camera-fov camera) pi)))
      (reject-without-change "plano próximo nulo"
                             (lambda () (setf (sg:camera-near camera) 0)))
      (reject-without-change "plano próximo além do distante"
                             (lambda () (setf (sg:camera-near camera) far-before)))
      (reject-without-change "plano distante antes do próximo"
                             (lambda () (setf (sg:camera-far camera) near-before)))
      (reject-without-change "vetor para cima nulo"
                             (lambda () (setf (sg:camera-up camera) (sg:vec3))))
      (reject-without-change "vetor para cima paralelo à visão"
                             (lambda () (setf (sg:camera-up camera) (sg:vec3 0 0 1))))
      (reject-without-change "alvo com direção paralela ao vetor para cima"
                             (lambda () (setf (sg:camera-target camera)
                                              (sg:vec3 0 5 5))))
      (reject-without-change "olho com direção paralela ao vetor para cima"
                             (lambda () (sg:set-camera-eye camera (sg:vec3 0 5 0)))))
    ;; Cada alteração válida avança a revisão uma vez.
    (setf (sg:camera-fov camera) 0.8d0)
    (is (= (1+ revision-before) (sg:object-revision camera)))
    (setf (sg:camera-near camera) 0.1d0)
    (is (= (+ revision-before 2) (sg:object-revision camera)))
    (setf (sg:camera-far camera) 250d0)
    (is (= (+ revision-before 3) (sg:object-revision camera)))
    (setf (sg:camera-up camera) (sg:vec3 1 0 0))
    (is (= (+ revision-before 4) (sg:object-revision camera)))
    (setf (sg:camera-target camera) (sg:vec3 1 0 0))
    (is (= (+ revision-before 5) (sg:object-revision camera)))))

(test picking-uses-live-object-and-transformed-geometry
  (let* ((world (sg:make-world :camera (sg:make-camera :eye (sg:vec3 0 0 5))))
         (near (sg:make-mesh-object (sg:make-box :size 2) :name "Near"
                                    :scale (sg:vec3 0.5d0 2d0 1d0)))
         (far (sg:make-mesh-object (sg:make-box :size 2) :name "Far"
                                   :position (sg:vec3 0 0 -4)))
         (ray (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 0 -1))))
    (sg:add-to-world world far)
    (sg:add-to-world world near)
    (multiple-value-bind (object distance point) (sg:ray-cast world ray)
      (is (eq near object))
      (is (approximately= 4 distance))
      (is (vector-approximately= #(0 0 1) point)))
    (setf (sg:world-selection world) near)
    (is (eq near (sg:world-selection world)))
    (setf (sg:scene-object-visible-p near) nil)
    (is (eq far (sg:ray-cast world ray)))
    (setf (sg:scene-object-visible-p near) t)
    (sg:set-position near (sg:vec3 20 0 0))
    (is (eq far (sg:ray-cast world ray)))
    (is (null (sg:ray-cast world (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 1 0)))))))

(test snapshot-hierarchy-filtering-and-camera-navigation
  (let* ((world (sg:make-world :camera (sg:make-camera :eye (sg:vec3 0 0 5))))
         (group (sg:make-scene-object :name "Group"))
         (object (sg:make-mesh-object (sg:make-box) :name "Box"))
         (camera (sg:world-camera world)))
    (sg:add-to-world world group)
    (sg:add-child group object)
    (is (= 1 (length (getf (sg:render-snapshot world) :objects))))
    (setf (sg:scene-object-enabled-p group) nil)
    (is (null (getf (sg:render-snapshot world) :objects)))
    (is (null (sg:ray-cast world (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 0 -1)))))
    (setf (sg:scene-object-enabled-p group) t)
    (let ((ray (sg:camera-ray world 399.5d0 299.5d0 800 600)))
      (is (vector-approximately= #(0 0 -1) (sg:ray-direction ray))))
    (sg:orbit-camera camera 0.3d0 0.2d0)
    (is (approximately= 5 (sg:vector-length (sg:v- (sg:camera-eye camera)
                                                   (sg:camera-target camera)))))
    (sg:zoom-camera camera -0.2d0)
    (is (< (sg:vector-length (sg:v- (sg:camera-eye camera)
                                     (sg:camera-target camera))) 5))
    (let ((offset (sg:v- (sg:camera-eye camera) (sg:camera-target camera))))
      (sg:pan-camera camera 0.1d0 -0.1d0)
      (is (vector-approximately= offset (sg:v- (sg:camera-eye camera)
                                               (sg:camera-target camera)))))))

(test live-function-and-class-redefinition
  ;; A classe e seu método mudam sem recriar a instância que já pertence ao mundo.
  (eval '(defclass live-probe (sg:scene-object) ((ticks :initform 0))))
  (eval '(defmethod sg:update-object ((object live-probe) world dt)
           (declare (ignore world dt))
           (incf (slot-value object 'ticks))))
  (let* ((world (sg:make-world))
         (object (make-instance 'live-probe :name "Live"))
         (id (sg:object-id object)))
    (sg:add-to-world world object)
    (sg:update-world world 0.01d0)
    (is (= 1 (slot-value object 'ticks)))
    (eval '(defmethod sg:update-object ((object live-probe) world dt)
             (declare (ignore world dt))
             (incf (slot-value object 'ticks) 10)))
    (eval '(defclass live-probe (sg:scene-object)
             ((ticks :initform 0) (health :initform 100))))
    (sg:update-world world 0.01d0)
    (is (= 11 (slot-value object 'ticks)))
    (is (= 100 (slot-value object 'health)))
    (is (= id (sg:object-id object)))
    (is (eq object (sg:find-object world "Live")))
    ;; Ocultar um objeto não deve desabilitar sua simulação.
    (setf (sg:scene-object-visible-p (sg:world-root world)) nil)
    (sg:update-world world 0.01d0)
    (is (= 21 (slot-value object 'ticks)))))

(test scene-cross-world-and-selection-validation
  (let* ((a (sg:make-world)) (b (sg:make-world))
         (object (sg:make-mesh-object (sg:make-box))))
    (sg:add-to-world a object)
    (signals sg:hierarchy-error (sg:add-to-world b object))
    (signals sg:hierarchy-error (setf (sg:world-selection b) object))
    (is (eq a (sg:scene-object-world object)))
    (is (eq (sg:world-root a) (sg:scene-object-parent object)))))

(test simultaneous-repl-style-translations
  (let* ((world (sg:make-world))
         (object (sg:make-scene-object :name "Concurrent")))
    (sg:add-to-world world object)
    (let ((workers
            (loop repeat 3 collect
              (bt:make-thread
               (lambda ()
                 (dotimes (index 100)
                   (declare (ignorable index))
                   (sg:translate object (sg:vec3 1 0 0))))
               :name "sgeo teste de mutação concorrente"))))
      (mapc #'bt:join-thread workers))
    (is (vector-approximately= #(300 0 0)
                               (sg:transform-point (sg:world-transform object) (sg:vec3))))))

(test hierarchy-readers-and-detached-selection
  (let* ((world (sg:make-world))
         (parent (sg:make-scene-object :name "Group"))
         (child (sg:make-mesh-object (sg:make-box) :name "Child")))
    (sg:add-to-world world parent)
    (sg:add-child parent child)
    (let ((children (sg:scene-object-children parent)))
      (setf (car children) parent)
      (is (equal (list child) (sg:scene-object-children parent))))
    (setf (sg:world-selection world) child)
    (sg:remove-child (sg:world-root world) parent)
    (is (null (sg:world-selection world)))
    (is (null (sg:scene-object-parent parent)))
    (is (null (sg:scene-object-world parent)))
    (is (null (sg:scene-object-world child)))
    (is (eq parent (sg:scene-object-parent child)))))
