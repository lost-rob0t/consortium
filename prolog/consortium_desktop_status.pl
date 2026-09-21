:- module(consortium_desktop_status,
          [ desktop_status_reset/0,
            desktop_status_event/1
          ]).

:- use_module(library(apply)).
:- use_module(library(filesex)).
:- use_module(library(http/json)).

:- dynamic desktop_runs/1.

max_desktop_runs(16).

desktop_status_reset :-
    with_mutex(consortium_desktop_status,
               ( retractall(desktop_runs(_)),
                 asserta(desktop_runs([])),
                 write_snapshot([])
               )).

desktop_status_event(Event) :-
    is_dict(Event, event),
    get_dict(run_id, Event, RunId),
    get_dict(sequence, Event, Sequence),
    integer(Sequence),
    !,
    with_mutex(consortium_desktop_status,
               ( current_runs(Runs0),
                 project_event(Event, Runs0, Runs),
                 retractall(desktop_runs(_)),
                 asserta(desktop_runs(Runs)),
                 write_snapshot(Runs)
               )).
desktop_status_event(_).

current_runs(Runs) :-
    ( desktop_runs(Runs0) -> Runs = Runs0 ; Runs = [] ).

project_event(Event, Runs0, Runs) :-
    RunId = Event.run_id,
    Sequence = Event.sequence,
    ( latest_sequence(RunId, Runs0, ExistingSequence),
      ExistingSequence >= Sequence
    -> Runs = Runs0
    ; event_entry(Event, Entry),
      exclude(run_matches(RunId), Runs0, Rest),
      max_desktop_runs(Max),
      take(Max, [Entry|Rest], Runs)
    ).

latest_sequence(RunId, Runs, Sequence) :-
    member(Entry, Runs),
    get_dict(run_id, Entry, ExistingRunId),
    ExistingRunId == RunId,
    get_dict(sequence, Entry, Sequence),
    !.

run_matches(RunId, Entry) :-
    get_dict(run_id, Entry, ExistingRunId),
    ExistingRunId == RunId.

take(0, _, []) :- !.
take(_, [], []) :- !.
take(N, [Head|Tail], [Head|Rest]) :-
    N > 0,
    Next is N - 1,
    take(Next, Tail, Rest).

event_entry(Event, Entry) :-
    Type = Event.type,
    event_state(Type, State),
    optional_value(Event, phase, Phase),
    optional_value(Event, worker, Worker),
    Entry = _{ run_id:Event.run_id,
               sequence:Event.sequence,
               state:State,
               phase:Phase,
               worker:Worker,
               event_type:Type,
               updated_at:Event.timestamp
             }.

optional_value(Dict, Key, Value) :-
    ( get_dict(Key, Dict, Found) -> Value = Found ; Value = @(null) ).

event_state('run.completed', completed) :- !.
event_state('run.failed', failed) :- !.
event_state('run.cancelled', cancelled) :- !.
event_state(_, running).

active_entry(Entry) :-
    Entry.state == running.

write_snapshot(Runs) :-
    include(active_entry, Runs, Active),
    length(Active, ActiveCount),
    Snapshot = _{schema_version:1,
                 active_count:ActiveCount,
                 runs:Runs},
    desktop_status_file(File),
    file_directory_name(File, Directory),
    make_directory_path(Directory),
    current_prolog_flag(pid, Pid),
    format(atom(Temp), '~w.tmp.~w', [File, Pid]),
    setup_call_cleanup(
        open(Temp, write, Stream, [encoding(utf8)]),
        ( json_write_dict(Stream, Snapshot, [width(0)]),
          nl(Stream),
          flush_output(Stream)
        ),
        close(Stream)),
    rename_file(Temp, File).

desktop_status_file(File) :-
    getenv('CONSORTIUM_QTILE_STATUS_FILE', Override),
    Override \== '',
    !,
    File = Override.
desktop_status_file(File) :-
    state_home(StateHome),
    directory_file_path(StateHome, consortium, Directory),
    directory_file_path(Directory, 'qtile-status.json', File).

state_home(StateHome) :-
    getenv('XDG_STATE_HOME', Value),
    Value \== '',
    !,
    StateHome = Value.
state_home(StateHome) :-
    expand_file_name('~/.local/state', [StateHome]).
