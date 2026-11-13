;;; consortium-rlm-session-tests.el --- session layer tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'json)
(require 'consortium-rlm-session)

(defun consortium-rlm-session-tests--feed (session frame)
  "Feed FRAME through SESSION's line handler as encoded NDJSON."
  (consortium-rlm-session--on-line session (json-encode frame)))

(defun consortium-rlm-session-tests--daemon-event (run-id seq type payload)
  "A daemon event envelope alist."
  `((kind . "event")
    (event . ((run_id . ,run-id)
              (sequence . ,seq)
              (event_id . ,(format "%s:%d" run-id seq))
              (timestamp . "2026-11-13T00:00:00Z")
              (type . ,type)
              (phase . "analyze")
              (worker . "none")
              (payload . ,payload)))))

;;; Request/response correlation -----------------------------------------

(ert-deftest consortium-rlm-session-request-assigns-monotonic-ids ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         captured)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured))))
      (let ((id1 (consortium-rlm-session-request session "status" '((run_id . "r1"))))
            (id2 (consortium-rlm-session-request session "cancel" '((run_id . "r1")))))
        (should (= id2 (1+ id1)))
        (let ((frame1 (json-read-from-string (car (last captured))))
              (frame2 (json-read-from-string (car captured))))
          (should (= (cdr (assq 'id frame1)) id1))
          (should (equal (cdr (assq 'method frame1)) "status"))
          (should (= (cdr (assq 'id frame2)) id2)))))))

(ert-deftest consortium-rlm-session-response-dispatches-callback-with-result ()
  (let ((session (consortium-rlm-session--make :name "t"))
        outcome)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s _line) nil)))
      (consortium-rlm-session-request
       session "start" '((task . "x"))
       (lambda (ok result) (setq outcome (list ok result)))))
    (consortium-rlm-session-tests--feed
     session `((kind . "response") (id . 1) (ok . t)
               (result . ((run_id . "run_1")))))
    (should (equal outcome '(t ((run_id . "run_1")))))))

(ert-deftest consortium-rlm-session-error-response-dispatches-callback-with-error ()
  (let ((session (consortium-rlm-session--make :name "t"))
        outcome)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s _line) nil)))
      (consortium-rlm-session-request
       session "approve" '((run_id . "r") (approval_id . "a"))
       (lambda (ok error) (setq outcome (list ok error)))))
    (consortium-rlm-session-tests--feed
     session `((kind . "response") (id . 1) (ok . :json-false)
               (error . ((kind . "request_error") (message . "boom")))))
    (should (eq (car outcome) nil))
    (should (equal (cdr (assq 'message (cadr outcome))) "boom"))))

(ert-deftest consortium-rlm-session-unknown-response-id-is-ignored ()
  (let ((session (consortium-rlm-session--make :name "t")))
    (should-not (consortium-rlm-session-pending session))
    (consortium-rlm-session-tests--feed
     session `((kind . "response") (id . 99) (ok . t) (result . nil)))
    (should t)))

;;; Event translation and reduction --------------------------------------

