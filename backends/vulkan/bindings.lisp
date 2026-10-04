(defpackage #:sgeo.vulkan-bindings (:use #:cl) (:export #:prepare-vulkan-bindings))
(in-package #:sgeo.vulkan-bindings)

(defun %copy-source-directory (source target)
  "Copia fontes e licenças para um cache privado do projeto."
  (ensure-directories-exist (merge-pathnames "placeholder" target))
  (dolist (file (uiop:directory-files source))
    (unless (string-equal (or (pathname-type file) "") "fasl")
      (uiop:copy-file file (merge-pathnames (file-namestring file) target))))
  (dolist (directory (uiop:subdirectories source))
    (unless (string= (car (last (pathname-directory directory))) ".git")
      (%copy-source-directory directory
                              (merge-pathnames (make-pathname :directory
                                                              (list :relative (car (last (pathname-directory directory)))))
                                               target)))))

(defun %patch-compile-helper-lifetime (text)
  "Corrige a duração dos auxiliares de macro da distribuição antiga de VK."
  (let ((needle "(eval-when (:compile-toplevel)"))
    (with-output-to-string (out)
      (loop with cursor = 0 for position = (search needle text :start2 cursor) do
        (write-string text out :start cursor :end position)
        (unless position (return))
        (write-string "(eval-when (:compile-toplevel :load-toplevel :execute)" out)
        (setf cursor (+ position (length needle)))))))

(defun prepare-vulkan-bindings ()
  "Registra fontes compatíveis sem alterar a instalação compartilhada do Quicklisp."
  (let* ((system (asdf:find-system :vk nil))
         (source (and system (asdf:system-source-directory system))))
    (unless source
      (error "Instale VK com Quicklisp ou registre seu sistema ASDF antes de carregar Vulkan."))
    (let* ((bindings (merge-pathnames "src/vk-bindings.lisp" source))
           (original (uiop:read-file-string bindings))
           (patched (%patch-compile-helper-lifetime original)))
      (unless (string= original patched)
        (let* ((root (asdf:system-source-directory (asdf:find-system :sgeo)))
               (cache (merge-pathnames
                       (format nil ".cache/vulkan-bindings/~A/" (asdf:component-version system)) root))
               (destination (merge-pathnames "src/vk-bindings.lisp" cache)))
          (unless (and (probe-file destination)
                       (string= patched (uiop:read-file-string destination)))
            (%copy-source-directory source cache)
            (with-open-file (stream destination :direction :output :if-exists :supersede)
              (write-string patched stream)))
          (asdf:clear-system :vk)
          (pushnew cache asdf:*central-registry* :test #'equal)
          (asdf:load-asd (merge-pathnames "vk.asd" cache))))
      (asdf:find-system :vk))))

(prepare-vulkan-bindings)
