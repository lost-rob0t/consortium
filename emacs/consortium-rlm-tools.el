;;; consortium-rlm-tools.el --- async elisp tools -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Gptel-style tools defined in Emacs Lisp with non-blocking
;; execution.
;;
;; Workflow-mode tools are thin proxies to admitted daemon methods:
;; the model proposes, Prolog decides.  There is no second runtime
;; and no local effect path; a proxy for any method outside
;; `consortium-rlm-tools-admitted-methods' fails closed at definition
;; time.  Free-mode tools are plain local elisp without lineage or
;; authority; they never see a session.
;;
;; Tool execution never blocks the editor: workflow proxies ride the
;; async session request layer, and free tools run on a timer and
;; deliver results through their callback.

;;; Code:

(require 'cl-lib)
(require 'consortium-rlm-session)

(defconst consortium-rlm-tools-admitted-methods
  '("start" "status" "events" "artifact" "cancel" "approve" "deny"
    "subscribe" "unsubscribe")
  "Daemon methods workflow-mode tools may proxy.  This is the
protocol dispatch surface of prolog/consortium_protocol.pl; growing
it requires a protocol change, not a tool definition.")

(defvar consortium-rlm-tools-registry nil
  "Registered tools as (NAME . PLIST) with :mode, :method, :function,
:doc, and :args.")

(defun consortium-rlm-tools--error (format &rest args)
  (signal 'consortium-rlm-error
          (list :reason "invalid-tool"
                :detail (apply #'format format args))))

(defun consortium-rlm-tools--register (name plist)
  (setf (alist-get name consortium-rlm-tools-registry nil nil 'eq)
        (plist-put plist :name name))
  name)

;;; Workflow-mode proxies --------------------------------------------------

(defmacro consortium-rlm-deftool (name mode &rest keys)
  "Define tool NAME in MODE (:workflow or :free).

Workflow tools take :method, an admitted daemon method, and proxy it
through a live session.  Free tools take :args and a body form
evaluating to the result; the body is data and may refer to the
argument symbols."
  (declare (indent defun))
  `(consortium-rlm-tools--define ',name ,mode ',keys))

(defun consortium-rlm-tools--define (name mode keys)
  (pcase mode
    (:workflow
     (let ((method (plist-get keys :method))
           (doc (or (plist-get keys :doc) "")))
       (unless (and (stringp method)
                    (member method consortium-rlm-tools-admitted-methods))
         (consortium-rlm-tools--error
          "workflow tool %s: method %S is not admitted" name method))
       (consortium-rlm-tools--register
        name (list :mode :workflow :method method :doc doc))))
    (:free
     (let* ((args (plist-get keys :args))
            (doc (or (plist-get keys :doc) ""))
            (body (plist-get keys :body)))
       (unless (and (listp args) (cl-every #'symbolp args))
         (consortium-rlm-tools--error
          "free tool %s: :args must be a plain argument list" name))
       (unless body
         (consortium-rlm-tools--error "free tool %s: :body required" name))
       (consortium-rlm-tools--register
        name (list :mode :free :args args :doc doc
                   :function (cons 'lambda (cons args (list body)))))))
    (_ (consortium-rlm-tools--error
       "tool %s: mode must be :workflow or :free" name))))

;;; Execution --------------------------------------------------------------

(defun consortium-rlm-tool-call (session name args &optional callback)
  "Run tool NAME with ARGS, delivering (ok VALUE) to CALLBACK.

Workflow tools require a live SESSION and return the daemon request
id.  Free tools ignore SESSION, run on a timer, and return the timer
object.  Both paths are non-blocking."
  (let ((tool (cdr (assq name consortium-rlm-tools-registry))))
    (unless tool
      (consortium-rlm-tools--error "unknown tool: %s" name))
    (pcase (plist-get tool :mode)
      (:workflow
       (unless (and session
                    (consortium-rlm-session-connection session))
         (consortium-rlm-tools--error
          "workflow tool %s requires a live session" name))
       (consortium-rlm-session-request
        session (plist-get tool :method) args callback))
      (:free
       (let ((function (plist-get tool :function)))
         (run-at-time
          0 nil
          (lambda ()
            (condition-case err
                (let ((value (apply function args)))
                  (when callback (funcall callback t value)))
              (t (when callback (funcall callback nil err)))))))))))

;;; Introspection ----------------------------------------------------------

(defun consortium-rlm-tools ()
  "Names of all registered tools."
  (mapcar #'car consortium-rlm-tools-registry))

(defun consortium-rlm-tool-doc (name)
  "Documentation string of tool NAME."
  (let ((tool (cdr (assq name consortium-rlm-tools-registry))))
    (unless tool
      (consortium-rlm-tools--error "unknown tool: %s" name))
    (plist-get tool :doc)))

(provide 'consortium-rlm-tools)
;;; consortium-rlm-tools.el ends here
