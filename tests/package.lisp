(defpackage #:sgeo.tests
  (:use #:cl #:fiveam)
  (:export #:run-tests))

(in-package #:sgeo.tests)

(def-suite sgeo-suite :description "Validação headless dos marcos M0 a M6.")
(in-suite sgeo-suite)

(defun approximately= (a b &optional (epsilon 1d-8))
  "Compara números com tolerância absoluta e relativa."
  (<= (abs (- a b)) (* epsilon (max 1d0 (abs a) (abs b)))))

(defun vector-approximately= (a b &optional (epsilon 1d-8))
  "Compara vetores sem depender de sua identidade ou representação interna."
  (and (= (length a) (length b))
       (every (lambda (x y) (approximately= x y epsilon)) a b)))

(defun run-tests ()
  "Executa a suíte e devolve verdadeiro somente quando todos os testes passam."
  (run! 'sgeo-suite))
