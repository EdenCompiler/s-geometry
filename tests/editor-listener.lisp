(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %await-editor-listener (editor &optional (timeout 5d0))
  "Atende a fila proprietária até a worker concluir, com prazo finito."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop while (sgeo.editor:listener-busy-p editor)
          do (sgeo.editor:process-editor-requests editor)
             (when (> (get-internal-real-time) deadline) (error "Listener bloqueado."))
             (sleep 0.001d0)))
  (sgeo.editor:process-editor-requests editor))

(test editor-listener-multiline-errors-and-owner-dispatch
  (let* ((object (sg:make-mesh-object (sg:make-half-edge-box) :name "Worker target"))
         (world (sg:make-world :root object))
         (editor (sgeo.editor:make-editor :world world))
         (owner (bt:current-thread))
         (mutation-thread nil))
    (sg:add-invalidation-observer object
      (lambda (object reason revision)
        (declare (ignore object reason revision))
        (setf mutation-thread (bt:current-thread))))
    (unwind-protect
         (progn
           (sgeo.editor:editor-select editor object)
           (sgeo.editor:submit-listener editor
             (format nil "(sg:set-position sg:*selection* #(2d0 3d0 4d0))~%(values :done 42)"))
           (%await-editor-listener editor)
           (is (eq owner mutation-thread))
           (is (vector-approximately= (sgeo.math:transform-position (sg:scene-object-local-transform object))
                                      #(2d0 3d0 4d0)))
           (is (= 1 (length (sgeo.editor:editor-undo-stack editor))))
           (is (some (lambda (line) (search ":DONE" line)) (sgeo.editor:editor-listener-output editor)))
           (sgeo.editor:undo-edit editor)
           (is (vector-approximately= (sgeo.math:transform-position (sg:scene-object-local-transform object))
                                      #(0d0 0d0 0d0)))
           (sgeo.editor:submit-listener editor "(error \"recoverable-listener-error\")")
           (%await-editor-listener editor)
           (is (some (lambda (line) (search "ERROR: recoverable-listener-error" line))
                     (sgeo.editor:editor-listener-output editor)))
           (sgeo.editor:submit-listener editor "(+ 20 22)")
           (%await-editor-listener editor)
           (is (search "42" (first (sgeo.editor:editor-listener-output editor))))
           (sgeo.editor:submit-listener editor "(sgeo.editor:execute-editor-command sgeo.editor:*editor* :create :name \"Created in listener\")")
           (%await-editor-listener editor)
           (is (string= "Created in listener" (sg:object-name (sg:world-selection world))))
           (sgeo.editor:submit-listener editor
             "(sgeo.editor:execute-editor-command sgeo.editor:*editor* :create :name \"Current form target\") (sg:translate sg:*selection* #(1d0 0d0 0d0))")
           (%await-editor-listener editor)
           (is (string= "Current form target" (sg:object-name (sg:world-selection world))))
           (is (approximately= 1d0 (aref (sgeo.math:transform-position
                                         (sg:scene-object-local-transform (sg:world-selection world))) 0)))
           (sgeo.editor:submit-listener editor "(setf sg:*selection* (sg:world-root sg:*world*))")
           (%await-editor-listener editor)
           (is (eq object (sg:world-selection world))))
      (sgeo.editor:close-editor editor))))

(test editor-listener-redefines-behavior-on-existing-mesh
  (let* ((mesh (sg:make-half-edge-box))
         (object (sg:make-mesh-object mesh))
         (editor (sgeo.editor:make-editor :world (sg:make-world :root object))))
    (unwind-protect
         (progn
           (sgeo.editor:editor-select editor object)
           (sgeo.editor:submit-listener editor
             "(defun cl-user::editor-test-live-operation (object) (sg:translate object #(0.1d0 0d0 0d0))) (cl-user::editor-test-live-operation sg:*selection*)")
           (%await-editor-listener editor)
           (sgeo.editor:submit-listener editor
             "(defun cl-user::editor-test-live-operation (object) (sg:translate object #(0.7d0 0d0 0d0))) (cl-user::editor-test-live-operation sg:*selection*)")
           (%await-editor-listener editor)
           (is (eq mesh (sg:mesh-object-geometry object)))
           (is (approximately= 0.8d0 (aref (sgeo.math:transform-position (sg:scene-object-local-transform object)) 0)))
           (is (= 2 (length (sgeo.editor:editor-undo-stack editor)))))
      (sgeo.editor:close-editor editor)
      (fmakunbound 'cl-user::editor-test-live-operation))))

(test editor-runtime-timeline-controls
  (let ((editor (sgeo.editor:make-editor)))
    (unwind-protect
         (progn
           (sgeo.editor:advance-editor-time editor 1d0)
           (is (= 0d0 (sgeo.editor:editor-time editor)))
           (sgeo.editor:execute-editor-command editor :step :dt 0.2d0)
           (is (approximately= 0.2d0 (sgeo.editor:editor-time editor)))
           (sgeo.editor:execute-editor-command editor :time-scale :value 2d0)
           (sgeo.editor:execute-editor-command editor :play)
           (sgeo.editor:advance-editor-time editor 0.3d0)
           (is (approximately= 0.8d0 (sgeo.editor:editor-time editor)))
           (sgeo.editor:execute-editor-command editor :pause)
           (sgeo.editor:advance-editor-time editor 5d0)
           (is (approximately= 0.8d0 (sgeo.editor:editor-time editor)))
           (signals sgeo.core:validation-error
             (sgeo.editor:execute-editor-command editor :time-scale :value 0d0))
           (signals sgeo.core:validation-error (sgeo.editor:advance-editor-time editor -1d0)))
      (sgeo.editor:close-editor editor))))
