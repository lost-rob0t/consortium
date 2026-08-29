# Consortium agent contract

These instructions apply repository-wide unless a nested `AGENTS.md` narrows them.

## Mission

Consortium orchestrates independent model workers over a durable Prolog-RLM control plane. Keep provider-specific behavior, UI concerns, and concrete coding-agent tools outside the core workflow semantics.

## ADARD workflow

The canonical phase order is:

`analyze -> design -> adversarial_review -> resolve -> develop -> verify`

Verification may finish the run, request bounded repair, or classify a failure as architectural and return it to analysis/design through an explicit gate.

## Context isolation

- Every model phase starts with fresh provider/model context.
- Never pass hidden chain-of-thought or a prior worker transcript as implicit phase state.
- Cross-phase knowledge is transferred only through immutable input packets, durable artifacts, cited evidence, and Prolog facts.
- A phase packet must identify every artifact/fact it includes.
- Keep packets bounded. Retrieve relevant facts/artifacts instead of replaying entire histories.

## Authority and effects

- Model output is data, not execution authority.
- Prolog owns legal transitions, budgets, capabilities, cancellation, lineage, and effect accounting.
- Reuse `prolog-rlm` execution/authority semantics instead of creating a second unrestricted tool runtime.
- Tool availability does not imply permission.
- External effects require an admitted tool/effect path; a phase cannot obtain shell/network/repository authority from prose.

## Gates

- Design requires a completed analysis artifact.
- Adversarial review binds to an immutable design artifact.
- Resolve binds to the exact analysis/design/review identities it adjudicates.
- Develop requires an explicit `approve` resolve decision.
- Verify binds to an exact implementation identity (commit/tree/artifact hash as appropriate).
- Failed verification must be classified before recursion:
  - local implementation defect -> bounded repair/develop retry;
  - missing evidence -> analyze;
  - architectural contradiction/failure -> design or RAGE escalation;
  - unverifiable/unsafe -> blocked.

## RAGE

RAGE is an escalation workflow/tool, not the default response to every failure. Invoke it only through an explicit gate when the failure requires renewed analysis/design. Never recurse without a budget and stop condition.

## Development discipline

Behavioral implementation is TDD-first. Independent verification must not rely on the implementing worker's claim that tests passed. Exact-head evidence wins over worker prose.

## Repository discipline

- Canonical branch: `main`.
- Work on issue/slice branches.
- Keep durable research under `roam/research/` and designs under `roam/design/`.
- Do not commit provider secrets, hidden prompts, raw chain-of-thought, or ephemeral model transcripts.
- Prefer small composable contracts over provider-specific orchestration code.
