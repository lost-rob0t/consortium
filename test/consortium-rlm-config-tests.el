;;; consortium-rlm-config-tests.el --- ERT for the canonical config -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Tests for `consortium-rlm-config': the single canonical Emacs
;; configuration mapping to daemon wire options.

;;; Code:

(require 'ert)
(require 'consortium-rlm-config)

(ert-deftest consortium-rlm-config-defaults ()
  "Default configuration maps to a complete rlm wire option set."
  (let ((options (consortium-rlm-config-run-options)))
    (should (equal (cdr (assq 'worker options)) "rlm"))
    (should (equal (cdr (assq 'provider options)) "openrouter"))
    (should (equal (cdr (assq 'models options))
                   '((root_agent . "z-ai/glm-4.6")
                     (analyze . "z-ai/glm-4.6")
                     (design . "z-ai/glm-4.6")
                     (adversarial_review . "z-ai/glm-4.6")
                     (resolve . "z-ai/glm-4.6")
                     (develop . "z-ai/glm-4.6")
                     (verify . "z-ai/glm-4.6"))))
    (should (assq 'budget options))
    (should (assq 'phase_budget options))
    ;; OpenRouter needs no endpoint or credential_env on the wire.
    (should-not (assq 'endpoint options))
    (should-not (assq 'credential_env options))
    ;; Nil optionals are omitted, not sent empty.
    (should-not (assq 'repository options))
    (should-not (assq 'evidence options))
    (should-not (assq 'skill_roots options))))

(ert-deftest consortium-rlm-config-models-string-expands-all-roles ()
  "A single model string expands to every ADARD phase role."
  (should (equal (consortium-rlm-config-expand-models "m")
                 '((root_agent . "m") (analyze . "m") (design . "m")
                   (adversarial_review . "m") (resolve . "m")
                   (develop . "m") (verify . "m")))))

(ert-deftest consortium-rlm-config-models-alist-validated ()
  "An explicit models alist must cover all seven roles."
  (let ((full '((root_agent . "a") (analyze . "a") (design . "a")
                (adversarial_review . "a") (resolve . "a")
                (develop . "a") (verify . "a"))))
    (should (equal (consortium-rlm-config-expand-models full) full)))
  (should-error (consortium-rlm-config-expand-models
                 '((root_agent . "a")))))

(ert-deftest consortium-rlm-config-provider-branches ()
  "codex and zai branches carry endpoint and credential_env."
  (dolist (provider '(codex zai))
    (let* ((options (consortium-rlm-config-run-options
                     :provider provider))
           (spec (cdr (assq provider consortium-rlm-config-providers))))
      (should (equal (cdr (assq 'provider options))
                     (symbol-name provider)))
      (should (equal (cdr (assq 'endpoint options))
                     (cdr (assq 'endpoint spec))))
      (should (equal (cdr (assq 'credential_env options))
                     (cdr (assq 'credential_env spec)))))))

(ert-deftest consortium-rlm-config-zai-defaults-coding-plan ()
  "The default zai endpoint targets the coding-plan endpoint."
  (let ((spec (cdr (assq 'zai consortium-rlm-config-providers))))
    (should (equal (cdr (assq 'endpoint spec))
                   "https://api.z.ai/api/coding/paas/v4/chat/completions"))
    (should (equal (cdr (assq 'credential_env spec)) "ZAI_API_KEY"))))

(ert-deftest consortium-rlm-config-unknown-provider-signals ()
  "An unknown provider fails closed."
  (should-error (consortium-rlm-config-run-options :provider 'bogus)))

(ert-deftest consortium-rlm-config-fake-workers-bypass-providers ()
  "fake and blocking workers carry no provider surface."
  (dolist (worker '(fake blocking))
    (let ((options (consortium-rlm-config-run-options :worker worker)))
      (should (equal options `((worker . ,(symbol-name worker))))))))

(ert-deftest consortium-rlm-config-overrides ()
  "Explicit overrides replace configuration values."
  (let ((options (consortium-rlm-config-run-options
                  :models "glm"
                  :budget '((max_total_tokens . 8)
                            (max_cost_usd . 0.1) (time_limit . 5.0))
                  :constraints '("no network"))))
    (should (equal (cdr (assq 'root_agent (cdr (assq 'models options))))
                   "glm"))
    (should (equal (cdr (assq 'constraints options)) '("no network")))
    (should (equal (cdr (assq 'budget options))
                   '((max_total_tokens . 8)
                     (max_cost_usd . 0.1) (time_limit . 5.0))))))

(ert-deftest consortium-rlm-config-context-options ()
  "ADARD context options ride the wire when configured."
  (let ((options (consortium-rlm-config-run-options
                  :repository "/repo"
                  :evidence '("log")
                  :acceptance-criteria '("gate")
                  :artifact-refs '("a")
                  :fact-refs '("f")
                  :skill-roots '("/skills"))))
    (should (equal (cdr (assq 'repository options)) "/repo"))
    (should (equal (cdr (assq 'evidence options)) '("log")))
    (should (equal (cdr (assq 'acceptance_criteria options)) '("gate")))
    (should (equal (cdr (assq 'artifact_refs options)) '("a")))
    (should (equal (cdr (assq 'fact_refs options)) '("f")))
    (should (equal (cdr (assq 'skill_roots options)) '("/skills")))))

(ert-deftest consortium-rlm-config-validate-accepts-defaults ()
  (should (eq (consortium-rlm-config-validate) t)))

(ert-deftest consortium-rlm-config-validate-rejects-bad-budget ()
  (should-error (consortium-rlm-config-validate
                 :budget '((max_total_tokens . -1))))
  (should-error (consortium-rlm-config-validate :max-repairs -1)))

(provide 'consortium-rlm-config-tests)
;;; consortium-rlm-config-tests.el ends here
