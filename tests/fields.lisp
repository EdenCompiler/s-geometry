(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(test sdf-primitives-csg-and-transform-distances
  (let* ((sphere (sgeo.fields:make-sphere-field :radius 2d0))
         (box (sgeo.fields:make-box-field :size (sgeo.math:make-vec3 2 2 2)))
         (union (sgeo.fields:make-union-field sphere box))
         (difference (sgeo.fields:make-difference-field sphere box)))
    (is (approximately= -2d0 (sgeo.fields:field-distance sphere (sgeo.math:make-vec3 0 0 0))))
    (is (approximately= 1d0 (sgeo.fields:field-distance sphere (sgeo.math:make-vec3 3 0 0))))
    (is (approximately= -1d0 (sgeo.fields:field-distance box (sgeo.math:make-vec3 0 0 0))))
    (is (<= (sgeo.fields:field-distance union (sgeo.math:make-vec3 0 0 0)) -1d0))
    (is (>= (sgeo.fields:field-distance difference (sgeo.math:make-vec3 0 0 0)) 0d0))
    (let ((matrix (sgeo.math:translation-mat4 (sgeo.math:make-vec3 4 0 0))))
      (is (approximately= 0d0 (sgeo.fields:field-distance (sgeo.fields:make-field-transform sphere matrix)
                                                              (sgeo.math:make-vec3 6 0 0)))))))

(test field-mesh-is-watertight-and-editable
  (let* ((field (sgeo.fields:make-sphere-field :radius 1d0))
         (mesh (sgeo.fields:field->mesh field :resolution 12)))
    (is (sgeo.geometry:validate-mesh mesh))
    (is (= 0 (getf (sgeo.geometry:mesh-counts mesh) :boundary-edges)))
    (is (> (getf (sgeo.geometry:mesh-counts mesh) :faces) 100))))

(test sdf-degenerate-inputs-are-rejected
  (signals sgeo.core:validation-error
    (sgeo.fields:make-sphere-field :radius 0d0))
  (signals sgeo.core:validation-error
    (sgeo.fields:make-field-transform (sgeo.fields:make-sphere-field)
                                      (sgeo.math:scaling-mat4 1 2 1))))

(test field-parameters-copy-inputs-and-advance-revisions
  (let* ((size (sgeo.math:make-vec3 2 2 2))
         (box (sgeo.fields:make-box-field :size size))
         (params (sgeo.fields:field-parameters box))
         (revision (sgeo.core:object-revision box)))
    (setf (aref size 0) 100d0 (aref (getf params :size) 1) 100d0)
    (is (approximately= -1d0 (sgeo.fields:field-distance box (sgeo.math:make-vec3 0 0 0))))
    (sgeo.fields:set-field-parameter box :size (sgeo.math:make-vec3 4 2 2))
    (is (> (sgeo.core:object-revision box) revision))
    (is (approximately= -0.5d0 (sgeo.fields:field-distance box (sgeo.math:make-vec3 1.5d0 0 0))))
    (signals sgeo.core:validation-error (sgeo.fields:set-field-parameter box :size #(1d0 -1d0 1d0)))
    (signals sgeo.core:validation-error (sgeo.fields:make-capsule-field :a #(0d0 0d0) :b #(0d0 0d0 1d0)))))

(test compound-fields-track-live-dependencies-and-nested-cavities-mesh-closed
  (let* ((outer (sgeo.fields:make-sphere-field :radius 1.25d0))
         (inner (sgeo.fields:make-sphere-field :radius 0.5d0))
         (difference (sgeo.fields:make-difference-field outer inner))
         (smooth (sgeo.fields:smooth-union-field outer (sgeo.fields:make-sphere-field :radius 0.75d0) 0.2d0))
         (revision (sgeo.core:object-revision difference)))
    (is (member outer (sgeo.core:dependencies-of difference)))
    (sgeo.fields:set-field-parameter inner :radius 0.4d0)
    (is (> (sgeo.core:object-revision difference) revision))
    (is (approximately= 0.4d0 (sgeo.fields:field-distance difference (sgeo.math:make-vec3 0 0 0))))
    (is (approximately= -1.25d0 (sgeo.fields:field-distance smooth (sgeo.math:make-vec3 0 0 0))))
    (let ((mesh (sgeo.fields:field->mesh difference :resolution 14)))
      (is (sgeo.geometry:validate-mesh mesh))
      (is (= 0 (getf (sgeo.geometry:mesh-counts mesh) :boundary-edges))))))

(test disjoint-intersection-has-no-bounds
  (let* ((left (sgeo.fields:make-field-transform (sgeo.fields:make-sphere-field) (sgeo.math:translation-mat4 (sgeo.math:make-vec3 -3 0 0))))
         (right (sgeo.fields:make-field-transform (sgeo.fields:make-sphere-field) (sgeo.math:translation-mat4 (sgeo.math:make-vec3 3 0 0))))
         (intersection (sgeo.fields:make-intersection-field left right)))
    (is (null (sgeo.fields:field-bounds intersection)))
    (signals sgeo.core:validation-error (sgeo.fields:field->mesh intersection :resolution 6))))

(test multi-component-union-mesh-has-no-cracks-and-transform-is-defensive
  (let* ((matrix (sgeo.math:translation-mat4 (sgeo.math:make-vec3 1 0 0)))
         (sphere (sgeo.fields:make-sphere-field :radius 0.6d0))
         (moving (sgeo.fields:make-field-transform sphere matrix))
         (revision (sgeo.core:object-revision moving))
         (union (sgeo.fields:make-union-field moving (sgeo.fields:make-field-transform
                                                       (sgeo.fields:make-sphere-field :radius 0.6d0)
                                                       (sgeo.math:translation-mat4 (sgeo.math:make-vec3 -1 0 0))))))
    (setf (aref matrix 12) 50d0)
    (is (approximately= 0d0 (sgeo.fields:field-distance moving (sgeo.math:make-vec3 1.6d0 0 0))))
    (let ((parameters (sgeo.fields:field-parameters moving)))
      (setf (aref (getf parameters :matrix) 12) 30d0)
      (sgeo.fields:set-field-parameter moving :matrix (sgeo.math:translation-mat4 (sgeo.math:make-vec3 2 0 0))))
    (is (> (sgeo.core:object-revision moving) revision))
    (is (approximately= 0d0 (sgeo.fields:field-distance moving (sgeo.math:make-vec3 2.6d0 0 0))))
    (let ((mesh (sgeo.fields:field->mesh union :resolution 14)))
      (is (sgeo.geometry:validate-mesh mesh))
      (is (= 0 (getf (sgeo.geometry:mesh-counts mesh) :boundary-edges))))))
