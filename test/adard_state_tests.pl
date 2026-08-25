:- begin_tests(adard_state).

:- use_module('../prolog/adard_state').

test(canonical_phase_order) :-
    initial_phase(analyze),
    normal_transition(analyze, design),
    normal_transition(design, adversarial_review),
    normal_transition(adversarial_review, resolve),
    normal_transition(resolve, develop),
    normal_transition(develop, verify),
    normal_transition(verify, complete).

test(all_model_phases_are_fresh_context) :-
    forall(phase(Phase), fresh_context_phase(Phase)).

test(develop_requires_approved_resolve) :-
    phase_requires(develop, approved_resolve_decision).

test(verify_requires_exact_identity) :-
    phase_requires(verify, exact_implementation_identity).

test(local_defect_routes_to_develop) :-
    failure_route(local_implementation_defect, develop).

test(local_defect_does_not_restart_analysis, [fail]) :-
    failure_route(local_implementation_defect, analyze).

test(architectural_failure_routes_to_design) :-
    failure_route(architectural_failure, design).

test(unsafe_blocks) :-
    failure_route(unsafe, blocked).

:- end_tests(adard_state).
