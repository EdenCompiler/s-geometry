(in-package #:sgeo.editor)

(defun %snapshot-value (value &optional (seen (make-hash-table :test #'eq)))
  "Copia dados mutáveis de slots, preservando referências a instâncias vivas."
  (or (gethash value seen)
      (typecase value
        (sgeo.math:transform
         (sgeo.math:make-transform :position (copy-seq (sgeo.math:transform-position value))
                                  :rotation (%snapshot-value (sgeo.math:transform-rotation value) seen)
                                  :scale (copy-seq (sgeo.math:transform-scale value))))
        (sgeo.math:quaternion
         (apply #'sgeo.math:make-quaternion (coerce (sgeo.math::quaternion-data value) 'list)))
        (cons (let ((copy (cons nil nil)))
                (setf (gethash value seen) copy
                      (car copy) (%snapshot-value (car value) seen)
                      (cdr copy) (%snapshot-value (cdr value) seen)) copy))
        (hash-table
         (let ((copy (make-hash-table :test (hash-table-test value))))
           (setf (gethash value seen) copy)
           (maphash (lambda (key item) (setf (gethash (%snapshot-value key seen) copy)
                                          (%snapshot-value item seen))) value) copy))
        (array (let ((copy (make-array (array-dimensions value) :element-type (array-element-type value))))
                 (setf (gethash value seen) copy)
                 (dotimes (index (array-total-size value) copy)
                   (setf (row-major-aref copy index) (%snapshot-value (row-major-aref value index) seen)))))
        (otherwise value))))

(defun %capture-slots (object)
  "Captura slots editáveis sem copiar identidade, locks ou observadores."
  #+sbcl
  (loop for definition in (sb-mop:class-slots (class-of object))
        for name = (sb-mop:slot-definition-name definition)
        unless (member name '(sgeo.core::id sgeo.core::revision sgeo.core::observer-lock
                              sgeo.core::observers sgeo.geometry::state sgeo.geometry::kernel-lock
                              sgeo.geometry::data-lock sgeo.geometry::positions
                              sgeo.geometry::normals sgeo.geometry::indices sgeo.geometry::bounds))
        when (slot-boundp object name)
        collect (list name (%snapshot-value (slot-value object name))))
  #-sbcl
  (error "O inspector de snapshots requer MOP nesta plataforma."))

(defun %restore-slots (record)
  (destructuring-bind (object slots) record
    (dolist (entry slots)
      (setf (slot-value object (first entry)) (%snapshot-value (second entry))))
    (sgeo.core:touch-object object :snapshot-restored)))

(defun capture-editor-snapshot (editor)
  "Captura o estado autoritativo completo, sem copiar caches de GPU."
  (sgeo.scene:with-world-lock ((editor-world editor))
    (let* ((world (editor-world editor))
           (objects (remove-duplicates (cons (sgeo.scene:world-camera world) (editor-objects editor)) :test #'eq))
           (meshes (remove-duplicates
                    (loop for object in objects when (typep object 'sgeo.scene:mesh-object)
                          collect (sgeo.scene:mesh-object-geometry object)) :test #'eq))
           (materials (remove-duplicates
                       (loop for object in objects when (typep object 'sgeo.scene:mesh-object)
                             collect (sgeo.scene:mesh-object-material object)) :test #'eq)))
      (make-editor-snapshot
       :root (sgeo.scene:world-root world) :camera (sgeo.scene:world-camera world)
       :selection (sgeo.scene:world-selection world)
       :records (mapcar (lambda (object) (list object (%capture-slots object))) objects)
       :materials (mapcar (lambda (material) (list material (%capture-slots material))) materials)
       :meshes (mapcar (lambda (mesh)
                         (list mesh (%capture-slots mesh)
                               (etypecase mesh
                                 (sgeo.geometry:half-edge-mesh
                                  (sgeo.geometry::%with-kernel-lock (mesh)
                                    (sgeo.geometry::%clone-state (sgeo.geometry::%mesh-state mesh))))
                                 (sgeo.geometry:triangle-mesh (sgeo.core:compile-render-data mesh)))))
                       meshes)))))

(defun %arena-merge-generations (desired current)
  "Mantém o limite de slots e avança gerações mesmo quando o histórico encolhe."
  (let ((items (sgeo.geometry::%arena-items desired))
        (generations (sgeo.geometry::%arena-generations desired))
        (current-generations (sgeo.geometry::%arena-generations current)))
    (loop while (< (length items) (length current-generations))
          do (vector-push-extend nil items) (vector-push-extend 0 generations))
    (dotimes (index (length generations))
      (setf (aref generations index)
            (1+ (max (aref generations index)
                     (if (< index (length current-generations)) (aref current-generations index) 0)))))
    desired))

(defun %restore-kernel-state (mesh stored)
  "Restaura polígonos na mesma malha, invalidando identificadores anteriores."
  (sgeo.geometry::%with-kernel-lock (mesh)
    (let ((state (sgeo.geometry::%clone-state stored))
          (current (sgeo.geometry::%mesh-state mesh)))
      (dolist (accessor '(sgeo.geometry::%state-vertices sgeo.geometry::%state-faces
                         sgeo.geometry::%state-edges sgeo.geometry::%state-half-edges))
        (%arena-merge-generations (funcall accessor state) (funcall accessor current)))
      ;; A reconstrução não pode reutilizar identidades cuja geração foi avançada.
      (dolist (accessor '(sgeo.geometry::%state-edges sgeo.geometry::%state-half-edges))
        (fill (sgeo.geometry::%arena-items (funcall accessor state)) nil))
      (clrhash (sgeo.geometry::mesh-state-edge-identities state))
      (clrhash (sgeo.geometry::mesh-state-half-edge-identities state))
      (sgeo.geometry::%rebuild-topology state)
      (sgeo.geometry::%validate-state state)
      (setf (sgeo.geometry::%mesh-state mesh) state)
      (sgeo.core:touch-object mesh :history-restored))))

(defun restore-editor-snapshot (editor snapshot)
  "Restaura a cena mantendo mundo, objetos sobreviventes e revisões monotônicas."
  (call-in-editor editor
    (lambda ()
      (let ((world (editor-world editor)))
        (sgeo.scene:with-world-lock (world)
          (let ((kept (mapcar #'first (editor-snapshot-records snapshot))))
            (dolist (object (editor-objects editor))
              (unless (member object kept :test #'eq)
                (setf (slot-value object 'sgeo.scene::parent) nil
                      (slot-value object 'sgeo.scene::world) nil))))
          (setf (slot-value world 'sgeo.scene::root) (editor-snapshot-root snapshot)
                (slot-value world 'sgeo.scene::camera) (editor-snapshot-camera snapshot))
          (mapc #'%restore-slots (editor-snapshot-records snapshot))
          (mapc #'%restore-slots (editor-snapshot-materials snapshot))
          (dolist (entry (editor-snapshot-meshes snapshot))
            (destructuring-bind (mesh slots data) entry
              (dolist (slot slots) (setf (slot-value mesh (first slot)) (%snapshot-value (second slot))))
              (etypecase mesh
                (sgeo.geometry:half-edge-mesh (%restore-kernel-state mesh data))
                (sgeo.geometry:triangle-mesh
                 (sgeo.geometry:set-mesh-data mesh (sgeo.geometry:render-mesh-positions data)
                                                   (sgeo.geometry:render-mesh-indices data)
                                                   (sgeo.geometry:render-mesh-normals data))))))
          (setf (sgeo.scene:world-selection world) (editor-snapshot-selection snapshot)
                (editor-elements editor) nil
                (%inspect-stack editor) nil
                (editor-inspected editor) (or (editor-snapshot-selection snapshot) (sgeo.scene:world-root world))))
        editor))))

(defun call-with-edit-transaction (editor label function &key name arguments form)
  "Agrupa operações em um passo de histórico e recupera a cena em caso de falha."
  (call-in-editor editor
    (lambda ()
      (if (plusp (%transaction-depth editor))
          (funcall function)
          (sgeo.scene:with-world-lock ((editor-world editor))
            (let ((before (capture-editor-snapshot editor)) (result nil))
              (incf (%transaction-depth editor))
              (unwind-protect
                   (restart-case
                       (handler-case
                           (progn
                             (setf result (multiple-value-list (funcall function)))
                             (let ((command (make-editor-command :name name :arguments arguments :label label :form form
                                              :before before :after (capture-editor-snapshot editor))))
                               (push command (editor-undo-stack editor))
                               (setf (editor-redo-stack editor) nil)
                               (push command (editor-history editor)))
                             (setf (editor-status editor) label)
                             (values-list result))
                         (error (condition)
                           (unless (equalp before (capture-editor-snapshot editor))
                             (restore-editor-snapshot editor before))
                           (setf (editor-status editor) (princ-to-string condition))
                           (error condition)))
                     (rollback-edit () :report "Reverter a transação para o estado anterior."
                       (restore-editor-snapshot editor before) nil))
                (decf (%transaction-depth editor)))))))))

(defmacro with-edit-transaction ((editor label) &body body)
  `(call-with-edit-transaction ,editor ,label (lambda () ,@body)))

(defun undo-edit (editor)
  "Desfaz um passo de edição sem ressuscitar identificadores obsoletos."
  (call-in-editor editor
    (lambda ()
      (let ((command (first (editor-undo-stack editor))))
        (when command
          (restore-editor-snapshot editor (command-before command))
          (pop (editor-undo-stack editor)) (push command (editor-redo-stack editor))
          (setf (editor-status editor) (format nil "Undo: ~A" (command-label command))))
        command))))

(defun redo-edit (editor)
  "Refaz um passo na mesma cena, criando gerações novas para seus elementos."
  (call-in-editor editor
    (lambda ()
      (let ((command (first (editor-redo-stack editor))))
        (when command
          (restore-editor-snapshot editor (command-after command))
          (pop (editor-redo-stack editor)) (push command (editor-undo-stack editor))
          (setf (editor-status editor) (format nil "Redo: ~A" (command-label command))))
        command))))
