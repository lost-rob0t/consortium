;;; consortium-rlm-config.el --- canonical Emacs configuration -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; The single canonical Consortium Emacs configuration.  Every
;; defcustom here maps onto daemon run options through one function,
;; `consortium-rlm-config-run-options'; there is no second place that
;; defines provider, model, or budget truth.  Daemon lifecycle
;; settings live here as well, and the UI layer consumes them.
;;
;; Provider branches carry an endpoint and a credential ENVIRONMENT
;; VARIABLE NAME only; secrets are resolved by the daemon from its
;; environment (or injected from auth-source at connect time by the UI
;; layer) and never enter configuration or the wire protocol.
;;
;; The mapping emits only keys from the daemon's closed run-option
;; vocabulary (prolog/consortium_protocol.pl): worker, provider,
;; endpoint, credential_env, models, budget, phase_budget,
;; max_repairs, max_rage_cycles, repository, artifact_refs, fact_refs,
;; evidence, constraints, acceptance_criteria, skill_roots.

;;; Code:

(require 'cl-lib)

(unless (get 'consortium-rlm-error 'error-conditions)
  (define-error 'consortium-rlm-error "Consortium RLM error"))

(defgroup consortium-rlm-config nil
  "Canonical Consortium configuration mapped to daemon run options."
  :group 'tools)

(defconst consortium-rlm-config-phase-roles
  '(root_agent analyze design adversarial_review resolve develop verify)
  "ADARD phase roles requiring a model route.")

(defconst consortium-rlm-config-providers-vocabulary
  '(openrouter codex zai)
  "Provider branches understood by the daemon protocol.")

(defconst consortium-rlm-config-workers
  '(rlm fake blocking)
  "Worker kinds understood by the daemon protocol.")

;;; Daemon lifecycle -------------------------------------------------------

(defcustom consortium-rlm-config-daemon-program "consortium"
  "Consortium daemon executable."
  :type 'string)

(defcustom consortium-rlm-config-daemon-arguments '("daemon")
  "Arguments used when starting the Consortium daemon."
  :type '(repeat string))

;;; Provider branches ------------------------------------------------------

(defcustom consortium-rlm-config-providers
  '((openrouter
     . ((endpoint . nil)
        (credential_env . "OPENROUTER_API_KEY")
        (auth_host . "openrouter.ai")))
    (codex
     . ((endpoint . "https://api.openai.com/v1/chat/completions")
        (credential_env . "OPENAI_API_KEY")
        (auth_host . "api.openai.com")))
    (zai
     . ((endpoint . "https://api.z.ai/api/coding/paas/v4/chat/completions")
        (credential_env . "ZAI_API_KEY")
        (auth_host . "api.z.ai"))))
  "Provider branches: wire endpoint, credential ENV NAME, and the
auth-source host the UI consults when the credential variable is not
already set in the daemon environment.  The zai default targets the
GLM Coding Plan endpoint: plan quota only flows through it."
  :type '(alist :key-type symbol))

(defcustom consortium-rlm-config-provider 'openrouter
  "Active provider branch used for rlm workers."
  :type '(choice (const openrouter) (const codex) (const zai)))

(defcustom consortium-rlm-config-worker 'rlm
  "Worker kind.  `rlm' uses providers and models; `fake' and
`blocking' run the deterministic test workers with no provider
surface (a local kill switch for AI-free runs)."
  :type '(choice (const rlm) (const fake) (const blocking)))

(defcustom consortium-rlm-config-models "z-ai/glm-4.6"
  "Model routes as a single string (expanded to every phase role) or
an alist covering all of `conortium-rlm-config-phase-roles'."
  :type '(choice string (alist :key-type symbol :value-type string)))

;;; Budgets ----------------------------------------------------------------

