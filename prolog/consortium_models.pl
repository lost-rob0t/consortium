:- module(consortium_models,
          [ default_models/1,
            role_model/3,
            run_phase_async/4,
            model_handler/4
          ]).

:- use_module(library(http/json)).
:- use_module(library(rlm_chain), [chain_invoke_async/4]).
:- use_module(library(rlm_completion)).
:- use_module(library(rlm_tool), [capability_allowed/2]).
:- use_module(consortium_packets).

default_models(
    models{root_agent:"operator/default",
           analyze:"operator/analyze",
           design:"operator/design",
           adversarial_review:"operator/adversarial",
           resolve:"operator/resolve",
           develop:"operator/develop",
           verify:"operator/verify"}).

role_model(Models, Role, Model) :-
    get_dict(Role, Models, Model),
    !.
role_model(_, Role, _) :-
    throw(error(consortium_error(missing_model_role(Role)),
                context(consortium_models:role_model/3,
                        'every ADARD role requires explicit model routing'))).

run_phase_async(Packet, Worker, Budget, Future) :-
    fake_worker(Worker),
    !,
    require_model_capability(Packet.capabilities, fake),
    packet_prompt(Packet, Prompt),
    Handler = consortium_models:model_handler(Worker, Packet),
    Options = [ model_handler(Handler),
                provider_name(fake),
                trace_id(Packet.run_id),
                session_id(Packet.session_id),
                budget(Budget),
                planner_max_tokens(Budget.max_total_tokens)
              ],
    llm_query_async(Prompt, Options, Future).
run_phase_async(Packet, rlm(Provider, ProviderName), Budget, Future) :-
    !,
    require_model_capability(Packet.capabilities, ProviderName),
    packet_prompt(Packet, Prompt),
    phase_structured_schema(Packet.phase, Schema),
    Request = model_request{
                  messages:[message{role:user, content:Prompt}],
                  options:_{max_tokens:Budget.max_total_tokens,
                            temperature:0,
                            response_format:_{type:"json_object"}}
              },
    Retry = retry_policy{max_attempts:2,
                         base_delay:0.25,
                         max_delay:0.25,
                         retry_kinds:[provider_error, structured_validation]},
    Options = [ structured_schema(Schema),
                retry_policy(Retry),
                trace_id(Packet.run_id),
                session_id(Packet.session_id)
              ],
    chain_invoke_async(Provider, Request, Options, Future).
run_phase_async(Packet, rlm, Budget, Future) :-
    !,
    route_provider(Packet.model, Provider, ProviderName),
    run_phase_async(Packet, rlm(Provider, ProviderName), Budget, Future).
run_phase_async(Packet, completion(CompletionOptions), Budget, Future) :-
    !,
    packet_prompt(Packet, Prompt),
    exclude(runtime_owned_completion_option,
            CompletionOptions,
            NarrowedOptions),
    Options = [ budget(Budget),
                trace_id(Packet.run_id),
                session_id(Packet.session_id),
                capabilities(Packet.capabilities),
                child_capabilities(Packet.capabilities)
              |NarrowedOptions],
    rlm_completion_async(Prompt, text(""), Options, Future).
run_phase_async(Packet, Worker, Budget, Future) :-
    packet_prompt(Packet, Prompt),
    Handler = consortium_models:model_handler(Worker, Packet),
    Options = [ model_handler(Handler),
                provider_name(unconfigured),
                trace_id(Packet.run_id),
                session_id(Packet.session_id),
                budget(Budget),
                planner_max_tokens(Budget.max_total_tokens)
              ],
    llm_query_async(Prompt, Options, Future).

fake_worker(fake(_)).
fake_worker(barrier(_, _, _)).

route_provider(Route, Provider, ProviderName) :-
    is_dict(Route),
    get_dict(provider, Route, Provider),
    get_dict(provider_name, Route, ProviderName),
    ground(Provider),
    ground(ProviderName),
    !.
