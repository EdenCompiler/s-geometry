(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %asset-test-path (name)
  (merge-pathnames (format nil "sgeo-assets-~A-~D-~D" name (get-universal-time) (random 1000000))
                   (uiop:temporary-directory)))

(defun %asset-write-bytes (path bytes)
  (with-open-file (stream path :direction :output :if-exists :supersede
                          :if-does-not-exist :create :element-type '(unsigned-byte 8))
    (write-sequence bytes stream))
  path)

(defun %asset-write-text (path text)
  (with-open-file (stream path :direction :output :if-exists :supersede
                          :if-does-not-exist :create :external-format :utf-8)
    (write-string text stream))
  path)

(defun %asset-read-bytes (path)
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length stream) :element-type '(unsigned-byte 8))))
      (read-sequence bytes stream)
      bytes)))

(defun %asset-cleanup (&rest paths)
  (dolist (path paths) (when (probe-file path) (ignore-errors (delete-file path)))))

(test asset-pack-is-deterministic-and-safe-data
  (let* ((source-a (%asset-test-path "first.src"))
         (source-b (%asset-test-path "second.src"))
         (pack-a (%asset-test-path "a.sgp")) (pack-b (%asset-test-path "b.sgp"))
         (source (map '(vector (unsigned-byte 8)) #'char-code "#.(error \"must not run\")")))
    (unwind-protect
         (progn
           (%asset-write-bytes source-a source)
           (%asset-write-bytes source-b source)
           (sgeo.assets:compile-assets (list (list :name "raw" :source source-a)) pack-a)
           (sgeo.assets:compile-assets (list (list :name "raw" :source source-b)) pack-b)
           (is (equalp (%asset-read-bytes pack-a) (%asset-read-bytes pack-b)))
           (let* ((pack (sgeo.assets:load-asset-pack pack-a))
                  (asset (sgeo.assets:find-packed-asset pack "raw")))
             (is (string= (sgeo.assets:packed-asset-id asset)
                          (sgeo.assets:packed-asset-id (sgeo.assets:find-packed-asset pack
                                                                                       (sgeo.assets:packed-asset-id asset)))))
             (is (equalp source (sgeo.assets:packed-asset-bytes asset)))
             (is (sgeo.assets:asset-pack-current-p pack (list (list :name "raw" :source source-a))))))
      (%asset-cleanup source-a source-b pack-a pack-b))))

