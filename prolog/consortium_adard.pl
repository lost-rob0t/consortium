:- module(consortium_adard,
          [ next_phase/2,
            output_kind/2,
            failure_destination/2
          ]).

:- use_module(adard_state).

next_phase(Phase, Next) :-
    normal_transition(Phase, Next).

output_kind(analyze, analysis).
output_kind(design, design).
output_kind(adversarial_review, adversarial_review).
output_kind(resolve, resolve_decision).
output_kind(develop, implementation).
output_kind(verify, verification).

failure_destination(Classification, Destination) :-
    failure_route(Classification, Destination).