route_provider(Route, _, _) :-
    throw(error(consortium_error(invalid_model_route(Route)),
                context(consortium_models:run_phase_async/4,
                        'rlm workers require a provider-bearing role route'))).

runtime_owned_completion_option(Option) :-
    functor(Option, Name, 1),
    memberchk(Name,
              [budget, trace_id, session_id,
               capabilities, child_capabilities]).

require_model_capability(Capabilities, ProviderName) :-
    (   capability_allowed(Capabilities, model(ProviderName))
    ->  true
    ;   throw(error(consortium_error(model_capability_denied(ProviderName)),
                    context(consortium_models:run_phase_async/4,
                            'phase does not possess the selected model capability')))
    ).

phase_structured_schema(Phase, object(Fields)) :-
    phase_string(Phase, PhaseString),
    Common = [ field(phase, enum([PhaseString]), optional(PhaseString)),
               field(status,
                     enum(["completed", "failed"]),
                     optional("completed")),
               field(content, any, optional(""))
             ],
    phase_schema_fields(Phase, PhaseFields),
    append(Common, PhaseFields, Fields).

phase_schema_fields(analyze,
                    [ field(findings, any, required),
                      field(evidence, any, required),
                      field(constraints, any, required),
                      field(unknowns, any, required),
                      field(alternatives, any, required),
                      field(falsifiers, any, required)
                    ]).
phase_schema_fields(design,
                    [ field(architecture, any, required),
                      field(interfaces, any, required),
                      field(invariants, any, required),
                      field(failure_semantics, any, required),
                      field(acceptance_criteria, any, required)
                    ]).
phase_schema_fields(adversarial_review,
                    [ field(design_binding, any, required),
                      field(attacks, any, required),
                      field(unsupported_assumptions, any, required),
                      field(security_risks, any, required),
                      field(testability, any, required),
                      field(verdict, any, required)
                    ]).
phase_schema_fields(resolve,
                    [ field(decision,
                            enum(["approve", "revise", "research",
                                  "reject", "blocked"]),
                            required),
                      field(rationale, any, required)
                    ]).
phase_schema_fields(develop,
                    [ field(implementation_identity,
                            object([field(kind, string, required),
                                    field(value, string, required)]),
                            required),
                      field(changes, any, required),
                      field(test_evidence, any, required)
                    ]).
phase_schema_fields(verify,
                    [ field(verified, boolean, optional(false)),
                      field(implementation_identity,
                            object([field(kind, string, required),
                                    field(value, string, required)]),
                            required),
                      field(evidence, any, required),
                      field(classification, any, optional(null))
                    ]).

phase_string(Phase, String) :-
    atom_string(Phase, String).

model_handler(fake(blocking), _, _, _) :-
    !,
    thread_get_message(_).

model_handler(fake(Scenario), Packet, Request, ok(Response)) :-
    !,
    fake_request_is_fresh(Request),
    fake_payload(Packet, Scenario, Payload),
    payload_response(Payload, Response).
model_handler(barrier(Started, Release, Scenario), Packet, Request, Outcome) :-
    !,
    fake_request_is_fresh(Request),
    thread_send_message(Started, worker_entered(Packet.phase, Packet)),
    thread_get_message(Release, go),
    fake_payload(Packet, Scenario, Payload),
    payload_response(Payload, Response),
    Outcome = ok(Response).
model_handler(Worker, _, _, error(Error)) :-
    Error = completion_error{
                phase:model,
                kind:unsupported_worker,
                worker:Worker,
                message:"unsupported Consortium worker binding"
            }.

fake_request_is_fresh(Request) :-
    Request.messages = [Message],
    Message.role == user,
    !.
fake_request_is_fresh(_) :-
    throw(error(consortium_error(non_fresh_model_request),
                context(consortium_models:model_handler/4,
                        'a phase model request must contain one fresh user message'))).

