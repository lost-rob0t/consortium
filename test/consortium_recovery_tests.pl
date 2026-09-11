:- begin_tests(consortium_recovery).

:- use_module('../prolog/consortium_agent').

wait_terminal(Queue, Event) :-
    thread_get_message(Queue, Candidate, [timeout(5.0)]),
    (   memberchk(Candidate.type,
                  ['run.completed', 'run.failed', 'run.cancelled'])
    ->  Event = Candidate
    ;   wait_terminal(Queue, Event)
    ).

has_event_type(Events, Type) :-
    member(Event, Events),
    Event.type == Type.

cleanup_state_file(File) :-
    catch(delete_file(File), _, true).

test(running_run_recovers_same_id_with_rotated_attempt_fence) :-
    tmp_file(consortium_recovery, File),
    message_queue_create(FirstQueue),
    message_queue_create(SecondQueue),
    setup_call_cleanup(
        harness_create([store(persist(File)), event_queue(FirstQueue)], First),
        ( start(First,
                "recover in-flight analysis",
                [worker(fake(blocking))],
                RunId),
          First = harness(FirstHarnessId),
          consortium_agent:active_attempt(FirstHarnessId,
                                           RunId,
                                           OldAttemptId,
                                           OldGeneration,
                                           analyze,
                                           _, _, _),
          consortium_agent:harness_abandon(First),

          harness_create([store(persist(File)), event_queue(SecondQueue)], Second),
          setup_call_cleanup(
              true,
              ( status(Second, RunId, Recovered),
                assertion(Recovered.run_id == RunId),
                assertion(Recovered.state == running),
                assertion(Recovered.phase == analyze),
                assertion(Recovered.generation > OldGeneration),

                Second = harness(SecondHarnessId),
                consortium_agent:active_attempt(SecondHarnessId,
                                                 RunId,
                                                 NewAttemptId,
                                                 NewGeneration,
                                                 analyze,
                                                 _, _, _),
                assertion(NewAttemptId \== OldAttemptId),
                assertion(NewGeneration > OldGeneration),

                events(Second, RunId, 0, Replayed),
                assertion(has_event_type(Replayed, 'run.recovered')),
                findall(Sequence,
                        ( member(Event, Replayed),
                          Sequence = Event.sequence ),
                        Sequences),
                last(Sequences, Last),
                numlist(1, Last, Sequences),

                phase_completed(Second,
                                RunId,
                                OldAttemptId,
                                OldGeneration,
                                ok(fake_late_result)),
                status(Second, RunId, StillRunning),
                assertion(StillRunning.state == running),
                events(Second, RunId, 0, AfterStale),
                assertion(has_event_type(AfterStale, 'worker.stale')),
                cancel(Second, RunId, ok(cancelled))
              ),
              harness_destroy(Second))
        ),
        ( catch(consortium_agent:harness_abandon(First), _, true),
          message_queue_destroy(FirstQueue),
          message_queue_destroy(SecondQueue),
          cleanup_state_file(File)
        )).

test(completed_run_remains_queryable_after_restart) :-
    tmp_file(consortium_completed, File),
    message_queue_create(Queue),
    setup_call_cleanup(
        harness_create([store(persist(File)), event_queue(Queue)], First),
        ( start(First,
                "complete before restart",
                [worker(fake(success))],
                RunId),
          wait_terminal(Queue, Terminal),
          assertion(Terminal.type == 'run.completed'),
          status(First, RunId, Before),
          events(First, RunId, 0, BeforeEvents),
          harness_destroy(First),

          harness_create([store(persist(File))], Second),
          setup_call_cleanup(
              true,
              ( status(Second, RunId, After),
                assertion(After.state == complete),
                assertion(After.usage == Before.usage),
                assertion(After.implementation_identity ==
                          Before.implementation_identity),
                events(Second, RunId, 0, AfterEvents),
                assertion(AfterEvents == BeforeEvents),
                once(( member(Created, AfterEvents),
                       Created.type == 'artifact.created',
                       Created.payload.kind == verification )),
                artifact(Second,
                         RunId,
                         Created.payload.artifact_id,
                         Artifact),
                assertion(Artifact.kind == verification)
              ),
              harness_destroy(Second))
        ),
        ( catch(harness_destroy(First), _, true),
          message_queue_destroy(Queue),
          cleanup_state_file(File)
        )).

test(cancelled_run_stays_cancelled_after_restart) :-
    tmp_file(consortium_cancelled, File),
    setup_call_cleanup(
        harness_create([store(persist(File))], First),
        ( start(First,
                "cancel before restart",
                [worker(fake(blocking))],
                RunId),
          cancel(First, RunId, ok(cancelled)),
          harness_destroy(First),
          harness_create([store(persist(File))], Second),
          setup_call_cleanup(
              true,
              ( status(Second, RunId, Status),
                assertion(Status.state == cancelled),
                events(Second, RunId, 0, Events),
                assertion(has_event_type(Events, 'run.cancelled'))
              ),
              harness_destroy(Second))
        ),
        ( catch(harness_destroy(First), _, true),
          cleanup_state_file(File)
        )).

:- end_tests(consortium_recovery).
