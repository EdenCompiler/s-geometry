(in-package #:sgeo.backend.opengl)

(defmethod sgeo.render:drain-renderer-profile ((renderer opengl-renderer) &key wait)
  "Publica consultas prontas; WAIT é usado apenas antes de destruir o contexto."
  (let ((pending nil))
    (dolist (record (%profile-queries renderer))
      (destructuring-bind (profiler frame queries targets) record
        (if (or wait (every (lambda (id) (gl:get-query-object id :query-result-available)) queries))
            (unwind-protect
                 (let ((results (mapcar (lambda (id) (gl:get-query-object id :query-result)) queries)))
                   (sgeo.diagnostics:record-gpu-sample profiler "OpenGL/frame" (first results)
                     :frame frame :subsystem :render)
                   (sgeo.diagnostics:record-pipeline-statistics profiler
                     (loop for target in (rest targets) for value in (rest results)
                           append (list target value)) :frame frame :subsystem :render :backend :opengl))
              (gl:delete-queries queries))
            (push record pending))))
    (setf (%profile-queries renderer) (nreverse pending))))

(defmethod sgeo.render:render-frame :around ((renderer opengl-renderer) world width height)
  "Cronometra comandos da GPU sem bloquear o laço enquanto consultas estão pendentes."
  (let ((profiler (sgeo.diagnostics:current-profiler)))
    (if (not (and profiler (sgeo.diagnostics:profiler-enabled-p profiler)))
        (call-next-method)
        (progn
          (sgeo.render:drain-renderer-profile renderer)
          ;; O limite impede acúmulo quando a GPU está ocupada; medição nunca força WAIT no quadro.
          (if (>= (length (%profile-queries renderer)) 8)
              (call-next-method)
              (let* ((targets (or (%profile-targets renderer)
                                  (setf (%profile-targets renderer)
                                        (append (list :time-elapsed :primitives-generated)
                                                (when (gl:extension-present-p "GL_ARB_pipeline_statistics_query")
                                                  (list :vertices-submitted :primitives-submitted
                                                        :vertex-shader-invocations))))))
                     (queries (gl:gen-queries (length targets))) (started nil))
                (unwind-protect
                     (progn
                       (loop for target in targets for id in queries
                             do (gl:begin-query target id) (push target started))
                       (call-next-method))
                  (dolist (target started) (gl:end-query target))
                  (if (= (length started) (length targets))
                      (push (list profiler (sgeo.diagnostics:current-frame profiler) queries targets)
                            (%profile-queries renderer))
                      (gl:delete-queries queries)))))))))

(defmethod sgeo.render:destroy-renderer :before ((renderer opengl-renderer))
  (sgeo.render:drain-renderer-profile renderer :wait t))
