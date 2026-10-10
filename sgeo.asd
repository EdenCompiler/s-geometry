;;;; Sistemas independentes permitem utilizar a geometria sem inicializar gráficos.

(asdf:defsystem #:sgeo/core
  :description "Objetos básicos, identidade, revisões e condições do S-Geometry."
  :version "0.1.0"
  :depends-on (#:bordeaux-threads)
  :serial t
  :components ((:file "src/core/package") (:file "src/core/core")))

(asdf:defsystem #:sgeo/math
  :description "Matemática própria do motor, sem dependências gráficas."
  :depends-on (#:sgeo/core)
  :serial t
  :components ((:file "src/math/package") (:file "src/math/math")))

(asdf:defsystem #:sgeo/geometry
  :description "Malhas de CPU, núcleo half-edge e operações de modelagem."
  :depends-on (#:sgeo/core #:sgeo/math)
  :serial t
  :components ((:file "src/geometry/package") (:file "src/geometry/mesh")
               (:file "src/geometry/topology") (:file "src/geometry/polygons")
               (:file "src/geometry/primitives") (:file "src/geometry/operations")))

(asdf:defsystem #:sgeo/scene
  :description "Mundo vivo, hierarquia, transformações, materiais e câmeras."
  :depends-on (#:sgeo/core #:sgeo/math #:sgeo/geometry #:bordeaux-threads)
  :serial t
  :components ((:file "src/scene/package") (:file "src/scene/scene")
               (:file "src/scene/materials")))

(asdf:defsystem #:sgeo/animation
  :description "Pistas, esqueletos e deformações derivados dos objetos vivos."
  :depends-on (#:sgeo/scene)
  :serial t
  :components ((:file "src/animation/package") (:file "src/animation/skeleton")
               (:file "src/animation/tracks") (:file "src/animation/playback")))

(asdf:defsystem #:sgeo/gltf
  :description "Intercâmbio glTF 2.0 de cenas, materiais, malhas e animações."
  :depends-on (#:sgeo/animation #:yason)
  :serial t
  :components ((:file "src/gltf/package") (:file "src/gltf/gltf")))

(asdf:defsystem #:sgeo
  :description "API pública do núcleo headless do S-Geometry/CL."
  :version "0.1.0"
  :depends-on (#:sgeo/animation)
  :in-order-to ((test-op (test-op "sgeo/tests")))
  :components ((:file "src/package")))

(asdf:defsystem #:sgeo/platform
  :description "Protocolo substituível de janelas e eventos."
  :depends-on (#:sgeo/core)
  :serial t
  :components ((:file "src/platform/package") (:file "src/platform/platform")))

(asdf:defsystem #:sgeo/shader
  :description "SGL: AST tipada, SGIR, SPIR-V e GLSL de inspeção, inteiramente em Lisp."
  :depends-on (#:sgeo/core #:sgeo/math)
  :serial t
  :components ((:file "src/shader/package") (:file "src/shader/frontend")
               (:file "src/shader/ir") (:file "src/shader/glsl") (:file "src/shader/spirv")))

(asdf:defsystem #:sgeo/render
  :description "Protocolo de renderização sobre instantâneos do mundo Lisp."
  :depends-on (#:sgeo/scene #:sgeo/platform #:sgeo/shader #:bordeaux-threads)
  :serial t
  :components ((:file "src/render/package") (:file "src/render/render")
               (:file "src/render/graph") (:file "src/render/hot-reload")
               (:file "src/render/shaders") (:file "src/render/modern-scene")))

(asdf:defsystem #:sgeo/backend/opengl
  :description "Backend OpenGL 3.3 com cl-glfw3, cl-opengl e CFFI."
  :depends-on (#:sgeo/platform #:sgeo/render #:cl-glfw3 #:cl-opengl #:cffi)
  :serial t
  :components ((:file "backends/opengl/package")
               (:file "backends/opengl/glfw")
               (:file "backends/opengl/opengl")))

(asdf:defsystem #:sgeo/backend/vulkan
  :description "Backend Vulkan: recursos, passes HDR/PBR e apresentação GLFW."
  :depends-on (#:sgeo-vulkan))

(asdf:defsystem #:sgeo/runtime/core
  :description "Laço gráfico e REPL externo sobre o mesmo mundo vivo."
  :depends-on (#:sgeo #:sgeo/render #:bordeaux-threads)
  :serial t
  :components ((:file "src/runtime/package") (:file "src/runtime/runtime")
               (:file "src/runtime-api")))

(asdf:defsystem #:sgeo/runtime
  :description "Runtime com backend OpenGL padrão."
  :depends-on (#:sgeo/runtime/core #:sgeo/backend/opengl))

(asdf:defsystem #:sgeo/runtime/vulkan
  :description "Runtime com backend Vulkan, sem carregar OpenGL."
  :depends-on (#:sgeo/runtime/core #:sgeo/backend/vulkan))

(asdf:defsystem #:sgeo/examples/pbr
  :description "Visualizador PBR com shaders Lisp, sombras e atualização ao vivo."
  :depends-on (#:sgeo/runtime/vulkan #:sgeo/serialization)
  :components ((:file "examples/pbr-scene")))

(asdf:defsystem #:sgeo/examples
  :description "Demonstrações executáveis dos marcos M0, M1 e M2."
  :depends-on (#:sgeo/runtime)
  :serial t
  :components ((:file "examples/package") (:file "examples/triangle")
               (:file "examples/live-scene") (:file "examples/kernel-scene")))

(asdf:defsystem #:sgeo/examples/animation
  :description "Personagem glTF animado no mesmo editor e mundo vivo."
  :depends-on (#:sgeo/editor/opengl)
  :components ((:file "examples/animation-scene")))

(asdf:defsystem #:sgeo/serialization
  :description "Persistência legível, validada e versionada de cenas Lisp."
  :depends-on (#:sgeo/animation)
  :serial t
  :components ((:file "src/serialization/package") (:file "src/serialization/serialization")
               (:file "src/serialization/animation")))

(asdf:defsystem #:sgeo/editor
  :description "Comandos, transações, seleção e listener do editor vivo."
  :depends-on (#:sgeo #:sgeo/serialization #:sgeo/gltf)
  :serial t
  :components ((:file "src/editor/package") (:file "src/editor/state")
               (:file "src/editor/transactions") (:file "src/editor/selection")
               (:file "src/editor/timeline")
               (:file "src/editor/commands") (:file "src/editor/inspector")
               (:file "src/editor/listener") (:file "src/editor/api")))

(asdf:defsystem #:sgeo/tests
  :description "Testes headless do núcleo e da cena."
  :depends-on (#:sgeo #:sgeo/editor #:sgeo/render #:fiveam)
  :serial t
  :components ((:file "tests/package") (:file "tests/core-math")
               (:file "tests/geometry-scene") (:file "tests/kernel-topology")
               (:file "tests/kernel-geometry") (:file "tests/kernel-operations")
               (:file "tests/serialization") (:file "tests/editor-selection")
               (:file "tests/editor-inspector") (:file "tests/editor-transactions")
               (:file "tests/editor-listener") (:file "tests/editor-terminal")
               (:file "tests/shader-language") (:file "tests/shader-spirv")
               (:file "tests/modern-render")
               (:file "tests/animation-tracks") (:file "tests/animation-skeleton")
               (:file "tests/animation-editor") (:file "tests/animation-persistence")
               (:file "tests/gltf") (:file "tests/gltf-validation"))
  :perform (test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :sgeo.tests :run-tests)
               (error "A suíte de testes do S-Geometry falhou."))))

(asdf:defsystem #:sgeo/editor/opengl
  :description "Editor nativo com OpenGL e atlas de fontes FreeType."
  :depends-on (#:sgeo/editor #:sgeo/runtime #:cl-freetype2)
  :serial t
  :components ((:file "backends/opengl/editor-draw")
               (:file "src/editor/opengl-package") (:file "src/editor/opengl-ui")
               (:file "src/editor/opengl-workspace")))