(ert-deftest consortium-rlm-session-translates-daemon-events ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         (canonical (consortium-rlm-session--translate-event
                     (consortium-rlm-session-tests--daemon-event
                      "run_1" 3 "approval_required"
                      '((approval_id . "approval_1"))))))
    (should (equal (cdr (assq 'protocol canonical))
                   consortium-rlm-client-protocol))
    (should (equal (cdr (assq 'session_id canonical)) "run_1"))
    (should (= (cdr (assq 'seq canonical)) 3))
    (should (equal (cdr (assq 'event_type canonical)) "approval_required"))))

(ert-deftest consortium-rlm-session-non-event-frames-translate-to-nil ()
  (let ((session (consortium-rlm-session--make :name "t")))
    (should-not (consortium-rlm-session--translate-event
                 `((kind . "response") (id . 1) (ok . t) (result . nil))))))

(ert-deftest consortium-rlm-session-event-reduces-view-and-fires-hooks ()
  (let ((session (consortium-rlm-session--make :name "t"))
        seen-type)
    (setf (consortium-rlm-session-event-hook session)
          (lambda (_s run-id event-type _p _v)
            (setq seen-type (list run-id event-type))))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 1 "approval_required" '((approval_id . "approval_1"))))
    (let ((view (consortium-rlm-session-view session "run_1")))
      (should view)
      (should (= (length (plist-get view :approvals)) 1))
      (should (equal (cdr (assq 'id (car (plist-get view :approvals))))
                     "approval_1")))
    (should (equal seen-type '("run_1" "approval_required")))))

(ert-deftest consortium-rlm-session-duplicate-sequence-is-ignored ()
  (let ((session (consortium-rlm-session--make :name "t")))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 1 "trace" '((note . "one"))))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 1 "trace" '((note . "dup"))))
    (let ((traces (plist-get (consortium-rlm-session-view session "run_1")
                             :traces)))
      (should (= (length traces) 1)))))

;;; Approval/question view surfaces --------------------------------------

(ert-deftest consortium-rlm-session-pending-approvals-exclude-resolved ()
  (let ((session (consortium-rlm-session--make :name "t")))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 1 "approval_required" '((approval_id . "approval_1"))))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 2 "approval_required" '((approval_id . "approval_2"))))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 3 "approval_resolved"
              '((approval_id . "approval_1") (decision . "allow_once"))))
    (let ((pending (consortium-rlm-session-pending-approvals session "run_1")))
      (should (= (length pending) 1))
      (should (equal (cdr (assq 'id (car pending))) "approval_2")))))

(ert-deftest consortium-rlm-session-pending-questions-exclude-answered ()
  (let ((session (consortium-rlm-session--make :name "t")))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 1 "question_required"
              '((question_id . "question_1") (prompt . "Profile?"))))
    (consortium-rlm-session-tests--feed
     session (consortium-rlm-session-tests--daemon-event
              "run_1" 2 "question_answered"
              '((question_id . "question_1") (answer . "authority"))))
    (should-not (consortium-rlm-session-pending-questions session "run_1"))))

;;; Resolve round-trip ---------------------------------------------------

(ert-deftest consortium-rlm-session-resolve-approval-sends-approve ()
  (let ((session (consortium-rlm-session--make :name "t"))
        captured)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured))))
      (consortium-rlm-session-resolve-approval
       session "run_1" "approval_1" "approve")
      (let ((frame (json-read-from-string (car captured))))
        (should (equal (cdr (assq 'method frame)) "approve"))
        (should (equal (cdr (assq 'run_id (cdr (assq 'params frame))))
                       "run_1"))
        (should (equal (cdr (assq 'approval_id (cdr (assq 'params frame))))
                       "approval_1"))))))

(ert-deftest consortium-rlm-session-resolve-deny-carries-reason ()
  (let ((session (consortium-rlm-session--make :name "t"))
        captured)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured))))
      (consortium-rlm-session-resolve-approval
       session "run_1" "approval_1" "deny" "unsafe")
      (let ((frame (json-read-from-string (car captured))))
        (should (equal (cdr (assq 'method frame)) "deny"))
        (should (equal (cdr (assq 'reason (cdr (assq 'params frame))))
                       "unsafe"))))))

(ert-deftest consortium-rlm-session-invalid-decision-signals ()
  (let ((session (consortium-rlm-session--make :name "t")))
    (should-error (consortium-rlm-session-resolve-approval
                   session "run_1" "approval_1" "maybe"))))

;;; Replay ---------------------------------------------------------------

(ert-deftest consortium-rlm-session-replay-rebuilds-view-from-events ()
  (let* ((event-1 (cdr (assq 'event
                             (consortium-rlm-session-tests--daemon-event
                              "run_9" 1 "approval_required"
                              '((approval_id . "approval_9"))))))
         (event-2 (cdr (assq 'event
                             (consortium-rlm-session-tests--daemon-event
                              "run_9" 2 "approval_resolved"
                              '((approval_id . "approval_9")
                                (decision . "approve_diff"))))))
         (session (consortium-rlm-session--make :name "t"))
         (consortium-rlm-session-tests--replay-events (list event-1 event-2))
         replay-outcome)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s _line)
                 (consortium-rlm-session-tests--feed
                  session
                  `((kind . "response") (id . 1) (ok . t)
                    (result . ((events
                                . ,consortium-rlm-session-tests--replay-events))))))))
      (consortium-rlm-session-replay
       session "run_9"
       (lambda (ok view) (setq replay-outcome (list ok view)))))
    (should (car replay-outcome))
    (should-not (consortium-rlm-session-pending-approvals session "run_9"))
    (should (= (length (plist-get (consortium-rlm-session-view session "run_9")
                                  :approvals))
               1))))

(defvar consortium-rlm-session-tests--replay-events nil)

(provide 'consortium-rlm-session-tests)
;;; consortium-rlm-session-tests.el ends here
