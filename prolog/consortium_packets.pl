:- module(consortium_packets,
          [ build_packet/4,
            packet_prompt/2,
            validate_packet/1,
            narrow_budget/3,
            capability_strings/2
          ]).

:- use_module(library(error)).
:- use_module(library(lists)).

build_packet(Run, Phase, Attempt, Packet) :-
    phase_contract(Phase, Contract),
    Base = packet{
               schema:"consortium.phase-packet.v1",
               run_id:Run.run_id,
               attempt_id:Attempt.id,
               generation:Attempt.generation,
               session_id:Attempt.session_id,
               phase:Phase,
               role:Phase,
               model:Attempt.model,
               task:Run.task,
               repository:Run.repository,
               approved_decisions:Run.approved_decisions,
               artifact_refs:Run.artifact_refs,
               artifact_inputs:Run.artifact_inputs,
               fact_refs:Run.fact_refs,
               evidence:Run.evidence,
               constraints:Run.constraints,
               capabilities:Run.phase_capabilities,
               budget:Run.phase_budget,
               acceptance_criteria:Run.acceptance_criteria,
               phase_contract:Contract,
               response_contract:response_contract{
                   format:"one JSON object, no markdown",
                   required:[phase, status, content],
                   phase:Phase,
                   statuses:[completed, failed],
                   failed_only_in:verify
               },
               repair_attempt:Run.repair_attempts,
               rage_cycles:Run.rage_cycles,
               provenance:provenance{
                              source:"consortium",
                              run_id:Run.run_id,
                              generation:Attempt.generation
                          }
           },
    add_implementation_identity(Phase, Run, Base, Packet),
    validate_packet(Packet).

phase_contract(analyze,
               phase_contract{
                   objective:"Establish repository state, evidence, constraints, unknowns, alternatives, and falsifiers.",
                   required_output:[findings, evidence, constraints, unknowns,
                                    alternatives, falsifiers]
               }).
phase_contract(design,
               phase_contract{
                   objective:"Produce an implementation-ready design from the bound analysis evidence.",
                   required_output:[architecture, interfaces, invariants,
                                    failure_semantics, acceptance_criteria]
               }).
phase_contract(adversarial_review,
               phase_contract{
                   objective:"Independently attack the exact design and identify material vetoes or risks.",
                   required_output:[design_binding, attacks, unsupported_assumptions,
                                    security_risks, testability, verdict]
               }).
phase_contract(resolve,
               phase_contract{
                   objective:"Adjudicate the bound analysis, design, and review without granting authority from prose.",
                   required_output:[decision, rationale],
                   decisions:[approve, revise, research, reject, blocked]
               }).
phase_contract(develop,
               phase_contract{
                   objective:"Implement only the approved design through admitted Prolog-RLM tools and TDD.",
                   required_output:[implementation_identity, changes, test_evidence]
               }).
phase_contract(verify,
               phase_contract{
                   objective:"Independently verify the exact implementation identity and classify any failure.",
                   required_output:[verified, implementation_identity,
                                    evidence, classification],
                   failure_classes:[local_implementation_defect,
                                    missing_evidence,
                                    architectural_failure,
                                    unverifiable,
                                    unsafe]
               }).

add_implementation_identity(verify, Run, Base, Packet) :-
    !,
    put_dict(implementation_identity,
             Base,
             Run.implementation_identity,
             Packet).
add_implementation_identity(_, _, Packet, Packet).

packet_prompt(Packet, Prompt) :-
    validate_packet(Packet),
    term_string(Packet,
                PacketText,
                [ quoted(true),
                  numbervars(true),
                  max_depth(64)
                ]),
    string_length(PacketText, Length),
    append([phase, status, content],
           Packet.phase_contract.required_output,
           RequiredKeys),
    response_shape_instruction(Packet.phase, ShapeInstruction),
    (   Length =< 12000
    ->  format(string(Prompt),
               "Execute exactly one Consortium ADARD phase from this explicit packet. Use the materialized artifact_inputs as prior-phase evidence. Return one JSON object only, with no markdown, transcript, or hidden reasoning. The top-level object MUST contain exactly these keys: ~q. Do not wrap them under analysis, result, output, or another key. Use phase=~w and status=completed for success. Obey phase_contract and response_contract. ~s\n~s",
               [RequiredKeys, Packet.phase, ShapeInstruction, PacketText])
    ;   throw(error(consortium_error(packet_too_large),
                    context(consortium_packets:packet_prompt/2,
                            'phase packet exceeds 12000 characters')))
     ).

response_shape_instruction(develop,
                           "implementation_identity MUST be a JSON object with exactly string fields kind and value, not a bare hash string.") :-
    !.
response_shape_instruction(verify,
                           "implementation_identity MUST be a JSON object with exactly string fields kind and value, not a bare hash string.") :-
    !.
response_shape_instruction(_, "Use the exact JSON types implied by the required fields.").

validate_packet(Packet) :-
    must_be(ground, Packet),
    (   forbidden_key_in(Packet, Key)
    ->  throw(error(consortium_error(forbidden_packet_key(Key)),
                    context(consortium_packets:validate_packet/1,
                            'phase packets cannot carry conversational state')))
    ;   true
    ),
    length(Packet.artifact_refs, ArtifactCount),
    (   ArtifactCount =< 16
    ->  true
    ;   throw(error(consortium_error(too_many_artifact_refs),
                    context(consortium_packets:validate_packet/1,
                            'phase packets allow at most 16 artifact refs')))
    ).

forbidden_key(messages).
forbidden_key(transcript).
forbidden_key(conversation).
forbidden_key(hidden_context).

forbidden_key_in(Dict, Key) :-
    is_dict(Dict),
    dict_pairs(Dict, _, Pairs),
    member(PairKey-Value, Pairs),
    (   forbidden_key(PairKey), Key = PairKey
    ;   forbidden_key_in(Value, Key)
    ).
forbidden_key_in(List, Key) :-
    is_list(List),
    member(Value, List),
    forbidden_key_in(Value, Key).

narrow_budget(Parent, Requested, Child) :-
    must_be(dict, Parent),
    must_be(dict, Requested),
    budget_dimension(max_total_tokens, Parent, Requested),
    budget_dimension(max_cost_usd, Parent, Requested),
    budget_dimension(time_limit, Parent, Requested),
    dict_pairs(Requested, _, Pairs),
    dict_pairs(Child, phase_budget, Pairs).

budget_dimension(Key, Parent, Requested) :-
    get_dict(Key, Parent, ParentValue),
    get_dict(Key, Requested, ChildValue),
    number(ParentValue),
    number(ChildValue),
    (   ChildValue =< ParentValue
    ->  true
    ;   throw(error(consortium_error(budget_widening),
                    context(consortium_packets:narrow_budget/3,
                            Key)))
    ).

capability_strings(Capabilities, Strings) :-
    maplist(capability_string, Capabilities, Strings).

capability_string(Capability, String) :-
    term_string(Capability, String, [quoted(true)]).
