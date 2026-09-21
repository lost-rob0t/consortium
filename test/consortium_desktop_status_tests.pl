:- begin_tests(consortium_desktop_status).

:- use_module(library(filesex)).
:- use_module(library(http/json)).
:- use_module('../prolog/consortium_desktop_status').

:- dynamic saved_status_environment/1.

status_test_setup(File) :-
    retractall(saved_status_environment(_)),
    ( getenv('CONSORTIUM_QTILE_STATUS_FILE', Old)
    -> asserta(saved_status_environment(value(Old)))
    ;  asserta(saved_status_environment(unset))
    ),
    tmp_file(consortium_qtile_status, File),
    setenv('CONSORTIUM_QTILE_STATUS_FILE', File).

status_test_cleanup(File) :-
    catch(delete_file(File), _, true),
    format(atom(TempPattern), '~w.tmp.*', [File]),
    expand_file_name(TempPattern, Temps),
    maplist(delete_if_present, Temps),
    ( retract(saved_status_environment(value(Old)))
    -> setenv('CONSORTIUM_QTILE_STATUS_FILE', Old)
    ; retractall(saved_status_environment(_)),
      unsetenv('CONSORTIUM_QTILE_STATUS_FILE')
    ).

delete_if_present(File) :-
    catch(delete_file(File), _, true).

read_snapshot(File, Snapshot) :-
    setup_call_cleanup(
        open(File, read, Stream, [encoding(utf8)]),
        json_read_dict(Stream, Snapshot),
        close(Stream)).

event(Sequence, Type, Phase, Worker, Event) :-
    Event = event{run_id:'run-1',
                  sequence:Sequence,
                  event_id:'event-1',
                  timestamp:"2026-09-21T03:00:00Z",
                  type:Type,
                  phase:Phase,
                  worker:Worker,
                  payload:_{}}.

test(projection_is_bounded_read_only_runtime_summary,
     [ setup(status_test_setup(File)),
       cleanup(status_test_cleanup(File))
     ]) :-
    desktop_status_reset,
    read_snapshot(File, Empty),
    assertion(Empty.schema_version == 1),
    assertion(Empty.active_count == 0),
    assertion(Empty.runs == []),

    event(1, 'run.started', analyze, none, Started),
    desktop_status_event(Started),
    read_snapshot(File, Running),
    assertion(Running.active_count == 1),
    [Run] = Running.runs,
    assertion(Run.run_id == "run-1"),
    assertion(Run.sequence == 1),
    assertion(Run.state == "running"),
    assertion(Run.phase == "analyze"),

    event(2, 'run.completed', verify, none, Completed),
    desktop_status_event(Completed),
    read_snapshot(File, Done),
    assertion(Done.active_count == 0),
    [Final] = Done.runs,
    assertion(Final.sequence == 2),
    assertion(Final.state == "completed"),
    assertion(Final.event_type == "run.completed"),

    desktop_status_event(Started),
    read_snapshot(File, StillDone),
    [StillFinal] = StillDone.runs,
    assertion(StillFinal.sequence == 2),
    assertion(StillFinal.state == "completed").

test(projection_keeps_only_recent_runs,
     [ setup(status_test_setup(File)),
       cleanup(status_test_cleanup(File))
     ]) :-
    desktop_status_reset,
    forall(between(1, 20, Index),
           ( format(atom(RunId), 'run-~d', [Index]),
             format(atom(EventId), 'event-~d', [Index]),
             Event = event{run_id:RunId,
                           sequence:1,
                           event_id:EventId,
                           timestamp:"2026-09-21T03:00:00Z",
                           type:'run.started',
                           phase:analyze,
                           worker:none,
                           payload:_{}},
             desktop_status_event(Event)
           )),
    read_snapshot(File, Snapshot),
    length(Snapshot.runs, 16),
    assertion(Snapshot.active_count == 16),
    Snapshot.runs = [Newest|_],
    assertion(Newest.run_id == "run-20").

:- end_tests(consortium_desktop_status).
