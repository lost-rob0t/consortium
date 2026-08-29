:- module(consortium_agent,
          [ harness_create/2,
            harness_destroy/1,
            start/4,
            status/3,
            cancel/3,
            events/4,
            artifact/4,
            phase_completed/5
          ]).

:- use_module(library(error)).
:- use_module(library(crypto)).
:- use_module(library(gensym)).
:- use_module(library(http/json)).
:- use_module(library(option)).
:- use_module(library(uuid)).
:- use_module(library(rlm_artifact)).
:- use_module(library(rlm_async)).
:- use_module(library(rlm_tool), [capabilities_narrow/3]).
:- use_module(consortium_adard).
:- use_module(consortium_models).
:- use_module(consortium_packets).

:- dynamic harness_record/2.
:- dynamic harness_sink/2.
:- dynamic run_record/3.
:- dynamic run_config/3.
:- dynamic run_event/4.
:- dynamic run_artifact/4.
:- dynamic run_output_ref/3.
:- dynamic run_phase_output/4.
:- dynamic active_attempt/8.
:- dynamic owned_future/2.

harness_create(Options, harness(Id)) :-
    must_be(list, Options),
    option(store(StoreSpec), Options, memory),
    artifact_store_open(StoreSpec, StoreOutcome),
    require_ok(StoreOutcome, Store),
    with_mutex(consortium_state,
               ( gensym(consortium_harness_, Id),
                 assertz(harness_record(Id, Store))
               )),
    forall(member(Option, Options), register_sink(Id, Option)).

register_sink(Id, event_queue(Queue)) :-
    !,
    assertz(harness_sink(Id, queue(Queue))).
register_sink(_, _).

harness_destroy(harness(Id)) :-
    findall(RunId,
            ( run_record(Id, RunId, Status), Status.state == running ),
            Running),
    forall(member(RunId, Running),
           catch(cancel(harness(Id), RunId, _), _, true)),
    findall(Future, retract(owned_future(Id, Future)), Futures),
    maplist(destroy_future_safely, Futures),
    (   retract(harness_record(Id, Store))
    ->  artifact_store_close(Store, _)
    ;   true
    ),
    retractall(harness_sink(Id, _)),
    retractall(run_record(Id, _, _)),
    retractall(run_config(Id, _, _)),
    retractall(run_event(Id, _, _, _)),
    retractall(run_artifact(Id, _, _, _)),
    retractall(run_output_ref(Id, _, _)),
    retractall(run_phase_output(Id, _, _, _)),
    retractall(active_attempt(Id, _, _, _, _, _, _, _)).

destroy_future_safely(Future) :-
    catch(rlm_future_destroy(Future), _, true).

start(Harness, Task0, Options, RunId) :-
    harness_id(Harness, HarnessId),
    text_string(Task0, Task),
    (   Task \== ""
    ->  true
    ;   throw(error(domain_error(nonempty_task, Task),
                    context(consortium_agent:start/4,
                            'task must not be empty')))
    ),
    normalize_run_options(Options, Config),
    validate_start_size(Task, Config),
    uuid(UUID, [version(4)]),
    atom_concat(run_, UUID, RunId),
    get_time(StartedAt),
    initial_usage(Usage),
    Status = run_status{
                 run_id:RunId,
                 task:Task,
                 budget:Config.budget,
                 lineage:lineage{parent_run_id:null, rage_cycle:0},
                 started_at:StartedAt,
                 state:running,
                 phase:analyze,
                 generation:0,
                 repair_attempts:0,
                 rage_cycles:0,
                 usage:Usage,
                 implementation_identity:null,
                 approved_decisions:[],
                 artifacts:[]
             },
    with_mutex(consortium_state,
               ( assertz(run_record(HarnessId, RunId, Status)),
                 assertz(run_config(HarnessId, RunId, Config))
               )),
    emit(HarnessId, RunId, 'run.started', none, none,
          _{task:Task}),
    catch(schedule_phase(HarnessId, RunId, analyze),
          Exception,
          ( cleanup_failed_admission(HarnessId, RunId),
            throw(Exception)
          )).

normalize_run_options(Options, Config) :-
    must_be(list, Options),
    maplist(validate_run_option, Options),
    option(worker(Worker), Options, unconfigured),
    default_models(DefaultModels),
    option(models(Models), Options, DefaultModels),
    must_be(dict, Models),
    option(capabilities(ParentCapabilities),
           Options,
           [model(fake)]),
    option(phase_capabilities(RequestedCapabilities),
           Options,
           ParentCapabilities),
    capabilities_narrow(ParentCapabilities,
                        RequestedCapabilities,
                        CapabilityOutcome),
    require_capability_narrowing(CapabilityOutcome, PhaseCapabilities),
    DefaultBudget = _{max_total_tokens:8192,
                      max_cost_usd:0.25,
                      time_limit:30.0},
    option(budget(Budget0), Options, DefaultBudget),
    dict_pairs(Budget0, _, BudgetPairs),
    dict_pairs(Budget, run_budget, BudgetPairs),
    option(phase_budget(RequestedBudget), Options, Budget),
    narrow_budget(Budget, RequestedBudget, PhaseBudget),
    option(max_repairs(MaxRepairs), Options, 1),
    option(max_rage_cycles(MaxRageCycles), Options, 3),
    must_be(nonneg, MaxRepairs),
    must_be(nonneg, MaxRageCycles),
    option(repository(Repository),
           Options,
           repository_identity{kind:unspecified, value:"unknown"}),
    option(artifact_refs(ArtifactRefs), Options, []),
    option(fact_refs(FactRefs), Options, []),
    option(evidence(Evidence), Options, []),
    option(constraints(Constraints), Options, []),
    option(acceptance_criteria(AcceptanceCriteria), Options, []),
    option(completion_barrier(CompletionBarrier), Options, none),
    maplist(must_be_ground,
            [Worker, Models, Repository, ArtifactRefs, FactRefs,
             Evidence, Constraints, AcceptanceCriteria, CompletionBarrier]),
    Config = run_config{
                 worker:Worker,
                 models:Models,
                 capabilities:ParentCapabilities,
                 phase_capabilities:PhaseCapabilities,
                 budget:Budget,
                 phase_budget:PhaseBudget,
                 max_repairs:MaxRepairs,
                 max_rage_cycles:MaxRageCycles,
                 repository:Repository,
                 initial_artifact_refs:ArtifactRefs,
                 fact_refs:FactRefs,
                 evidence:Evidence,
                 constraints:Constraints,
                 acceptance_criteria:AcceptanceCriteria,
                 completion_barrier:CompletionBarrier
              }.

