:- module(consortium_protocol,
          [ main/1,
            daemon/1,
            push_event/1
          ]).

:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- use_module(library(readutil)).
:- use_module(library(rlm_chain), [openrouter_provider/2]).
:- use_module(consortium_agent).

:- dynamic protocol_output_queue/1.
:- dynamic protocol_harness/1.
:- dynamic protocol_subscribed/1.

main(Args) :-
    (   memberchk('--help', Args)
    ->  print_help
    ;   Args = [daemon|DaemonArgs]
    ->  daemon(DaemonArgs)
    ;   Args == []
    ->  daemon([])
    ;   format(user_error, 'Unknown command. Use --help.~n', []),
        halt(2)
    ).

print_help :-
    format('Usage: consortium [daemon] [--memory | --state-dir DIR]~n'),
    format('Persistent JSON Lines methods: start, status, events, artifact, cancel, subscribe, unsubscribe, shutdown.~n').

daemon(Args) :-
    store_from_args(Args, Store),
    retractall(protocol_output_queue(_)),
    retractall(protocol_subscribed(_)),
    asserta(protocol_subscribed(true)),
    message_queue_create(OutputQueue),
    asserta(protocol_output_queue(OutputQueue)),
    thread_create(consortium_protocol:protocol_writer_loop(OutputQueue),
                  Writer,
                  []),
    harness_create([store(Store), event_queue(OutputQueue)],
                   Harness),
    asserta(protocol_harness(Harness)),
    setup_call_cleanup(
        true,
        protocol_loop(Harness),
        ( retractall(protocol_harness(_)),
          harness_destroy(Harness),
          thread_send_message(OutputQueue, stop),
          catch(thread_join(Writer, _), _, true),
          retractall(protocol_output_queue(_)),
          retractall(protocol_subscribed(_)),
          catch(message_queue_destroy(OutputQueue), _, true)
        )).

protocol_writer_loop(Queue) :-
    thread_get_message(Queue, Item),
    (   Item == stop
    ->  true
    ;   (   protocol_output_item(Item, Message)
        ->  (   catch(write_protocol_now(Message), _, fail)
            ->  protocol_writer_loop(Queue)
            ;   true
            )
        ;   protocol_writer_loop(Queue)
        )
    ).

protocol_output_item(output(Message), Message) :- !.
protocol_output_item(Event0, _{kind:"event", event:Event}) :-
    is_dict(Event0, event),
    protocol_subscribed(true),
    !,
    portable_json(Event0, Event).

store_from_args(Args, memory) :-
    memberchk('--memory', Args),
    !.
store_from_args(Args, persist(File)) :-
    append(_, ['--state-dir', Directory0|_], Args),
    !,
    atom_string(Directory, Directory0),
    make_directory_path(Directory),
    directory_file_path(Directory, 'artifacts.db', File).
store_from_args(_, persist(File)) :-
    state_home(StateHome),
    directory_file_path(StateHome, consortium, Directory),
    make_directory_path(Directory),
    directory_file_path(Directory, 'artifacts.db', File).

state_home(StateHome) :-
    getenv('XDG_STATE_HOME', Value),
    Value \== '',
    !,
    StateHome = Value.
state_home(StateHome) :-
    expand_file_name('~/.local/state', [StateHome]).

protocol_loop(Harness) :-
    read_line_to_string(user_input, Line),
    (   Line == end_of_file
    ->  true
    ;   Line == ""
    ->  protocol_loop(Harness)
    ;   handle_line(Harness, Line, Continue),
        ( Continue == true -> protocol_loop(Harness) ; true )
    ).

handle_line(Harness, Line, Continue) :-
    (   catch(parse_request(Line, Request),
              Exception,
              ( write_exception(none, Exception), fail ))
    ->  request_id(Request, Id),
        (   catch(( dispatch(Harness, Request, Result, DispatchContinue)
                  -> true
                  ;  throw(error(consortium_error(request_failed),
                                 context(consortium_protocol,
                                         'request validation failed')))
                  ),
                  Exception,
                  ( write_exception(Id, Exception), fail ))
        ->  write_response(Id, true, Result),
            ( DispatchContinue == stop -> Continue = false ; Continue = true )
        ;   Continue = true
        )
    ;   Continue = true
    ).

parse_request(Line, Request) :-
    atom_json_dict(Line, Request0, [tag(json)]),
    (   is_dict(Request0)
    ->  Request = Request0
    ;   throw(error(type_error(json_object, Request0),
                    context(consortium_protocol,
                            'each protocol line must be a JSON object')))
    ).

request_id(Request, Id) :-
    ( get_dict(id, Request, Id0) -> Id = Id0 ; Id = none ).

dispatch(Harness, Request, Result, Continue) :-
    Method = Request.method,
    ( get_dict(params, Request, Params) -> true ; Params = json{} ),
    (   is_dict(Params)
    ->  true
    ;   throw(error(type_error(json_object, Params),
                    context(consortium_protocol,
                            'request params must be a JSON object')))
    ),
    dispatch_method(Method, Harness, Params, Result, Continue).

dispatch_method("start", Harness, Params, _{run_id:RunId}, true) :-
    ( get_dict(options, Params, OptionDict) -> true ; OptionDict = json{} ),
    protocol_options(OptionDict, Options),
    start(Harness, Params.task, Options, RunId).
dispatch_method("status", Harness, Params, Status, true) :-
    run_atom(Params.run_id, RunId),
    status(Harness, RunId, Status).
dispatch_method("events", Harness, Params, _{events:Events}, true) :-
    run_atom(Params.run_id, RunId),
    ( get_dict(since, Params, Since) -> true ; Since = 0 ),
    events(Harness, RunId, Since, Events).