(test asset-cache-invalidates-on-dependency-and-importer-changes
  (let* ((source-a (%asset-test-path "dependency.src"))
         (source-b (%asset-test-path "dependent.src"))
         (pack-path (%asset-test-path "cache.sgp"))
         (manifest (list (list :name "base" :source source-a)
                         (list :name "derived" :source source-b :dependencies '("base")))))
    (unwind-protect
         (progn
           (%asset-write-bytes source-a #(1 2 3))
           (%asset-write-bytes source-b #(8 9))
           (let ((pack (sgeo.assets:load-or-build-asset-pack manifest pack-path)))
             (is (sgeo.assets:asset-pack-current-p pack manifest))
             (is (not (sgeo.assets:asset-pack-current-p
                       pack (list (list :name "base" :source source-a :compression :fast)
                                  (list :name "derived" :source source-b
                                        :dependencies '("base"))))))
             (%asset-write-bytes source-a #(1 2 4))
             (is (not (sgeo.assets:asset-pack-current-p pack manifest)))
             (let ((rebuilt (sgeo.assets:load-or-build-asset-pack manifest pack-path)))
               (is (sgeo.assets:asset-pack-current-p rebuilt manifest))
               (is (not (string= (sgeo.assets:packed-asset-id (sgeo.assets:find-packed-asset pack "derived"))
                                 (sgeo.assets:packed-asset-id (sgeo.assets:find-packed-asset rebuilt "derived"))))))
           (sgeo.assets:register-importer "asset-test-versioned"
                                          (lambda (pathname spec)
                                            (declare (ignore spec))
                                            (sgeo.assets::%read-bytes pathname))
                                          :version "1")
           (let ((manifest-v1 (list (list :name "raw" :source source-b :importer "asset-test-versioned")))
                 (manifest-v2 nil))
             (let ((pack (sgeo.assets:load-or-build-asset-pack manifest-v1 pack-path)))
               (sgeo.assets:register-importer "asset-test-versioned"
                                              (lambda (pathname spec)
                                                (declare (ignore spec))
                                                (sgeo.assets::%read-bytes pathname))
                                              :version "2")
               (setf manifest-v2 manifest-v1)
               (is (not (sgeo.assets:asset-pack-current-p pack manifest-v2)))
               (is (sgeo.assets:asset-pack-current-p
                    (sgeo.assets:load-or-build-asset-pack manifest-v2 pack-path) manifest-v2))))))
      (sgeo.assets:unregister-importer "asset-test-versioned")
      (%asset-cleanup source-a source-b pack-path))))

(test asset-pack-rejects-corruption-and-truncation
  (let* ((source (%asset-test-path "integrity.src")) (path (%asset-test-path "integrity.sgp"))
         (corrupt (%asset-test-path "corrupt.sgp")) (truncated (%asset-test-path "truncated.sgp"))
         (huge-length (%asset-test-path "huge-length.sgp")))
    (unwind-protect
         (progn
           (%asset-write-bytes source #(42 43 44 45))
           (sgeo.assets:compile-assets (list (list :name "integrity" :source source)) path)
           (let* ((bytes (%asset-read-bytes path))
                  (changed (copy-seq bytes))
                  (short (subseq bytes 0 (1- (length bytes))))
                  (bad-length (copy-seq bytes)))
             (setf (aref changed (1- (length changed))) (logxor 1 (aref changed (1- (length changed)))))
             ;; O primeiro comprimento de string começa após magic, versão e contagem.
             (fill bad-length #xff :start 16 :end 20)
             (%asset-write-bytes corrupt changed)
             (%asset-write-bytes truncated short)
             (%asset-write-bytes huge-length bad-length))
           (signals sgeo.assets:asset-pack-error (sgeo.assets:load-asset-pack corrupt))
           (signals sgeo.assets:asset-pack-error (sgeo.assets:load-asset-pack truncated))
           (signals sgeo.assets:asset-pack-error (sgeo.assets:load-asset-pack huge-length))
           (signals sgeo.assets:asset-pack-error (sgeo.assets::%decode-utf8 #(237 160 128))))
      (%asset-cleanup source path corrupt truncated huge-length))))

(test asset-compile-validates-names-dependencies-and-rolls-back
  (let* ((source (%asset-test-path "rollback.src")) (path (%asset-test-path "rollback.sgp")))
    (unwind-protect
         (progn
           (%asset-write-bytes source #(5 6 7))
           (sgeo.assets:compile-assets (list (list :name "good" :source source)) path)
           (let ((before (%asset-read-bytes path)))
             (sgeo.assets:register-importer "asset-test-failing"
                                            (lambda (pathname spec)
                                              (declare (ignore pathname spec))
                                              (error "intentional importer failure")))
             (unwind-protect
                  (progn
                    (signals error
                      (sgeo.assets:compile-assets
                       (list (list :name "bad" :source source :importer "asset-test-failing")) path))
                    (is (equalp before (%asset-read-bytes path))))
               (sgeo.assets:unregister-importer "asset-test-failing")))
           (signals sgeo.assets:asset-validation-error
             (sgeo.assets:compile-assets (list (list :name "../escape" :source source)) path))
           (signals sgeo.assets:asset-validation-error
             (sgeo.assets:compile-assets
              (list (list :name "a" :source source :dependencies '("b"))
                    (list :name "b" :source source :dependencies '("a"))) path))
           (let ((cyclic (list (list :name "loop" :source source))))
             (setf (cdr cyclic) cyclic)
             (signals sgeo.assets:asset-validation-error
               (sgeo.assets:compile-assets cyclic path))))
      (%asset-cleanup source path))))

(test asset-gltf-importer-canonicalizes-and-tracks-external-resources
  (let* ((fixture (merge-pathnames "tests/fixtures/gltf/minimal.gltf"
                                   (asdf:system-source-directory :sgeo)))
         (source (%asset-test-path "external.gltf"))
         (sidecar (merge-pathnames "sidecar.bin" source))
         (dependency-source (%asset-test-path "external.bin"))
         (pack-a (%asset-test-path "gltf-a.sgp"))
         (pack-b (%asset-test-path "gltf-b.sgp"))
         (text (uiop:read-file-string fixture))
         (uri-start (search "data:application/octet-stream;base64," text))
         (uri-end (and uri-start (position #\" text :start uri-start)))
         (uri (and uri-start uri-end (subseq text uri-start uri-end)))
         (bytes (and uri (sgeo.gltf::%base64-decode (subseq uri (1+ (position #\, uri))))))
         (new-text (and uri-start uri-end
                        (concatenate 'string (subseq text 0 uri-start) "sidecar.bin"
                                     (subseq text uri-end))))
         (manifest nil))
    (unwind-protect
         (progn
           (is (and bytes new-text))
           (%asset-write-text source new-text)
           (%asset-write-bytes sidecar bytes)
           (%asset-write-bytes dependency-source bytes)
           (setf manifest
                 (list (list :name "geometry-data" :source dependency-source)
                       (list :name "fixture" :source source :importer "gltf"
                             :dependencies '("geometry-data")
                             :external-resources '(("sidecar.bin" . "geometry-data")))))
           (sgeo.assets:compile-assets manifest pack-a)
           (sgeo.assets:compile-assets (reverse manifest) pack-b)
           (is (equalp (%asset-read-bytes pack-a) (%asset-read-bytes pack-b)))
           (let ((pack (sgeo.assets:load-asset-pack pack-a)))
             (is (sgeo.assets:asset-pack-current-p pack manifest))
             (let ((changed (copy-seq bytes)))
               (setf (aref changed (1- (length changed)))
                     (logxor #xff (aref changed (1- (length changed)))))
               (%asset-write-bytes sidecar changed)
               (%asset-write-bytes dependency-source changed)
               (is (not (sgeo.assets:asset-pack-current-p pack manifest))))))
      (%asset-cleanup source sidecar dependency-source pack-a pack-b))))

(test asset-watcher-polls-rebuilds-and-keeps-last-good-pack
  (let* ((source (%asset-test-path "watch.src"))
         (path (%asset-test-path "watch.sgp"))
         (fail-p nil) (errors nil)
         (manifest (list (list :name "watched" :source source
                               :importer "asset-test-watcher")))
         (watcher nil) (old-pack-bytes nil))
    (sgeo.assets:register-importer
     "asset-test-watcher"
     (lambda (pathname spec)
       (declare (ignore spec))
       (when fail-p (error "Intentional watch rebuild failure."))
       (sgeo.assets::%read-bytes pathname)))
    (unwind-protect
         (progn
           (%asset-write-bytes source #(1 2 3))
           (setf watcher (sgeo.assets:make-asset-watcher
                          manifest path :on-error (lambda (condition) (push condition errors))))
           (setf old-pack-bytes (%asset-read-bytes path))
           (multiple-value-bind (pack changed condition) (sgeo.assets:poll-asset-watcher watcher)
             (is (eq pack (sgeo.assets:asset-watcher-pack watcher)))
             (is (not changed))
             (is (null condition)))
           (%asset-write-bytes source #(4 5 6))
           (setf fail-p t)
           (multiple-value-bind (pack changed condition) (sgeo.assets:poll-asset-watcher watcher)
             (is (not changed))
             (is (not (null condition)))
             (is (eq pack (sgeo.assets:asset-watcher-pack watcher)))
             (is (sgeo.assets:asset-watcher-last-error watcher))
             (is (= 1 (length errors)))
             (is (equalp old-pack-bytes (%asset-read-bytes path))))
           (setf fail-p nil)
           (multiple-value-bind (pack changed condition) (sgeo.assets:poll-asset-watcher watcher)
             (is (not (null changed)))
             (is (null condition))
             (is (equalp #(4 5 6)
                         (sgeo.assets:packed-asset-bytes
                          (sgeo.assets:find-packed-asset pack "watched")))))
           (sgeo.assets:stop-asset-watcher watcher)
           (is (sgeo.assets:asset-watcher-disposed-p watcher))
           (signals sgeo.assets:asset-validation-error
             (sgeo.assets:poll-asset-watcher watcher)))
      (when watcher (sgeo.assets:stop-asset-watcher watcher))
      (sgeo.assets:unregister-importer "asset-test-watcher")
      (%asset-cleanup source path))))

(test asset-scene-preserves-procedural-local-id-parameters
  (let* ((graph (sg:make-dependency-graph))
         (literal '(:id 99999999 :object-id 88888888 :value (:parent-id 77777777)))
         (source (%asset-test-path "procedural.sgeo"))
         (pack-a (%asset-test-path "procedural-a.sgp"))
         (pack-b (%asset-test-path "procedural-b.sgp")))
    (sg:define-generator 'asset-procedural-fixture nil
                        (lambda (parameters dependencies)
                          (declare (ignore parameters dependencies))
                          (sg:make-half-edge-box)))
    (sg:add-parameter-node graph :literal literal)
    (sg:add-generator-node graph :mesh 'asset-procedural-fixture '(:literal))
    (unwind-protect
         (let* ((object (sg:make-procedural-object graph :mesh))
                (world (sg:make-world :root object))
                (manifest (list (list :name "procedural" :source source :importer "scene"))))
           (sgeo.serialization:save-world world source)
           (sgeo.assets:compile-assets manifest pack-a)
           (sgeo.assets:compile-assets manifest pack-b)
           (is (equalp (%asset-read-bytes pack-a) (%asset-read-bytes pack-b)))
           (let* ((bytes (sgeo.assets:packed-asset-bytes
                          (sgeo.assets:find-packed-asset (sgeo.assets:load-asset-pack pack-a) "procedural")))
                  (*read-eval* nil)
                  (reopened (sgeo.serialization:world-from-data
                             (read-from-string (sgeo.assets::%decode-utf8 bytes))))
                  (restored (sg:world-root reopened)))
             (is (typep restored 'sg:procedural-object))
             (is (equal literal (sg:node-value (sg:procedural-graph restored) :literal)))
             (sg:update-world reopened 0d0)
             (is (= 6 (length (sg:mesh-faces (sg:mesh-object-geometry restored)))))))
      (%asset-cleanup source pack-a pack-b))))
