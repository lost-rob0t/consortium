:- module(workbench_expert,
          [ slice_id/1, slice_branch/1, upstream_rlm_sha/1,
            ui_frame_kind/1, ui_event_type/1, ui_command_known/1,
            ui_snapshot_field/1, ui_capability/1,
            server_fixture/1, fixture_server_script/1,
            consortium_ext_namespace/1, consortium_ext_event/1,
            unmerged_api_not_consumed/1,
            task/4, depends/2, evidence/3, file_exists/1, test_passes/1,
            status/2, ready/1, blocked/2, next_ready/1,
            progress/2, area_status/2, task_chain/2,
            task_evidence_ok/1, done_without_evidence/1,
            artifact_file/1, artifact_test/1,
            coverage_missing_file/1, coverage_missing_test/1,
            event_render_missing/1, command_binding_missing/1,
            ext_event_missing_adapter/1,
            verify_slice/0, verify_slice_report/1,
            gate_summary/3
          ]).

/** <module> Consortium Emacs RLM workbench expert system

Working expert system for the CONSORTIUM-003 Emacs RLM workbench slice.
It tracks the task graph, dependency closure, recorded API facts, and
verification gates.  Statuses and evidence are updated as the slice
proceeds; verification queries derive what is missing rather than
trusting prose.

Facts are grouped:

- slice identity and pinned upstream revision;
- canonical prolog_agent_ui_v1 API surface (from the pinned SHA);
- Consortium extension namespace registry;
- planned deliverable artifacts and their tests;
- task graph (task/4) with dependencies (depends/2);
- dynamic evidence/3, file_exists/1, test_passes/1 fed from the shell.

Rules derive readiness, progress, and verification.  A task may only be
marked done when evidence exists; verify_slice/0 fails if any gate is
open.
*/

%! slice_id(+Id) is det.
slice_id("emacs-rlm-workbench").

%! slice_branch(+Branch) is det.
slice_branch("emacs/3-rlm-workbench").

%! upstream_rlm_sha(+Sha) is det.
%  Canonical lost-rob0t/prolog-rlm origin/main commit used for this slice.
upstream_rlm_sha("a89175bf925df3afa358f8d05a370fe2a03e2117").

/* ------------------------------------------------------------------ */
/* Canonical prolog_agent_ui_v1 surface (recorded from upstream SHA)   */
/* ------------------------------------------------------------------ */

%! server_fixture(+Path) is det.
%  Polyglot golden NDJSON session shipped by prolog-rlm.
server_fixture("test/fixtures/prolog_agent_ui_v1_session.ndjson").

%! fixture_server_script(+Path) is det.
%  Deterministic child-process fixture server (swipl -q -s ...).
fixture_server_script("test/support/prolog-agent-ui-fixture.pl").

%! ui_frame_kind(+Kind) is det.
ui_frame_kind(K) :-
    member(K, ["negotiate", "snapshot", "event", "command", "result",
               "error"]).

%! ui_event_type(+Type) is det.
%  Known semantic event vocabulary at the pinned SHA.
ui_event_type(E) :-
    member(E, ["run_started",
               "message_started",
               "text_delta",
               "message_completed",
               "tool_started",
               "tool_output",
               "tool_finished",
               "approval_required",
               "approval_resolved",
               "question_required",
               "question_answered",
               "subagent_started",
               "subagent_finished",
               "verification",
               "usage",
               "trace",
               "effect_indeterminate",
               "run_finished"]).

%! ui_command_known(+Command) is det.
%  Commands the deterministic fixture server actually answers.
ui_command_known(C) :-
    member(C, ["approval.decide", "question.answer", "session.cancel"]).

%! ui_snapshot_field(+Field) is det.
%  Required canonical snapshot state fields.
ui_snapshot_field(F) :-
    member(F, [status, run, messages, tools, approvals, questions,
               subagents, verification, usage, traces,
               indeterminate_effects, extensions]).

