(defpackage #:sgeo.examples.animation
  (:use #:cl)
  (:export #:make-animation-world #:make-animation-editor #:run-animation-editor))
(in-package #:sgeo.examples.animation)

(defun make-animation-world (&key path)
  "Importa o personagem da Cesium e mantém esqueleto, clipes e malha na imagem Lisp."
  (let* ((path (or path (asdf:system-relative-pathname :sgeo "examples/assets/rigged-figure/RiggedFigure.gltf")))
         (world (sg:make-world :camera (sg:make-camera :eye #(1.9d0 1.2d0 2.8d0) :target #(0d0 0.65d0 0d0))))
         (asset (sgeo.gltf:import-gltf path :world world)))
    (values world asset)))

(defun make-animation-editor (&key path (playing-p t))
  "Prepara um editor com o clipe importado selecionado, pronto para edição ao vivo."
  (multiple-value-bind (world asset) (make-animation-world :path path)
    (let ((editor (sgeo.editor:make-editor :world world :scene-path "animation.sgeo")))
      (when (plusp (length (sgeo.gltf:gltf-clips asset)))
        (sgeo.editor:select-animation-clip editor (aref (sgeo.gltf:gltf-clips asset) 0))
        (sgeo.editor:execute-editor-command editor (if playing-p :play :pause)))
      (let ((meshes (sgeo.gltf:gltf-meshes asset)))
        (when (plusp (length meshes)) (sgeo.editor:editor-select editor (aref meshes 0))))
      (values editor asset))))

(defun run-animation-editor (&key path (width 1280) (height 800) (visible t)
                                 (repl t) max-frames capture-path frame-hook)
  "Abre a demonstração de animação na interface nativa do projeto."
  (multiple-value-bind (editor asset) (make-animation-editor :path path)
    (declare (ignore asset))
    (sgeo.editor.opengl:run-editor editor :width width :height height :visible visible
      :repl repl :max-frames max-frames :capture-path capture-path
      :frame-hook (lambda (editor window renderer frame)
                    (when (zerop frame)
                      (setf (sgeo.editor.opengl::editor-ui-workspace-tool
                             sgeo.editor.opengl::*active-ui-state*) :timeline))
                    (when frame-hook (funcall frame-hook editor window renderer frame))))))
