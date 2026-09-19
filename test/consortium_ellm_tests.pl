:- begin_tests(consortium_ellm).

:- use_module('../prolog/consortium_protocol', []).
:- use_module('../prolog/consortium_models', []).
:- use_module(library(rlm_tool), []).
:- use_module(library(rlm_tool_loader), []).

:- multifile rlm_tool_loader:tool_pack/2.
:- multifile rlm_tool_loader:tool_pack_manifest/2.

rlm_tool_loader:tool_pack(
    consortium_ellm_fixture,
    plunit_consortium_ellm:load_fixture_pack).

rlm_tool_loader:tool_pack_manifest(
    consortium_ellm_fixture,
    tool_pack_manifest{
        library:consortium_tests,
        category:consortium_fixture,
        tools:[tool_export{
                   name:fixture_read,
                   capability:tool(fixture_read),
                   effect:read
               }]
    }).

load_fixture_pack(Registry, Outcome) :-
    Schema = tool_schema{
                 name:fixture_read,
                 description:"deterministic ELLM bridge fixture",
                 capability:tool(fixture_read),
                 effect:read,
                 arguments:_{
                     type:object,
                     required:[],
                     additional_properties:false,
                     properties:_{}
                 },
                 result:_{type:any},
                 limits:_{time_limit:1.0, max_output_bytes:1024}
             },
    rlm_tool:tool_register(
        Registry,
        Schema,
        plunit_consortium_ellm:fixture_read,
        Outcome).

fixture_read(_, _{ok:true}).

ellm_models(
    json{
        root_agent:"openai/gpt-oss-120b",
        analyze:"openai/gpt-oss-120b",
        design:"openai/gpt-oss-120b",
        adversarial_review:"openai/gpt-oss-120b",
        resolve:"openai/gpt-oss-120b",
        develop:"openai/gpt-oss-120b",
        verify:"openai/gpt-oss-120b"
    }).

test(protocol_compiles_ellm_worker_to_completion_and_capabilities) :-
    ellm_models(Models),
    consortium_protocol:protocol_options(
        json{
            worker:"ellm",
            provider:"openrouter",
            models:Models,
            skills:["simple-output"],
            tools:["fixture_read"]
        },
        Options),
    once(member(worker(completion(CompletionOptions)), Options)),
    assertion(memberchk(explicit_skills(['simple-output']), CompletionOptions)),
    assertion(memberchk(ellm_tools([fixture_read]), CompletionOptions)),
    once(member(capabilities(Capabilities), Options)),
    assertion(memberchk(rlm, Capabilities)),
    assertion(memberchk(model(openrouter), Capabilities)),
    assertion(memberchk(tool(fixture_read), Capabilities)),
    assertion(memberchk(phase_capabilities(Capabilities), Options)).

test(protocol_rejects_non_list_ellm_tools,
     [throws(error(type_error(list, _), _))]) :-
    ellm_models(Models),
    consortium_protocol:protocol_options(
        json{
            worker:"ellm",
            provider:"openrouter",
            models:Models,
            tools:"fixture_read"
        },
        _).

test(tool_registry_resolves_requested_tool_through_trusted_manifest) :-
    consortium_models:completion_tool_registry(
        [fixture_read],
        Registry),
    setup_call_cleanup(
        true,
        ( rlm_tool:tool_discover(Registry, Schemas),
          assertion(member(Schema, Schemas)),
          assertion(Schema.name == fixture_read),
          assertion(Schema.capability == tool(fixture_read))
        ),
        rlm_tool:tool_registry_destroy(Registry)).

test(tool_registry_rejects_unknown_requested_tool,
     [throws(error(consortium_error(unknown_ellm_tool(missing_tool)), _))]) :-
    consortium_models:completion_tool_registry(
        [missing_tool],
        _).

:- end_tests(consortium_ellm).
