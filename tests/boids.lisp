(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(test boids-object-and-packed-paths-match-and-remain-live
  (multiple-value-bind (object-world object-flock) (sgeo.examples.simulation:make-boids-world :count 12)
    (multiple-value-bind (packed-world packed-flock) (sgeo.examples.simulation:make-boids-world :count 12 :mode :packed)
      (let ((first-boid (aref (sgeo.examples.simulation:flock-boids object-flock) 0)))
        (setf (sgeo.examples.simulation:boid-max-speed first-boid) 0.5d0)
        (setf (sgeo.examples.simulation:boid-max-speed (aref (sgeo.examples.simulation:flock-boids packed-flock) 0)) 0.5d0)
        (dotimes (i 30) (sg:update-world object-world (/ 1d0 60d0)) (sg:update-world packed-world (/ 1d0 60d0)))
        (loop for a across (sgeo.examples.simulation:flock-boids object-flock)
              for b across (sgeo.examples.simulation:flock-boids packed-flock) do
          (is (vector-approximately= (sg:transform-position (sg:scene-object-local-transform a))
                                     (sg:transform-position (sg:scene-object-local-transform b)))))
        (is (eq first-boid (aref (sgeo.examples.simulation:flock-boids object-flock) 0)))
        (is (<= (sg:vector-length (sgeo.examples.simulation:boid-velocity first-boid)) 0.50000001d0))
        (let* ((name 'sgeo.examples.simulation:update-flock) (previous (fdefinition name)) (calls 0))
          (unwind-protect
              (progn (setf (fdefinition name) (lambda (flock dt) (incf calls) (funcall previous flock dt)))
                     (sg:update-world object-world (/ 1d0 60d0))
                     (is (= 1 calls))
                     (is (eq first-boid (aref (sgeo.examples.simulation:flock-boids object-flock) 0))))
            (setf (fdefinition name) previous)))))))
