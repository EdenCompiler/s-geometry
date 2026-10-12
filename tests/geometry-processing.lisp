(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(test geometry-processing-result-contract
  (let* ((geometry (sgeo.geometry:make-box))
         (positions (sgeo.geometry:mesh-positions geometry))
         (normals (sgeo.geometry:mesh-normals geometry))
         (result (sgeo.geometry-processing:make-geometry-processing-result
                  :geometry geometry :source-revision 17 :positions positions :normals normals
                  :operation :deform :backend :opengl)))
    (setf (aref positions 0) 888d0)
    (is (eq geometry (sgeo.geometry-processing:processing-result-geometry result)))
    (is (= 17 (sgeo.geometry-processing:processing-result-source-revision result)))
    (is (eq :deform (sgeo.geometry-processing:processing-result-operation result)))
    (is (eq :opengl (sgeo.geometry-processing:processing-result-backend result)))
    (is (/= 888d0 (aref (sgeo.geometry-processing:processing-result-positions result) 0)))
    (is (= (length positions) (length (sgeo.geometry-processing:processing-result-positions result))))
    (is (= (length normals) (length (sgeo.geometry-processing:processing-result-normals result))))
    (let ((returned-positions (sgeo.geometry-processing:processing-result-positions result))
          (returned-normals (sgeo.geometry-processing:processing-result-normals result)))
      (setf (aref returned-positions 0) 999d0
            (aref returned-normals 0) 999d0)
      (is (/= 999d0 (aref (sgeo.geometry-processing:processing-result-positions result) 0)))
      (is (/= 999d0 (aref (sgeo.geometry-processing:processing-result-normals result) 0))))))

(test geometry-processing-capability-contract
  (let ((capabilities
          (sgeo.geometry-processing::%make-compute-capabilities
           :supported-p nil :backend :opengl :reason "OpenGL 3.3 não oferece compute shader."
           :version "3.3" :device "Headless")))
    (is (not (sgeo.geometry-processing:capabilities-supported-p capabilities)))
    (is (eq :opengl (sgeo.geometry-processing:capabilities-backend capabilities)))
    (is (string= "3.3" (sgeo.geometry-processing:capabilities-version capabilities)))
    (signals sgeo.geometry-processing:unsupported-compute-error
      (error 'sgeo.geometry-processing:unsupported-compute-error
             :reason (sgeo.geometry-processing:capabilities-reason capabilities)))))
