;;;; Prepara dependências Common Lisp da CI sem carregar o editor.
(require :asdf)

(defparameter *ci-project-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *compile-file-truename*))))
(defparameter *ci-quicklisp-directory*
  (merge-pathnames "quicklisp/" (user-homedir-pathname)))
(defparameter *ci-quicklisp-setup*
  (merge-pathnames "setup.lisp" *ci-quicklisp-directory*))

(unless (probe-file *ci-quicklisp-setup*)
  (let ((installer (merge-pathnames "sgeo-quicklisp-install.lisp" (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (uiop:run-program
            (list "curl" "--fail" "--silent" "--show-error" "--location"
                  "https://beta.quicklisp.org/quicklisp.lisp" "--output"
                  (namestring installer))
            :output *standard-output* :error-output *error-output*)
           (load installer)
           (funcall (find-symbol "INSTALL" "QUICKLISP-QUICKSTART")
                    :path *ci-quicklisp-directory*))
      (when (probe-file installer) (delete-file installer)))))

(load *ci-quicklisp-setup*)
(pushnew *ci-project-root* asdf:*central-registry* :test #'equal)
(asdf:load-asd (merge-pathnames "sgeo.asd" *ci-project-root*))
(ql:quickload '(:bordeaux-threads :cffi :ironclad :yason :fiveam) :silent t)
(let ((search-path (uiop:getenv "SGEO_NATIVE_LIBRARY_PATH")))
  (when (and search-path (plusp (length search-path)))
    (dolist (directory (uiop:split-string
                        search-path
                        :separator (list (if (uiop:os-windows-p) #\; #\:))))
      (unless (string= directory "")
        (pushnew (uiop:ensure-directory-pathname (pathname directory))
                 cffi:*foreign-library-directories* :test #'equalp)))))
(ql:quickload '(:cl-glfw3 :cl-opengl) :silent t)
;; Compila a rota nativa do jogo, sem criar janela ou inicializar dispositivos.
(asdf:load-system :sgeo/game/opengl)
(unless (and (asdf:find-system :sgeo/game/opengl nil)
             (not (find-package :sgeo.editor)))
  (error "A rota de jogo não foi carregada isolada do editor."))
(format t "Dependências Lisp e sistemas de release carregados; nenhum dispositivo foi aberto.~%")