validate_run_option(Option) :-
    compound(Option),
    functor(Option, Name, 1),
    memberchk(Name,
              [ worker,
                models,
                capabilities,
                phase_capabilities,
                budget,
                phase_budget,
                max_repairs,
                max_rage_cycles,
                repository,
                artifact_refs,
                fact_refs,
                evidence,
                constraints,
                acceptance_criteria,
                completion_barrier
              ]),
    !.
validate_run_option(Option) :-
    throw(error(consortium_error(unknown_run_option(Option)),
                context(consortium_agent:start/4,
                        'run options use a closed trusted vocabulary'))).

validate_start_size(Task, Config) :-
    term_string(start_request(Task, Config), Text, [quoted(true)]),
    string_length(Text, Length),
    (   Length =< 8000
    ->  true
    ;   throw(error(consortium_error(start_request_too_large),
                    context(consortium_agent:start/4,
                            'start request exceeds the bounded packet limit')))
    ).

cleanup_failed_admission(HarnessId, RunId) :-
    retractall(active_attempt(HarnessId, RunId, _, _, _, _, _, _)),
    retractall(run_record(HarnessId, RunId, _)),
    retractall(run_config(HarnessId, RunId, _)),
    retractall(run_event(HarnessId, RunId, _, _)),
    retractall(run_artifact(HarnessId, RunId, _, _)),
    retractall(run_output_ref(HarnessId, RunId, _)),
    retractall(run_phase_output(HarnessId, RunId, _, _)).

must_be_ground(Term) :-
    must_be(ground, Term).

require_capability_narrowing(ok(Capabilities), Capabilities) :- !.
require_capability_narrowing(error(Error), _) :-
    (   is_dict(Error), Error.kind == widening_denied
    ->  throw(error(consortium_error(capability_widening),
                    context(consortium_agent:start/4, Error)))
    ;   throw(error(consortium_error(invalid_capabilities),
                    context(consortium_agent:start/4, Error)))
    ).

schedule_phase(HarnessId, RunId, Phase) :-
    run_mutex(HarnessId, RunId, Mutex),
    with_mutex(Mutex, schedule_phase_locked(HarnessId, RunId, Phase)).

schedule_phase_locked(HarnessId, RunId, Phase) :-
    run_snapshot(HarnessId, RunId, Status, Config),
    Status.state == running,
    phase_artifact_refs(HarnessId,
                        RunId,
                        Phase,
                        Config.initial_artifact_refs,
                        ArtifactRefs),
    phase_artifact_inputs(HarnessId, RunId, Phase, ArtifactInputs),
    remaining_phase_budget(Status, Config, PhaseBudget),
    NextGeneration is Status.generation+1,
    uuid(AttemptUUID, [version(4)]),
    atom_concat(attempt_, AttemptUUID, AttemptId),
    uuid(SessionUUID, [version(4)]),
    atom_concat(session_, SessionUUID, SessionId),
    role_model(Config.models, Phase, Model),
    Run = Status.put(_{
              repository:Config.repository,
              approved_decisions:Status.approved_decisions,
              artifact_refs:ArtifactRefs,
              artifact_inputs:ArtifactInputs,
              fact_refs:Config.fact_refs,
              evidence:Config.evidence,
              constraints:Config.constraints,
              phase_capabilities:Config.phase_capabilities,
              phase_budget:PhaseBudget,
              acceptance_criteria:Config.acceptance_criteria
          }),
    Attempt = attempt{id:AttemptId,
                      generation:NextGeneration,
                      session_id:SessionId,
                      model:Model},
    build_packet(Run, Phase, Attempt, Packet),
    set_phase(HarnessId, RunId, Phase, NextGeneration),
    publish_artifact(HarnessId,
                     RunId,
                     Phase,
                     NextGeneration,
                     context_packet,
                     Packet,
                     PacketId,
                     _),
    run_phase_async(Packet, Config.worker, PhaseBudget, Future),
    rlm_future_then(
        Future,
        consortium_agent:phase_continuation(HarnessId,
                                             RunId,
                                             AttemptId,
                                             NextGeneration),
        Continuation),
    assertz(owned_future(HarnessId, Future)),
    assertz(owned_future(HarnessId, Continuation)),
    assertz(active_attempt(HarnessId,
                           RunId,
                           AttemptId,
                           NextGeneration,
                           Phase,
                           Future,
                           Continuation,
                           Packet)),
    rlm_future_on_complete(
        Continuation,
        consortium_agent:cleanup_attempt_futures(HarnessId,
                                                  Future,
                                                  Continuation)),
    emit(HarnessId, RunId, 'phase.started', Phase, AttemptId,
         _{generation:NextGeneration,
           session_id:SessionId,
           model:Model,
           packet_artifact:PacketId}),
    emit(HarnessId, RunId, 'worker.started', Phase, AttemptId,
         _{generation:NextGeneration, session_id:SessionId}),
    (   Phase == verify
    ->  emit(HarnessId, RunId, 'verification.started', Phase, AttemptId,
             _{implementation_identity:Status.implementation_identity})
    ;   true
    ).

