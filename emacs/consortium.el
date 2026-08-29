;;; consortium.el --- Async Consortium client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Persistent, fully asynchronous JSON Lines client for the Consortium daemon.
;; This library deliberately contains no model or workflow policy.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function auth-source-search "auth-source" (&rest spec))

(defgroup consortium nil
  "Asynchronous Consortium agent harness."
  :group 'tools)

(defcustom consortium-program "consortium"
  "Consortium daemon executable."
  :type 'string)

(defcustom consortium-program-arguments '("daemon")
  "Arguments used when starting the Consortium daemon."
  :type '(repeat string))

(defcustom consortium-default-options
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
  "Default provider-neutral run options sent to the Consortium daemon."
  :type 'sexp)

(defcustom consortium-openrouter-auth-host "openrouter.ai"
  "Auth-source host used when OPENROUTER_API_KEY is not already set."
  :type 'string)

(defvar consortium-process nil
  "Persistent Consortium daemon process.")

(defvar consortium-event-hook nil
  "Hook run with one argument for each accepted Consortium event.")

(defvar consortium--input "")
(defvar consortium--next-request-id 0)
(defvar consortium--callbacks (make-hash-table :test #'eql))
(defvar consortium--run-events (make-hash-table :test #'equal))
(defvar consortium--run-statuses (make-hash-table :test #'equal))
(defvar consortium--latest-status-request (make-hash-table :test #'equal))

(defun consortium-connect (&optional command)
  "Start a persistent Consortium process without blocking Emacs.
COMMAND defaults to `consortium-program' and
`consortium-program-arguments'.  Return the process."
  (unless (process-live-p consortium-process)
    (setq consortium--input "")
    (let ((process-environment (copy-sequence process-environment)))
      (unless (getenv "OPENROUTER_API_KEY")
        (when-let ((secret (consortium--auth-source-secret)))
          (setenv "OPENROUTER_API_KEY" secret)))
      (setq consortium-process
            (make-process
             :name "consortium"
             :command (or command
                          (cons consortium-program consortium-program-arguments))
             :connection-type 'pipe
             :coding 'utf-8-unix
             :noquery t
             :filter #'consortium--process-filter
             :sentinel #'consortium--process-sentinel))))
  consortium-process)

(defun consortium-disconnect ()
  "Stop the local client connection without waiting for the daemon."
  (when (process-live-p consortium-process)
    (delete-process consortium-process))
  (setq consortium-process nil
        consortium--input "")
  (consortium--fail-pending '((kind . "disconnected"))))

(defun consortium-request (method params callback)
  "Send asynchronous METHOD with PARAMS and register CALLBACK.
CALLBACK receives RESULT and ERROR.  Return the numeric request ID immediately."
  (consortium-connect)
  (let* ((request-id (cl-incf consortium--next-request-id))
         (request `((id . ,request-id)
                    (method . ,method)
                    (params . ,params)))
         (line (concat (json-encode request) "\n")))
    (when callback
      (puthash request-id callback consortium--callbacks))
    (process-send-string consortium-process line)
    request-id))

(defun consortium-start-task (task &optional options callback)
  "Asynchronously start TASK with OPTIONS.
CALLBACK receives RUN-ID and ERROR.  Return the request ID immediately."
  (interactive "sConsortium task: ")
  (consortium-request
   "start"
   `((task . ,task) (options . ,(or options consortium-default-options)))
   (lambda (result error)
     (let ((run-id (and result (alist-get 'run_id result))))
       (when (and run-id (called-interactively-p 'interactive))
         (message "Consortium admitted %s" run-id))
       (when callback
         (funcall callback run-id error))))))

(defun consortium-status (run-id callback)
  "Request RUN-ID status asynchronously and invoke CALLBACK."
  (let (request-id)
    (setq request-id
          (consortium-request
           "status"
           `((run_id . ,run-id))
           (lambda (result error)
             (when result
               (consortium--record-status request-id result))
             (when callback
               (funcall callback result error)))))
    (puthash run-id request-id consortium--latest-status-request)
    request-id))

(defun consortium-cancel (run-id callback)
  "Cancel RUN-ID asynchronously and invoke CALLBACK."
  (consortium-request "cancel" `((run_id . ,run-id)) callback))

(defun consortium-events (run-id since callback)
  "Replay RUN-ID events after sequence SINCE asynchronously."
  (consortium-request
   "events"
   `((run_id . ,run-id) (since . ,since))
   (lambda (result error)
     (dolist (event (alist-get 'events result))
       (consortium--handle-event event))
     (when callback
       (funcall callback result error)))))

(defun consortium-artifact (run-id artifact-id callback)
  "Fetch ARTIFACT-ID for RUN-ID asynchronously."
  (consortium-request
   "artifact"
   `((run_id . ,run-id) (artifact_id . ,artifact-id))
   callback))

(defun consortium-subscribe (&optional callback)
  "Enable pushed daemon events asynchronously."
  (consortium-request "subscribe" (consortium--empty-object) callback))

(defun consortium-unsubscribe (&optional callback)
  "Disable pushed daemon events asynchronously."
  (consortium-request "unsubscribe" (consortium--empty-object) callback))

(defun consortium--empty-object ()
  (make-hash-table :test #'equal))

(defun consortium--auth-source-secret ()
  (when (require 'auth-source nil t)
    (when-let* ((entry (car (auth-source-search
                             :host consortium-openrouter-auth-host
                             :max 1
                             :require '(:secret))))
                (secret (plist-get entry :secret)))
      (if (functionp secret) (funcall secret) secret))))

(defun consortium-run-state (run-id)
  "Return current status, augmented with the newest event, for RUN-ID."
  (let ((status (gethash run-id consortium--run-statuses))
        (event (gethash run-id consortium--run-events)))
    (cond
     (status
      (append status
              (when event
                `((latest_event . ,event)
                  (sequence . ,(alist-get 'sequence event))))))
     (event event))))

(defun consortium-run-event (run-id)
  "Return the newest accepted pushed/replayed event for RUN-ID."
  (gethash run-id consortium--run-events))

(defun consortium-run-status (run-id)
  "Return the newest accepted status response for RUN-ID."
  (gethash run-id consortium--run-statuses))

(defun consortium--process-filter (_process chunk)
  (setq consortium--input (concat consortium--input chunk))
  (when (> (string-bytes consortium--input) 1048576)
    (setq consortium--input "")
    (consortium--fail-pending '((kind . "frame_too_large")))
    (when (process-live-p consortium-process)
      (delete-process consortium-process)))
  (let ((start 0))
    (while (string-match "\n" consortium--input start)
      (let ((line (substring consortium--input start (match-beginning 0))))
        (unless (string-empty-p line)
          (consortium--handle-line line)))
      (setq start (match-end 0)))
    (setq consortium--input (substring consortium--input start))))

(defun consortium--handle-line (line)
  (condition-case error-data
      (let* ((message (json-parse-string line
                                         :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil))
             (kind (alist-get 'kind message)))
        (cond
         ((equal kind "response")
          (consortium--handle-response message))
         ((equal kind "event")
          (consortium--handle-event (alist-get 'event message)))
         (t
          (message "Consortium ignored unknown message kind: %S" kind))))
    (error
     (message "Consortium protocol error: %s"
              (error-message-string error-data)))))

(defun consortium--handle-response (message)
  (let* ((request-id (alist-get 'id message))
         (callback (gethash request-id consortium--callbacks)))
    (if (and (integerp request-id)
             (assq 'ok message)
             (or (alist-get 'ok message)
                 (assq 'error message)))
        (progn
          (remhash request-id consortium--callbacks)
          (when callback
            (if (alist-get 'ok message)
                (funcall callback (alist-get 'result message) nil)
              (funcall callback nil (alist-get 'error message)))))
      (message "Consortium ignored malformed response: %S" message))))

(defun consortium--handle-event (event)
  (let* ((run-id (alist-get 'run_id event))
         (sequence (alist-get 'sequence event))
         (current (gethash run-id consortium--run-events))
         (current-sequence (or (alist-get 'sequence current) 0)))
    (when (and (stringp run-id)
               (integerp sequence)
               (> sequence current-sequence))
      (puthash run-id event consortium--run-events)
      (run-hook-with-args 'consortium-event-hook event))))

(defun consortium--record-status (request-id status)
  (let* ((run-id (alist-get 'run_id status))
         (latest (gethash run-id consortium--latest-status-request))
         (current (gethash run-id consortium--run-events))
         (current-type (alist-get 'type current)))
    (when (and latest
               (>= request-id latest)
               (not (and (member current-type
                                 '("run.completed" "run.failed" "run.cancelled"))
                         (equal (alist-get 'state status) "running"))))
      (puthash run-id status consortium--run-statuses))))

(defun consortium--process-sentinel (process _event)
  (unless (process-live-p process)
    (when (eq process consortium-process)
      (setq consortium-process nil)
      (consortium--fail-pending '((kind . "daemon_exited"))))))

(defun consortium--fail-pending (error)
  (let (callbacks)
    (maphash (lambda (_ callback)
               (when callback (push callback callbacks)))
             consortium--callbacks)
    (clrhash consortium--callbacks)
    (dolist (callback callbacks)
      (funcall callback nil error))))

(provide 'consortium)
;;; consortium.el ends here
