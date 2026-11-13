;;; consortium-rlm-session.el --- Consortium daemon session layer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Request/event session over the Consortium NDJSON daemon transport.
;;
;; This layer owns exactly three concerns and no UI:
;;
;; 1. Request/response correlation: `consortium-rlm-session-request'
;;    assigns protocol ids and dispatches the response (or error) to the
;;    registered callback.
;;
;; 2. Event projection: daemon event pushes carry the daemon envelope
;;    {run_id, sequence, type, payload}; they are translated into
;;    canonical `prolog_agent_ui_v1' frames and reduced into per-run
;;    views by `consortium-rlm-client'.  Sequence enforcement, duplicate
;;    suppression and fail-closed unknown events stay in the reducer.
;;
;; 3. Human resolution surfaces as plain requests: `approve'/`deny'
;;    round-trips an `approval_required' event, and deterministic view
;;    rebuild after (re)connect is `consortium-rlm-session-replay' over
;;    the daemon's ordered `events' surface.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'consortium-rlm-client)
(require 'consortium-rlm-process)

(defconst consortium-rlm-session-max-views 16
  "Bounded number of per-run views retained by one session.")

(cl-defstruct (consortium-rlm-session
               (:constructor consortium-rlm-session--make)
               (:conc-name consortium-rlm-session-))
  "Correlated request/event session over a Consortium daemon."
  name
  connection
  (next-id 1)
  (pending nil)
  (views nil)
  event-hook
  view-hook
  on-death)

(defun consortium-rlm-session-start (name program arguments &optional on-death)
  "Start daemon session NAME running PROGRAM with ARGUMENTS.
ON-DEATH, when given, receives (session process event-string)."
  (let ((session (consortium-rlm-session--make :name name :on-death on-death)))
    (setf (consortium-rlm-session-connection session)
          (consortium-rlm-process-start
           name program arguments
           (lambda (line) (consortium-rlm-session--on-line session line))
           (lambda (process event)
             (when on-death (funcall on-death session process event)))))
    session))

(defun consortium-rlm-session-shutdown (session)
  "Stop SESSION's transport."
  (consortium-rlm-process-stop (consortium-rlm-session-connection session)))

(defun consortium-rlm-session--send (session line)
  "Send one encoded LINE over SESSION's transport."
  (consortium-rlm-process-send (consortium-rlm-session-connection session) line))

(defun consortium-rlm-session-request (session method params &optional callback)
  "Send a {id, method, params} request on SESSION.
CALLBACK, when given, receives (ok result) where OK is non-nil for a
successful response carrying RESULT, or nil carrying the error plist."
  (let* ((id (consortium-rlm-session-next-id session))
         (frame `((id . ,id) (method . ,method) (params . ,params))))
    (setf (consortium-rlm-session-next-id session) (1+ id))
    (setf (consortium-rlm-session-pending session)
          (cons (cons id callback) (consortium-rlm-session-pending session)))
    (consortium-rlm-session--send session (json-encode frame))
    id))

(defun consortium-rlm-session--on-line (session line)
  "Handle one decoded daemon LINE for SESSION.
Daemon transport frames are plain {kind: response|event} envelopes,
not `prolog_agent_ui_v1' records; translated event envelopes are
validated with the canonical client validator before reduction."
  (condition-case err
      (let* ((frame (json-parse-string line
                                       :object-type 'alist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object :json-false))
             (kind (and (listp frame) (cdr (assq 'kind frame)))))
        (pcase kind
          ("response" (consortium-rlm-session--on-response session frame))
          ("event" (consortium-rlm-session--on-daemon-event session frame))
          (_ (message "consortium-rlm: unknown daemon frame kind: %S" kind))))
    (json-error
     (message "consortium-rlm: invalid daemon line: %S" err))))

(defun consortium-rlm-session--on-response (session frame)
  "Route a response FRAME to its pending SESSION callback."
  (let* ((id (cdr (assq 'id frame)))
         (entry (assq id (consortium-rlm-session-pending session))))
    (setf (consortium-rlm-session-pending session)
          (delq entry (consortium-rlm-session-pending session)))
    (when entry
      (let ((callback (cdr entry)))
        (cond
         ((eq (cdr (assq 'ok frame)) t)
          (when callback (funcall callback t (cdr (assq 'result frame)))))
         (callback
          (funcall callback nil (cdr (assq 'error frame)))))))))

(defun consortium-rlm-session--on-daemon-event (session frame)
  "Reduce a daemon event FRAME into SESSION's per-run views."
  (pcase (consortium-rlm-session--translate-event frame)
    ((and canonical-frame (guard canonical-frame))
     (pcase (consortium-rlm-client--catch
             (consortium-rlm-client-validate canonical-frame))
       (`(:ok ,_validated)
        (consortium-rlm-session--apply-canonical session canonical-frame))
       (`(:error ,plist)
        (message "consortium-rlm: invalid event frame: %S" plist)))
     nil)
    (_ nil)))

(defun consortium-rlm-session--apply-canonical (session canonical-frame)
  "Apply one canonical client frame to SESSION's view and fire hooks."
  (let* ((run-id (cdr (assq 'session_id canonical-frame)))
         (view (or (consortium-rlm-session-view session run-id)
                   (consortium-rlm-client-initial-view run-id)))
         (outcome (consortium-rlm-client-apply-event view canonical-frame)))
    (pcase outcome
      (`(:ok ,next-view)
       (consortium-rlm-session--install-view session run-id next-view)
       (let ((payload (cdr (assq 'payload canonical-frame)))
             (event-type (cdr (assq 'event_type canonical-frame))))
         (when (consortium-rlm-session-event-hook session)
           (funcall (consortium-rlm-session-event-hook session)
                    session run-id event-type payload next-view))
         (when (consortium-rlm-session-view-hook session)
           (funcall (consortium-rlm-session-view-hook session)
                    session run-id next-view))))
      (`(:error ,plist)
       (message "consortium-rlm: event reduction failed: %S" plist)))))

(defun consortium-rlm-session--translate-event (frame)
  "Translate a daemon event FRAME into a canonical client frame.
Return nil for frames that are not daemon event envelopes."
  (let ((event (cdr (assq 'event frame))))
    (when (and (listp event) (assq 'run_id event) (assq 'sequence event))
      `((protocol . ,consortium-rlm-client-protocol)
        (kind . "event")
        (session_id . ,(cdr (assq 'run_id event)))
        (seq . ,(cdr (assq 'sequence event)))
        (event_id . ,(cdr (assq 'event_id event)))
        (event_type . ,(cdr (assq 'type event)))
        (payload . ,(cdr (assq 'payload event)))))))

(defun consortium-rlm-session--install-view (session run-id view)
  "Install VIEW for RUN-ID in SESSION, bounding retained views."
  (setf (consortium-rlm-session-views session)
        (cons (cons run-id view)
              (delete (assoc run-id (consortium-rlm-session-views session))
                      (consortium-rlm-session-views session))))
  (let ((excess (nthcdr consortium-rlm-session-max-views
                        (consortium-rlm-session-views session))))
    (setf (consortium-rlm-session-views session)
          (nbutlast (consortium-rlm-session-views session)
                    (length excess)))))

(defun consortium-rlm-session-view (session run-id)
  "Return SESSION's current view for RUN-ID, or nil."
  (cdr (assoc run-id (consortium-rlm-session-views session))))

(defun consortium-rlm-session--items (view key status)
  "Collect VIEW items under KEY not carrying STATUS."
  (let ((view-items (and view (plist-get view key))))
    (cl-loop for item in view-items
             unless (equal (cdr (assq 'status item)) status)
             collect item)))

(defun consortium-rlm-session-pending-approvals (session run-id)
  "Return RUN-ID's unresolved approvals in SESSION's view."
  (consortium-rlm-session--items (consortium-rlm-session-view session run-id)
                                 :approvals "resolved"))

(defun consortium-rlm-session-pending-questions (session run-id)
  "Return RUN-ID's unanswered questions in SESSION's view."
  (consortium-rlm-session--items (consortium-rlm-session-view session run-id)
                                 :questions "answered"))

(defun consortium-rlm-session-resolve-approval (session run-id approval-id
                                                     decision
                                                     &optional reason callback)
  "Resolve APPROVAL-ID on RUN-ID with DECISION.
DECISION is \"approve\" or \"deny\"; REASON accompanies a denial.
CALLBACK receives (ok result)."
  (pcase decision
    ("approve"
     (consortium-rlm-session-request
      session "approve" `((run_id . ,run-id)
                          (approval_id . ,approval-id))
      callback))
    ("deny"
     (consortium-rlm-session-request
      session "deny" `((run_id . ,run-id)
                       (approval_id . ,approval-id)
                       (reason . ,(or reason "")))
      callback))
    (_ (signal 'consortium-rlm-error
               (list :reason "invalid-approval-decision" :decision decision)))))

(defun consortium-rlm-session-replay (session run-id &optional callback)
  "Rebuild RUN-ID's view in SESSION from the ordered daemon event log.
This is the reconnect path: the view is replaced deterministically
from events since 0.  CALLBACK receives (ok view)."
  (consortium-rlm-session-request
   session "events" `((run_id . ,run-id) (since . 0))
   (lambda (ok result)
     (if (not ok)
         (when callback (funcall callback nil result))
       (consortium-rlm-session--replay-events
        session run-id (cdr (assq 'events result)) callback)))))

(defun consortium-rlm-session--replay-events (session run-id events callback)
  "Reduce EVENTS into RUN-ID's view in SESSION; report via CALLBACK."
  (let ((view (consortium-rlm-client-initial-view run-id))
        (failed nil))
    (dolist (event events)
      (when (and (not failed) (consp event) (assq 'run_id event))
        (pcase (consortium-rlm-client-apply-event
                view
                (consortium-rlm-session--translate-event
                 `((event . ,event))))
          (`(:ok ,next) (setq view next))
          (`(:error ,plist)
           (setq failed plist)
           (message "consortium-rlm: replay failed: %S" plist)))))
    (cond
     (failed (when callback (funcall callback nil failed)))
     (t
      (consortium-rlm-session--install-view session run-id view)
      (when (consortium-rlm-session-view-hook session)
        (funcall (consortium-rlm-session-view-hook session)
                 session run-id view))
      (when callback (funcall callback t view))))))

(provide 'consortium-rlm-session)
;;; consortium-rlm-session.el ends here
