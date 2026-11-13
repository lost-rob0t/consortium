;;; consortium-rlm-dsl.el --- defskill/defexpert/defworkflow DSL -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Elisp definitions that compile to Consortium runtime inputs.
;;
;; `consortium-rlm-defskill' defines a skill and materializes it as a
;; SKILL.md package under `consortium-rlm-dsl-skill-root'; exported
;; roots ride the wire as skill_roots options and load server-side
;; through the pinned rlm_skill catalog loader.  `consortium-rlm-defexpert'
;; emits Prolog knowledge clauses (`conortium_expert/2' facts) that
;; consult clean.  `consortium-rlm-defworkflow' composes the canonical
;; config mapping with per-workflow overrides into wire-ready run
;; options.
;;
;; The DSL emits definitions, never authority: model output remains
;; data, and Prolog owns every transition.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'consortium-rlm-config)

(defgroup consortium-rlm-dsl nil
  "Elisp definitions compiling to Consortium runtime inputs."
  :group 'consortium-rlm-config)

(defcustom consortium-rlm-dsl-skill-root
  (locate-user-emacs-file "consortium-skills")
  "Directory under which `consortium-rlm-defskill' packages export."
  :type 'directory)

(defvar consortium-rlm-dsl-skills nil
  "Registered skills as (NAME . PLIST) with :name, :description, :body.")

(defvar consortium-rlm-dsl-experts nil
  "Registered experts as (NAME . PLIST) with runtime-side specs.")

(defvar consortium-rlm-dsl-workflows nil
  "Registered workflows as (NAME . PLIST) of run-option overrides.")

