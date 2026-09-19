;;; ellm-gptel.el --- gptel adapter for ELLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Lightweight ELLM conversations reuse gptel instead of growing another
;; provider client.  This adapter maps explicit ELLM conversations, model
;; selection, pure tools and cache policy onto gptel's programmatic API.
;;
;; Manual provider prompt caching is passed through to `gptel-cache'.  ELLM
;; uses a provider-neutral policy and normalizes plural aliases such as
;; `tools' and `messages' to gptel's `tool' and `message' keys.
;;
;; Effectful tools are deliberately not exposed through direct gptel requests.
;; They belong behind the Consortium/Prolog-RLM authority bridge.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ellm)
(require 'ellm-tools)

(declare-function gptel-request "gptel-request" (&optional prompt &rest args))
(declare-function gptel-make-tool "gptel-request" (&rest slots))
(declare-function gptel-tool-name "gptel-request" (tool))
(declare-function gptel-tool-args "gptel-request" (tool))
(declare-function gptel-tool-function "gptel-request" (tool))
(declare-function ai/prompt-lib-template-read "prompt-lib" (name))

(defvar ellm-prompt-resolver-function nil
  "Optional function used by `ellm-prompt' for named prompt objects.")

(defvar ellm-gptel-backend-resolver-function nil
  "Optional function mapping an ELLM actor to a concrete gptel backend.")

(defvar ellm-gptel-model-resolver-function nil
  "Optional function mapping an ELLM actor to a concrete gptel model.")

