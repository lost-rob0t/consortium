import json
import pathlib
import tomllib

import jsonschema


ROOT = pathlib.Path(__file__).resolve().parent.parent

schemas = {}
for schema_name in ("adard-run.schema.json", "consortium-event.schema.json"):
    with (ROOT / "schema" / schema_name).open(encoding="utf-8") as stream:
        schema = json.load(stream)
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    jsonschema.Draft202012Validator.check_schema(schema)
    schemas[schema_name] = schema

with (ROOT / "test" / "fixtures" / "run-status.json").open(
    encoding="utf-8"
) as stream:
    jsonschema.validate(json.load(stream), schemas["adard-run.schema.json"])

with (ROOT / "test" / "fixtures" / "event.json").open(encoding="utf-8") as stream:
    jsonschema.validate(json.load(stream), schemas["consortium-event.schema.json"])

with (ROOT / "consortium.toml").open("rb") as stream:
    config = tomllib.load(stream)

assert config["control_plane"]["runtime"] == "prolog-rlm"
assert config["control_plane"]["fresh_context_per_phase"] is True
assert config["control_plane"]["hidden_transcript_transfer"] is False
assert config["control_plane"]["async_boundary"] is True
assert config["rage"]["mode"] == "tool"
assert config["rage"]["auto_escalate_local_failures"] is False
assert config["events"] == {
    "schema": "consortium.event.v1",
    "push": True,
    "replay": True,
}
assert set(config["models"]) == {
    "provider",
    "root-agent",
    "analyze",
    "design",
    "adversarial_review",
    "resolve",
    "develop",
    "verify",
    "codex",
}

# The default route is z.ai via OpenRouter; the codex sub-table documents
# the OpenAI-compatible alternative. Neither carries secrets.
assert config["models"]["provider"] == "openrouter"
codex = config["models"]["codex"]
assert codex["provider"] == "codex"
assert codex["credential-env"] == "OPENAI_API_KEY"
assert codex["endpoint"].startswith("https://")
for role in (
    "root-agent",
    "analyze",
    "design",
    "adversarial_review",
    "resolve",
    "develop",
    "verify",
):
    assert isinstance(config["models"][role], str) and config["models"][role]
    assert isinstance(codex[role], str) and codex[role]
