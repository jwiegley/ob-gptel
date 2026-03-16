;;; ob-gptel-bench.el --- Benchmarks for ob-gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2025 John Wiegley

;;; Commentary:

;; Performance benchmarks for ob-gptel.  Run with:
;;   emacs --batch -L . -l ob-gptel-bench.el --eval '(ob-gptel-bench-run)'

;;; Code:

(require 'benchmark)
(require 'ob-gptel)

(defun ob-gptel-bench-var-to-gptel ()
  "Benchmark `ob-gptel-var-to-gptel'."
  (car (benchmark-run 10000
         (ob-gptel-var-to-gptel "test string")
         (ob-gptel-var-to-gptel 42)
         (ob-gptel-var-to-gptel '(1 2 3)))))

(defun ob-gptel-bench-find-session ()
  "Benchmark `ob-gptel-find-session' with 10 session blocks."
  (with-temp-buffer
    (org-mode)
    (dotimes (i 10)
      (insert (format "#+begin_src gptel :session bench\nQuestion %d\n#+end_src\n\n" i))
      (insert (format "#+RESULTS:\n: Answer %d\n\n" i)))
    (goto-char (point-max))
    (car (benchmark-run 100
           (ob-gptel-find-session "bench" "system")))))

(defun ob-gptel-bench-run ()
  "Run all benchmarks and print results."
  (let ((results
         (list
          (cons "var_to_gptel" (ob-gptel-bench-var-to-gptel))
          (cons "find_session" (ob-gptel-bench-find-session)))))
    (dolist (r results)
      (message "BENCH %s %.6f" (car r) (cdr r)))
    results))

(provide 'ob-gptel-bench)
;;; ob-gptel-bench.el ends here
