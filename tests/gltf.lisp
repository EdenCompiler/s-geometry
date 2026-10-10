(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %gltf-fixture (name)
  (asdf:system-relative-pathname "sgeo/gltf" (format nil "tests/fixtures/gltf/~a" name)))

(test gltf-imports-json-scene-and-preserves-material-metadata
  (let* ((asset (sgeo.gltf:import-gltf (%gltf-fixture "minimal.gltf")))
         (nodes (sgeo.gltf:gltf-nodes asset))
         (meshes (sgeo.gltf:gltf-meshes asset))
         (materials (sgeo.gltf:gltf-materials asset))
         (transform (sgeo.scene:scene-object-local-transform (aref nodes 0)))
         (material-data (sgeo.scene:pbr-material-data (aref materials 0))))
    (is (= 1 (length nodes)))
    (is (= 1 (length meshes)))
    (is (vector-approximately= #(1d0 2d0 3d0) (sgeo.math:transform-position transform)))
    (is (approximately= 0.25d0 (getf material-data :metallic)))
    (is (< (abs (- 0.7d0 (getf material-data :roughness))) 1d-6))
    (is (= 9 (length (sgeo.geometry:mesh-positions
                      (sgeo.scene:mesh-object-geometry (aref meshes 0))))))))

(test gltf-import-fails-unknown-required-extension-without-world-mutation
  (let* ((world (sgeo.scene:make-world))
         (root (sgeo.scene:world-root world))
         (before (length (sgeo.scene:scene-object-children root))))
    (signals error (sgeo.gltf:import-gltf (%gltf-fixture "unsupported-required.gltf") :world world))
    (is (= before (length (sgeo.scene:scene-object-children root))))))

(test gltf-export-import-glb-and-external-buffer
  (let* ((asset (sgeo.gltf:import-gltf (%gltf-fixture "minimal.gltf")))
         (directory (uiop:temporary-directory))
         (json-path (merge-pathnames "sgeo-gltf-roundtrip.gltf" directory))
         (glb-path (merge-pathnames "sgeo-gltf-roundtrip.glb" directory)))
    (unwind-protect
         (progn
           (sgeo.gltf:export-gltf (sgeo.gltf:gltf-world asset) json-path)
           (sgeo.gltf:export-gltf (sgeo.gltf:gltf-world asset) glb-path :binary t)
           (is (= 1 (length (sgeo.gltf:gltf-meshes (sgeo.gltf:import-gltf json-path)))))
           (is (= 1 (length (sgeo.gltf:gltf-meshes (sgeo.gltf:import-gltf glb-path)))))
           (is (probe-file (make-pathname :type "bin" :defaults json-path))))
      (dolist (path (list json-path glb-path (make-pathname :type "bin" :defaults json-path)))
        (when (probe-file path) (delete-file path))))))

(defun %gltf-channel (clip path)
  (find path (sgeo.animation:clip-tracks clip) :key (lambda (track) (first (sgeo.animation:track-path track)))))

(test gltf-bundled-character-imports-live-skin-and-all-channels
  (let* ((asset (sgeo.gltf:import-gltf
                (asdf:system-relative-pathname :sgeo "examples/assets/rigged-figure/RiggedFigure.gltf")))
         (world (sgeo.gltf:gltf-world asset))
         (object (aref (sgeo.gltf:gltf-meshes asset) 0))
         (clip (aref (sgeo.gltf:gltf-clips asset) 0))
         (player (sgeo.animation:play-animation world clip))
         (before (copy-seq (sgeo.geometry:render-mesh-positions (sgeo.animation:deformed-render-data object)))))
    (is (typep object 'sgeo.animation:deformable-mesh-object))
    (is (= 57 (length (sgeo.animation:clip-tracks clip))))
    (is (= 19 (length (sgeo.animation:skeleton-joints (sgeo.animation:mesh-skeleton object)))))
    (sgeo.animation:seek-animation player 0.4d0)
    (is (not (equalp before (sgeo.geometry:render-mesh-positions (sgeo.animation:deformed-render-data object)))))))

(test gltf-animation-skin-morph-stride-sparse-and-json-roundtrip
  (let* ((asset (sgeo.gltf:import-gltf (%gltf-fixture "animated.gltf")))
         (world (sgeo.gltf:gltf-world asset))
         (meshes (sgeo.gltf:gltf-meshes asset))
         (a (aref meshes 0)) (b (aref meshes 1)) (morph (aref meshes 2))
         (clip (aref (sgeo.gltf:gltf-clips asset) 0))
         (player (sgeo.animation:play-animation world clip))
         (directory (uiop:temporary-directory))
         (scene (merge-pathnames "sgeo-animated-test.sgeo" directory))
         (glb (merge-pathnames "sgeo-animated-test.glb" directory)))
    (unwind-protect
         (progn
           (is (= 3 (length meshes)))
           (is (not (eq a b)))
           (is (eq (sgeo.scene:mesh-object-geometry a) (sgeo.scene:mesh-object-geometry b)))
           (is (not (eq (sgeo.scene:scene-object-parent a) (sgeo.scene:scene-object-parent b))))
           (is (eq (sgeo.animation:mesh-skeleton a) (sgeo.animation:mesh-skeleton b)))
           (is (null (sgeo.animation:mesh-skeleton morph)))
           (is (= 9 (length (first (gethash :gltf-morph-tangents
                                (sg:object-metadata (sg:mesh-object-geometry morph)))))))
           (is (approximately= -0.5d0 (aref (sgeo.geometry:mesh-positions (sgeo.scene:mesh-object-geometry a)) 0)))
           (is (approximately= 1.5d0 (aref (sgeo.geometry:mesh-positions (sgeo.scene:mesh-object-geometry morph)) 7)))
           (is (approximately= 1d0 (aref (aref (sgeo.animation:mesh-joint-weights a) 0) 0)))
           (sgeo.animation:seek-animation player 1d0)
           (is (vector-approximately= #(1d0 0d0 0d0)
                  (sgeo.math:transform-position (sgeo.scene:scene-object-local-transform
                    (sgeo.scene:find-object world "Joint")))))
           (is (vector-approximately= #(1.5d0 1.5d0 1.5d0)
                  (sgeo.math:transform-scale (sgeo.scene:scene-object-local-transform
                    (sgeo.scene:find-object world "Skin B")))))
           (is (vector-approximately= #(0.5d0 0.25d0 0d0 0.125d0 0.375d0)
                                      (sgeo.animation:mesh-morph-weights morph)))
           (is (approximately= 0d0 (aref (sgeo.math::quaternion-data (sgeo.animation:sample-track (%gltf-channel clip :rotation) 1d0)) 2)))
           (is (eq :step (sgeo.animation:track-interpolation (%gltf-channel clip :rotation))))
           (is (eq :cubic-spline (sgeo.animation:track-interpolation (%gltf-channel clip :weights))))
           (let* ((rotation-clip (aref (sgeo.gltf:gltf-clips asset) 1))
                  (value (sgeo.animation:sample-track (%gltf-channel rotation-clip :rotation) 1d0)))
             (is (typep value 'sgeo.math:quaternion))
             (is (< (abs (- (sin (/ pi 8)) (aref (sgeo.math::quaternion-data value) 2))) 1d-6)))
           ;; O histórico copia strings JSON ajustáveis sem incluir a capacidade ociosa.
           (let ((editor (sgeo.editor:make-editor :world world)))
             (sgeo.editor:with-edit-transaction (editor "Material change")
               (sgeo.scene:set-pbr-material (sgeo.scene:mesh-object-material a) :metallic 0.6d0))
             (sgeo.editor:undo-edit editor)
             (sgeo.editor:redo-edit editor))
           (sgeo.serialization:save-world world scene)
           (let ((loaded (sgeo.serialization:load-world scene)))
             (sgeo.gltf:export-gltf loaded glb :binary t)
             (let* ((roundtrip (sgeo.gltf:import-gltf glb))
                    (new-clip (aref (sgeo.gltf:gltf-clips roundtrip) 0))
                    (weight-track (%gltf-channel new-clip :weights))
                    (material (aref (sgeo.gltf:gltf-materials roundtrip) 0))
                    (meta (gethash :gltf-material (sgeo.core:object-metadata material)))
                    (definition (sgeo.gltf::%json-unsafe (getf meta :definition)))
                    (extras (gethash "extras" definition)))
               (is (= 4 (length (sgeo.animation:clip-tracks new-clip))))
               (is (vector-approximately= #(0.5d0 0.25d0 0d0 0.125d0 0.375d0)
                                          (sgeo.animation:sample-track weight-track 1d0)))
               (is (eq 'yason:false (gethash "doubleSided" definition)))
               (is (eq 'yason:null (gethash "nullable" extras)))
               (is (equalp #() (gethash "empty" extras)))
               (is (eq 'yason:true (gethash "enabled" extras)))
               (is (string= "Material ç" (sgeo.core:object-name material)))
               (is (= 1 (length (sgeo.gltf:gltf-images roundtrip))))
               (is (= 1 (length (sgeo.gltf:gltf-textures roundtrip))))
               (is (= 9 (length (first (gethash :gltf-morph-tangents
                                  (sg:object-metadata (sg:mesh-object-geometry
                                    (sgeo.animation:track-target weight-track))))))))
               (is (< (abs (- 0.6d0 (getf (sgeo.scene:pbr-material-data material) :metallic))) 1d-6)))))
      (dolist (path (list scene glb)) (when (probe-file path) (delete-file path))))))

(test gltf-late-validation-failure-preserves-world-and-animations
  (let* ((world (sg:make-world)) (root (sg:world-root world))
         (path (merge-pathnames "sgeo-invalid-channel.gltf" (uiop:temporary-directory)))
         (document (with-open-file (stream (%gltf-fixture "animated.gltf"))
                     (yason:parse stream :json-arrays-as-vectors t))))
    (unwind-protect
         (progn
           (setf (gethash "uri" (aref (gethash "buffers" document) 0))
                 (format nil "data:application/octet-stream;base64,~A"
                   (sgeo.gltf::%base64-encode (sgeo.gltf::%read-bytes (%gltf-fixture "animated.bin")))))
           (setf (gethash "node" (gethash "target"
                   (aref (gethash "channels" (aref (gethash "animations" document) 0)) 3))) 999)
           (with-open-file (stream path :direction :output :if-exists :supersede) (yason:encode document stream))
           (signals error (sgeo.gltf:import-gltf path :world world))
           (is (null (sg:scene-object-children root)))
           (is (null (sg:world-animation-state world)))
           (is (null (gethash :gltf-sources (sg:object-metadata root)))))
      (when (probe-file path) (delete-file path)))))

(test gltf-merges-texture-libraries-with-image-and-sampler-remapping
  (let* ((asset (sgeo.gltf:import-gltf (%gltf-fixture "animated.gltf")))
         (world (sgeo.gltf:gltf-world asset))
         (input (merge-pathnames "sgeo-second-textures.gltf" (uiop:temporary-directory)))
         (output (merge-pathnames "sgeo-merged-textures.glb" (uiop:temporary-directory)))
         (document (with-open-file (stream (%gltf-fixture "animated.gltf"))
                     (yason:parse stream :json-arrays-as-vectors t :json-booleans-as-symbols t :json-nulls-as-keyword t))))
    (unwind-protect
         (progn
           (setf (gethash "uri" (aref (gethash "buffers" document) 0))
                 (format nil "data:application/octet-stream;base64,~A"
                   (sgeo.gltf::%base64-encode (sgeo.gltf::%read-bytes (%gltf-fixture "animated.bin"))))
                 (gethash "name" (aref (gethash "images" document) 0)) "Second image"
                 (gethash "name" (aref (gethash "materials" document) 0)) "Second material"
                 (gethash "magFilter" (aref (gethash "samplers" document) 0)) 9728)
           (with-open-file (stream input :direction :output :if-exists :supersede)
             ;; O YASON antigo representa NULL pelo símbolo, ao contrário do parser.
             (setf (gethash "nullable" (gethash "extras" (aref (gethash "materials" document) 0))) 'yason:null)
             (yason:encode document stream))
           (sgeo.gltf:import-gltf input :world world)
           (sgeo.gltf:export-gltf world output :binary t)
           (let* ((result (sgeo.gltf::%load-document output))
                  (textures (gethash "textures" result))
                  (materials (gethash "materials" result)))
             (is (= 2 (length textures)))
             (is (= 2 (length (gethash "images" result))))
             (is (= 2 (length (gethash "samplers" result))))
             (is (= 0 (gethash "source" (aref textures 0))))
             (is (= 1 (gethash "source" (aref textures 1))))
             (is (= 1 (gethash "sampler" (aref textures 1))))
             (is (= 1 (gethash "index" (gethash "baseColorTexture"
                       (gethash "pbrMetallicRoughness" (aref materials 1))))))))
      (dolist (path (list input output)) (when (probe-file path) (delete-file path))))))
