(defpackage #:sgeo.examples.pbr (:use #:cl) (:export #:make-pbr-world #:run-pbr-viewer))
(in-package #:sgeo.examples.pbr)

(defun make-pbr-world ()
  "Cria polígonos editáveis, diferentes metais e um piso que recebe sombras."
  (let ((world (sg:make-world :camera (sg:make-camera :eye #(7d0 5.5d0 9d0)
                                                    :target #(0d0 0.7d0 0d0)))))
    (sg:add-to-world world (sg:make-directional-light :name "Sun" :direction #(-0.4d0 -1d0 -0.3d0)
                                                     :intensity 4d0 :shadow-extent 7d0))
    (sg:add-to-world world
      (sg:make-mesh-object (sg:make-grid :width 12d0 :depth 12d0 :columns 2 :rows 2)
                          :name "Ground" :material (sg:make-pbr-material :base-color #(0.22d0 0.25d0 0.3d0 1d0)
                                                                        :roughness 0.8d0)))
    (loop for x in '(-2.4d0 0d0 2.4d0) for roughness in '(0.12d0 0.4d0 0.8d0) do
      (sg:add-to-world world
        (sg:make-mesh-object (sg:make-sphere :radius 0.8d0 :segments 32 :rings 16)
                            :name (format nil "Copper ~,2F" roughness) :position (vector x 0.8d0 -1.2d0)
                            :material (sg:make-pbr-material :base-color #(0.95d0 0.55d0 0.28d0 1d0)
                                                          :metallic 1d0 :roughness roughness))))
    (sg:add-to-world world
      (sg:make-mesh-object (sg:make-half-edge-box :size 1.4d0) :name "EditableBox"
                          :position #(-1.7d0 0.7d0 1.5d0)
                          :material (sg:make-pbr-material :base-color #(0.12d0 0.45d0 0.8d0 1d0)
                                                        :metallic 0d0 :roughness 0.3d0)))
    (sg:add-to-world world
      (sg:make-mesh-object (sg:make-torus :major-radius 0.75d0 :minor-radius 0.25d0 :segments 32 :sides 16)
                          :name "Gold" :position #(1.5d0 1d0 1.4d0) :rotation #(0.6d0 0d0 0d0)
                          :material (sg:make-pbr-material :base-color #(1d0 0.76d0 0.34d0 1d0)
                                                        :metallic 1d0 :roughness 0.22d0)))
    world))

(defun run-pbr-viewer (&key world (width 1100) (height 720) (visible t) (repl t)
                          max-frames capture-path frame-hook validation)
  "Abre o visualizador Vulkan na thread principal, mantendo a cena acessível pelo REPL."
  (sgeo.runtime:run-world (or world (make-pbr-world)) :backend :vulkan
                          :title "S-Geometry — Shader Lisp / Vulkan"
                          :width width :height height :visible visible :repl repl
                          :max-frames max-frames :capture-path capture-path
                          :frame-hook frame-hook :validation validation))
