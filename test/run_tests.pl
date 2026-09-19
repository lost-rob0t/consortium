:- initialization(main, main).

:- prolog_load_context(directory, TestDirectory),
   asserta(user:file_search_path(consortium_test, TestDirectory)).

:- use_module(library(rlm_async)).

main(_) :-
    rlm_async_runtime_status(_),
    load_files([consortium_test('prolog_rlm_contract_tests.pl'),
                consortium_test('adard_state_tests.pl'),
                consortium_test('consortium_agent_tests.pl'),
                consortium_test('consortium_protocol_tests.pl'),
                consortium_test('consortium_ellm_tests.pl')],
               [if(changed)]),
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
