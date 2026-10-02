(in-package #:sgeo.examples)

(defclass spinning-mesh-object (sg:mesh-object) ()
  (:documentation "Objeto de exemplo cujo comportamento pode ser redefinido ao vivo."))

;; O contrato amplo evita que o compilador congele o tipo do valor literal inicial.
(declaim (ftype (function () real) spin-rate) (notinline spin-rate))

(defun spin-rate ()
  "Retorna a velocidade angular da demonstração; pode ser redefinida pelo REPL."
  0.35d0)

(defun step-demo-motion (object world dt)
  "Atualiza a instância existente com a definição atual da velocidade."
  (declare (ignore world))
  (sg:rotate object (sg:vec3 0 (* dt (spin-rate)) 0)))

(defmethod sg:update-object ((object spinning-mesh-object) world dt)
  (step-demo-motion object world dt))

(defun make-live-world ()
  "Cria uma hierarquia com duas malhas e comportamento redefinível ao vivo."
  (let* ((world (sg:make-world :camera (sg:make-camera :eye (sg:vec3 5 3.5d0 7))))
         (group (sg:make-scene-object :name "Models"))
         (cube (make-instance
                'spinning-mesh-object :name "Cube"
                :geometry (sg:make-box :size 1.7d0 :name "Cube geometry")
                :material (sg:make-material :color (sg:vec3 0.25d0 0.65d0 0.95d0))))
         (wire (sg:make-mesh-object
                (sg:make-box :size 1.7d0 :name "Wire geometry") :name "WireCube"
                :material (sg:make-material :color (sg:vec3 0.95d0 0.7d0 0.25d0)
                                            :wireframe-p t))))
    (sg:set-position cube (sg:vec3 -1.2d0 0 0))
    (sg:set-position wire (sg:vec3 1.2d0 0 0))
    (sg:add-to-world world group)
    (sg:add-child group cube)
    (sg:add-child group wire)
    world))
