(in-package #:sgeo.render)

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
