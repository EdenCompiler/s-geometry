(in-package #:sgeo.examples)

(defun make-triangle-world ()
  "Cria a demonstração mínima de renderização pelo protocolo do motor."
  (let* ((world (sg:make-world :camera (sg:make-camera :eye (sg:vec3 0 0 3))))
         (mesh (sg:make-triangle-mesh
                :name "Triangle geometry"
                :positions #(-1 -0.7d0 0 1 -0.7d0 0 0 1 0)
                :indices #(0 1 2)))
         (object (sg:make-mesh-object
                  mesh :name "Triangle"
                  :material (sg:make-material :color (sg:vec3 0.95d0 0.45d0 0.2d0)))))
    (sg:add-to-world world object)
    world))