phase_continuation(HarnessId, RunId, AttemptId, Generation, Outcome,
                   processed) :-
    phase_completed(HarnessId, RunId, AttemptId, Generation, Outcome).

cleanup_attempt_futures(HarnessId, Future, Continuation, _) :-
    retractall(owned_future(HarnessId, Future)),
    retractall(owned_future(HarnessId, Continuation)),
    destroy_future_safely(Future),
    destroy_future_safely(Continuation).

phase_completed(Harness0, RunId, AttemptId, Generation, Outcome) :-
    harness_id(Harness0, HarnessId),
    run_mutex(HarnessId, RunId, Mutex),
    with_mutex(
        Mutex,
        catch(( phase_completed_(HarnessId,
                                  RunId,
                                  AttemptId,
                                  Generation,
                                  Outcome)
              -> true
              ;  throw(error(consortium_error(callback_failed),
                             context(consortium_agent:phase_completed/5,
                                     'phase callback failed')))
              ),
              Exception,
              callback_failed(HarnessId,
                              RunId,
                              AttemptId,
                              Exception))).

phase_completed_(HarnessId, RunId, AttemptId, Generation, Outcome) :-
    (   take_active_attempt(HarnessId,
                            RunId,
                            AttemptId,
                            Generation,
                            Phase,
                            _Future,
                            _Continuation,
                            Packet)
    ->  await_completion_barrier(HarnessId, RunId, Phase),
        process_phase_outcome(HarnessId,
                              RunId,
                              Phase,
                              AttemptId,
                               Generation,
                                Packet,
                                Outcome)
    ;   emit(HarnessId, RunId, 'worker.stale', none, AttemptId,
              _{generation:Generation,
                reason:"attempt fence no longer current"})
    ).

await_completion_barrier(HarnessId, RunId, Phase) :-
    run_config(HarnessId, RunId, Config),
    (   Config.completion_barrier = barrier(Started, Release)
    ->  thread_send_message(Started, callback_entered(Phase)),
        thread_get_message(Release, go)
    ;   true
    ).

callback_failed(HarnessId, RunId, AttemptId, Exception) :-
    message_to_string(Exception, Message),
    emit(HarnessId, RunId, 'phase.failed', none, AttemptId,
         _{error:Message, source:"completion callback"}),
    (   catch(status(harness(HarnessId), RunId, Status), _, fail),
        Status.state == running
    ->  fail_run(HarnessId, RunId, none, Message)
    ;   true
    ).

take_active_attempt(HarnessId, RunId, AttemptId, Generation,
                    Phase, Future, Continuation, Packet) :-
    with_mutex(consortium_state,
               ( run_record(HarnessId, RunId, Status),
                 Status.state == running,
                 Status.generation =:= Generation,
                 retract(active_attempt(HarnessId,
                                        RunId,
                                        AttemptId,
                                        Generation,
                                        Phase,
                                        Future,
                                        Continuation,
                                        Packet))
               )).

process_phase_outcome(HarnessId, RunId, Phase, AttemptId, Generation,
                      _Packet, ok(ModelResult)) :-
    is_dict(ModelResult),
    phase_result_payload(Phase, ModelResult, Payload0),
    normalize_phase_payload(Phase, Payload0, Payload),
    !,
    usage_from_result(ModelResult, Usage),
    add_usage(HarnessId, RunId, Usage, TotalUsage),
    emit(HarnessId, RunId, 'usage.updated', Phase, AttemptId,
         _{phase_usage:Usage, total_usage:TotalUsage}),
    handle_payload(HarnessId,
                   RunId,
                   Phase,
                   AttemptId,
                   Generation,
                   Payload).
process_phase_outcome(HarnessId, RunId, Phase, AttemptId, _, _, Error) :-
    account_error_usage(HarnessId, RunId, Phase, AttemptId, Error),
    emit(HarnessId, RunId, 'phase.failed', Phase, AttemptId,
         _{error:Error}),
    fail_run(HarnessId, RunId, Phase, Error).

handle_payload(HarnessId, RunId, Phase, AttemptId, Generation, Payload) :-
    validate_payload_phase(Phase, Payload),
    normalize_name(Payload.status, Status),
    (   Status == completed
    ->  handle_completed_payload(HarnessId,
                                 RunId,
                                 Phase,
                                 AttemptId,
                                 Generation,
                                 Payload)
    ;   Status == failed,
        Phase == verify,
        get_dict(classification, Payload, Classification0),
        normalize_name(Classification0, Classification),
        handle_failed_payload(HarnessId,
                              RunId,
                              Phase,
                              AttemptId,
                              Classification,
                               Payload)
    ;   throw(error(consortium_error(invalid_phase_result),
                    context(consortium_agent:phase_completed/5,
                            'phase result status or failure source is invalid')))
    ).

