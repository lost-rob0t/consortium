/** <module> Machine gates for elisp->Prolog DSL generated artifacts

The ERT suite pins that the elisp encoders reproduce these checked-in
fixtures byte-for-byte; this suite proves the very same artifacts are
valid runtime inputs: expert knowledge consults clean and queries, and
the generated skill catalog loads through the pinned rlm_skill loader.
*/

:- begin_tests(consortium_dsl).

:- use_module(library(rlm_skill), [skill_catalog_load/3]).

:- prolog_load_context(directory, TestDirectory),
   asserta(dsl_test_directory(TestDirectory)).

test(expert_knowledge_consults_and_queries) :-
    dsl_test_directory(Dir),
    directory_file_path(Dir, 'fixtures/dsl/demo-experts.pl', ExpertFile),
    consult(ExpertFile),
    consortium_expert('dsl-reviewer', Spec),
    Spec.role == review,
    memberchk(grill, Spec.skills),
    memberchk('cite file:line evidence', Spec.constraints).

test(dsl_skill_catalog_loads) :-
    dsl_test_directory(Dir),
    directory_file_path(Dir, 'fixtures/dsl/skills', Root0),
    absolute_file_name(Root0, Root, [file_type(directory)]),
    skill_catalog_load([Root], [], ok(Catalog)),
    assertion(length(Catalog.skills, 1)),
    assertion(atom(Catalog.fingerprint)).

:- end_tests(consortium_dsl).
