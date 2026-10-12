;;;; Localiza o projeto pelo próprio arquivo, sem depender do diretório corrente.
(require :asdf)
(let ((quicklisp (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (and (not (find-package :ql)) (probe-file quicklisp))
    (load quicklisp)))
(defparameter *project-root*
  (uiop:pathname-parent-directory-pathname
   (uiop:pathname-directory-pathname (or *load-truename* *compile-file-truename*))))
(pushnew *project-root* asdf:*central-registry* :test #'equal)
(asdf:load-asd (merge-pathnames "sgeo.asd" *project-root*))

;; Aplica os caminhos configurados também aos novos processos de build.
(let ((native-path (uiop:getenv "SGEO_NATIVE_LIBRARY_PATH")))
  (when (and native-path (plusp (length native-path)))
    (asdf:load-system :cffi)
    (let ((directories (find-symbol "*FOREIGN-LIBRARY-DIRECTORIES*" "CFFI")))
      (dolist (directory (reverse (uiop:split-string native-path
                                      :separator (list (if (uiop:os-windows-p) #\; #\:)))))
        (unless (string= directory "")
          (pushnew (uiop:ensure-directory-pathname (pathname directory))
                   (symbol-value directories) :test #'equalp))))))
