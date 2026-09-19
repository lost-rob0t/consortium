:- begin_tests(prolog_rlm_contract).

:- use_module(library(rlm_artifact), []).
:- use_module(library(rlm_async), []).
:- use_module(library(rlm_chain), []).
:- use_module(library(rlm_completion), []).
:- use_module(library(rlm_direct), []).
:- use_module(library(rlm_tool), []).
:- use_module(library(rlm_tool_loader), []).

required_predicate(Module, Name/Arity) :-
    current_predicate(Module:Name/Arity).

test(async_future_contract) :-
    maplist(required_predicate(rlm_async),
            [ rlm_async_runtime_status/1,
              rlm_future_await/2,
              rlm_future_await/3,
              rlm_future_cancel/2,
              rlm_future_destroy/1,
              rlm_future_then/3
            ]).

test(model_execution_contract) :-
    maplist(required_predicate(rlm_chain),
            [ chain_invoke_async/4,
              model_stream_async/4,
              openrouter_provider/2
            ]),
    maplist(required_predicate(rlm_completion),
            [ llm_query_async/3,
              rlm_completion_async/4,
              completion_runtime_budget/2
            ]).

test(authority_and_artifact_contract) :-
    maplist(required_predicate(rlm_direct),
            [ rlm_direct_execute/4
            ]),
    maplist(required_predicate(rlm_tool),
            [ capability_allowed/2,
              capabilities_narrow/3,
              tool_registry_create/1,
              tool_registry_destroy/1,
              tool_discover/2
            ]),
    maplist(required_predicate(rlm_tool_loader),
            [ rlm_tool_catalog/1,
              rlm_load_tools/3
            ]),
    maplist(required_predicate(rlm_artifact),
            [ artifact_store_open/2,
              artifact_put/7,
              artifact_get/3
            ]).

test(current_budget_has_cost_and_time_bounds) :-
    rlm_completion:default_completion_budget(Budget),
    assertion(get_dict(max_total_tokens, Budget, _)),
    assertion(get_dict(max_cost_usd, Budget, _)),
    assertion(get_dict(time_limit, Budget, _)).

:- end_tests(prolog_rlm_contract).
