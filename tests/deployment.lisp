(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %deployment-test-root ()
  (merge-pathnames
   (format nil "sgeo-deployment-test-~36R-~36R/"
           (get-universal-time) (random most-positive-fixnum))
   (uiop:ensure-directory-pathname (uiop:temporary-directory))))

(defun %deployment-write-file (root relative contents)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output :if-exists :supersede
                                  :if-does-not-exist :create :external-format :utf-8)
      (write-string contents stream))
    path))

(defun %deployment-file-octets (path)
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length stream) :element-type '(unsigned-byte 8))))
      (read-sequence bytes stream)
      bytes)))

(defun %deployment-other-target (target)
  (case target (:linux :windows) (:windows :macos) (:macos :linux)))

(test deployment-registration-validates-entry-and-preserves-config
  (let* ((root (%deployment-test-root))
         (name (string-downcase
                (format nil "deployment-fixture-~36R" (random most-positive-fixnum))))
         (source (%deployment-write-file root #P"assets/scene.sgeo" "scene"))
         (app (sgeo.deployment:register-application
               name :entry-point 'deployment-test-entry :systems '(:sgeo/game)
               :version "2.4.1" :target :desktop
               :assets (list (list :name "scene" :source source)))))
    (unwind-protect
         (let* ((description (sgeo.deployment::%application-description app root))
                (asset (first (getf description :assets))))
           (is (eq app (sgeo.deployment:find-application name)))
           (is (string= name (sgeo.deployment:application-name app)))
           (is (string= "2.4.1" (sgeo.deployment:application-version app)))
           (is (eq 'deployment-test-entry (sgeo.deployment:application-entry-point app)))
           (is (equal '(:sgeo/game) (sgeo.deployment:application-systems app)))
           (is (equal '("sgeo/game") (getf description :systems)))
           (is (equal (list "SGEO.TESTS" "DEPLOYMENT-TEST-ENTRY")
                      (getf description :entry)))
           (is (equal source (getf asset :source)))
           (signals sgeo.deployment:build-error
             (sgeo.deployment:register-application "bad-entry" :entry-point nil :systems '(:sgeo)))
           (signals sgeo.deployment:build-error
             (sgeo.deployment:register-application "no-systems"
                                                   :entry-point 'deployment-test-entry :systems nil))
           (signals sgeo.deployment:build-error
             (sgeo.deployment:register-application "bad-target"
                                                   :entry-point 'deployment-test-entry
                                                   :systems '(:sgeo) :target :wasm)))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test deployment-resource-path-uses-host-layout-and-rejects-traversal
  (let* ((root (%deployment-test-root))
         (sgeo.deployment:*application-directory* root)
         (relative "levels/one.sgeo")
         (expected (ecase (sgeo.deployment:host-target)
                     (:linux (merge-pathnames "assets/levels/one.sgeo" root))
                     (:windows (merge-pathnames "resources/levels/one.sgeo" root))
                     (:macos (merge-pathnames "Resources/levels/one.sgeo" root))))
         (actual (sgeo.deployment:application-resource-path relative)))
    (unwind-protect
         (progn
           (is (equalp expected actual))
           (signals sgeo.deployment:packaging-error
             (sgeo.deployment:application-resource-path "../outside.txt"))
           (signals sgeo.deployment:packaging-error
             (sgeo.deployment:application-resource-path #P"/tmp/outside.txt"))
           (signals sgeo.deployment:packaging-error
             (sgeo.deployment:application-resource-path "levels/../../outside.txt")))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test deployment-build-refuses-cross-host-and-reused-output
  (let* ((root (%deployment-test-root))
         (entry 'deployment-test-entry)
         (foreign (sgeo.deployment:register-application
                   (format nil "foreign-build-~36R" (random most-positive-fixnum))
                   :entry-point entry :systems '(:sgeo/game)
                   :target (%deployment-other-target (sgeo.deployment:host-target))))
         (native (sgeo.deployment:register-application
                  (format nil "reuse-build-~36R" (random most-positive-fixnum))
                  :entry-point entry :systems '(:sgeo/game)))
         (reused (merge-pathnames #P"already-built/" root)))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames #P".placeholder" root))
           (signals sgeo.deployment:build-error
             (sgeo.deployment:build-application foreign :project-root root
                                                :output-directory "cross/"))
           (is (not (probe-file (merge-pathnames #P"cross/" root))))
           (%deployment-write-file root #P"already-built/keep.txt" "do not replace")
           (signals sgeo.deployment:build-error
             (sgeo.deployment:build-application native :project-root root
                                                :output-directory reused))
           (is (string= "do not replace"
                        (uiop:read-file-string (merge-pathnames #P"keep.txt" reused)))))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test deployment-asset-directory-expansion-is-stable-and-rejects-overlap
  (let* ((root-a (%deployment-test-root))
         (root-b (%deployment-test-root))
         (pack-a (merge-pathnames #P"assets-a.sgp" root-a))
         (pack-b (merge-pathnames #P"assets-b.sgp" root-b))
         (collision-pack (merge-pathnames #P"collision.sgp" root-a)))
    (unwind-protect
         (progn
           (%deployment-write-file root-a #P"data/one.bin" "one")
           (%deployment-write-file root-a #P"data/nested/two.bin" "two")
           (%deployment-write-file root-b #P"data/one.bin" "one")
           (%deployment-write-file root-b #P"data/nested/two.bin" "two")
           (let* ((assets-a (sgeo.deployment::%absolute-assets (list "data/") root-a))
                  (assets-b (sgeo.deployment::%absolute-assets (list "data/") root-b))
                  (names-a (mapcar (lambda (spec) (getf spec :name)) assets-a))
                  (names-b (mapcar (lambda (spec) (getf spec :name)) assets-b)))
             (is (= 2 (length assets-a)))
             (is (equal names-a names-b))
             (sgeo.assets:compile-assets assets-a pack-a)
             (sgeo.assets:compile-assets assets-b pack-b)
             (is (equalp (%deployment-file-octets pack-a)
                         (%deployment-file-octets pack-b)))
             (signals sgeo.assets:asset-validation-error
               (sgeo.assets:compile-assets
                (sgeo.deployment::%absolute-assets (list "data/" "data/one.bin") root-a)
                collision-pack))))
      (dolist (root (list root-a root-b))
        (when (probe-file root)
          (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))))

(test deployment-packed-game-consumes-geometry-and-pcm-products-headlessly
  (let* ((root (%deployment-test-root))
         (project-root (asdf:system-source-directory :sgeo))
         (geometry (merge-pathnames #P"assets/game/geometry.sgeo" project-root))
         (pcm (merge-pathnames #P"assets/game/collect.pcm" project-root))
         (pack-path (merge-pathnames #P"assets/game.sgp" root)))
    (unwind-protect
         (progn
           (ensure-directories-exist pack-path)
           (sgeo.assets:compile-assets
            (list (list :name "geometry" :source geometry :importer "scene")
                  (list :name "collect-tone" :source pcm :importer "bytes"))
            pack-path)
           (multiple-value-bind (world game)
               (uiop:symbol-call :sgeo.game :make-packed-game pack-path)
             (unwind-protect
                  (let* ((collect-source
                           (uiop:symbol-call :sgeo.examples.simulation
                                             :game-state-collect-source game))
                         (buffer (sgeo.audio:audio-source-buffer collect-source)))
                    (is (eq :playing (sgeo.examples.simulation:game-status game)))
                    (is (eq world (sgeo.scene:scene-object-world
                                   (sgeo.examples.simulation:game-player game))))
                    (is (= (floor (with-open-file (stream pcm :direction :input
                                                               :element-type '(unsigned-byte 8))
                                    (file-length stream))
                                  2)
                           (length (sgeo.audio:audio-buffer-samples buffer))))
                    (is (>= (length (sgeo.physics:physics-bodies
                                    (sgeo.examples.simulation:game-physics game)))
                            10)))
               (sgeo.simulation:detach-simulation world :close-audio t))))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))
