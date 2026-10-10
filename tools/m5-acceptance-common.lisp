(defun m5-check (condition description)
  "Interrompe a aceitação quando uma exigência observável não foi cumprida."
  (unless condition (error "M5: ~A" description)) t)

(defun m5-close-enough-p (a b)
  "Compara dados numéricos derivados com tolerância, preservando estrutura e nomes."
  (cond ((and (numberp a) (numberp b))
         (<= (abs (- a b)) (* 1d-7 (max 1d0 (abs a) (abs b)))))
        ((and (consp a) (consp b)) (and (m5-close-enough-p (car a) (car b)) (m5-close-enough-p (cdr a) (cdr b))))
        ((and (vectorp a) (not (stringp a)) (vectorp b) (not (stringp b)))
         (and (= (length a) (length b)) (every #'m5-close-enough-p a b)))
        (t (equal a b))))

(defun m5-world-evidence (world)
  "Registra fontes, poses e pistas para comparar a cena em uma imagem Lisp nova."
  (let* ((entries (getf (sg:render-snapshot world) :objects))
         (state (sg:world-animation-state world)))
    (list
     :meshes
     (mapcar (lambda (entry)
               (let ((object (getf entry :object)))
                 (list :name (sg:object-name object)
                       :source-positions (coerce (sg:mesh-positions (sg:mesh-object-geometry object)) 'list)
                       :indices (coerce (getf entry :indices) 'list)
                       :positions (coerce (getf entry :positions) 'list)
                       :normals (coerce (getf entry :normals) 'list)
                       :model (coerce (getf entry :model-matrix) 'list)))) entries)
     :clips (mapcar (lambda (clip)
                      (list (sg:clip-duration clip)
                            (loop for track in (sg:clip-tracks clip)
                                  when (typep track 'sg:property-track)
                                  collect (list (sg:object-name (sg:track-target track))
                                                (sg:track-path track) (sg:track-interpolation track)
                                                (sg:track-easings track)
                                                (mapcar (lambda (key)
                                                          (mapcar (lambda (value)
                                                                    (typecase value
                                                                      (sg:quaternion (coerce (sgeo.math::quaternion-data value) 'list))
                                                                      (vector (coerce value 'list))
                                                                      (otherwise value))) key))
                                                        (sg:track-keys track))))))
                    (sg:animation-state-clips state))
     :players (mapcar (lambda (player) (list (sg:player-time player) (sg:player-weight player)
                                             (sg:player-speed player) (sg:player-playing-p player)
                                             (sg:player-looping-p player) (sg:player-additive-p player)))
                      (sg:animation-state-players state)))))

(defun m5-write-evidence (world path)
  "Grava somente dados de referência produzidos pela aceitação."
  (ensure-directories-exist path)
  (with-open-file (stream path :direction :output :if-exists :supersede)
    (let ((*print-readably* t) (*print-pretty* nil)) (prin1 (m5-world-evidence world) stream))))

(defun m5-read-evidence (path)
  "Lê o arquivo de comparação sem permitir avaliação pelo leitor."
  (with-open-file (stream path)
    (let ((*read-eval* nil)) (read stream))))