dispatch_method("artifact", Harness, Params, Artifact, true) :-
    run_atom(Params.run_id, RunId),
    run_atom(Params.artifact_id, ArtifactId),
    artifact(Harness, RunId, ArtifactId, Artifact).
dispatch_method("cancel", Harness, Params, Result, true) :-
    run_atom(Params.run_id, RunId),
    cancel(Harness, RunId, Outcome),
    cancellation_json(Outcome, Result).
dispatch_method("subscribe", _, _, _{subscribed:true}, true) :-
    retractall(protocol_subscribed(_)),
    asserta(protocol_subscribed(true)).
dispatch_method("unsubscribe", _, _, _{subscribed:false}, true) :-
    retractall(protocol_subscribed(_)),
    asserta(protocol_subscribed(false)).
dispatch_method("shutdown", _, _, _{shutdown:true}, stop).
dispatch_method(Method, _, _, _, _) :-
    throw(error(existence_error(consortium_method, Method),
                context(consortium_protocol, 'unknown protocol method'))).

protocol_options(Dict, Options) :-
    (   is_dict(Dict)
    ->  protocol_ground(Dict, GroundDict),
        protocol_execution_options(GroundDict, ExecutionOptions),
        protocol_policy_options(GroundDict, PolicyOptions),
        append(ExecutionOptions, PolicyOptions, Options)
    ;   Options = [worker(fake(success))]
    ).

protocol_ground(Value, Ground) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs0),
    maplist(protocol_ground_pair, Pairs0, Pairs),
    dict_pairs(Ground, json, Pairs).
protocol_ground(Value, Ground) :-
    is_list(Value),
    !,
    maplist(protocol_ground, Value, Ground).
protocol_ground(Value, Value).

protocol_ground_pair(Key-Value0, Key-Value) :-
    protocol_ground(Value0, Value).

protocol_execution_options(Dict, Options) :-
    get_dict(worker, Dict, "rlm"),
    !,
    get_dict(provider, Dict, "openrouter"),
    get_dict(models, Dict, ModelDict),
    openrouter_model_routes(ModelDict, Models),
    Options = [ worker(rlm),
                models(Models),
                capabilities([model(openrouter)]),
                phase_capabilities([model(openrouter)])
              ].
protocol_execution_options(Dict, [worker(Worker)]) :-
    protocol_worker(Dict, Worker).

protocol_policy_options(Dict, Options) :-
    findall(Option,
            ( member(Key,
                     [budget, phase_budget, max_repairs, max_rage_cycles,
                      repository, artifact_refs, fact_refs, evidence,
                      constraints, acceptance_criteria]),
              optional_option(Key, Dict, [Option])
            ),
            Options).

openrouter_model_routes(ModelDict, Models) :-
    is_dict(ModelDict),
    maplist(openrouter_role_route(ModelDict),
            [root_agent, analyze, design, adversarial_review,
             resolve, develop, verify],
            Routes),
    Routes = [Root, Analyze, Design, Adversarial, Resolve, Develop, Verify],
    Models = models{root_agent:Root,
                    analyze:Analyze,
                    design:Design,
                    adversarial_review:Adversarial,
                    resolve:Resolve,
                    develop:Develop,
                    verify:Verify}.

openrouter_role_route(ModelDict, Role, Route) :-
    get_dict(Role, ModelDict, Model),
    openrouter_provider(Model, Provider),
    Route = model_route{provider:Provider,
                        provider_name:openrouter,
                        model:Model}.

protocol_worker(Dict, fake(blocking)) :-
    get_dict(worker, Dict, "blocking"),
    !.
protocol_worker(Dict, fake(success)) :-
    get_dict(worker, Dict, "fake"),
    !.
protocol_worker(_, unconfigured).

optional_option(Key, Dict, [Option]) :-
    get_dict(Key, Dict, Value),
    !,
    Option =.. [Key, Value].
optional_option(_, _, []).

cancellation_json(ok(cancelled), _{status:"cancelled"}).
cancellation_json(ok(already_terminal), _{status:"already_terminal"}).

run_atom(String, Atom) :-
    ( string(String) -> atom_string(Atom, String) ; Atom = String ).

request_exception(Id, Exception, error(Error)) :-
    message_to_string(Exception, Message),
    Error = _{kind:"request_error", message:Message, request_id:Id}.

write_exception(Id, Exception) :-
    request_exception(Id, Exception, error(Error)),
    write_response(Id, false, Error).

write_response(Id, Ok, Value0) :-
    portable_json(Value0, Value),
    (   Ok == true
    ->  Message = _{kind:"response", id:Id, ok:true, result:Value}
    ;   Message = _{kind:"response", id:Id, ok:false, error:Value}
    ),
    write_protocol(Message).

push_event(Event0) :-
    protocol_output_queue(Queue),
    thread_send_message(Queue, Event0).

write_protocol(Message) :-
    protocol_output_queue(Queue),
    thread_send_message(Queue, output(Message)).

write_protocol_now(Message) :-
    json_write_dict(current_output, Message, [width(0)]),
    nl(current_output),
    flush_output(current_output).

portable_json(Value, Json) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    maplist(portable_pair, Pairs, JsonPairs),
    dict_pairs(Json, json, JsonPairs).
portable_json(Value, Json) :-
    is_list(Value),
    !,
    maplist(portable_json, Value, Json).
portable_json(Value, Value) :-
    atomic(Value),
    !.
portable_json(Value, Json) :-
    term_string(Value, Json, [quoted(true)]).

portable_pair(Key-Value, Key-Json) :-
    portable_json(Value, Json).
