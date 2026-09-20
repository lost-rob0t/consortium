# Z.AI / ZCode Coding Plan profile

Tracking: #23

This file records the intended provider-plan contract for the scheduled OpenCode worker. It is **not** a secret store and is not yet an active Consortium config schema.

## Provider facts

OpenCode supports a Z.AI provider and exposes a Z.AI Coding Plan connection option.

Z.AI's current Coding Plan API-key route is the coding-only OpenAI-compatible endpoint:

```text
https://api.z.ai/api/coding/paas/v4
```

The general prepaid/resource-package endpoint is different:

```text
https://api.z.ai/api/paas/v4
```

The scheduled coding worker must not silently switch from Coding Plan quota to general prepaid spending.

Primary references:
- https://opencode.ai/docs/providers
- https://zcode.z.ai/en/docs/configuration
- https://zcode.z.ai/en/docs/usage-stats

## Proposed profile semantics

```toml
[provider_profile]
id = "zai-coding-plan"
worker_backend = "opencode"
provider = "zai"
plan = "coding"
allow_general_api_fallback = false
secret_ref = "external:zai-coding-plan"

[provider_profile.quota]
source = "provider"
track_5_hour = true
track_weekly = true
track_monthly_tools = true
unknown = "unknown"
```

The implementation may change field names to fit the final validated profile schema.

## Secret handling

Store only a secret reference in repository configuration.

Valid runtime approaches include:
- systemd credentials;
- auth-source;
- environment indirection from a host secret manager.

Never commit the API key/token.

## Admission rules

Before a scheduled run:
- confirm the selected provider is the Coding Plan;
- capture quota status if the provider exposes it;
- reject/defer on exhausted quota;
- treat unavailable quota telemetry as unknown rather than inventing a balance;
- do not fall back to general-balance API spend without an explicit separate profile;
- emit the provider/plan/quota observation into durable run metadata.

Do not hard-code plan allowance numbers because Z.AI changes plan tiers and quota rules over time.
