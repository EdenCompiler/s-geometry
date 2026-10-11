(in-package #:sgeo.deployment)

;;;; Coleta avisos de licença localmente, sem presumir a licença do projeto.

(defparameter +license-file-prefixes+ '("LICENSE" "COPYING" "COPYRIGHT" "NOTICE"))

(defun %license-file-p (path)
  (let ((name (string-upcase (file-namestring path))))
    (some (lambda (prefix) (and (>= (length name) (length prefix))
                                (string= name prefix :end1 (length prefix))))
          +license-file-prefixes+)))

(defun %license-search-files (root &optional (depth 0))
  "Procura arquivos de licença em fontes e diretórios de documentação próximos."
  (when (and root (probe-file root) (uiop:directory-exists-p root) (<= depth 5))
    (append
     (remove-if-not #'%license-file-p (uiop:directory-files root))
     (loop for directory in (uiop:subdirectories root)
           for leaf = (string-downcase (or (car (last (pathname-directory directory))) ""))
           unless (member leaf '(".git" "tests" "test" "examples" "node_modules" "build")
                          :test #'string=)
             append (%license-search-files directory (1+ depth)))))
  )

(defun %license-read-text (path)
  (handler-case (uiop:read-file-string path :external-format :utf-8)
    (error (condition)
      (values nil (format nil "Could not read ~A as UTF-8: ~A" path condition)))))

(defun %license-system-source (name)
  (handler-case
      (let ((system (asdf:find-system name nil)))
        (and system (ignore-errors (asdf:system-source-directory system))))
    (error () nil)))

(defun %license-system-value (name accessor)
  (handler-case
      (let ((system (asdf:find-system name nil)))
        (when system (funcall accessor system)))
    (error () nil)))

(defun %license-system-homepage (name)
  (let ((system (ignore-errors (asdf:find-system name nil))))
    (when system (ignore-errors (asdf:system-homepage system)))))

(defun %license-asdf-systems ()
  (sort (remove-duplicates
         (copy-list (asdf:already-loaded-systems)) :test #'string-equal)
        #'string-lessp))

(defun %license-path-parents (path &optional (limit 6))
  (let ((current (uiop:pathname-directory-pathname
                  (if (pathnamep path) path (pathname path)))))
    (loop repeat limit
          collect current
          do (let ((parent (uiop:pathname-parent-directory-pathname current)))
               (when (equalp parent current) (return))
               (setf current parent)))))

(defun %license-system-roots (name)
  (let* ((source (%license-system-source name))
         (quicklisp (merge-pathnames "quicklisp/" (user-homedir-pathname)))
         (software (merge-pathnames "dists/quicklisp/software/" quicklisp))
         (roots (when source (list source))))
    ;; O cliente Quicklisp pode manter suas fontes e licenças na árvore da distribuição.
    (when (string-equal name "quicklisp")
      (setf roots
            (append roots
                    (loop for directory in (uiop:subdirectories software)
                          for leaf = (string-downcase
                                      (or (car (last (pathname-directory directory))) ""))
                          when (search "quicklisp-client" leaf) collect directory))))
    (remove-duplicates (remove nil roots) :test #'equalp)))

(defun %license-native-path (entry)
  (let ((value (if (and (consp entry)
                        (or (pathnamep (car entry)) (stringp (car entry))))
                   (car entry) entry)))
    (cond ((pathnamep value) value)
          ((stringp value) (pathname value))
          ((and (listp entry) (getf entry :source))
           (pathname (getf entry :source)))
          (t nil))))

(defun %license-native-name (entry)
  (let ((path (%license-native-path entry)))
    (if path (file-namestring path) (princ-to-string entry))))

(defun %license-native-kind (path)
  (let ((name (string-downcase (file-namestring path))))
    (cond ((search "glfw" name) :glfw)
          ((search "openal" name) :openal)
          (t nil))))

(defun %license-native-link (kind)
  (case kind
    (:glfw "https://github.com/glfw/glfw/blob/master/LICENSE.md")
    (:openal "https://github.com/kcat/openal-soft/blob/master/COPYING")
    (t nil)))

(defun %license-dpkg-copyright (path)
  (when (and (uiop:os-unix-p) (probe-file "/usr/bin/dpkg-query"))
    (let ((result (uiop:run-program
                   (list "dpkg-query" "-S" (namestring path))
                   :output :string :error-output :string :ignore-error-status t)))
      (loop for line in (uiop:split-string result :separator '(#\Newline))
            for marker = (search ": " line)
            when marker do
              (let* ((raw-package (subseq line 0 marker))
                     (architecture (position #\: raw-package :from-end t))
                     (package (if (and architecture (> architecture 0))
                                  (subseq raw-package 0 architecture)
                                  raw-package))
                     (copyright (merge-pathnames
                                 (format nil "~A/copyright" package)
                                 #P"/usr/share/doc/")))
                (when (probe-file copyright) (return copyright)))))))

(defun %license-vcpkg-copyright (path kind)
  (let ((folder (case kind (:glfw "glfw3") (:openal "openal-soft"))))
    (when folder
      (loop for directory in (%license-path-parents path 8)
            for candidate = (merge-pathnames (format nil "share/~A/copyright" folder)
                                             directory)
            when (and (search "installed" (namestring directory) :test #'char-equal)
                      (probe-file candidate)) return candidate))))

(defun %license-native-files (path kind)
  (let* ((direct (or (%license-dpkg-copyright path)
                     (%license-vcpkg-copyright path kind)))
         (nearby (loop for root in (%license-path-parents path 6)
                       append (remove-if-not #'%license-file-p (uiop:directory-files root))))
         (package-roots
           (case kind
             (:glfw (list #P"/usr/share/doc/libglfw3/" #P"/usr/share/doc/glfw/"
                          #P"/opt/homebrew/opt/glfw/" #P"/usr/local/opt/glfw/"))
             (:openal (list #P"/usr/share/doc/libopenal1/" #P"/usr/share/doc/openal-soft/"
                            #P"/opt/homebrew/opt/openal-soft/" #P"/usr/local/opt/openal-soft/"))
             (t nil)))
         (discovered (append (when direct (list direct)) nearby
                             (loop for root in package-roots
                                   append (%license-search-files root)))))
    (remove-duplicates (remove-if-not #'probe-file discovered) :test #'equalp)))

(defun %license-write-section (stream title &key source metadata files link diagnostics seen)
  (format stream "~%~%================================================================~%~A~%================================================================~%"
          title)
  (when source (format stream "ASDF source directory: ~A~%" source))
  (when metadata (format stream "License metadata: ~A~%" metadata))
  (when link (format stream "License source: ~A~%" link))
  (dolist (diagnostic diagnostics) (format stream "Discovery note: ~A~%" diagnostic))
  (if files
      (dolist (file files)
        (if (gethash (namestring file) seen)
            (format stream "~%License text already included from ~A~%" (namestring file))
            (multiple-value-bind (text problem) (%license-read-text file)
              (setf (gethash (namestring file) seen) t)
              (if text
                  (format stream "~%--- Full text from ~A ---~%~A~%"
                          (namestring file) text)
                  (format stream "~%License text unavailable at ~A: ~A~%"
                          (namestring file) problem)))))
      (unless link
        (format stream "License text was not found in the local installation.~%"))))

(defun %license-diagnostic (diagnostics message)
  (pushnew message diagnostics :test #'string=))

(defun %license-output-path (destination)
  (let* ((path (if (pathnamep destination) destination (pathname destination)))
         (directory-p (or (uiop:directory-exists-p path)
                          (null (pathname-name path)))))
    (if directory-p
        (merge-pathnames #P"THIRD-PARTY.txt" (uiop:ensure-directory-pathname path))
        path)))

(defun write-license-notices (destination &key native-libraries)
  "Escreve avisos de terceiros com textos de licença encontrados localmente.

Retorna o caminho do arquivo e uma lista de descobertas incompletas. Nenhuma
licença do S-Geometry é inferida; sistemas sem texto local aparecem como
diagnósticos explícitos no arquivo e no segundo valor de retorno."
  (let* ((output (%license-output-path destination))
         (diagnostics nil)
         (seen (make-hash-table :test #'equalp))
         (native-items (cond ((null native-libraries) nil)
                             ((or (pathnamep native-libraries)
                                  (stringp native-libraries)
                                  (and (listp native-libraries)
                                       (keywordp (first native-libraries))
                                       (getf native-libraries :source))
                                  (and (consp native-libraries)
                                       (or (pathnamep (car native-libraries))
                                           (stringp (car native-libraries)))
                                       (not (listp (cdr native-libraries)))))
                              (list native-libraries))
                             ((listp native-libraries) native-libraries)
                             (t (list native-libraries)))))
    (ensure-directories-exist output)
    (with-open-file (stream output :direction :output :if-exists :supersede
                                   :if-does-not-exist :create :external-format :utf-8)
      (format stream "THIRD-PARTY NOTICES~%Generated from local build dependencies and package metadata.~%")
      (format stream "No license is stated or inferred for S-Geometry by this file.~%")
      (let* ((sbcl-path #+sbcl sb-ext:*runtime-pathname* #-sbcl nil)
             (sbcl-files (append (when sbcl-path (%license-search-files
                                                  (uiop:pathname-directory-pathname sbcl-path)))
                                 (%license-search-files #P"/usr/share/doc/sbcl/")
                                 (%license-search-files #P"/usr/local/share/doc/sbcl/")
                                 (when sbcl-path
                                   (loop for root in (%license-path-parents sbcl-path 7)
                                         append (remove-if-not #'%license-file-p
                                                               (uiop:directory-files root)))))))
        (unless sbcl-files
          (setf diagnostics
                (%license-diagnostic diagnostics
                                     "SBCL license text was not found locally; consult https://github.com/sbcl/sbcl/blob/master/COPYING.")))
        (%license-write-section
         stream "SBCL, ASDF, and UIOP runtime" :source sbcl-path
         :metadata "SBCL and bundled ASDF licenses are implementation-specific."
         :files (remove-duplicates sbcl-files :test #'equalp)
         :link "https://github.com/sbcl/sbcl/blob/master/COPYING"
         :diagnostics (unless sbcl-files (list (car diagnostics))) :seen seen))
      (let* ((quicklisp-files (loop for root in (%license-system-roots "quicklisp")
                                    append (%license-search-files root)))
             (quicklisp-link "https://github.com/quicklisp/quicklisp-client/blob/master/LICENSE.txt"))
        (unless quicklisp-files
          (setf diagnostics
                (%license-diagnostic diagnostics
                                     "Quicklisp client license text was not found locally; consult https://github.com/quicklisp/quicklisp-client/blob/master/LICENSE.txt.")))
        (%license-write-section stream "Quicklisp client" :source (%license-system-source "quicklisp")
                                :files (remove-duplicates quicklisp-files :test #'equalp)
                                :link quicklisp-link
                                :diagnostics (unless quicklisp-files (list (car diagnostics)))
                                :seen seen))
      (dolist (name (%license-asdf-systems))
        (unless (or (member name '("asdf" "uiop" "asdf-package-system" "quicklisp")
                            :test #'string-equal)
                    (and (>= (length name) 4) (string-equal name "sgeo" :end1 4)))
          (let* ((source (%license-system-source name))
                 (metadata (%license-system-value name #'asdf:system-license))
                 (files (loop for root in (%license-system-roots name)
                              append (%license-search-files root)))
                 (homepage (%license-system-homepage name))
                 (notice (format nil "License text for loaded ASDF system ~A was not found locally." name)))
            (unless files
              (setf diagnostics (%license-diagnostic diagnostics notice)))
            (%license-write-section
             stream (format nil "Loaded ASDF system: ~A" name)
             :source source :metadata metadata :link homepage
             :files (remove-duplicates files :test #'equalp)
             :diagnostics (unless files (list notice)) :seen seen))))
      (dolist (entry native-items)
        (let* ((path (%license-native-path entry))
               (kind (and path (%license-native-kind path)))
               (name (%license-native-name entry))
               (files (when path (%license-native-files path kind)))
               (link (%license-native-link kind))
               (notice (if path
                           (format nil "Native library license text was not found locally for ~A." name)
                           (format nil "Could not identify a native library path in ~S." entry))))
          (unless files
            (setf diagnostics (%license-diagnostic diagnostics notice)))
          (when (and path (eq kind :openal)
                     (not (search "openal-soft" (string-downcase (namestring path)))))
            (setf diagnostics
                  (%license-diagnostic diagnostics
                                       (format nil "~A is an OpenAL implementation; OpenAL Soft license text is not assumed for other implementations." name))))
          (%license-write-section
           stream (format nil "Bundled native library: ~A" name)
           :source path :files files :link link
           :diagnostics (append (unless files (list notice))
                                (when (and path (eq kind :openal)
                                           (not (search "openal-soft" (string-downcase (namestring path)))))
                                  (list "The upstream OpenAL Soft link is provided for reference only; confirm the packaged implementation.")))
           :seen seen)))
      (when diagnostics
        (format stream "~%~%================================================================~%License discovery diagnostics~%================================================================~%")
        (dolist (diagnostic (nreverse (copy-list diagnostics)))
          (format stream "- ~A~%" diagnostic))))
    (values output (nreverse diagnostics))))
