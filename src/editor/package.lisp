(defpackage #:sgeo.editor
  (:use #:cl)
  (:export
   #:editor-state #:make-editor #:open-editor #:*editor*
   #:editor-world #:editor-selection-mode #:editor-elements #:editor-view
   #:editor-layout #:editor-tool #:editor-inspected #:editor-status #:editor-history
   #:editor-running-p #:editor-scene-path #:editor-listener-input #:editor-listener-output
   #:editor-profile #:editor-time #:editor-playing-p #:editor-time-scale #:advance-editor-time
   #:editor-select #:editor-objects #:set-editor-view #:set-editor-layout
   #:execute-editor-command #:replay-editor-command #:editor-command #:command-name
   #:command-arguments #:command-label #:command-form
   #:with-edit-transaction #:call-with-edit-transaction #:undo-edit #:redo-edit
   #:editor-undo-stack #:editor-redo-stack #:capture-editor-snapshot #:restore-editor-snapshot
   #:call-in-editor #:process-editor-requests #:install-editor-dispatch #:close-editor
   #:submit-listener #:listener-busy-p #:start-editor-listener #:stop-editor-listener
   #:start-editor-server #:inspect-value #:inspect-editor #:inspect-back #:set-inspector-number
   #:start-editor-terminal #:stop-editor-terminal
   #:editor-view-camera #:projected-position #:pick-element))
(in-package #:sgeo.editor)
(defvar *editor* nil)