%! ui_capability(+Cap) is det.
%  Server capabilities advertised at the pinned SHA.
ui_capability(C) :-
    member(C, ["streaming_text",
               "generic_tools",
               "approvals",
               "questions",
               "subagents",
               "verification",
               "usage",
               "traces",
               "indeterminate_effects",
               "optional_extensions",
               "native_file_buffers",
               "side_by_side_diff",
               "mouse",
               "clipboard",
               "multiple_windows"]).

%! consortium_ext_namespace(+Ns) is det.
consortium_ext_namespace("consortium.v1").

%! consortium_ext_event(+Type) is det.
%  Consortium domain extension events (versioned consortium.v1).
%  Only domain state; never duplicates generic RLM events.
consortium_ext_event(E) :-
    member(E, ["consortium.phase.started",
               "consortium.phase.finished",
               "consortium.artifact.created",
               "consortium.gate.pending",
               "consortium.gate.resolved",
               "consortium.repair.started",
               "consortium.rage.started",
               "consortium.rage.finished"]).

%! unmerged_api_not_consumed(+Ref) is det.
%  Upstream branches deliberately not consumed by this slice.
unmerged_api_not_consumed(
    "feat/spec-plan-flow-api: spec-seeded plan flow API (no ui_v1 delta)").

/* ------------------------------------------------------------------ */
/* Planned deliverables                                                */
/* ------------------------------------------------------------------ */

%! artifact_file(+Path) is det.
%  Every file the slice must deliver.
artifact_file("emacs/consortium-rlm.el").
artifact_file("emacs/consortium-rlm-client.el").
artifact_file("emacs/consortium-rlm-process.el").
artifact_file("emacs/consortium-rlm-events.el").
artifact_file("emacs/consortium-rlm-state.el").
artifact_file("emacs/consortium-rlm-chat.el").
artifact_file("emacs/consortium-rlm-diff.el").
artifact_file("emacs/consortium-rlm-tools.el").
artifact_file("emacs/consortium-rlm-tasks.el").
artifact_file("emacs/consortium-rlm-verification.el").
artifact_file("emacs/consortium-rlm-trace.el").
artifact_file("emacs/consortium-rlm-transient.el").
artifact_file("emacs/consortium-rlm-consortium.el").
artifact_file("test/consortium-rlm-tests.el").
artifact_file("test/consortium-rlm-conformance.el").
artifact_file("flake.nix").

%! artifact_test(+Path) is det.
%  Test entrypoints that must exist and pass.
artifact_test("test/consortium-rlm-tests.el").
artifact_test("test/consortium-rlm-conformance.el").

/* ------------------------------------------------------------------ */
/* Task graph                                                          */
/* ------------------------------------------------------------------ */

%! task(+Id, +Area, +Title, +Status) is det.
%  Status in {pending, in_progress, done, blocked}.
:- dynamic task/4.

task(t01_api_sync,   api,  "Sync upstream prolog-rlm, inspect ui_v1 + runtime surfaces", done).
task(t02_expert,     api,  "Bootstrap Prolog expert system for task/fact tracking", in_progress).
task(t03_transport,  core, "NDJSON pipe transport: framing, UTF-8, death, reconnect", pending).
task(t04_protocol,   core, "Codec + canonical reducer: seq, dup, gap, extensions", pending).
task(t05_state,      core, "Session state store, multi-session isolation", pending).
task(t06_chat,       ui,   "Session buffer mode, composer, streaming", pending).
task(t07_tools,      ui,   "Tool cards, unknown-safe details, file navigation", pending).
task(t08_diff,       ui,   "Approval/diff UI via diff-mode, authority decisions", pending).
task(t09_verify_ui,  ui,   "Verification summary + compilation-mode buffer", pending).
task(t10_tasks,      ui,   "Tasks/phases tabulated list, RAGE nesting", pending).
task(t11_sessions,   ui,   "Sessions list + runtime status projection", pending).
task(t12_trace,      ui,   "Trace buffer with point-local actions", pending).
task(t13_ext,        ext,  "consortium.v1 extension events + artifacts", pending).
task(t14_transient,  ext,  "Transient menu, public API, keymaps", pending).
task(t15_conform,    qa,   "Upstream fixture conformance harness", pending).
task(t16_flake,      build,"Nix flake: pinned prolog-rlm, devShell, checks", pending).
task(t17_gates,      qa,   "Full deterministic gates + final report", pending).

