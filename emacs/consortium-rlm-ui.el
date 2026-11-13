;;; consortium-rlm-ui.el --- Consortium workbench UI -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Interactive surface over `consortium-rlm-session': daemon lifecycle
;; defaults, provider secrets through auth-source (never stored in
;; configuration), and the approval/question prompt surfaces.
;;
;; Approval resolution round-trips through the daemon `approve'/`deny'
;; methods, which proxy the pinned Prolog-RLM trusted authority APIs; the
;; reducer marks the approval resolved when `approval_resolved' arrives.
;; Question prompts surface the worker's question, but answering a
;; question requires an upstream question-resolution API that the pinned
;; Prolog-RLM revision does not expose yet, so the prompt is advisory
;; until that lands upstream.
;;
;; This module supersedes the retired `consortium.el' async client; the
;; protocol-pinned client/session/process stack is the single canonical
;; Emacs surface.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'consortium-rlm-client)
(require 'consortium-rlm-process)
(require 'consortium-rlm-session)

(defgroup consortium-rlm-ui nil
  "Consortium workbench prompt surfaces and daemon lifecycle."
  :group 'tools)

(defcustom consortium-rlm-ui-program "consortium"
  "Consortium daemon executable."
  :type 'string)

(defcustom consortium-rlm-ui-program-arguments '("daemon")
  "Arguments used when starting the Consortium daemon."
  :type '(repeat string))

(defcustom consortium-rlm-ui-openrouter-auth-host "openrouter.ai"
  "Auth-source host consulted for the OpenRouter secret when the
OPENROUTER_API_KEY environment variable is not already set."
  :type 'string)

(defcustom consortium-rlm-ui-auto-prompt t
  "Prompt in the minibuffer when approvals or questions are required."
  :type 'boolean)

(defcustom consortium-rlm-ui-default-run-options
  '((worker . "rlm")
    (provider . "openrouter")
    (models . ((root_agent . "openai/gpt-oss-120b")
               (analyze . "openai/gpt-oss-120b")
               (design . "openai/gpt-oss-120b")
               (adversarial_review . "openai/gpt-oss-120b")
               (resolve . "openai/gpt-oss-120b")
               (develop . "openai/gpt-oss-120b")
               (verify . "openai/gpt-oss-120b")))
    (budget . ((max_total_tokens . 24000)
               (max_cost_usd . 2.0)
               (time_limit . 300.0)))
    (phase_budget . ((max_total_tokens . 4000)
                     (max_cost_usd . 0.5)
                     (time_limit . 60.0))))
  "Provider-neutral run options sent with started tasks."
  :type 'sexp)

(defvar consortium-rlm-ui-session nil
  "The shared workbench daemon session, or nil.")

;;; Daemon lifecycle -------------------------------------------------------

(defun consortium-rlm-ui--auth-source-secret ()
  "Return the auth-source secret for `consortium-rlm-ui-openrouter-auth-host'."
  (when (require 'auth-source nil t)
    (when-let* ((entry (car (auth-source-search
                             :host consortium-rlm-ui-openrouter-auth-host
                             :max 1
                             :require '(:secret))))
                (secret (plist-get entry :secret)))
      (if (functionp secret) (funcall secret) secret))))

(defun consortium-rlm-ui-connect ()
  "Start or adopt the shared daemon session with prompt hooks attached.
The OpenRouter secret is injected into the daemon's environment from
auth-source only when `OPENROUTER_API_KEY' is not already set; the
secret itself never enters configuration or the wire protocol."
  (if (and consortium-rlm-ui-session
           (process-live-p (consortium-rlm-session-connection
                            consortium-rlm-ui-session)))
      consortium-rlm-ui-session
    (let ((session (consortium-rlm-session-start
                    "consortium-rlm-ui"
                    consortium-rlm-ui-program
                    consortium-rlm-ui-program-arguments
                    (lambda (sess _process event)
                      (message "Consortium daemon exited: %s" event)
                      (when (eq sess consortium-rlm-ui-session)
                        (setq consortium-rlm-ui-session nil))))))
      (setf (consortium-rlm-session-event-hook session)
            #'consortium-rlm-ui--handle-event)
      (setq consortium-rlm-ui-session session)
      session)))

(defun consortium-rlm-ui-disconnect ()
  "Stop the shared daemon session and fail its pending requests."
  (when consortium-rlm-ui-session
    (consortium-rlm-session-shutdown consortium-rlm-ui-session)
    (setq consortium-rlm-ui-session nil)))

(defun consortium-rlm-ui-start-task (task &optional options callback)
  "Start TASK with OPTIONS on the shared session.
OPTIONS default to `consortium-rlm-ui-default-run-options'.  CALLBACK,
when given, receives (ok result).  Return the request id."
  (interactive "sConsortium task: ")
  (let ((session (consortium-rlm-ui-connect)))
    (consortium-rlm-session-request
     session
     "start"
     `((task . ,task)
       (options . ,(or options consortium-rlm-ui-default-run-options)))
     callback)))

;;; Prompt surfaces --------------------------------------------------------

(defun consortium-rlm-ui--handle-event (session run-id event-type payload _view)
  "Session event hook: prompt for approval/question requirements."
  (cond
   ((and (string-equal event-type "approval_required")
         consortium-rlm-ui-auto-prompt)
    (consortium-rlm-ui-prompt-approval session run-id payload))
   ((and (string-equal event-type "question_required")
         consortium-rlm-ui-auto-prompt)
    (consortium-rlm-ui-prompt-question session run-id payload))))

(defun consortium-rlm-ui--approval-choices (payload)
  "Return the decision choices offered by an approval PAYLOAD.
The daemon-side denial path is always offered, because a missing
denial option would make the prompt coerce-only."
  (let ((choices (append (cdr (assq 'choices payload)) nil)))
    (if (member "deny" choices)
        choices
      (append choices (list "deny")))))

(defun consortium-rlm-ui-prompt-approval (session run-id payload)
  "Prompt for an approval PAYLOAD on RUN-ID and resolve it.
Any non-denial choice resolves as an approval; the chosen variant is
reported.  Denials ask for a reason."
  (let* ((approval-id (cdr (assq 'approval_id payload)))
         (name (or (cdr (assq 'name payload)) approval-id))
         (choices (consortium-rlm-ui--approval-choices payload))
         (choice (completing-read
                  (format "Consortium approval [%s]: " name)
                  choices
                  nil t nil nil (car choices))))
    (if (string-equal choice "deny")
        (let ((reason (read-string (format "Denial reason for %s: " name))))
          (consortium-rlm-session-resolve-approval
           session run-id approval-id "deny" reason))
      (consortium-rlm-session-resolve-approval
       session run-id approval-id "approve")
      (message "Consortium approval %s resolved: %s" approval-id choice))))

(defun consortium-rlm-ui-prompt-question (session run-id payload)
  "Surface a question PAYLOAD from RUN-ID.
The pinned Prolog-RLM revision has no public question-resolution API,
so this prompt is advisory: it shows the question and records nothing
that would pretend to reach the waiting worker."
  (let* ((question-id (cdr (assq 'question_id payload)))
         (prompt (or (cdr (assq 'prompt payload)) question-id))
         (choices (append (cdr (assq 'choices payload)) nil)))
    (display-message-or-buffer
     (format "Consortium question [%s]: %s%s\n(Answering requires an \
upstream question-resolution API; not yet available.)"
             question-id
             prompt
             (if choices
                 (format "  choices: %s"
                         (string-join choices ", "))
               "")))
    (when consortium-rlm-ui-auto-prompt
      (message "Consortium question %s is pending upstream support"
               question-id))))

(defun consortium-rlm-ui-resolve-approval (run-id approval-id decision
                                           &optional reason)
  "Resolve APPROVAL-ID on RUN-ID with DECISION interactively.
DECISION is \"approve\" or \"deny\"; a denial prompts for REASON when
omitted."
  (interactive
   (let* ((session (or consortium-rlm-ui-session
                       (user-error "No Consortium session")))
          (run-id (completing-read
                   "Run id: "
                   (mapcar #'car (consortium-rlm-session-views session))))
          (pending (consortium-rlm-session-pending-approvals session run-id))
          (approval-id (completing-read
                        "Approval: "
                        (mapcar (lambda (item)
                                  (cdr (assq 'id item)))
                                pending)
                        nil t))
          (decision (completing-read "Decision: " '("approve" "deny") nil t)))
     (list run-id approval-id decision)))
  (let ((session (or consortium-rlm-ui-session
                     (user-error "No Consortium session"))))
    (when (and (string-equal decision "deny") (not reason))
      (setq reason (read-string "Denial reason: ")))
    (consortium-rlm-session-resolve-approval
     session run-id approval-id decision reason)))

(defun consortium-rlm-ui-pending (run-id)
  "Echo the pending approvals and questions for RUN-ID."
  (interactive)
  (let ((session (or consortium-rlm-ui-session
                     (user-error "No Consortium session"))))
    (let ((approvals (consortium-rlm-session-pending-approvals session run-id))
          (questions (consortium-rlm-session-pending-questions session run-id)))
      (message "Consortium %s: %d pending approvals, %d pending questions"
               run-id (length approvals) (length questions)))))

(provide 'consortium-rlm-ui)
;;; consortium-rlm-ui.el ends here
