;;;; Compila o jogo release sem carregar o editor.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/deployment)
(asdf:load-system :sgeo/assets/importers)
(asdf:load-system :sgeo/game/opengl)

(handler-case
    (let ((arguments (uiop:command-line-arguments)) (output nil) (libraries nil))
      (loop while arguments for option = (pop arguments) do
        (cond ((string= option "--output") (setf output (or (pop arguments) (error "--output needs a directory."))))
              ((string= option "--native-lib") (push (truename (or (pop arguments) (error "--native-lib needs a file."))) libraries))
              ((string= option "--help")
               (format t "sbcl --script tools/build.lisp [--output DIRECTORY] [--native-lib FILE ...]~%")
               (uiop:quit 0))
              (t (error "Unknown option: ~A" option))))
      ;; OpenAL é carregado apenas ao solicitar saída, mas acompanha o pacote quando disponível.
      (let* ((name (ecase (sgeo.deployment:host-target)
                     (:linux "libopenal.so.1") (:windows "OpenAL32.dll") (:macos "libopenal.1.dylib")))
             (openal (sgeo.deployment::%resolve-native-library name)))
        (when openal (pushnew (cons (namestring (truename openal)) name) libraries :test #'equal)))
      (sgeo.deployment:define-application sgeo-game
        :entry-point 'sgeo.game:main :systems '(:sgeo/game/opengl)
        :native-libraries libraries
        :assets (list (list :name "geometry" :source (merge-pathnames "assets/game/geometry.sgeo" *project-root*) :importer "scene")
                      (list :name "collect-tone" :source (merge-pathnames "assets/game/collect.pcm" *project-root*) :importer "bytes")))
      (let ((result (sgeo.deployment:build-application 'sgeo-game :output-directory output)))
        (format t "~&Application: ~A~%Archive: ~A~%" (getf result :application) (getf result :archive))))
  (error (condition) (format *error-output* "Build failed: ~A~%" condition) (uiop:quit 1)))
