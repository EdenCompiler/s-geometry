(in-package #:sgeo.editor)

(install-editor-dispatch)
(dolist (name '(open-editor make-editor *editor* execute-editor-command with-edit-transaction
                undo-edit redo-edit editor-select submit-listener inspect-editor))
  (import name :sgeo)
  (export name :sgeo))
(dolist (name '(sgeo.serialization:save-world sgeo.serialization:load-world sgeo.serialization:scene-data))
  (import name :sgeo)
  (export name :sgeo))
