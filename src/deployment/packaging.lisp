(in-package #:sgeo.deployment)

;;;; Montagem de pacotes relocáveis a partir de um executável nativo.

(define-condition packaging-error (error)
  ((message :initarg :message :reader %packaging-error-message))
  (:report (lambda (condition stream)
             (write-string (%packaging-error-message condition) stream))))

(defun %packaging-fail (control &rest arguments)
  (error 'packaging-error :message (apply #'format nil control arguments)))

(defun %host-target ()
  (cond ((uiop:os-windows-p) :windows)
        ((uiop:os-macosx-p) :macos)
        ((uiop:os-unix-p) :linux)
        (t (%packaging-fail "Sistema operacional hospedeiro não suportado."))))

(defun %safe-name (value label)
  (unless (and (stringp value) (plusp (length value))
               (every (lambda (character)
                        (or (alphanumericp character)
                            (find character "-_.")))
                      value)
               (not (member value '("." "..") :test #'string=)))
    (%packaging-fail "~A inválido; use letras, números, ponto, hífen ou sublinhado." label))
  value)

(defun %path-string (path)
  (namestring (if (pathnamep path) path (pathname path))))

(defun %relative-components (relative)
  (let* ((text (etypecase relative
                 (string relative)
                 (pathname (namestring relative))))
         (length (length text))
         (components nil)
         (start 0))
    (when (or (zerop length)
              (find (char text 0) "/\\")
              (and (> length 1) (char= (char text 1) #\:))
              (some (lambda (character) (or (< (char-code character) 32)
                                           (= (char-code character) 127))) text))
      (%packaging-fail "Destino relativo inválido: ~S." text))
    (loop for index from 0 to length do
      (when (or (= index length) (find (char text index) "/\\"))
        (let ((component (subseq text start index)))
          (when (or (string= component "..") (string= component ""))
            (%packaging-fail "Destino relativo inválido ou com traversal: ~S." text))
          (unless (string= component ".") (push component components)))
        (setf start (1+ index))))
    (when (null components) (%packaging-fail "Destino relativo vazio: ~S." text))
    (nreverse components)))

(defun %relative-pathname (components)
  (pathname (format nil "~{~A~^/~}" components)))

(defun %input-list (entries label)
  (cond ((null entries) nil)
        ((or (stringp entries) (pathnamep entries)) (list entries))
        ((typep entries 'sequence) (coerce entries 'list))
        (t (%packaging-fail "~A precisa ser um caminho ou uma sequência de caminhos." label))))

(defun %directory-leaf (directory)
  (let ((components (pathname-directory directory)))
    (or (car (last components))
        (%packaging-fail "O destino precisa nomear uma pasta, não a raiz."))))

(defun %directory-parent (directory)
  (make-pathname :directory (butlast (pathname-directory directory))
                 :name nil :type nil :defaults directory))

(defun %directory-prefix-string (directory)
  (let ((text (namestring (uiop:ensure-directory-pathname directory))))
    (if (or (zerop (length text))
            (find (char text (1- (length text))) "/\\"))
        text
        (concatenate 'string text "/"))))

(defun %path-under-directory-p (path directory)
  (let* ((path-name (namestring (if (pathnamep path) path (pathname path))))
         (prefix (%directory-prefix-string directory)))
    (if (uiop:os-windows-p)
        (and (>= (length path-name) (length prefix))
        (string-equal prefix path-name :end2 (length prefix)))
        (and (>= (length path-name) (length prefix))
             (string= prefix path-name :end2 (length prefix))))))

(defun %canonical-existing-file (path label)
  (let ((true (probe-file path)))
    (unless (and true (not (uiop:directory-exists-p true)))
      (%packaging-fail "~A não é um arquivo existente: ~A." label (%path-string path)))
    (truename true)))

(defun %source-destination (entry base-directory label)
  (let* ((source (if (consp entry) (car entry) entry))
         (relative (if (consp entry) (cdr entry) (file-namestring (pathname source))))
         (components (%relative-components relative))
         (canonical-source (%canonical-existing-file source label)))
    (values canonical-source
            (merge-pathnames (%relative-pathname components) base-directory)
            components)))

(defun %normalize-inputs (entries base-directory label)
  (loop for entry in (%input-list entries label)
        collect (multiple-value-bind (source destination components)
                    (%source-destination entry base-directory label)
                  (list source destination components))))

(defun %check-input-collisions (items generated-paths)
  (let ((destinations (make-hash-table :test #'equalp))
        (basenames (make-hash-table :test #'equalp)))
    (dolist (path generated-paths)
      (setf (gethash (%path-string path) destinations) :generated)
      (setf (gethash (string-downcase (file-namestring path)) basenames) :generated))
    (dolist (item items)
      (let* ((destination (second item))
             (name (%path-string destination))
           (basename (string-downcase (car (last (third item))))))
        (when (gethash name destinations)
          (%packaging-fail "Caminho de pacote duplicado: ~A." name))
        (when (gethash basename basenames)
          (%packaging-fail "Nomes de arquivo conflitantes no pacote: ~A." basename))
        (setf (gethash name destinations) t
              (gethash basename basenames) t)))
    t))

(defun %assert-safe-destination (destination source-files)
  (when (probe-file destination)
    (%packaging-fail "O diretório de destino já existe: ~A." (%path-string destination)))
  (let* ((parent (%directory-parent destination))
         (leaf (%directory-leaf destination)))
    (ensure-directories-exist (merge-pathnames #P".sgeo-placeholder" parent))
    (let* ((true-parent (truename parent))
           (candidate (merge-pathnames (make-pathname :directory `(:relative ,leaf))
                                       (uiop:ensure-directory-pathname true-parent))))
      (dolist (source source-files)
        (let ((source-parent (uiop:pathname-directory-pathname source)))
          (when (or (%path-under-directory-p source candidate)
                    (%path-under-directory-p candidate source-parent))
            (%packaging-fail "O destino se sobrepõe ao diretório de uma entrada: ~A." 
                             (%path-string source)))))
      (when (probe-file candidate)
        (%packaging-fail "O diretório de destino já existe: ~A." (%path-string candidate)))
      (values candidate true-parent))))

(defun %copy-inputs (items)
  (dolist (item items)
    (let ((source (first item))
          (destination (second item)))
      (ensure-directories-exist destination)
      (uiop:copy-file source destination))))

(defun %write-text (path text)
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :error
                                    :if-does-not-exist :create
                                    :external-format :utf-8)
    (write-string text stream))
  path)

(defun %chmod-executable (path)
  (uiop:run-program (list "chmod" "755" (namestring path))
                    :ignore-error-status nil :output :string :error-output :string))

(defun %install-executable (source destination)
  (ensure-directories-exist destination)
  (uiop:copy-file source destination)
  (unless (uiop:os-windows-p) (%chmod-executable destination))
  destination)

(defun %write-linux-launcher (path name)
  (%write-text path
               (format nil
                       "#!/bin/sh~%set -eu~%APP_ROOT=$(CDPATH= cd -- \"$(dirname -- \"$0\")\" && pwd)~%export LD_LIBRARY_PATH=\"$APP_ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"~%exec \"$APP_ROOT/bin/~A\" \"$@\"~%"
                       name))
  (%chmod-executable path))

(defun %write-windows-launcher (path executable-name)
  (%write-text path
               (format nil "@echo off~%setlocal~%\"%~~dp0~A\" %*~%exit /b %errorlevel%~%"
                       executable-name)))

(defun %write-macos-plist (path name version executable)
  (%write-text path
               (format nil
                       "<?xml version=\"1.0\" encoding=\"UTF-8\"?>~%<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">~%<plist version=\"1.0\"><dict>~%<key>CFBundleName</key><string>~A</string>~%<key>CFBundleDisplayName</key><string>~A</string>~%<key>CFBundleIdentifier</key><string>org.sgeometry.~A</string>~%<key>CFBundleVersion</key><string>~A</string>~%<key>CFBundleExecutable</key><string>~A</string>~%<key>CFBundlePackageType</key><string>APPL</string>~%<key>LSMinimumSystemVersion</key><string>10.13</string>~%</dict></plist>~%"
                       name name name version executable)))

(defun %file-sha256 (path)
  (string-downcase (ironclad:byte-array-to-hex-string
                    (ironclad:digest-file :sha256 path))))

(defun %relative-file-names (root)
  (setf root (truename root))
  (sort
   (loop for path in (%all-files root)
         collect (enough-namestring path root))
   #'string<))

(defun %all-files (root)
  (append (uiop:directory-files root)
          (loop for directory in (uiop:subdirectories root)
                append (%all-files directory))))

(defun %portable-relative-name (path root)
  (substitute #\/ #\\ (enough-namestring (truename path) (truename root))))

(defun %safe-package-tree-files (root)
  "Retorna arquivos sem seguir links simbólicos nem sair da raiz do pacote."
  (let ((root (truename root))
        (visited (make-hash-table :test #'equalp))
        (files nil))
    (labels ((canonical-entry-path (path directory-p)
               (let* ((parent (if directory-p
                                  (%directory-parent (uiop:ensure-directory-pathname path))
                                  (uiop:pathname-directory-pathname path)))
                      (canonical-parent (truename parent))
                      (entry (if directory-p
                                 (merge-pathnames
                                  (pathname (format nil "~A/"
                                                    (car (last (pathname-directory
                                                                (uiop:ensure-directory-pathname path))))))
                                  canonical-parent)
                                 (make-pathname :name (pathname-name path)
                                                :type (pathname-type path)
                                                :version (pathname-version path)
                                                :defaults canonical-parent))))
                 entry))
             (check-node (path directory-p)
               (let ((true (truename path)))
                 (unless (and (%path-under-directory-p true root)
                              (equalp (namestring (canonical-entry-path path directory-p))
                                      (namestring true)))
                   (%packaging-fail "Caminho simbólico ou externo ao pacote: ~A."
                                    (%path-string path)))
                 (when directory-p
                   (let ((key (namestring true)))
                     (when (gethash key visited)
                       (%packaging-fail "Ciclo ou diretório duplicado no pacote: ~A."
                                        (%path-string path)))
                     (setf (gethash key visited) t)))
                 true))
             (walk (directory)
               (check-node directory t)
               (dolist (file (uiop:directory-files directory))
                 (check-node file nil)
                 (push file files))
               (dolist (subdirectory (uiop:subdirectories directory))
                 (walk subdirectory))))
      (walk root))
    files))

(defun %hex-digest-p (text)
  (and (= (length text) 64)
       (every (lambda (character)
                (or (digit-char-p character 16)
                    (find character "abcdefABCDEF")))
              text)))

(defun %canonical-manifest-name (text)
  (let* ((portable (substitute #\/ #\\ text))
         (components (%relative-components text))
         (canonical (format nil "~{~A~^/~}" components)))
    (unless (string= portable canonical)
      (%packaging-fail "Caminho não canônico no manifesto: ~S." text))
    canonical))

(defun %verify-package (directory)
  (let* ((root (uiop:ensure-directory-pathname (truename directory)))
         (manifest (merge-pathnames #P"MANIFEST.sha256" root))
         (lines (uiop:read-file-lines manifest))
         (metadata (make-hash-table :test #'equal))
         (listed (make-hash-table :test #'equalp))
         (header-seen nil))
    (unless (and (uiop:directory-exists-p root)
                 (probe-file manifest)
                 (not (uiop:directory-exists-p manifest)))
      (%packaging-fail "Pacote sem MANIFEST.sha256 válido."))
    (dolist (line lines)
      (cond
        ((not header-seen)
         (unless (string= line "S-GEOMETRY-PACKAGE 1")
           (%packaging-fail "Cabeçalho do manifesto inválido."))
         (setf header-seen t))
        ((or (and (>= (length line) 5) (string= line "name " :end1 5))
             (and (>= (length line) 8) (string= line "version " :end1 8))
             (and (>= (length line) 7) (string= line "target " :end1 7)))
         (let* ((space (position #\Space line))
                (key (subseq line 0 space))
                (value (subseq line (1+ space))))
           (when (or (zerop (length value)) (gethash key metadata))
             (%packaging-fail "Metadado ausente ou repetido no manifesto: ~A." key))
           (setf (gethash key metadata) value)))
        ((and (>= (length line) 11) (string= line "diagnostic " :end1 11))
         (when (find #\Return line)
           (%packaging-fail "Diagnóstico inválido no manifesto.")))
        (t
         (unless (and (>= (length line) 67)
                      (%hex-digest-p (subseq line 0 64))
                      (char= (char line 64) #\Space)
                      (char= (char line 65) #\Space))
           (%packaging-fail "Entrada de checksum malformada."))
         (let* ((digest (string-downcase (subseq line 0 64)))
                (relative (%canonical-manifest-name (subseq line 66))))
           (when (or (string-equal relative "MANIFEST.sha256")
                     (gethash relative listed))
             (%packaging-fail "Caminho repetido ou reservado no manifesto: ~A." relative))
           (setf (gethash relative listed) digest)))))
    (unless (and header-seen (gethash "name" metadata) (gethash "version" metadata)
                 (member (gethash "target" metadata) '("linux" "windows" "macos")
                         :test #'string=))
      (%packaging-fail "Metadados obrigatórios ausentes ou inválidos."))
    (let ((actual (make-hash-table :test #'equalp)))
      (dolist (file (%safe-package-tree-files root))
        (let ((relative (%portable-relative-name file root)))
          (unless (if (uiop:os-windows-p)
                      (string-equal relative "MANIFEST.sha256")
                      (string= relative "MANIFEST.sha256"))
            (setf (gethash relative actual) t)
            (let ((expected (gethash relative listed)))
              (unless (and expected (string= expected (%file-sha256 file)))
                (%packaging-fail "Arquivo ausente do manifesto ou checksum divergente: ~A."
                                 relative))))))
      (maphash (lambda (relative digest)
                 (declare (ignore digest))
                 (unless (gethash relative actual)
                   (%packaging-fail "Arquivo listado ausente do pacote: ~A." relative)))
               listed))
    t))

(defun verify-package (directory)
  "Verifica manifesto, arquivos e integridade de um diretório empacotado."
  (handler-case
      (%verify-package directory)
    (error () nil)))

(defun %write-manifest (app-directory name version target diagnostics)
  (setf app-directory (truename app-directory))
  (let* ((manifest (merge-pathnames #P"MANIFEST.sha256" app-directory))
         (files (sort (remove manifest (%all-files app-directory) :test #'equal)
                      #'string< :key (lambda (path) (enough-namestring path app-directory)))))
    (%write-text manifest
                 (with-output-to-string (stream)
                   (format stream "S-GEOMETRY-PACKAGE 1~%name ~A~%version ~A~%target ~A~%"
                           name version (string-downcase (symbol-name target)))
                   (dolist (diagnostic diagnostics)
                     (format stream "diagnostic ~A~%" diagnostic))
                   (dolist (path files)
                     (format stream "~A  ~A~%" (%file-sha256 path)
                             (enough-namestring path app-directory)))))
    manifest))

(defun %package-diagnostics (target native-libraries)
  (append
   (list "Only native builds for the current host are supported; this tool does not cross-compile."
         "Only explicitly supplied native libraries are bundled; transitive dependencies must be supplied or installed by the user.")
   (list (ecase target
           (:linux "Requires a compatible system graphics driver (OpenGL 3.3; Vulkan when selected by the runtime).")
           (:windows "Requires compatible graphics drivers and any system runtime DLLs not explicitly bundled.")
           (:macos "Requires a compatible macOS graphics stack; system frameworks are supplied by macOS.")))
   (when (eq target :linux)
     (list "The desktop entry expects the package launcher to be available on PATH."))
   (when (null native-libraries)
     (list "No native libraries were supplied; runtime libraries remain a host installation prerequisite."))))

(defun %temporary-tar-files (app-directory)
  (let* ((parent (%directory-parent app-directory))
         (leaf (%directory-leaf app-directory))
         (stem (concatenate 'string "." leaf ".sgeo-package")))
    (values (make-pathname :name stem :type "tar" :defaults parent)
            (make-pathname :name (concatenate 'string stem ".tar")
                           :type "gz" :defaults parent))))

(defun %create-archive (app-directory archive target)
  (let* ((parent (%directory-parent app-directory))
         (leaf (%directory-leaf app-directory)))
    (ecase target
      (:linux
       (let* ((version (uiop:run-program '("tar" "--version") :output :string
                                         :error-output :string :ignore-error-status t))
              (gnu-p (search "GNU tar" version)))
         (if gnu-p
             (multiple-value-bind (tar-file gzip-file)
                 (%temporary-tar-files app-directory)
               (uiop:run-program
                (list "tar" "--sort=name" "--mtime=@0" "--owner=0" "--group=0"
                      "--numeric-owner" "-cf" (namestring tar-file)
                      "-C" (namestring parent) leaf)
                :ignore-error-status nil :output :string :error-output :string)
               (uiop:run-program (list "gzip" "-n" "-f" (namestring tar-file))
                                 :ignore-error-status nil :output :string :error-output :string)
               (rename-file gzip-file archive))
             (uiop:run-program (list "tar" "-czf" (namestring archive)
                                     "-C" (namestring parent) leaf)
                               :ignore-error-status nil :output :string :error-output :string))))
      (:macos
       (uiop:run-program (list "tar" "-czf" (namestring archive)
                               "-C" (namestring parent) leaf)
                         :ignore-error-status nil :output :string :error-output :string))
      (:windows
       (uiop:run-program
        (list "powershell.exe" "-NoProfile" "-Command"
              (format nil "Compress-Archive -LiteralPath '~A' -DestinationPath '~A' -Force"
                      (with-output-to-string (out)
                        (loop for character across (namestring app-directory) do
                          (write-char character out)
                          (when (char= character #\') (write-char character out))))
                      (with-output-to-string (out)
                        (loop for character across (namestring archive) do
                          (write-char character out)
                          (when (char= character #\') (write-char character out))))))
        :ignore-error-status nil :output :string :error-output :string)))
    archive))

(defun package-application (executable destination &key name (version "0.1.0") target
                                                        native-libraries assets diagnostics)
  "Monta um pacote relocável no formato nativo do hospedeiro e retorna seus caminhos."
  (let* ((host (%host-target))
         (target (or target host))
         (source (%canonical-existing-file executable "Executável"))
         (name (%safe-name (or name (pathname-name source)) "name"))
         (version (%safe-name version "version"))
         (destination-path (uiop:ensure-directory-pathname (pathname destination)))
         (native-inputs (%input-list native-libraries "native-libraries"))
         (asset-inputs (%input-list assets "assets"))
         (sources (cons source
                        (append (mapcar (lambda (entry)
                                          (%canonical-existing-file
                                           (if (consp entry) (car entry) entry)
                                           "Biblioteca nativa"))
                                        native-inputs)
                                (mapcar (lambda (entry)
                                          (%canonical-existing-file
                                           (if (consp entry) (car entry) entry) "Asset"))
                                        asset-inputs))))
         (native-target (eq target host))
         (executable-name (if (eq target :windows) (concatenate 'string name ".exe") name)))
    (unless (member target '(:linux :windows :macos))
      (%packaging-fail "target precisa ser :linux, :windows ou :macos."))
    (unless native-target
      (%packaging-fail "Não é possível construir target ~A no hospedeiro ~A." target host))
    (unless (and (stringp version) (plusp (length version)))
      (%packaging-fail "version precisa ser uma string não vazia."))
    (let* ((base (ecase target
                   (:linux destination-path)
                   (:windows destination-path)
                   (:macos (merge-pathnames (pathname (concatenate 'string name ".app/"))
                                            destination-path))))
           (generated (ecase target
                        (:linux (list (merge-pathnames (make-pathname :directory '(:relative "bin")
                                                                     :name name)
                                                       base)
                                      (merge-pathnames name base)
                                      (merge-pathnames (make-pathname :directory '(:relative "share" "applications")
                                                                     :name (concatenate 'string name ".desktop")) base)))
                        (:windows (list (merge-pathnames executable-name base)
                                        (merge-pathnames (concatenate 'string name ".cmd") base)))
                        (:macos (list (merge-pathnames (make-pathname :directory '(:relative "Contents" "MacOS")
                                                                     :name name) base)
                                      (merge-pathnames (make-pathname :directory '(:relative "Contents")
                                                                     :name "Info" :type "plist") base)))))
           (native-base (ecase target
                          (:linux (merge-pathnames #P"lib/" base))
                          (:windows base)
                          (:macos (merge-pathnames #P"Contents/Frameworks/" base))))
           (assets-base (ecase target
                          (:linux (merge-pathnames #P"assets/" base))
                          (:windows (merge-pathnames #P"resources/" base))
                          (:macos (merge-pathnames #P"Contents/Resources/" base))))
           (native-items (%normalize-inputs native-inputs native-base "native-libraries"))
           (asset-items (%normalize-inputs asset-inputs assets-base "assets"))
           (planned-generated (append generated
                                      (list (merge-pathnames #P"MANIFEST.sha256" base))))
           (reported-diagnostics
             (append (%package-diagnostics target native-items)
                     (loop for diagnostic in (coerce (if (stringp diagnostics)
                                                          (list diagnostics)
                                                          diagnostics)
                                                    'list)
                           collect (let ((text (princ-to-string diagnostic)))
                                     (when (or (find #\Newline text) (find #\Return text))
                                       (%packaging-fail "Diagnostic precisa caber em uma linha."))
                                     text))))
           (leaf (%directory-leaf base))
           (archive (make-pathname :name (if (eq target :windows) leaf
                                             (concatenate 'string leaf ".tar"))
                                   :type (if (eq target :windows) "zip" "gz")
                                   :defaults (%directory-parent base))))
      (when (probe-file archive)
        (%packaging-fail "O arquivo de destino já existe: ~A." (%path-string archive)))
      (when (eq target :linux)
        (multiple-value-bind (tar-file gzip-file) (%temporary-tar-files base)
          (when (or (probe-file tar-file) (probe-file gzip-file))
            (%packaging-fail "Arquivo temporário de empacotamento já existe."))))
      (%check-input-collisions (append native-items asset-items) planned-generated)
      (multiple-value-bind (final-directory ignored-parent)
          (%assert-safe-destination base sources)
        (declare (ignore ignored-parent))
        (unless (equalp base final-directory)
          (setf base final-directory))
        (let ((created-p nil) (success-p nil))
          (unwind-protect
               (progn
                 (ensure-directories-exist (merge-pathnames #P".sgeo-placeholder" base))
                 (setf created-p t)
                 (ecase target
                   (:linux
                    (%install-executable source (merge-pathnames (make-pathname :directory '(:relative "bin")
                                                                              :name name) base))
                    (%write-linux-launcher (merge-pathnames name base) executable-name)
                    (%write-text (merge-pathnames (make-pathname :directory '(:relative "share" "applications")
                                                                 :name (concatenate 'string name ".desktop")) base)
                                 (format nil "[Desktop Entry]~%Type=Application~%Name=~A~%Exec=~A %U~%Terminal=false~%Categories=Game;~%"
                                         name name)))
                   (:windows
                    (%install-executable source (merge-pathnames executable-name base))
                    (%write-windows-launcher (merge-pathnames (concatenate 'string name ".cmd") base)
                                             executable-name))
                   (:macos
                    (%install-executable source
                                         (merge-pathnames (make-pathname :directory '(:relative "Contents" "MacOS")
                                                                         :name name) base))
                    (%write-macos-plist (merge-pathnames (make-pathname :directory '(:relative "Contents")
                                                                         :name "Info" :type "plist") base)
                                        name version name)))
                 (%copy-inputs native-items)
                 (%copy-inputs asset-items)
                 (let* ((manifest (%write-manifest base name version target reported-diagnostics))
                        (archive-path (progn
                                        (unless (verify-package base)
                                          (%packaging-fail "O pacote gerado falhou na verificação de integridade."))
                                        (%create-archive base archive target))))
                   (setf success-p t)
                   (list :target target :application base :archive archive-path
                         :manifest manifest :files (%relative-file-names base)
                         :diagnostics reported-diagnostics)))
            (unless success-p
              (when (and created-p (probe-file base))
                (uiop:delete-directory-tree base :validate t :if-does-not-exist :ignore))
              (when (probe-file archive) (delete-file archive))
              (when (eq target :linux)
                (multiple-value-bind (tar-file gzip-file) (%temporary-tar-files base)
                  (when (probe-file tar-file) (delete-file tar-file))
                  (when (probe-file gzip-file) (delete-file gzip-file)))))))))))
