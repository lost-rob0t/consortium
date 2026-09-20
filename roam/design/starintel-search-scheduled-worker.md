# StarIntel Search scheduled worker bootstrap

Tracking: #23
Depends on: #22, #8, #11
Initial target: starintel-labs/starintel-search#3

## Purpose

Run a reusable headless Consortium sweep on a cron-style schedule. The trigger may be cron or a systemd timer, but it must call one bounded Consortium command rather than containing workflow logic itself.

Target semantic command:

```sh
consortium sweep --profile starintel-search --once
```

The command does not exist yet; #23 adds it.

## Ownership

- Prolog-RLM: tools, Experts, capability/budget authority, model execution runtime.
- Consortium: ADARD/RAGE workflow, phase packets, durable run lineage and gates.
- OpenCode: coding worker backend.
- Emacs: operator/control/inspection UI.
- cron/systemd: trigger only.

## Scheduled sweep

Each sweep:

1. acquire project-profile lease/fence;
2. recover/reconcile existing run;
3. check OpenCode/provider availability;
4. read current Z.AI Coding Plan quota state when available;
5. select eligible issue/slice;
6. start or resume one bounded run through Consortium;
7. emit durable events/artifacts;
8. exit with machine-readable status.

Double invocation must still result in one effective owner.

## Initial project profile

The first profile targets `starintel-labs/starintel-search` and should include:
- canonical branch `main`;
- OpenCode worker adapter;
- Z.AI Coding Plan provider profile;
- issue selection rules;
- allowed capabilities/tools/Experts;
- branch/worktree naming;
- test/verify commands;
- ARADR policy;
- RAGE cycle policy;
- RSI proposal/evaluation policy;
- admission/quota thresholds.

Keep the profile format reusable for other repositories.

## ARADR

ARADR is a research path before design when external/repository evidence is missing.

For search issue #3 it should verify at minimum:
- current SearXNG YaCy engine behavior;
- current SearXNG container deployment;
- current YaCy container/API/index export behavior;
- current StarIntel actor/ingest/star:// contracts.

Research artifacts are immutable downstream inputs and include source/provenance hashes.

## Auto-RAGE

RAGE is entered only through an explicit failure classification/gate. It is appropriate for architectural contradictions or missing design evidence, not ordinary local implementation defects.

Every automatic RAGE path has:
- finite budget;
- parent lineage;
- fresh model context;
- immutable prior artifacts;
- explicit resolve decision;
- terminal blocked state on budget exhaustion.

## RSI

RSI watches measured failures and proposes changes.

Inputs include:
- success/failure classification;
- CI/test/reviewer outcome;
- repair/RAGE counts;
- tool/Expert use;
- quota/usage;
- latency;
- context/artifact size;
- cancellation/fencing faults.

Output is a reviewable proposal branch/PR. It must pass benchmark + adversarial review + exact-head verification before merge. RSI never makes its own proposal authoritative merely by writing it.

## Emacs

Interactive and scheduled runs share the same event stream/state model. When Emacs is connected, the user can inspect:
- run/phase status;
- peer chat/event feed;
- files/artifacts;
- runtime-loaded KB/Experts;
- agents/workers;
- diff/test/verify evidence.

Headless execution remains fully functional with Emacs absent.
