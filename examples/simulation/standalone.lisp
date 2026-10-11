(defpackage #:sgeo.game
  (:use #:cl)
  (:export #:main #:make-packed-game #:game-self-test-input))
(in-package #:sgeo.game)

(defun %read-scene-product (bytes)
  "Lê dados canônicos sem leitor executável e rejeita conteúdo adicional."
  (let ((*read-eval* nil) (*package* (find-package :keyword)))
    (with-input-from-string (stream (babel:octets-to-string bytes :encoding :utf-8 :errorp t))
      (let* ((eof (gensym)) (data (read stream nil eof)))
        (when (or (eq data eof) (not (eq (read stream nil eof) eof)))
          (error "Invalid geometry asset."))
        (sgeo.serialization:world-from-data data)))))

(defun %pcm-buffer (bytes)
  "Converte o produto PCM16 little-endian mono em amostras do mixer Lisp."
  (unless (and (plusp (length bytes)) (evenp (length bytes))) (error "Invalid PCM asset."))
  (sgeo.audio:make-audio-buffer :sample-rate 44100 :channels 1
    :samples (map '(vector single-float)
                  (lambda (word) (/ (float (if (> word 32767) (- word 65536) word) 1f0) 32768f0))
                  (loop for offset from 0 below (length bytes) by 2
                        collect (logior (aref bytes offset) (ash (aref bytes (1+ offset)) 8))))))

(defun make-packed-game (path)
  "Cria a mesma partida M6 usando geometria e áudio do cache distribuído."
  (let* ((pack (sgeo.assets:load-asset-pack path))
         (geometry (sgeo.assets:find-packed-asset pack "geometry"))
         (audio (sgeo.assets:find-packed-asset pack "collect-tone")))
    (unless (and geometry audio) (error "The game asset pack is incomplete."))
    (let* ((templates (%read-scene-product (sgeo.assets:packed-asset-bytes geometry)))
           (box (sgeo.scene:find-object templates "box"))
           (coin (sgeo.scene:find-object templates "coin"))
           (player (sgeo.scene:find-object templates "player")))
      (unless (every (lambda (object) (typep object 'sgeo.scene:mesh-object)) (list box coin player))
        (error "Missing geometry templates."))
      (sgeo.examples.simulation:make-game-world
        :audio-buffer (%pcm-buffer (sgeo.assets:packed-asset-bytes audio))
        :geometry-provider
        (lambda (kind radius name)
          (declare (ignore name))
          (sgeo.scene:mesh-object-geometry
            (ecase kind (:box box)
                        (:sphere (cond ((= radius 0.18d0) coin) ((= radius 0.35d0) player)
                                       (t (error "Unknown sphere template.")))))))))))

(defun game-self-test-input (game)
  "Exercita a partida por entrada semântica; não altera placar, corpos ou estados diretamente."
  (let* ((input (sgeo.examples.simulation:game-input game))
         (position (sgeo.physics:body-position (sgeo.examples.simulation:game-player-body game)))
         (won (eq :won (sgeo.examples.simulation:game-status game))))
    (sgeo.input:queue-input-event input :key :code :d :action (if won :release :press))
    (sgeo.input:queue-input-event input :key :code :e
      :action (if (and (not won) (> (sgeo.math:vx position) 0.4d0)
                       (not (sgeo.examples.simulation:game-door-locked-p game))) :press :release))
    (sgeo.input:queue-input-event input :key :code :w
      :action (if (and (not won) (sgeo.examples.simulation:game-door-open-p game)
                       (> (sgeo.math:vz position) 0.02d0)) :press :release))))

(defun %options (arguments)
  (let ((options (list :frames nil :headless nil :self-test nil :hidden nil)))
    (labels ((value (option) (or (pop arguments) (error "~A needs an argument." option))))
      (loop while arguments for option = (pop arguments) do
        (cond ((member option '("--headless" "--self-test" "--hidden" "--audio" "--diagnostics") :test #'equal)
               (setf (getf options (intern (string-upcase (subseq option 2)) :keyword)) t))
              ((string= option "--frames")
               (let ((frames (parse-integer (value option) :junk-allowed nil)))
                 (unless (plusp frames) (error "--frames must be positive."))
                 (setf (getf options :frames) frames)))
              ((member option '("--assets" "--capture" "--profile") :test #'equal)
               (setf (getf options (intern (string-upcase (subseq option 2)) :keyword)) (value option)))
              ((string= option "--help") (setf (getf options :help) t))
              (t (error "Unknown option: ~A" option)))))
    (when (and (getf options :headless) (getf options :audio))
      (error "Audio device output needs the window loop."))
    options))

(defun main (arguments)
  "Ponto de entrada release; falhas retornam código não zero e deixam relatório de perfil."
  (let ((options (%options arguments)))
    (when (getf options :help)
      (format t "sgeo-game [--frames N] [--hidden] [--audio] [--headless] [--self-test] [--assets FILE] [--capture FILE.ppm] [--profile FILE.json] [--diagnostics]~%")
      (return-from main 0))
    (when (find-package :sgeo.editor) (error "The release image contains the development editor."))
    (let* ((profiler (sgeo.diagnostics:make-profiler
                      :enabled (or (getf options :profile) (getf options :diagnostics))
                      :timeline-limit 20000
                      :renderer-info (list :application "sgeo-game" :editor-loaded :false
                                           :asset-pack "game.sgp")))
           (pack (or (getf options :assets) (sgeo.deployment:application-resource-path "game.sgp")))
           (world nil) (game nil) (output nil)
           (frames (or (getf options :frames) (when (or (getf options :headless) (getf options :self-test)) 240))))
      (unwind-protect
           (handler-case
               (progn
                 (multiple-value-setq (world game) (make-packed-game pack))
                 (when (getf options :audio)
                   (setf output (uiop:symbol-call :sgeo.audio.openal :make-openal-output))
                   (sgeo.simulation:add-phase-hook (sgeo.examples.simulation:game-simulation game) :audio
                     (lambda (w state dt) (declare (ignore w dt))
                       (uiop:symbol-call :sgeo.audio.openal :submit-audio output
                         (sgeo.simulation:simulation-audio-samples state)))))
                 (if (getf options :headless)
                     (dotimes (frame frames)
                       (declare (ignore frame))
                       (sgeo.diagnostics:begin-frame profiler)
                       (unwind-protect
                            (sgeo.diagnostics:with-profile-scope ("game/frame" :profiler profiler :subsystem :game)
                              (when (getf options :self-test) (game-self-test-input game))
                              (sgeo.scene:update-world world (/ 1d0 60d0)))
                         (sgeo.diagnostics:end-frame profiler)))
                     (multiple-value-bind (w renderer report)
                         (uiop:symbol-call :sgeo.runtime :run-world world :controls :game :repl nil
                           :title "S-Geometry: Coins and Door" :visible (not (getf options :hidden))
                           :max-frames frames :profiler profiler :capture-path (getf options :capture)
                           :frame-dt (when (getf options :self-test) (/ 1d0 60d0))
                           :frame-hook (when (getf options :self-test)
                                         (lambda (w window renderer frame)
                                           (declare (ignore w window renderer frame)) (game-self-test-input game))))
                       (declare (ignore w renderer))
                       (when (or (sgeo.runtime:runtime-report-render-error report)
                                 (sgeo.runtime:runtime-report-platform-error report))
                         (error "Window loop failed: ~S" report))))
                 (when (getf options :self-test)
                   (unless (and (= 3 (sgeo.examples.simulation:game-score game))
                                (sgeo.examples.simulation:game-door-open-p game)
                                (eq :won (sgeo.examples.simulation:game-status game)))
                     (error "Game self-test failed: score=~D, status=~S"
                            (sgeo.examples.simulation:game-score game) (sgeo.examples.simulation:game-status game)))
                   (format t "Standalone game self-test passed: 3 coins, open door, won; editor absent.~%"))
                 0)
             (error (condition)
               (sgeo.diagnostics:record-diagnostic-error profiler condition :phase :game)
               (format *error-output* "Game failed: ~A~%" condition) 1))
        (when output (uiop:symbol-call :sgeo.audio.openal :close-audio-output output))
        (when world (sgeo.simulation:detach-simulation world :close-audio t))
        (let ((info (getf (sgeo.diagnostics:profiler-snapshot profiler) :renderer-info)))
          (setf (getf info :application) "sgeo-game"
                (getf info :editor-loaded) :false
                (getf info :asset-pack) "game.sgp")
          (sgeo.diagnostics:set-profiler-renderer-info profiler info))
        (when (getf options :diagnostics)
          (write-line (sgeo.diagnostics:profile-report profiler :format :text)))
        (when (getf options :profile)
          (sgeo.diagnostics:write-profile-report profiler (getf options :profile)))))))
