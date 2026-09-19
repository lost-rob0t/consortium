;;; ellm_tests.el --- ERT tests for ELLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'ellm)

(defun ellm-test--reset ()
  (clrhash ellm--actors)
  (clrhash ellm--backends)
  (setq ellm--conversation-sequence 0
        ellm--request-sequence 0))

(ert-deftest ellm-defactor-registers-provider-neutral-actor ()
  (ellm-test--reset)
  (ellm-defactor researcher
    :backend 'fake
    :model "test/model"
    :system "Be concise."
    :tools '(output-org-tree)
    :skills '(simple-output))
  (let ((actor (ellm-actor 'researcher)))
    (should (ellm-actor-p actor))
    (should (eq (ellm-actor-name actor) 'researcher))
    (should (eq (ellm-actor-backend actor) 'fake))
    (should (equal (ellm-actor-model actor) "test/model"))
    (should (equal (ellm-actor-tools actor) '(output-org-tree)))
    (should (equal (ellm-actor-skills actor) '(simple-output)))))

(ert-deftest ellm-conversation-is-explicit-and-resettable ()
  (ellm-test--reset)
  (ellm-register-actor 'researcher :backend 'fake :model "test/model")
  (let ((conversation
         (ellm-conversation 'researcher
                            :input '((document . "alpha"))
                            :cache '(system messages))))
    (should (ellm-conversation-p conversation))
    (should (string-prefix-p "conversation-" (ellm-conversation-id conversation)))
    (should (eq (ellm-actor-name (ellm-conversation-actor conversation))
                'researcher))
    (should (equal (ellm-conversation-input conversation)
                   '((document . "alpha"))))
    (should (equal (ellm-conversation-cache conversation)
                   '(system messages)))
    (setf (ellm-conversation-messages conversation)
          '(((role . user) (content . "hello"))))
    (ellm-reset conversation)
    (should-not (ellm-conversation-messages conversation))
    (should (equal (ellm-conversation-input conversation)
                   '((document . "alpha"))))))

(ert-deftest ellm-ask-dispatches-async-request-and-records-history ()
  (ellm-test--reset)
  (let (seen-request callback-result)
    (ellm-register-backend
     'fake
     (lambda (request deliver)
       (setq seen-request request)
       (funcall deliver '((summary . "ok")) nil)
       'fake-handle))
    (ellm-register-actor
     'researcher
     :backend 'fake
     :model "test/model"
     :tools '(output-org-tree)
     :skills '(simple-output))
    (let* ((request
            (ellm-ask
             'researcher
             "Explain this."
             :input '((documents . ("a" "b")))
             :cache '(system tools messages)
             :callback
             (lambda (result error completed-request)
               (setq callback-result
                     (list result error completed-request)))))
           (conversation (ellm-request-conversation request)))
      (should (eq seen-request request))
      (should (eq (ellm-request-state request) 'done))
      (should (eq (ellm-request-handle request) 'fake-handle))
      (should (equal (ellm-request-result request) '((summary . "ok"))))
      (should-not (ellm-request-error request))
      (should (equal (ellm-request-input request)
                     '((documents . ("a" "b")))))
      (should (equal (ellm-request-cache request)
                     '(system tools messages)))
      (should (equal (car callback-result) '((summary . "ok"))))
      (should-not (nth 1 callback-result))
      (should (eq (nth 2 callback-result) request))
      (should
       (equal
        (ellm-conversation-messages conversation)
        '(((role . user) (content . "Explain this."))
          ((role . assistant) (content . ((summary . "ok"))))))))))

(ert-deftest ellm-reply-reuses-conversation-and-explicit-history ()
  (ellm-test--reset)
  (ellm-register-backend
   'fake
   (lambda (request deliver)
     (funcall deliver
              (format "reply-%d"
                      (length
                       (ellm-conversation-messages
                        (ellm-request-conversation request))))
              nil)
     request))
  (ellm-register-actor 'researcher :backend 'fake :model "test/model")
  (let* ((first (ellm-ask 'researcher "first"))
         (conversation (ellm-request-conversation first))
         (second (ellm-reply conversation "second")))
    (should (eq conversation (ellm-request-conversation second)))
    (should (equal (ellm-request-result first) "reply-1"))
    (should (equal (ellm-request-result second) "reply-3"))
    (should (= (length (ellm-conversation-messages conversation)) 4))))

(ert-deftest ellm-backend-errors-become-request-state ()
  (ellm-test--reset)
  (ellm-register-backend
   'fake
   (lambda (_request deliver)
     (funcall deliver nil '((kind . "backend_error")))
     nil))
  (ellm-register-actor 'researcher :backend 'fake)
  (let ((request (ellm-ask 'researcher "fail")))
    (should (eq (ellm-request-state request) 'failed))
    (should-not (ellm-request-result request))
    (should (equal (alist-get 'kind (ellm-request-error request))
                   "backend_error"))))

(provide 'ellm-tests)
;;; ellm_tests.el ends here