(defun ellm-prompt (prompt)
  "Resolve PROMPT to a string.

Strings are treated as literal prompts.  Functions are called with no
arguments.  Other values are delegated to
`ellm-prompt-resolver-function'."
  (cond
   ((stringp prompt) prompt)
   ((functionp prompt)
    (let ((value (funcall prompt)))
      (unless (stringp value)
        (error "ELLM prompt function returned non-string: %S" value))
      value))
   ((functionp ellm-prompt-resolver-function)
    (let ((value (funcall ellm-prompt-resolver-function prompt)))
      (unless (stringp value)
        (error "ELLM prompt resolver returned non-string: %S" value))
      value))
   (t
    (error "No ELLM prompt resolver for %S" prompt))))

(defun ellm-prompt-lib-resolver (name)
  "Resolve prompt library NAME through the existing dotfiles prompt API."
  (unless (fboundp 'ai/prompt-lib-template-read)
    (unless (require 'prompt-lib nil t)
      (error "prompt-lib is not available on load-path")))
  (ai/prompt-lib-template-read
   (if (symbolp name) (symbol-name name) name)))

(defun ellm-enable-prompt-lib ()
  "Use the existing `prompt-lib' package for named ELLM prompts."
  (unless (fboundp 'ai/prompt-lib-template-read)
    (unless (require 'prompt-lib nil t)
      (error "prompt-lib is not available on load-path")))
  (setq ellm-prompt-resolver-function #'ellm-prompt-lib-resolver))

(defun ellm-gptel-cache-policy (policy)
  "Normalize provider-neutral cache POLICY to gptel cache keys."
  (cond
   ((or (null policy) (eq policy t)) policy)
   ((listp policy)
    (delete-dups
     (mapcar
      (lambda (item)
        (pcase item
          ((or 'message 'messages) 'message)
          ((or 'tool 'tools) 'tool)
          ((or 'system 'systems) 'system)
          (_ (error "Unknown ELLM cache policy item: %S" item))))
      policy)))
   (t
    (error "Invalid ELLM cache policy: %S" policy))))

(defun ellm-gptel--ensure-request-api ()
  "Ensure gptel's programmatic request API is available."
  (unless (fboundp 'gptel-request)
    (unless (require 'gptel-request nil t)
      (error "gptel-request is not available"))))

(defun ellm-gptel--ensure-tool-api ()
  "Ensure gptel's tool constructors are available."
  (unless (fboundp 'gptel-make-tool)
    (unless (or (require 'gptel-request nil t)
                (require 'gptel nil t))
      (error "gptel tool API is not available")))
  (unless (fboundp 'gptel-make-tool)
    (error "gptel-make-tool is not available")))

(defun ellm-gptel--model (actor)
  "Return concrete gptel model for ACTOR."
  (cond
   ((functionp ellm-gptel-model-resolver-function)
    (funcall ellm-gptel-model-resolver-function actor))
   ((stringp (ellm-actor-model actor))
    (intern (ellm-actor-model actor)))
   (t
    (ellm-actor-model actor))))

(defun ellm-gptel--backend (actor)
  "Return concrete gptel backend for ACTOR, or the current gptel backend."
  (or
   (and (functionp ellm-gptel-backend-resolver-function)
        (funcall ellm-gptel-backend-resolver-function actor))
   (plist-get (ellm-actor-metadata actor) :gptel-backend)
   (and (boundp 'gptel-backend) (symbol-value 'gptel-backend))))

(defun ellm-gptel--content-string (value)
  "Serialize explicit ELLM VALUE at the provider boundary."
  (if (stringp value)
      value
    (prin1-to-string value)))

(defun ellm-gptel--prompt-sequence (request)
  "Return gptel conversation sequence for REQUEST."
  (let* ((conversation (ellm-request-conversation request))
         (messages (ellm-conversation-messages conversation))
         (input (ellm-request-input request))
         (last-index (1- (length messages))))
    (cl-loop
     for message in messages
     for index from 0
     for role = (alist-get 'role message)
     for content = (ellm-gptel--content-string
                    (alist-get 'content message))
     collect
     (if (and input
              (= index last-index)
              (eq role 'user))
         (concat
          content
          "\n\nELLM current input:\n"
          (ellm-gptel--content-string input))
       content))))

(defun ellm-gptel--schema (tool)
  "Return gptel argument schema for ELLM TOOL."
  (or
   (ellm-tool-schema tool)
   (let ((named
          (cl-remove-if
           (lambda (symbol)
             (or (memq symbol
                       '(input &optional &rest &key &allow-other-keys &aux))
                 (keywordp symbol)))
           (ellm-tool-arglist tool))))
     (if named
         (error "ELLM tool %S needs :schema for gptel arguments"
                (ellm-tool-name tool))
       nil))))

(defun ellm-gptel--values-alist (schema values)
  "Pair gptel SCHEMA argument names with positional VALUES."
  (cl-loop
   for spec in schema
   for value in values
   collect
   (cons
    (intern
     (let ((name (plist-get spec :name)))
       (if (symbolp name) (symbol-name name) name)))
    value)))

(defun ellm-gptel--tool-spec (request tool-name)
  "Build one request-scoped gptel tool for ELLM TOOL-NAME."
  (ellm-gptel--ensure-tool-api)
  (let* ((tool (ellm-tool tool-name))
         (schema (ellm-gptel--schema tool)))
    (unless (eq (ellm-tool-effect tool) 'pure)
      (error
       "Effectful ELLM tool %S cannot be exposed through direct gptel"
       tool-name))
    (gptel-make-tool
     :name (symbol-name tool-name)
     :description (or (ellm-tool-description tool)
                      (format "ELLM tool %s" tool-name))
     :args (copy-tree schema)
     :category "ellm"
     :include nil
     :function
     (lambda (&rest values)
       (ellm-request-call-tool
        request
        tool-name
        (ellm-gptel--values-alist schema values))))))

(defun ellm-gptel--tool-specs (request)
  "Build gptel tool specs declared on REQUEST."
  (mapcar
   (lambda (name) (ellm-gptel--tool-spec request name))
   (ellm-request-tools request)))

(defun ellm-gptel--tool-arg-values (tool args)
  "Map gptel tool call ARGS into positional values for TOOL."
  (mapcar
   (lambda (spec)
     (let* ((name (plist-get spec :name))
            (key
             (intern
              (concat
               ":"
               (if (symbolp name) (symbol-name name) name)))))
       (plist-get args key)))
   (gptel-tool-args tool)))

(defun ellm-gptel--tool-result-value (value)
  "Return VALUE in a form suitable for gptel tool continuation."
  (if (stringp value) value value))

(defun ellm-gptel--run-tool-calls (_request calls)
  "Execute pure request-scoped gptel CALLS and continue each one."
  (dolist (call calls)
    (pcase-let ((`(,tool ,args ,continue) call))
      (let ((result
             (condition-case error-data
                 (apply
                  (gptel-tool-function tool)
                  (ellm-gptel--tool-arg-values tool args))
               (ellm-tool-error
                `((error . ,(cadr error-data))))
               (error
                `((error
                   . ((kind . "gptel_tool_adapter_error")
                      (message
                       . ,(error-message-string error-data)))))))))
        (funcall continue (ellm-gptel--tool-result-value result))))))

(defun ellm-gptel--callback (request deliver)
  "Create gptel callback for ELLM REQUEST and DELIVER."
  (lambda (response info)
    (cond
     ((stringp response)
      (funcall deliver response nil))
     ((eq response 'abort)
      (funcall
       deliver nil
       '((kind . "gptel_abort"))))
     ((and (consp response) (eq (car response) 'tool-call))
      (ellm-gptel--run-tool-calls request (cdr response)))
     ((and (consp response)
           (memq (car response) '(tool-result reasoning)))
      nil)
     ((null response)
      (funcall
       deliver nil
       `((kind . "gptel_error")
         (status . ,(plist-get info :status)))))
     (t nil))))

(defun ellm-gptel-backend-request (request deliver)
  "Submit ELLM REQUEST through gptel and call DELIVER on completion."
  (ellm-gptel--ensure-request-api)
  (let* ((actor (ellm-request-actor request))
         (backend (ellm-gptel--backend actor))
         (model (or (ellm-gptel--model actor)
                    (and (boundp 'gptel-model)
                         (symbol-value 'gptel-model))))
         (cache (ellm-gptel-cache-policy (ellm-request-cache request)))
         (tools (ellm-gptel--tool-specs request))
         (bindings
          '(gptel-backend
            gptel-model
            gptel-cache
            gptel-tools
            gptel-use-tools
            gptel-use-context))
         (values
          (list backend model cache tools (and tools t) nil)))
    (cl-progv bindings values
      (gptel-request
       (ellm-gptel--prompt-sequence request)
       :system (ellm-request-system request)
       :stream nil
       :callback (ellm-gptel--callback request deliver)))))

(ellm-register-backend 'gptel #'ellm-gptel-backend-request)

(provide 'ellm-gptel)
;;; ellm-gptel.el ends here
