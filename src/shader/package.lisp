(defpackage #:sgeo.shader
  (:use #:cl)
  (:export
   #:shader-error #:shader-type-error #:shader-interface-error
   #:shader-definition #:shader-definition-name #:shader-definition-stage
   #:shader-definition-declarations
   #:shader-definition-parameters #:shader-definition-outputs
   #:shader-definition-ast #:shader-definition-sgir #:shader-definition-source
   #:shader-parameter #:shader-parameter-name #:shader-parameter-type
   #:shader-parameter-storage #:shader-parameter-location
   #:shader-parameter-set #:shader-parameter-binding #:shader-parameter-decorations
   #:shader-expression #:shader-expression-opcode #:shader-expression-type
   #:shader-expression-operands #:shader-expression-value #:shader-expression-attributes
   #:shader-statement #:shader-statement-opcode #:shader-statement-data
   #:shader-output #:shader-output-name #:shader-output-type #:shader-output-expression
   #:gpu-function-definition #:gpu-function-definition-name #:gpu-function-definition-arguments
   #:gpu-function-definition-return-type #:gpu-function-definition-ast
   #:gpu-function-definition-source #:compile-gpu-function-form
   #:sgir-module #:sgir-module-name #:sgir-module-stage #:sgir-module-entry-point
   #:sgir-module-functions #:sgir-module-interfaces
   #:sgir-function #:sgir-function-name #:sgir-function-return-type
   #:sgir-function-parameters #:sgir-function-blocks
   #:sgir-parameter #:sgir-parameter-name #:sgir-parameter-type
   #:sgir-parameter-storage #:sgir-parameter-decorations
   #:sgir-block #:sgir-block-name #:sgir-block-instructions #:sgir-block-terminator
   #:sgir-instruction #:sgir-instruction-opcode #:sgir-instruction-result
   #:sgir-instruction-type #:sgir-instruction-operands #:sgir-instruction-attributes
   #:sgir-terminator #:sgir-terminator-opcode #:sgir-terminator-operands
   #:sgir-terminator-targets
   #:sgir-interface #:sgir-interface-name #:sgir-interface-type
   #:sgir-interface-storage #:sgir-interface-location #:sgir-interface-set
   #:sgir-interface-binding #:sgir-interface-decorations
   #:compile-shader #:shader-definition-by-name #:all-shader-definitions
   #:defshader #:defgpu-function #:compile-shader-form
   #:emit-glsl #:link-shaders
   #:compile-shader-to-spirv #:write-shader-spirv #:spirv-module-metadata
   #:shader-type-p #:shader-type-width #:shader-type-kind))
(in-package #:sgeo.shader)