%! depends(+Id, +DependsOn) is det.
depends(t02_expert,    t01_api_sync).
depends(t03_transport, t01_api_sync).
depends(t04_protocol,  t03_transport).
depends(t05_state,     t04_protocol).
depends(t06_chat,      t05_state).
depends(t07_tools,     t06_chat).
depends(t08_diff,      t06_chat).
depends(t09_verify_ui, t06_chat).
depends(t10_tasks,     t05_state).
depends(t11_sessions,  t05_state).
depends(t12_trace,     t06_chat).
depends(t13_ext,       t05_state).
depends(t14_transient, t06_chat).
depends(t15_conform,   t04_protocol).
depends(t15_conform,   t03_transport).
depends(t16_flake,     t15_conform).
depends(t17_gates,     t16_flake).
depends(t17_gates,     t07_tools).
depends(t17_gates,     t08_diff).
depends(t17_gates,     t09_verify_ui).
depends(t17_gates,     t10_tasks).
depends(t17_gates,     t11_sessions).
depends(t17_gates,     t12_trace).
depends(t17_gates,     t13_ext).
depends(t17_gates,     t14_transient).

/* ------------------------------------------------------------------ */
/* Dynamic evidence (fed from the working environment)                 */
/* ------------------------------------------------------------------ */

%! evidence(+TaskId, +Kind, +Ref) is nondet.
%  Kind: test | file | inspection | manual.
:- dynamic evidence/3.

%! file_exists(+Path) is nondet.
%  Recorded by the shell scan before verification.
:- dynamic file_exists/1.

%! test_passes(+TestRef) is nondet.
%  Recorded after a local test run.
:- dynamic test_passes/1.

/* ------------------------------------------------------------------ */
/* Dependency and progress rules                                       */
/* ------------------------------------------------------------------ */

status(Id, Status) :-
    task(Id, _, _, Status).

%! ready(+Id) is nondet.
%  A pending task whose whole dependency closure is done.
ready(Id) :-
    task(Id, _, _, pending),
    forall(depends(Id, Dep), status(Dep, done)).

%! blocked(+Id, +BlockingDep) is nondet.
blocked(Id, Dep) :-
    task(Id, _, _, pending),
    depends(Id, Dep),
    \+ status(Dep, done).

%! next_ready(+Id) is nondet.
next_ready(Id) :-
    ready(Id).

%! progress(-Done, -Total) is det.
progress(Done, Total) :-
    aggregate_all(count, task(_, _, _, done), Done),
    aggregate_all(count, task(_, _, _, _), Total).

%! area_status(+Area, -Status) is det.
%  done | in_progress | pending for a whole area.
area_status(Area, done) :-
    forall(task(Id, Area, _, _), status(Id, done)).
area_status(Area, in_progress) :-
    task(_, Area, _, done),
    task(_, Area, _, pending).
area_status(_, pending).

%! task_chain(+From, +To) is nondet.
%  Transitive dependency closure (From must eventually see To done).
task_chain(From, To) :-
    depends(From, To).
task_chain(From, To) :-
    depends(From, Mid),
    task_chain(Mid, To).

%! dependency_cycle(-Id) is nondet.
%  Guard: the dependency graph must stay acyclic.
dependency_cycle(Id) :-
    task_chain(Id, Id).

/* ------------------------------------------------------------------ */
/* Verification gates                                                  */
/* ------------------------------------------------------------------ */

%! task_evidence_ok(+Id) is semidet.
task_evidence_ok(Id) :-
    status(Id, done),
    evidence(Id, _, _).

%! done_without_evidence(-Id) is nondet.
done_without_evidence(Id) :-
    status(Id, done),
    \+ evidence(Id, _, _).

%! coverage_missing_file(-Path) is nondet.
coverage_missing_file(Path) :-
    artifact_file(Path),
    \+ file_exists(Path).

