(defpackage #:sgeo.procedural
  (:use #:cl)
  (:import-from #:sgeo.core
                #:touch-object #:validation-error)
  (:import-from #:sgeo.geometry
                #:triangle-mesh #:half-edge-mesh)
  (:import-from #:sgeo.scene
                #:mesh-object #:make-mesh-object #:mesh-object-geometry)
  (:export
   #:dependency-graph #:make-dependency-graph #:graph-revision
   #:define-generator #:define-geometry-generator #:find-generator #:generator-definition
   #:add-parameter-node #:add-generator-node #:remove-graph-node
   #:set-parameter #:set-generator-inputs #:set-generator-parameter
   #:node-value #:node-revision #:node-dirty-p #:node-error
   #:evaluate-node #:invalidate-node #:graph-node-data #:graph-data
   #:procedural-object #:make-procedural-object #:procedural-graph
   #:procedural-output #:regenerate-procedural-object
   #:procedural-data #:procedural-from-data))
