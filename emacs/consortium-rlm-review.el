;;; consortium-rlm-review.el --- Region review surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Region-based review for the Consortium workbench: select a region and
;; review it against a manual rubric checklist, or send it through the
;; daemon as a budgeted run whose findings are anchored locally.
;;
;; The manual rubric path is static local data and works with the
;; daemon and every provider fully off.  The AI path always carries
;; explicit budgets, records the daemon run id for lineage, renders
;; findings in their own buffer, never mutates the source region, and
;; never posts anything anywhere by itself.  Rubric defaults are
;; distilled from the operator's ponytail-review, grill, and
;; impeccable review skills.

;;; Code:

(require 'subr-x)
(require 'transient)
(require 'consortium-rlm-ui)

(defgroup consortium-rlm-review nil
  "Region review: manual rubric checklists and budgeted AI review."
  :group 'tools)

(defcustom consortium-rlm-review-rubrics
  '(("ponytail-review"
     . ("Could a simpler design deliver the same behavior?"
        "Is any code speculative, with no concrete current requirement?"
        "Is there a second code path duplicating an existing one?"
        "Are dependencies added beyond what the task needs?"
        "Does every abstraction earn its keep, or can it be inlined?"))
    ("grill"
     . ("Is every claim backed by evidence (tests, logs, artifacts)?"
        "Which assumptions are load-bearing and untested?"
        "What is the most likely way this fails in practice?"
        "Do the tests pin the required behavior, or only the happy path?"
        "What happens at the boundaries (empty, huge, concurrent, offline)?"))
    ("impeccable"
     . ("Does the result read as intentional: consistent spacing, hierarchy, terminology?"
        "Is keyboard access complete and focus always visible?"
        "Are the loading, empty, error, and success states covered?"
        "Do labels and messages speak the user's language, without jargon?"
        "Is the change consistent with the surrounding style and patterns?")))
  "Named manual review rubrics as (NAME . CHECKLIST-ITEMS).
The manual path uses this data directly; it is local, static, and
AI-free."
  :type '(alist :key-type string :value-type (repeat string)))

(defcustom consortium-rlm-review-ai-options
  '((worker . "rlm")
    (provider . "openrouter")
    (models . ((root_agent . "z-ai/glm-4.6")
               (analyze . "z-ai/glm-4.6")
               (design . "z-ai/glm-4.6")
               (adversarial_review . "z-ai/glm-4.6")
               (resolve . "z-ai/glm-4.6")
               (develop . "z-ai/glm-4.6")
               (verify . "z-ai/glm-4.6")))
    (budget . ((max_total_tokens . 8000)
               (max_cost_usd . 0.5)
               (time_limit . 120.0)))
    (phase_budget . ((max_total_tokens . 2000)
                     (max_cost_usd . 0.25)
                     (time_limit . 45.0))))
  "Run options for AI region review.
Budgets are mandatory: a review must never run against a provider
without an explicit budget."
  :type 'sexp)

(defcustom consortium-rlm-review-record-directory
  (locate-user-emacs-file "consortium-reviews")
  "Directory for local review records written by `consortium-rlm-review-record'."
  :type 'directory)

(defvar consortium-rlm-review--pending-request nil
  "In-flight AI review start as (CONTEXT . CALLBACK), or nil.")

(defvar consortium-rlm-review--pending nil
  "Alist (RUN-ID . CONTEXT) of started AI reviews awaiting completion.")

(defvar consortium-rlm-review--base-hook nil
  "Session event hook that was installed before review observation.")

(defvar-local consortium-rlm-review--context nil
  "Review context plist of the buffer's source region.")

;;; Region context ---------------------------------------------------------

(defun consortium-rlm-review--region-bounds (&optional beg end)
  "Resolve the region bounds from BEG/END or the active region."
  (cond ((and beg end) (list beg end))
        ((use-region-p) (list (region-beginning) (region-end)))
        (t (user-error "No active region"))))

(defun consortium-rlm-review--context (beg end)
  "Return the review context plist for BEG..END in the current buffer."
  (list :file (buffer-file-name)
        :buffer (buffer-name)
        :beg beg
        :end end
        :beg-line (line-number-at-pos beg)
        :end-line (line-number-at-pos end)
        :text (buffer-substring-no-properties beg end)))

(defun consortium-rlm-review--anchor (context)
  "Return the one-line source anchor for CONTEXT."
  (format "%s (lines %d-%d)"
          (or (plist-get context :file) (plist-get context :buffer))
          (plist-get context :beg-line)
          (plist-get context :end-line)))

(defun consortium-rlm-review--buffer-name (context)
  "Return the review buffer name for CONTEXT."
  (concat "*Consortium Review: "
          (or (plist-get context :file) (plist-get context :buffer))
          "*"))

;;; Manual rubric path (zero AI) -------------------------------------------

(defun consortium-rlm-review--org-checklist (rubric-name)
  "Return the org checkbox lines for RUBRIC-NAME."
  (mapcar (lambda (item) (format "- [ ] %s" item))
          (or (cdr (assoc rubric-name consortium-rlm-review-rubrics))
              (user-error "Unknown rubric: %s" rubric-name))))

(defun consortium-rlm-review-region-manual (&optional beg end rubric)
  "Review the region BEG..END against rubric RUBRIC.
Purely local: no daemon, no provider, no AI.  Interactively the
rubric is chosen with `completing-read'."
  (interactive (consortium-rlm-review--region-bounds))
  (pcase-let* ((`(,beg ,end) (consortium-rlm-review--region-bounds beg end))
               (rubric (or rubric
                           (completing-read
                            "Rubric: "
                            (mapcar #'car consortium-rlm-review-rubrics)
                            nil t)))
               (context (consortium-rlm-review--context beg end))
               (buffer (get-buffer-create
                        (consortium-rlm-review--buffer-name context))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (org-mode)
      (insert
       "#+TITLE: Consortium manual review: " rubric "\n"
       "#+SOURCE: " (consortium-rlm-review--anchor context) "\n"
       "#+MODE: manual (no AI involved)\n"
       "#+DATE: " (format-time-string "%Y-%m-%d %a %H:%M") "\n\n"
       "* Region\n#+BEGIN_EXAMPLE\n" (plist-get context :text)
       "\n#+END_EXAMPLE\n\n"
       "* Checklist\n"
       (string-join (consortium-rlm-review--org-checklist rubric) "\n")
       "\n\n* Notes\n")
      (setq consortium-rlm-review--context context))
    (pop-to-buffer buffer)
    buffer))

;;; Local disposition record -----------------------------------------------

(defun consortium-rlm-review--slug (context)
  "Return a filesystem-safe slug for CONTEXT's anchor."
  (replace-regexp-in-string "[^A-Za-z0-9]+" "_"
                            (consortium-rlm-review--anchor context)))

(defun consortium-rlm-review-record ()
  "Append this review buffer to a local record file and report it.
Nothing is sent anywhere: the record is a plain local org file."
  (interactive)
  (unless consortium-rlm-review--context
    (user-error "Not a Consortium review buffer"))
  (let* ((directory (expand-file-name consortium-rlm-review-record-directory))
         (file (expand-file-name
                (concat (format-time-string "%Y%m%d-%H%M%S") "-"
                        (consortium-rlm-review--slug
                         consortium-rlm-review--context)
                        ".org")
                directory)))
    (make-directory directory t)
    (append-to-file (point-min) (point-max) file)
    (message "Consortium review recorded: %s" file)))

;;; AI path (budgeted daemon run) ------------------------------------------

(defun consortium-rlm-review--ai-task (context)
  "Return the review task text for CONTEXT."
  (concat "Review this code region. Report concrete findings as a "
          "list, each anchored to what you observed; do not modify "
          "the code.\n\nRegion text:\n"
          (plist-get context :text)))

(defun consortium-rlm-review--install-hook (session)
  "Install the review event observer on SESSION once."
  (unless (eq (consortium-rlm-session-event-hook session)
              #'consortium-rlm-review--handle-event)
    (setq consortium-rlm-review--base-hook
          (consortium-rlm-session-event-hook session))
    (setf (consortium-rlm-session-event-hook session)
          #'consortium-rlm-review--handle-event)))

(defun consortium-rlm-review--start-result (session context ok result)
  "Handle a review `start' response: register lineage or report failure."
  (setq consortium-rlm-review--pending-request nil)
  (if (not ok)
      (message "Consortium AI review failed to start: %S" result)
    (let ((run-id (or (cdr (assq 'run_id result)) "unknown")))
      (consortium-rlm-review--install-hook session)
      (push (cons run-id context) consortium-rlm-review--pending)
      (message "Consortium AI review started: %s" run-id))))

(defun consortium-rlm-review-region-ai (&optional beg end)
  "Send the region BEG..END through the daemon as a budgeted review run.
The run id is recorded for lineage; findings are rendered in their
own buffer anchored to the region when the run finishes.  The
source buffer is never mutated and nothing is posted anywhere."
  (interactive (consortium-rlm-review--region-bounds))
  (pcase-let* ((`(,beg ,end) (consortium-rlm-review--region-bounds beg end))
               (context (consortium-rlm-review--context beg end))
               (session (consortium-rlm-ui-connect)))
    (setq consortium-rlm-review--pending-request
          (cons context
                (lambda (ok result)
                  (consortium-rlm-review--start-result
                   session context ok result))))
    (consortium-rlm-session-request
     session "start"
     `((task . ,(consortium-rlm-review--ai-task context))
       (options . ,consortium-rlm-review-ai-options))
     (cdr consortium-rlm-review--pending-request))
    (message "Consortium AI review requested")))

(defun consortium-rlm-review--render-findings (context run-id view)
  "Render the finished review run RUN-ID's VIEW findings for CONTEXT."
  (let ((buffer (get-buffer-create
                 (consortium-rlm-review--buffer-name context))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (org-mode)
      (insert
       "#+TITLE: Consortium AI review findings\n"
       "#+SOURCE: " (consortium-rlm-review--anchor context) "\n"
       "#+RUN: " run-id " (consortium daemon lineage)\n"
       "#+DATE: " (format-time-string "%Y-%m-%d %a %H:%M") "\n\n"
       "* Region\n#+BEGIN_EXAMPLE\n" (plist-get context :text)
       "\n#+END_EXAMPLE\n\n"
       "* Findings\n")
      (dolist (message (plist-get view :messages))
        (when (string-equal (or (cdr (assq 'status message)) "")
                            "complete")
          (insert "\n" (or (cdr (assq 'text message)) "") "\n")))
      (setq consortium-rlm-review--context context))
    (pop-to-buffer buffer)
    (message "Consortium AI review %s finished" run-id)))

(defun consortium-rlm-review--handle-event (session run-id event-type
                                                   payload view)
  "Session event hook: render findings when a reviewed run finishes.
Other events are forwarded to the hook that was installed before
review observation, so approval and question prompts keep working."
  (let ((base consortium-rlm-review--base-hook))
    (when (and view
               (assoc run-id consortium-rlm-review--pending)
               (string-equal (or (plist-get view :status) "")
                             "finished"))
      (let ((context (cdr (assoc run-id consortium-rlm-review--pending))))
        (setq consortium-rlm-review--pending
              (delete (cons run-id context) consortium-rlm-review--pending))
        (when (null consortium-rlm-review--pending)
          (setf (consortium-rlm-session-event-hook session)
                consortium-rlm-review--base-hook)
          (setq consortium-rlm-review--base-hook nil))
        (consortium-rlm-review--render-findings context run-id view)))
    (when (and (functionp base)
               (eq (consortium-rlm-session-event-hook session)
                   #'consortium-rlm-review--handle-event))
      (funcall base session run-id event-type payload view))))

;;; Entry point -------------------------------------------------------------

(transient-define-prefix consortium-rlm-review-region ()
  "Review the active region with Consortium.
Manual rubric review is AI-free; AI review is a budgeted daemon
run with recorded lineage."
  [:description
   "Consortium region review"
   ("r" "manual rubric review (no AI)"
    consortium-rlm-review-region-manual)
   ("a" "AI review (budgeted daemon run)"
    consortium-rlm-review-region-ai)])

(provide 'consortium-rlm-review)
;;; consortium-rlm-review.el ends here
