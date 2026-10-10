;;;; Partida interativa com física, eventos, animação e áudio opcional.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(load (merge-pathnames "simulation-options.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/examples/simulation/opengl)
(handler-case
    (multiple-value-bind (visible repl frames capture audio packed count)
        (simulation-options (uiop:command-line-arguments))
      (declare (ignore count))
      (when packed (error "--packed é uma opção do lançador Boids."))
      (multiple-value-bind (world game) (sgeo.examples.simulation:make-game-world)
        (let ((output nil))
          (unwind-protect
               (progn
                 (when audio
                   (asdf:load-system :sgeo/audio/openal)
                   (setf output (uiop:symbol-call :sgeo.audio.openal :make-openal-output))
                   (sgeo.simulation:add-phase-hook (sgeo.examples.simulation:game-simulation game) :audio
                     (lambda (world state dt) (declare (ignore world dt))
                       (uiop:symbol-call :sgeo.audio.openal :submit-audio output (sgeo.simulation:simulation-audio-samples state)))))
                 (format t "WASD/setas: mover | Espaço: pular | E/clique: porta | P: pausar | R: reiniciar | F1: colisões~%")
                 (multiple-value-bind (world renderer report)
                     (sgeo.runtime:run-world world :title "S-Geometry — Moedas e Porta" :width 1280 :height 800
                       :controls :game :visible visible :repl repl :max-frames frames :capture-path capture)
                   (declare (ignore world renderer))
                   (when (or (sgeo.runtime:runtime-report-render-error report) (sgeo.runtime:runtime-report-platform-error report))
                     (error "Falha no jogo: ~S" report))
                   (format t "Jogo: ~D quadros.~%" (sgeo.runtime:runtime-report-frames report))))
            (when output (uiop:symbol-call :sgeo.audio.openal :close-audio-output output))
            (sgeo.simulation:detach-simulation world :close-audio t)))))
  (error (condition) (format *error-output* "~&Falha no jogo: ~A~%" condition) (uiop:quit 1)))
