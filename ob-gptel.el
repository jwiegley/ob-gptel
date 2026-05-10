;;; ob-gptel.el --- Org-babel backend for GPTel AI interactions -*- lexical-binding: t -*-

;; Copyright (C) 2025 John Wiegley

;; Author: John Wiegley
;; URL: https://github.com/jwiegley/ob-gptel
;; Keywords: comm processes
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1") (gptel "0.9.8.5"))

;;; Commentary:

;; This package provides an Org-babel backend for GPTel, allowing
;; AI interactions directly within Org mode source blocks.
;;
;; Usage:
;;   #+begin_src gptel :model gpt-4 :temperature 0.7
;;   What is the capital of France?
;;   #+end_src
;;
;; Header arguments include :model, :temperature, :max-tokens, :system,
;; :backend, :preset, :context (files), :prompt (named block as prior
;; turn), :session (id linking earlier blocks as prior turns), :format
;; (\"org\" or \"markdown\"), :dry-run (inspect payload), and :entry
;; (when t, prepend the prose preceding the block in its enclosing org
;; entry to the body — handy for \"summarize the above\" style queries).

;;; Code:

(require 'ob)
(require 'org-element)
(require 'gptel)

;; Optional: when available, use the `pending' library for async
;; placeholders instead of the UUID search/replace fallback.
(require 'pending nil t)

;; Forward declarations to keep the byte-compiler quiet when the
;; optional `pending' library is not loaded.  When `pending' is
;; available these resolve to its real definitions; otherwise the
;; helpers that reference them are guarded by `ob-gptel--use-pending-p'.
(declare-function pending-make "pending"
                  (buffer &rest keys))
(declare-function pending-finish "pending" (token text))
(declare-function pending-reject "pending" (token reason &optional replacement-text))
(declare-function pending-active-p "pending" (token))
(declare-function pending-buffer "pending" (token))
(declare-function gptel-abort "gptel" (buf))

(defvar org-babel-default-header-args:gptel
  '((:results . "replace")
    (:exports . "both")
    (:model . nil)
    (:temperature . nil)
    (:max-tokens . nil)
    (:system . nil)
    (:backend . nil)
    (:dry-run . nil)
    (:preset . nil)
    (:context . nil)
    (:prompt . nil)
    (:session . nil)
    (:entry . nil)
    (:format . "org"))
  "Default header arguments for gptel source blocks.")

(defun ob-gptel-find-prompt (prompt &optional system-message)
  "Given a PROMPT identifier, find the block/result pair it names.
The result is a directive in the format of `gptel-directives', which
includes the SYSTEM-MESSAGE, the block as a message in the USER role,
and the result in the ASSISTANT role."
  (let ((directives (list system-message)))
    (let ((block (org-babel-find-named-block prompt)))
      (when block
        (save-excursion
          (goto-char block)
          (let ((info (and block
                           (save-excursion
                             (goto-char block)
                             (org-babel-get-src-block-info)))))
            (when info
              (nconc directives (list (and info (nth 1 info))))
              (let ((result (org-babel-where-is-src-block-result nil info)))
                (when result
                  (goto-char result)
                  (nconc directives (list (org-babel-read-result))))))))))
    directives))

(defun ob-gptel--all-source-blocks (session)
  "Return all Source blocks before point with `:session' set to SESSION."
  (org-element-map
   (save-restriction
     (narrow-to-region (point-min) (point))
     (org-element-parse-buffer))
   '(src-block fixed-width)
   (lambda (element)
     (cond ((eq (org-element-type element) 'src-block)
            (let ((start
                   (org-element-property :begin element))
                  (language
                   (when (org-element-property :language element)
                     (string-trim (org-element-property :language element))))
                  (parameters
                   (when (org-element-property :parameters element)
                     (org-babel-parse-header-arguments
                      (string-trim (org-element-property :parameters element))))))
              (and (<= start (point))
                   (equal session (cdr (assq :session parameters)))
                   (list :start start
                         :language language
                         :parameters parameters
                         :body
                         (when (org-element-property :value element)
                           (string-trim (org-element-property :value element)))
                         :result
                         (save-excursion
                           (save-restriction
                             (goto-char (org-element-property :begin element))
                             (when (org-babel-where-is-src-block-result)
                               (goto-char (org-babel-where-is-src-block-result))
                               (org-babel-read-result))))))))))))

(defun ob-gptel-find-session (session &optional system-message)
  "Given a SESSION identifier, find the blocks/result pairs it names.
The result is a directive in the format of `gptel-directives', which
includes the SYSTEM-MESSAGE, and the blocks and their results as
messages in the USER/ASSISTANT roles, respectively."
  (let ((directives (list system-message)))
    (let ((blocks (ob-gptel--all-source-blocks session)))
      (dolist (block blocks)
        (save-excursion
          (nconc directives (list (plist-get block :body)))
          (let ((result (plist-get block :result)))
            (if result
                (nconc directives (list result))
              (nconc directives (list "\n")))))))
    directives))

;; Use gptel's built-in markdown to org converter
(declare-function gptel--convert-markdown->org "gptel-org")
(require 'gptel-org nil t) ;; Optional require for markdown->org conversion

(defun ob-gptel--add-context (context)
  "Call `gptel--transform-add-context' with the given CONTEXT."
  `(lambda (callback fsm)
     (setq-local gptel-context--alist
                 (quote ,(if (stringp context)
                             (list (list context))
                           (mapcar #'list context))))
     (gptel--transform-add-context callback fsm)))

(defmacro ob-gptel--with-preset (name &rest body)
  "Run BODY with gptel preset NAME applied.
This macro can be used to create `gptel-request' command with settings
from a gptel preset applied.  NAME is the preset name, typically a
symbol."
  (declare (indent 1))
  `(let ((name ,name))
     (cl-progv (and name (gptel--preset-syms (gptel-get-preset name)))
         nil
       (if name (gptel--apply-preset name))
       ,@body)))

(defun ob-gptel--entry-text-before-block ()
  "Return entry text from the heading body up to the current src block.
The returned string spans from `org-end-of-meta-data' of the
enclosing heading (which skips the heading line itself, PROPERTIES,
planning lines, and LOGBOOK) to the `:begin' of the src block at
point.  When no enclosing heading exists, the start is `point-min'.
The result is trimmed; returns nil when the region is empty."
  (save-excursion
    (let* ((element (org-element-context))
           (src-begin
            (cond
             ((and element
                   (memq (org-element-type element)
                         '(src-block inline-src-block)))
              (org-element-property :begin element))
             ;; Fallback: search backward from point for #+begin_src gptel.
             ((save-excursion
                (re-search-backward
                 "^[ \t]*#\\+begin_src[ \t]+gptel" nil t))))))
      (when src-begin
        (let ((entry-start
               (save-excursion
                 (goto-char src-begin)
                 (if (and (derived-mode-p 'org-mode)
                          (ignore-errors (org-back-to-heading t)))
                     (progn
                       ;; Skip heading line + planning + drawers.
                       (org-end-of-meta-data t)
                       (point))
                   (point-min)))))
          (when (< entry-start src-begin)
            (let ((text (string-trim
                         (buffer-substring-no-properties
                          entry-start src-begin))))
              (and (not (string-empty-p text)) text))))))))

;;; Pending integration helpers

(defun ob-gptel--use-pending-p ()
  "Return non-nil when the `pending' library is loadable."
  (featurep 'pending))

(defun ob-gptel--legacy-replace (uuid buffer text)
  "In BUFFER, find UUID and atomically replace it with TEXT."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (when (search-forward uuid nil t)
            (let ((s (match-beginning 0))
                  (e (match-end 0)))
              (goto-char s)
              (delete-region s e)
              (insert text))))))))

(defun ob-gptel--format-response (response format)
  "Trim RESPONSE and convert markdown->org if FORMAT equals \"org\"."
  (let ((trimmed (string-trim response)))
    (if (equal format "org")
        (gptel--convert-markdown->org trimmed)
      trimmed)))

(defun ob-gptel--adopt-pending (uuid buffer label cell)
  "Find UUID in BUFFER and adopt its region as a pending placeholder.
Store the resulting token in (car CELL) and return it.  No-op if the
pending library is not loaded, BUFFER is dead, or UUID cannot be
found."
  (when (and (ob-gptel--use-pending-p)
             (buffer-live-p buffer))
    (with-current-buffer buffer
      (save-excursion
        (save-restriction
          (widen)
          (goto-char (point-min))
          (when (search-forward uuid nil t)
            (let* ((s (copy-marker (match-beginning 0)))
                   (e (copy-marker (match-end 0)))
                   (token
                    (pending-make
                     buffer
                     :start s
                     :end e
                     :label label
                     :indicator :spinner
                     :on-cancel
                     (lambda (p)
                       (let ((buf (pending-buffer p)))
                         (when (buffer-live-p buf)
                           (with-current-buffer buf
                             (when (fboundp 'gptel-abort)
                               (gptel-abort buf)))))))))
              (setcar cell token)
              token)))))))

(defun ob-gptel--make-callback (uuid buffer format cell)
  "Return a gptel callback closure for an async block.
The callback uses the pending token in (car CELL) when active;
otherwise it falls back to UUID-based search/replace.
UUID, BUFFER, and FORMAT are the values captured at request time."
  (lambda (response info)
    (let ((token (car cell)))
      (cond
       ((stringp response)
        (let ((text (ob-gptel--format-response response format)))
          (if (and token
                   (ob-gptel--use-pending-p)
                   (pending-active-p token))
              (pending-finish token text)
            (ob-gptel--legacy-replace uuid buffer text))))
       ;; gptel signals abort by calling the callback with the
       ;; symbol `abort'.  Leave the placeholder for `gptel-abort'
       ;; to clean up via the on-cancel path; do nothing here.
       ((eq response 'abort) nil)
       (t
        (let ((reason (or (and (listp info) (plist-get info :error))
                          "gptel error")))
          (if (and token
                   (ob-gptel--use-pending-p)
                   (pending-active-p token))
              (pending-reject token (format "%s" reason))
            (ob-gptel--legacy-replace
             uuid buffer
             (format "(gptel error: %s)" reason)))))))))

(defun org-babel-execute:gptel (body params)
  "Execute a gptel source block with BODY and PARAMS.
This function sends the BODY text to GPTel and returns the response."
  (let* ((model (cdr (assoc :model params)))
         (temperature (cdr (assoc :temperature params)))
         (max-tokens (cdr (assoc :max-tokens params)))
         (system-message (cdr (assoc :system params)))
         (backend-name (cdr (assoc :backend params)))
         (prompt (cdr (assoc :prompt params)))
         (session (cdr (assoc :session params)))
         (preset (cdr (assoc :preset params)))
         (context (cdr (assoc :context params)))
         (format (cdr (assoc :format params)))
         (dry-run (cdr (assoc :dry-run params)))
         (entry (cdr (assoc :entry params)))
         (buffer (current-buffer))
         (dry-run (and dry-run (not (member dry-run '("no" "nil" "false")))))
         (entry (and entry (not (member entry '("no" "nil" "false")))))
         (effective-body
          (if entry
              (let ((prefix
                     (with-current-buffer buffer
                       (save-excursion
                         (ob-gptel--entry-text-before-block)))))
                (if prefix (concat prefix "\n\n" body) body))
            body))
         (ob-gptel--uuid (concat "<gptel_thinking_" (org-id-uuid) ">"))
         ;; Shared cell for communicating the pending token between
         ;; the adoption hook and the gptel callback.
         (cell (cons nil nil))
         ;; Captured below inside the `let' that rebinds gptel-model
         ;; so that presets / params have already taken effect.
         (resolved-model nil)
         (fsm
          (ob-gptel--with-preset (and preset (intern-soft preset))
				 (let ((gptel-model
					(if model
					    (if (symbolp model) model (intern model))
					  gptel-model))
				       (gptel-temperature
					(if (and temperature (stringp temperature))
					    (string-to-number temperature)
					  gptel-temperature))
				       (gptel-max-tokens
					(if (and max-tokens (stringp max-tokens))
					    (string-to-number max-tokens)
					  gptel-max-tokens))
				       (gptel--system-message
					(or system-message
					    gptel--system-message))
				       (gptel-backend
					(if backend-name
					    (let ((backend (gptel-get-backend backend-name)))
					      (if backend
						  (setq-local gptel-backend backend)
						gptel-backend))
					  gptel-backend)))
				   (setq resolved-model gptel-model)
				   (gptel-request
				    effective-body
				    :callback
				    (ob-gptel--make-callback
				     ob-gptel--uuid buffer format cell)
				    :buffer (current-buffer)
				    :transforms (list #'gptel--transform-apply-preset
						      (ob-gptel--add-context context))
				    :system
				    (cond (prompt
					   (with-current-buffer buffer
					     (ob-gptel-find-prompt prompt system-message)))
					  (session
					   (with-current-buffer buffer
					     (ob-gptel-find-session session system-message)))
					  (t system-message))
				    :dry-run dry-run
				    :stream nil)))))
    (if dry-run
        (thread-first
         fsm
         (gptel-fsm-info)
         (plist-get :data)
         (pp-to-string))
      ;; When `pending' is loaded, schedule a one-shot, buffer-local
      ;; hook to adopt the inserted UUID region as a placeholder once
      ;; org-babel has finished writing the result.
      (when (ob-gptel--use-pending-p)
        (let* ((uuid ob-gptel--uuid)
               (label (format "gptel: %s" (or resolved-model "gptel")))
               (adopt-cell cell)
               (target-buffer buffer)
               adopt-fn)
          (setq adopt-fn
                (lambda ()
                  (remove-hook 'org-babel-after-execute-hook adopt-fn t)
                  (ob-gptel--adopt-pending
                   uuid target-buffer label adopt-cell)))
          (with-current-buffer buffer
            (add-hook 'org-babel-after-execute-hook adopt-fn nil t))))
      ob-gptel--uuid)))

(defun org-babel-prep-session:gptel (session _params)
  "Prepare SESSION according to PARAMS.
GPTel blocks don't use sessions, so this is a no-op."
  session)

(defun ob-gptel-var-to-gptel (var)
  "Convert an elisp VAR into a string for GPTel."
  (format "%S" var))

(defun org-babel-variable-assignments:gptel (params)
  "Return list of GPTel statements assigning variables from PARAMS."
  (mapcar
   (lambda (pair)
     (format "%s = %s"
             (car pair)
             (ob-gptel-var-to-gptel (cdr pair))))
   (org-babel--get-vars params)))

;;; This function courtesy Karthik Chikmagalur <karthik.chikmagalur@gmail.com>
(defun ob-gptel-capf ()
  (save-excursion
    (when (and (equal (org-thing-at-point) '("block-option" . "src"))
               (save-excursion
                 (re-search-backward "src[ \t]+gptel" (line-beginning-position) t)))
      (let* (start (end (point))
                   (word (buffer-substring-no-properties ;word being completed
                          (progn (skip-syntax-backward "_w") (setq start (point))) end))
                   (header-arg-p (eq (char-before) ?:))) ;completing a :header-arg?
        (if header-arg-p
            (let ((args '(("backend" . "The gptel backend to use")
                          ("model"   . "The model to use")
                          ("preset"  . "Use gptel preset")
                          ("dry-run" . "Don't send, instead return payload?")
                          ("system"  . "System message for request")
                          ("prompt"  . "Include result of other block")
                          ("context" . "List of files to include")
                          ("entry"   . "Include preceding entry text")
                          ("format"  . "Output format: markdown or org"))))
              (list start end (all-completions word args)
                    :annotation-function #'(lambda (c) (cdr-safe (assoc c args)))
                    :exclusive 'no))
          ;; Completing the value of a header-arg
          (when-let* ((key (and (re-search-backward ;capture header-arg being completed
                                 ":\\([^ \t]+?\\) +" (line-beginning-position) t)
                                (match-string 1)))
                      (comp-and-annotation
                       (pcase key ;generate completion table and annotation function for key
                         ("backend" (list gptel--known-backends))
                         ("model"
                          (cons (gptel-backend-models
                                 (save-excursion ;find backend being used, or
                                   (forward-line 0)
                                   (if (re-search-forward
                                        ":backend +\\([^ \t]+\\)" (line-end-position) t)
                                       (gptel-get-backend (match-string 1))
                                     gptel-backend))) ;fall back to buffer backend
                                (lambda (m) (get (intern m) :description))))
                         ("preset" (cons gptel--known-presets
                                         (lambda (p) (thread-first
                                                      (cdr (assq (intern p) gptel--known-presets))
                                                      (plist-get :description)))))
                         ("dry-run" (cons (list "t" "nil") (lambda (_) "" "Boolean")))
                         ("entry" (cons (list "t" "nil") (lambda (_) "" "Boolean")))
                         ("format" (cons (list "markdown" "org") (lambda (_) "" "Output format"))))))
            (list start end (all-completions word (car comp-and-annotation))
                  :exclusive 'no
                  :annotation-function (cdr comp-and-annotation))))))))

(add-to-list 'org-src-lang-modes '("gptel" . text))

(provide 'ob-gptel)

;;; ob-gptel.el ends here
