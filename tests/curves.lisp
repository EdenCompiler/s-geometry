(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(test polyline-bezier-and-bspline-evaluation
  (let* ((points (vector (sgeo.math:make-vec3 0 0 0)
                         (sgeo.math:make-vec3 1 0 0)
                         (sgeo.math:make-vec3 1 1 0)))
         (poly (sgeo.curves:make-polyline-curve points))
         (bezier (sgeo.curves:make-bezier-curve points))
         (spline (sgeo.curves:make-bspline-curve points :degree 2)))
    (is (vector-approximately= (sgeo.curves:curve-point poly 0.5d0) (sgeo.math:make-vec3 1 0 0)))
    (is (vector-approximately= (sgeo.curves:curve-point bezier 0.5d0) (sgeo.math:make-vec3 0.75d0 0.25d0 0)))
    (is (vector-approximately= (sgeo.curves:curve-point spline 0.5d0) (sgeo.math:make-vec3 0.75d0 0.25d0 0)))
    (is (vector-approximately= (sgeo.curves:curve-derivative poly 0.25d0) (sgeo.math:make-vec3 2 0 0)))))

(test curve-and-bezier-surface-controls-are-authoritative
  (let* ((points (vector (sgeo.math:make-vec3 0 0 0) (sgeo.math:make-vec3 1 0 0)))
         (curve (sgeo.curves:make-bezier-curve points))
         (grid (make-array '(2 2) :initial-contents
                           (list (list (sgeo.math:make-vec3 0 0 0) (sgeo.math:make-vec3 0 1 0))
                                 (list (sgeo.math:make-vec3 1 0 0) (sgeo.math:make-vec3 1 1 0)))))
         (surface (sgeo.curves:make-bezier-surface grid))
         (curve-revision (sgeo.core:object-revision curve))
         (surface-revision (sgeo.core:object-revision surface)))
    (sgeo.curves:set-curve-control-point curve 1 (sgeo.math:make-vec3 2 0 0))
    (sgeo.curves:set-surface-control-point surface 1 1 (sgeo.math:make-vec3 1 1 1))
    (is (> (sgeo.core:object-revision curve) curve-revision))
    (is (> (sgeo.core:object-revision surface) surface-revision))
    (is (vector-approximately= (sgeo.curves:curve-point curve 1d0) (sgeo.math:make-vec3 2 0 0)))
    (is (vector-approximately= (sgeo.curves:surface-point surface 1d0 1d0) (sgeo.math:make-vec3 1 1 1)))))

(test bspline-analytic-derivatives-cover-clamped-and-internal-knots
  (let* ((controls #((0d0 0d0 0d0) (1d0 0d0 0d0) (1d0 1d0 0d0) (2d0 1d0 0d0)))
         (curve (sgeo.curves:make-bspline-curve controls :degree 2 :knots #(0d0 0d0 0d0 0.5d0 1d0 1d0 1d0))))
    (dolist (u '(0d0 0.25d0 0.5d0 0.75d0 1d0))
      (let* ((h 1d-6) (lo (max 0d0 (- u h))) (hi (min 1d0 (+ u h)))
             (finite-difference (sgeo.math:v* (sgeo.math:v- (sgeo.curves:curve-point curve hi)
                                                             (sgeo.curves:curve-point curve lo))
                                              (/ 1d0 (- hi lo)))))
        (is (vector-approximately= finite-difference (sgeo.curves:curve-derivative curve u) 1d-5)))))
  (let ((line (sgeo.curves:make-bspline-curve #((0d0 0d0 0d0) (1d0 0d0 0d0)) :degree 1)))
    (is (vector-approximately= (sgeo.curves:curve-derivative line 0.5d0) (sgeo.math:make-vec3 1 0 0)))))

(test surface-tessellation-and-lathe-topology
  (let* ((grid (make-array '(2 2) :initial-contents
                           (list (list (sgeo.math:make-vec3 0 0 0) (sgeo.math:make-vec3 0 1 0))
                                 (list (sgeo.math:make-vec3 1 0 0) (sgeo.math:make-vec3 1 1 0)))))
         (surface (sgeo.curves:make-bezier-surface grid))
         (patch (sgeo.curves:tessellate-surface surface :u-segments 2 :v-segments 2))
         (lathe (sgeo.curves:lathe-surface #((0d0 0d0) (1d0 0d0) (1d0 1d0) (0d0 1d0)) :segments 12)))
    (is (sgeo.geometry:validate-mesh patch))
    (is (sgeo.geometry:validate-mesh lathe))
    (is (= 0 (getf (sgeo.geometry:mesh-counts lathe) :boundary-edges)))))

(test sweep-produces-editable-boundaries-and-rejects-degenerate-frames
  (let* ((path (sgeo.curves:make-polyline-curve #((0d0 0d0 0d0) (0d0 0d0 2d0))))
         (profile #((-0.5d0 -0.5d0) (0.5d0 -0.5d0) (0.5d0 0.5d0) (-0.5d0 0.5d0)))
         (sweep (sgeo.curves:sweep-curve path profile :path-segments 8))
         (collapsed (sgeo.curves:make-polyline-curve #((0d0 0d0 0d0) (0d0 0d0 0d0)))))
    (is (sgeo.geometry:validate-mesh sweep))
    (is (= 8 (getf (sgeo.geometry:mesh-counts sweep) :boundary-edges)))
    (signals sgeo.core:validation-error (sgeo.curves:sweep-curve collapsed profile :path-segments 4))))

(test invalid-curve-domains-and-profiles-are-rejected
  (let ((curve (sgeo.curves:make-polyline-curve #((0 0 0) (1 0 0)))))
    (signals sgeo.core:validation-error (sgeo.curves:curve-point curve 1.1d0))
    (signals sgeo.core:validation-error (sgeo.curves:lathe-surface #(( -1 0) (1 1))))))
