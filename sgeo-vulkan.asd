(asdf:defsystem #:sgeo-vulkan
  :description "Implementação Vulkan do protocolo de renderização do S-Geometry."
  :defsystem-depends-on (#:sgeo-vulkan-setup)
  :depends-on (#:sgeo/render #:vk #:cl-glfw3 #:cffi)
  :serial t
  :components ((:file "backends/vulkan/package") (:file "backends/vulkan/context")
               (:file "backends/vulkan/resources") (:file "backends/vulkan/presentation")
               (:file "backends/vulkan/renderer") (:file "backends/vulkan/output")))
