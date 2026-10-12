(in-package #:sgeo.examples)

(sgeo.procedural:define-generator
 'advanced-scene-box nil
 (lambda (parameters dependencies)
   (declare (ignore parameters))
   (let ((size (or (gethash "size" dependencies)
                   (gethash "alternate-size" dependencies))))
     (when (> size 1.75d0)
       (error "Advanced scene box rejects sizes above 1.75."))
     (sg:make-half-edge-box :size size :name "Procedural box result"))))

(defun %advanced-offset-mesh (mesh offset)
  (sgeo.geometry:set-vertex-positions
   mesh
   (mapcar (lambda (vertex)
             (cons vertex (sg:v+ (sg:vertex-position mesh vertex) offset)))
           (sg:mesh-vertices mesh)))
  mesh)

(defun %advanced-color (r g b)
  (sg:make-material :color (sg:vec3 r g b)))

(defun %advanced-surface-controls ()
  (let ((controls (make-array '(4 4))))
    (dotimes (i 4)
      (dotimes (j 4)
        (let* ((x (- (* i 0.55d0) 0.825d0))
               (z (- (* j 0.55d0) 0.825d0))
               (y (* 0.35d0 (sin (* pi (/ i 3))) (sin (* pi (/ j 3))))))
          (setf (aref controls i j) (sg:vec3 x y z)))))
    controls))

(defun %advanced-sweep-path ()
  (sgeo.curves:make-bezier-curve
   #((0d0 -0.4d0 -0.7d0) (0.2d0 0.7d0 -0.2d0)
     (-0.2d0 0.7d0 0.35d0) (0d0 -0.4d0 0.7d0))
   :name "Sweep path"))

(defun make-advanced-world ()
  "Monta uma cena compacta para exercitar modelagem, campos, curvas e nós procedurais."
  (let* ((world (sg:make-world :camera (sg:make-camera :eye '(9d0 7d0 13d0))))
         (root (sg:make-scene-object :name "M8 Advanced Geometry"))
         (subdivision-source (sg:make-half-edge-box :size 1.35d0 :name "Subdivision source"))
         (subdivision (sgeo.advanced:subdivide-mesh subdivision-source :levels 1 :in-place t))
         (left (sg:make-half-edge-box :size 1.5d0 :name "CSG left operand"))
         (right (%advanced-offset-mesh (sg:make-half-edge-box :size 1.5d0 :name "CSG right operand")
                                       (sg:vec3 0.7d0 0.15d0 0d0)))
         (union (sgeo.advanced:csg-union left right))
         (difference (sgeo.advanced:csg-difference left right))
         (sphere (sgeo.fields:make-sphere-field :radius 0.82d0 :name "SDF sphere"))
         (sdf-box (sgeo.fields:make-box-field :size '(1.05d0 1.05d0 1.05d0) :name "SDF box"))
         (sdf (sgeo.fields:make-union-field sphere sdf-box))
         (sdf-mesh (sgeo.fields:field->mesh
                    sdf :bounds (sg:make-aabb (sg:vec3 -1.1d0 -1.1d0 -1.1d0)
                                               (sg:vec3 1.1d0 1.1d0 1.1d0))
                    :resolution 12 :name "SDF union surface"))
         (surface-controls (%advanced-surface-controls))
         (surface-definition (sgeo.curves:make-bezier-surface
                              surface-controls :name "Bezier surface definition"))
         (surface (sgeo.curves:tessellate-surface
                   surface-definition :u-segments 8 :v-segments 8
                   :name "Bezier surface mesh"))
         (sweep-path (%advanced-sweep-path))
         (sweep-profile #((0.26d0 0d0) (0.13d0 0.23d0) (-0.13d0 0.23d0)
                          (-0.26d0 0d0) (-0.13d0 -0.23d0) (0.13d0 -0.23d0)))
         (sweep (sgeo.curves:sweep-curve sweep-path sweep-profile
                                         :path-segments 12 :name "Curve sweep mesh"))
         (graph (sgeo.procedural:make-dependency-graph))
         (procedural nil)
         (subdivision-object (sg:make-mesh-object subdivision :name "Catmull-Clark subdivision"
                                                  :material (%advanced-color 0.22d0 0.62d0 0.88d0)))
         (union-object (sg:make-mesh-object union :name "CSG union"
                                            :material (%advanced-color 0.9d0 0.42d0 0.22d0)))
         (difference-object (sg:make-mesh-object difference :name "CSG difference"
                                                 :material (%advanced-color 0.8d0 0.72d0 0.25d0)))
         (sdf-object (sg:make-mesh-object sdf-mesh :name "SDF union"
                                          :material (%advanced-color 0.42d0 0.8d0 0.48d0)))
         (surface-object (sg:make-mesh-object surface :name "Bezier surface"
                                              :material (%advanced-color 0.52d0 0.48d0 0.9d0)))
         (sweep-object (sg:make-mesh-object sweep :name "Curve sweep"
                                            :material (%advanced-color 0.9d0 0.42d0 0.72d0)))
         (gpu-geometry (sg:make-half-edge-box :size 1.1d0 :name "Live GPU geometry"))
         (gpu-object (sg:make-mesh-object gpu-geometry :name "Live GPU mesh"
                                         :material (%advanced-color 0.22d0 0.82d0 0.82d0))))
    (sgeo.procedural:add-parameter-node graph :size 1d0)
    (sgeo.procedural:add-parameter-node graph :alternate-size 0.85d0)
    (sgeo.procedural:add-generator-node graph :mesh 'advanced-scene-box '(:size))
    (setf procedural (sgeo.procedural:make-procedural-object
                      graph :mesh :name "Procedural live mesh"
                      :material (%advanced-color 0.95d0 0.62d0 0.23d0)))
    (dolist (entry (list (cons subdivision-object (sg:vec3 -3d0 0d0 0d0))
                         (cons union-object (sg:vec3 -1d0 0d0 0d0))
                         (cons difference-object (sg:vec3 1d0 0d0 0d0))
                         (cons sdf-object (sg:vec3 3d0 0d0 0d0))
                         (cons surface-object (sg:vec3 -2d0 1.7d0 -2d0))
                         (cons sweep-object (sg:vec3 2d0 1.7d0 2d0))
                         (cons gpu-object (sg:vec3 0d0 1.8d0 0d0))
                         (cons procedural (sg:vec3 0d0 -1.8d0 0d0))))
      (sg:set-position (car entry) (cdr entry))
      (sg:add-child root (car entry)))
    (sg:add-to-world world root)
    (values world
            (list :subdivision subdivision :subdivision-source subdivision-source
                  :csg-union union :csg-difference difference :csg-left left :csg-right right
                  :sdf sdf :sdf-sphere sphere :sdf-box sdf-box :sdf-mesh sdf-mesh
                  :surface surface :surface-definition surface-definition
                  :surface-controls surface-controls :sweep sweep :sweep-path sweep-path
                  :sweep-profile sweep-profile
                  :gpu-geometry gpu-geometry
                  :gpu-object gpu-object :procedural procedural :graph graph))))
