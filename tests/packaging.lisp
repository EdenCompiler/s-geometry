(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %make-package-fixture (root relative contents)
  (let ((path (merge-pathnames relative root)))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output :if-exists :supersede
                                     :if-does-not-exist :create
                                     :external-format :utf-8)
      (write-string contents stream))
    path))

(defun %package-test-root ()
  (merge-pathnames
   (format nil "sgeo-package-test-~36R-~36R/"
           (get-universal-time) (random most-positive-fixnum))
   (uiop:ensure-directory-pathname (uiop:temporary-directory))))

(defun %host-package-layout (target root)
  (ecase target
    (:linux (values root (merge-pathnames #P"bin/Runner" root)
                    (merge-pathnames #P"Runner" root)
                    (merge-pathnames #P"share/applications/Runner.desktop" root)
                    (merge-pathnames #P"lib/libdemo.so" root)
                    (merge-pathnames #P"assets/levels/one.txt" root)
                    (merge-pathnames #P"MANIFEST.sha256" root)))
    (:windows (values root (merge-pathnames #P"Runner.exe" root)
                      (merge-pathnames #P"Runner.cmd" root)
                      nil
                      (merge-pathnames #P"demo.dll" root)
                      (merge-pathnames #P"resources/levels/one.txt" root)
                      (merge-pathnames #P"MANIFEST.sha256" root)))
    (:macos (let ((app (merge-pathnames #P"Runner.app/" root)))
              (values app (merge-pathnames #P"Contents/MacOS/Runner" app)
                      nil nil
                      (merge-pathnames #P"Contents/Frameworks/libdemo.dylib" app)
                      (merge-pathnames #P"Contents/Resources/levels/one.txt" app)
                      (merge-pathnames #P"MANIFEST.sha256" app))))))

(defun %file-octets (path)
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length stream) :element-type '(unsigned-byte 8))))
      (read-sequence bytes stream)
      bytes)))

(defun %replace-package-text (path text)
  (with-open-file (stream path :direction :output :if-exists :supersede
                               :if-does-not-exist :create :external-format :utf-8)
    (write-string text stream)))

(test package-application-builds-relocatable-host-layout-and-stable-manifest
  (let* ((root (%package-test-root))
         (inputs (merge-pathnames #P"inputs/" root))
         (source (%make-package-fixture inputs #P"runner" "native executable bytes"))
         (library-name (ecase (sgeo.deployment::%host-target)
                         (:linux "libdemo.so") (:windows "demo.dll") (:macos "libdemo.dylib")))
         (library (%make-package-fixture inputs (pathname library-name) "native library bytes"))
         (asset (%make-package-fixture inputs #P"assets/one.txt" "asset bytes"))
         (target (sgeo.deployment::%host-target))
         (destination (merge-pathnames #P"RunnerBundle/" root))
         (second-destination (merge-pathnames #P"rerun/RunnerBundle/" root)))
    (unwind-protect
         (let ((result (sgeo.deployment:package-application
                        source destination :name "Runner" :version "1.2.3" :target target
                        :native-libraries (list (cons library library-name))
                        :assets (list (cons asset "levels/one.txt"))
                        :diagnostics '("native build id: 42"))))
           (multiple-value-bind (app executable launcher desktop copied-library copied-asset manifest)
               (%host-package-layout target destination)
             (is (equalp (getf result :application) app))
             (is (probe-file executable))
             (is (or (null launcher) (probe-file launcher)))
             (is (or (null desktop) (probe-file desktop)))
             (is (probe-file copied-library))
             (is (probe-file copied-asset))
             (is (probe-file manifest))
             (is (probe-file (getf result :archive)))
             (is (equal (getf result :target) target))
             (is (member "native library bytes" (uiop:read-file-lines copied-library)
                         :test #'string=))
             (is (member "asset bytes" (uiop:read-file-lines copied-asset)
                         :test #'string=))
             (when desktop
               (let ((text (uiop:read-file-string desktop)))
                 (is (search "[Desktop Entry]" text))
                 (is (search "Exec=Runner %U" text))))
             (when (eq target :macos)
               (is (probe-file (merge-pathnames #P"Contents/Info.plist" app))))
             (let* ((first-manifest (uiop:read-file-string manifest))
                    (second-result (sgeo.deployment:package-application
                                    source second-destination :name "Runner" :version "1.2.3"
                                    :target target
                                    :native-libraries (list (cons library library-name))
                                    :assets (list (cons asset "levels/one.txt"))
                                    :diagnostics '("native build id: 42")))
                    (second-manifest (getf second-result :manifest)))
               (is (string= first-manifest (uiop:read-file-string second-manifest)))
               (is (search (ironclad:byte-array-to-hex-string
                            (ironclad:digest-file :sha256 source)) first-manifest))
               (is (search (ironclad:byte-array-to-hex-string
                            (ironclad:digest-file :sha256 copied-library)) first-manifest))
               (is (search "diagnostic native build id: 42" first-manifest))
               (when (eq target :linux)
                 (is (equalp (%file-octets (getf result :archive))
                             (%file-octets (getf second-result :archive)))))
               (is (plusp (length (getf result :diagnostics)))))))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test package-application-refuses-source-overlap-traversal-and-basename-collisions
  (let* ((root (%package-test-root))
         (inputs (merge-pathnames #P"inputs/" root))
         (source (%make-package-fixture inputs #P"runner" "exe"))
         (asset (%make-package-fixture inputs #P"asset.txt" "asset"))
         (library (%make-package-fixture inputs #P"copy.so" "library"))
         (inside-source (merge-pathnames #P"build/" inputs))
         (external-output (merge-pathnames #P"package/" root)))
    (unwind-protect
         (progn
           (signals error
             (sgeo.deployment:package-application source inside-source :name "Runner"))
           (is (not (probe-file inside-source)))
           (signals error
             (sgeo.deployment:package-application
              source external-output :name "Runner"
              :assets (list (cons asset "../escape.txt"))))
           (is (not (probe-file external-output)))
           (signals error
             (sgeo.deployment:package-application
              source external-output :name "Runner"
              :native-libraries (list (cons library "same.so"))
              :assets (list (cons asset "same.so"))))
           (is (not (probe-file external-output))))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test package-application-rejects-control-characters-in-destinations
  (let* ((root (%package-test-root))
         (source (%make-package-fixture root #P"runner" "exe"))
         (asset (%make-package-fixture root #P"asset.txt" "asset"))
         (destination (merge-pathnames #P"invalid/" root)))
    (unwind-protect
         (dolist (control (list #\Newline #\Return #\Tab))
           (let ((relative (format nil "levels/bad~Abin" control)))
             (signals error
               (sgeo.deployment:package-application
                source destination :name "Runner"
                :assets (list (cons asset relative))))
             (is (not (probe-file destination)))))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test package-application-rolls-back-when-generated-package-verification-fails
  (let* ((root (%package-test-root))
         (source (%make-package-fixture root #P"runner" "exe"))
         (target (sgeo.deployment::%host-target))
         (destination (merge-pathnames #P"failed/" root))
         (app (ecase target
                ((:linux :windows) destination)
                (:macos (merge-pathnames #P"Runner.app/" destination))))
         (leaf (sgeo.deployment::%directory-leaf app))
         (archive (make-pathname
                   :name (if (eq target :windows) leaf (concatenate 'string leaf ".tar"))
                   :type (if (eq target :windows) "zip" "gz")
                   :defaults (sgeo.deployment::%directory-parent app)))
         (original-verifier (symbol-function 'sgeo.deployment:verify-package)))
    (unwind-protect
         (progn
           ;; Force the validation branch to fail after files and manifest are written.
           (setf (symbol-function 'sgeo.deployment:verify-package)
                 (lambda (directory)
                   (declare (ignore directory))
                   nil))
           (signals error
             (sgeo.deployment:package-application
              source destination :name "Runner" :target target))
           (is (not (probe-file app)))
           (is (not (probe-file archive))))
      (setf (symbol-function 'sgeo.deployment:verify-package) original-verifier)
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test package-application-rejects-cross-target-builds
  (let* ((root (%package-test-root))
         (source (%make-package-fixture root #P"runner" "exe"))
         (host (sgeo.deployment::%host-target))
         (other (case host (:linux :windows) (:windows :macos) (:macos :linux))))
    (unwind-protect
         (signals error
           (sgeo.deployment:package-application source (merge-pathnames #P"cross/" root)
                                                :name "Runner" :target other))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(test verify-package-checks-content-manifest-and-tree
  (let* ((root (%package-test-root))
         (inputs (merge-pathnames #P"inputs/" root))
         (source (%make-package-fixture inputs #P"runner" "executable"))
         (asset (%make-package-fixture inputs #P"level.txt" "level"))
         (target (sgeo.deployment::%host-target)))
    (labels ((build (leaf)
               (let ((destination (merge-pathnames (pathname (format nil "~A/" leaf)) root)))
                 (sgeo.deployment:package-application
                  source destination :name "Runner" :target target
                  :assets (list (cons asset "levels/one.txt")))
                 (multiple-value-bind (app executable launcher desktop library copied-asset manifest)
                     (%host-package-layout target destination)
                   (declare (ignore launcher desktop library))
                   (values app executable copied-asset manifest)))))
      (unwind-protect
           (multiple-value-bind (good-app good-executable)
               (build "valid")
             (is (sgeo.deployment:verify-package good-app))
             (unless (uiop:os-windows-p)
               (let ((alias (merge-pathnames #P"package-root-alias" root)))
                 (uiop:run-program (list "ln" "-s" (namestring good-app) (namestring alias))
                                   :ignore-error-status nil)
                 (is (sgeo.deployment:verify-package alias))))
             (with-open-file (stream good-executable :direction :output :if-exists :supersede)
               (write-string "tampered" stream))
             (is (not (sgeo.deployment:verify-package good-app)))
             (multiple-value-bind (app executable asset-path manifest)
                 (build "missing")
               (declare (ignore executable manifest))
               (delete-file asset-path)
               (is (not (sgeo.deployment:verify-package app))))
             (multiple-value-bind (app executable asset-path manifest)
                 (build "additional")
               (declare (ignore executable asset-path manifest))
               (%make-package-fixture app #P"unexpected.txt" "not listed")
               (is (not (sgeo.deployment:verify-package app))))
             (multiple-value-bind (app executable asset-path manifest)
                 (build "malformed")
               (declare (ignore executable asset-path))
               (let ((lines (uiop:read-file-lines manifest)))
                 (%replace-package-text
                  manifest
                  (format nil "~{~A~%~}broken checksum row~%"
                          (subseq lines 0 4))))
               (is (not (sgeo.deployment:verify-package app))))
             (multiple-value-bind (app executable asset-path manifest)
                 (build "duplicate")
               (declare (ignore executable asset-path))
               (let* ((lines (uiop:read-file-lines manifest))
                      (first-file-line
                        (find-if (lambda (line)
                                  (and (>= (length line) 64)
                                       (sgeo.deployment::%hex-digest-p (subseq line 0 64))))
                                lines)))
                 (%replace-package-text
                  manifest
                  (format nil "~{~A~%~}~A~%" lines first-file-line)))
               (is (not (sgeo.deployment:verify-package app))))
             (multiple-value-bind (app executable asset-path manifest)
                 (build "escape")
               (declare (ignore executable asset-path))
               (%replace-package-text
                manifest
                (format nil "S-GEOMETRY-PACKAGE 1~%name Runner~%version 0.1.0~%target ~A~%~A  ../outside~%"
                        (string-downcase (symbol-name target))
                        (make-string 64 :initial-element #\0)))
               (is (not (sgeo.deployment:verify-package app))))
             (unless (uiop:os-windows-p)
               (multiple-value-bind (app executable asset-path manifest)
                   (build "symlink")
                 (declare (ignore executable asset-path manifest))
                 (let ((outside (%make-package-fixture inputs #P"outside.txt" "outside"))
                       (link (merge-pathnames #P"linked.txt" app)))
                   (uiop:run-program (list "ln" "-s" (namestring outside) (namestring link))
                                     :ignore-error-status nil :output :string)
                   (is (not (sgeo.deployment:verify-package app)))))))
        (when (probe-file root)
          (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))))