(defun consortium-rlm-dsl--error (format &rest args)
  (signal 'consortium-rlm-error
          (list :reason "invalid-dsl-definition"
                :detail (apply #'format format args))))

;;; Skills -----------------------------------------------------------------

(defmacro consortium-rlm-defskill (name docstring &rest keys)
  "Register skill NAME with DOCSTRING and attribute KEYS.
:body is the skill prompt body.  The skill is exported to a SKILL.md
package by `consortium-rlm-dsl-export-skill'.  KEY values are data,
not evaluated."
  (declare (indent defun))
  `(consortium-rlm-dsl--register-skill ',name ,docstring ',keys))

(defun consortium-rlm-dsl--register-skill (name docstring attrs)
  (unless (stringp docstring)
    (consortium-rlm-dsl--error "defskill %s: docstring required" name))
  (let* ((body (plist-get attrs :body))
         (spec (list :name (symbol-name name)
                     :description docstring
                     :body (if (stringp body) body ""))))
    (setf (alist-get name consortium-rlm-dsl-skills nil nil 'eq) spec)
    name))

(defun consortium-rlm-dsl-skill-text (name)
  "Return the SKILL.md file text for registered skill NAME."
  (let ((spec (cdr (assq name consortium-rlm-dsl-skills))))
    (unless spec
      (consortium-rlm-dsl--error "unknown skill: %s" name))
    (concat "---\n"
            "name: " (plist-get spec :name) "\n"
            "description: " (plist-get spec :description) "\n"
            "---\n\n"
            (plist-get spec :body)
            (unless (string-suffix-p "\n" (plist-get spec :body)) "\n"))))

(defun consortium-rlm-dsl-export-skill (name)
  "Write skill NAME under the skill root; return its directory."
  (let* ((spec (cdr (assq name consortium-rlm-dsl-skills))))
    (unless spec
      (consortium-rlm-dsl--error "unknown skill: %s" name))
    (let* ((dir (expand-file-name (plist-get spec :name)
                                  consortium-rlm-dsl-skill-root))
           (file (expand-file-name "SKILL.md" dir)))
      (make-directory dir :parents)
      (with-temp-file file
        (insert (consortium-rlm-dsl-skill-text name)))
      dir)))

(defun consortium-rlm-dsl-exported-skills-p ()
  "Non-nil when at least one exported skill package exists."
  (and consortium-rlm-dsl-skills
       (file-exists-p
        (expand-file-name
         (concat (plist-get (cdr (car consortium-rlm-dsl-skills)) :name)
                 "/SKILL.md")
         consortium-rlm-dsl-skill-root))))

(defun consortium-rlm-dsl-skill-root-options ()
  "Wire options advertising the exported skill root, or nil."
  (when (consortium-rlm-dsl-exported-skills-p)
    `((skill_roots . (,consortium-rlm-dsl-skill-root)))))

;;; Experts ----------------------------------------------------------------

(defmacro consortium-rlm-defexpert (name docstring &rest keys)
  "Register expert NAME with DOCSTRING and attribute KEYS.
:role is a symbolic role, :skills a list of skill names, :constraints
a list of constraint strings.  Emits `conortium_expert/2' knowledge.
KEY values are data, not evaluated."
  (declare (indent defun))
  `(consortium-rlm-dsl--register-expert ',name ,docstring ',keys))

(defun consortium-rlm-dsl--register-expert (name docstring attrs)
  (unless (stringp docstring)
    (consortium-rlm-dsl--error "defexpert %s: docstring required" name))
  (let ((spec (list :role (or (plist-get attrs :role) 'generic)
                    :skills (or (plist-get attrs :skills) '())
                    :constraints (or (plist-get attrs :constraints) '())
                    :description docstring)))
    (setf (alist-get name consortium-rlm-dsl-experts nil nil 'eq) spec)
    name))

(defun consortium-rlm-dsl--prolog-atom (symbol)
  "Render SYMBOL as a Prolog atom, quoting when not plain."
  (let ((name (symbol-name symbol)))
    (if (string-match-p "\\`[a-z][A-Za-z0-9_]*\\'" name)
        name
      (format "'%s'" name))))

(defun consortium-rlm-dsl-expert-prolog (name)
  "Prolog knowledge clause for expert NAME, consultable as-is."
  (let ((spec (cdr (assq name consortium-rlm-dsl-experts))))
    (unless spec
      (consortium-rlm-dsl--error "unknown expert: %s" name))
    (concat
     "% Generated by consortium-rlm-defexpert; do not hand-edit.\n"
     (format "consortium_expert(%s, expertise{role:%s, skills:[%s], constraints:[%s]}).\n"
             (consortium-rlm-dsl--prolog-atom name)
             (consortium-rlm-dsl--prolog-atom (plist-get spec :role))
             (mapconcat #'consortium-rlm-dsl--prolog-atom
                        (plist-get spec :skills) ", ")
             (mapconcat (lambda (s) (format "'%s'" s))
                        (plist-get spec :constraints) ", ")))))

(defun consortium-rlm-dsl-export-experts (file)
  "Write all registered experts as Prolog knowledge to FILE."
  (with-temp-file file
    (dolist (entry consortium-rlm-dsl-experts)
      (insert (consortium-rlm-dsl-expert-prolog (car entry))))))

;;; Workflows --------------------------------------------------------------

(defconst consortium-rlm-dsl-workflow-keys
  '(:provider :worker :models :budget :phase-budget :max-repairs
    :max-rage-cycles :repository :artifact-refs :fact-refs :evidence
    :constraints :acceptance-criteria :skill-roots)
  "Workflow override keys; the same vocabulary the config mapping takes.")

(defmacro consortium-rlm-defworkflow (name docstring &rest keys)
  "Register workflow NAME with DOCSTRING and override KEYS.
`conortium-rlm-workflow-options' composes these with the canonical
configuration mapping.  KEY values are data, not evaluated."
  (declare (indent defun))
  `(consortium-rlm-dsl--register-workflow ',name ,docstring ',keys))

(defun consortium-rlm-dsl--register-workflow (name docstring attrs)
  (unless (stringp docstring)
    (consortium-rlm-dsl--error "defworkflow %s: docstring required" name))
  (let ((unknown (cl-set-difference
                  (cl-loop for k on attrs by #'cddr collect (car k))
                  consortium-rlm-dsl-workflow-keys)))
    (when unknown
      (consortium-rlm-dsl--error "defworkflow %s: unknown keys %s"
                                 name unknown)))
  (setf (alist-get name consortium-rlm-dsl-workflows nil nil 'eq)
        (list :description docstring :overrides attrs))
  name)

(defun consortium-rlm-workflow-options (name)
  "Wire-ready run options for workflow NAME."
  (let ((workflow (cdr (assq name consortium-rlm-dsl-workflows))))
    (unless workflow
      (consortium-rlm-dsl--error "unknown workflow: %s" name))
    (apply #'consortium-rlm-config-run-options
           (plist-get workflow :overrides))))

(provide 'consortium-rlm-dsl)
;;; consortium-rlm-dsl.el ends here