%! coverage_missing_test(-Path) is nondet.
coverage_missing_test(Path) :-
    artifact_test(Path),
    \+ ( file_exists(Path),
         evidence(_, test, Path) ).

%! event_render_missing(-EventType) is nondet.
%  Every canonical event type must have rendered reducer+UI evidence.
event_render_missing(Type) :-
    ui_event_type(Type),
    \+ evidence(t06_chat, event_render, Type),
    \+ evidence(t07_tools, event_render, Type),
    \+ evidence(t08_diff, event_render, Type),
    \+ evidence(t09_verify_ui, event_render, Type),
    \+ evidence(t12_trace, event_render, Type),
    \+ evidence(t13_ext, event_render, Type),
    \+ evidence(t04_protocol, event_render, Type).

%! command_binding_missing(-Command) is nondet.
command_binding_missing(Command) :-
    ui_command_known(Command),
    \+ evidence(t14_transient, command_binding, Command).

%! ext_event_missing_adapter(-Type) is nondet.
ext_event_missing_adapter(Type) :-
    consortium_ext_event(Type),
    \+ evidence(t13_ext, ext_adapter, Type).

%! gate_summary(-Passing, -Open, -OpenGates) is det.
gate_summary(Passing, Open, OpenGates) :-
    findall(G, gate_open(G), OpenGates),
    length(OpenGates, Open),
    gate_count(Total),
    Passing is Total - Open.

gate_count(11).

%! gate_open(+Gate) is nondet.
gate_open(no_done_without_evidence) :-
    done_without_evidence(_).
gate_open(no_dependency_cycle) :-
    dependency_cycle(_).
gate_open(all_artifacts_present) :-
    coverage_missing_file(_).
gate_open(all_tests_recorded) :-
    coverage_missing_test(_).
gate_open(all_events_rendered) :-
    event_render_missing(_).
gate_open(all_commands_bound) :-
    command_binding_missing(_).
gate_open(all_ext_events_adapted) :-
    ext_event_missing_adapter(_).
gate_open(upstream_sha_recorded) :-
    \+ ( evidence(t01_api_sync, inspection, Ref),
         ref_prefixed("upstream-sha:", Ref) ).
gate_open(conformance_passing) :-
    \+ evidence(t15_conform, test, _).
gate_open(emacs_tests_passing) :-
    \+ evidence(t17_gates, test, "ert:consortium-rlm").
gate_open(flake_check_passing) :-
    \+ evidence(t17_gates, test, "nix flake check").

%! ref_prefixed(+Prefix, +Ref) is semidet.
%  True when evidence reference Ref (string or atom) starts with Prefix.
ref_prefixed(Prefix, Ref) :-
    atom_string(Atom, Ref),
    atom_concat(Prefix, _, Atom).

%! verify_slice is semidet.
%  Succeeds only when every gate is closed.
verify_slice :-
    \+ gate_open(_).

%! verify_slice_report(-Lines) is det.
%  Human-readable gate report; empty when fully verified.
verify_slice_report(Lines) :-
    findall(Line,
            (   gate_open(Gate),
                gate_detail(Gate, Line)
            ),
            Lines).

gate_detail(no_done_without_evidence, "a done task lacks evidence").
gate_detail(no_dependency_cycle, "dependency graph contains a cycle").
gate_detail(all_artifacts_present, "a planned artifact file is missing").
gate_detail(all_tests_recorded, "a planned test file lacks passing evidence").
gate_detail(all_events_rendered, "a canonical event type lacks render evidence").
gate_detail(all_commands_bound, "a known backend command lacks a binding").
gate_detail(all_ext_events_adapted, "a consortium.v1 event lacks adapter evidence").
gate_detail(upstream_sha_recorded, "upstream SHA inspection evidence missing").
gate_detail(conformance_passing, "fixture conformance has no passing evidence").
gate_detail(emacs_tests_passing, "ERT suite consortium-rlm has no passing evidence").
gate_detail(flake_check_passing, "nix flake check has no passing evidence").
