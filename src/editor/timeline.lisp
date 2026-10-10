(in-package #:sgeo.editor)

(defun %timeline-clips (editor)
  (let ((state (sgeo.scene:world-animation-state (editor-world editor))))
    (when state (sgeo.animation:animation-state-clips state))))

(defun select-animation-clip (editor clip)
  "Seleciona o clipe vivo e reutiliza seu player na linha do tempo."
  (call-in-editor editor
    (lambda ()
      (unless (member clip (%timeline-clips editor))
        (error "O clipe precisa pertencer ao mundo do editor."))
      (let* ((state (sgeo.animation:ensure-animation-state (editor-world editor)))
             (player (or (find clip (sgeo.animation:animation-state-players state)
                              :key #'sgeo.animation:player-clip)
                         (sgeo.animation:play-animation (editor-world editor) clip))))
        (setf (editor-animation-clip editor) clip
              (editor-animation-track editor) (first (sgeo.animation:clip-tracks clip))
              (editor-animation-key editor) nil
              (editor-animation-player editor) player
              (sgeo.animation:player-playing-p player) (editor-playing-p editor)
              (editor-time editor) (sgeo.animation:player-time player))
        clip))))

(defun %ensure-timeline-selection (editor)
  (let ((clips (%timeline-clips editor)))
    (unless (member (editor-animation-clip editor) clips)
      (setf (editor-animation-clip editor) nil (editor-animation-track editor) nil
            (editor-animation-player editor) nil (editor-animation-key editor) nil)
      (when clips (select-animation-clip editor (first clips))))))

(defun timeline-data (editor)
  "Descreve a linha do tempo usando referências aos clipes e pistas do mundo."
  (call-in-editor editor
    (lambda ()
      (%ensure-timeline-selection editor)
      (let* ((clip (editor-animation-clip editor))
             (player (editor-animation-player editor)))
        (list :clips (%timeline-clips editor) :clip clip :player player
              :time (if player (sgeo.animation:player-time player) (editor-time editor))
              :duration (if clip (sgeo.animation:clip-duration clip) 10d0)
              :tracks (when clip (sgeo.animation:clip-tracks clip))
              :track (editor-animation-track editor) :key (editor-animation-key editor))))))

(defun scrub-animation (editor time)
  "Amostra o clipe selecionado sem avançar eventos nem criar outro estado de projeto."
  (let ((time (%editor-time-number time)))
    (call-in-editor editor
      (lambda ()
        (%ensure-timeline-selection editor)
        (unless (editor-animation-player editor) (error "Selecione um clipe antes de mover o cursor."))
        (setf (editor-playing-p editor) nil
              (sgeo.animation:player-playing-p (editor-animation-player editor)) nil)
        (sgeo.animation:seek-animation (editor-animation-player editor) time)
        (setf (editor-time editor) (sgeo.animation:player-time (editor-animation-player editor)))))))

(defun %timeline-track (editor track)
  (let ((track (or track (editor-animation-track editor))))
    (unless (and (editor-animation-clip editor) (typep track 'sgeo.animation:property-track)
                 (member track (sgeo.animation:clip-tracks (editor-animation-clip editor))))
      (error "Selecione uma pista de propriedades neste clipe."))
    track))

(defun %zero-animation-value (value)
  (typecase value
    (number 0d0)
    (sgeo.math:quaternion (sgeo.math:make-quaternion 0d0 0d0 0d0 0d0))
    (vector (map 'vector (lambda (x) (declare (ignore x)) 0d0) value))
    (otherwise (error "O valor não admite tangentes numéricas."))))

(defun %timeline-reevaluate (editor)
  (sgeo.animation:evaluate-animation-state
   (sgeo.animation:ensure-animation-state (editor-world editor))))

(defun %timeline-key-entries (track)
  "Mantém o easing junto da chave durante inserções, remoções e reordenação."
  (mapcar #'list (sgeo.animation:track-keys track) (sgeo.animation:track-easings track)))

(defun %set-timeline-key-entries (track entries)
  (setf (slot-value track 'sgeo.animation::easings) (mapcar #'second entries))
  (sgeo.animation:set-track-keys track (mapcar #'first entries)))

(defun add-animation-key (editor &key track (time (editor-time editor)) (value nil value-p))
  "Grava o valor atual da propriedade em uma chave, dentro do histórico do editor."
  (let ((time (%editor-time-number time)))
    (call-in-editor editor
      (lambda ()
        (%ensure-timeline-selection editor)
        (let ((track (%timeline-track editor track)))
          (call-with-edit-transaction editor "Record animation key"
            (lambda ()
              (let* ((value (if value-p value (sgeo.animation:read-track-value track)))
                     (key (if (eq (sgeo.animation:track-interpolation track) :cubic-spline)
                              (list time value (%zero-animation-value value) (%zero-animation-value value))
                              (list time value)))
                     (entries (remove time (%timeline-key-entries track)
                                      :key (lambda (entry) (first (first entry))) :test #'=)))
                (%set-timeline-key-entries track
                  (sort (cons (list key nil) entries) #'< :key (lambda (entry) (first (first entry)))))
                (setf (sgeo.animation:clip-duration (editor-animation-clip editor))
                      (max time (sgeo.animation:clip-duration (editor-animation-clip editor)))
                      (editor-animation-track editor) track
                      (editor-animation-key editor) (position time (sgeo.animation:track-keys track)
                                                             :key #'first :test #'=))
                (%timeline-reevaluate editor) key))))))))

(defun delete-animation-key (editor &key track (index (editor-animation-key editor)))
  "Remove uma chave selecionada sem deixar uma pista inválida no clipe."
  (call-in-editor editor
    (lambda ()
      (let* ((track (%timeline-track editor track)) (keys (sgeo.animation:track-keys track)))
        (unless (and (integerp index) (<= 0 index) (< index (length keys)))
          (error "Selecione uma chave para remover."))
        (call-with-edit-transaction editor "Delete animation key"
          (lambda ()
            (if (= 1 (length keys))
                (setf (sgeo.animation:clip-tracks (editor-animation-clip editor))
                      (remove track (sgeo.animation:clip-tracks (editor-animation-clip editor)))
                      (editor-animation-track editor) nil)
                (%set-timeline-key-entries track
                  (loop for entry in (%timeline-key-entries track) for i from 0 unless (= i index) collect entry)))
            (setf (editor-animation-key editor) nil)
            (%timeline-reevaluate editor)))))))

(defun move-animation-key (editor time &key track (index (editor-animation-key editor)))
  "Reposiciona a chave selecionada; colisões com outras chaves são recusadas."
  (let ((time (%editor-time-number time)))
    (call-in-editor editor
      (lambda ()
        (let* ((track (%timeline-track editor track)) (keys (sgeo.animation:track-keys track)))
          (unless (and (integerp index) (<= 0 index) (< index (length keys)))
            (error "Selecione uma chave para mover."))
          (call-with-edit-transaction editor "Move animation key"
            (lambda ()
              (let ((entries (copy-tree (%timeline-key-entries track))))
                (setf (first (first (nth index entries))) time)
                (%set-timeline-key-entries track
                  (sort entries #'< :key (lambda (entry) (first (first entry))))))
              (setf (editor-animation-key editor)
                    (position time (sgeo.animation:track-keys track) :key #'first :test #'=)
                    (sgeo.animation:clip-duration (editor-animation-clip editor))
                    (max time (sgeo.animation:clip-duration (editor-animation-clip editor))))
              (%timeline-reevaluate editor))))))))

(defun create-editor-animation (editor &key object (path '(position)) (duration 2d0) (name "Motion"))
  "Cria um clipe editável para a propriedade do objeto selecionado."
  (call-in-editor editor
    (lambda ()
      (let* ((target (or object (sgeo.scene:world-selection (editor-world editor))))
             (duration (%editor-time-number duration t)))
        (unless target (error "Selecione um objeto para animar."))
        (call-with-edit-transaction editor "Create animation"
          (lambda ()
            (let* ((getter (sgeo.animation:animation-property-accessors target path))
                   (value (funcall getter))
                   (track (sgeo.animation:make-property-track target path (list (list 0d0 value)))))
              (sgeo.animation:set-track-keys track (list (list 0d0 value) (list duration value)))
              (let ((clip (sgeo.animation:make-animation-clip :name name :tracks (list track) :duration duration)))
                (sgeo.animation:add-animation-clip (editor-world editor) clip)
                (select-animation-clip editor clip) clip))))))))

(defun import-editor-gltf (editor path)
  "Importa o ativo validado como uma transação na cena que está aberta."
  (call-in-editor editor
    (lambda ()
      (call-with-edit-transaction editor "Import glTF"
        (lambda ()
          (let ((asset (sgeo.gltf:import-gltf path :world (editor-world editor))))
            (%ensure-timeline-selection editor)
            (setf (editor-status editor) (format nil "Imported: ~A" path)) asset))))))

(defun export-editor-gltf (editor path &key binary)
  "Exporta a cena e seus clipes para o formato de intercâmbio."
  (call-in-editor editor
    (lambda () (sgeo.gltf:export-gltf (editor-world editor) path :binary binary))))
