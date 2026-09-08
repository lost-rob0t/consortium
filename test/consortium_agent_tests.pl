:- begin_tests(consortium_agent).

:- use_module(library(lists)).
:- use_module('../prolog/consortium_agent').
:- use_module('../prolog/consortium_models').
:- use_module(library(rlm_async)).

setup_harness(Harness, Queue) :-
    message_queue_create(Queue),
    harness_create([store(memory), event_queue(Queue)], Harness).

cleanup_harness(Harness, Queue) :-
    harness_destroy(Harness),
    message_queue_destroy(Queue).

success_options([worker(fake(success))]).

wait_event(Queue, Type, Event) :-
    thread_get_message(Queue, Candidate, [timeout(5.0)]),
    (   Candidate.type == Type
    ->  Event = Candidate
    ;   wait_event(Queue, Type, Event)
    ).

wait_terminal(Queue, Event) :-
    thread_get_message(Queue, Candidate, [timeout(5.0)]),
    (   memberchk(Candidate.type,
                  ['run.completed', 'run.failed', 'run.cancelled'])
    ->  Event = Candidate
    ;   wait_terminal(Queue, Event)
    ).

event_phases(Events, Type, Phases) :-
    findall(Phase,
            ( member(Event, Events),
              Event.type == Type,
              Phase = Event.phase
            ),
            Phases).

has_event_type(Events, Type) :-
    member(Event, Events),
    get_dict(type, Event, Type).

