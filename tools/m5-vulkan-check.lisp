;;;; Verifica as poses glTF e a edição da fonte através do backend Vulkan real.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/runtime/vulkan)
(asdf:load-system :sgeo/gltf)
(load (merge-pathnames "m5-acceptance-common.lisp" (uiop:pathname-directory-pathname *load-truename*)))

(handler-case
    (let* ((world (sg:make-world :camera (sg:make-camera :eye #(1.9d0 1.2d0 2.8d0) :target #(0d0 0.65d0 0d0))))
           (asset (sgeo.gltf:import-gltf (merge-pathnames "examples/assets/rigged-figure/RiggedFigure.gltf" *project-root*) :world world))
           (object (aref (sgeo.gltf:gltf-meshes asset) 0))
           (mesh (sg:mesh-object-geometry object))
           (player (sg:play-animation world (aref (sgeo.gltf:gltf-clips asset) 0)))
           (baseline nil) (animated nil) (uploads nil) (finished nil))
      (sg:add-to-world world (sg:make-directional-light :name "Sun" :direction #(-0.4d0 -1d0 -0.3d0) :intensity 4d0 :shadow-extent 2d0))
      (setf (sg:player-playing-p player) nil)
      (multiple-value-bind (returned renderer report)
          (sgeo.runtime:run-world world :backend :vulkan :width 640 :height 420 :visible nil
            :repl nil :validation t :max-frames 6
            :frame-hook
            (lambda (current window renderer frame)
              (declare (ignore current window))
              (m5-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages)) "validação Vulkan limpa")
              (case frame
                (0 (sg:seek-animation player 0d0))
                (1 (setf baseline (copy-seq (sgeo.backend.vulkan::%last-frame-pixels renderer))
                         uploads (sgeo.render:renderer-upload-count renderer))
                   (sg:seek-animation player 0.4d0))
                (2 (setf animated (copy-seq (sgeo.backend.vulkan::%last-frame-pixels renderer)))
                   (m5-check (not (equalp baseline animated)) "pose alterou imagem Vulkan")
                   (m5-check (> (sgeo.render:renderer-upload-count renderer) uploads) "cache de pose foi reenviado")
                   (let ((positions (sg:mesh-positions mesh)))
                     (dotimes (i 6)
                       (sg:set-mesh-position mesh i
                         (sg:v+ (subseq positions (* 3 i) (+ (* 3 i) 3)) #(0d0 0d0 0.15d0))))))
                (3 (m5-check (not (equalp animated (sgeo.backend.vulkan::%last-frame-pixels renderer))) "edição da fonte alterou imagem Vulkan")
                   (setf finished t)))))
        (declare (ignore returned))
        (m5-check finished "todos os passos Vulkan executados")
        (m5-check (null (sgeo.runtime:runtime-report-render-error report)) "renderização Vulkan sem erro")
        (m5-check (null (sgeo.runtime:runtime-report-platform-error report)) "janela Vulkan sem erro")
        (m5-check (null (getf (sgeo.render:renderer-info renderer) :validation-messages)) "validação após limpeza Vulkan")
        (format t "~&M5 Vulkan: ~D quadros, ~D uploads; pose, edição e validação verificados.~%"
                (sgeo.runtime:runtime-report-frames report) (sgeo.runtime:runtime-report-uploads report)))
      (uiop:quit 0))
  (error (condition) (format *error-output* "~&Falha no teste Vulkan M5: ~A~%" condition) (uiop:quit 1)))
