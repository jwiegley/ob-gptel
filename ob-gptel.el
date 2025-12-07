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
(require 'gptel-request)

(defvar org-babel-default-header-args:gptel
  '((:results . "raw drawer")
    (:exports . "both")
    (:model . nil)
    (:temperature . nil)
    (:max-tokens . nil)
    (:system . nil)
    (:backend . nil)
    (:dry-run . nil)
    (:preset . nil)
    (:media . nil)
    (:context . nil)
    (:tools . nil)
    (:prompt . nil)
    (:session . nil))
  "Default header arguments for gptel source blocks.")

(defun ob-gptel-find-prompt (prompt)
  "Given a PROMPT identifier, find the block/result pair it names.
The result is a directive in the format of `gptel-directives' with
the block as a message in the USER role and the result in the ASSISTANT role.
Note that a system message is not included at the start.
Returns nil when no PROMPT block is found."
  (let ((block (org-babel-find-named-block prompt)))
    (when block
      (save-excursion
        (goto-char block)
        (let ((info (org-babel-get-src-block-info)))
          (when info
            (let ((result (org-babel-where-is-src-block-result nil info)))
              (list (nth 1 info)
                    (when result
                      (goto-char result)
                      (org-babel-read-result))))))))))

(defun ob-gptel--all-source-blocks (session)
  "Return all Source blocks before point with `:session' set to SESSION."
  (org-element-map
      (save-restriction
        (narrow-to-region (point-min) (point))
        (org-element-parse-buffer))
      '(src-block)
    (lambda (element)
      (let ((start (org-element-property :begin element))
            (parameters
             (when (org-element-property :parameters element)
               (org-babel-parse-header-arguments
                (string-trim (org-element-property :parameters element))))))
        (and (<= start (point))
             (equal session (cdr (assq :session parameters)))
             (list :start start
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
                         (org-babel-read-result))))))))))

(defun ob-gptel-find-session (session)
  "Given a SESSION identifier, find the blocks/result pairs it names.
The result is a directive in the format of `gptel-directives', but does not
include a system message at the start. The blocks and their results alternate
in the list as messages in the USER/ASSISTANT roles, respectively."
  (mapcan (lambda (block)
            (list (plist-get block :body) (plist-get block :result)))
          (ob-gptel--all-source-blocks session)))

(defmacro ob-gptel--request-callback (buffer uuid)
  "Create callback for `gptel-request' that replaces the results with
current uuid in buffer."
  `(lambda (response _info)
      (when (stringp response)
        (with-current-buffer ,buffer
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (when (search-forward ,uuid nil t)
                (let* ((match-start (match-beginning 0))
                       (match-end (match-end 0)))
                  (goto-char match-start)
                  (delete-region match-start match-end)
                  (insert response)))))))))

(defun ob-gptel--execute (body params)
  (let* ((model (cdr (assoc :model params)))
         (gptel-model (if model
                       (if (symbolp model) model (intern model))
                     gptel-model))
         (temperature (cdr (assoc :temperature params)))
         (gptel-temperature (if (and temperature (stringp temperature))
                       (string-to-number temperature)
                       gptel-temperature))
         (max-tokens (cdr (assoc :max-tokens params)))
         (gptel-max-tokens (if (and max-tokens (stringp max-tokens))
                               (string-to-number max-tokens)
                     gptel-max-tokens))
         (backend-name (cdr (assoc :backend params)))
         (gptel-backend (if backend-name
                            (gptel-get-backend backend-name)
                          gptel-backend))
         (prompt (cdr (assoc :prompt params)))
         (prompt-directives (when prompt (ob-gptel-find-prompt prompt)))
         (session (cdr (assoc :session params)))
         (session-directives (when session (ob-gptel-find-session session)))
         (system-message (cdr (assoc :system params)))
         (gptel--system-message (or system-message gptel--system-message))
         (directives (append (list gptel--system-message)
                             session-directives prompt-directives))
         (media (cdr (assoc :media params)))
         (gptel-track-media (not (member media '("no" "nil" nil))))
         (context (cdr (assoc :context params)))
         (gptel-context (if context
                            (append gptel-context (split-string context))
                          gptel-context))
         (tools (cdr (assoc :tools params)))
         (gptel-tools (when tools
                        (mapcar (lambda (tool-name)
                                  (or (gptel-get-tool tool-name)
                                      (error "Tool %s not found" tool-name)))
                                (split-string tools))))
         (dry-run (cdr (assoc :dry-run params)))
         (dry-run (not (member dry-run '("no" "nil" nil))))
         (uuid (concat "<gptel_thinking_" (org-id-uuid) ">"))
         (buffer (current-buffer))
         (fsm (gptel-request body
                :callback (ob-gptel--request-callback buffer uuid)
                :transforms '(gptel--transform-add-context)
                :system directives
                :dry-run dry-run)))
    (if dry-run
        (thread-first
          fsm
          (gptel-fsm-info)
          (plist-get :data)
          (pp-to-string))
      uuid)))

(defun org-babel-execute:gptel (body params)
  "Execute a gptel source block with BODY and PARAMS.
This function sends the BODY text to GPTel and returns the response."
  (let ((preset (intern-soft (cdr (assoc :preset params)))))
    (if preset
        (gptel-with-preset preset (ob-gptel--execute body params))
      (ob-gptel--execute body params))))

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
                          ("media"  . "Send the contents of all linked, supported files?")
                          ("context" . "List of files to include")
                          ("tools"   . "List of tool names to use"))))
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
                         ("media" (cons (list "t" "nil") (lambda (_) "" "Boolean")))
                         ("tools" (cons (and (boundp 'gptel--known-tools)
                                             (mapcar #'car gptel--known-tools))
                                        (lambda (t-name)
                                          (and (boundp 'gptel--known-tools)
                                               (when-let ((tool (alist-get
                                                                 (intern t-name)
                                                                 gptel--known-tools)))
                                                 (gptel-tool-description tool))))))
                         ("dry-run" (cons (list "t" "nil") (lambda (_) "" "Boolean"))))))
            (list start end (all-completions word (car comp-and-annotation))
                  :exclusive 'no
                  :annotation-function (cdr comp-and-annotation))))))))

(with-eval-after-load 'org-src
  (add-to-list 'org-src-lang-modes '("gptel" . org)))

(provide 'ob-gptel)

;;; ob-gptel.el ends here
