;;; consortium-rlm-dsl-tests.el --- ERT for defskill/defexpert/defworkflow -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Tests for the elisp->Prolog DSL: skills materialize SKILL.md
;; catalogs whose bytes round-trip against checked-in fixtures (the
;; PlUnit suite consults/loads the very same fixtures), experts emit
;; Prolog knowledge clauses that consult clean, and workflows emit
;; wire-ready run options through the canonical config mapping.

;;; Code:

(require 'ert)
(require 'consortium-rlm-dsl)

(defconst consortium-rlm-dsl-tests--fixture-dir
  (expand-file-name
   "fixtures/dsl" (file-name-directory load-file-name)))

(ert-deftest consortium-rlm-dsl-defskill-registers ()
  (consortium-rlm-defskill dsl-demo
    "A demo skill pinned byte-for-byte by the PlUnit catalog fixture."
    :body "When asked to demonstrate the DSL, reply that the elisp
defskill surface reached the runtime catalog.")
  (let ((spec (cdr (assq 'dsl-demo consortium-rlm-dsl-skills))))
    (should spec)
    (should (equal (plist-get spec :name) "dsl-demo"))
    (should (stringp (plist-get spec :description)))))

(ert-deftest consortium-rlm-dsl-skill-file-round-trips-fixture ()
  "The exported SKILL.md is byte-identical to the PlUnit fixture."
  (let* ((root (make-temp-file "consortium-dsl-skills" t))
         (consortium-rlm-dsl-skill-root root))
    (consortium-rlm-defskill dsl-demo
      "A demo skill pinned byte-for-byte by the PlUnit catalog fixture."
      :body "When asked to demonstrate the DSL, reply that the elisp
defskill surface reached the runtime catalog.")
    (let ((exported (consortium-rlm-dsl-export-skill 'dsl-demo)))
      (should (equal (file-name-nondirectory (directory-file-name exported))
                     "dsl-demo"))
      (should (equal (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name "SKILL.md" exported))
                       (buffer-string))
                     (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name
                         "skills/dsl-demo/SKILL.md"
                         consortium-rlm-dsl-tests--fixture-dir))
                       (buffer-string)))))))

(ert-deftest consortium-rlm-dsl-skill-options ()
  "Exported skills surface as skill_roots wire options."
  (let* ((root (make-temp-file "consortium-dsl-skills" t))
         (consortium-rlm-dsl-skill-root root))
    (should-not (consortium-rlm-dsl-skill-root-options))
    (consortium-rlm-defskill dsl-demo
      "A demo skill pinned byte-for-byte by the PlUnit catalog fixture."
      :body "body")
    (consortium-rlm-dsl-export-skill 'dsl-demo)
    (should (equal (consortium-rlm-dsl-skill-root-options)
                   `((skill_roots . (,root)))))))

(ert-deftest consortium-rlm-dsl-defexpert-emits-consultable-prolog ()
  "Expert clauses are byte-identical to the consulted PlUnit fixture."
  (consortium-rlm-defexpert dsl-reviewer
    "Demo expert pinned by the PlUnit consult fixture."
    :role review
    :skills (grill impeccable)
    :constraints ("cite file:line evidence"))
  (should (equal (consortium-rlm-dsl-expert-prolog 'dsl-reviewer)
                 (with-temp-buffer
                   (insert-file-contents
                    (expand-file-name "demo-experts.pl"
                                      consortium-rlm-dsl-tests--fixture-dir))
                   (buffer-string)))))

(ert-deftest consortium-rlm-dsl-defexpert-registers ()
  (consortium-rlm-defexpert dsl-reviewer
    "Demo expert pinned by the PlUnit consult fixture."
    :role review
    :skills (grill impeccable)
    :constraints ("cite file:line evidence"))
  (let ((spec (cdr (assq 'dsl-reviewer consortium-rlm-dsl-experts))))
    (should spec)
    (should (eq (plist-get spec :role) 'review))))

(ert-deftest consortium-rlm-dsl-defworkflow-emits-wire-options ()
  "Workflows reuse the canonical config mapping with overrides."
  (consortium-rlm-defworkflow dwl-demo
    "Demo workflow."
    :models "demo-model"
    :budget ((max_total_tokens . 1000)
              (max_cost_usd . 0.1) (time_limit . 10.0))
    :constraints ("keep it small"))
  (let ((options (consortium-rlm-workflow-options 'dwl-demo)))
    (should (equal (cdr (assq 'worker options)) "rlm"))
    (should (equal (cdr (assq 'models options))
                   '((root_agent . "demo-model")
                     (analyze . "demo-model") (design . "demo-model")
                     (adversarial_review . "demo-model")
                     (resolve . "demo-model") (develop . "demo-model")
                     (verify . "demo-model"))))
    (should (equal (cdr (assq 'budget options))
                   '((max_total_tokens . 1000)
                     (max_cost_usd . 0.1) (time_limit . 10.0))))
    (should (equal (cdr (assq 'constraints options))
                   '("keep it small")))
    ;; Unspecified keys fall through to the config defaults.
    (should (equal (cdr (assq 'provider options)) "openrouter"))))

(ert-deftest consortium-rlm-dsl-defworkflow-unknown-signals ()
  (should-error (consortium-rlm-workflow-options 'no-such-workflow)))

(provide 'consortium-rlm-dsl-tests)
;;; consortium-rlm-dsl-tests.el ends here