handle_completed_payload(HarnessId, RunId, Phase, AttemptId, Generation,
                         Payload0) :-
    prepare_completed_payload(Phase, Payload0, Payload),
    validate_completed_payload(HarnessId, RunId, Phase, Payload),
    output_kind(Phase, Kind),
    publish_artifact(HarnessId,
                     RunId,
                     Phase,
                     Generation,
                     Kind,
                     Payload,
                     ArtifactId,
                     ArtifactRef),
    assertz(run_output_ref(HarnessId, RunId, ArtifactRef)),
    retractall(run_phase_output(HarnessId, RunId, Phase, _)),
    assertz(run_phase_output(HarnessId, RunId, Phase, ArtifactRef)),
    apply_phase_fields(HarnessId, RunId, Phase, Payload),
    emit(HarnessId, RunId, 'worker.completed', Phase, AttemptId,
         _{artifact_id:ArtifactId}),
    emit(HarnessId, RunId, 'phase.completed', Phase, AttemptId,
         _{artifact_id:ArtifactId}),
    (   Phase == verify
    ->  emit(HarnessId, RunId, 'verification.completed', Phase, AttemptId,
             _{artifact_id:ArtifactId}),
        complete_run(HarnessId, RunId)
    ;   advance_completed_phase(HarnessId, RunId, Phase, Payload)
    ).

advance_completed_phase(HarnessId, RunId, resolve, Payload) :-
    !,
    get_dict(decision, Payload, Decision0),
    normalize_name(Decision0, Decision),
    apply_resolve_decision(HarnessId, RunId, Decision).
advance_completed_phase(HarnessId, RunId, Phase, _) :-
    next_phase(Phase, Next),
    schedule_phase(HarnessId, RunId, Next).

apply_resolve_decision(HarnessId, RunId, approve) :-
    !,
    status(harness(HarnessId), RunId, Status),
    maplist(required_phase_ref(HarnessId, RunId),
            [analyze, design, adversarial_review, resolve],
            DecisionRefs),
    append(Status.approved_decisions,
           [decision{kind:resolve,
                     value:approve,
                     artifact_refs:DecisionRefs}],
           Decisions),
    update_status(HarnessId, RunId, [approved_decisions-Decisions]),
    schedule_phase(HarnessId, RunId, develop).
apply_resolve_decision(HarnessId, RunId, reject) :-
    !,
    update_status(HarnessId, RunId, [state-rejected]),
    emit(HarnessId, RunId, 'run.failed', resolve, none,
         _{state:rejected, reason:resolve_rejected}).
apply_resolve_decision(HarnessId, RunId, blocked) :-
    !,
    block_run(HarnessId, RunId, resolve_blocked).
apply_resolve_decision(HarnessId, RunId, research) :-
    !,
    route_failure(HarnessId, RunId, missing_evidence).
apply_resolve_decision(HarnessId, RunId, revise) :-
    !,
    route_failure(HarnessId, RunId, architectural_failure).
apply_resolve_decision(HarnessId, RunId, Decision) :-
    fail_run(HarnessId, RunId, resolve, invalid_resolve_decision(Decision)).

phase_result_payload(_, ModelResult, Payload) :-
    get_dict(structured, ModelResult, Structured),
    Structured \== none,
    !,
    dict_pairs(Structured, _, Pairs),
    dict_pairs(Payload, json, Pairs).
phase_result_payload(_, ModelResult, Payload) :-
    get_dict(response, ModelResult, Response),
    !,
    get_dict(text, Response, Text),
    atom_json_dict(Text, Payload, [tag(json)]).
phase_result_payload(_, ModelResult, Payload) :-
    get_dict(value, ModelResult, Value),
    completion_value_payload(Value, Payload).

normalize_phase_payload(Phase, Payload0, Payload) :-
    phase_string_value(Phase, PhaseString),
    put_default_dict(phase, PhaseString, Payload0, Payload1),
    inferred_status(Phase, Payload1, Status),
    put_default_dict(status, Status, Payload1, Payload2),
    put_default_dict(content, "", Payload2, Payload).

inferred_status(verify, Payload, "failed") :-
    get_dict(verified, Payload, false),
    get_dict(classification, Payload, Classification),
    Classification \== null,
    !.
inferred_status(_, _, "completed").

put_default_dict(Key, Default, Dict0, Dict) :-
    ( get_dict(Key, Dict0, _) -> Dict = Dict0
    ; put_dict(Key, Dict0, Default, Dict) ).

phase_string_value(Phase, String) :-
    atom_string(Phase, String).

completion_value_payload(Value, Payload) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    dict_pairs(Payload, json, Pairs).
completion_value_payload(Value, Payload) :-
    atom_json_dict(Value, Payload, [tag(json)]).

validate_payload_phase(Phase, Payload) :-
    get_dict(phase, Payload, PayloadPhase0),
    normalize_name(PayloadPhase0, PayloadPhase),
    (   PayloadPhase == Phase
    ->  true
    ;   throw(error(consortium_error(phase_result_mismatch),
                    context(consortium_agent:phase_completed/5,
                            'worker result names a different phase')))
    ).

validate_completed_payload(_, _, resolve, Payload) :-
    !,
    require_payload_fields(Payload, [decision, rationale]).
validate_completed_payload(_, _, analyze, Payload) :-
    !,
    require_payload_fields(Payload,
                           [findings, evidence, constraints, unknowns,
                            alternatives, falsifiers]).
validate_completed_payload(_, _, design, Payload) :-
    !,
    require_payload_fields(Payload,
                           [architecture, interfaces, invariants,
                            failure_semantics, acceptance_criteria]).
validate_completed_payload(_, _, adversarial_review, Payload) :-
    !,
    require_payload_fields(Payload,
                           [design_binding, attacks, unsupported_assumptions,
                            security_risks, testability, verdict]).
