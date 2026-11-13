% CI cancel-barrier knowledge: verified failure mode of the deterministic
% test gate.
% discovery/2 is declared dynamic+discontiguous in index.pl.

failure_mode(ci_cancel_starvation,
  'cancel_racing_claimed_callback_cannot_complete_run (PlUnit) can exceed
   its 30s cancel_completion wait under concurrent CI nix builds; local
   runs stay green.  Root cause contract: cancel/3 blocks on run_mutex
   held by the completion callback inside with_mutex(phase_completed_ incl
   await_completion_barrier); mutex ordering is contract-enforced, so the
   fix is generous positive waits, never removing the tight negative
   assertion.  PR 26 added generous timeouts plus an always-on
   barrier-diagnosis dump; the flake recurred once on the PR 31 run and
   the dump self-identified it (cancel_completion timed out after 30s,
   run in design phase) and a re-run went green.  If it recurs again,
   raise the cancel_completion wait or make the barrier wait
   load-adaptive in the same slice that touches the barrier.').

diagnosis_dump(barrier_diagnosis,
  'The deterministic test gate prints [barrier-diagnosis] lines (timeout
   reason, full run_status, recent events) on cancel-barrier timeouts.
   Treat those lines as the authoritative evidence for flake triage:
   they distinguish CI starvation from a real cancellation regression
   without a local reproduction.').
