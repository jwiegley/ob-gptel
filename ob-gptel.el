;;; ob-gptel.el --- Org-babel backend for GPTel AI interactions -*- lexical-binding: t -*-

;; Copyright (C) 2025 John Wiegley

;; Author: John Wiegley
;; Keywords: org, babel, ai, gptel
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1") (org "9.0") (gptel "0.9.8.5"))

;;; Commentary:

;; This package provides an Org-babel backend for GPTel, allowing
;; AI interactions directly within Org mode source blocks.
;;
;; Usage:
;;   #+begin_src gptel :model gpt-4 :temperature 0.7
;;   What is the capital of France?
;;   #+end_src

;;; Code:

(require 'ob)
(require 'gptel)

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
         (buffer (current-buffer))
         (dry-run (and dry-run (not (member dry-run '("no" "nil" "false")))))
         (ob-gptel--uuid (concat "<gptel_thinking_" (org-id-uuid) ">"))
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
              (gptel-request
                  body
                :callback
                #'(lambda (response _info)
                    (when (stringp response)
                      (with-current-buffer buffer
                        (save-excursion
                          (save-restriction
                            (widen)
                            (goto-char (point-min))
                            (when (search-forward ob-gptel--uuid nil t)
                              (let* ((match-start (match-beginning 0))
                                     (match-end (match-end 0))
                                     (formatted-response
                                      (if (equal format "org")
                                          (gptel--convert-markdown->org (string-trim response))
                                        (string-trim response))))
                                (goto-char match-start)
                                (delete-region match-start match-end)
                                (insert formatted-response))))))))
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
                      (system-message system-message))
                :dry-run dry-run
                :stream nil)))))
    (if dry-run
        (thread-first
          fsm
          (gptel-fsm-info)
          (plist-get :data)
          (pp-to-string))
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
                         ("format" (cons (list "markdown" "org") (lambda (_) "" "Output format"))))))
            (list start end (all-completions word (car comp-and-annotation))
                  :exclusive 'no
                  :annotation-function (cdr comp-and-annotation))))))))

(with-eval-after-load 'org-src
  (add-to-list 'org-src-lang-modes '("gptel" . text)))

(provide 'ob-gptel)

;;; ob-gptel.el ends here
