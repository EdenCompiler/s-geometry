;;;; Abre a cena M4 em uma imagem SBCL nova e a renderiza em Vulkan.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/pbr)
(load (merge-pathnames "m4-acceptance-common.lisp" (uiop:pathname-directory-pathname *load-truename*)))

(handler-case
    (destructuring-bind (scene-path expected-path) (uiop:command-line-arguments)
      (let* ((world (sgeo.serialization:load-world scene-path))
             (actual (m4-canonical-scene (sgeo.serialization:scene-data world)))
             (expected (m4-canonical-scene (m4-read-data expected-path))))
        (m4-check (m4-data-equivalent-p expected actual) "cena reaberta equivalente em sessão nova")
        (multiple-value-bind (returned renderer report)
            (sgeo.examples.pbr:run-pbr-viewer :world world :width 640 :height 420
                                             :visible nil :repl nil :max-frames 4 :validation t
                                             :capture-path (merge-pathnames "artifacts/m4-reopened.ppm" *project-root*))
          (m4-check (eq returned world) "mundo reaberto preservado")
          (m4-check (= 4 (sgeo.runtime:runtime-report-frames report)) "renderização na sessão nova")
          (m4-check (not (or (sgeo.runtime:runtime-report-platform-error report)
                             (sgeo.runtime:runtime-report-render-error report))) "sessão nova sem erro")
          (m4-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages))
                    "sessão nova encerrada sem recursos Vulkan pendentes")))
      (format t "M4: geometria, materiais e luz reabertos e renderizados em sessão SBCL nova.~%"))
  (error (condition) (format *error-output* "~&~A~%" condition) (uiop:quit 1)))
