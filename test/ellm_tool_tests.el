;;; ellm_tool_tests.el --- ERT tests for ELLM tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'ellm)
(require 'ellm-tools)

(defun ellm-tool-test--reset ()
  (clrhash ellm--tools)
  (setq ellm-effect-dispatch-function nil))

(ert-deftest ellm-tool-injects-current-input-by-default ()
  (ellm-tool-test--reset)
  (ellm-def-tool output-org-tree (input &key heading)
    :effect 'pure
    :description "Render input."
    (list :input input :heading heading))
  (should
   (equal
    (ellm-call-tool
     'output-org-tree
     '((heading . "Recent work"))
     '((documents . ("a" "b"))))
    '(:input ((documents . ("a" "b")))
      :heading "Recent work"))))

(ert-deftest ellm-tool-explicit-input-overrides-current-value ()
  (ellm-tool-test--reset)
  (ellm-def-tool echo-input (input &key label)
    :effect 'pure
    (list input label))
  (should
   (equal
    (ellm-call-tool
     'echo-input
     '((input . "override") (label . "x"))
     "current")
    '("override" "x"))))

(ert-deftest ellm-request-tool-result-becomes-next-current-value ()
  (ellm-tool-test--reset)
  (ellm-def-tool increment (input &key by)
    :effect 'pure
    (+ input (or by 1)))
  (let* ((actor
          (ellm--make-actor :name 'fake :backend 'unused))
         (conversation
          (ellm--make-conversation
           :id "conversation-test"
           :actor actor
           :input 5))
         (request
          (ellm--make-request
           :id "request-test"
           :actor actor
           :conversation conversation
           :input 5)))
    (should (= (ellm-request-call-tool request 'increment '((by . 3))) 8))
    (should (= (ellm-request-input request) 8))
    (should (= (ellm-conversation-input conversation) 8))))

(ert-deftest ellm-effectful-tool-refuses-local-execution-without-bridge ()
  (ellm-tool-test--reset)
  (ellm-def-tool write-file (input &key path)
    :effect 'effectful
    (list input path))
  (let ((error-data
         (condition-case error-data
             (progn
               (ellm-call-tool 'write-file '((path . "x")) "body")
               nil)
           (ellm-tool-error (cadr error-data)))))
    (should error-data)
    (should (equal (alist-get 'kind error-data)
                   "effect_requires_bridge"))
    (should (eq (alist-get 'tool error-data) 'write-file))))

(ert-deftest ellm-effectful-tool-dispatches-through-authority-bridge ()
  (ellm-tool-test--reset)
  (let (seen)
    (ellm-def-tool write-file (input &key path)
      :effect 'effectful
      (list input path))
    (setq ellm-effect-dispatch-function
          (lambda (tool arguments input request)
            (setq seen (list tool arguments input request))
            'admitted-result))
    (should
     (eq
      (ellm-call-tool
       'write-file
       '((path . "x"))
       "body"
       'request-token)
      'admitted-result))
    (should (eq (nth 0 seen) 'write-file))
    (should (equal (nth 1 seen) '((path . "x"))))
    (should (equal (nth 2 seen) "body"))
    (should (eq (nth 3 seen) 'request-token))))

(ert-deftest ellm-tool-implementation-errors-are-structured ()
  (ellm-tool-test--reset)
  (ellm-def-tool explode (input)
    :effect 'pure
    (error "boom: %S" input))
  (let ((error-data
         (condition-case error-data
             (progn
               (ellm-call-tool 'explode nil "value")
               nil)
           (ellm-tool-error (cadr error-data)))))
    (should error-data)
    (should (equal (alist-get 'kind error-data)
                   "implementation_error"))
    (should (eq (alist-get 'tool error-data) 'explode))
    (should (string-match-p "boom" (alist-get 'message error-data)))))

(provide 'ellm-tool-tests)
;;; ellm_tool_tests.el ends here
