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
              (:send-report nil)
              (:report-format 'lcov)
              (:report-file "coverage.lcov")))

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

(ert-deftest ob-gptel-test-legacy-replace-inserts-result ()
  "`ob-gptel--legacy-replace' replaces the block result."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel\nQuestion\n#+end_src\n\n#+RESULTS:\n: OLD\n")
    (ob-gptel--legacy-replace
     (current-buffer) "RESULT" (point-min) '("replace"))
    (should (equal (buffer-string)
                   "#+begin_src gptel\nQuestion\n#+end_src\n\n#+RESULTS:\n: RESULT\n"))))

(ert-deftest ob-gptel-test-legacy-replace-noop-for-dead-buffer ()
  "`ob-gptel--legacy-replace' is a no-op for a dead buffer."
  (let ((buffer (generate-new-buffer " *ob-gptel-dead*")))
    (kill-buffer buffer)
    (should-not (ob-gptel--legacy-replace buffer "RESULT" 1 '("replace")))))

(ert-deftest ob-gptel-test-format-response-trims ()
  "`ob-gptel--format-response' trims whitespace."
  (cl-letf (((symbol-function 'gptel--convert-markdown->org)
             (lambda (s) (concat "ORG:" s))))
    (should (equal (ob-gptel--format-response "  hi  " "markdown") "hi"))
    (should (equal (ob-gptel--format-response "  hi  " "org") "ORG:hi"))))

(ert-deftest ob-gptel-test-make-callback-inserts-result-without-token ()
  "Callback inserts an Org result when no pending token exists."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel\nQuestion\n#+end_src\n\n#+RESULTS:\n: OLD\n")
    (let* ((cell (cons nil nil))
           (cb (ob-gptel--make-callback
                (current-buffer) "markdown" cell (point-min) '("replace"))))
      (funcall cb "RESULT" nil)
      (should (equal (buffer-string)
                     "#+begin_src gptel\nQuestion\n#+end_src\n\n#+RESULTS:\n: RESULT\n")))))

(ert-deftest ob-gptel-test-make-callback-prefers-pending-when-active ()
  "Callback calls `pending-finish' with a function that invokes
`ob-gptel--legacy-replace' on the trimmed response."
  (let* ((cell (cons 'fake-token nil))
         (finish-args nil)
         (replace-args nil)
         ;; Stub featurep so the predicate sees pending as loaded.
         (orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'featurep)
               (lambda (f &optional v)
                 (or (eq f 'pending) (funcall orig-featurep f v))))
              ((symbol-function 'pending-active-p)
               (lambda (tok) (eq tok 'fake-token)))
              ((symbol-function 'pending-finish)
               (lambda (tok fn) (setq finish-args (list tok fn)) t))
              ((symbol-function 'ob-gptel--legacy-replace)
               (lambda (buffer text block-start result-params)
                 (setq replace-args
                       (list buffer text block-start result-params)))))
      (with-temp-buffer
        (let ((cb (ob-gptel--make-callback
                   (current-buffer) "markdown" cell (point-min) nil)))
          (funcall cb "  hello  " nil)))
      ;; pending-finish should have been called with token + a function.
      (should (= (length finish-args) 2))
      (should (eq (car finish-args) 'fake-token))
      (should (functionp (cadr finish-args)))
      ;; Invoking that function should call ob-gptel--legacy-replace
      ;; with the trimmed text.
      (funcall (cadr finish-args))
      (should (= (length replace-args) 4))
      (should (string= (cadr replace-args) "hello")))))

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
        (let ((cb (ob-gptel--make-callback
                   (current-buffer) "markdown" cell (point-min) nil)))
          (funcall cb nil '(:error "boom")))
        (should (equal (car reject-args) 'fake-token))
        (should (string-match-p "boom" (cadr reject-args)))))))

(ert-deftest ob-gptel-test-make-callback-abort-is-noop ()
  "Callback does not touch the buffer when response is symbol `abort'."
  (with-temp-buffer
    (insert "unchanged")
    (let* ((cell (cons nil nil))
           (cb (ob-gptel--make-callback
                (current-buffer) "markdown" cell (point-min) nil)))
      (funcall cb 'abort nil)
      (should (equal (buffer-string) "unchanged")))))

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

;;; ob-gptel--all-source-blocks tests

(ert-deftest ob-gptel-test-all-source-blocks-single ()
  "Test collecting a single source block from a session."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session my-sess :model gpt-4\n")
    (insert "Hello world\n")
    (insert "#+end_src\n")
    ;; ob-gptel--all-source-blocks narrows to (point-min .. point),
    ;; so point must be past the blocks we want to find.
    (goto-char (point-max))
    (let ((blocks (ob-gptel--all-source-blocks "my-sess")))
      (should (= (length blocks) 1))
      (should (equal (plist-get (car blocks) :language) "gptel"))
      (should (equal (plist-get (car blocks) :body) "Hello world"))
      (should (equal (cdr (assoc :model (plist-get (car blocks) :parameters)))
                     "gpt-4")))))

(ert-deftest ob-gptel-test-all-source-blocks-multiple ()
  "Test collecting multiple source blocks from one session."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session shared\n")
    (insert "First block\n")
    (insert "#+end_src\n\n")
    (insert "#+RESULTS:\n: answer1\n\n")
    (insert "#+begin_src gptel :session shared\n")
    (insert "Second block\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let ((blocks (ob-gptel--all-source-blocks "shared")))
      (should (= (length blocks) 2))
      (should (equal (plist-get (nth 0 blocks) :body) "First block"))
      (should (equal (plist-get (nth 1 blocks) :body) "Second block")))))

(ert-deftest ob-gptel-test-all-source-blocks-ignores-other-sessions ()
  "Test that only blocks matching SESSION are returned."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session alpha\n")
    (insert "Alpha\n")
    (insert "#+end_src\n\n")
    (insert "#+begin_src gptel :session beta\n")
    (insert "Beta\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let ((blocks (ob-gptel--all-source-blocks "alpha")))
      (should (= (length blocks) 1))
      (should (equal (plist-get (car blocks) :body) "Alpha")))
    (goto-char (point-max))
    (let ((blocks (ob-gptel--all-source-blocks "beta")))
      (should (= (length blocks) 1))
      (should (equal (plist-get (car blocks) :body) "Beta")))))

(ert-deftest ob-gptel-test-all-source-blocks-no-match ()
  "Test that no blocks are returned for an unknown session."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session other\nHello\n#+end_src\n")
    (goto-char (point-max))
    (let ((blocks (ob-gptel--all-source-blocks "nonexistent")))
      (should (null blocks)))))

(ert-deftest ob-gptel-test-all-source-blocks-with-result ()
  "Test that block results are captured when present."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session sess-with-result\n")
    (insert "Question\n")
    (insert "#+end_src\n")
    (insert "\n")
    (insert "#+RESULTS:\n")
    (insert ": Answer\n")
    (goto-char (point-max))
    (let ((blocks (ob-gptel--all-source-blocks "sess-with-result")))
      (should (= (length blocks) 1))
      (should (string-match-p "Answer" (plist-get (car blocks) :result))))))

(ert-deftest ob-gptel-test-all-source-blocks-block-after-point ()
  "Test that blocks after point are excluded."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session sess\n")
    (insert "Before point\n")
    (insert "#+end_src\n\n")
    (insert "#+RESULTS:\n\n")
    (insert "#+begin_src gptel :session sess\n")
    (insert "After point\n")
    (insert "#+end_src\n")
    ;; Save the position just past the first block's #+end_src
    (let ((halfway (save-excursion
                     (goto-char (point-min))
                     (search-forward "#+end_src")
                     (point))))
      ;; Now narrow to before the second block so it's excluded.
      (narrow-to-region (point-min) halfway)
      (let ((blocks (ob-gptel--all-source-blocks "sess")))
        (should (= (length blocks) 1))
        (should (equal (plist-get (car blocks) :body) "Before point"))))))

;;; ob-gptel-find-session-param tests

(ert-deftest ob-gptel-test-find-session-param-block-override ()
  "Test that the block's own param takes precedence over session fallback."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session sess :model gpt-3.5\n")
    (insert "First\n")
    (insert "#+end_src\n")
    (insert "\n")
    (insert "#+begin_src gptel :session sess :model gpt-4\n")
    (insert "Second\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    ;; Block params explicitly provide :model, so no fallback needed.
    (should (equal (ob-gptel-find-session-param :model '((:model . "gpt-4o")) "sess")
                   "gpt-4o"))
    ;; Block params explicitly provide :model, session blocks are ignored.
    (should (equal (ob-gptel-find-session-param :model '((:model . "override")) "sess")
                   "override"))))

(ert-deftest ob-gptel-test-find-session-param-fallback-to-session ()
  "Test that nil block param falls back to latest session block value."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session sess :model gpt-3.5\n")
    (insert "First\n")
    (insert "#+end_src\n")
    (insert "\n")
    (insert "#+begin_src gptel :session sess :temperature 0.9\n")
    (insert "Second\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    ;; :model not in block params, should fallback to latest session block.
    (should (equal (ob-gptel-find-session-param :model '((:model)) "sess") "gpt-3.5"))
    ;; :temperature is explicitly set in the latest block (parsed as number).
    (should (equal (ob-gptel-find-session-param :temperature '((:temperature)) "sess")
                   0.9))))

(ert-deftest ob-gptel-test-find-session-param-no-session-match ()
  "Test that nil is returned when no session blocks exist."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session other\nHello\n#+end_src\n")
    (goto-char (point-max))
    (should (null (ob-gptel-find-session-param :model '() "nonexistent")))))

(ert-deftest ob-gptel-test-find-session-param-no-session-param-nil ()
  "Test that nil is returned when block has no param and no session fallback."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel\nHello\n#+end_src\n")
    (goto-char (point-max))
    (should (null (ob-gptel-find-session-param :model '() "any")))))

(ert-deftest ob-gptel-test-find-session-param-fallback-is-latest ()
  "Test that session fallback returns the *latest* defined param."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session sess :model gpt-3.5\n")
    (insert "First\n")
    (insert "#+end_src\n")
    (insert "\n")
    (insert "#+begin_src gptel :session sess :model gpt-4\n")
    (insert "Second\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    ;; The latest block defines :model as gpt-4, so that should win.
    (should (equal (ob-gptel-find-session-param :model '((:model)) "sess")
                   "gpt-4"))))

(ert-deftest ob-gptel-test-find-session-param-covers-inherited-params ()
  "Each inheritable param can be found from prior session history."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session s :model gpt-4 :temperature 0.7 :max-tokens 500 :backend openai :system be-helpful :preset default :context ctx.txt :format markdown\n")
    (insert "one\n")
    (insert "#+end_src\n\n")
    (insert "#+begin_src gptel :session s\n")
    (insert "two\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let ((params '((:session . "s"))))
      (should (equal (ob-gptel-find-session-param :model params "s") "gpt-4"))
      (should (equal (ob-gptel-find-session-param :temperature params "s") 0.7))
      (should (equal (ob-gptel-find-session-param :max-tokens params "s") 500))
      (should (equal (ob-gptel-find-session-param :backend params "s") "openai"))
      (should (equal (ob-gptel-find-session-param :system params "s") "be-helpful"))
      (should (equal (ob-gptel-find-session-param :preset params "s") "default"))
      (should (equal (ob-gptel-find-session-param :context params "s") "ctx.txt"))
      (should (equal (ob-gptel-find-session-param :format params "s") "markdown")))))

(ert-deftest ob-gptel-test-execute-uses-inherited-session-params ()
  "Executor applies inherited params from session history."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session test-sess :model inherited-model :temperature 0.8 :max-tokens 200 :system sys-msg\n")
    (insert "first\n")
    (insert "#+end_src\n\n")
    (insert "#+begin_src gptel :session test-sess\n")
    (insert "question\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let* ((info (org-babel-get-src-block-info))
           (body (nth 1 info))
           (params (nth 2 info))
           captured-model
           captured-temperature
           captured-max-tokens
           captured-system
           captured-format)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest args)
                   (setq captured-model gptel-model)
                   (setq captured-temperature gptel-temperature)
                   (setq captured-max-tokens gptel-max-tokens)
                   (setq captured-system (plist-get args :system))
                   (setq captured-format (plist-get args :format))
                   'fake-fsm))
                ((symbol-function 'org-id-uuid)
                 (lambda () "test-uuid")))
        (should (equal (org-babel-execute:gptel body params)
                       "<gptel_thinking_test-uuid>")))
      (should (equal captured-model 'inherited-model))
      (should (= captured-temperature 0.8))
      (should (= captured-max-tokens 200))
      (should (member "sys-msg" captured-system)))))

(ert-deftest ob-gptel-test-execute-does-not-inherit-tools ()
  ":tools should not be inherited from prior session blocks."
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src gptel :session test-sess :tools \"dangerous-tool\"\n")
    (insert "one\n")
    (insert "#+end_src\n\n")
    (insert "#+begin_src gptel :session test-sess\n")
    (insert "two\n")
    (insert "#+end_src\n")
    (goto-char (point-max))
    (let* ((info (org-babel-get-src-block-info))
           (body (nth 1 info))
           (params (nth 2 info))
           captured-tools)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (_prompt &rest _args)
                   (setq captured-tools gptel-tools)
                   'fake-fsm))
                ((symbol-function 'org-id-uuid)
                 (lambda () "test-uuid")))
        (should (equal (org-babel-execute:gptel body params)
                       "<gptel_thinking_test-uuid>")))
      (should-not captured-tools))))

(provide 'ob-gptel-test)
;;; ob-gptel-test.el ends here