validate_completed_payload(_, _, develop, Payload) :-
    !,
    require_payload_fields(Payload,
                           [implementation_identity, changes, test_evidence]).
validate_completed_payload(HarnessId, RunId, verify, Payload) :-
    !,
    get_dict(verified, Payload, true),
    get_dict(implementation_identity, Payload, VerifiedIdentity),
    get_dict(evidence, Payload, _),
    status(harness(HarnessId), RunId, Status),
    same_implementation_identity(VerifiedIdentity,
                                 Status.implementation_identity).
validate_completed_payload(_, _, _, _).

require_payload_fields(Payload, Fields) :-
    forall(member(Field, Fields), require_payload_field(Payload, Field)).

require_payload_field(Payload, Field) :-
    (   get_dict(Field, Payload, _)
    ->  true
    ;   throw(error(consortium_error(missing_phase_result_field(Field)),
                    context(consortium_agent:phase_completed/5,
                            'phase result omitted a required field')))
    ).

prepare_completed_payload(develop, Payload0, Payload) :-
    !,
    (   del_dict(implementation_identity, Payload0, _, HashPayload)
    ->  true
    ;   HashPayload = Payload0
    ),
    term_string(HashPayload, Canonical, [quoted(true), numbervars(true)]),
    crypto_data_hash(Canonical, HashAtom, [algorithm(sha256), encoding(utf8)]),
    atom_string(HashAtom, Hash),
    Identity = implementation_identity{kind:"artifact_sha256", value:Hash},
    put_dict(implementation_identity, Payload0, Identity, Payload).
prepare_completed_payload(_, Payload, Payload).

same_implementation_identity(Left, Right) :-
    Left.kind == Right.kind,
    Left.value == Right.value,
    !.
same_implementation_identity(_, _) :-
    throw(error(consortium_error(verification_identity_mismatch),
                context(consortium_agent:phase_completed/5,
                        'verification is not bound to the implementation'))).

apply_phase_fields(HarnessId, RunId, develop, Payload) :-
    !,
    get_dict(implementation_identity, Payload, Identity0),
    dict_pairs(Identity0, _, IdentityPairs),
    dict_pairs(Identity, implementation_identity, IdentityPairs),
    update_status(HarnessId,
                  RunId,
                  [implementation_identity-Identity]).
apply_phase_fields(_, _, _, _).

handle_failed_payload(HarnessId, RunId, Phase, AttemptId, Classification,
                      Payload0) :-
    status(harness(HarnessId), RunId, Status),
    put_dict(implementation_identity,
             Payload0,
             Status.implementation_identity,
             Payload),
    publish_artifact(HarnessId,
                     RunId,
                     Phase,
                     Status.generation,
                     verification_failure,
                     Payload,
                     ArtifactId,
                     ArtifactRef),
    assertz(run_output_ref(HarnessId, RunId, ArtifactRef)),
    retractall(run_phase_output(HarnessId, RunId, verify_failure, _)),
    assertz(run_phase_output(HarnessId,
                             RunId,
                             verify_failure,
                             ArtifactRef)),
    emit(HarnessId, RunId, 'worker.completed', Phase, AttemptId,
         _{status:failed,
           classification:Classification,
           artifact_id:ArtifactId}),
    emit(HarnessId, RunId, 'phase.failed', Phase, AttemptId,
         _{classification:Classification,
           artifact_id:ArtifactId,
           implementation_identity:Status.implementation_identity}),
    (   Phase == verify
    ->  emit(HarnessId, RunId, 'verification.failed', Phase, AttemptId,
             _{classification:Classification})
    ;   true
    ),
    route_failure(HarnessId, RunId, Classification).

route_failure(HarnessId, RunId, local_implementation_defect) :-
    !,
    run_snapshot(HarnessId, RunId, Status, Config),
    (   Status.repair_attempts < Config.max_repairs
    ->  Repairs is Status.repair_attempts+1,
        update_status(HarnessId, RunId, [repair_attempts-Repairs]),
        emit(HarnessId, RunId, 'repair.started', develop, none,
             _{attempt:Repairs}),
        schedule_phase(HarnessId, RunId, develop)
    ;   block_run(HarnessId, RunId, repair_budget_exhausted)
    ).
route_failure(HarnessId, RunId, architectural_failure) :-
    !,
    run_snapshot(HarnessId, RunId, Status, Config),
    (   Status.rage_cycles < Config.max_rage_cycles
    ->  RageCycles is Status.rage_cycles+1,
        update_status(HarnessId, RunId, [rage_cycles-RageCycles]),
        emit(HarnessId, RunId, 'rage.started', design, none,
             _{cycle:RageCycles, reason:architectural_failure}),
        schedule_phase(HarnessId, RunId, design)
    ;   block_run(HarnessId, RunId, rage_budget_exhausted)
    ).
route_failure(HarnessId, RunId, missing_evidence) :-
    !,
    run_snapshot(HarnessId, RunId, Status, Config),
    (   Status.rage_cycles < Config.max_rage_cycles
    ->  RageCycles is Status.rage_cycles+1,
        update_status(HarnessId, RunId, [rage_cycles-RageCycles]),
        emit(HarnessId, RunId, 'rage.started', analyze, none,
             _{cycle:RageCycles, reason:missing_evidence}),
        schedule_phase(HarnessId, RunId, analyze)
    ;   block_run(HarnessId, RunId, rage_budget_exhausted)
    ).
