;;; consortium_emacs_tests.el --- ERT tests for Consortium -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'consortium)

(defun consortium-test--reset ()
  (when (process-live-p consortium-process)
    (delete-process consortium-process))
  (setq consortium-process nil
        consortium--input ""
        consortium--next-request-id 0
        consortium-event-hook nil)
  (clrhash consortium--callbacks)
  (clrhash consortium--run-events)
  (clrhash consortium--run-statuses)
  (clrhash consortium--latest-status-request))

(defun consortium-test--await (predicate &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 5.0))))
    (while (and (not (funcall predicate))
                (< (float-time) deadline))
      (accept-process-output consortium-process 0.05))
    (should (funcall predicate))))

(ert-deftest consortium-request-is-immediate-and-jsonl ()
  (consortium-test--reset)
  (let (sent)
    (setq consortium-process 'fake-process)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-send-string)
               (lambda (_ text) (setq sent text))))
      (let ((request-id
             (consortium-request "status" '((run_id . "run-1")) #'ignore)))
        (should (= request-id 1))
        (should (string-suffix-p "\n" sent))
        (let ((request (json-parse-string sent :object-type 'alist)))
          (should (= (alist-get 'id request) request-id))
          (should (equal (alist-get 'method request) "status")))))))

(ert-deftest consortium-filter-handles-partial-lines-and-dispatches-callback ()
  (consortium-test--reset)
  (let (received)
    (puthash 7 (lambda (result error) (setq received (list result error)))
             consortium--callbacks)
    (consortium--process-filter nil
                                "{\"kind\":\"response\",\"id\":7,\"ok\":true,")
    (should-not received)
    (consortium--process-filter nil "\"result\":{\"run_id\":\"run-7\"}}\n")
    (should (equal (alist-get 'run_id (car received)) "run-7"))
    (should-not (cadr received))
    (should-not (gethash 7 consortium--callbacks))))

(ert-deftest consortium-events-ignore-stale-sequences ()
  (consortium-test--reset)
  (consortium--handle-line
   "{\"kind\":\"event\",\"event\":{\"run_id\":\"run-1\",\"sequence\":2,\"type\":\"phase.started\",\"phase\":\"design\",\"payload\":{}}}")
  (consortium--handle-line
   "{\"kind\":\"event\",\"event\":{\"run_id\":\"run-1\",\"sequence\":1,\"type\":\"run.failed\",\"phase\":\"analyze\",\"payload\":{}}}")
  (let ((state (consortium-run-state "run-1")))
    (should (= (alist-get 'sequence state) 2))
    (should (equal (alist-get 'type state) "phase.started"))
    (should (equal (alist-get 'phase state) "design"))))

(ert-deftest consortium-status-response-cannot-overwrite-newer-request ()
  (consortium-test--reset)
  (puthash "run-1" 9 consortium--latest-status-request)
  (consortium--record-status 8 '((run_id . "run-1") (state . "running")))
  (should-not (consortium-run-state "run-1"))
  (consortium--record-status 9 '((run_id . "run-1") (state . "cancelled")))
  (should (equal (alist-get 'state (consortium-run-state "run-1"))
                 "cancelled")))

(ert-deftest consortium-sentinel-fails-and-clears-pending-callbacks ()
  (consortium-test--reset)
  (let (received)
    (setq consortium-process 'dead-process)
    (puthash 4 (lambda (result error) (setq received (list result error)))
             consortium--callbacks)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil)))
      (consortium--process-sentinel 'dead-process "exited"))
    (should (equal (alist-get 'kind (cadr received)) "daemon_exited"))
    (should (= (hash-table-count consortium--callbacks) 0))))

(ert-deftest consortium-make-process-remains-responsive-during-active-run ()
  (consortium-test--reset)
  (let ((command (getenv "CONSORTIUM_COMMAND"))
        run-id status cancel-result cancelled-event)
    (skip-unless (and command (file-executable-p command)))
    (unwind-protect
        (progn
          (consortium-connect (list command "daemon" "--memory"))
          (add-hook 'consortium-event-hook
                    (lambda (event)
                      (when (equal (alist-get 'type event) "run.cancelled")
                        (setq cancelled-event event))))
          (let ((request-id
                 (consortium-start-task
                  "Emacs async integration"
                  '((worker . "blocking"))
                  (lambda (id error)
                    (should-not error)
                    (setq run-id id)))))
            (should (integerp request-id)))
          (consortium-test--await (lambda () run-id))
          (consortium-status
           run-id
           (lambda (result error)
             (should-not error)
             (setq status result)))
          (consortium-test--await (lambda () status))
          (should (equal (alist-get 'state status) "running"))
          (consortium-cancel
           run-id
           (lambda (result error)
             (should-not error)
             (setq cancel-result result)))
          (consortium-test--await (lambda () cancel-result))
          (consortium-test--await (lambda () cancelled-event))
          (should (equal (alist-get 'status cancel-result) "cancelled"))
          (should (equal (alist-get 'run_id cancelled-event) run-id)))
      (consortium-disconnect))))

(provide 'consortium-emacs-tests)
;;; consortium_emacs_tests.el ends here