fake_payload(Packet, local_failure_once, Payload) :-
    Packet.phase == verify,
    Packet.repair_attempt =:= 0,
    !,
    failed_payload(Packet, local_implementation_defect, Payload).
fake_payload(Packet, architectural_failure_once, Payload) :-
    Packet.phase == verify,
    Packet.rage_cycles =:= 0,
    !,
    failed_payload(Packet, architectural_failure, Payload).
fake_payload(Packet, architectural_failure_always, Payload) :-
    Packet.phase == verify,
    !,
    failed_payload(Packet, architectural_failure, Payload).
fake_payload(Packet, local_failure_always, Payload) :-
    Packet.phase == verify,
    !,
    failed_payload(Packet, local_implementation_defect, Payload).
fake_payload(Packet, malformed, Payload) :-
    !,
    Payload = _{phase:Packet.phase,
                content:"missing required status"}.
fake_payload(Packet, verification_identity_mismatch, Payload) :-
    Packet.phase == verify,
    !,
    Payload = _{phase:verify,
                status:"completed",
                verified:true,
                implementation_identity:_{kind:"tree", value:"wrong-tree"},
                content:"mismatched identity"}.
fake_payload(Packet, resolve_rejects, Payload) :-
    Packet.phase == resolve,
    !,
    Payload = _{phase:resolve,
                status:"completed",
                decision:"reject",
                rationale:"deterministic rejection",
                content:"deterministic rejection"}.
fake_payload(Packet, _, Payload) :-
    successful_payload(Packet, Payload).

failed_payload(Packet, Classification,
               _{phase:Packet.phase,
                 status:"failed",
                 classification:Classification,
                 content:"deterministic fake verification failure"}).

successful_payload(Packet, Payload) :-
    Phase = Packet.phase,
    phase_success_fields(Packet, Fields),
    put_dict(Fields,
             _{phase:Phase,
               status:"completed",
               content:"deterministic fake phase result"},
             Payload).

phase_success_fields(Packet,
                     _{decision:"approve",
                       rationale:"deterministic approval"}) :-
    Packet.phase == resolve,
    !.
phase_success_fields(Packet,
                     _{findings:["deterministic finding"],
                       evidence:[],
                       constraints:Packet.constraints,
                       unknowns:[],
                       alternatives:[],
                       falsifiers:[]}) :-
    Packet.phase == analyze,
    !.
phase_success_fields(Packet,
                     _{architecture:"deterministic architecture",
                       interfaces:[],
                       invariants:[],
                       failure_semantics:[],
                       acceptance_criteria:Packet.acceptance_criteria}) :-
    Packet.phase == design,
    !.
phase_success_fields(Packet,
                     _{design_binding:Packet.artifact_refs,
                       attacks:[],
                       unsupported_assumptions:[],
                       security_risks:[],
                       testability:[],
                       verdict:"accept"}) :-
    Packet.phase == adversarial_review,
    !.
phase_success_fields(Packet,
                     _{implementation_identity:
                           implementation_identity{
                               kind:tree,
                               value:"fake-tree-1"
                           },
                       changes:[],
                       test_evidence:[]}) :-
    Packet.phase == develop,
    !.
phase_success_fields(Packet,
                     _{verified:true,
                       implementation_identity:Implementation,
                       evidence:[]}) :-
    Packet.phase == verify,
    !,
    Implementation = Packet.implementation_identity.
phase_success_fields(_, _{}).

payload_response(Payload,
                 model_response{
                     provider:fake,
                     requested_model:fake,
                     selected_model:fake,
                     text:Text,
                     reasoning:"",
                     tool_calls:[],
                     finish_reason:stop,
                     usage:usage{
                               present:true,
                               prompt_tokens:2,
                               completion_tokens:1,
                               total_tokens:3,
                               cost:0.0
                           },
                     metadata:metadata{
                                  http_status:200,
                                  response_received:true
                              }
                 }) :-
    atom_json_dict(Atom, Payload, []),
    atom_string(Atom, Text).
