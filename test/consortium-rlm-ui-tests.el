;;; consortium-rlm-ui-tests.el --- prompt surface tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'json)
(require 'consortium-rlm-ui)

(defun consortium-rlm-ui-tests--feed (session frame)
  "Feed one daemon FRAME through SESSION's line handler."
  (consortium-rlm-session--on-line session (json-encode frame)))

(defun consortium-rlm-ui-tests--daemon-event (run-id seq type payload)
  `((kind . "event")
    (event . ((run_id . ,run-id)
              (sequence . ,seq)
              (event_id . ,(format "%s:%d" run-id seq))
              (timestamp . "2026-11-13T00:00:00Z")
              (type . ,type)
              (phase . "analyze")
              (worker . "none")
              (payload . ,payload)))))

;;; Choice surface -------------------------------------------------------

(ert-deftest consortium-rlm-ui-approval-choices-offer-deny ()
  (should (equal (consortium-rlm-ui--approval-choices
                  '((choices . ["approve_diff" "allow_once"])))
                 '("approve_diff" "allow_once" "deny"))))

(ert-deftest consortium-rlm-ui-approval-choices-keep-explicit-deny ()
  (should (equal (consortium-rlm-ui--approval-choices
                  '((choices . ["approve_diff" "deny"])))
                 '("approve_diff" "deny"))))

(ert-deftest consortium-rlm-ui-approval-choices-default-when-absent ()
  (should (equal (consortium-rlm-ui--approval-choices '((approval_id . "a")))
                 '("deny"))))

;;; Event dispatch -------------------------------------------------------

(ert-deftest consortium-rlm-ui-approval-required-prompts-and-resolves ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         captured)
    (setf (consortium-rlm-session-event-hook session)
          #'consortium-rlm-ui--handle-event)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _args) "approve_diff")))
      (consortium-rlm-ui-tests--feed
       session
       (consortium-rlm-ui-tests--daemon-event
        "run_1" 1 "approval_required"
        '((approval_id . "approval_1")
          (name . "apply diff")
          (choices . ["approve_diff" "allow_once" "allow_session"]))))
      (let ((frame (json-read-from-string (car captured))))
        (should (equal (cdr (assq 'method frame)) "approve"))
        (should (equal (cdr (assq 'approval_id (cdr (assq 'params frame))))
                       "approval_1"))
        (should (equal (cdr (assq 'run_id (cdr (assq 'params frame))))
                       "run_1"))))))

(ert-deftest consortium-rlm-ui-deny-choice-asks-reason-and-denies ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         captured)
    (setf (consortium-rlm-session-event-hook session)
          #'consortium-rlm-ui--handle-event)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _coll &rest _args) "deny"))
              ((symbol-function 'read-string)
               (lambda (_prompt &optional _init _hist _def) "unsafe effect")))
      (consortium-rlm-ui-tests--feed
       session
       (consortium-rlm-ui-tests--daemon-event
        "run_1" 1 "approval_required" '((approval_id . "approval_1"))))
      (let ((frame (json-read-from-string (car captured))))
        (should (equal (cdr (assq 'method frame)) "deny"))
        (should (equal (cdr (assq 'reason (cdr (assq 'params frame))))
                       "unsafe effect"))))))

(ert-deftest consortium-rlm-ui-auto-prompt-nil-stays-silent ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         captured
         (consortium-rlm-ui-auto-prompt nil))
    (setf (consortium-rlm-session-event-hook session)
          #'consortium-rlm-ui--handle-event)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured))))
      (consortium-rlm-ui-tests--feed
       session
       (consortium-rlm-ui-tests--daemon-event
        "run_1" 1 "approval_required" '((approval_id . "approval_1"))))
      (should-not captured)
      (should (consortium-rlm-session-pending-approvals session "run_1")))))

(ert-deftest consortium-rlm-ui-question-required-is-advisory-only ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         captured)
    (setf (consortium-rlm-session-event-hook session)
          #'consortium-rlm-ui--handle-event)
    (cl-letf (((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line captured)))
              ((symbol-function 'display-message-or-buffer)
               (lambda (_msg) t)))
      (consortium-rlm-ui-tests--feed
       session
       (consortium-rlm-ui-tests--daemon-event
        "run_1" 1 "question_required"
        '((question_id . "question_1") (prompt . "Profile?"))))
      (should-not captured)
      (should (consortium-rlm-session-pending-questions session "run_1")))))

;;; Default options ------------------------------------------------------

(ert-deftest consortium-rlm-ui-default-run-options-shape ()
  (let ((options consortium-rlm-ui-default-run-options))
    (should (equal (cdr (assq 'worker options)) "rlm"))
    (should (equal (cdr (assq 'provider options)) "openrouter"))
    (should (assq 'models options))
    (should (assq 'budget options))))

(provide 'consortium-rlm-ui-tests)
;;; consortium-rlm-ui-tests.el ends here
