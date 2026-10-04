(in-package #:sgeo.backend.vulkan)

(defstruct (gpu-mesh (:constructor %make-gpu-mesh))
  geometry revision vertex-buffer index-buffer index-count)

(defclass vulkan-renderer (sgeo.render:renderer)
  ((context :initarg :context :reader %renderer-context)
   (scene-window :initarg :window :initform nil :reader %renderer-window)
   (geometry-cache :initform (make-hash-table :test #'eq) :reader %geometry-cache)
   (pipelines :initform nil :accessor %pipelines)
   (descriptor-pool :initform nil :accessor %descriptor-pool)
   (readback-buffer :initform nil :accessor %readback-buffer)
   (descriptor-layout :initform nil :accessor %descriptor-layout)
   (pipeline-layout :initform nil :accessor %pipeline-layout)
   (shadow-pass :initform nil :accessor %shadow-pass)
   (pbr-pass :initform nil :accessor %pbr-pass)
   (tone-pass :initform nil :accessor %tone-pass)
   (shadow-image :initform nil :accessor %shadow-image)
   (hdr-image :initform nil :accessor %hdr-image)
   (depth-image :initform nil :accessor %depth-image)
   (output-image :initform nil :accessor %output-image)
   (shadow-framebuffer :initform nil :accessor %shadow-framebuffer)
   (pbr-framebuffer :initform nil :accessor %pbr-framebuffer)
   (tone-framebuffers :initform nil :accessor %tone-framebuffers)
   (shadow-sampler :initform nil :accessor %shadow-sampler)
   (hdr-sampler :initform nil :accessor %hdr-sampler)
   (pbr-program :initform nil :accessor %pbr-program)
   (shadow-program :initform nil :accessor %shadow-program)
   (tone-program :initform nil :accessor %tone-program)
   (fullscreen-buffer :initform nil :accessor %fullscreen-buffer)
   (extent-width :initform 0 :accessor %extent-width)
   (extent-height :initform 0 :accessor %extent-height)
   (shadow-size :initarg :shadow-size :initform 1024 :reader %shadow-size)
   (image-available :initform nil :accessor %image-available)
   (present-ready :initform nil :accessor %present-ready)
   (presentation-format :initform nil :accessor %presentation-format)
   (presentation-image :initform nil :accessor %presentation-image)
   (presentation-image-layout :initform :undefined :accessor %presentation-image-layout)
   (image-layouts :initform (make-hash-table :test #'eq) :reader %image-layouts)
   (image-states :initform (make-hash-table :test #'eq) :reader %image-states)
   (last-frame-pixels :initform nil :accessor %last-frame-pixels)
   (device-name :initform nil :accessor %renderer-device-name)
   (validation-enabled :initform nil :accessor %renderer-validation-enabled)
   (acquire-wait-pending-p :initform nil :accessor %acquire-wait-pending-p)
   (needs-recovery-p :initform nil :accessor %needs-recovery-p)
   (closed-p :initform nil :accessor %renderer-closed-p)))

(defun %float-vector-octets (values)
  (let ((octets (make-array (* 4 (length values))
                            :element-type '(unsigned-byte 8))))
    (cffi:with-pointer-to-vector-data (source values)
      (dotimes (index (length octets) octets)
        (setf (aref octets index) (cffi:mem-aref source :uint8 index))))))

(defun %single-float-vector (&rest values)
  (make-array (length values) :element-type 'single-float
              :initial-contents (mapcar (lambda (value) (coerce value 'single-float)) values)))

(defun %u32-vector-octets (values)
  (let ((words (map '(vector (unsigned-byte 32))
                    (lambda (value) (logand value #xffffffff)) values)))
    (cffi:with-pointer-to-vector-data (source words)
      (let ((octets (make-array (* 4 (length words))
                                :element-type '(unsigned-byte 8))))
        (dotimes (index (length octets) octets)
          (setf (aref octets index) (cffi:mem-aref source :uint8 index)))))))

(defun %make-color-attachment (format final-layout)
  (vk:make-attachment-description
   :format format :samples :1 :load-op :clear :store-op :store
   :stencil-load-op :dont-care :stencil-store-op :dont-care
   :initial-layout :color-attachment-optimal :final-layout final-layout))

(defun %make-depth-attachment (format final-layout)
  (vk:make-attachment-description
   :format format :samples :1 :load-op :clear :store-op :store
   :stencil-load-op :dont-care :stencil-store-op :dont-care
   :initial-layout :depth-stencil-attachment-optimal :final-layout final-layout))

(defun %make-color-pass (context format final-layout)
  (vk:create-render-pass
   (context-device context)
   (vk:make-render-pass-create-info
    :attachments (list (%make-color-attachment format final-layout))
    :subpasses (list (vk:make-subpass-description
                      :pipeline-bind-point :graphics
                      :color-attachments
                      (list (vk:make-attachment-reference
                             :attachment 0 :layout :color-attachment-optimal))))
    :dependencies
    (list (vk:make-subpass-dependency
           :src-subpass #xffffffff :dst-subpass 0
           :src-stage-mask '(:color-attachment-output)
           :dst-stage-mask '(:color-attachment-output)
           :src-access-mask nil :dst-access-mask '(:color-attachment-write)
           :dependency-flags '(:by-region))
          (vk:make-subpass-dependency
           :src-subpass 0 :dst-subpass #xffffffff
           :src-stage-mask '(:color-attachment-output)
           :dst-stage-mask '(:transfer)
           :src-access-mask '(:color-attachment-write)
           :dst-access-mask '(:transfer-read)
           :dependency-flags '(:by-region))))))

(defun %make-depth-pass (context format final-layout)
  (vk:create-render-pass
   (context-device context)
   (vk:make-render-pass-create-info
    :attachments (list (%make-depth-attachment format final-layout))
    :subpasses (list (vk:make-subpass-description
                      :pipeline-bind-point :graphics
                      :depth-stencil-attachment
                      (vk:make-attachment-reference
                       :attachment 0 :layout :depth-stencil-attachment-optimal)))
    :dependencies
    (list (vk:make-subpass-dependency
           :src-subpass #xffffffff :dst-subpass 0
           :src-stage-mask '(:fragment-shader :early-fragment-tests)
           :dst-stage-mask '(:early-fragment-tests :late-fragment-tests)
           :src-access-mask '(:shader-read)
           :dst-access-mask '(:depth-stencil-attachment-write)
           :dependency-flags '(:by-region))
          (vk:make-subpass-dependency
           :src-subpass 0 :dst-subpass #xffffffff
           :src-stage-mask '(:late-fragment-tests)
           :dst-stage-mask '(:fragment-shader)
           :src-access-mask '(:depth-stencil-attachment-write)
           :dst-access-mask '(:shader-read)
           :dependency-flags '(:by-region))))))

(defun %make-color-depth-pass (context color-format depth-format)
  (vk:create-render-pass
   (context-device context)
   (vk:make-render-pass-create-info
    :attachments (list (%make-color-attachment color-format :shader-read-only-optimal)
                       (%make-depth-attachment depth-format :depth-stencil-attachment-optimal))
    :subpasses (list (vk:make-subpass-description
                      :pipeline-bind-point :graphics
                      :color-attachments
                      (list (vk:make-attachment-reference
                             :attachment 0 :layout :color-attachment-optimal))
                      :depth-stencil-attachment
                      (vk:make-attachment-reference
                       :attachment 1 :layout :depth-stencil-attachment-optimal)))
    :dependencies
    (list (vk:make-subpass-dependency
           :src-subpass #xffffffff :dst-subpass 0
           :src-stage-mask '(:fragment-shader)
           :dst-stage-mask '(:color-attachment-output :early-fragment-tests)
           :src-access-mask '(:shader-read)
           :dst-access-mask '(:color-attachment-write :depth-stencil-attachment-write)
           :dependency-flags '(:by-region))
          (vk:make-subpass-dependency
           :src-subpass 0 :dst-subpass #xffffffff
           :src-stage-mask '(:color-attachment-output)
           :dst-stage-mask '(:fragment-shader)
           :src-access-mask '(:color-attachment-write)
           :dst-access-mask '(:shader-read)
           :dependency-flags '(:by-region))))))

(defun %framebuffer (context pass views width height)
  (vk:create-framebuffer
   (context-device context)
   (vk:make-framebuffer-create-info :render-pass pass :attachments views
                                    :width width :height height :layers 1)))

(defun %destroy-framebuffers (renderer)
  (let ((device (context-device (%renderer-context renderer))))
    (when (%shadow-framebuffer renderer)
      (vk:destroy-framebuffer device (%shadow-framebuffer renderer))
      (setf (%shadow-framebuffer renderer) nil))
    (when (%pbr-framebuffer renderer)
      (vk:destroy-framebuffer device (%pbr-framebuffer renderer))
      (setf (%pbr-framebuffer renderer) nil))
    (dolist (framebuffer (%tone-framebuffers renderer))
      (vk:destroy-framebuffer device framebuffer))
    (setf (%tone-framebuffers renderer) nil)))

(defun %destroy-render-programs (renderer)
  (dolist (slot '(pbr-program shadow-program tone-program))
    (let ((program (slot-value renderer slot)))
      (when program (sgeo.render:destroy-shader-program program))
      (setf (slot-value renderer slot) nil)))
  (setf (%pipelines renderer) nil))

(defun %destroy-targets (renderer)
  (%destroy-framebuffers renderer)
  (dolist (image (list (%shadow-image renderer) (%hdr-image renderer)
                       (%depth-image renderer) (%output-image renderer)))
    (when image (destroy-image image)))
  (setf (%shadow-image renderer) nil (%hdr-image renderer) nil
        (%depth-image renderer) nil (%output-image renderer) nil))

(defun %ensure-render-targets (renderer width height)
  "Substitui os alvos somente após construir todos os recursos novos."
  (unless (and (plusp width) (plusp height))
    (error "O tamanho dos alvos Vulkan deve ser positivo."))
  (unless (and (= width (%extent-width renderer))
               (= height (%extent-height renderer)) (%shadow-image renderer))
    (let* ((context (%renderer-context renderer))
           (candidate (make-instance 'vulkan-renderer :context context
                                     :shadow-size (%shadow-size renderer))))
      ;; Os passes e pipelines independem do tamanho; recargas continuam pendentes.
      (unless (%shadow-pass renderer)
        (setf (%shadow-pass renderer)
              (%make-depth-pass context :d32-sfloat :depth-stencil-read-only-optimal)))
      (unless (%pbr-pass renderer)
        (setf (%pbr-pass renderer)
              (%make-color-depth-pass context :r16g16b16a16-sfloat :d32-sfloat)))
      (unless (%tone-pass renderer)
        (setf (%tone-pass renderer)
              (%make-color-pass context :r8g8b8a8-unorm :transfer-src-optimal)))
      (unwind-protect
           (progn
             (setf (%shadow-image candidate)
                   (make-image context (%shadow-size renderer) (%shadow-size renderer)
                               :d32-sfloat '(:depth-stencil-attachment :sampled)
                               '(:device-local) :aspect '(:depth))
                   (%hdr-image candidate)
                   (make-image context width height :r16g16b16a16-sfloat
                               '(:color-attachment :sampled) '(:device-local))
                   (%depth-image candidate)
                   (make-image context width height :d32-sfloat
                               '(:depth-stencil-attachment) '(:device-local) :aspect '(:depth))
                   (%output-image candidate)
                   (make-image context width height :r8g8b8a8-unorm
                               '(:color-attachment :transfer-src) '(:device-local))
                   (%shadow-framebuffer candidate)
                   (%framebuffer context (%shadow-pass renderer)
                                 (list (image-view (%shadow-image candidate)))
                                 (%shadow-size renderer) (%shadow-size renderer))
                   (%pbr-framebuffer candidate)
                   (%framebuffer context (%pbr-pass renderer)
                                 (list (image-view (%hdr-image candidate))
                                       (image-view (%depth-image candidate))) width height)
                   (%tone-framebuffers candidate)
                   (list (%framebuffer context (%tone-pass renderer)
                                       (list (image-view (%output-image candidate))) width height))
                   (%readback-buffer candidate)
                   (make-buffer context (* width height 4) '(:transfer-dst)
                                '(:host-visible :host-coherent)))
             (vk:device-wait-idle (context-device context))
             (dolist (slot '(shadow-image hdr-image depth-image output-image
                            shadow-framebuffer pbr-framebuffer tone-framebuffers readback-buffer))
               (rotatef (slot-value renderer slot) (slot-value candidate slot)))
             (setf (%extent-width renderer) width (%extent-height renderer) height)
             (clrhash (%image-layouts renderer))
             (clrhash (%image-states renderer)))
        (%destroy-targets candidate)
        (when (%readback-buffer candidate) (destroy-buffer (%readback-buffer candidate))))))
  renderer)

(defun %make-descriptor-layout (device)
  (vk:create-descriptor-set-layout
   device
   (vk:make-descriptor-set-layout-create-info
    :bindings (list
               (vk:make-descriptor-set-layout-binding
                :binding 0 :descriptor-type :uniform-buffer :descriptor-count 1
                :stage-flags '(:vertex :fragment))
               (vk:make-descriptor-set-layout-binding
                :binding 1 :descriptor-type :combined-image-sampler :descriptor-count 1
                :stage-flags '(:fragment))))))

(defun %pipeline (renderer pass vertex-binary fragment-binary vertex-entry fragment-entry kind width height)
  (let* ((context (%renderer-context renderer)) (device (context-device context))
         (vertex nil) (fragment nil))
    (unwind-protect
         (progn
           (setf vertex (make-shader-module context vertex-binary)
                 fragment (and fragment-binary (make-shader-module context fragment-binary)))
           (let* ((layout (%pipeline-layout renderer))
                   (stages (append (list (vk:make-pipeline-shader-stage-create-info
                                          :stage :vertex :module (shader-module-handle vertex) :name vertex-entry))
                                      (when fragment
                                        (list (vk:make-pipeline-shader-stage-create-info
                                               :stage :fragment :module (shader-module-handle fragment)
                                               :name fragment-entry)))))
                   (tone (eq kind :tone))
                   (vertex-input
                     (vk:make-pipeline-vertex-input-state-create-info
                      :vertex-binding-descriptions
                      (list (vk:make-vertex-input-binding-description
                             :binding 0 :stride (if tone 8 24) :input-rate :vertex))
                      :vertex-attribute-descriptions
                      (cond (tone (list (vk:make-vertex-input-attribute-description
                                         :location 0 :binding 0 :format :r32g32-sfloat :offset 0)))
                            ((eq kind :shadow) (list (vk:make-vertex-input-attribute-description
                                                      :location 0 :binding 0 :format :r32g32b32-sfloat
                                                      :offset 0)))
                            (t (list (vk:make-vertex-input-attribute-description
                                      :location 0 :binding 0 :format :r32g32b32-sfloat :offset 0)
                                     (vk:make-vertex-input-attribute-description
                                      :location 1 :binding 0 :format :r32g32b32-sfloat :offset 12))))))
                   (color-count (if (eq kind :shadow) 0 1))
                   (info
                     (vk:make-graphics-pipeline-create-info
                      :stages stages :vertex-input-state vertex-input
                      :input-assembly-state (vk:make-pipeline-input-assembly-state-create-info
                                             :topology :triangle-list)
                      :viewport-state
                      (vk:make-pipeline-viewport-state-create-info
                       :viewports (list (vk:make-viewport :x 0.0f0 :y 0.0f0
                                                           :width (float width 1.0f0)
                                                           :height (float height 1.0f0)
                                                           :min-depth 0.0f0 :max-depth 1.0f0))
                       :scissors (list (vk:make-rect-2d
                                        :offset (vk:make-offset-2d :x 0 :y 0)
                                        :extent (vk:make-extent-2d :width width :height height))))
                      :rasterization-state (vk:make-pipeline-rasterization-state-create-info
                                            :polygon-mode :fill :cull-mode nil :front-face :counter-clockwise
                                            :line-width 1.0 :depth-bias-enable (eq kind :shadow)
                                            :depth-bias-constant-factor 1.25 :depth-bias-slope-factor 1.75)
                      :multisample-state (vk:make-pipeline-multisample-state-create-info
                                          :rasterization-samples :1)
                      :depth-stencil-state (vk:make-pipeline-depth-stencil-state-create-info
                                            :depth-test-enable (not tone) :depth-write-enable (not tone)
                                            :depth-compare-op :less :min-depth-bounds 0.0f0
                                            :max-depth-bounds 1.0f0
                                            :front (vk:make-stencil-op-state
                                                    :fail-op :keep :pass-op :keep
                                                    :depth-fail-op :keep :compare-op :always)
                                            :back (vk:make-stencil-op-state
                                                   :fail-op :keep :pass-op :keep
                                                   :depth-fail-op :keep :compare-op :always))
                      :color-blend-state (vk:make-pipeline-color-blend-state-create-info
                                          :logic-op-enable nil :logic-op :copy
                                          :blend-constants (%single-float-vector 0 0 0 0)
                                          :attachments (when (plusp color-count)
                                                         (list (vk:make-pipeline-color-blend-attachment-state
                                                                :blend-enable nil
                                                                :src-color-blend-factor :one
                                                                :dst-color-blend-factor :zero
                                                                :color-blend-op :add
                                                                :src-alpha-blend-factor :one
                                                                :dst-alpha-blend-factor :zero
                                                                :alpha-blend-op :add
                                                                :color-write-mask '(:r :g :b :a)))))
                      :dynamic-state (vk:make-pipeline-dynamic-state-create-info
                                      :dynamic-states '(:viewport :scissor))
                      :layout layout :render-pass pass :subpass 0
                      :base-pipeline-handle nil :base-pipeline-index -1)))
             (first (vk:create-graphics-pipelines device (list info)))))
      (when vertex (destroy-shader-module vertex))
      (when fragment (destroy-shader-module fragment)))))

(defun %compile-program (kind)
  (sgeo.render:compile-graphics-program (sgeo.render:standard-shader-sources kind)))

(defun %validate-program-layout (compiled kind)
  (let* ((vertex-meta (getf compiled :vertex-metadata))
         (expected-inputs
           (cond ((eq kind :shadow)
                  '((0 . (:vector :float 3))))
                 ((eq kind :pbr)
                  '((0 . (:vector :float 3)) (1 . (:vector :float 3))))
                 ((eq kind :tone)
                  '((0 . (:vector :float 2))))
                 (t nil))))
    (unless (eq (getf vertex-meta :stage) :vertex)
      (error "O programa ~S exige um shader de vértices." kind))
    (let ((fragment-meta (getf compiled :fragment-metadata)))
      (when (and (member kind '(:pbr :tone))
                 (not (and (eq (getf fragment-meta :stage) :fragment)
                           (find-if (lambda (interface)
                                      (and (eq (getf interface :storage) :output)
                                           (eql (getf interface :location) 0)
                                           (equal (getf interface :type) '(:vector :float 4))))
                                    (getf fragment-meta :interfaces)))))
        (error "O programa ~S exige um shader de fragmentos com saída vec4 na localização 0." kind))
      (when (and (eq kind :shadow) fragment-meta)
        (error "O passe de sombras usa somente o shader de vértices.")))
    (dolist (metadata (list vertex-meta (getf compiled :fragment-metadata)))
      (dolist (interface (getf metadata :interfaces))
        (when (eq (getf interface :storage) :uniform)
          (let ((set (getf interface :set))
                (binding (getf interface :binding))
                (storage (getf interface :spirv-storage))
                (type (getf interface :type)))
            (unless (or (and (eql set 0) (eql binding 0)
                             (eq storage :uniform) (consp type)
                             (eq (first type) :struct)
                             (equal (mapcar #'second (third type))
                                    (append (make-list 4 :initial-element '(:matrix 4 4))
                                            (make-list 8 :initial-element '(:vector :float 4)))))
                        (and (eql set 0) (eql binding 1)
                             (eq storage :uniform-constant) (consp type)
                             (equal type '(:sampled-image (:image :2d :float))))
              (error "Shader ~S tem descritor incompatível set ~S/binding ~S (~S, ~S)."
                     (getf metadata :name) set binding storage type)))))
        (when (and (eq (getf interface :storage) :input)
                   (eq (getf metadata :stage) :vertex))
          (let* ((location (getf interface :location))
                 (expected (assoc location expected-inputs :test #'eql)))
            (unless (and expected (equal (getf interface :type) (cdr expected)))
              (error "Shader ~S tem entrada de vértice não suportada na localização ~S: ~S."
                     (getf metadata :name) location (getf interface :type)))))))
    compiled))

(defun %build-pipelines (renderer)
  (let ((device (context-device (%renderer-context renderer))))
    (unless (%descriptor-layout renderer)
      (setf (%descriptor-layout renderer) (%make-descriptor-layout device)))
    (unless (%pipeline-layout renderer)
      (setf (%pipeline-layout renderer)
            (vk:create-pipeline-layout
             device (vk:make-pipeline-layout-create-info
                     :set-layouts (list (%descriptor-layout renderer))))))
    (flet ((make-program (kind)
             (sgeo.render:make-shader-program
              kind #'sgeo.render:compile-graphics-program
              (lambda (compiled)
                (%validate-program-layout compiled kind)
                (%pipeline renderer
                           (ecase kind (:shadow (%shadow-pass renderer))
                             (:pbr (%pbr-pass renderer)) (:tone (%tone-pass renderer)))
                           (getf compiled :vertex) (getf compiled :fragment)
                           (princ-to-string (getf (getf compiled :vertex-metadata) :entry-point))
                           (and (getf compiled :fragment-metadata)
                                (princ-to-string (getf (getf compiled :fragment-metadata) :entry-point)))
                           kind (%extent-width renderer) (%extent-height renderer)))
              (lambda (pipeline) (vk:destroy-pipeline device pipeline))
              (sgeo.render:standard-shader-sources kind))))
      (setf (%shadow-program renderer) (make-program :shadow)
            (%pbr-program renderer) (make-program :pbr)
            (%tone-program renderer) (make-program :tone)))))

(defun %entry-object (entry) (getf entry :object))
(defun %gpu-mesh-for-entry (renderer entry)
  (let* ((object (%entry-object entry)) (revision (getf entry :revision))
         (geometry (getf entry :geometry))
         (cache (%geometry-cache renderer)) (cached (gethash object cache)))
    (if (and cached (eq geometry (gpu-mesh-geometry cached))
             (eql revision (gpu-mesh-revision cached))) cached
        (let* ((vertices (sgeo.render:interleave-render-mesh entry))
               (indices (getf entry :indices)) (vb nil) (ib nil))
          (unwind-protect
               (progn
                 (setf vb (make-buffer (%renderer-context renderer) (* 4 (length vertices))
                                       '(:vertex-buffer) '(:host-visible :host-coherent)
                                       :initial-data (%float-vector-octets vertices))
                       ib (make-buffer (%renderer-context renderer) (* 4 (length indices))
                                       '(:index-buffer) '(:host-visible :host-coherent)
                                       :initial-data (%u32-vector-octets indices)))
                 (let ((mesh (%make-gpu-mesh :geometry geometry :revision revision :vertex-buffer vb
                                             :index-buffer ib :index-count (length indices))))
                   (when cached
                     (destroy-buffer (gpu-mesh-vertex-buffer cached))
                     (destroy-buffer (gpu-mesh-index-buffer cached)))
                   (setf (gethash object cache) mesh vb nil ib nil)
                   (incf (sgeo.render:renderer-upload-count renderer))
                   mesh))
            (when vb (destroy-buffer vb))
            (when ib (destroy-buffer ib)))))))

(defun %make-descriptors (renderer snapshot objects)
  "Constrói descritores do quadro e libera qualquer construção incompleta."
  (let* ((context (%renderer-context renderer)) (device (context-device context))
         (count (1+ (length objects))) (sets nil) (uniforms nil) (complete nil))
    (unwind-protect
         (progn
           (setf (%descriptor-pool renderer)
                 (vk:create-descriptor-pool
                  device (vk:make-descriptor-pool-create-info
                          :max-sets count
                          :pool-sizes (list (vk:make-descriptor-pool-size
                                             :type :uniform-buffer :descriptor-count count)
                                            (vk:make-descriptor-pool-size
                                             :type :combined-image-sampler :descriptor-count count))))
                 sets (vk:allocate-descriptor-sets
                       device (vk:make-descriptor-set-allocate-info
                               :descriptor-pool (%descriptor-pool renderer)
                               :set-layouts (make-list count :initial-element (%descriptor-layout renderer)))))
           (labels ((write-set (descriptor entry sampler image layout)
                      (let ((buffer (make-buffer context 384 '(:uniform-buffer)
                                                 '(:host-visible :host-coherent)
                                                 :initial-data (%float-vector-octets
                                                                (sgeo.render:pack-frame-uniforms snapshot entry)))))
                        (push buffer uniforms)
                        (vk:update-descriptor-sets
                         device
                         (list (vk:make-write-descriptor-set
                                :dst-set descriptor :dst-binding 0 :descriptor-type :uniform-buffer
                                :buffer-info (list (vk:make-descriptor-buffer-info
                                                    :buffer (buffer-handle buffer) :offset 0 :range 384)))
                               (vk:make-write-descriptor-set
                                :dst-set descriptor :dst-binding 1 :descriptor-type :combined-image-sampler
                                :image-info (list (vk:make-descriptor-image-info
                                                   :sampler (sampler-handle sampler)
                                                   :image-view (image-view image)
                                                   :image-layout layout)))) nil))))
             (loop for entry in objects for descriptor in sets
                   do (write-set descriptor entry (%shadow-sampler renderer)
                                 (%shadow-image renderer) :depth-stencil-read-only-optimal))
             (write-set (car (last sets)) nil (%hdr-sampler renderer)
                        (%hdr-image renderer) :shader-read-only-optimal))
           (setf complete t)
           (values sets (car (last sets)) uniforms))
      (unless complete
        (dolist (buffer uniforms) (destroy-buffer buffer))
        (when (%descriptor-pool renderer)
          (vk:destroy-descriptor-pool device (%descriptor-pool renderer))
          (setf (%descriptor-pool renderer) nil))))))

(defun %begin-pass (command pass framebuffer width height clear-values)
  (vk:cmd-begin-render-pass
   command (vk:make-render-pass-begin-info
            :render-pass pass :framebuffer framebuffer
            :render-area (vk:make-rect-2d :offset (vk:make-offset-2d :x 0 :y 0)
                                          :extent (vk:make-extent-2d :width width :height height))
            :clear-values clear-values)
   :inline)
  (vk:cmd-set-viewport command 0
                       (list (vk:make-viewport :x 0.0f0 :y 0.0f0
                                               :width (float width 1.0f0)
                                               :height (float height 1.0f0)
                                               :min-depth 0.0f0 :max-depth 1.0f0)))
  (vk:cmd-set-scissor command 0
                      (list (vk:make-rect-2d :offset (vk:make-offset-2d :x 0 :y 0)
                                             :extent (vk:make-extent-2d :width width :height height)))))

(defun %draw-entries (renderer command pipeline descriptor-sets entries)
  (vk:cmd-bind-pipeline command :graphics pipeline)
  (loop for entry in entries for descriptor in descriptor-sets do
    (let ((mesh (%gpu-mesh-for-entry renderer entry)))
      (vk:cmd-bind-descriptor-sets command :graphics (%pipeline-layout renderer) 0
                                   (list descriptor) nil)
      (vk:cmd-bind-vertex-buffers command 0 (list (buffer-handle (gpu-mesh-vertex-buffer mesh)))
                                  (list 0))
      (vk:cmd-bind-index-buffer command (buffer-handle (gpu-mesh-index-buffer mesh)) 0 :uint32)
      (vk:cmd-draw-indexed command (gpu-mesh-index-count mesh) 1 0 0 0))))

(defun %draw-fullscreen (renderer command descriptor)
  (vk:cmd-bind-pipeline command :graphics (third (%pipelines renderer)))
  (vk:cmd-bind-descriptor-sets command :graphics (%pipeline-layout renderer) 0
                               (list descriptor) nil)
  (vk:cmd-bind-vertex-buffers command 0
                              (list (buffer-handle (%fullscreen-buffer renderer))) (list 0))
  (vk:cmd-draw command 3 1 0 0))

(defun %copy-output (renderer command)
  (let* ((context (%renderer-context renderer))
         (copy (vk:make-buffer-image-copy
                :buffer-offset 0 :buffer-row-length 0 :buffer-image-height 0
                :image-subresource (vk:make-image-subresource-layers
                                    :aspect-mask '(:color) :mip-level 0
                                    :base-array-layer 0 :layer-count 1)
                :image-offset (vk:make-offset-3d :x 0 :y 0 :z 0)
                :image-extent (vk:make-extent-3d :width (%extent-width renderer)
                                                 :height (%extent-height renderer) :depth 1))))
    (declare (ignore context))
    (vk:cmd-copy-image-to-buffer command (image-handle (%output-image renderer))
                                 :transfer-src-optimal
                                 (buffer-handle (%readback-buffer renderer)) (list copy))))

(defun %layout-for-graph-state (state resource)
  (case state
    (:undefined :undefined)
    (:depth-write :depth-stencil-attachment-optimal)
    (:sampled-read (if (eq resource :shadow)
                       :depth-stencil-read-only-optimal :shader-read-only-optimal))
    (:color-write :color-attachment-optimal)
    (:transfer-read :transfer-src-optimal)
    (otherwise (error "Estado de grafo Vulkan desconhecido: ~S" state))))

(defun %graph-state-scope (state)
  (case state
    (:undefined (values nil '(:top-of-pipe)))
    (:depth-write (values '(:depth-stencil-attachment-write)
                          '(:early-fragment-tests :late-fragment-tests)))
    (:sampled-read (values '(:shader-read) '(:fragment-shader)))
    (:color-write (values '(:color-attachment-write) '(:color-attachment-output)))
    (:transfer-read (values '(:transfer-read) '(:transfer)))
    (:transfer-write (values '(:transfer-write) '(:transfer)))
    (:present (values nil '(:bottom-of-pipe)))
    (otherwise (values nil '(:all-commands)))))

(defun %graph-image (renderer name)
  (ecase name
    (:shadow (%shadow-image renderer)) (:hdr (%hdr-image renderer))
    (:depth (%depth-image renderer)) (:output (%output-image renderer))))

(defun %graph-transition (renderer command barrier)
  (let* ((name (getf barrier :resource))
         (image (%graph-image renderer name))
         (actual (gethash name (%image-layouts renderer) :undefined))
         (target (%layout-for-graph-state (getf barrier :to) name)))
    (multiple-value-bind (src-access src-stage) (%graph-state-scope (gethash name (%image-states renderer) :undefined))
      (multiple-value-bind (dst-access dst-stage) (%graph-state-scope (getf barrier :to))
        ;; A dependência permanece mesmo quando o passe já estabeleceu o layout.
        (vk:cmd-pipeline-barrier
         command nil nil
         (list (vk:make-image-memory-barrier
                :src-access-mask src-access :dst-access-mask dst-access
                :old-layout actual :new-layout target
                :src-queue-family-index vk:+queue-family-ignored+
                :dst-queue-family-index vk:+queue-family-ignored+
                :image (image-handle image)
                :subresource-range
                (vk:make-image-subresource-range
                 :aspect-mask (if (member name '(:shadow :depth)) '(:depth) '(:color))
                 :base-mip-level 0 :level-count 1 :base-array-layer 0 :layer-count 1)))
         src-stage dst-stage)
        (setf (gethash name (%image-layouts renderer)) target
              (gethash name (%image-states renderer)) (getf barrier :to))))))

(defun %cache-renderer-device-info (renderer)
  (setf (%renderer-device-name renderer)
        (vk:device-name
         (vk:get-physical-device-properties
          (context-physical-device (%renderer-context renderer))))
        (%renderer-validation-enabled renderer) sgeo.render:*graphics-validation*)
  renderer)

(defun %initialize-renderer (window width height)
  "Entrega somente um renderer completo; falhas liberam o contexto parcial."
  (let ((context nil) (renderer nil))
    (handler-case
        (progn
          (setf context (create-context :window window :validation sgeo.render:*graphics-validation*)
                renderer (make-instance 'vulkan-renderer :context context :window window))
          (%cache-renderer-device-info renderer)
          (%check-render-formats context)
          (%ensure-render-targets renderer width height)
          (setf (%fullscreen-buffer renderer)
                (make-buffer context 24 '(:vertex-buffer) '(:host-visible :host-coherent)
                             :initial-data (%float-vector-octets
                                            (make-array 6 :element-type 'single-float
                                                        :initial-contents #(-1.0f0 -1.0f0 3.0f0
                                                                            -1.0f0 -1.0f0 3.0f0))))
                (%shadow-sampler renderer)
                (make-sampler context :filter :nearest :address-mode :clamp-to-border)
                (%hdr-sampler renderer)
                (make-sampler context :filter :linear :address-mode :clamp-to-edge))
          (%build-pipelines renderer)
          (when (context-surface context) (%recreate-renderer-swapchain renderer width height))
          (%create-present-sync renderer)
          renderer)
      (error (condition)
        (if renderer (sgeo.render:destroy-renderer renderer)
            (when context (destroy-context context)))
        (error condition)))))

(defun %check-render-formats (context)
  "Exige os recursos de formato usados pelos passes e pelo filtro HDR."
  (dolist (requirement '((:d32-sfloat :depth-stencil-attachment :sampled-image)
                         (:r16g16b16a16-sfloat :color-attachment :sampled-image :sampled-image-filter-linear)
                         (:r8g8b8a8-unorm :color-attachment :blit-src)))
    (let* ((format (first requirement))
           (features (vk:optimal-tiling-features
                      (vk:get-physical-device-format-properties (context-physical-device context) format))))
      (unless (every (lambda (feature) (member feature features)) (rest requirement))
        (error "O dispositivo não suporta ~S com os recursos ~S." format (rest requirement))))))

(defmethod sgeo.render:create-renderer ((window vulkan-window))
  (multiple-value-bind (width height) (sgeo.platform:framebuffer-size window)
    (%initialize-renderer window (if (plusp width) width 640) (if (plusp height) height 480))))

(defmethod sgeo.render:create-renderer ((window null))
  (%initialize-renderer nil 640 480))

(defun %recreate-renderer-swapchain (renderer width height)
  (multiple-value-bind (extent format)
      (recreate-swapchain (%renderer-context renderer) width height)
    (when extent (%prepare-presentation-output renderer extent format))
    extent))

(defun %acquire-present-image (renderer)
  (let* ((context (%renderer-context renderer))
         (vk:*default-extension-loader* (context-extension-loader context)))
    (acquire-frame context :semaphore (%image-available renderer))))

(defun %create-present-sync (renderer)
  (when (context-surface (%renderer-context renderer))
    (let ((device (context-device (%renderer-context renderer))))
      (setf (%image-available renderer)
            (vk:create-semaphore device (vk:make-semaphore-create-info))
            (%present-ready renderer)
            (vk:create-semaphore device (vk:make-semaphore-create-info)))))
  renderer)

(defun %recover-presentation (renderer width height)
  "Descarta uma aquisição interrompida antes de reutilizar a sincronização."
  (let ((device (context-device (%renderer-context renderer))))
    (when (%acquire-wait-pending-p renderer)
      ;; Consome a sinalização da aquisição interrompida antes de destruir o semáforo.
      (vk:queue-submit (context-queue (%renderer-context renderer))
                       (list (vk:make-submit-info
                              :wait-semaphores (list (%image-available renderer))
                              :wait-dst-stage-mask '(:transfer))))
      (vk:queue-wait-idle (context-queue (%renderer-context renderer)))
      (setf (%acquire-wait-pending-p renderer) nil))
    (vk:device-wait-idle device)
    (%recreate-renderer-swapchain renderer width height)
    (when (%image-available renderer) (vk:destroy-semaphore device (%image-available renderer)))
    (when (%present-ready renderer) (vk:destroy-semaphore device (%present-ready renderer)))
    (setf (%image-available renderer) nil (%present-ready renderer) nil)
    (%create-present-sync renderer)
    (setf (%needs-recovery-p renderer) nil)))

(defun %copy-render-state (table)
  (let ((copy (make-hash-table :test #'eq)))
    (maphash (lambda (key value) (setf (gethash key copy) value)) table)
    copy))

(defun %restore-render-state (target saved)
  (clrhash target)
  (maphash (lambda (key value) (setf (gethash key target) value)) saved))

(defun %submit-frame (renderer command)
  (let* ((context (%renderer-context renderer))
         (device (context-device context))
         (surface-p (context-surface context)))
    (end-command-buffer command)
    (vk:queue-submit
     (context-queue context)
     (list (vk:make-submit-info
            :wait-semaphores (if surface-p (list (%image-available renderer)) nil)
            :wait-dst-stage-mask (if surface-p '(:transfer) nil)
            :command-buffers (list command)
            :signal-semaphores (if surface-p (list (%present-ready renderer)) nil))))
    (setf (%acquire-wait-pending-p renderer) nil)
    (vk:queue-wait-idle (context-queue context))
    (vk:free-command-buffers device (context-command-pool context) (list command))))

(defun %sweep-geometry-cache (renderer objects)
  (let ((live (mapcar #'%entry-object objects)) (cache (%geometry-cache renderer))
        (dead nil))
    (maphash (lambda (object mesh)
               (unless (member object live :test #'eq) (push (cons object mesh) dead))) cache)
    (dolist (pair dead)
      (destroy-buffer (gpu-mesh-vertex-buffer (cdr pair)))
      (destroy-buffer (gpu-mesh-index-buffer (cdr pair)))
      (remhash (car pair) cache))))

(defmethod sgeo.render:render-frame ((renderer vulkan-renderer) world width height)
  (when (%renderer-closed-p renderer) (error "Renderer Vulkan já destruído."))
  (unless (and (plusp width) (plusp height))
    (return-from sgeo.render:render-frame nil))
  (let* ((context (%renderer-context renderer))
         (surface-p (context-surface context))
         (snapshot (sgeo.render:modern-scene-snapshot
                    world :aspect (/ (float width 1d0) (max height 1))
                    :shadow-size (%shadow-size renderer)))
         (objects (getf snapshot :objects))
         (image-index nil) (command nil) (uniforms nil) (acquire-status nil)
         (complete nil) (submitted nil) (saved-layouts nil) (saved-states nil)
         (saved-proxy-layout :undefined))
    (when (and surface-p (%needs-recovery-p renderer))
      (%recover-presentation renderer width height))
    (unless (and (= width (%extent-width renderer)) (= height (%extent-height renderer)))
      (vk:device-wait-idle (context-device context))
      (when surface-p (%recreate-renderer-swapchain renderer width height))
      (%ensure-render-targets renderer width height))
    (when surface-p
      (multiple-value-setq (image-index acquire-status) (%acquire-present-image renderer))
      (unless (member acquire-status '(:success :suboptimal))
        (when (eq acquire-status :out-of-date)
          (%recreate-renderer-swapchain renderer width height))
        (unless (member acquire-status '(:out-of-date :timeout :not-ready))
          (error "Resultado de aquisição Vulkan inesperado: ~S." acquire-status))
        (return-from sgeo.render:render-frame renderer))
      (setf (%acquire-wait-pending-p renderer) t))
    (setf saved-layouts (%copy-render-state (%image-layouts renderer))
          saved-states (%copy-render-state (%image-states renderer))
          saved-proxy-layout (%presentation-image-layout renderer))
    (unwind-protect
         (multiple-value-bind (sets tone-set allocated-uniforms)
             (%make-descriptors renderer snapshot objects)
           (setf uniforms allocated-uniforms
                 command (begin-command-buffer context :one-time t))
             (dolist (program (list (%shadow-program renderer)
                                    (%pbr-program renderer) (%tone-program renderer)))
               (when program
                 (sgeo.render:install-pending-shader program
                                                     (sgeo.render:renderer-frame-count renderer))))
             (setf (%pipelines renderer)
                   (list (sgeo.render:shader-program-active (%shadow-program renderer))
                         (sgeo.render:shader-program-active (%pbr-program renderer))
                         (sgeo.render:shader-program-active (%tone-program renderer))))
             (sgeo.render:execute-render-graph
              (sgeo.render:make-pbr-render-graph)
              (lambda (pass)
                (case (sgeo.render:render-pass-name pass)
                  (:shadow
                   (%begin-pass command (%shadow-pass renderer) (%shadow-framebuffer renderer)
                                (%shadow-size renderer) (%shadow-size renderer)
                                (list (vk:make-clear-value
                                       :depth-stencil (vk:make-clear-depth-stencil-value
                                                       :depth 1.0 :stencil 0))))
                   (let ((shadow-entries nil) (shadow-sets nil))
                     (loop for entry in objects for descriptor in sets
                           when (getf (getf entry :pbr) :casts-shadow-p)
                             do (push entry shadow-entries) (push descriptor shadow-sets))
                     (%draw-entries renderer command (first (%pipelines renderer))
                                    (nreverse shadow-sets) (nreverse shadow-entries)))
                   (vk:cmd-end-render-pass command)
                   (setf (gethash :shadow (%image-layouts renderer))
                         :depth-stencil-read-only-optimal))
                  (:pbr
                   (%begin-pass command (%pbr-pass renderer) (%pbr-framebuffer renderer)
                                width height
                                (list (vk:make-clear-value :color
                                                          (vk:make-clear-color-value
                                                           :float-32 (%single-float-vector
                                                                      0.02 0.025 0.04 1.0)))
                                      (vk:make-clear-value :depth-stencil
                                                           (vk:make-clear-depth-stencil-value
                                                            :depth 1.0 :stencil 0))))
                   (%draw-entries renderer command (second (%pipelines renderer)) sets objects)
                   (vk:cmd-end-render-pass command)
                   (setf (gethash :hdr (%image-layouts renderer)) :shader-read-only-optimal
                         (gethash :depth (%image-layouts renderer))
                         :depth-stencil-attachment-optimal))
                  (:tone
                   (%begin-pass command (%tone-pass renderer) (first (%tone-framebuffers renderer))
                                width height
                                (list (vk:make-clear-value :color
                                                          (vk:make-clear-color-value
                                                           :float-32 (%single-float-vector
                                                                      0 0 0 1)))))
                   (%draw-fullscreen renderer command tone-set)
                   (vk:cmd-end-render-pass command)
                   (setf (gethash :output (%image-layouts renderer)) :transfer-src-optimal))
                  (:output
                   (%copy-output renderer command)
                   (when surface-p (%record-swapchain-blit renderer command image-index)))))
              :transition (lambda (barrier) (%graph-transition renderer command barrier)))
             (%submit-frame renderer command)
             (setf command nil submitted t
                   (%last-frame-pixels renderer)
                   (read-buffer (%readback-buffer renderer)))
             (when surface-p
               (let ((result (present-frame context image-index
                                            :wait-semaphores (list (%present-ready renderer)))))
                 (vk:queue-wait-idle (context-present-queue context))
                 (unless (member result '(:success :suboptimal :out-of-date))
                   (error "Resultado de apresentação Vulkan inesperado: ~S." result))
                 (when (or (member result '(:suboptimal :out-of-date))
                           (eq acquire-status :suboptimal))
                   (%recreate-renderer-swapchain renderer width height))))
             (dolist (program (list (%shadow-program renderer)
                                    (%pbr-program renderer) (%tone-program renderer)))
               (sgeo.render:collect-retired-shaders
                program (sgeo.render:renderer-frame-count renderer)))
             (%sweep-geometry-cache renderer objects)
             (incf (sgeo.render:renderer-frame-count renderer))
             (setf (sgeo.render:renderer-last-error renderer) nil complete t)
             (%last-frame-pixels renderer))
        (unless complete
          (when surface-p (setf (%needs-recovery-p renderer) t))
          (unless submitted
            (%restore-render-state (%image-layouts renderer) saved-layouts)
            (%restore-render-state (%image-states renderer) saved-states)
            (setf (%presentation-image-layout renderer) saved-proxy-layout)))
        (when command
          (ignore-errors (vk:device-wait-idle (context-device context)))
          (ignore-errors (vk:free-command-buffers (context-device context)
                                                   (context-command-pool context) (list command))))
        (dolist (buffer uniforms) (destroy-buffer buffer))
        (when (%descriptor-pool renderer)
          (vk:destroy-descriptor-pool (context-device context) (%descriptor-pool renderer))
          (setf (%descriptor-pool renderer) nil))))
  renderer)

(defmethod sgeo.render:reload-renderer-shaders ((renderer vulkan-renderer)
                                                 &key (kind :pbr) source)
  (let ((program (ecase kind
                   (:pbr (%pbr-program renderer))
                   (:shadow (%shadow-program renderer))
                   (:tone (%tone-program renderer)))))
    (sgeo.render:request-shader-reload
     program (or source (sgeo.render:standard-shader-sources kind)))))

(defmethod sgeo.render:destroy-renderer ((renderer vulkan-renderer))
  (unless (%renderer-closed-p renderer)
    (let* ((context (%renderer-context renderer)) (device (context-device context)))
      (vk:device-wait-idle device)
      (%destroy-render-programs renderer)
      (when (%descriptor-pool renderer) (vk:destroy-descriptor-pool device (%descriptor-pool renderer)))
      (when (%readback-buffer renderer) (destroy-buffer (%readback-buffer renderer)))
      (when (%fullscreen-buffer renderer) (destroy-buffer (%fullscreen-buffer renderer)))
      (%destroy-targets renderer)
      (when (%presentation-image renderer) (destroy-image (%presentation-image renderer)))
      (when (%shadow-pass renderer) (vk:destroy-render-pass device (%shadow-pass renderer)))
      (when (%pbr-pass renderer) (vk:destroy-render-pass device (%pbr-pass renderer)))
      (when (%tone-pass renderer) (vk:destroy-render-pass device (%tone-pass renderer)))
      (when (%pipeline-layout renderer) (vk:destroy-pipeline-layout device (%pipeline-layout renderer)))
      (when (%descriptor-layout renderer) (vk:destroy-descriptor-set-layout device (%descriptor-layout renderer)))
      (maphash (lambda (object mesh) (declare (ignore object))
                 (destroy-buffer (gpu-mesh-vertex-buffer mesh))
                 (destroy-buffer (gpu-mesh-index-buffer mesh))) (%geometry-cache renderer))
      (clrhash (%geometry-cache renderer))
      (destroy-sampler (%shadow-sampler renderer)) (destroy-sampler (%hdr-sampler renderer))
      (when (%image-available renderer) (vk:destroy-semaphore device (%image-available renderer)))
      (when (%present-ready renderer) (vk:destroy-semaphore device (%present-ready renderer)))
      (destroy-context context)
      (setf (%renderer-closed-p renderer) t)))
  nil)

(defmethod sgeo.render:capture-frame ((renderer vulkan-renderer) window path)
  (declare (ignore window))
  (let ((pixels (%last-frame-pixels renderer)))
    (unless pixels
      (error 'sgeo.core:render-error :context "captura Vulkan"
             :message "Ainda não há um quadro concluído para capturar."))
    (ensure-directories-exist path)
    (with-open-file (stream path :direction :output :if-exists :supersede
                                  :if-does-not-exist :create
                                  :element-type '(unsigned-byte 8))
      (write-sequence (map '(vector (unsigned-byte 8)) #'char-code
                           (format nil "P6~%~D ~D~%255~%"
                                   (%extent-width renderer) (%extent-height renderer))) stream)
      (loop for y below (%extent-height renderer) do
        (loop for x below (%extent-width renderer)
              for offset = (* 4 (+ x (* y (%extent-width renderer))))
              do (write-byte (aref pixels offset) stream)
                 (write-byte (aref pixels (+ offset 1)) stream)
                 (write-byte (aref pixels (+ offset 2)) stream))))
    path))

(defmethod sgeo.render:renderer-info ((renderer vulkan-renderer))
  (flet ((generation (program)
           (if program (sgeo.render:shader-program-generation program) 0))
         (shader-error (program)
           (and program (sgeo.render:shader-program-last-error program))))
    (list :backend :vulkan :device (%renderer-device-name renderer)
          :frames (sgeo.render:renderer-frame-count renderer)
          :uploads (sgeo.render:renderer-upload-count renderer)
          :extent (list (%extent-width renderer) (%extent-height renderer))
          :gpu-meshes (hash-table-count (%geometry-cache renderer))
          :closed-p (%renderer-closed-p renderer)
          :validation (%renderer-validation-enabled renderer)
          :validation-messages (context-validation-messages (%renderer-context renderer))
          :shader-generations
          (list :shadow (generation (%shadow-program renderer))
                :pbr (generation (%pbr-program renderer))
                :tone (generation (%tone-program renderer)))
          :shader-errors
          (list :shadow (shader-error (%shadow-program renderer))
                :pbr (shader-error (%pbr-program renderer))
                :tone (shader-error (%tone-program renderer))))))
