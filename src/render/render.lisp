(in-package #:sgeo.render)

(defvar *graphics-validation* nil)
(defgeneric reload-renderer-shaders (renderer &key kind source))
(defmethod reload-renderer-shaders ((renderer renderer) &key (kind :pbr) source)
  (declare (ignore kind source))
  (error 'sgeo.core:render-error :context "recarga de shader" :message "O backend não oferece recarga de shaders."))

(defgeneric capture-frame (renderer window path))
(defmethod capture-frame ((renderer renderer) window path)
  (declare (ignore window path))
  (error 'sgeo.core:render-error :context "captura" :message "O backend não oferece captura de quadros."))

(defmethod create-renderer ((window t))
  (declare (ignore window))
  (error 'sgeo.core:render-error :context "criação do renderizador"
         :message "Nenhuma implementação de renderização foi carregada."))
(defmethod render-frame ((renderer renderer) world width height)
  (declare (ignore world width height))
  (error 'sgeo.core:render-error :context "quadro"
         :message "Nenhuma implementação de renderização foi carregada."))
(defmethod destroy-renderer ((renderer renderer))
  (declare (ignore renderer)) nil)
(defmethod renderer-info ((renderer renderer))
  (list :frames (renderer-frame-count renderer)
        :uploads (renderer-upload-count renderer)
        :last-error (renderer-last-error renderer)))
