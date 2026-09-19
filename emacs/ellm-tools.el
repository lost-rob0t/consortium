;;; ellm-tools.el --- LLM-callable tool registry for ELLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; ELLM tools are real functions callable by an LLM adapter.  A tool receives
;; the current ELLM value as its default `input'.  Arguments supplied by the
;; model are merged on top, so an explicit input argument overrides that
;; default.
;;
;; Pure tools may execute locally in Emacs.  Effectful tools never execute
;; their local implementation through this dispatcher; they must be admitted
;; by `ellm-effect-dispatch-function', which is supplied by the
;; Consortium/Prolog-RLM bridge.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'ellm)

(cl-defstruct (ellm-tool (:constructor ellm--make-tool))
  "Definition of one LLM-callable ELLM tool."
  name description arglist schema effect function metadata)

(defvar ellm--tools (make-hash-table :test #'eq)
  "Registry of ELLM tools keyed by symbol.")

(defvar ellm-effect-dispatch-function nil
  "Authority bridge for effectful ELLM tools.

When non-nil, this function is called as
(FUNCTION TOOL ARGUMENTS INPUT REQUEST).  TOOL is the tool symbol,
ARGUMENTS is a normalized alist excluding any explicit input argument,
INPUT is the resolved current/explicit input, and REQUEST is optional
backend/request context.")

(define-error 'ellm-tool-error "ELLM tool invocation failed")

(defun ellm-register-tool (name &rest properties)
  "Register ELLM tool NAME from PROPERTIES and return it.

Recognized properties are :description, :arglist, :schema, :effect,
:function and :metadata.  Tools default to the conservative
`effectful' class unless explicitly marked `pure'."
  (unless (symbolp name)
    (signal 'wrong-type-argument (list 'symbolp name)))
  (let ((function (plist-get properties :function))
        (effect (or (plist-get properties :effect) 'effectful)))
    (unless (functionp function)
      (signal 'wrong-type-argument (list 'functionp function)))
    (unless (memq effect '(pure effectful))
      (error "Unknown ELLM tool effect class: %S" effect))
    (let ((tool
           (ellm--make-tool
            :name name
            :description (plist-get properties :description)
            :arglist (copy-tree (plist-get properties :arglist))
            :schema (plist-get properties :schema)
            :effect effect
            :function function
            :metadata (plist-get properties :metadata))))
      (puthash name tool ellm--tools)
      tool)))

(defmacro ellm-def-tool (name arglist &rest forms)
  "Define and register LLM-callable tool NAME.

ARGLIST is the implementation lambda list.  Leading keyword/value pairs in
FORMS configure the tool:

  :description STRING
  :schema      VALUE
  :effect      'pure or 'effectful
  :metadata    VALUE

The remaining FORMS are the tool implementation body."
  (declare (indent 2))
  (let ((description nil)
        (schema nil)
        (effect ''effectful)
        (metadata nil))
    (while (keywordp (car forms))
      (let ((key (pop forms)))
        (unless forms
          (error "Missing value for ELLM tool option %S" key))
        (pcase key
          (:description (setq description (pop forms)))
          (:schema (setq schema (pop forms)))
          (:effect (setq effect (pop forms)))
          (:metadata (setq metadata (pop forms)))
          (_ (error "Unknown ELLM tool option %S" key)))))
    `(ellm-register-tool
      ',name
      :description ,description
      :arglist ',arglist
      :schema ,schema
      :effect ,effect
      :metadata ,metadata
      :function (cl-function (lambda ,arglist ,@forms)))))

(defun ellm-tool (tool)
  "Resolve TOOL to an `ellm-tool' object."
  (cond
   ((ellm-tool-p tool) tool)
   ((symbolp tool)
    (or (gethash tool ellm--tools)
        (error "Unknown ELLM tool: %S" tool)))
   (t
    (signal 'wrong-type-argument (list '(or symbol ellm-tool) tool)))))

(defun ellm-tool-accepts-input-p (tool)
  "Return non-nil when TOOL's lambda list explicitly accepts `input'."
  (memq 'input (ellm-tool-arglist (ellm-tool tool))))

(defun ellm--tool-key-symbol (key)
  "Normalize tool argument KEY to an uninterned-independent symbol."
  (cond
   ((keywordp key)
    (intern (substring (symbol-name key) 1)))
   ((symbolp key) key)
   ((stringp key) (intern key))
   (t
    (signal 'wrong-type-argument
            (list '(or symbol string) key)))))

(defun ellm--tool-arguments-alist (arguments)
  "Normalize model ARGUMENTS to a symbol-keyed alist."
  (cond
   ((null arguments) nil)
   ((hash-table-p arguments)
    (let (result)
      (maphash
       (lambda (key value)
         (push (cons (ellm--tool-key-symbol key) value) result))
       arguments)
      (nreverse result)))
   ((and (listp arguments)
         (or (null arguments) (keywordp (car arguments))))
    (let (result)
      (while arguments
        (let ((key (pop arguments)))
          (unless arguments
            (error "Odd ELLM tool argument plist"))
          (push (cons (ellm--tool-key-symbol key) (pop arguments))
                result)))
      (nreverse result)))
   ((listp arguments)
    (mapcar
     (lambda (entry)
       (unless (consp entry)
         (error "Invalid ELLM tool argument entry: %S" entry))
       (cons (ellm--tool-key-symbol (car entry)) (cdr entry)))
     arguments))
   (t
    (signal 'wrong-type-argument
            (list '(or list hash-table) arguments)))))

(defun ellm--tool-keyword-plist (arguments)
  "Convert symbol-keyed alist ARGUMENTS to a keyword plist."
  (let (result)
    (dolist (entry arguments (nreverse result))
      (push (intern (concat ":" (symbol-name (car entry)))) result)
      (push (cdr entry) result))))

(defun ellm--signal-tool-error (kind tool &optional message data)
  "Signal structured tool error KIND for TOOL."
  (signal
   'ellm-tool-error
   (list
    `((kind . ,kind)
      (tool . ,tool)
      ,@(when message `((message . ,message)))
      ,@(when data `((data . ,data)))))))

(defun ellm-call-tool (tool arguments current-input &optional request)
  "Invoke TOOL with model ARGUMENTS and CURRENT-INPUT.

When TOOL accepts an argument named `input', CURRENT-INPUT is injected by
default.  A model-supplied input argument overrides it.  Remaining model
arguments are passed as keyword arguments.

Pure tools execute locally.  Effectful tools are sent to
`ellm-effect-dispatch-function'; without that bridge they fail closed.
REQUEST is optional backend context passed to the authority bridge."
  (let* ((definition (ellm-tool tool))
         (name (ellm-tool-name definition))
         (accepts-input (ellm-tool-accepts-input-p definition))
         (normalized
          (condition-case error-data
              (ellm--tool-arguments-alist arguments)
            (error
             (ellm--signal-tool-error
              "invalid_arguments"
              name
              (error-message-string error-data)))))
         (explicit-input (assq 'input normalized))
         (resolved-input
          (if explicit-input (cdr explicit-input) current-input))
         (remaining (assq-delete-all 'input (copy-tree normalized))))
    (when (and explicit-input (not accepts-input))
      (ellm--signal-tool-error
       "input_not_accepted"
       name
       "Tool does not accept an input argument"))
    (pcase (ellm-tool-effect definition)
      ('effectful
       (unless (functionp ellm-effect-dispatch-function)
         (ellm--signal-tool-error
          "effect_requires_bridge"
          name
          "Effectful tool requires Consortium/Prolog-RLM authority"))
       (funcall ellm-effect-dispatch-function
                name remaining resolved-input request))
      ('pure
       (condition-case error-data
           (if accepts-input
               (apply
                (ellm-tool-function definition)
                resolved-input
                (ellm--tool-keyword-plist remaining))
             (apply
              (ellm-tool-function definition)
              (ellm--tool-keyword-plist remaining)))
         (ellm-tool-error
          (signal (car error-data) (cdr error-data)))
         (error
          (ellm--signal-tool-error
           "implementation_error"
           name
           (error-message-string error-data))))))))

(defun ellm-request-call-tool (request tool arguments)
  "Call TOOL for REQUEST and advance REQUEST's current value.

The current value is `ellm-request-input'.  On success the tool result
becomes both the request input and the explicit conversation input."
  (unless (ellm-request-p request)
    (signal 'wrong-type-argument (list 'ellm-request-p request)))
  (let ((value
         (ellm-call-tool
          tool arguments (ellm-request-input request) request)))
    (setf (ellm-request-input request) value
          (ellm-conversation-input (ellm-request-conversation request))
          value)
    value))

(provide 'ellm-tools)
;;; ellm-tools.el ends here
