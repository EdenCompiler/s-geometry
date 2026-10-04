;;;; Visualizador M4; o lançador principal continua abrindo o editor.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/pbr)

(defun pbr-viewer-options (arguments)
  "Lê opções do visualizador sem avaliar conteúdo externo."
  (let ((options nil) (open nil))
    (labels ((argument (flag) (or (pop arguments) (error "~A exige um argumento." flag)))
             (positive (flag)
               (let ((number (parse-integer (argument flag))))
                 (unless (plusp number) (error "~A exige um inteiro positivo." flag)) number)))
      (loop while arguments for flag = (pop arguments) do
        (cond ((string= flag "--frames") (setf (getf options :max-frames) (positive flag)))
              ((string= flag "--width") (setf (getf options :width) (positive flag)))
              ((string= flag "--height") (setf (getf options :height) (positive flag)))
              ((string= flag "--hidden") (setf (getf options :visible) nil))
              ((string= flag "--no-repl") (setf (getf options :repl) nil))
              ((string= flag "--validation") (setf (getf options :validation) t))
              ((string= flag "--capture") (setf (getf options :capture-path) (argument flag)))
              ((string= flag "--open") (setf open (argument flag)))
              ((string= flag "--help")
               (format t "sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp [--open scene.sgeo] [--frames N] [--width N] [--height N] [--hidden] [--no-repl] [--validation] [--capture image.ppm]~%")
               (uiop:quit 0))
              (t (error "Opção desconhecida: ~A" flag)))))
    (when open (setf (getf options :world) (sgeo.serialization:load-world open)))
    options))

(handler-case
    (progn
      (format t "~&S-Geometry/CL — PBR em Vulkan, shaders escritos em Lisp~%")
      (format t "LMB: selecionar | RMB: orbitar | MMB: deslocar | roda: zoom | R: recompilar shaders | Esc: sair~%")
      (multiple-value-bind (world renderer report)
          (apply #'sgeo.examples.pbr:run-pbr-viewer (pbr-viewer-options (uiop:command-line-arguments)))
        (declare (ignore world))
        (format t "~&Visualizador concluído: ~D quadros, ~D envios de malha.~%"
                (sgeo.runtime:runtime-report-frames report) (sgeo.runtime:runtime-report-uploads report))
        (let ((failure (or (sgeo.runtime:runtime-report-platform-error report)
                           (sgeo.runtime:runtime-report-render-error report))))
          (when failure (error failure)))
        (let ((messages (getf (sgeo.render:renderer-info renderer) :validation-messages)))
          (when messages (error "Validação Vulkan: ~S" messages)))))
  (error (condition)
    (format *error-output* "~&Falha no visualizador: ~A~%" condition) (uiop:quit 1)))
