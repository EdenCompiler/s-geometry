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