route_failure(HarnessId, RunId, Classification) :-
    (   failure_destination(Classification, blocked)
    ->  block_run(HarnessId, RunId, Classification)
    ;   fail_run(HarnessId, RunId, none, Classification)
    ).

complete_run(HarnessId, RunId) :-
    update_status(HarnessId, RunId, [state-complete]),
    status(harness(HarnessId), RunId, Status),
    emit(HarnessId, RunId, 'run.completed', verify, none,
         _{usage:Status.usage,
           implementation_identity:Status.implementation_identity}).

block_run(HarnessId, RunId, Reason) :-
    update_status(HarnessId, RunId, [state-blocked]),
    emit(HarnessId, RunId, 'run.failed', none, none,
         _{state:blocked, reason:Reason}).

fail_run(HarnessId, RunId, Phase, Error) :-
    update_status(HarnessId, RunId, [state-failed]),
    emit(HarnessId, RunId, 'run.failed', Phase, none,
         _{state:failed, error:Error}).

status(Harness, RunId, Status) :-
    harness_id(Harness, HarnessId),
    with_mutex(consortium_state,
               ( run_record(HarnessId, RunId, Found)
               -> Status = Found
               ;  throw(error(existence_error(consortium_run, RunId),
                              context(consortium_agent:status/3,
                                      'run does not exist')))
               )).

cancel(Harness, RunId, Outcome) :-
    harness_id(Harness, HarnessId),
    run_mutex(HarnessId, RunId, Mutex),
    with_mutex(
        Mutex,
        ( with_mutex(consortium_state,
                     cancel_transition(HarnessId,
                                       RunId,
                                       Transition,
                                       Future,
                                       Continuation,
                                       Phase,
                                       AttemptId,
                                       Generation)),
          apply_cancel(HarnessId,
                       RunId,
                       Transition,
                       Future,
                       Continuation,
                       Phase,
                       AttemptId,
                       Generation,
                       Outcome)
        )).

cancel_transition(HarnessId, RunId, already_terminal, none, none, none, none,
                  0) :-
    run_record(HarnessId, RunId, Status),
    Status.state \== running,
    !.
cancel_transition(HarnessId, RunId, cancel, Future, Continuation, Phase,
                  AttemptId, Generation) :-
    retract(run_record(HarnessId, RunId, Status0)),
    Status0.state == running,
    Generation is Status0.generation+1,
    Status = Status0.put(_{state:cancelled, generation:Generation}),
    assertz(run_record(HarnessId, RunId, Status)),
    (   retract(active_attempt(HarnessId,
                               RunId,
                               AttemptId,
                               _,
                               Phase,
                               Future,
                               Continuation,
                               _))
    ->  true
    ;   Future = none,
        Continuation = none,
        Phase = none,
        AttemptId = none
    ).

apply_cancel(_, _, already_terminal, _, _, _, _, _, ok(already_terminal)) :- !.
apply_cancel(HarnessId, RunId, cancel, Future, Continuation, Phase, AttemptId,
             Generation, ok(cancelled)) :-
    (   Future == none
    ->  true
    ;   catch(rlm_future_cancel(Future, _), _, true)
    ),
    (   Continuation == none
    ->  true
    ;   catch(rlm_future_cancel(Continuation, _), _, true)
    ),
    emit(HarnessId, RunId, 'worker.cancelled', Phase, AttemptId,
         _{generation:Generation}),
    emit(HarnessId, RunId, 'run.cancelled', Phase, AttemptId,
         _{generation:Generation}).

events(Harness, RunId, Since, Events) :-
    harness_id(Harness, HarnessId),
    must_be(nonneg, Since),
    with_mutex(consortium_state,
               ( run_record(HarnessId, RunId, _)
               -> findall(Sequence-Event,
                          ( run_event(HarnessId, RunId, Sequence, Event),
                            Sequence > Since
                          ),
                          Pairs)
               ;  throw(error(existence_error(consortium_run, RunId),
                              context(consortium_agent:events/4,
                                      'run does not exist')))
               )),
    keysort(Pairs, Sorted),
    pairs_values(Sorted, Events).

artifact(Harness, RunId, ArtifactId, Artifact) :-
    harness_id(Harness, HarnessId),
    harness_record(HarnessId, Store),
    (   run_artifact(HarnessId, RunId, ArtifactId, Ref)
    ->  artifact_get(Store, Ref, Outcome),
        require_ok(Outcome, Artifact)
    ;   artifact_latest(Store, RunId, ArtifactId, Outcome),
        require_ok(Outcome, Artifact)
    ).

publish_artifact(HarnessId, RunId, Phase, Generation, Kind, Value,
                 ArtifactId, Ref) :-
    harness_record(HarnessId, Store),
    format(atom(ArtifactId), '~w-~w-~d', [Kind, Phase, Generation]),
    Provenance = provenance{run_id:RunId,
                            phase:Phase,
                            generation:Generation,
                            producer:consortium},
    artifact_put(Store,
                 RunId,
                 ArtifactId,
                 Kind,
                 Value,
                 Provenance,
                 Outcome),
    require_ok(Outcome, Artifact),
    Ref = Artifact.ref,
    assertz(run_artifact(HarnessId, RunId, ArtifactId, Ref)),
    add_artifact_id(HarnessId, RunId, ArtifactId),
    emit(HarnessId, RunId, 'artifact.created', Phase, none,
         _{artifact_id:ArtifactId, kind:Kind, ref:Ref}).

