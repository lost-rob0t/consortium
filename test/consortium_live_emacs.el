;;; consortium_live_emacs.el --- Credentialed Consortium smoke -*- lexical-binding: t; -*-

(require 'consortium)

(defun consortium-live--await (predicate deadline)
  (while (and (not (funcall predicate)) (< (float-time) deadline))
    (accept-process-output consortium-process 0.1))
  (funcall predicate))

(defun consortium-live-main ()
  (let ((command (or (getenv "CONSORTIUM_COMMAND") consortium-program))
        (deadline (+ (float-time) 360.0))
        run-id terminal status)
    (unwind-protect
        (progn
          (consortium-connect (list command "daemon" "--memory"))
          (add-hook 'consortium-event-hook
                    (lambda (event)
                      (when (member (alist-get 'type event)
                                    '("run.completed" "run.failed"
                                      "run.cancelled"))
                        (setq terminal event))))
          (consortium-start-task
           "Run a bounded harness-conformance exercise without changing files. Analyze the supplied fixture identity, design a no-effect conformance run, adversarially review it, approve it when the explicit criteria are satisfied, describe the realized conformance artifact, and verify that exact artifact identity."
           (append consortium-default-options
                   '((repository . ((kind . "fixture")
                                    (value . "consortium-live-contract-v1")))
                     (constraints . ("No filesystem, process, or repository mutation"))
                     (acceptance_criteria
                      . ("Every phase returns its required structured fields"
                         "Resolve approves only if the no-effect design is coherent"
                         "Verify binds to the exact implementation artifact hash"))))
           (lambda (id error)
             (when error (error "start failed: %S" error))
             (setq run-id id)))
          (unless (consortium-live--await (lambda () run-id) deadline)
            (error "timed out waiting for run admission"))
          (unless (consortium-live--await (lambda () terminal) deadline)
            (error "timed out waiting for terminal event"))
          (consortium-status
           run-id
           (lambda (result error)
             (when error (error "status failed: %S" error))
             (setq status result)))
          (unless (consortium-live--await (lambda () status) deadline)
            (error "timed out waiting for status"))
          (princ (format "run_id=%s\n" run-id))
          (princ (format "terminal=%s\n" (alist-get 'type terminal)))
          (princ (format "phase=%s\n" (alist-get 'phase terminal)))
          (princ (format "terminal_payload=%S\n" (alist-get 'payload terminal)))
          (princ (format "state=%s\n" (alist-get 'state status)))
          (princ (format "model_calls=%s\n"
                         (alist-get 'model_calls (alist-get 'usage status))))
          (princ (format "total_tokens=%s\n"
                         (alist-get 'total_tokens (alist-get 'usage status))))
          (unless (equal (alist-get 'type terminal) "run.completed")
            (kill-emacs 1)))
      (consortium-disconnect))))

(consortium-live-main)
