% Consortium run journal @ 6dfb05e
run(head, '6dfb05e').
task(consortium_ide_package, 'ELLM/core feature package: agentic IDE for Emacs; repin prolog-rlm main eba3f90').
phase(consortium_ide_package, analyze, complete).
artifact(research, 'roam/research/CONSORTIUM-RESEARCH-003-ellm-agentic-ide.org').
todo(gate_research_approval, 'ADADR human gate: user must approve CONSORTIUM-RESEARCH-003 before design', active).
todo(design_ellm_slice, 'Design doc after research approval: rebase+client consolidation+ELLM compiler+protocol', pending).
blocker(research_approval, 'Waiting on user approval of CONSORTIUM-RESEARCH-003').
fact(upstream_main, prolog_rlm_main('eba3f90a1d4c0b9342e9e37049f92b178c115c1c')).
fact(upstream_delta, pin_to_main('45 files, +5880/-34, CL adapter, symbolic tools, semantic knowledge, zara')).
fact(emacs_layer, ert_state('11/35 pass, 24 red; reducer/validate outcome mismatch WIP')).

% ===== Task: consortium-emacs-ide (2026-09-20 operator pivot) =====
% Operator intent: full StarIntel IDE in Emacs (starintel-emacs) with gptel
% agentic AI, LEM clone repo into starintel monorepo, consortium moved into
% starintel/ workspace. "Just make auto research on this topic first."
task(consortium_emacs_ide_research, 'RESEARCH-004: starintel-emacs gptel IDE, LEM vendor-clone track, monorepo relocation').
supersedes_gate_scope(consortium_ide_package, 'RESEARCH-003 gate shared with RESEARCH-004').
artifact(research, 'roam/research/CONSORTIUM-RESEARCH-004-starintel-emacs-ide-gptel.org').
todo(gate_research_003_004, 'ADADR human gate: approve RESEARCH-003 + RESEARCH-004 together', active).
todo(relocate_consortium, 'mv consortium -> /home/unseen/starintel/consortium; origin -> git.starintel.actor (org unknown), github mirror', pending, [depends(gate_research_003_004)]).
todo(vendor_lem, 'clone lem-project/lem into starintel/lem upstream-tracking, no local commits (option A)', pending, [depends(gate_research_003_004)]).
todo(triage_ert, 'root-cause 24 red ERTs in test/consortium-rlm-tests.el', pending).
todo(starintel_emacs_repo, 'new repo starintel/starintel-emacs: gptel phase presets + daemon-proxy workflow-mode tools', pending, [depends(triage_ert)]).
blocker(research_approval, 'Waiting on user approval of RESEARCH-003 + RESEARCH-004').
observation('research-004-write', command(['prolog-verify','observe','--','test','-f','roam/research/CONSORTIUM-RESEARCH-004-starintel-emacs-ide-gptel.org']), exit(0), verify_checked('workspace_verification:complete'), '6dfb05e', none).
decision(lem_track, option_a_vendor_clone, 'no local commits inside lem/; starintel code as out-of-tree extension; fork (B) rejected on upstream-velocity grounds').
decision(gptel_mode_split, two_explicit_modes, 'workflow mode = gptel tools proxy daemon methods only; free mode = local tools, no run authority; mode is a preset attribute, never inferred').

% ===== consortium-emacs-ide: slice 2 COMPLETE (ERT triage + fixes) =====
% Relocation done pre-slice: repo now at /home/unseen/starintel/consortium.
% Forge git.starintel.actor outage (ssh timeout, API 502) -> origin stays
% github:lost-rob0t/consortium; forge repo creation pending (blocked).
lem_vendor_clone(lem-project/lem, f5ba7d83, '/home/unseen/starintel/lem', option_a_vendor_clone, clean).
ert_state(before, '11/35 pass, 24 red').
ert_state(after, '35/35 pass (test/consortium-rlm-tests.el) + consortium_emacs_tests green (1 live-daemon skip)').
todo(gate_research_003_004, 'ADADR human gate: approve RESEARCH-003 + RESEARCH-004 together', done).
todo(relocate_consortium, 'moved to starintel/ monorepo', done, [note('origin github pending forge recovery')]).
todo(vendor_lem, 'starintel/lem upstream-tracking clone @ f5ba7d83, no local commits', done).
todo(triage_ert, 'root-caused and fixed; 35/35 green', done).
todo(starintel_emacs_repo, 'new repo starintel/starintel-emacs: gptel phase presets + daemon-proxy workflow-mode tools', active).

% Root causes (all test-side except two client defects):
root_cause(apply_snapshot_dead_ok_branch, 'pcase ((pred listp)) clause shadowed (:ok ...) -> (error "impossible") on every snapshot; client bug, removed clause, fail-closed fallback added').
root_cause(shared_quoted_constant, 'delq test mutated the quoted snapshot literal shared by all tests -> invalid_snapshot_state cascade after alphabetical test #21; fixed with copy-tree helper (backquote shares non-comma sublists - copy-alist insufficient, shares pair cdrs)').
root_cause(erosion_nreverse, 'framer test helper collect used destructive nreverse and is called twice; fixed with non-destructive reverse').
root_cause(void_delta_text, 'client text_delta reducer concatenated void delta-text; fixed to (alist-get delta payload) per upstream update_message_delta/4 (plain concat) and lambda returns whole item via merge-item (upstream put_dict semantics)').
root_cause(vector_vs_list, 'snapshot view held wire arrays as vectors; transport decodes :array-type list; --snapshot-view now normalizes collections via --as-list').
upstream_authority('prolog_agent_ui_v1.pl @ pinned a89175b via nix store prolog-rlm-0.1.0: state_to_view copies fields as-is (no empty->nil), ui_error details are objects (alist keys), append_bounded appends end trims front (oldest dropped), update_message_delta plain concat, unknown id -> replay_missing_entity').
test_fixes('sequence-gap details alist-get; reconnect empty-list assertion; ten-thousand transposed expectations (at-seq 10001, text 10000); verification-bounded oldest-dropped (car=5, last=260); malformed-line literal "{brokenjunk"; session-mismatch verified correct').
layer_note('emacs/consortium.el is the daemon-API layer (connect/start/status/cancel), distinct from rlm-client codec/reducer; both test suites green; merge-vs-layer decision deferred to design gate').

% ===== starintel-emacs bootstrap COMPLETE =====
todo(starintel_emacs_repo, 'bootstrapped at /home/unseen/starintel/starintel-emacs', done).
artifact(package, 'starintel-emacs: phase model + mode invariant, 5 daemon-proxy tools, 6 workflow presets + free preset').
ert_state(starintel_emacs, '12/12 pass; nix flake check green (ert gate in sandbox)').
pending_commit('consortium: emacs fixes + research-004 untracked/modified; slice branch + PR per AGENTS.md').
pending_commit('starintel-emacs: initial tree staged, no commit yet (awaiting operator)').
pending(forge_repos, 'create consortium + starintel-emacs on git.starintel.actor via tea when forge recovers; origin per global policy').
pending(doom_wiring, 'wire starintel-emacs into user doom config: load-path, install-presets/install-tools, consortium-connect').
