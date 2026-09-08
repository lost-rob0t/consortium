% Consortium ADARD state contract.
% Copyright (C) 2026 Consortium contributors
%
% This program is free software; you can redistribute it and/or modify
% it under the terms of the GNU General Public License as published by
% the Free Software Foundation; either version 2 of the License, or
% (at your option) any later version.

:- module(consortium_adard_state,
          [ phase/1,
            initial_phase/1,
            terminal_state/1,
            normal_transition/2,
            failure_route/2,
            fresh_context_phase/1,
            phase_requires/2
          ]).

phase(analyze).
phase(design).
phase(adversarial_review).
phase(resolve).
phase(develop).
phase(verify).

initial_phase(analyze).
terminal_state(complete).
terminal_state(rejected).
terminal_state(blocked).
terminal_state(cancelled).
terminal_state(failed).

normal_transition(analyze, design).
normal_transition(design, adversarial_review).
normal_transition(adversarial_review, resolve).
normal_transition(resolve, develop).
normal_transition(develop, verify).
normal_transition(verify, complete).

% Failure routing is classification-driven.  A local implementation defect
% does not restart architectural analysis.
failure_route(local_implementation_defect, develop).
failure_route(missing_evidence, analyze).
failure_route(architectural_failure, design).
failure_route(architectural_unknown, analyze).
failure_route(unverifiable, blocked).
failure_route(unsafe, blocked).

% Every model-bearing ADARD phase must begin with a fresh provider/model
% context.  Durable artifacts and Prolog facts are the cross-phase memory.
fresh_context_phase(analyze).
fresh_context_phase(design).
fresh_context_phase(adversarial_review).
fresh_context_phase(resolve).
fresh_context_phase(develop).
fresh_context_phase(verify).

phase_requires(design, analysis_artifact).
phase_requires(adversarial_review, design_artifact).
phase_requires(resolve, analysis_artifact).
phase_requires(resolve, design_artifact).
phase_requires(resolve, adversarial_review_artifact).
phase_requires(develop, approved_resolve_decision).
phase_requires(verify, exact_implementation_identity).