emit(HarnessId, RunId, Type, Phase, Worker, Payload) :-
    dict_pairs(Payload, _, PayloadPairs),
    dict_pairs(GroundPayload, payload, PayloadPairs),
    with_mutex(consortium_events,
               ( findall(Sequence,
                         run_event(HarnessId, RunId, Sequence, _),
                         Sequences),
                 next_sequence(Sequences, Sequence),
                 event_timestamp(Timestamp),
                 format(atom(EventId), '~w:~d', [RunId, Sequence]),
                 Event = event{run_id:RunId,
                               sequence:Sequence,
                               event_id:EventId,
                               timestamp:Timestamp,
                               type:Type,
                               phase:Phase,
                               worker:Worker,
                               payload:GroundPayload},
                 assertz(run_event(HarnessId, RunId, Sequence, Event))
               )),
    notify_sinks(HarnessId, Event).

next_sequence([], 1).
next_sequence(Sequences, Sequence) :-
    Sequences \== [],
    max_list(Sequences, Latest),
    Sequence is Latest+1.

event_timestamp(Timestamp) :-
    get_time(Now),
    format_time(string(Timestamp), '%FT%TZ', Now, posix).

notify_sinks(HarnessId, Event) :-
    forall(harness_sink(HarnessId, Sink), notify_sink(Sink, Event)).

notify_sink(queue(Queue), Event) :-
    catch(thread_send_message(Queue, Event, [timeout(0)]), _, true).

run_snapshot(HarnessId, RunId, Status, Config) :-
    with_mutex(consortium_state,
               ( run_record(HarnessId, RunId, Status),
                 run_config(HarnessId, RunId, Config)
               )).

set_phase(HarnessId, RunId, Phase, Generation) :-
    update_status(HarnessId,
                  RunId,
                  [phase-Phase, generation-Generation]).

update_status(HarnessId, RunId, Pairs) :-
    with_mutex(consortium_state,
               ( retract(run_record(HarnessId, RunId, Status0)),
                 put_pairs(Pairs, Status0, Status),
                 assertz(run_record(HarnessId, RunId, Status))
               )).

put_pairs([], Status, Status).
put_pairs([Key-Value|Pairs], Status0, Status) :-
    put_dict(Key, Status0, Value, Status1),
    put_pairs(Pairs, Status1, Status).

add_artifact_id(HarnessId, RunId, ArtifactId) :-
    with_mutex(consortium_state,
               ( retract(run_record(HarnessId, RunId, Status0)),
                 append(Status0.artifacts, [ArtifactId], ArtifactIds),
                 Status = Status0.put(artifacts, ArtifactIds),
                 assertz(run_record(HarnessId, RunId, Status))
               )).

phase_artifact_refs(HarnessId, RunId, Phase, InitialRefs, Refs) :-
    required_output_phases(Phase, RequiredPhases),
    maplist(required_phase_ref(HarnessId, RunId),
            RequiredPhases,
            RequiredRefs),
    failure_context_refs(HarnessId, RunId, Phase, FailureRefs),
    append([RequiredRefs, FailureRefs, InitialRefs], Candidates),
    list_to_set(Candidates, Unique),
    take_first(16, Unique, Refs),
    phase_gate(HarnessId, RunId, Phase).

phase_artifact_inputs(HarnessId, RunId, Phase, Inputs) :-
    required_output_phases(Phase, RequiredPhases),
    maplist(required_phase_ref(HarnessId, RunId),
            RequiredPhases,
            RequiredRefs),
    failure_context_refs(HarnessId, RunId, Phase, FailureRefs),
    run_config(HarnessId, RunId, Config),
    include(available_artifact_ref(HarnessId),
            Config.initial_artifact_refs,
            InitialRefs),
    append([RequiredRefs, FailureRefs, InitialRefs], MaterializedRefs0),
    list_to_set(MaterializedRefs0, MaterializedRefs),
    (   MaterializedRefs == []
    ->  Inputs = []
    ;   harness_record(HarnessId, Store),
        artifact_context_refs(
            Store,
            MaterializedRefs,
            [ max_items(8),
              max_chars(6000),
              consumer(phase(RunId, Phase))
            ],
            Outcome),
        require_ok(Outcome, Pack),
        Inputs = Pack.entries
    ).

available_artifact_ref(HarnessId, Ref) :-
    harness_record(HarnessId, Store),
    artifact_get(Store, Ref, ok(_)).

failure_context_refs(HarnessId, RunId, Phase, [Ref]) :-
    memberchk(Phase, [analyze, design, develop]),
    run_phase_output(HarnessId, RunId, verify_failure, Ref),
    !.
failure_context_refs(_, _, _, []).

required_output_phases(analyze, []).
required_output_phases(design, [analyze]).
required_output_phases(adversarial_review, [analyze, design]).
required_output_phases(resolve, [analyze, design, adversarial_review]).
required_output_phases(develop, [resolve]).
required_output_phases(verify, [develop]).

required_phase_ref(HarnessId, RunId, Phase, Ref) :-
    (   run_phase_output(HarnessId, RunId, Phase, Ref)
    ->  true
    ;   throw(error(consortium_error(missing_phase_artifact(Phase)),
                    context(consortium_agent:schedule_phase/3,
                            'ADARD artifact prerequisite is missing')))
    ).

phase_gate(HarnessId, RunId, develop) :-
    !,
    run_record(HarnessId, RunId, Status),
    member(Decision, Status.approved_decisions),
    Decision.value == approve.
phase_gate(HarnessId, RunId, verify) :-
    !,
    run_record(HarnessId, RunId, Status),
    Status.implementation_identity \== null.
phase_gate(_, _, _).

