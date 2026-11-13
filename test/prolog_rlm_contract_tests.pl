:- begin_tests(prolog_rlm_contract).

:- use_module(library(rlm_artifact), []).
:- use_module(library(rlm_async), []).
:- use_module(library(rlm), []).
:- use_module(library(rlm_chain), []).
:- use_module(library(rlm_completion), []).
:- use_module(library(rlm_skill), []).
:- use_module(library(rlm_tool), []).

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
    maplist(required_predicate(rlm_tool),
            [ capability_allowed/2,
              capabilities_narrow/3
            ]),
    maplist(required_predicate(rlm_artifact),
            [ artifact_store_open/2,
              artifact_put/7,
              artifact_get/3
            ]).

test(authority_resolution_contract) :-
    maplist(required_predicate(rlm),
            [ rlm_approve/2,
              rlm_deny/3,
              rlm_pending_approvals/2,
              rlm_pending_resolution_async/2
            ]).

test(skill_catalog_contract) :-
    maplist(required_predicate(rlm_skill),
            [ rlm_skill_ready/0,
              skill_catalog_load/3,
              skill_catalog_merge/3,
              skill_catalog_skills/2,
              skill_catalog_skill/3,
              skill_catalog_prompt_units/3,
              skill_read_resource/3,
              skill_default_catalog/1
            ]).

:- prolog_load_context(directory, TestDirectory),
   asserta(rlm_contract_test_directory(TestDirectory)).

test(skill_catalog_loads_bounded_packages) :-
    rlm_contract_test_directory(TestDirectory),
    directory_file_path(TestDirectory, 'fixtures/skills', Roots0),
    absolute_file_name(Roots0, Roots, [file_type(directory)]),
    rlm_skill:skill_catalog_load([Roots], [], ok(Catalog)),
    rlm_skill:skill_catalog_skills(Catalog, Skills),
    length(Skills, 1),
    Catalog.fingerprint \== "".

test(current_budget_has_cost_and_time_bounds) :-
    rlm_completion:default_completion_budget(Budget),
    assertion(get_dict(max_total_tokens, Budget, _)),
    assertion(get_dict(max_cost_usd, Budget, _)),
    assertion(get_dict(time_limit, Budget, _)).

:- end_tests(prolog_rlm_contract).
