;;;; A preparação é carregada somente quando o backend Vulkan é solicitado.
(asdf:defsystem #:sgeo-vulkan-setup
  :description "Preparação isolada das fontes dos bindings Vulkan."
  :depends-on (#:cffi #:alexandria)
  :components ((:file "backends/vulkan/bindings")))
