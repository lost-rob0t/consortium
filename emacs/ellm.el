;;; ellm.el --- Elisp LLM mesh foundation for Consortium -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; ELLM is Consortium's provider-neutral Elisp surface for named actors and
;; explicit conversations.  It intentionally owns no HTTP/provider runtime and
;; no autonomous effect authority.  Backends are adapters registered with
;; `ellm-register-backend'; controlled worker execution is bridged to
;; Consortium/Prolog-RLM by separate modules.
;;
;; The core API is deliberately small:
;;
;;   (ellm-defactor researcher :backend 'gptel :model "model")
;;   (ellm-ask 'researcher "Explain this." :callback CALLBACK)
;;   (ellm-reply CONVERSATION "Continue." :callback CALLBACK)
;;   (ellm-reset CONVERSATION)
;;
;; Conversation history is explicit data.  Nothing in this file transfers
;; hidden provider transcripts into Consortium ADARD phase packets.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup ellm nil
  "Elisp LLM mesh and conversation layer for Consortium."
  :group 'consortium)

(defcustom ellm-default-backend 'gptel
  "Backend used by actors that do not name one explicitly."
  :type 'symbol
  :group 'ellm)

(cl-defstruct (ellm-actor (:constructor ellm--make-actor))
  "Provider-neutral ELLM actor description."
  name backend model system tools skills metadata)

(cl-defstruct (ellm-conversation (:constructor ellm--make-conversation))
  "Explicit ELLM conversation state."
  id actor messages input cache metadata)

(cl-defstruct (ellm-request (:constructor ellm--make-request))
  "One asynchronous ELLM backend request."
  id
  prompt
  actor
  conversation
  input
  cache
  tools
  skills
  system
  metadata
  state
  result
  error
  handle)

(defvar ellm--actors (make-hash-table :test #'eq)
  "Registry of ELLM actors keyed by symbol.")

(defvar ellm--backends (make-hash-table :test #'eq)
  "Registry of ELLM backend adapter functions keyed by symbol.")

(defvar ellm--conversation-sequence 0
  "Monotonic local sequence used for conversation IDs.")

(defvar ellm--request-sequence 0
  "Monotonic local sequence used for request IDs.")

(defun ellm-register-actor (name &rest properties)
  "Register actor NAME from PROPERTIES and return the actor.

PROPERTIES accepts :backend, :model, :system, :tools, :skills and :metadata."
  (unless (symbolp name)
    (signal 'wrong-type-argument (list 'symbolp name)))
  (let ((actor
         (ellm--make-actor
          :name name
          :backend (plist-get properties :backend)
          :model (plist-get properties :model)
          :system (plist-get properties :system)
          :tools (copy-sequence (plist-get properties :tools))
          :skills (copy-sequence (plist-get properties :skills))
          :metadata (plist-get properties :metadata))))
    (puthash name actor ellm--actors)
    actor))

(defmacro ellm-defactor (name &rest properties)
  "Define and register ELLM actor NAME with PROPERTIES."
  (declare (indent 1))
  `(ellm-register-actor ',name ,@properties))

(defun ellm-actor (actor)
  "Resolve ACTOR to an `ellm-actor' object.

ACTOR may already be an actor object or may be the registered actor symbol."
  (cond
   ((ellm-actor-p actor) actor)
   ((symbolp actor)
    (or (gethash actor ellm--actors)
        (error "Unknown ELLM actor: %S" actor)))
   (t
    (signal 'wrong-type-argument (list '(or symbol ellm-actor) actor)))))

