(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %animation-test-triangle (&optional normals)
  (sgeo.geometry:make-triangle-mesh
   :positions #(0d0 0d0 0d0  1d0 0d0 0d0  0d0 1d0 0d0)
   :normals normals :indices #(0 1 2)))

(defun %animation-test-v3 (data index)
  (subseq data (* 3 index) (+ 3 (* 3 index))))

(test skeleton-palette-and-bind-pose
  (let* ((joint (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
         (skeleton (sgeo.animation:make-skeleton
                    :joints (vector joint)
                    :inverse-bind-matrices (vector (sgeo.math:translation-mat4 -1d0 0d0 0d0))))
         (mesh (%animation-test-triangle))
         (object (sgeo.animation:make-deformable-mesh-object
                  :geometry mesh :skeleton skeleton
                  :joint-indices #(#(0) #(0) #(0))
                  :joint-weights #(#(1d0) #(1d0) #(1d0))))
         (bound (sgeo.animation:deformed-render-data object)))
    (is (vector-approximately= (sgeo.geometry:render-mesh-positions bound)
                               (sgeo.geometry:render-mesh-positions
                                (sgeo.core:compile-render-data mesh))))
    ;; O espaço local do objeto é compensado na paleta, e o nó da malha não
    ;; altera o resultado mundial jointWorld * inverseBind * posição.
    (sgeo.scene:set-position object #(20d0 0d0 0d0))
    (sgeo.scene:set-position joint #(3d0 0d0 0d0))
    (let* ((moved (sgeo.animation:deformed-render-data object))
           (local (sgeo.geometry:render-mesh-positions moved)))
      (is (approximately= (aref local 0) -18d0))
      (is (approximately= (+ 20d0 (aref local 0)) 2d0)))))

(test skeleton-bind-and-influence-accessors-do-not-alias-source
  (let* ((joint (sgeo.scene:make-scene-object))
         (bind (sgeo.math:identity-mat4))
         (skeleton (sgeo.animation:make-skeleton
                    :joints (vector joint) :inverse-bind-matrices (vector bind)))
         (joint-copy (sgeo.animation:skeleton-joints skeleton))
         (bind-copy (aref (sgeo.animation:skeleton-inverse-bind-matrices skeleton) 0)))
    (setf (aref joint-copy 0) nil
          (aref bind-copy 12) 42d0
          (aref bind 13) 9d0)
    (is (eq joint (aref (sgeo.animation:skeleton-joints skeleton) 0)))
    (is (vector-approximately= (aref (sgeo.animation:skeleton-inverse-bind-matrices skeleton) 0)
                               (sgeo.math:identity-mat4)))
    (is (vector-approximately= (aref (sgeo.animation:joint-palette skeleton) 0)
                               (sgeo.math:identity-mat4)))
    (let* ((mesh (%animation-test-triangle))
           (object (sgeo.animation:make-deformable-mesh-object
                    :geometry mesh :skeleton skeleton
                    :joint-indices #(#(0) #(0) #(0))
                    :joint-weights #(#(1d0) #(1d0) #(1d0))))
           (indices (sgeo.animation:mesh-joint-indices object))
           (weights (sgeo.animation:mesh-joint-weights object)))
      (setf (aref (aref indices 0) 0) 99
            (aref (aref weights 0) 0) 0d0)
      (is (= 0 (aref (aref (sgeo.animation:mesh-joint-indices object) 0) 0)))
      (is (= 1d0 (aref (aref (sgeo.animation:mesh-joint-weights object) 0) 0))))))

(test skeleton-normal-inverse-transpose-and-multi-influence
  (let* ((root (sgeo.scene:make-scene-object))
         (joint-a (sgeo.scene:make-scene-object))
         (joint-b (sgeo.scene:make-scene-object))
         (normal (sgeo.math:normalize #(1d0 1d0 0d0)))
         (mesh (%animation-test-triangle
                (concatenate 'vector normal normal normal)))
         (skeleton (sgeo.animation:make-skeleton :joints (vector root joint-a joint-b)))
         (object (sgeo.animation:make-deformable-mesh-object
                  :geometry mesh :skeleton skeleton
                  :joint-indices #(#(1 2) #(1) #(1))
                  :joint-weights #(#(0.5d0 0.5d0) #(1d0) #(1d0))))
         (second-object (sgeo.animation:make-deformable-mesh-object
                         :geometry mesh :skeleton skeleton
                         :joint-indices #(#(1) #(1) #(1))
                         :joint-weights #(#(1d0) #(1d0) #(1d0))))
         (first-data (sgeo.animation:deformed-render-data object)))
    (sgeo.scene:set-scale joint-a #(2d0 1d0 1d0))
    (let* ((data (sgeo.animation:deformed-render-data object))
           (actual (%animation-test-v3 (sgeo.geometry:render-mesh-normals data) 0))
           (expected (sgeo.math:normalize (vector (/ 1d0 1.5d0) 1d0 0d0))))
      (is (not (eq first-data data)))
      (is (vector-approximately= actual expected)))
    (is (not (eq (sgeo.animation:deformed-render-data object)
                 (sgeo.animation:deformed-render-data second-object))))
    (is (eq (sgeo.animation:deformed-render-data object)
            (sgeo.animation:deformed-render-data object)))))

(test skeleton-morph-edit-cache-and-validation
  (let* ((mesh (%animation-test-triangle))
         (joint (sgeo.scene:make-scene-object))
         (skeleton (sgeo.animation:make-skeleton :joints (vector joint)))
         (target (sgeo.animation:make-morph-target
                  :positions #(0d0 0d0 1d0  0d0 0d0 0d0  0d0 0d0 0d0)))
         (object (sgeo.animation:make-deformable-mesh-object
                  :geometry mesh :skeleton skeleton :morph-targets (vector target)
                  :morph-weights #(0d0)))
         (initial (sgeo.animation:deformed-render-data object)))
    (is (eq initial (sgeo.animation:deformed-render-data object)))
    (sgeo.animation:set-morph-weights object #(1d0))
    (let ((morphed (sgeo.animation:deformed-render-data object)))
      (is (not (eq initial morphed)))
      (is (approximately= (aref (sgeo.geometry:render-mesh-positions morphed) 2) 1d0))
      (is (> (sgeo.geometry:render-mesh-revision morphed)
             (sgeo.geometry:render-mesh-revision initial)))
      (is (approximately= (aref (sgeo.geometry:mesh-positions mesh) 2) 0d0))
      (signals sgeo.core:validation-error
        (sgeo.animation:set-morph-weights object #(0d0 1d0))))
    (sgeo.geometry:set-mesh-data mesh
      #(0d0 0d0 0d0  2d0 0d0 0d0  0d0 2d0 0d0) #(0 1 2))
    (let ((edited (sgeo.animation:deformed-render-data object)))
      (is (not (eq edited initial)))
      (is (approximately= (aref (sgeo.geometry:render-mesh-positions edited) 3) 2d0)))
    (signals sgeo.core:validation-error
      (sgeo.animation:make-deformable-mesh-object
       :geometry mesh :skeleton skeleton
       :joint-indices #(#(1) #(0) #(0))
       :joint-weights #(#(1d0) #(1d0) #(1d0))))))

(test morph-only-mesh-without-skeleton
  (let* ((mesh (%animation-test-triangle))
         (target (sgeo.animation:make-morph-target
                  :positions #(0d0 0d0 2d0  0d0 0d0 0d0  0d0 0d0 0d0)
                  :normals #(1d0 0d0 0d0  0d0 0d0 0d0  0d0 0d0 0d0)))
         (object (sgeo.animation:make-deformable-mesh-object
                  :geometry mesh :morph-targets (vector target) :morph-weights #(0.5d0)
                  :position #(3d0 0d0 0d0) :scale #(2d0 1d0 1d0)))
         (first-data (sgeo.animation:deformed-render-data object)))
    (is (null (sgeo.animation:mesh-skeleton object)))
    (is (loop for row across (sgeo.animation:mesh-joint-indices object)
              always (zerop (length row))))
    (is (approximately= 1d0 (aref (sgeo.geometry:render-mesh-positions first-data) 2)))
    (is (approximately= 1d0
                        (aref (sgeo.math:aabb-max (sgeo.core:bounds object)) 2)))
    (let ((normal (%animation-test-v3 (sgeo.geometry:render-mesh-normals first-data) 0)))
      (is (approximately= (aref normal 0) (/ 1d0 (sqrt 5d0))))
      (is (approximately= (aref normal 2) (/ 2d0 (sqrt 5d0)))))
    ;; A malha derivada fica no espaço local; a transformação do nó continua
    ;; sendo aplicada normalmente pelo caminho de renderização da cena.
    (is (vector-approximately= #(3d0 0d0 1d0)
          (sgeo.scene:local->world object #(0d0 0d0 1d0))))
    (signals sgeo.core:validation-error
      (sgeo.animation:make-deformable-mesh-object
       :geometry mesh :joint-indices #(#(0) #(0) #(0))
       :joint-weights #(#(1d0) #(1d0) #(1d0))))
    (sgeo.geometry:set-mesh-position mesh 0 #(0d0 0d0 0.25d0))
    (let ((edited (sgeo.animation:deformed-render-data object)))
      (is (not (eq first-data edited)))
      (is (approximately= 1.25d0 (aref (sgeo.geometry:render-mesh-positions edited) 2)))
      (is (> (sgeo.geometry:render-mesh-revision edited)
             (sgeo.geometry:render-mesh-revision first-data))))))

(test skeleton-ancestor-pose-and-zero-weights
  (let* ((parent (sgeo.scene:make-scene-object))
         (joint (sgeo.scene:make-scene-object))
         (mesh (%animation-test-triangle))
         (skeleton (sgeo.animation:make-skeleton :joints (vector joint)))
         (object (sgeo.animation:make-deformable-mesh-object
                  :geometry mesh :skeleton skeleton
                  :joint-indices #(#(0) #(0) #(0))
                  :joint-weights #(#(0d0) #(0d0) #(0d0))))
         (before (sgeo.animation:deformed-render-data object)))
    (sgeo.scene:add-child parent joint)
    (sgeo.scene:set-position parent #(2d0 0d0 0d0))
    (let ((after (sgeo.animation:deformed-render-data object)))
      (is (not (eq before after)))
      (is (vector-approximately= (sgeo.geometry:render-mesh-positions after)
                                 (sgeo.geometry:render-mesh-positions
                                  (sgeo.core:compile-render-data mesh)))))))

(test skeleton-ik-and-root-motion
  (let* ((root (sgeo.scene:make-scene-object))
         (middle (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
         (end (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
         (skeleton (sgeo.animation:make-skeleton :joints (vector root middle end))))
    (sgeo.scene:add-child root middle)
    (sgeo.scene:add-child middle end)
    (is (sgeo.animation:solve-ik skeleton (vector root middle end) #(1d0 1d0 0d0)))
    (let* ((pole-root (sgeo.scene:make-scene-object))
           (pole-middle (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
           (pole-end (sgeo.scene:make-scene-object :position #(1d0 0d0 0d0)))
           (pole-skeleton (sgeo.animation:make-skeleton
                           :joints (vector pole-root pole-middle pole-end))))
      (sgeo.scene:add-child pole-root pole-middle)
      (sgeo.scene:add-child pole-middle pole-end)
      (is (sgeo.animation:solve-ik pole-skeleton
                                    (vector pole-root pole-middle pole-end)
                                    #(1d0 1d0 0d0) :pole #(0d0 0d0 1d0)))
      (is (> (aref (sgeo.scene:local->world pole-middle (sgeo.math:make-vec3)) 2) 0.5d0)))
    (let ((delta (sgeo.animation:extract-root-motion
                  (lambda (time) (vector time 0d0 0d0)) 0.75d0 1.25d0
                  :looping-p t :duration 1d0)))
      (is (approximately= (aref delta 0) 0.5d0)))
    (signals sgeo.core:validation-error
      (sgeo.animation:extract-root-motion (lambda (time) (declare (ignore time)) #(0d0 0d0))
                                          0d0 0.5d0))
    (signals sgeo.core:validation-error
      (sgeo.animation:solve-ik skeleton (vector root) #(0d0 0d0 0d0)))))
