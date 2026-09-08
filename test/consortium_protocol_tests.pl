:- begin_tests(consortium_protocol).

:- use_module(library(http/json)).
:- use_module(library(process)).
:- use_module('../prolog/consortium_protocol', []).

:- prolog_load_context(directory, TestDirectory),
   asserta(protocol_test_directory(TestDirectory)).

consortium_entrypoint(Path) :-
    protocol_test_directory(TestDirectory),
    directory_file_path(TestDirectory, '..', Root0),
    absolute_file_name(Root0, Root),
    directory_file_path(Root, 'bin/consortium.pl', Path).

send_request(Stream, Dict) :-
    json_write_dict(Stream, Dict, [width(0)]),
    nl(Stream),
    flush_output(Stream).

read_response(Stream, Id, Seen0, Response, Seen) :-
    json_read_dict(Stream, Message),
    (   Message.get(kind) == "response",
        Message.get(id) == Id
    ->  Response = Message,
        Seen = Seen0
    ;   read_response(Stream, Id, [Message|Seen0], Response, Seen)
    ).

has_event(Type, Messages) :-
    member(Message, Messages),
    Message.get(kind) == "event",
    Message.event.type == Type.

start_daemon(Input, Output, Error, Pid) :-
    consortium_entrypoint(Script),
    process_create(path(swipl),
                   ['-q', '-s', Script, '--', daemon, '--memory'],
                   [ stdin(pipe(Input)),
                     stdout(pipe(Output)),
                     stderr(pipe(Error)),
                     process(Pid)
                   ]),
    set_stream(Output, timeout(5)).

stop_daemon(Input, Output, Error, Pid) :-
    close(Input, [force(true)]),
    close(Output, [force(true)]),
    close(Error, [force(true)]),
    catch(process_wait(Pid, _, [timeout(5)]), _, true).

test(emacs_style_client_remains_responsive_and_cancels) :-
    start_daemon(Input, Output, Error, Pid),
    setup_call_cleanup(
        true,
        ( send_request(Input,
                       _{id:1,
                         method:"start",
                         params:_{task:"protocol task",
                                  options:_{worker:"blocking"}}}),
          read_response(Output, 1, [], StartResponse, StartMessages),
          assertion(StartResponse.ok == true),
          RunId = StartResponse.result.run_id,
          assertion(string(RunId)),
          send_request(Input,
                       _{id:2,
                         method:"status",
                         params:_{run_id:RunId}}),
          read_response(Output, 2, StartMessages, StatusResponse, StatusMessages),
          assertion(StatusResponse.result.state == "running"),
          assertion(has_event("phase.started", StatusMessages)),
          send_request(Input,
                       _{id:3,
                         method:"cancel",
                         params:_{run_id:RunId}}),
          read_response(Output, 3, StatusMessages, CancelResponse, CancelMessages),
          assertion(CancelResponse.ok == true),
          send_request(Input,
                       _{id:4,
                         method:"status",
                         params:_{run_id:RunId}}),
          read_response(Output, 4, CancelMessages, FinalStatus, FinalMessages),
          assertion(FinalStatus.result.state == "cancelled"),
          assertion(has_event("run.cancelled", FinalMessages)),
          send_request(Input,
                       _{id:5, method:"shutdown", params:_{}}),
          read_response(Output, 5, FinalMessages, Shutdown, _),
          assertion(Shutdown.ok == true)
        ),
        stop_daemon(Input, Output, Error, Pid)).

test(malformed_request_does_not_terminate_daemon) :-
    start_daemon(Input, Output, Error, Pid),
    setup_call_cleanup(
        true,
        ( format(Input, '{~n', []),
          flush_output(Input),
          json_read_dict(Output, ErrorResponse),
          assertion(ErrorResponse.ok == false),
          send_request(Input,
                       _{id:2, method:"shutdown", params:_{}}),
          read_response(Output, 2, [], Shutdown, _),
          assertion(Shutdown.ok == true)
        ),
        stop_daemon(Input, Output, Error, Pid)).

