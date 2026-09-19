;;; ellm_consortium_tests.el --- ERT tests for ELLM Consortium bridge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'ellm)
(require 'ellm-tools)
(require 'ellm-consortium)

(defun ellm-consortium-test--reset ()
  (clrhash ellm--actors)
  (clrhash ellm--tools))

(ert-deftest ellm-consortium-options-compile-actor-to-prolog-rlm-run ()
  (ellm-consortium-test--reset)
  (ellm-def-tool output-org-tree (input)
    :effect 'pure
    input)
  (ellm-register-tool
   'project_read
   :effect 'effectful
   :function #'identity)
  (ellm-register-actor
   'researcher
   :model "openrouter/glm-5.3-flash"
   :tools '(output-org-tree project_read)
   :skills '(simple-output))
  (let* ((options (ellm-consortium-options 'researcher))
         (models (alist-get 'models options)))
    (should (equal (alist-get 'worker options) "ellm"))
    (should (equal (alist-get 'provider options) "openrouter"))
    (dolist (role ellm-consortium-roles)
      (should
       (equal
        (alist-get role models)
        "openrouter/glm-5.3-flash")))
    (should (equal (alist-get 'skills options) '("simple-output")))
    (should (equal (alist-get 'tools options) '("project_read")))))

(ert-deftest ellm-consortium-role-actors-preserve-per-phase-model-routing ()
  (ellm-consortium-test--reset)
  (ellm-register-actor 'default :model "openrouter/default")
  (ellm-register-actor 'critic :model "openrouter/critic" :skills '(review))
  (let* ((options
          (ellm-consortium-options
           'default
           :actors '((adversarial_review . critic))))
         (models (alist-get 'models options)))
    (should (equal (alist-get 'analyze models) "openrouter/default"))
    (should
     (equal
      (alist-get 'adversarial_review models)
      "openrouter/critic"))
    (should (equal (alist-get 'skills options) '("review")))))

(ert-deftest ellm-consortium-submit-reuses-existing-async-client ()
  (ellm-consortium-test--reset)
  (ellm-register-actor 'researcher :model "openrouter/test")
  (let (seen-task seen-options seen-callback)
    (cl-letf (((symbol-function 'consortium-start-task)
               (lambda (task options callback)
                 (setq seen-task task
                       seen-options options
                       seen-callback callback)
                 77)))
      (let ((request-id
             (ellm-consortium-submit
              'researcher
              "Implement the slice."
              :budget '((max_total_tokens . 12000)
                        (max_cost_usd . 1.0)
                        (time_limit . 120.0))
              :callback #'ignore)))
        (should (= request-id 77))
        (should (equal seen-task "Implement the slice."))
        (should (equal (alist-get 'worker seen-options) "ellm"))
        (should
         (equal
          (alist-get 'budget seen-options)
          '((max_total_tokens . 12000)
            (max_cost_usd . 1.0)
            (time_limit . 120.0))))
        (should (eq seen-callback #'ignore))))))

(ert-deftest ellm-consortium-run-api-is-thin-client-delegation ()
  (let (calls)
    (cl-letf (((symbol-function 'consortium-status)
               (lambda (run callback)
                 (push (list 'status run callback) calls) 1))
              ((symbol-function 'consortium-events)
               (lambda (run since callback)
                 (push (list 'events run since callback) calls) 2))
              ((symbol-function 'consortium-cancel)
               (lambda (run callback)
                 (push (list 'cancel run callback) calls) 3))
              ((symbol-function 'consortium-artifact)
               (lambda (run artifact callback)
                 (push (list 'artifact run artifact callback) calls) 4)))
      (should (= (ellm-consortium-status "run-1" #'ignore) 1))
      (should (= (ellm-consortium-events "run-1" 9 #'ignore) 2))
      (should (= (ellm-consortium-cancel "run-1" #'ignore) 3))
      (should (= (ellm-consortium-artifact "run-1" "a-1" #'ignore) 4))
      (should (= (length calls) 4)))))

(provide 'ellm-consortium-tests)
;;; ellm_consortium_tests.el ends here
