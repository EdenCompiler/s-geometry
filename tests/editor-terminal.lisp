(in-package #:sgeo.tests)

(in-suite sgeo-suite)

(test editor-terminal-evaluates-mutations-on-owner-and-quits
  (let* ((object (sg:make-scene-object :name "Terminal"))
         (world (sg:make-world :root object))
         (editor (sgeo.editor:make-editor :world world))
         (stop-flag (list nil))
         (input (make-string-input-stream
                 (format nil "(sg:set-position sg:*selection* #(2d0 3d0 4d0))~%:quit~%")))
         (output (make-string-output-stream))
         (query (make-two-way-stream input output))
         (thread nil))
    (unwind-protect
         (let ((*standard-input* input)
               (*standard-output* output)
               (*query-io* query))
           (sgeo.editor:editor-select editor object)
           (setf thread (sgeo.editor:start-editor-terminal editor stop-flag))
           (let ((deadline (+ (get-internal-real-time) (* 5 internal-time-units-per-second))))
             (loop while (bt:thread-alive-p thread)
                   do (sgeo.editor:process-editor-requests editor)
                      (when (> (get-internal-real-time) deadline)
                        (error "O terminal não encerrou após :quit."))
                      (sleep 0.001d0)))
           (is (car stop-flag))
           (is (eq world (sgeo.editor:editor-world editor)))
           (is (vector-approximately= (sgeo.math:transform-position
                                       (sg:scene-object-local-transform object))
                                      #(2d0 3d0 4d0)))
           (is (= 1 (length (sgeo.editor:editor-undo-stack editor))))
           (is (search "sgeo>" (get-output-stream-string output)))
           (sgeo.editor:undo-edit editor)
           (is (vector-approximately= (sgeo.math:transform-position
                                       (sg:scene-object-local-transform object))
                                      #(0d0 0d0 0d0))))
      (when thread (sgeo.editor:stop-editor-terminal thread stop-flag))
      (sgeo.editor:close-editor editor))))
