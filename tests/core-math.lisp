(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(test object-identity-and-revision
  (let ((a (make-instance 'sg:sgeo-object :name "A"))
        (b (make-instance 'sg:sgeo-object :name "B")))
    (is (not (equal (sg:object-id a) (sg:object-id b))))
    (is (= 0 (sg:object-revision a)))
    (setf (gethash "purpose" (sg:object-metadata a)) "fixture")
    (is (equal "fixture" (gethash "purpose" (sg:object-metadata a))))
    (sg:touch-object a :vertex-data-changed)
    (sg:touch-object a :transform-changed)
    (is (= 2 (sg:object-revision a)))
    (is (= 0 (sg:object-revision b)))))

(test metadata-isolation-and-invalidation-observers
  (let* ((a (make-instance 'sg:sgeo-object))
         (b (make-instance 'sg:sgeo-object :metadata nil))
         (events nil)
         (observer (lambda (object reason revision)
                     (push (list object reason revision) events))))
    (setf (gethash "private" (sg:object-metadata a)) t)
    (is (not (gethash "private" (sg:object-metadata b))))
    (sg:add-invalidation-observer a observer)
    (sg:invalidate-object a :changed)
    (is (= 1 (length events)))
    (is (eq a (first (first events))))
    (is (eq :changed (second (first events))))
    (is (= 1 (third (first events))))
    (sg:remove-invalidation-observer a observer)
    (sg:touch-object a)
    (is (= 1 (length events))))
  (signals sg:validation-error (make-instance 'sg:sgeo-object :metadata 42)))

(test vector-operations
  (let ((a (sg:vec3 1 2 3)) (b (sg:vec3 4 5 6)))
    (is (vector-approximately= #(5 7 9) (sg:v+ a b)))
    (is (vector-approximately= #(-3 -3 -3) (sg:v- a b)))
    (is (approximately= 32 (sg:dot a b)))
    (is (vector-approximately= #(-3 6 -3) (sg:cross a b)))
    (is (approximately= 1 (sg:vector-length (sg:normalize a))))
    (let ((destination (sg:vec3)))
      (sg:v+! destination a b)
      (is (vector-approximately= #(5 7 9) destination))
      ;; A operação destrutiva também aceita o destino como um dos operandos.
      (sg:v*! destination destination 2)
      (is (vector-approximately= #(10 14 18) destination))))
  (signals sg:math-error (sg:normalize (sg:vec3))))

(test affine-composition-and-inverse
  (let* ((matrix (sg:mat* (sg:translation-mat4 3 -2 7)
                          (sg:mat* (sg:rotation-y-mat4 0.73d0)
                                   (sg:scaling-mat4 2 3 0.5d0))))
         (inverse (sg:inverse-mat4 matrix)))
    (dolist (point (list (sg:vec3) (sg:vec3 1 2 3) (sg:vec3 -7 0.2d0 11)))
      (is (vector-approximately=
           point (sg:transform-point inverse (sg:transform-point matrix point)))))
    (is (vector-approximately= (sg:identity-mat4) (sg:mat* matrix inverse))))
  (is (vector-approximately= #(1 2 3)
                             (sg:transform-direction (sg:translation-mat4 9 8 7)
                                                     (sg:vec3 1 2 3))))
  (signals sg:math-error (sg:inverse-mat4 (sg:scaling-mat4 0 1 1))))

(test quaternion-and-camera-conventions
  (let* ((rotation (sg:quaternion-from-axis-angle (sg:vec3 0 1 0) (/ pi 2)))
         (point (sg:transform-point (sg:quaternion->mat4 rotation) (sg:vec3 1 0 0))))
    (is (vector-approximately= #(0 0 -1) point)))
  (let ((view (sg:look-at-mat4 (sg:vec3 0 0 5) (sg:vec3) (sg:vec3 0 1 0))))
    (is (vector-approximately= #(0 0 0) (sg:transform-point view (sg:vec3 0 0 5))))
    (is (vector-approximately= #(0 0 -5) (sg:transform-point view (sg:vec3)))))
  (let ((projection (sg:perspective-mat4 (/ pi 3) 1.5d0 0.1d0 100d0)))
    (is (vector-approximately= (sg:identity-mat4)
                               (sg:mat* projection (sg:inverse-mat4 projection)))))
  (signals sg:math-error (sg:perspective-mat4 1d0 0d0 0.1d0 10d0)))

(test bounds-and-ray-intersections
  (let* ((box (sg:make-aabb (sg:vec3 -1 -2 -3) (sg:vec3 1 2 3)))
         (moved (sg:transform-aabb box (sg:translation-mat4 5 0 -2))))
    (is (vector-approximately= #(4 -2 -5) (sg:aabb-min moved)))
    (is (vector-approximately= #(6 2 1) (sg:aabb-max moved)))
    (is (approximately= 2 (sg:ray-aabb-intersection
                            (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 0 -1)) box)))
    (is (null (sg:ray-aabb-intersection
               (sg:make-ray (sg:vec3 2 0 5) (sg:vec3 0 0 -1)) box))))
  (let ((a (sg:vec3 -1 -1 0)) (b (sg:vec3 1 -1 0)) (c (sg:vec3 0 1 0)))
    (is (approximately= 5 (sg:ray-triangle-intersection
                            (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 0 -1)) a b c)))
    (is (null (sg:ray-triangle-intersection
               (sg:make-ray (sg:vec3 0 0 5) (sg:vec3 0 0 1)) a b c)))))

(test mesh-public-reads-do-not-leak-mutable-storage
  (let* ((mesh (sg:make-triangle-mesh
                :positions #(0 0 0  1 0 0  0 1 0)
                :indices #(0 1 2)))
         (revision (sg:object-revision mesh))
         (positions (sg:mesh-positions mesh))
         (normals (sg:mesh-normals mesh))
         (indices (sg:mesh-indices mesh))
         (bounds (sg:mesh-bounds mesh))
         (compiled (sg:compile-render-data mesh)))
    (setf (aref positions 0) 42d0
          (aref normals 2) -1d0
          (aref indices 0) 2
          (aref (sg:aabb-min bounds) 0) -100d0
          (aref (sg:aabb-max bounds) 0) 100d0)
    (is (vector-approximately= #(0 0 0  1 0 0  0 1 0) (sg:mesh-positions mesh)))
    (is (vector-approximately= #(0 0 1  0 0 1  0 0 1) (sg:mesh-normals mesh)))
    (is (equalp #(0 1 2) (sg:mesh-indices mesh)))
    (is (vector-approximately= #(0 0 0) (sg:aabb-min (sg:mesh-bounds mesh))))
    (is (vector-approximately= #(1 1 0) (sg:aabb-max (sg:mesh-bounds mesh))))
    (is (= revision (sg:object-revision mesh)))
    ;; Um snapshot compilado também não compartilha armazenamento com a malha.
    (setf (aref (sg:render-mesh-positions compiled) 1) 99d0
          (aref (sg:render-mesh-normals compiled) 0) 99d0
          (aref (sg:render-mesh-indices compiled) 1) 2)
    (let ((fresh (sg:compile-render-data mesh)))
      (is (= revision (sg:render-mesh-revision fresh)))
      (is (vector-approximately= #(0 0 0  1 0 0  0 1 0)
                                 (sg:render-mesh-positions fresh)))
      (is (vector-approximately= #(0 0 1  0 0 1  0 0 1)
                                 (sg:render-mesh-normals fresh)))
      (is (equalp #(0 1 2) (sg:render-mesh-indices fresh))))))