capability_planner(_, ok(Output)) :-
    Plan = plan([final(literal("{\"phase\":\"analyze\",\"status\":\"completed\",\"content\":\"ok\"}"))]),
    Output = planner_output{
                 plan:Plan,
                 usage:_{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

packet_artifacts(Harness, RunId, Packets) :-
    events(Harness, RunId, 0, Events),
    findall(Packet,
            ( member(Event, Events),
              Event.type == 'artifact.created',
              Event.payload.kind == context_packet,
              artifact(Harness,
                       RunId,
                       Event.payload.artifact_id,
                       Artifact),
              Packet = Artifact.value
            ),
            Packets).

forbidden_packet_key(messages).
forbidden_packet_key(transcript).
forbidden_packet_key(conversation).
forbidden_packet_key(hidden_context).

contains_forbidden_key(Dict) :-
    is_dict(Dict),
    dict_pairs(Dict, _, Pairs),
    member(Key-Value, Pairs),
    (   forbidden_packet_key(Key)
    ;   contains_forbidden_key(Value)
    ).
contains_forbidden_key(List) :-
    is_list(List),
    member(Value, List),
    contains_forbidden_key(Value).

test(start_returns_stable_run_id_before_worker_completion,
     [ setup(setup_harness(Harness, Events)),
       cleanup(cleanup_harness(Harness, Events))
     ]) :-
    message_queue_create(Started),
    message_queue_create(Release),
    setup_call_cleanup(
        true,
        ( start(Harness,
                "blocked task",
                [worker(barrier(Started, Release, success))],
                RunId),
          assertion(atom(RunId)),
          thread_get_message(Started,
                             worker_entered(analyze, _Packet),
                             [timeout(2.0)]),
          status(Harness, RunId, Active),
          assertion(Active.run_id == RunId),
          assertion(Active.state == running),
          cancel(Harness, RunId, ok(cancelled))
        ),
        ( message_queue_destroy(Started),
          message_queue_destroy(Release)
        )).

test(adard_order_and_replayable_events,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    success_options(Options),
    start(Harness, "ordered task", Options, RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.completed'),
    events(Harness, RunId, 0, Events),
    event_phases(Events, 'phase.started', Started),
    assertion(Started == [analyze, design, adversarial_review,
                          resolve, develop, verify]),
    findall(Sequence,
            ( member(Event, Events), Sequence = Event.sequence ),
            Sequences),
    last(Sequences, Last),
    numlist(1, Last, Sequences),
    Since is Last-2,
    events(Harness, RunId, Since, Replay),
    length(Replay, 2),
    forall(member(Event, Replay), assertion(Event.sequence > Since)).

test(each_phase_has_fresh_session_and_no_hidden_transcript,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    success_options(Options),
    start(Harness, "fresh context task", Options, RunId),
    wait_terminal(Queue, _),
    packet_artifacts(Harness, RunId, Packets),
    length(Packets, 6),
    findall(Session,
            ( member(Packet, Packets), Session = Packet.session_id ),
            Sessions),
    sort(Sessions, UniqueSessions),
    length(UniqueSessions, 6),
    forall(member(Packet, Packets),
           assertion(\+ contains_forbidden_key(Packet))).

test(explicit_artifact_and_fact_references_propagate,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    InputRef = artifact_ref{namespace:input, key:brief, version:1},
    start(Harness,
          "explicit handoff",
          [ worker(fake(success)),
            artifact_refs([InputRef]),
            fact_refs([fact(project_language, prolog)])
          ],
          RunId),
    wait_terminal(Queue, _),
    packet_artifacts(Harness, RunId, [Analyze|Later]),
    member(PropagatedRef, Analyze.artifact_refs),
    assertion(PropagatedRef.namespace == InputRef.namespace),
    assertion(PropagatedRef.key == InputRef.key),
    assertion(PropagatedRef.version =:= InputRef.version),
    assertion(memberchk(fact(project_language, prolog), Analyze.fact_refs)),
    forall(member(Packet, Later),
           ( assertion(Packet.artifact_refs \== []),
             assertion(Packet.artifact_inputs \== []) )).

test(cancellation_propagates_and_stale_completion_is_fenced,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    message_queue_create(Started),
    message_queue_create(Release),
    setup_call_cleanup(
        true,
        ( start(Harness,
                "cancel task",
                [worker(barrier(Started, Release, success))],
                RunId),
          thread_get_message(Started,
                             worker_entered(analyze, Packet),
                             [timeout(2.0)]),
          cancel(Harness, RunId, Cancelled),
          assertion(Cancelled == ok(cancelled)),
          Harness = harness(HarnessId),
          assertion(\+ consortium_agent:owned_future(HarnessId, _)),
          status(Harness, RunId, Status0),
          assertion(Status0.state == cancelled),
          consortium_agent:phase_completed(
              Harness,
              RunId,
              Packet.attempt_id,
              Packet.generation,
              ok(fake_late_result)),
          status(Harness, RunId, Status1),
          assertion(Status1.state == cancelled),
          events(Harness, RunId, 0, RunEvents),
          assertion(\+ has_event_type(RunEvents, 'run.completed')),
          assertion(has_event_type(RunEvents, 'worker.stale'))
        ),
        ( message_queue_destroy(Started),
          message_queue_destroy(Release)
        )).

test(local_failure_repairs_without_analysis_restart,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    start(Harness,
          "repair locally",
          [worker(fake(local_failure_once))],
          RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.completed'),
    events(Harness, RunId, 0, RunEvents),
    event_phases(RunEvents, 'phase.started', Phases),
    assertion(Phases == [analyze, design, adversarial_review, resolve,
                         develop, verify, develop, verify]),
    include(==(analyze), Phases, AnalyzePhases),
    assertion(AnalyzePhases == [analyze]),
    assertion(has_event_type(RunEvents, 'repair.started')),
    packet_artifacts(Harness, RunId, Packets),
    once(( member(RepairPacket, Packets),
           RepairPacket.phase == develop,
           RepairPacket.repair_attempt =:= 1,
           member(FailureInput, RepairPacket.artifact_inputs),
           FailureInput.kind == verification_failure )).

test(architectural_failure_requests_bounded_rage_escalation,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    start(Harness,
          "redesign once",
          [ worker(fake(architectural_failure_once)),
            max_rage_cycles(1)
          ],
          RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.completed'),
    events(Harness, RunId, 0, RunEvents),
    event_phases(RunEvents, 'phase.started', Phases),
    assertion(Phases == [analyze, design, adversarial_review, resolve,
                         develop, verify, design, adversarial_review,
                         resolve, develop, verify]),
    assertion(has_event_type(RunEvents, 'rage.started')),
    status(Harness, RunId, Status),
    assertion(Status.rage_cycles =:= 1),
    packet_artifacts(Harness, RunId, Packets),
    once(( member(RedesignPacket, Packets),
           RedesignPacket.phase == design,
           RedesignPacket.rage_cycles =:= 1,
           member(FailureInput, RedesignPacket.artifact_inputs),
           FailureInput.kind == verification_failure )).

test(child_capabilities_cannot_widen,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue)),
       throws(error(consortium_error(capability_widening), _))
     ]) :-
    start(Harness,
          "deny widening",
          [ worker(fake(success)),
            capabilities([model(fake)]),
            phase_capabilities([model(fake), filesystem(project)])
          ],
          _).

test(child_budget_cannot_widen,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue)),
       throws(error(consortium_error(budget_widening), _))
     ]) :-
    start(Harness,
          "deny budget widening",
          [ worker(fake(success)),
            budget(_{max_total_tokens:100, max_cost_usd:1.0,
                     time_limit:10.0}),
            phase_budget(_{max_total_tokens:101, max_cost_usd:1.0,
                           time_limit:10.0})
          ],
          _).

test(unknown_run_option_fails_closed,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue)),
       throws(error(consortium_error(unknown_run_option(ambient_shell(true))), _))
     ]) :-
    start(Harness,
          "reject unknown option",
          [worker(fake(success)), ambient_shell(true)],
          _).

test(usage_survives_in_state_and_events,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    success_options(Options),
    start(Harness, "account usage", Options, RunId),
    wait_terminal(Queue, _),
    status(Harness, RunId, Status),
    assertion(Status.usage.model_calls =:= 6),
    assertion(Status.usage.total_tokens =:= 18),
    events(Harness, RunId, 0, RunEvents),
    findall(Event,
            ( member(Event, RunEvents),
              Event.type == 'usage.updated'
            ),
            UsageEvents),
    length(UsageEvents, 6).

test(verification_packet_binds_exact_implementation_identity,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    success_options(Options),
    start(Harness, "verify exact identity", Options, RunId),
    wait_terminal(Queue, _),
    packet_artifacts(Harness, RunId, Packets),
    member(VerifyPacket, Packets),
    VerifyPacket.phase == verify,
    assertion(VerifyPacket.implementation_identity.kind == "artifact_sha256"),
    string_length(VerifyPacket.implementation_identity.value, 64).

test(fake_provider_end_to_end_reaches_deterministic_success,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    Models = models{root_agent:"fake/root",
                    analyze:"fake/analyze",
                    design:"fake/design",
                    adversarial_review:"fake/adversarial",
                    resolve:"fake/resolve",
                    develop:"fake/develop",
                    verify:"fake/verify"},
    start(Harness,
          "deterministic success",
          [worker(fake(success)), models(Models)],
          RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.completed'),
    status(Harness, RunId, Status),
    assertion(Status.state == complete),
    assertion(Status.phase == verify),
    assertion(Status.implementation_identity.kind == "artifact_sha256"),
    string_length(Status.implementation_identity.value, 64).

test(resolve_rejection_cannot_admit_development,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    start(Harness,
          "reject before development",
          [worker(fake(resolve_rejects))],
          RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.failed'),
    status(Harness, RunId, Status),
    assertion(Status.state == rejected),
    events(Harness, RunId, 0, RunEvents),
    event_phases(RunEvents, 'phase.started', Phases),
    assertion(Phases == [analyze, design, adversarial_review, resolve]).

test(cancel_racing_claimed_callback_cannot_complete_run,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    message_queue_create(CallbackStarted),
    message_queue_create(CallbackRelease),
    message_queue_create(Cancelled),
    setup_call_cleanup(
        true,
        ( start(Harness,
                "serialized cancellation",
                [ worker(fake(success)),
                  completion_barrier(barrier(CallbackStarted,
                                             CallbackRelease))
                ],
                RunId),
          thread_get_message(CallbackStarted,
                             callback_entered(analyze),
                             [timeout(2.0)]),
          thread_create(( cancel(Harness, RunId, Outcome),
                          thread_send_message(Cancelled, Outcome) ),
                        CancelThread,
                        []),
          assertion(\+ thread_get_message(Cancelled, _, [timeout(0.05)])),
          thread_send_message(CallbackRelease, go),
          thread_get_message(Cancelled, ok(cancelled), [timeout(2.0)]),
          thread_join(CancelThread, true),
          status(Harness, RunId, Status),
          assertion(Status.state == cancelled),
          events(Harness, RunId, 0, RunEvents),
          assertion(\+ has_event_type(RunEvents, 'run.completed'))
        ),
        ( message_queue_destroy(CallbackStarted),
          message_queue_destroy(CallbackRelease),
          message_queue_destroy(Cancelled)
        )).

test(malformed_model_result_fails_without_stranding_runtime,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    start(Harness, "malformed", [worker(fake(malformed))], BadRun),
    wait_terminal(Queue, BadTerminal),
    assertion(BadTerminal.type == 'run.failed'),
    status(Harness, BadRun, BadStatus),
    assertion(BadStatus.state == failed),
    start(Harness, "still responsive", [worker(fake(success))], GoodRun),
    wait_terminal(Queue, GoodTerminal),
    assertion(GoodTerminal.type == 'run.completed'),
    status(Harness, GoodRun, GoodStatus),
    assertion(GoodStatus.state == complete).

test(run_budget_is_cumulative_across_phases,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    Budget = _{max_total_tokens:17,
               max_cost_usd:1.0,
               time_limit:10.0},
    start(Harness,
          "bounded total usage",
          [worker(fake(success)), budget(Budget)],
          RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.failed'),
    status(Harness, RunId, Status),
    assertion(Status.state == failed),
    assertion(Status.usage.total_tokens =:= 18).

test(rage_and_repair_budgets_stop_repeated_failures,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    start(Harness,
          "bounded rage",
          [ worker(fake(architectural_failure_always)),
            max_rage_cycles(1)
          ],
          RageRun),
    wait_terminal(Queue, RageTerminal),
    assertion(RageTerminal.type == 'run.failed'),
    status(Harness, RageRun, RageStatus),
    assertion(RageStatus.state == blocked),
    assertion(RageStatus.rage_cycles =:= 1),
    start(Harness,
          "bounded repair",
          [ worker(fake(local_failure_always)),
            max_repairs(1)
          ],
          RepairRun),
    wait_terminal(Queue, RepairTerminal),
    assertion(RepairTerminal.type == 'run.failed'),
    status(Harness, RepairRun, RepairStatus),
    assertion(RepairStatus.state == blocked),
    assertion(RepairStatus.repair_attempts =:= 1).

test(verification_identity_mismatch_cannot_complete,
     [ setup(setup_harness(Harness, Queue)),
       cleanup(cleanup_harness(Harness, Queue))
     ]) :-
    start(Harness,
          "mismatched verification",
          [worker(fake(verification_identity_mismatch))],
          RunId),
    wait_terminal(Queue, Terminal),
    assertion(Terminal.type == 'run.failed'),
    status(Harness, RunId, Status),
    assertion(Status.state == failed),
    events(Harness, RunId, 0, RunEvents),
    assertion(\+ has_event_type(RunEvents, 'run.completed')).

test(completion_options_cannot_override_narrowed_capabilities) :-
    Packet = packet{run_id:test_run,
                    session_id:test_session,
                     model:"test/model",
                     capabilities:[model(fake)],
                     phase:analyze,
                     phase_contract:phase_contract{required_output:[]},
                     artifact_refs:[]},
    Budget = phase_budget{max_total_tokens:32,
                          max_cost_usd:1.0,
                          time_limit:2.0},
    Worker = completion([
                 planner_handler(
                     plunit_consortium_agent:capability_planner),
                 capabilities([filesystem(project)]),
                 child_capabilities([filesystem(project)])
             ]),
    run_phase_async(Packet, Worker, Budget, Future),
    setup_call_cleanup(
        true,
        ( rlm_future_await(Future, 2.0, Outcome),
          Outcome = ok(Result),
          assertion(Result.child_capabilities == [model(fake)])
        ),
        rlm_future_destroy(Future)).

test(direct_provider_requires_matching_model_capability,
     [throws(error(consortium_error(model_capability_denied(openrouter)), _))]) :-
    Packet = packet{run_id:test_run,
                    session_id:test_session,
                     model:"test/model",
                     capabilities:[model(fake)],
                     phase:analyze,
                     phase_contract:phase_contract{required_output:[]},
                     artifact_refs:[]},
    Budget = phase_budget{max_total_tokens:32,
                          max_cost_usd:1.0,
                          time_limit:2.0},
    run_phase_async(Packet,
                    rlm(provider(openrouter, []), openrouter),
                    Budget,
                    _).

test(persistent_artifact_remains_addressable_after_restart) :-
    tmp_file(consortium_artifacts, File),
    message_queue_create(Queue),
    setup_call_cleanup(
        harness_create([store(persist(File)), event_queue(Queue)], First),
        ( start(First,
                "persistent artifact",
                [worker(fake(success))],
                RunId),
          wait_terminal(Queue, _),
          events(First, RunId, 0, Events),
          once(( member(Created, Events),
                 Created.type == 'artifact.created',
                 Created.payload.kind == verification )),
          ArtifactId = Created.payload.artifact_id,
          harness_destroy(First),
          harness_create([store(persist(File))], Second),
          setup_call_cleanup(
              true,
              ( artifact(Second, RunId, ArtifactId, Artifact),
                assertion(Artifact.kind == verification)
              ),
              harness_destroy(Second))
        ),
        ( catch(harness_destroy(First), _, true),
          message_queue_destroy(Queue),
          catch(delete_file(File), _, true)
        )).

:- end_tests(consortium_agent).
