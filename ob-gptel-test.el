;;; ob-gptel-test.el --- Tests for ob-gptel -*- lexical-binding: t; -*-

;; Copyright (C) 2025 John Wiegley

;;; Commentary:

;; ERT tests for ob-gptel.  Run with:
;;   emacs --batch -L . -l ob-gptel-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'cl-lib)

;; Set up undercover for coverage when available (must come before
;; loading ob-gptel so that it can instrument the file).
(when (require 'undercover nil t)
  (undercover "ob-gptel.el"
              (:send-report nil)))

(require 'ert)
(require 'ob-gptel)

;;; Variable conversion tests

(ert-deftest ob-gptel-test-var-to-gptel-number ()
  "Test converting a number to string."
  (should (equal (ob-gptel-var-to-gptel 42) "42")))

(ert-deftest ob-gptel-test-var-to-gptel-string ()
  "Test converting a string to its printed representation."
  (should (equal (ob-gptel-var-to-gptel "hello") "\"hello\"")))

(ert-deftest ob-gptel-test-var-to-gptel-nil ()
  "Test converting nil."
  (should (equal (ob-gptel-var-to-gptel nil) "nil")))

(ert-deftest ob-gptel-test-var-to-gptel-list ()
  "Test converting a list."
  (should (equal (ob-gptel-var-to-gptel '(1 2 3)) "(1 2 3)")))

(ert-deftest ob-gptel-test-var-to-gptel-symbol ()
  "Test converting a symbol."
  (should (equal (ob-gptel-var-to-gptel 'foo) "foo")))

;;; Default header arguments tests

(ert-deftest ob-gptel-test-default-args-results ()
  "Test that :results defaults to replace."
  (should (equal (cdr (assoc :results org-babel-default-header-args:gptel))
                 "replace")))

(ert-deftest ob-gptel-test-default-args-exports ()
  "Test that :exports defaults to both."
  (should (equal (cdr (assoc :exports org-babel-default-header-args:gptel))
                 "both")))

(ert-deftest ob-gptel-test-default-args-format ()
  "Test that :format defaults to org."
  (should (equal (cdr (assoc :format org-babel-default-header-args:gptel))
                 "org")))

(ert-deftest ob-gptel-test-default-args-nil-keys ()
  "Test that optional parameters default to nil."
  (dolist (key '(:model :temperature :max-tokens :system :backend
                 :dry-run :preset :context :prompt :session))
    (should-not (cdr (assoc key org-babel-default-header-args:gptel)))))

(ert-deftest ob-gptel-test-default-args-completeness ()
  "Test that all expected header args are present."
  (let ((expected-keys '(:results :exports :model :temperature :max-tokens
                         :system :backend :dry-run :preset :context
                         :prompt :session :format)))
    (dolist (key expected-keys)
      (should (assoc key org-babel-default-header-args:gptel)))))

;;; Variable assignment tests

(ert-deftest ob-gptel-test-variable-assignments ()
  "Test variable assignment generation."
  (cl-letf (((symbol-function 'org-babel--get-vars)
             (lambda (_params) '(("name" . "John") ("age" . 30)))))
    (let ((assignments (org-babel-variable-assignments:gptel nil)))
      (should (= (length assignments) 2))
      (should (equal (car assignments) "name = \"John\""))
      (should (equal (cadr assignments) "age = 30")))))

(ert-deftest ob-gptel-test-variable-assignments-empty ()
  "Test variable assignments with no variables."
  (cl-letf (((symbol-function 'org-babel--get-vars)
             (lambda (_params) nil)))
    (let ((assignments (org-babel-variable-assignments:gptel nil)))
      (should (null assignments)))))

;;; Prompt finding tests

(ert-deftest ob-gptel-test-find-prompt-with-result ()
  "Test finding a named prompt block with its result."
  (with-temp-buffer
    (org-mode)
    (insert "#+name: test-prompt\n")
    (insert "#+begin_src gptel\n")
    (insert "What is 2+2?\n")
    (insert "#+end_src\n")
    (insert "\n")
    (insert "#+RESULTS: test-prompt\n")
    (insert ": 4\n")
    (goto-char (point-min))
    (let ((directives (ob-gptel-find-prompt "test-prompt" "You are helpful.")))
      (should (listp directives))
      (should (equal (car directives) "You are helpful."))
      (should (stringp (nth 1 directives)))
      (should (string-match-p "What is 2\\+2\\?" (nth 1 directives))))))

(ert-deftest ob-gptel-test-find-prompt-without-result ()
  "Test finding a named prompt block that has no result yet."
  (with-temp-buffer
    (org-mode)
    (insert "#+name: test-prompt\n")
    (insert "#+begin_src gptel\n")
    (insert "What is 2+2?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (let ((directives (ob-gptel-find-prompt "test-prompt" "system msg")))
      (should (listp directives))
      (should (equal (car directives) "system msg"))
      (should (stringp (nth 1 directives)))
      (should (string-match-p "What is 2\\+2\\?" (nth 1 directives))))))

(ert-deftest ob-gptel-test-find-prompt-not-found ()
  "Test finding a non-existent named prompt."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel\nHello\n#+end_src\n")
    (goto-char (point-min))
    (let ((directives (ob-gptel-find-prompt "nonexistent" nil)))
      (should (listp directives))
      (should (= (length directives) 1))
      (should (null (car directives))))))

(ert-deftest ob-gptel-test-find-prompt-nil-system ()
  "Test finding a prompt with nil system message."
  (with-temp-buffer
    (org-mode)
    (insert "#+name: test-prompt\n")
    (insert "#+begin_src gptel\n")
    (insert "Hello\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (let ((directives (ob-gptel-find-prompt "test-prompt" nil)))
      (should (null (car directives))))))

;;; Session tests

(ert-deftest ob-gptel-test-find-session-multiple-blocks ()
  "Test collecting blocks from a multi-block session."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session test-sess\n")
    (insert "First question\n")
    (insert "#+end_src\n")
    (insert "\n")
    (insert "#+RESULTS:\n")
    (insert ": First answer\n")
    (insert "\n")
    (insert "#+begin_src gptel :session test-sess\n")
    (insert "Second question\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let ((directives (ob-gptel-find-session "test-sess" "system")))
      (should (listp directives))
      (should (equal (car directives) "system"))
      (should (>= (length directives) 3))
      (should (string-match-p "First question" (nth 1 directives)))
      (should (string-match-p "Second question" (nth 3 directives))))))

(ert-deftest ob-gptel-test-find-session-empty ()
  "Test finding a session with no matching blocks."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session other\n")
    (insert "Hello\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let ((directives (ob-gptel-find-session "nonexistent" "system")))
      (should (listp directives))
      (should (equal (car directives) "system"))
      (should (= (length directives) 1)))))

(ert-deftest ob-gptel-test-find-session-ignores-other-sessions ()
  "Test that find-session only collects blocks from the named session."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session alpha\n")
    (insert "Alpha question\n")
    (insert "#+end_src\n\n")
    (insert "#+begin_src gptel :session beta\n")
    (insert "Beta question\n")
    (insert "#+end_src\n\n")
    (insert "#+begin_src gptel :session alpha\n")
    (insert "Alpha followup\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let ((directives (ob-gptel-find-session "alpha" nil)))
      ;; Should have nil system + 2 blocks with bodies (and possibly results)
      (should (>= (length directives) 3))
      ;; Should not contain beta content
      (let ((all-text (mapconcat (lambda (d) (or d "")) directives " ")))
        (should (string-match-p "Alpha question" all-text))
        (should (string-match-p "Alpha followup" all-text))
        (should-not (string-match-p "Beta question" all-text))))))

;;; Prep session test

(ert-deftest ob-gptel-test-prep-session-noop ()
  "Test that prep-session is a no-op and returns the session."
  (should (equal (org-babel-prep-session:gptel "my-session" nil)
                 "my-session")))

(provide 'ob-gptel-test)
;;; ob-gptel-test.el ends here
