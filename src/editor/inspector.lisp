(in-package #:sgeo.editor)

(defparameter *inspector-item-limit* 128)
(defparameter *inspector-depth-limit* 4)

(defun %inspector-row (label value &optional editable reference)
  (list :label label :value value :editable editable :reference reference))

(defun %object-revision-row (object)
  (list (%inspector-row "Revisão" (sgeo.core:object-revision object))))

(defun %metadata-rows (object)
  (list (%inspector-row "Metadados" (sgeo.core:object-metadata object) nil
                        (sgeo.core:object-metadata object))))

(defun %transform-rows (object)
  (let ((transform (sgeo.scene:scene-object-local-transform object)))
    (list (%inspector-row "Posição" (copy-seq (sgeo.math:transform-position transform))
                          :position)
          (%inspector-row "Rotação" (sgeo.math:transform-rotation transform))
          (%inspector-row "Escala" (copy-seq (sgeo.math:transform-scale transform))
                          :scale))))

(defun %world-rows (world)
  (list (%inspector-row "Raiz" (sgeo.scene:world-root world) nil (sgeo.scene:world-root world))
        (%inspector-row "Câmera" (sgeo.scene:world-camera world) nil (sgeo.scene:world-camera world))
        (%inspector-row "Seleção" (sgeo.scene:world-selection world) nil
                        (sgeo.scene:world-selection world))))

(defun %scene-object-rows (object)
  (append
   (list (%inspector-row "Tipo" (type-of object))
         (%inspector-row "Nome" (sgeo.core:object-name object))
         (%inspector-row "Visível" (sgeo.scene:scene-object-visible-p object))
         (%inspector-row "Habilitado" (sgeo.scene:scene-object-enabled-p object))
         (%inspector-row "Pai" (sgeo.scene:scene-object-parent object) nil
                         (sgeo.scene:scene-object-parent object))
         (%inspector-row "Filhos" (sgeo.scene:scene-object-children object) nil
                         (sgeo.scene:scene-object-children object)))
   (%transform-rows object)
   (%object-revision-row object)
   (%metadata-rows object)
   (when (typep object 'sgeo.scene:mesh-object)
     (list (%inspector-row "Geometria" (sgeo.scene:mesh-object-geometry object) nil
                           (sgeo.scene:mesh-object-geometry object))
           (%inspector-row "Material" (sgeo.scene:mesh-object-material object) nil
                           (sgeo.scene:mesh-object-material object))))
   (when (typep object 'sgeo.scene:camera)
     (list (%inspector-row "Olho" (sgeo.scene:camera-eye object))
           (%inspector-row "Alvo" (sgeo.scene:camera-target object))
           (%inspector-row "Para cima" (sgeo.scene:camera-up object))
           (%inspector-row "Projeção" (sgeo.scene:camera-projection-mode object))
           (%inspector-row "Campo de visão" (sgeo.scene:camera-fov object) :fov)
           (%inspector-row "Perto" (sgeo.scene:camera-near object) :near)
           (%inspector-row "Longe" (sgeo.scene:camera-far object) :far)
           (%inspector-row "Altura ortográfica"
                           (sgeo.scene:camera-orthographic-height object)
                           :orthographic-height)))))

(defun %material-rows (material)
  (append (list (%inspector-row "Tipo" (type-of material))
                (%inspector-row "Nome" (sgeo.core:object-name material))
                (%inspector-row "Cor" (sgeo.scene:simple-material-color material) :color)
                (%inspector-row "Arame" (sgeo.scene:simple-material-wireframe-p material)))
          (%object-revision-row material)
          (%metadata-rows material)))

(defun %triangle-mesh-rows (mesh)
  (append (list (%inspector-row "Tipo" :triangle-mesh)
                (%inspector-row "Nome" (sgeo.core:object-name mesh))
                (%inspector-row "Vértices" (/ (length (sgeo.geometry:mesh-positions mesh)) 3))
                (%inspector-row "Triângulos" (/ (length (sgeo.geometry:mesh-indices mesh)) 3))
                (%inspector-row "Posições" (sgeo.geometry:mesh-positions mesh) nil
                                (sgeo.geometry:mesh-positions mesh))
                (%inspector-row "Normais" (sgeo.geometry:mesh-normals mesh) nil
                                (sgeo.geometry:mesh-normals mesh))
                (%inspector-row "Índices" (sgeo.geometry:mesh-indices mesh) nil
                                (sgeo.geometry:mesh-indices mesh)))
          (%object-revision-row mesh)
          (%metadata-rows mesh)))

(defun %half-edge-mesh-rows (mesh)
  (let ((counts (sgeo.geometry:mesh-counts mesh)))
    (append (list (%inspector-row "Tipo" :half-edge-mesh)
                  (%inspector-row "Nome" (sgeo.core:object-name mesh))
                  (%inspector-row "Contagens" counts)
                  (%inspector-row "Vértices" (sgeo.geometry:mesh-vertices mesh) nil
                                  (%element-references mesh (sgeo.geometry:mesh-vertices mesh)))
                  (%inspector-row "Arestas" (sgeo.geometry:mesh-edges mesh) nil
                                  (%element-references mesh (sgeo.geometry:mesh-edges mesh)))
                  (%inspector-row "Faces" (sgeo.geometry:mesh-faces mesh) nil
                                  (%element-references mesh (sgeo.geometry:mesh-faces mesh)))
                  (%inspector-row "Meias-arestas" (sgeo.geometry:mesh-half-edges mesh) nil
                  (%element-references mesh (sgeo.geometry:mesh-half-edges mesh))))
            (%object-revision-row mesh)
            (%metadata-rows mesh))))

(defun %element-reference (mesh handle)
  (and handle (list :element mesh handle)))

(defun %element-references (mesh handles)
  (mapcar (lambda (handle) (%element-reference mesh handle)) handles))

(defun %handle-row (label mesh handle)
  (%inspector-row label handle nil (%element-reference mesh handle)))

(defun %element-rows (mesh handle)
  (unless (sgeo.geometry:mesh-handle-p handle)
    (error 'sgeo.core:validation-error :context "inspetor"
           :message "A referência de elemento não é um handle de malha."))
  (case (sgeo.geometry:handle-kind handle)
    (:vertex
     (append (list (%inspector-row "Tipo" :vertex)
                   (%inspector-row "Posição" (sgeo.geometry:vertex-position mesh handle)
                                   :vertex-position))
             (list (%inspector-row "Vizinhos" (sgeo.geometry:vertex-neighbors mesh handle) nil
                                   (%element-references mesh (sgeo.geometry:vertex-neighbors mesh handle))))
             (list (%inspector-row "Arestas" (sgeo.geometry:vertex-edges mesh handle) nil
                                   (%element-references mesh (sgeo.geometry:vertex-edges mesh handle)))
                   (%inspector-row "Faces" (sgeo.geometry:vertex-faces mesh handle) nil
                                   (%element-references mesh (sgeo.geometry:vertex-faces mesh handle))))))
    (:face
     (append (list (%inspector-row "Tipo" :face)
                   (%inspector-row "Área" (sgeo.geometry:face-area mesh handle))
                   (%inspector-row "Normal" (sgeo.geometry:face-normal mesh handle)))
             (list (%inspector-row "Vértices" (sgeo.geometry:face-vertices mesh handle) nil
                                   (%element-references mesh (sgeo.geometry:face-vertices mesh handle)))
                   (%inspector-row "Meias-arestas" (sgeo.geometry:face-half-edges mesh handle) nil
                                   (%element-references mesh (sgeo.geometry:face-half-edges mesh handle))))))
    (:edge
     (list (%inspector-row "Tipo" :edge)
           (%inspector-row "Vértices" (sgeo.geometry:edge-vertices mesh handle) nil
                           (%element-references mesh (sgeo.geometry:edge-vertices mesh handle)))
           (%inspector-row "Meias-arestas" (sgeo.geometry:edge-half-edges mesh handle) nil
                           (%element-references mesh (sgeo.geometry:edge-half-edges mesh handle)))
           (%inspector-row "Contorno" (sgeo.geometry:boundary-edge-p mesh handle))))
    (:half-edge
     (list (%inspector-row "Tipo" :half-edge)
           (%handle-row "Origem" mesh (sgeo.geometry:half-edge-origin mesh handle))
           (%handle-row "Destino" mesh (sgeo.geometry:half-edge-destination mesh handle))
           (%handle-row "Próxima" mesh (sgeo.geometry:half-edge-next mesh handle))
           (%handle-row "Anterior" mesh (sgeo.geometry:half-edge-previous mesh handle))
           (%handle-row "Gêmea" mesh (sgeo.geometry:half-edge-twin mesh handle))
           (%handle-row "Aresta" mesh (sgeo.geometry:half-edge-edge mesh handle))
           (%handle-row "Face" mesh (sgeo.geometry:half-edge-face mesh handle))
           (%inspector-row "Contorno" (sgeo.geometry:boundary-half-edge-p mesh handle))))
    (otherwise
     (error 'sgeo.core:validation-error :context "inspetor"
            :message "Tipo de handle de malha desconhecido."))))

(defun %compound-rows (value depth)
  (when (>= depth *inspector-depth-limit*)
    (return-from %compound-rows nil))
  (cond
    ((hash-table-p value)
     (let ((entries nil) (count 0))
       (maphash (lambda (key item)
                  (when (< count *inspector-item-limit*)
                    (incf count)
                    (push (%inspector-row (princ-to-string key) item nil item) entries))) value)
       (sort entries #'string< :key (lambda (row) (getf row :label)))))
    ((and (arrayp value) (not (stringp value)))
     (loop for index below (min (array-total-size value) *inspector-item-limit*)
           collect (%inspector-row (format nil "[~D]" index) (row-major-aref value index)
                                   nil (row-major-aref value index))))
    ((consp value)
     (loop for item in value for index from 0 below *inspector-item-limit*
           collect (%inspector-row (format nil "[~D]" index) item nil item)))
    (#+sbcl (and (typep value 'standard-object)
                 (not (typep value 'sgeo.core:sgeo-object)))
     #+sbcl
     (loop for slot in (sb-mop:class-slots (class-of value))
           for name = (sb-mop:slot-definition-name slot)
           when (slot-boundp value name)
             collect (%inspector-row (string-downcase (symbol-name name))
                                     (handler-case (slot-value value name)
                                       (error () :unavailable)))))
    (t nil)))

(defun %inspect-value (value depth)
  (cond
    ((null value) (list (%inspector-row "Valor" nil)))
    ((or (stringp value) (numberp value) (symbolp value) (characterp value))
     (list (%inspector-row "Valor" value)))
    ((typep value 'sgeo.scene:world) (%world-rows value))
    ((and (consp value) (eq (first value) :element)
          (consp (rest value)) (consp (cddr value)) (null (cdddr value)))
     (%element-rows (second value) (third value)))
    ((typep value 'sgeo.scene:scene-object) (%scene-object-rows value))
    ((typep value 'sgeo.scene:simple-material) (%material-rows value))
    ((typep value 'sgeo.geometry:triangle-mesh) (%triangle-mesh-rows value))
    ((typep value 'sgeo.geometry:half-edge-mesh) (%half-edge-mesh-rows value))
    ((typep value 'sgeo.math:transform)
     (list (%inspector-row "Posição" (sgeo.math:transform-position value))
           (%inspector-row "Rotação" (sgeo.math:transform-rotation value))
           (%inspector-row "Escala" (sgeo.math:transform-scale value))) )
    ((typep value 'sgeo.math:quaternion)
     (list (%inspector-row "x" (aref (sgeo.math::quaternion-data value) 0))
           (%inspector-row "y" (aref (sgeo.math::quaternion-data value) 1))
           (%inspector-row "z" (aref (sgeo.math::quaternion-data value) 2))
           (%inspector-row "w" (aref (sgeo.math::quaternion-data value) 3))))
    ((sgeo.geometry:mesh-handle-p value)
     (list (%inspector-row "Tipo" (sgeo.geometry:handle-kind value))
           (%inspector-row "Índice" (sgeo.geometry:handle-index value))
           (%inspector-row "Geração" (sgeo.geometry:handle-generation value))
           (%inspector-row "Malha" (sgeo.geometry:handle-mesh-id value))))
    ((or (hash-table-p value) (arrayp value) (consp value)
         #+sbcl (typep value 'standard-object))
     (%compound-rows value depth))
    (t nil)))

(defun inspect-value (value)
  "Projeta um valor em linhas navegáveis sem expor operações de escrita direta."
  (%inspect-value value 0))

(defun inspect-editor (editor value)
  "Define o valor inspecionado e guarda a navegação anterior."
  (call-in-editor editor
    (lambda ()
      (when (editor-inspected editor)
        (push (editor-inspected editor) (%inspect-stack editor)))
      (setf (editor-inspected editor) value)
      (inspect-value value))))

(defun inspect-back (editor)
  "Retorna ao último valor visitado no inspetor."
  (call-in-editor editor
    (lambda ()
      (when (%inspect-stack editor)
        (setf (editor-inspected editor) (pop (%inspect-stack editor))))
      (inspect-value (editor-inspected editor)))))

(defun %inspector-selected-object (editor object-override)
  (or object-override
      (let ((inspected (editor-inspected editor)))
        (cond ((and (consp inspected) (eq (first inspected) :element)) (second inspected))
              ((typep inspected 'sgeo.scene:scene-object) inspected)
              ((typep inspected 'sgeo.scene:simple-material) inspected)
              (t (sgeo.scene:world-selection (editor-world editor)))))))

(defun %replace-component (vector axis value context)
  (unless (and (integerp axis) (<= 0 axis 2))
    (error 'sgeo.core:validation-error :context context
           :message "O eixo precisa ser 0, 1 ou 2."))
  (unless (and (realp value)
               (handler-case (let ((v (coerce value 'double-float)))
                               (and (= v v) (< (abs v) most-positive-double-float)))
                 (error () nil)))
    (error 'sgeo.core:validation-error :context context
           :message "O valor precisa ser um número real finito."))
  (let ((copy (copy-seq vector)))
    (setf (aref copy axis) (coerce value 'double-float))
    copy))

(defun set-inspector-number (editor field value &key (axis 0) object)
  "Edita um campo numérico por meio do executor transacional do editor."
  (call-in-editor editor
    (lambda ()
      (let* ((target (%inspector-selected-object editor object))
             (inspected (editor-inspected editor)))
        (case field
          (:position
           (unless (typep target 'sgeo.scene:scene-object)
             (error 'sgeo.core:validation-error :context "inspetor" :message "Selecione um objeto de cena."))
           (let ((current (sgeo.math:transform-position
                           (sgeo.scene:scene-object-local-transform target))))
             (execute-editor-command editor :position :object target
                                     :value (%replace-component current axis value "posição"))))
          (:scale
           (unless (typep target 'sgeo.scene:scene-object)
             (error 'sgeo.core:validation-error :context "inspetor" :message "Selecione um objeto de cena."))
           (let ((current (sgeo.math:transform-scale
                           (sgeo.scene:scene-object-local-transform target))))
             (execute-editor-command editor :scale :object target
                                     :value (%replace-component current axis value "escala"))))
          (:vertex-position
           (unless (and (consp inspected) (eq (first inspected) :element)
                        (sgeo.geometry:mesh-handle-p (third inspected))
                        (eq (sgeo.geometry:handle-kind (third inspected)) :vertex))
             (error 'sgeo.core:validation-error :context "inspetor" :message "Selecione um vértice da malha."))
           (let* ((mesh (second inspected)) (handle (third inspected))
                  (current (sgeo.geometry:vertex-position mesh handle))
                  (owner (find mesh (editor-objects editor)
                               :key (lambda (candidate)
                                      (and (typep candidate 'sgeo.scene:mesh-object)
                                           (sgeo.scene:mesh-object-geometry candidate)))
                               :test #'eq)))
             (unless owner
               (error 'sgeo.core:validation-error :context "inspetor"
                      :message "A malha do vértice não pertence à cena atual."))
             (execute-editor-command editor :move-vertex :object owner
                                     :index (sgeo.geometry:handle-index handle)
                                     :position (%replace-component current axis value "posição de vértice"))))
          (:color
           (let* ((owner (cond ((typep target 'sgeo.scene:mesh-object) target)
                               ((typep target 'sgeo.scene:simple-material)
                                (find target (editor-objects editor)
                                      :key (lambda (candidate)
                                             (and (typep candidate 'sgeo.scene:mesh-object)
                                                  (sgeo.scene:mesh-object-material candidate)))
                                      :test #'eq))))
                  (material (and owner (sgeo.scene:mesh-object-material owner))))
             (unless material
               (error 'sgeo.core:validation-error :context "inspetor" :message "Selecione um material ou objeto de malha."))
             (execute-editor-command editor :material :object owner
                                     :color (%replace-component
                                             (sgeo.scene:simple-material-color material)
                                             axis value "cor do material"))))
          ((:fov :near :far :orthographic-height
            :camera-fov :camera-near :camera-far :camera-orthographic-height)
           (let ((name (ecase field
                         (:fov :fov) (:camera-fov :fov)
                         (:near :near) (:camera-near :near)
                         (:far :far) (:camera-far :far)
                         (:orthographic-height :orthographic-height)
                         (:camera-orthographic-height :orthographic-height))))
             (execute-editor-command editor :camera
                                     :object (sgeo.scene:world-root (editor-world editor))
                                     :field name :value value)))
          (otherwise
           (error 'sgeo.core:validation-error :context "inspetor"
                  :message (format nil "Campo numérico não editável: ~S." field))))
        (inspect-value (editor-inspected editor))))))
