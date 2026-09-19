;;; ellm_gptel_tests.el --- ERT tests for ELLM gptel adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'ellm)
(require 'ellm-gptel)

(defun ellm-gptel-test--reset ()
  (clrhash ellm--actors)
  (clrhash ellm--backends)
  (setq ellm--conversation-sequence 0
        ellm--request-sequence 0
        ellm-prompt-resolver-function nil)
  (ellm-register-backend 'gptel #'ellm-gptel-backend-request))

(ert-deftest ellm-gptel-normalizes-provider-cache-policy ()
  (should
   (equal
    (ellm-gptel-cache-policy '(system tools messages))
    '(system tool message)))
  (should (eq (ellm-gptel-cache-policy t) t))
  (should-not (ellm-gptel-cache-policy nil)))

(ert-deftest ellm-prompt-lib-adapter-reuses-existing-api ()
  (ellm-gptel-test--reset)
  (cl-letf (((symbol-function 'ai/prompt-lib-template-read)
             (lambda (name) (format "prompt:%s" name))))
    (ellm-enable-prompt-lib)
    (should (equal (ellm-prompt 'daily-update)
                   "prompt:daily-update"))))

(ert-deftest ellm-gptel-backend-binds-model-cache-and-explicit-input ()
  (ellm-gptel-test--reset)
  (let (seen-prompt seen-system seen-cache seen-model seen-context)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (prompt &rest args)
                 (setq seen-prompt prompt
                       seen-system (plist-get args :system)
                       seen-cache gptel-cache
                       seen-model gptel-model
                       seen-context gptel-use-context)
                 (funcall (plist-get args :callback)
                          "ok"
                          '(:status "200"))
                 'fake-fsm)))
      (ellm-register-actor
       'researcher
       :backend 'gptel
       :model "test/model"
       :system "Be concise.")
      (let ((request
             (ellm-ask
              'researcher
              "Explain this."
              :input '((document . "alpha"))
              :cache '(system tools messages))))
        (should (equal seen-prompt
                       '("Explain this.\n\nELLM current input:\n((document . \"alpha\"))")))
        (should (equal seen-system "Be concise."))
        (should (equal seen-cache '(system tool message)))
        (should (eq seen-model 'test/model))
        (should-not seen-context)
        (should (eq (ellm-request-handle request) 'fake-fsm))
        (should (eq (ellm-request-state request) 'done))
        (should (equal (ellm-request-result request) "ok"))))))

(ert-deftest ellm-gptel-backend-replays-explicit-conversation-history ()
  (ellm-gptel-test--reset)
  (let (seen-prompt)
    (cl-letf (((symbol-function 'gptel-request)
               (lambda (prompt &rest args)
                 (setq seen-prompt prompt)
                 (funcall (plist-get args :callback)
                          "second answer"
                          '(:status "200"))
                 'fake-fsm)))
      (ellm-register-actor 'researcher :backend 'gptel :model "test/model")
      (let ((conversation
             (ellm-conversation
              'researcher
              :messages
              '(((role . user) (content . "first"))
                ((role . assistant) (content . "first answer"))))))
        (ellm-reply conversation "second")
        (should
         (equal
          seen-prompt
          '("first" "first answer" "second")))))))

(ert-deftest ellm-gptel-failure-becomes-structured-backend-error ()
  (ellm-gptel-test--reset)
  (cl-letf (((symbol-function 'gptel-request)
             (lambda (_prompt &rest args)
               (funcall (plist-get args :callback)
                        nil
                        '(:status "HTTP 500"))
               'fake-fsm)))
    (ellm-register-actor 'researcher :backend 'gptel)
    (let ((request (ellm-ask 'researcher "fail")))
      (should (eq (ellm-request-state request) 'failed))
      (should
       (equal
        (alist-get 'kind (ellm-request-error request))
        "gptel_error"))
      (should
       (equal
        (alist-get 'status (ellm-request-error request))
        "HTTP 500")))))

(provide 'ellm-gptel-tests)
;;; ellm_gptel_tests.el ends here
