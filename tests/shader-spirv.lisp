(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(defun %spirv-test-modules ()
  (let* ((vertex
           (sgeo.shader:compile-shader-form
            'spirv-test-vertex :vertex
            '((position :vec3 :location 0) (uv :vec2 :location 1)
              (frame (:struct (:model :mat4)) :uniform :binding 0 :std140))
            '((values (:position (* (field frame model) (vec4 position 1.0)))
                      (:uv uv)))))
         (fragment
           (sgeo.shader:compile-shader-form
            'spirv-test-fragment :fragment
            '((uv :vec2 :location 0) (albedo :sampler2d :uniform :binding 1))
            '((:color (texture albedo uv))))))
    (values (sgeo.shader:shader-definition-sgir vertex)
            (sgeo.shader:shader-definition-sgir fragment))))

(defun %spirv-validation-tool ()
  (let* ((bundled (merge-pathnames
                   ".cache/vulkan-tools/usr/bin/spirv-val"
                   (asdf:system-source-directory :sgeo)))
         (path (uiop:getenv "PATH")))
    (or (and (probe-file bundled) bundled)
        (when path
          (loop for start = 0 then (1+ end)
                for end = (position #\: path :start start)
                for directory = (subseq path start end)
                for candidate = (merge-pathnames
                                 "spirv-val"
                                 (uiop:ensure-directory-pathname directory))
                when (probe-file candidate) return candidate
                while end)))))

(defun %validate-spirv-file (validator pathname)
  (multiple-value-bind (output error-output status)
      (uiop:run-program (list (namestring validator) "--target-env" "vulkan1.2"
                              (namestring pathname))
                        :output :string :error-output :string
                        :ignore-error-status t)
    (unless (zerop status)
      (error "spirv-val rejected ~a (status ~d):~%~a~%~a"
             pathname status output error-output))
    t))

(defun %same-interface-name-p (interface name)
  (string-equal (princ-to-string (getf interface :name))
                (princ-to-string name)))

(test shader-spirv-emits-vertex-and-fragment-binary
  (multiple-value-bind (vertex fragment) (%spirv-test-modules)
    (multiple-value-bind (vertex-bytes vertex-metadata)
        (sgeo.shader:compile-shader-to-spirv vertex)
      (is (typep vertex-bytes '(vector (unsigned-byte 8))))
      (is (zerop (mod (length vertex-bytes) 4)))
      (is (equalp #(3 2 35 7) (subseq vertex-bytes 0 4)))
      (is (eq :vertex (getf vertex-metadata :stage)))
      (is (find :position (getf vertex-metadata :interfaces)
                :key (lambda (interface) (getf interface :name)))))
    (multiple-value-bind (fragment-bytes fragment-metadata)
        (sgeo.shader:compile-shader-to-spirv fragment)
      (is (typep fragment-bytes '(vector (unsigned-byte 8))))
      (is (zerop (mod (length fragment-bytes) 4)))
      (is (eq :fragment (getf fragment-metadata :stage)))
      (is (some (lambda (interface)
                  (%same-interface-name-p interface :albedo))
                (getf fragment-metadata :interfaces))))))

(test shader-spirv-file-writing-and-deterministic-ids
  (multiple-value-bind (vertex fragment) (%spirv-test-modules)
    (declare (ignore fragment))
    (let ((pathname (merge-pathnames "sgeo-shader-spirv-test.spv"
                                     (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (sgeo.shader:write-shader-spirv vertex pathname)
             (let ((written (with-open-file (stream pathname :element-type '(unsigned-byte 8))
                              (let ((bytes (make-array (file-length stream)
                                                       :element-type '(unsigned-byte 8))))
                                (read-sequence bytes stream)
                                bytes)))
                   (again (sgeo.shader:compile-shader-to-spirv vertex)))
               (is (equalp written again))))
        (when (probe-file pathname) (delete-file pathname))))))

(test shader-spirv-modules-pass-vulkan-validator-when-available
  (let ((validator (%spirv-validation-tool)))
    (unless validator (skip "spirv-val não está disponível para validar os módulos."))
    (when validator
      (multiple-value-bind (vertex fragment) (%spirv-test-modules)
        (dolist (module (list vertex fragment))
          (let ((pathname (merge-pathnames
                           (format nil "sgeo-spirv-~36r.spv" (random most-positive-fixnum))
                           (uiop:temporary-directory))))
            (unwind-protect
                 (progn
                   (sgeo.shader:write-shader-spirv module pathname)
                   (%validate-spirv-file validator pathname)
                   (is (equal t t)))
              (when (probe-file pathname) (delete-file pathname)))))))))

(test shader-spirv-validates-pbr-shadow-and-tone-passes
  (let ((validator (%spirv-validation-tool)))
    (unless validator (skip "spirv-val não está disponível para validar os passes."))
    (when validator
      (dolist (kind '(:pbr :shadow :tone))
        (let ((program (sgeo.render:compile-graphics-program
                        (sgeo.render:standard-shader-sources kind))))
          (dolist (stage '(:vertex :fragment))
            (let ((bytes (getf program stage)))
              (when bytes
                (let ((pathname (merge-pathnames
                                 (format nil "sgeo-~(~a~)-~(~a~)-~36r.spv"
                                         kind stage (random most-positive-fixnum))
                                 (uiop:temporary-directory))))
                  (unwind-protect
                       (progn
                         (with-open-file (stream pathname :direction :output
                                                 :if-exists :supersede :if-does-not-exist :create
                                                 :element-type '(unsigned-byte 8))
                           (write-sequence bytes stream))
                         (%validate-spirv-file validator pathname)
                         (is (equal t t)))
                    (when (probe-file pathname) (delete-file pathname))))))))))))

(test shader-spirv-rejects-invalid-and-unsupported-stage
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'spirv-invalid-interface :vertex '((position :vec3))
     '((:position (vec4 position 1.0)))))
  (signals sgeo.shader:shader-interface-error
    (sgeo.shader:compile-shader-form
     'spirv-compute-not-supported :compute nil '((:value 1.0)))))
