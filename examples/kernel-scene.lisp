(in-package #:sgeo.examples)

;; O contrato de tipo permite redefinir a distância sem congelar o valor compilado.
(declaim (ftype (function () real) kernel-extrude-distance)
         (notinline kernel-extrude-distance))

(defun kernel-extrude-distance ()
  "Retorna a distância da operação demonstrável no listener externo."
  0.3d0)

(defun extrude-demo-face (mesh face)
  "Aplica a definição atual do comportamento à mesma malha editável."
  (sg:extrude-face mesh face :distance (kernel-extrude-distance)))

(defun make-kernel-world ()
  "Cria uma caixa half-edge viva no viewport de M1."
  (let* ((world (sg:make-world :camera (sg:make-camera :eye '(6 5 8))))
         (geometry (sg:make-half-edge-box :size 2d0 :name "Editable geometry"))
         (object (sg:make-mesh-object geometry :name "EditableBox"
                                      :material (sg:make-material :color '(0.3d0 0.7d0 0.85d0)))))
    (sg:add-to-world world object)
    world))
