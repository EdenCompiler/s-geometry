(in-package #:sgeo.deployment)

(define-condition build-error (error)
  ((message :initarg :message :reader %build-error-message))
  (:report (lambda (condition stream) (write-string (%build-error-message condition) stream))))

(defstruct (application (:constructor %make-application))
  name (version "0.1.0") entry-point systems assets native-libraries (target :desktop) debug)

(defvar *applications* (make-hash-table :test #'equal))
(defvar *application-directory* nil)
(defvar *release-entry-point* nil)
(defvar *release-libraries* nil)
(defvar *release-description* nil)

(defun host-target ()
  "Retorna o alvo nativo que esta imagem pode compilar."
  (%host-target))

(defun register-application (name &key entry-point systems assets native-libraries
                                     (version "0.1.0") (target :desktop) debug)
  "Registra uma aplicação; a definição é código de desenvolvimento confiável."
  (unless (and entry-point (symbolp entry-point) (symbol-package entry-point)
               (listp systems) systems (every (lambda (x) (or (symbolp x) (stringp x))) systems)
               (member target '(:desktop :linux :windows :macos)))
    (error 'build-error :message "Aplicação precisa de entry-point, sistemas e alvo desktop válidos."))
  (let* ((key (string-downcase (string name)))
         (app (%make-application :name (%safe-name key "nome") :version (%safe-name version "versão")
                                :entry-point entry-point :systems systems :assets assets
                                :native-libraries native-libraries :target target :debug debug)))
    (setf (gethash key *applications*) app)))

(defmacro define-application (name &rest options)
  "Declara os sistemas, ativos e ponto de entrada de uma aplicação desktop."
  `(register-application ',name ,@options))

(defun find-application (name)
  "Localiza uma definição de aplicação registrada."
  (gethash (string-downcase (string name)) *applications*))

(defun application-resource-path (relative)
  "Resolve um recurso dentro do pacote, independentemente do diretório corrente."
  (unless *application-directory*
    (error 'build-error :message "Nenhum pacote de aplicação está ativo."))
  (%relative-components relative)
  (merge-pathnames relative
    (ecase (host-target)
      (:linux (merge-pathnames "assets/" *application-directory*))
      (:windows (merge-pathnames "resources/" *application-directory*))
      (:macos (merge-pathnames "Resources/" *application-directory*)))))

(defun %executable-path ()
  #+sbcl (truename sb-ext:*runtime-pathname*)
  #-sbcl (error 'build-error :message "A geração de executáveis exige SBCL."))

(defun %release-main ()
  "Restaura bibliotecas relocadas antes de chamar o ponto de entrada da aplicação."
  (handler-case
      (let* ((binary (%executable-path))
             (binary-directory (uiop:pathname-directory-pathname binary))
             (parent (uiop:pathname-parent-directory-pathname binary-directory)))
        (setf *application-directory* (if (eq (host-target) :windows) binary-directory parent))
        (let ((native (ecase (host-target)
                        (:linux (merge-pathnames "lib/" *application-directory*))
                        (:windows *application-directory*)
                        (:macos (merge-pathnames "Frameworks/" *application-directory*)))))
          (%restore-release-libraries native *release-libraries*))
        (let ((code (funcall *release-entry-point* (uiop:command-line-arguments))))
          (uiop:quit (if (integerp code) code 0))))
    (error (condition)
      (format *error-output* "~&Application failed: ~A~%" condition)
      (uiop:quit 1))))

(defun %resolve-native-library (path)
  "Localiza uma biblioteca já carregada sem pressupor caminhos da máquina de build."
  (or (probe-file path)
      (loop for directory in cffi:*foreign-library-directories*
            for candidate = (merge-pathnames (file-namestring path) directory)
            when (probe-file candidate) return (probe-file candidate))
      (loop for directory in (uiop:split-string (or (uiop:getenv "PATH") "")
                               :separator (list (if (uiop:os-windows-p) #\; #\:)))
            unless (zerop (length directory))
              do (let ((candidate (merge-pathnames (file-namestring path)
                                     (uiop:ensure-directory-pathname directory))))
                   (when (probe-file candidate) (return (probe-file candidate)))))
      (when (eq (host-target) :linux)
        (let* ((ldconfig (or (probe-file "/sbin/ldconfig") (probe-file "/usr/sbin/ldconfig") "ldconfig"))
               (listing (ignore-errors
                          (uiop:run-program (list (namestring (pathname ldconfig)) "-p")
                                            :output :string :ignore-error-status t))))
          (loop for line in (uiop:split-string (or listing "") :separator '(#\Newline))
                for words = (remove "" (uiop:split-string line :separator '(#\Space #\Tab)) :test #'equal)
                when (and words (string= (first words) (file-namestring path)))
                  return (probe-file (car (last words))))))
      (loop for directory in '("/opt/homebrew/lib/" "/usr/local/lib/" "/usr/lib/")
            for candidate = (merge-pathnames (file-namestring path) directory)
            when (probe-file candidate) return (probe-file candidate))))

(defun %bundled-library-p (filename)
  "Drivers gráficos e bibliotecas do sistema continuam fornecidos pelo sistema operacional."
  (or (search "glfw" (string-downcase filename)) (search "openal" (string-downcase filename))))

(defun %loaded-library-records ()
  (loop for library in (cffi:list-foreign-libraries)
        for name = (cffi:foreign-library-name library)
        for path = (cffi:foreign-library-pathname library)
        when path collect (list name path)))

(defun %normalize-native-inputs (entries)
  "Conserva nomes de carga e elimina apenas cópias idênticas da mesma biblioteca."
  (let ((seen (make-hash-table :test #'equalp)) (result nil))
    (dolist (entry entries (nreverse result))
      (let* ((source (truename (if (consp entry) (car entry) entry)))
             (name (if (consp entry) (cdr entry) (file-namestring source)))
             (previous (gethash name seen)))
        (%relative-components name)
        (when (and previous (not (equal source previous)))
          (error 'build-error :message (format nil "Bibliotecas diferentes usam o mesmo destino: ~A" name)))
        (unless previous
          (setf (gethash name seen) source)
          (push (cons (namestring source) name) result))))))

(defun %canonical-native-library-source (source)
  "Resolve o caminho de uma biblioteca carregada ou seu nome de carga quando possível."
  (let ((path (or (ignore-errors (truename source))
                  (let ((resolved (ignore-errors (%resolve-native-library source))))
                    (and resolved (ignore-errors (truename resolved)))))))
    (and path (namestring path))))

(defun %native-destination-for-source (source native)
  "Retorna o nome empacotado que corresponde à origem canônica de SOURCE."
  (let ((canonical (%canonical-native-library-source source)))
    (when canonical
      (cdr (assoc canonical native :test #'equal
                                   :key (lambda (entry)
                                          (%canonical-native-library-source entry)))))))

(defun %release-library-record (designator filename bundled-p)
  (list :name designator :filename filename :bundled-p (not (null bundled-p))))

(defun %release-library-records (loaded native)
  "Marca explicitamente quais bibliotecas CFFI foram incluídas no pacote."
  (loop for (designator source) in loaded
        for destination = (%native-destination-for-source source native)
        collect (%release-library-record designator
                                         (or destination (file-namestring source))
                                         destination)))

(defun %restore-release-libraries (native-directory libraries)
  "Carrega bibliotecas empacotadas pelo caminho relocável e as demais pelo CFFI."
  (pushnew native-directory cffi:*foreign-library-directories* :test #'equal)
  (dolist (library libraries)
    (let* ((designator (getf library :name))
           (filename (getf library :filename))
           (bundled (merge-pathnames filename native-directory)))
      (when (getf library :bundled-p)
        (unless (probe-file bundled)
          (error "Bundled library is missing: ~A" bundled))
        ;; A definição absoluta evita usar a instalação da máquina de build.
        (eval `(cffi:define-foreign-library ,designator
                 (t ,(namestring (truename bundled))))))
      (cffi:load-foreign-library designator)))
  libraries)

(defun %loaded-bundled-library-p (record)
  (%bundled-library-p (file-namestring (second record))))

(defun %native-entry-for-source (source native)
  (let ((canonical (%canonical-native-library-source source)))
    (and canonical
         (find canonical native :test #'equal
                                 :key (lambda (entry)
                                        (%canonical-native-library-source (car entry)))))))

(defun %register-lazy-openal-library (libraries native)
  "Inclui a definição CFFI OpenAL mesmo quando o áudio ainda não foi aberto."
  (let ((package (find-package :sgeo.audio.openal)))
    (when package
      (let ((file (find-if (lambda (entry)
                             (or (search "openal" (string-downcase (cdr entry)))
                                 (search "openal" (string-downcase
                                                    (file-namestring (car entry))))))
                           native)))
        (when file
          (let ((designator (find-symbol "%OPENAL-LIBRARY" package)))
            (unless (find designator libraries
                          :key (lambda (record) (getf record :name)) :test #'eq)
              (push (%release-library-record designator (cdr file) t) libraries)))))))
  libraries)

(defun %save-release-image (description executable library-list-path)
  "Prepara uma imagem nova sem janelas, threads de jogo ou caminhos de biblioteca ativos."
  (dolist (system (getf description :systems)) (asdf:load-system system))
  (let* ((entry (getf description :entry))
         (symbol (find-symbol (second entry) (or (find-package (first entry))
                                                (error "Pacote de entrada ausente."))))
         (loaded-libraries (%loaded-library-records))
         (native (getf description :native-libraries)))
    (unless (and symbol (fboundp symbol)) (error "Ponto de entrada não definido: ~S" entry))
    (unless (getf description :debug)
      (when (find-package :sgeo.editor)
        (error 'build-error :message "Uma aplicação release não pode carregar o editor.")))
    (dolist (library loaded-libraries)
      (when (%loaded-bundled-library-p library)
        (let ((path (%resolve-native-library (second library))))
          (unless path (error "Biblioteca nativa não localizada: ~A" (second library)))
          (unless (%native-entry-for-source path native)
            (push (cons (namestring (truename path))
                        (file-namestring (second library)))
                  native)))))
    (setf native (%normalize-native-inputs native))
    (let ((libraries (%register-lazy-openal-library
                      (%release-library-records loaded-libraries native) native)))
    (multiple-value-bind (notices diagnostics)
        (write-license-notices (uiop:pathname-directory-pathname library-list-path)
                              :native-libraries native)
      (declare (ignore notices))
      (with-open-file (stream library-list-path :direction :output :if-exists :supersede)
        (let ((*print-readably* t))
          (write (list :native-libraries native :license-diagnostics diagnostics) :stream stream))))
    (setf *release-entry-point* (symbol-function symbol)
          *release-libraries* libraries
          *release-description* (loop for key in '(:name :version :systems :entry :debug)
                                     append (list key (getf description key))))
    ;; CLOSE remove o objeto compartilhado da lista que o SBCL reabre na inicialização.
    (dolist (library (cffi:list-foreign-libraries))
      (cffi:close-foreign-library (cffi:foreign-library-name library)))
    (setf asdf:*central-registry* nil)
    #+sbcl (sb-ext:save-lisp-and-die executable :executable t :toplevel #'%release-main
                                    :save-runtime-options t :compression t)
    #-sbcl (error 'build-error :message "A geração de executáveis exige SBCL."))))

(defun %absolute-assets (manifest root)
  "Expande arquivos e diretórios como bytes; manifests explícitos escolhem nome e importador."
  (unless (handler-case (or (null manifest) (list-length manifest)) (type-error () nil))
    (error 'build-error :message "A lista de ativos precisa ser própria e finita."))
  (loop for spec in manifest append
    (if (or (stringp spec) (pathnamep spec))
        (let* ((path (truename (merge-pathnames spec root)))
               (directory-p (uiop:directory-exists-p path))
               (base root)
               (files (if directory-p
                          (sort (%safe-package-tree-files path) #'string< :key #'namestring)
                          (list path))))
          (loop for file in files
                for relative = (%portable-relative-name file base)
                for key = (with-output-to-string (out)
                            (loop for character across relative do
                              (format out "~X-" (char-code character))))
                collect (list :name (concatenate 'string "file-"
                                     (string-downcase (ironclad:byte-array-to-hex-string
                                       (ironclad:digest-sequence :sha256
                                         (ironclad:ascii-string-to-byte-array key)))))
                              :source file :importer "bytes")))
        (let ((copy (copy-list spec)))
          (setf (getf copy :source) (merge-pathnames (getf copy :source) root))
          (list copy)))))

(defun %application-description (app root)
  (let ((entry (application-entry-point app)))
    (list :name (application-name app) :version (application-version app)
          :entry (list (package-name (symbol-package entry)) (symbol-name entry))
          :systems (mapcar (lambda (system) (string-downcase (string system))) (application-systems app))
          :native-libraries (application-native-libraries app) :debug (application-debug app)
          :assets (%absolute-assets (application-assets app) root))))

(defun build-application (application &key output-directory project-root (sbcl "sbcl"))
  "Compila ativos e gera um executável em outro processo, depois monta o pacote nativo."
  (let* ((app (if (typep application 'application) application (find-application application)))
         (root (truename (or project-root (asdf:system-source-directory "sgeo")))))
    (unless app (error 'build-error :message "Aplicação não registrada."))
    (unless (member (application-target app) (list :desktop (host-target)))
      (error 'build-error :message "Compile o pacote no próprio sistema alvo; cross-compilation não é oferecida."))
    (let* ((destination (uiop:ensure-directory-pathname
                         (merge-pathnames (or output-directory
                                              (format nil "artifacts/releases/~A-~A-~(~A~)/"
                                                (application-name app) (application-version app) (host-target))) root)))
           (stage (uiop:ensure-directory-pathname
                    (merge-pathnames (format nil ".sgeo-build-~D-~D/" (get-universal-time) (random 1000000))
                                     (uiop:pathname-parent-directory-pathname destination))))
           (executable (merge-pathnames (if (eq (host-target) :windows) "application.exe" "application") stage))
           (script (merge-pathnames "save-image.lisp" stage))
           (libraries (merge-pathnames "libraries.sexp" stage))
           (pack (merge-pathnames "game.sgp" stage))
           (description (%application-description app root)))
      (when (probe-file destination) (error 'build-error :message "O destino do build já existe."))
      (ensure-directories-exist script)
      (unwind-protect
           (progn
             (sgeo.assets:compile-assets (getf description :assets) pack)
             (with-open-file (stream script :direction :output :if-exists :error)
               (let ((*print-readably* t) (*print-case* :downcase))
                 (write `(load ,(namestring (merge-pathnames "tools/bootstrap.lisp"
                                            (asdf:system-source-directory "sgeo")))) :stream stream)
                 (terpri stream)
                 (write `(pushnew ,root asdf:*central-registry* :test #'equal) :stream stream)
                 (terpri stream)
                 (write '(asdf:load-system :sgeo/deployment) :stream stream) (terpri stream)
                 (format stream "(sgeo.deployment::%save-release-image '~S ~S ~S)~%"
                         description (namestring executable) (namestring libraries))))
             (uiop:run-program (list sbcl "--dynamic-space-size" "4096" "--script" (namestring script))
                               :output *standard-output* :error-output *error-output*)
             (let* ((metadata (with-open-file (stream libraries)
                                (let ((*read-eval* nil)) (read stream))))
                    (native (getf metadata :native-libraries))
                    (diagnostics (getf metadata :license-diagnostics))
                    (notices (merge-pathnames "THIRD-PARTY.txt" stage)))
               (let ((result (package-application executable destination
                                 :name (application-name app) :version (application-version app)
                                 :native-libraries native :assets (list pack notices)
                                 :diagnostics diagnostics)))
                   (unless (verify-package (getf result :application))
                     (uiop:delete-directory-tree (getf result :application) :validate t)
                     (when (probe-file (getf result :archive)) (delete-file (getf result :archive)))
                     (error 'build-error :message "Falha na integridade do pacote gerado."))
                   result)))
        (when (probe-file stage) (uiop:delete-directory-tree stage :validate t))))))
