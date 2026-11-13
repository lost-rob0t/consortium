% Emacs surface knowledge: verified, reusable project facts.

architecture(region_review_surface,
  'emacs/consortium-rlm-review.el: region -> transient offering a manual
   rubric path (static local checklist data from ponytail-review/grill/
   impeccable; zero AI; works with the daemon fully off) and an AI path
   (budgeted daemon run through consortium-rlm-ui-connect with recorded
   run-id lineage; findings render anchored in their own org buffer).
   The AI path wraps the session event hook once and restores the prior
   hook when the reviewed run finishes; forwarding to the saved hook
   keeps approval/question prompts working during review runs.  Source
   buffers are never mutated; nothing auto-posts; dispositions record
   locally through consortium-rlm-review-record as org files.').

discovery(unwind_protect_byte_compile_warning,
  'A byte-compile warning "`unwind-protect\' without unwind forms" means
   the cleanup forms were parsed as siblings of the unwind-protect, not
   forms of it: one closing paren too many on the body form consumed the
   unwind-protect itself.  check-parens and total-balance scans still pass
   because the file balances overall.  To see the form the compiler really
   has, advise byte-compile-warn-x around byte-compile-file and print the
   POS argument; then fix the specific closing-paren count on the body
   form''s last line.  Seen while writing test/consortium-rlm-review-tests.el.').

architecture(canonical_config_mapping,
  'emacs/consortium-rlm-config.el is the ONE canonical Emacs
   configuration: every defcustom maps onto daemon run options through
   consortium-rlm-config-run-options (closed protocol vocabulary only).
   Daemon lifecycle defcustoms live here (consortium-rlm-ui-program
   names are obsolete aliases).  fake/blocking workers emit worker-only
   options - the AI-free kill switch.  Provider branches carry endpoint
   + credential_env (wire) + auth_host (auth-source injection at connect
   time only when the env var is unset); secrets never enter config or
   the wire.  Landed in PR #32 / forgejo#7.').

architecture(elisp_prolog_dsl,
  'emacs/consortium-rlm-dsl.el: defskill materializes SKILL.md packages
   under consortium-rlm-dsl-skill-root and emits skill_roots wire terms;
   defexpert emits consortium_expert/2 knowledge clauses (hyphenated
   names auto-quote as Prolog atoms); defworkflow composes config
   defaults with per-workflow overrides into wire options.  Macro
   attribute values are DATA, never evaluated - callers pass unquoted
   plists; a quoted value arrives as a literal (quote ...) form and
   fails validation downstream.  Round-trip discipline: ERT pins
   encoder output byte-identical to test/fixtures/dsl/, and the PlUnit
   suite consults the same expert fixture and loads the same skill root
   through rlm_skill:skill_catalog_load/3 - encoder output is
   machine-proven valid runtime input.  Landed in PR #32 / forgejo#7.').

architecture(async_elisp_tools,
  'emacs/consortium-rlm-tools.el: workflow-mode tools proxy ONLY the
   admitted daemon method vocabulary (pinned in
   consortium-rlm-tools-admitted-methods = the protocol dispatch
   surface); anything else fails closed at definition time AND call
   time, and workflow calls require a live session.  Free-mode tools
   are plain local elisp on a timer; they never see a session and carry
   no lineage.  Both paths deliver results via callback without
   blocking the editor.  Landed in PR #32 / forgejo#7.').

discovery(flake_tracked_files_and_stale_observations,
  'Two verification gotchas during forgejo#7: (1) nix flake check only
   sees git-TRACKED files - brand-new test files must be committed
   before flake check can load them, else the checks fail with
   "Cannot open load file" pointing into /nix/store.  (2) prolog-verify
   requirements go stale the moment HEAD moves: re-observe every
   requirement back-to-back at the SAME head and run check immediately
   (known lesson, bit again); commit the evidence as a follow-up
   verification commit, matching the PR31 session precedent.').