(defcustom consortium-rlm-config-budget
  '((max_total_tokens . 24000) (max_cost_usd . 2.0) (time_limit . 300.0))
  "Run budget.  Mandatory for provider runs; never disable it."
  :type '(alist :key-type symbol :value-type number))

(defcustom consortium-rlm-config-phase-budget
  '((max_total_tokens . 4000) (max_cost_usd . 0.5) (time_limit . 60.0))
  "Phase budget; must not exceed the run budget (the daemon narrows)."
  :type '(alist :key-type symbol :value-type number))

(defcustom consortium-rlm-config-max-repairs 1
  "Bounded repair retries per run."
  :type 'natnum)

(defcustom consortium-rlm-config-max-rage-cycles 3
  "Bounded RAGE escalation cycles per run."
  :type 'natnum)

;;; ADARD context ----------------------------------------------------------

(defcustom consortium-rlm-config-repository nil
  "Repository path shipped as run context, or nil."
  :type '(choice (const nil) string))

(defcustom consortium-rlm-config-artifact-refs nil
  "Initial artifact references for the analyze phase."
  :type '(repeat string))

(defcustom consortium-rlm-config-fact-refs nil
  "Fact references riding every phase packet."
  :type '(repeat string))

(defcustom consortium-rlm-config-evidence nil
  "Evidence strings bound into run packets."
  :type '(repeat string))

(defcustom consortium-rlm-config-constraints nil
  "Constraint strings bound into run packets."
  :type '(repeat string))

(defcustom consortium-rlm-config-acceptance-criteria nil
  "Acceptance criteria bound into run packets."
  :type '(repeat string))

;;; Skill catalogs ---------------------------------------------------------

(defcustom consortium-rlm-config-skill-roots nil
  "Operator-configured skill catalog roots (directories of SKILL.md
packages) loaded server-side once per run."
  :type '(repeat directory))

;;; Validation -------------------------------------------------------------

(defun consortium-rlm-config--error (format &rest args)
  "Signal a configuration error with FORMat ARGS."
  (signal 'consortium-rlm-error
          (list :reason "invalid-config"
                :detail (apply #'format format args))))

(defun consortium-rlm-config-provider-spec (provider)
  "Return the branch plist for PROVIDER, failing closed when unknown."
  (or (cdr (assq provider consortium-rlm-config-providers))
      (consortium-rlm-config--error "unknown provider: %s" provider)))

(defun consortium-rlm-config-expand-models (models)
  "Expand MODELS to a complete role alist.

A string covers every phase role; an alist must itself cover all of
`consortium-rlm-config-phase-roles'."
  (cond
   ((stringp models)
    (mapcar (lambda (role) (cons role models))
            consortium-rlm-config-phase-roles))
   ((and (listp models)
         (cl-every #'consp models)
         (cl-every (lambda (pair)
                     (and (memq (car pair)
                                consortium-rlm-config-phase-roles)
                          (stringp (cdr pair))))
                   models))
    (dolist (role consortium-rlm-config-phase-roles)
      (unless (assq role models)
        (consortium-rlm-config--error
         "models alist missing phase role: %s" role)))
    (mapcar (lambda (role) (assq role models))
            consortium-rlm-config-phase-roles))
   (t (consortium-rlm-config--error "invalid models: %S" models))))

(defun consortium-rlm-config-validate-budget (budget)
  "Check BUDGET is an alist of non-negative numbers."
  (unless (and (listp budget)
               (cl-every (lambda (pair)
                           (and (consp pair)
                                (numberp (cdr pair))
                                (>= (cdr pair) 0)))
                         budget))
    (consortium-rlm-config--error "invalid budget: %S" budget))
  budget)

(defun consortium-rlm-config-validate (&rest overrides)
  "Validate configuration with OVERRIDES applied; return t or signal."
  (let* ((override (lambda (key default)
                     (if (plist-member overrides key)
                         (plist-get overrides key)
                       default)))
         (worker (funcall override :worker consortium-rlm-config-worker))
         (provider (funcall override :provider
                            consortium-rlm-config-provider))
         (budget (funcall override :budget consortium-rlm-config-budget))
         (models (funcall override :models consortium-rlm-config-models))
         (max-repairs (funcall override :max-repairs
                               consortium-rlm-config-max-repairs))
         (max-rage (funcall override :max-rage-cycles
                            consortium-rlm-config-max-rage-cycles)))
    (unless (memq worker consortium-rlm-config-workers)
      (consortium-rlm-config--error "unknown worker: %s" worker))
    (when (eq worker 'rlm)
      (consortium-rlm-config-provider-spec provider)
      (consortium-rlm-config-expand-models models))
    (consortium-rlm-config-validate-budget budget)
    (unless (and (natnump max-repairs) (natnump max-rage))
      (consortium-rlm-config--error "repair/rage bounds must be natural"))
    t))

;;; The canonical mapping --------------------------------------------------

(defun consortium-rlm-config-run-options (&rest overrides)
  "Return daemon run options for the configuration with OVERRIDES.

OVERRIDES is a plist using the same keys as the defcustoms
\(:provider :worker :models :budget :phase-budget :max-repairs
:max-rage-cycles :repository :artifact-refs :fact-refs :evidence
:constraints :acceptance-criteria :skill-roots\).  Nil-valued context
options are omitted from the wire."
  (apply #'consortium-rlm-config-validate overrides)
  (let ((get (lambda (key default)
               (if (plist-member overrides key)
                   (plist-get overrides key)
                 default)))
        options)
    (let ((worker (funcall get :worker consortium-rlm-config-worker)))
      (if (eq worker 'rlm)
          (let* ((provider (funcall get :provider
                                    consortium-rlm-config-provider))
                 (spec (consortium-rlm-config-provider-spec provider))
                 (endpoint (cdr (assq 'endpoint spec)))
                 (credential-env (cdr (assq 'credential_env spec))))
            (push (cons 'worker "rlm") options)
            (push (cons 'provider (symbol-name provider)) options)
            (when (memq provider '(codex zai))
              (when endpoint
                (push (cons 'endpoint endpoint) options))
              (when credential-env
                (push (cons 'credential_env credential-env) options)))
            (push (cons 'models
                        (consortium-rlm-config-expand-models
                         (funcall get :models
                                  consortium-rlm-config-models)))
                  options))
        ;; fake/blocking workers are the AI-free kill switch: no
        ;; provider, budget, or context surface rides the wire.
        (push (cons 'worker (symbol-name worker)) options)))
    (when (eq (funcall get :worker consortium-rlm-config-worker) 'rlm)
      (dolist (pair `((budget :budget ,consortium-rlm-config-budget)
                      (phase_budget :phase-budget
                                    ,consortium-rlm-config-phase-budget)
                      (max_repairs :max-repairs
                                   ,consortium-rlm-config-max-repairs)
                      (max_rage_cycles :max-rage-cycles
                                       ,consortium-rlm-config-max-rage-cycles)
                      (repository :repository
                                  ,consortium-rlm-config-repository)
                      (artifact_refs :artifact-refs
                                     ,consortium-rlm-config-artifact-refs)
                      (fact_refs :fact-refs
                                 ,consortium-rlm-config-fact-refs)
                      (evidence :evidence ,consortium-rlm-config-evidence)
                      (constraints :constraints
                                   ,consortium-rlm-config-constraints)
                      (acceptance_criteria :acceptance-criteria
                                           ,consortium-rlm-config-acceptance-criteria)
                      (skill_roots :skill-roots
                                   ,consortium-rlm-config-skill-roots)))
        (let ((value (funcall get (nth 1 pair) (nth 2 pair))))
          (when value (push (cons (car pair) value) options)))))
    (nreverse options)))

(provide 'consortium-rlm-config)
;;; consortium-rlm-config.el ends here
