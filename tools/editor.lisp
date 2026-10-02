;;;; Compatibilidade: o lançador principal do editor fica em run.lisp.
(load (merge-pathnames "run.lisp" (or *load-truename* *compile-file-truename*)))