test(valid_json_with_invalid_params_returns_error_and_stays_alive) :-
    start_daemon(Input, Output, Error, Pid),
    setup_call_cleanup(
        true,
        ( send_request(Input,
                       _{id:1, method:"status", params:[]}),
          read_response(Output, 1, [], Invalid, _),
          assertion(Invalid.ok == false),
          send_request(Input,
                       _{id:2, method:"shutdown", params:_{}}),
          read_response(Output, 2, [], Shutdown, _),
          assertion(Shutdown.ok == true)
        ),
        stop_daemon(Input, Output, Error, Pid)).

test(openrouter_role_routes_are_available_without_hardcoded_test_provider) :-
    Models = json{root_agent:"openai/gpt-oss-120b",
                  analyze:"openai/gpt-oss-120b",
                  design:"openai/gpt-oss-120b",
                  adversarial_review:"openai/gpt-oss-120b",
                  resolve:"openai/gpt-oss-120b",
                  develop:"openai/gpt-oss-120b",
                  verify:"openai/gpt-oss-120b"},
    consortium_protocol:protocol_options(
        json{worker:"rlm", provider:"openrouter", models:Models},
        Options),
    assertion(memberchk(worker(rlm), Options)),
    assertion(memberchk(capabilities([model(openrouter)]), Options)),
    once(member(models(Routes), Options)),
    assertion(Routes.verify.provider_name == openrouter),
    assertion(Routes.verify.model == "openai/gpt-oss-120b").

test(json_option_objects_are_grounded_at_protocol_boundary) :-
    Line = "{\"id\":1,\"method\":\"start\",\"params\":{\"task\":\"protocol task\",\"options\":{\"worker\":\"rlm\",\"provider\":\"openrouter\",\"models\":{\"root_agent\":\"openai/gpt-oss-120b\",\"analyze\":\"openai/gpt-oss-120b\",\"design\":\"openai/gpt-oss-120b\",\"adversarial_review\":\"openai/gpt-oss-120b\",\"resolve\":\"openai/gpt-oss-120b\",\"develop\":\"openai/gpt-oss-120b\",\"verify\":\"openai/gpt-oss-120b\"},\"budget\":{\"max_total_tokens\":24000,\"max_cost_usd\":2.0,\"time_limit\":300.0},\"phase_budget\":{\"max_total_tokens\":4000,\"max_cost_usd\":0.5,\"time_limit\":60.0},\"repository\":{\"kind\":\"fixture\",\"value\":\"consortium-live-contract-v1\"}}}}",
    consortium_protocol:parse_request(Line, Request),
    get_dict(params, Request, Params),
    get_dict(options, Params, OptionDict),
    consortium_protocol:protocol_options(OptionDict, Options),
    once(member(repository(Repository), Options)),
    once(member(budget(Budget), Options)),
    assertion(ground(Repository)),
    assertion(ground(Budget)).

test(unsubscribe_stops_push_until_resubscribed) :-
    start_daemon(Input, Output, Error, Pid),
    setup_call_cleanup(
        true,
        ( send_request(Input,
                       _{id:1, method:"unsubscribe", params:_{}}),
          read_response(Output, 1, [], Unsubscribed, _),
          assertion(Unsubscribed.result.subscribed == false),
          send_request(Input,
                       _{id:2,
                         method:"start",
                         params:_{task:"quiet protocol task",
                                  options:_{worker:"blocking"}}}),
          read_response(Output, 2, [], Started, QuietMessages),
          assertion(QuietMessages == []),
          RunId = Started.result.run_id,
          send_request(Input,
                       _{id:3, method:"subscribe", params:_{}}),
          read_response(Output, 3, [], Subscribed, _),
          assertion(Subscribed.result.subscribed == true),
          send_request(Input,
                       _{id:4,
                         method:"cancel",
                         params:_{run_id:RunId}}),
          read_response(Output, 4, [], Cancelled, CancelMessages),
          assertion(Cancelled.ok == true),
          assertion(has_event("run.cancelled", CancelMessages)),
          send_request(Input,
                       _{id:5, method:"shutdown", params:_{}}),
          read_response(Output, 5, [], _, _)
        ),
        stop_daemon(Input, Output, Error, Pid)).

:- end_tests(consortium_protocol).