(defun ellm-register-backend (name function)
  "Register backend NAME implemented by FUNCTION.

FUNCTION is called as (FUNCTION REQUEST DELIVER).  REQUEST is an
`ellm-request'.  DELIVER is a callback accepting RESULT and ERROR.  The
backend must call DELIVER exactly once and may return any opaque request
handle."
  (unless (symbolp name)
    (signal 'wrong-type-argument (list 'symbolp name)))
  (unless (functionp function)
    (signal 'wrong-type-argument (list 'functionp function)))
  (puthash name function ellm--backends)
  function)

(defun ellm-backend (name)
  "Return registered backend adapter NAME or signal an error."
  (or (gethash name ellm--backends)
      (error "Unknown ELLM backend: %S" name)))

(defun ellm-conversation (actor &rest properties)
  "Create an explicit conversation for ACTOR.

PROPERTIES accepts :id, :messages, :input, :cache and :metadata."
  (let ((resolved (ellm-actor actor)))
    (ellm--make-conversation
     :id (or (plist-get properties :id)
             (format "conversation-%d"
                     (cl-incf ellm--conversation-sequence)))
     :actor resolved
     :messages (copy-tree (plist-get properties :messages))
     :input (plist-get properties :input)
     :cache (plist-get properties :cache)
     :metadata (plist-get properties :metadata))))

(defun ellm-reset (conversation)
  "Clear explicit message history from CONVERSATION and return it.

The conversation's actor, input, cache policy and metadata are preserved."
  (unless (ellm-conversation-p conversation)
    (signal 'wrong-type-argument (list 'ellm-conversation-p conversation)))
  (setf (ellm-conversation-messages conversation) nil)
  conversation)

(defun ellm--plist-get-present (plist key fallback)
  "Return KEY from PLIST when present, otherwise FALLBACK."
  (if (plist-member plist key)
      (plist-get plist key)
    fallback))

(defun ellm--append-message (conversation role content)
  "Append ROLE and CONTENT to CONVERSATION."
  (setf (ellm-conversation-messages conversation)
        (append
         (ellm-conversation-messages conversation)
         (list `((role . ,role) (content . ,content))))))

(defun ellm--request-deliverer (request callback)
  "Return a completion function for REQUEST and CALLBACK."
  (lambda (result error)
    (unless (memq (ellm-request-state request) '(done failed cancelled))
      (if error
          (setf (ellm-request-state request) 'failed
                (ellm-request-error request) error)
        (setf (ellm-request-state request) 'done
              (ellm-request-result request) result)
        (ellm--append-message
         (ellm-request-conversation request)
         'assistant
         result))
      (when callback
        (funcall callback result error request)))))

(defun ellm-ask (actor prompt &rest options)
  "Ask ACTOR PROMPT asynchronously and return an `ellm-request'.

OPTIONS accepts:

  :conversation  Existing explicit conversation to reuse.
  :input         Structured current input/value for this request.
  :cache         Backend-neutral prompt-cache policy.
  :tools         Tool names visible to the backend.
  :skills        Skill names visible to the backend.
  :system        Explicit system prompt override.
  :metadata      Consumer metadata.
  :callback      Function called as (RESULT ERROR REQUEST).

The backend is selected from the resolved actor, or
`ellm-default-backend'.  This function performs no provider I/O itself."
  (unless (stringp prompt)
    (signal 'wrong-type-argument (list 'stringp prompt)))
  (let* ((provided-conversation (plist-get options :conversation))
         (conversation
          (if provided-conversation
              (progn
                (unless (ellm-conversation-p provided-conversation)
                  (signal 'wrong-type-argument
                          (list 'ellm-conversation-p
                                provided-conversation)))
                provided-conversation)
            (ellm-conversation actor)))
         (resolved-actor
          (if provided-conversation
              (ellm-conversation-actor conversation)
            (ellm-actor actor)))
         (backend-name
          (or (ellm-actor-backend resolved-actor)
              ellm-default-backend))
         (backend (ellm-backend backend-name))
         (input
          (ellm--plist-get-present
           options :input (ellm-conversation-input conversation)))
         (cache
          (ellm--plist-get-present
           options :cache (ellm-conversation-cache conversation)))
         (request
          (ellm--make-request
           :id (format "request-%d" (cl-incf ellm--request-sequence))
           :prompt prompt
           :actor resolved-actor
           :conversation conversation
           :input input
           :cache cache
           :tools
           (ellm--plist-get-present
            options :tools (ellm-actor-tools resolved-actor))
           :skills
           (ellm--plist-get-present
            options :skills (ellm-actor-skills resolved-actor))
           :system
           (ellm--plist-get-present
            options :system (ellm-actor-system resolved-actor))
           :metadata (plist-get options :metadata)
           :state 'pending))
         (callback (plist-get options :callback))
         (deliver (ellm--request-deliverer request callback)))
    (ellm--append-message conversation 'user prompt)
    (condition-case error-data
        (setf (ellm-request-handle request)
              (funcall backend request deliver))
      (error
       (funcall
        deliver nil
        `((kind . "backend_signal")
          (message . ,(error-message-string error-data))))))
    request))

(defun ellm-reply (conversation prompt &rest options)
  "Send PROMPT as the next turn in CONVERSATION.

OPTIONS are the same as for `ellm-ask'."
  (unless (ellm-conversation-p conversation)
    (signal 'wrong-type-argument (list 'ellm-conversation-p conversation)))
  (apply #'ellm-ask
         (ellm-conversation-actor conversation)
         prompt
         :conversation conversation
         options))

(provide 'ellm)
;;; ellm.el ends here
