;;; consortium-rlm-tools-tests.el --- ERT for async elisp tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Tests for `consortium-rlm-tools': workflow-mode tools are thin
;; async proxies to admitted daemon methods only; free-mode tools are
;; plain local elisp without lineage or authority.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'consortium-rlm-tools)
(require 'consortium-rlm-session)

(ert-deftest consortium-rlm-tools-admitted-methods-pinned ()
  "The admitted daemon method vocabulary is the protocol surface."
  (should (equal consortium-rlm-tools-admitted-methods
                 '("start" "status" "events" "artifact" "cancel"
                   "approve" "deny" "subscribe" "unsubscribe"))))

(ert-deftest consortium-rlm-tools-proxy-rejects-unadmitted-method ()
  "Defining a proxy for a non-admitted method fails closed."
  (should-error (consortium-rlm-deftool bad-proxy :workflow :method "shell"))
  (should-error (consortium-rlm-deftool bad-proxy-2 :workflow :method "eval")))

(ert-deftest consortium-rlm-tools-proxy-routes-through-session ()
  "Workflow tools proxy admitted methods; they never run effects locally."
  (consortium-rlm-deftool demo-status :workflow :method "status"
    :doc "Proxy the daemon status method.")
  (let* ((requests nil)
         (session (consortium-rlm-session--make :name "fake")))
    (setf (consortium-rlm-session-connection session) 'fake)
    (cl-letf (((symbol-function 'consortium-rlm-process-send)
               (lambda (_conn line)
                 (push line requests))))
      (let ((id (consortium-rlm-tool-call session 'demo-status
                                          '((run_id . "r1"))
                                          (lambda (_ok _result)))))
        (should (integerp id))))
    (should (= (length requests) 1))
    (should (string-match-p "\"method\":\"status\"" (car requests)))))

(ert-deftest consortium-rlm-tools-proxy-requires-session ()
  "Workflow tools fail closed without a live session."
  (consortium-rlm-deftool demo-cancel :workflow :method "cancel"
    :doc "Proxy the daemon cancel method.")
  (should-error (consortium-rlm-tool-call nil 'demo-cancel
                                          '((run_id . "r1")))))

(ert-deftest consortium-rlm-tools-free-tool-runs-locally-async ()
  "Free tools run without a session and call back asynchronously."
  (consortium-rlm-deftool demo-echo :free :args (text)
    :doc "Echo TEXT locally without lineage."
    :body (upcase text))
  (let* ((result nil)
         (callback (lambda (ok value)
                     (setq result (list ok value)))))
    (let ((handle (consortium-rlm-tool-call nil 'demo-echo
                                            '("word") callback)))
      (should handle)
      ;; Non-blocking: the callback has not run synchronously.
      (should (null result))
      (let ((waited 0))
        (while (and (null result) (< waited 100))
          (sleep-for 0.01)
          (cl-incf waited 1)))
      (should (equal result '(t "WORD"))))))

(ert-deftest consortium-rlm-tools-free-tool-errors-reach-callback ()
  (consortium-rlm-deftool demo-boom :free :args ()
    :doc "Always fails."
    :body (error "boom"))
  (let* ((result nil)
         (callback (lambda (ok value)
                     (setq result (list ok value)))))
    (consortium-rlm-tool-call nil 'demo-boom nil callback)
    (let ((waited 0))
      (while (and (null result) (< waited 100))
        (sleep-for 0.01)
        (cl-incf waited 1)))
    (should (eq (car result) nil))))

(ert-deftest consortium-rlm-tools-unknown-tool-signals ()
  (should-error (consortium-rlm-tool-call nil 'no-such-tool nil)))

(ert-deftest consortium-rlm-tools-registry-docs ()
  (consortium-rlm-deftool demo-docd :free :args (x)
    :doc "Documented free tool."
    :body x)
  (should (equal (consortium-rlm-tool-doc 'demo-docd)
                 "Documented free tool."))
  (should (memq 'demo-docd (consortium-rlm-tools))))

(provide 'consortium-rlm-tools-tests)
;;; consortium-rlm-tools-tests.el ends here
