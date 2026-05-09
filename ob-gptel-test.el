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

;;; Pending integration tests

(ert-deftest ob-gptel-test-use-pending-p-honors-feature ()
  "Predicate reflects whether `pending' is loaded."
  (cl-letf (((symbol-function 'featurep)
             (lambda (f &optional _) (eq f 'pending))))
    (should (ob-gptel--use-pending-p)))
  (cl-letf (((symbol-function 'featurep)
             (lambda (_f &optional _) nil)))
    (should-not (ob-gptel--use-pending-p))))

(ert-deftest ob-gptel-test-legacy-replace-replaces-uuid ()
  "`ob-gptel--legacy-replace' substitutes the UUID with the response."
  (with-temp-buffer
    (insert "before <gptel-uuid> after")
    (ob-gptel--legacy-replace "<gptel-uuid>" (current-buffer) "RESULT")
    (should (equal (buffer-string) "before RESULT after"))))

(ert-deftest ob-gptel-test-legacy-replace-noop-when-missing ()
  "`ob-gptel--legacy-replace' is a no-op when UUID is absent."
  (with-temp-buffer
    (insert "no marker here")
    (ob-gptel--legacy-replace "<gptel-uuid>" (current-buffer) "RESULT")
    (should (equal (buffer-string) "no marker here"))))

(ert-deftest ob-gptel-test-format-response-trims ()
  "`ob-gptel--format-response' trims whitespace."
  (cl-letf (((symbol-function 'gptel--convert-markdown->org)
             (lambda (s) (concat "ORG:" s))))
    (should (equal (ob-gptel--format-response "  hi  " "markdown") "hi"))
    (should (equal (ob-gptel--format-response "  hi  " "org") "ORG:hi"))))

(ert-deftest ob-gptel-test-make-callback-uses-legacy-when-no-token ()
  "Callback falls back to UUID search/replace when no pending token."
  (with-temp-buffer
    (insert "X<gptel-uuid>X")
    (let* ((cell (cons nil nil))
           (cb (ob-gptel--make-callback "<gptel-uuid>"
                                        (current-buffer) "markdown" cell)))
      (funcall cb "RESULT" nil)
      (should (equal (buffer-string) "XRESULTX")))))

(ert-deftest ob-gptel-test-make-callback-prefers-pending-when-active ()
  "Callback calls `pending-finish' when token is active."
  (let* ((cell (cons 'fake-token nil))
         (finish-args nil)
         ;; Stub featurep so the predicate sees pending as loaded.
         (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &optional v)
                 (or (eq f 'pending) (funcall orig-featurep f v))))
              ((symbol-function 'pending-active-p)
               (lambda (tok) (eq tok 'fake-token)))
              ((symbol-function 'pending-finish)
               (lambda (tok text) (setq finish-args (list tok text)) t)))
      (with-temp-buffer
        (let ((cb (ob-gptel--make-callback "<gptel-uuid>"
                                           (current-buffer) "markdown" cell)))
          (funcall cb "  hello  " nil)))
      (should (equal finish-args '(fake-token "hello"))))))

(ert-deftest ob-gptel-test-make-callback-rejects-on-error ()
  "Callback calls `pending-reject' when response is not a string."
  (let* ((cell (cons 'fake-token nil))
         (reject-args nil)
         (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &optional v)
                 (or (eq f 'pending) (funcall orig-featurep f v))))
              ((symbol-function 'pending-active-p)
               (lambda (_) t))
              ((symbol-function 'pending-reject)
               (lambda (tok reason &optional _)
                 (setq reject-args (list tok reason)) t)))
      (with-temp-buffer
        (let ((cb (ob-gptel--make-callback "<gptel-uuid>"
                                           (current-buffer) "markdown" cell)))
          (funcall cb nil '(:error "boom")))
        (should (equal (car reject-args) 'fake-token))
        (should (string-match-p "boom" (cadr reject-args)))))))

(ert-deftest ob-gptel-test-make-callback-abort-is-noop ()
  "Callback does not touch the buffer when response is symbol `abort'."
  (with-temp-buffer
    (insert "X<gptel-uuid>X")
    (let* ((cell (cons nil nil))
           (cb (ob-gptel--make-callback "<gptel-uuid>"
                                        (current-buffer) "markdown" cell)))
      (funcall cb 'abort nil)
      (should (equal (buffer-string) "X<gptel-uuid>X")))))

(ert-deftest ob-gptel-test-adopt-pending-noop-without-feature ()
  "`ob-gptel--adopt-pending' is a no-op when pending is not loaded."
  (cl-letf (((symbol-function 'featurep)
             (lambda (_f &optional _) nil)))
    (with-temp-buffer
      (insert "X<gptel-uuid>X")
      (let ((cell (cons nil nil)))
        (should-not (ob-gptel--adopt-pending "<gptel-uuid>"
                                             (current-buffer) "label" cell))
        (should (null (car cell)))))))

;;; Entry-context tests

(ert-deftest ob-gptel-test-default-args-entry ()
  "`:entry' defaults to nil in the default header args alist."
  (should (assoc :entry org-babel-default-header-args:gptel))
  (should-not (cdr (assoc :entry org-babel-default-header-args:gptel))))

(ert-deftest ob-gptel-test-entry-text-captures-prose ()
  "Entry helper returns the prose preceding the src block."
  (with-temp-buffer
    (org-mode)
    (insert "* My heading\n")
    (insert "Prose line one.\n")
    (insert "Prose line two.\n")
    (insert "\n")
    (insert "#+begin_src gptel :entry t\n")
    (insert "Question?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (search-forward "#+begin_src gptel")
    (let ((text (ob-gptel--entry-text-before-block)))
      (should (stringp text))
      (should (string-match-p "Prose line one\\." text))
      (should (string-match-p "Prose line two\\." text))
      (should-not (string-match-p "My heading" text))
      (should-not (string-match-p "begin_src" text)))))

(ert-deftest ob-gptel-test-entry-text-skips-properties-and-planning ()
  "Entry helper skips :PROPERTIES:, planning, and :LOGBOOK: drawers."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading with metadata\n")
    (insert "SCHEDULED: <2025-01-01 Wed>\n")
    (insert ":PROPERTIES:\n:CUSTOM_ID: foo\n:END:\n")
    (insert ":LOGBOOK:\n- Note taken on [2025-01-02 Thu] \\\\\n  whatever\n:END:\n")
    (insert "Actual prose here.\n")
    (insert "#+begin_src gptel :entry t\n")
    (insert "Q?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (search-forward "#+begin_src gptel")
    (let ((text (ob-gptel--entry-text-before-block)))
      (should (stringp text))
      (should (string-match-p "Actual prose here" text))
      (should-not (string-match-p "SCHEDULED" text))
      (should-not (string-match-p "CUSTOM_ID" text))
      (should-not (string-match-p "LOGBOOK" text))
      (should-not (string-match-p "Note taken" text)))))

(ert-deftest ob-gptel-test-entry-text-empty-when-block-is-first ()
  "Entry helper returns nil when block immediately follows the heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\n")
    (insert "#+begin_src gptel :entry t\n")
    (insert "Q?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (search-forward "#+begin_src gptel")
    (should-not (ob-gptel--entry-text-before-block))))

(ert-deftest ob-gptel-test-entry-text-uses-current-heading-only ()
  "Entry helper captures only the heading containing the block."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n")
    (insert "Parent prose should not appear.\n")
    (insert "** Child\n")
    (insert "Child prose should appear.\n")
    (insert "#+begin_src gptel :entry t\n")
    (insert "Q?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (search-forward "#+begin_src gptel")
    (let ((text (ob-gptel--entry-text-before-block)))
      (should (stringp text))
      (should (string-match-p "Child prose should appear\\." text))
      (should-not (string-match-p "Parent prose" text)))))

(ert-deftest ob-gptel-test-entry-text-no-heading-uses-buffer-start ()
  "Entry helper falls back to point-min when no heading exists."
  (with-temp-buffer
    (org-mode)
    (insert "Loose prose at top of buffer.\n")
    (insert "More loose prose.\n")
    (insert "#+begin_src gptel :entry t\n")
    (insert "Q?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (search-forward "#+begin_src gptel")
    (let ((text (ob-gptel--entry-text-before-block)))
      (should (stringp text))
      (should (string-match-p "Loose prose at top" text))
      (should (string-match-p "More loose prose" text)))))

(ert-deftest ob-gptel-test-entry-text-buffer-start-empty ()
  "Entry helper returns nil when block is at top of buffer with no content."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :entry t\n")
    (insert "Q?\n")
    (insert "#+end_src\n")
    (goto-char (point-min))
    (search-forward "#+begin_src gptel")
    (should-not (ob-gptel--entry-text-before-block))))

(ert-deftest ob-gptel-test-capf-advertises-entry ()
  "Completion-at-point advertises the :entry header arg."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :")
    (let ((completion-data (ob-gptel-capf)))
      (should completion-data)
      (let ((completions (nth 2 completion-data)))
        (should (member "entry" completions))))))

(provide 'ob-gptel-test)
;;; ob-gptel-test.el ends here