remaining_phase_budget(Status, Config, Budget) :-
    Usage = Status.usage,
    (   Usage.tokens_known == true,
        Usage.cost_known == true
    ->  true
    ;   throw(error(consortium_error(unverifiable_usage),
                    context(consortium_agent:schedule_phase/3,
                            'reported usage is required before more work')))
    ),
    RemainingTokens is Config.budget.max_total_tokens-Usage.total_tokens,
    RemainingCost is Config.budget.max_cost_usd-Usage.cost_usd,
    get_time(Now),
    Elapsed is Now-Status.started_at,
    RemainingTime is Config.budget.time_limit-Elapsed,
    (   RemainingTokens > 0,
        RemainingCost >= 0,
        RemainingTime > 0
    ->  Tokens is min(Config.phase_budget.max_total_tokens,
                      RemainingTokens),
        Cost is min(Config.phase_budget.max_cost_usd, RemainingCost),
        Time is min(Config.phase_budget.time_limit, RemainingTime),
        Budget = phase_budget{max_total_tokens:Tokens,
                              max_cost_usd:Cost,
                              time_limit:Time}
    ;   throw(error(consortium_error(run_budget_exhausted),
                    context(consortium_agent:schedule_phase/3,
                            'run-level budget is exhausted')))
    ).

take_first(Count, List, Prefix) :-
    length(List, Length),
    (   Length =< Count
    ->  Prefix = List
    ;   length(Prefix, Count),
        append(Prefix, _, List)
    ).

initial_usage(usage_summary{model_calls:0,
                            prompt_tokens:0,
                            completion_tokens:0,
                            total_tokens:0,
                            cost_usd:0.0,
                            tokens_known:true,
                            cost_known:true}).

usage_from_result(Result, Usage) :-
    Usage0 = Result.usage,
    (   get_dict(attempts, Result, Attempts),
        \+ get_dict(model_calls, Usage0, _)
    ->  put_dict(model_calls, Usage0, Attempts, Usage1)
    ;   Usage1 = Usage0
    ),
    normalize_usage(Usage1, Usage).

account_error_usage(HarnessId, RunId, Phase, AttemptId, error(Error)) :-
    is_dict(Error),
    get_dict(usage, Error, Usage0),
    !,
    normalize_usage(Usage0, Usage),
    add_usage(HarnessId, RunId, Usage, TotalUsage),
    emit(HarnessId, RunId, 'usage.updated', Phase, AttemptId,
         _{phase_usage:Usage, total_usage:TotalUsage}).
account_error_usage(_, _, _, _, _).

normalize_usage(Usage0, Usage) :-
    ( get_dict(model_calls, Usage0, ModelCalls) -> true ; ModelCalls = 1 ),
    ( get_dict(cost_usd, Usage0, Cost) -> true
    ; get_dict(cost, Usage0, Cost) -> true
    ; Cost = 0.0 ),
    ( get_dict(tokens_known, Usage0, TokensKnown) -> true
    ; TokensKnown = true ),
    ( get_dict(cost_known, Usage0, CostKnown) -> true
    ; CostKnown = true ),
    Usage = usage_summary{
                model_calls:ModelCalls,
                prompt_tokens:Usage0.prompt_tokens,
                completion_tokens:Usage0.completion_tokens,
                total_tokens:Usage0.total_tokens,
                cost_usd:Cost,
                tokens_known:TokensKnown,
                cost_known:CostKnown
            }.

add_usage(HarnessId, RunId, Delta, Total) :-
    with_mutex(consortium_state,
               ( retract(run_record(HarnessId, RunId, Status0)),
                 usage_add(Status0.usage, Delta, Total),
                 Status = Status0.put(usage, Total),
                 assertz(run_record(HarnessId, RunId, Status))
               )).

usage_add(A, B,
          usage_summary{
              model_calls:ModelCalls,
              prompt_tokens:PromptTokens,
              completion_tokens:CompletionTokens,
              total_tokens:TotalTokens,
              cost_usd:Cost,
              tokens_known:TokensKnown,
              cost_known:CostKnown
          }) :-
    ModelCalls is A.model_calls+B.model_calls,
    PromptTokens is A.prompt_tokens+B.prompt_tokens,
    CompletionTokens is A.completion_tokens+B.completion_tokens,
    TotalTokens is A.total_tokens+B.total_tokens,
    Cost is A.cost_usd+B.cost_usd,
    bool_and(A.tokens_known, B.tokens_known, TokensKnown),
    bool_and(A.cost_known, B.cost_known, CostKnown).

bool_and(true, true, true) :- !.
bool_and(_, _, false).

normalize_name(Value, Atom) :-
    (   atom(Value)
    ->  Atom = Value
    ;   string(Value)
    ->  atom_string(Atom, Value)
    ).

require_ok(ok(Value), Value) :- !.
require_ok(error(Error), _) :-
    throw(error(consortium_error(runtime(Error)),
                context(consortium_agent, 'Prolog-RLM operation failed'))).

harness_id(harness(Id), Id) :-
    harness_record(Id, _),
    !.
harness_id(Id, Id) :-
    atom(Id),
    harness_record(Id, _),
    !.
harness_id(Harness, _) :-
    throw(error(existence_error(consortium_harness, Harness),
                context(consortium_agent, 'harness does not exist'))).

run_mutex(HarnessId, RunId, Mutex) :-
    format(atom(Mutex), 'consortium_run_~w_~w', [HarnessId, RunId]).

text_string(Text, String) :-
    (   string(Text)
    ->  String = Text
    ;   atom(Text)
    ->  atom_string(Text, String)
    ;   throw(error(type_error(text, Text),
                    context(consortium_agent:start/4,
                            'task must be text')))
    ).
