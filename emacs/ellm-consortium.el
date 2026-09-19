;;; ellm-consortium.el --- Consortium/Prolog-RLM bridge for ELLM -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; This module is the controlled worker bridge for ELLM.  It compiles one
;; default ELLM actor plus optional per-ADARD role actor overrides into the
;; existing Consortium JSONL start protocol.  Consortium owns run lifecycle;
;; Prolog-RLM owns model/tool/skill authority and execution.
;;
;; Pure local ELLM tools are intentionally excluded from worker tool requests.
;; Non-pure or server-only tool names are sent only as inert names.  The daemon
;; resolves those names against trusted Prolog-RLM tool-pack manifests.

;;; Code:

(require 'cl-lib)
(require 'ellm)
(require 'ellm-tools)
(require 'consortium)

(defconst ellm-consortium-roles
  '(root_agent analyze design adversarial_review resolve develop verify)
  "Consortium roles that receive explicit model routes.")

(defconst ellm-consortium--forward-options
  '((:budget . budget)
    (:phase-budget . phase_budget)
    (:repository . repository)
    (:artifact-refs . artifact_refs)
    (:fact-refs . fact_refs)
    (:evidence . evidence)
    (:constraints . constraints)
    (:acceptance-criteria . acceptance_criteria)
    (:max-repairs . max_repairs)
    (:max-rage-cycles . max_rage_cycles))
  "ELLM option names mapped to Consortium protocol option keys.")

(defun ellm-consortium--role-actor (default actors role)
  "Resolve ROLE from ACTORS, falling back to DEFAULT."
  (ellm-actor
   (or (alist-get role actors)
       default)))

(defun ellm-consortium--model (actor)
  "Return model string for ACTOR or signal a useful error."
  (let ((model (ellm-actor-model actor)))
    (cond
     ((and (stringp model) (not (string-empty-p model))) model)
     ((symbolp model) (symbol-name model))
     (t
      (error "ELLM Consortium actor %S needs an explicit model"
             (ellm-actor-name actor))))))

(defun ellm-consortium--name-string (value)
  "Normalize symbol/string VALUE to a protocol string."
  (cond
   ((symbolp value) (symbol-name value))
   ((stringp value) value)
   (t
    (signal 'wrong-type-argument
            (list '(or symbol string) value)))))

(defun ellm-consortium--server-tool-p (name)
  "Return non-nil when tool NAME belongs at the Prolog-RLM boundary.

Known pure ELLM tools stay in Emacs.  Unknown names are treated as inert
server tool references and must resolve against a trusted Prolog-RLM tool
manifest before any model request is admitted."
  (let ((definition (gethash name ellm--tools)))
    (or (null definition)
        (not (eq (ellm-tool-effect definition) 'pure)))))

(defun ellm-consortium--collect (actors accessor &optional predicate)
  "Collect stable unique values from ACTORS using ACCESSOR and PREDICATE."
  (let (result)
    (dolist (actor actors)
      (dolist (value (funcall accessor actor))
        (when (or (null predicate) (funcall predicate value))
          (unless (member value result)
            (setq result (append result (list value)))))))
    result))

(defun ellm-consortium--resolved-role-actors (default actors)
  "Return role actors resolved from DEFAULT and ACTORS overrides."
  (mapcar
   (lambda (role)
     (ellm-consortium--role-actor default actors role))
   ellm-consortium-roles))

(defun ellm-consortium--models (default actors)
  "Compile DEFAULT and ACTORS into a Consortium role-model alist."
  (mapcar
   (lambda (role)
     (cons
      role
      (ellm-consortium--model
       (ellm-consortium--role-actor default actors role))))
   ellm-consortium-roles))

(defun ellm-consortium--forwarded-options (options)
  "Compile supported run OPTIONS for the Consortium protocol."
  (let (result)
    (dolist (mapping ellm-consortium--forward-options)
      (let ((source (car mapping))
            (target (cdr mapping)))
        (when (plist-member options source)
          (setq result
                (append
                 result
                 (list (cons target (plist-get options source))))))))
    result))

(defun ellm-consortium-options (actor &rest options)
  "Compile ACTOR and OPTIONS into Consortium start options.

OPTIONS supports :actors, an alist of ADARD role symbols to ELLM actors.
Unspecified roles use ACTOR.  Tool and skill declarations are the stable
union across the resolved role actors.  Pure local ELLM tools are not sent
to the daemon.

Run policy keys such as :budget, :phase-budget, :repository, :constraints,
:evidence and :acceptance-criteria are forwarded without converting them to
prompt text."
  (let* ((actors (plist-get options :actors))
         (resolved (ellm-consortium--resolved-role-actors actor actors))
         (skills
          (mapcar
           #'ellm-consortium--name-string
           (ellm-consortium--collect resolved #'ellm-actor-skills)))
         (tools
          (mapcar
           #'ellm-consortium--name-string
           (ellm-consortium--collect
            resolved
            #'ellm-actor-tools
            #'ellm-consortium--server-tool-p))))
    (append
     `((worker . "ellm")
       (provider . "openrouter")
       (models . ,(ellm-consortium--models actor actors))
       (skills . ,skills)
       (tools . ,tools))
     (ellm-consortium--forwarded-options options))))

(defun ellm-consortium--without-option (plist key)
  "Return PLIST without KEY and its value."
  (let (result)
    (while plist
      (let ((current (pop plist))
            (value (pop plist)))
        (unless (eq current key)
          (setq result (append result (list current value))))))
    result))

(defun ellm-consortium-submit (actor task &rest options)
  "Submit TASK for ACTOR through Consortium/Prolog-RLM asynchronously.

OPTIONS are accepted by `ellm-consortium-options' plus :callback.
The callback receives RUN-ID and ERROR, matching `consortium-start-task'."
  (let ((callback (plist-get options :callback)))
    (consortium-start-task
     task
     (apply
      #'ellm-consortium-options
      actor
      (ellm-consortium--without-option options :callback))
     callback)))

(defun ellm-consortium-status (run-id callback)
  "Request status for RUN-ID through the existing Consortium client."
  (consortium-status run-id callback))

(defun ellm-consortium-events (run-id since callback)
  "Request RUN-ID events after SINCE through the Consortium client."
  (consortium-events run-id since callback))

(defun ellm-consortium-cancel (run-id callback)
  "Cancel RUN-ID through the existing Consortium client."
  (consortium-cancel run-id callback))

(defun ellm-consortium-artifact (run-id artifact-id callback)
  "Fetch ARTIFACT-ID from RUN-ID through the existing Consortium client."
  (consortium-artifact run-id artifact-id callback))

(provide 'ellm-consortium)
;;; ellm-consortium.el ends here
