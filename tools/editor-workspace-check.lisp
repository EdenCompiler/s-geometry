;;;; Verifica os controles de workspace sem criar uma janela OpenGL.
(load (merge-pathnames "bootstrap.lisp" (or *load-truename* *compile-file-truename*)))
(asdf:load-system :sgeo/editor/opengl)

(defun workspace-check (condition description)
  "Interrompe a verificação quando um contrato do workspace falha."
  (unless condition (error "Verificação do workspace falhou: ~A" description))
  t)

(let* ((editor (sgeo.editor:make-editor))
       (state (sgeo.editor.opengl::%make-editor-ui
               :editor editor :width 1000 :height 800
               :renderer (make-instance 'sgeo.render:renderer))))
  (workspace-check (sgeo.editor.opengl::%dispatch-workspace-action
                    state '(:workspace-tool :debug))
                   "ativação do painel de diagnóstico")
  (workspace-check (and (eq (sgeo.editor.opengl::editor-ui-workspace-tool state) :debug)
                        (sgeo.editor.opengl::editor-ui-show-hierarchy-p state)
                        (>= (sgeo.editor.opengl::editor-ui-left-width state) 320))
                   "ferramenta visível com painel esquerdo mínimo")

  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-size :left 20))
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-size :right -20))
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-size :bottom 40))
  (workspace-check (= (sgeo.editor.opengl::editor-ui-left-width state) 340)
                   "ajuste da largura esquerda")
  (workspace-check (= (sgeo.editor.opengl::editor-ui-right-width state) 266)
                   "ajuste da largura direita")
  (workspace-check (= (sgeo.editor.opengl::editor-ui-bottom-height state) 206)
                   "ajuste da altura inferior")
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-size :bottom -1000))
  (workspace-check (= (sgeo.editor.opengl::editor-ui-bottom-height state) 78)
                   "limite mínimo do painel inferior")

  (dolist (panel '(:hierarchy :inspector :history :listener))
    (workspace-check (sgeo.editor.opengl::%dispatch-workspace-action
                      state (list :workspace-toggle panel))
                     (format nil "alternância do painel ~A" panel))
    (workspace-check
     (not (funcall (ecase panel
                     (:hierarchy #'sgeo.editor.opengl::editor-ui-show-hierarchy-p)
                     (:inspector #'sgeo.editor.opengl::editor-ui-show-inspector-p)
                     (:history #'sgeo.editor.opengl::editor-ui-show-history-p)
                     (:listener #'sgeo.editor.opengl::editor-ui-show-listener-p)) state))
     (format nil "painel ~A oculto" panel)))

  (workspace-check (sgeo.editor.opengl::%dispatch-workspace-action
                    state '(:workspace-clock :play)) "início do relógio")
  (workspace-check (sgeo.editor:editor-playing-p editor) "relógio em reprodução")
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-clock :step))
  (workspace-check (> (sgeo.editor:editor-time editor) 0d0) "avanço de quadro único")
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-clock :pause))
  (workspace-check (not (sgeo.editor:editor-playing-p editor)) "pausa do relógio")
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-clock :slower))
  (workspace-check (= (sgeo.editor:editor-time-scale editor) 0.5d0) "redução da velocidade")
  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-clock :faster))
  (workspace-check (= (sgeo.editor:editor-time-scale editor) 1d0) "aumento da velocidade")

  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-tool :profile))
  (dotimes (index 125)
    (sgeo.editor.opengl::%update-profile state (/ (1+ index) 1000d0) 0d0))
  (workspace-check (= (length (sgeo.editor.opengl::editor-ui-profile-samples state)) 120)
                   "retenção limitada de amostras de perfil")
  (workspace-check (= (first (sgeo.editor.opengl::editor-ui-profile-samples state)) 125d0)
                   "amostra mais recente do perfil")
  (workspace-check (= (getf (sgeo.editor:editor-profile editor) :uploads) 0)
                   "contadores do renderizador sem contexto gráfico")

  (sgeo.editor.opengl::%dispatch-workspace-action state '(:workspace-reset))
  (workspace-check (and (null (sgeo.editor.opengl::editor-ui-workspace-tool state))
                        (null (sgeo.editor.opengl::editor-ui-left-width state))
                        (null (sgeo.editor.opengl::editor-ui-right-width state))
                        (null (sgeo.editor.opengl::editor-ui-bottom-height state))
                        (sgeo.editor.opengl::editor-ui-show-hierarchy-p state)
                        (sgeo.editor.opengl::editor-ui-show-inspector-p state)
                        (sgeo.editor.opengl::editor-ui-show-history-p state)
                        (sgeo.editor.opengl::editor-ui-show-listener-p state))
                   "restauração dos valores padrão")
  ;; Ocultar a hierarquia não muda a região de rolagem do histórico.
  (setf (sgeo.editor.opengl::editor-ui-show-hierarchy-p state) nil)
  (let* ((layout (sgeo.editor.opengl::%make-layout state 1000 800))
         (bottom (getf layout :bottom)))
    (setf (sgeo.editor.opengl::editor-ui-mouse-x state) 100
          (sgeo.editor.opengl::editor-ui-mouse-y state) (+ (second bottom) 50))
    (sgeo.editor.opengl::%scroll state 0d0 -1d0)
    (workspace-check (and (= 1 (sgeo.editor.opengl::editor-ui-history-scroll state))
                          (zerop (sgeo.editor.opengl::editor-ui-output-scroll state)))
                     "o histórico ainda rola com a hierarquia oculta")
    (setf (sgeo.editor.opengl::editor-ui-mouse-x state) 550)
    (sgeo.editor.opengl::%scroll state 0d0 -1d0)
    (workspace-check (= 1 (sgeo.editor.opengl::editor-ui-output-scroll state))
                     "a região do listener rola sua própria saída")
    (setf (sgeo.editor.opengl::editor-ui-show-listener-p state) nil)
    (sgeo.editor.opengl::%scroll state 0d0 -1d0)
    (workspace-check (= 2 (sgeo.editor.opengl::editor-ui-history-scroll state))
                     "o histórico ocupa o painel inferior quando o listener está oculto"))
  (sgeo.editor:close-editor editor))

(format t "Verificação do workspace concluída.~%")
