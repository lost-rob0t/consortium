;;; consortium-rlm-tests.el --- ERT tests for the Emacs RLM workbench -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Deterministic ERT coverage for the prolog_agent_ui_v1 client:
;; framing, codec, canonical reducer, and sequence discipline.
;; Upstream prolog-rlm golden fixture conformance lives in
;; consortium-rlm-conformance.el.

;;; Code:

(require 'ert)
(require 'consortium-rlm-client)
(require 'consortium-rlm-process)

(defconst consortium-rlm-tests--protocol "prolog_agent_ui_v1")

;;; Helpers ------------------------------------------------------------

(defun consortium-rlm-tests--decode (line)
  "Decode LINE into an ok/error outcome plist."
  (consortium-rlm-client-decode-line line))

(defun consortium-rlm-tests--snapshot-frame ()
  "A minimal valid snapshot frame as an alist.
COPY-ALIST guards against destructive tests mutating shared literal
structure (backquoted/quoted sublists are constants)."
  (copy-tree
   '((protocol . "prolog_agent_ui_v1")
     (kind . "snapshot")
     (session_id . "session_1")
     (snapshot_id . "snapshot_0")
     (at_seq . 0)
     (state . ((status . "idle")
               (run . nil)
               (messages . [])
               (tools . [])
               (approvals . [])
               (questions . [])
               (subagents . [])
               (verification . [])
               (usage . nil)
               (traces . [])
               (indeterminate_effects . [])
               (extensions . []))))))

(defun consortium-rlm-tests--view ()
  "Canonical view from the minimal snapshot."
  (let ((outcome (consortium-rlm-client-apply-snapshot
                  (consortium-rlm-client-initial-view "session_1")
                  (consortium-rlm-tests--snapshot-frame))))
    (should (plist-get outcome :ok))
    (plist-get outcome :ok)))

(defun consortium-rlm-tests--event-frame (seq event-type payload)
  "Build a validated event frame alist with SEQ, EVENT-TYPE and PAYLOAD."
  `((protocol . "prolog_agent_ui_v1")
    (kind . "event")
    (session_id . "session_1")
    (seq . ,seq)
    (event_id . ,(format "evt_%d" seq))
    (event_type . ,event-type)
    (payload . ,payload)))

(defun consortium-rlm-tests--apply (view seq event-type payload)
  "Apply one event to VIEW and return the outcome plist."
  (consortium-rlm-client-apply-event
   view (consortium-rlm-tests--event-frame seq event-type payload)))

(defun consortium-rlm-tests--apply! (view seq event-type payload)
  "Like `consortium-rlm-tests--apply' but assert success."
  (let ((outcome (consortium-rlm-tests--apply view seq event-type payload)))
    (should (plist-get outcome :ok))
    (plist-get outcome :ok)))

(defun consortium-rlm-tests--messages (view)
  "Messages of VIEW as a list of alists."
  (plist-get view :messages))

;;; Codec: NDJSON line decoding ----------------------------------------

(ert-deftest consortium-rlm-decode-line-valid-command ()
  (let ((line "{\"protocol\":\"prolog_agent_ui_v1\",\"kind\":\"command\",\"session_id\":\"s1\",\"request_id\":\"req_1\",\"command\":\"session.cancel\",\"payload\":{}}"))
    (let ((outcome (consortium-rlm-tests--decode line)))
      (should (plist-get outcome :ok))
      (should (equal "command" (alist-get 'kind (plist-get outcome :ok)))))))

(ert-deftest consortium-rlm-decode-line-malformed-json ()
  (let ((outcome (consortium-rlm-tests--decode "{\"protocol\":")))
    (should-not (plist-get outcome :ok))
    (should (equal "ndjson_codec_error" (plist-get (plist-get outcome :error) :code)))))

(ert-deftest consortium-rlm-decode-line-wrong-protocol ()
  (let ((line "{\"protocol\":\"some_other_v9\",\"kind\":\"command\",\"session_id\":\"s1\",\"request_id\":\"req_1\",\"command\":\"x\",\"payload\":{}}"))
    (let ((outcome (consortium-rlm-tests--decode line)))
      (should-not (plist-get outcome :ok))
      (should (equal "invalid_field" (plist-get (plist-get outcome :error) :code))))))

(ert-deftest consortium-rlm-decode-line-unknown-kind ()
  (let ((line "{\"protocol\":\"prolog_agent_ui_v1\",\"kind\":\"future_kind\"}"))
    (let ((outcome (consortium-rlm-tests--decode line)))
      (should-not (plist-get outcome :ok))
      (should (equal "unknown_frame_kind" (plist-get (plist-get outcome :error) :code))))))

(ert-deftest consortium-rlm-decode-line-error-frame ()
  (let ((line "{\"protocol\":\"prolog_agent_ui_v1\",\"kind\":\"error\",\"session_id\":\"s1\",\"request_id\":\"req_1\",\"code\":\"sequence_gap\",\"message\":\"gap\",\"details\":{}}"))
    (let ((outcome (consortium-rlm-tests--decode line)))
      (should (plist-get outcome :ok))
      (should (equal "sequence_gap" (alist-get 'code (plist-get outcome :ok)))))))

;;; Reducer: snapshot ----------------------------------------------------

(ert-deftest consortium-rlm-snapshot-produces-canonical-view ()
  (let ((view (consortium-rlm-tests--view)))
    (should (equal "session_1" (plist-get view :session-id)))
    (should (equal 0 (plist-get view :at-seq)))
    (should (equal "idle" (plist-get view :status)))))

(ert-deftest consortium-rlm-snapshot-missing-state-field-fails ()
  (let* ((frame (consortium-rlm-tests--snapshot-frame))
         (state (alist-get 'state frame))
         (broken `((protocol . "prolog_agent_ui_v1")
                   (kind . "snapshot")
                   (session_id . "session_1")
                   (snapshot_id . "snapshot_0")
                   (at_seq . 0)
                   (state . ,(delq (assq 'messages state) state))))
         (outcome (consortium-rlm-client-apply-snapshot
                   (consortium-rlm-client-initial-view "session_1") broken)))
    (should-not (plist-get outcome :ok))
    (should (equal "invalid_snapshot_state" (plist-get (plist-get outcome :error) :code)))))

;;; Reducer: messages and text deltas -----------------------------------

(ert-deftest consortium-rlm-text-deltas-accumulate ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "message_started" '((message_id . "msg_1") (role . "assistant"))))
         (v2 (consortium-rlm-tests--apply! v1 2 "text_delta" '((message_id . "msg_1") (delta . "hello "))))
         (v3 (consortium-rlm-tests--apply! v2 3 "text_delta" '((message_id . "msg_1") (delta . "world"))))
         (msg (car (consortium-rlm-tests--messages v3))))
    (should (equal "hello world" (alist-get 'text msg)))
    (should (equal "streaming" (alist-get 'status msg)))))

(ert-deftest consortium-rlm-message-completed ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "message_started" '((message_id . "msg_1") (role . "assistant"))))
         (v2 (consortium-rlm-tests--apply! v1 2 "message_completed" '((message_id . "msg_1"))))
         (msg (car (consortium-rlm-tests--messages v2))))
    (should (equal "complete" (alist-get 'status msg)))))

(ert-deftest consortium-rlm-text-delta-unknown-message-fails ()
  (let ((outcome (consortium-rlm-tests--apply (consortium-rlm-tests--view) 1 "text_delta" '((message_id . "ghost") (delta . "x")))))
    (should-not (plist-get outcome :ok))
    (should (equal "replay_missing_entity" (plist-get (plist-get outcome :error) :code)))))

(ert-deftest consortium-rlm-ten-thousand-deltas ()
  (let ((view (consortium-rlm-tests--apply!
               (consortium-rlm-tests--apply!
                (consortium-rlm-tests--view) 1 "message_started"
                '((message_id . "msg_1") (role . "assistant")))
               2 "text_delta" '((message_id . "msg_1") (delta . "x"))))
        (seq 2))
    (dotimes (_ 9999)
      (setq seq (1+ seq)
            view (consortium-rlm-tests--apply! view seq "text_delta" '((message_id . "msg_1") (delta . "y")))))
    (should (equal 10001 (plist-get view :at-seq)))
    ;; 1 "x" delta + 9999 "y" deltas, upstream concatenates directly.
    (should (equal 10000 (length (alist-get 'text (car (consortium-rlm-tests--messages view))))))))

;;; Reducer: sequence discipline ----------------------------------------

(ert-deftest consortium-rlm-duplicate-seq-ignored ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "run_started" '((run_id . "run_1"))))
         (v2 (consortium-rlm-tests--apply! v1 1 "run_started" '((run_id . "run_1")))))
    (should (eq v1 v2))
    (should (equal 1 (plist-get v2 :at-seq)))))

(ert-deftest consortium-rlm-sequence-gap-error ()
  (let* ((v0 (consortium-rlm-tests--view))
         (outcome (consortium-rlm-tests--apply v0 5 "run_started" '((run_id . "run_1")))))
    (should-not (plist-get outcome :ok))
    (let ((err (plist-get outcome :error)))
      (should (equal "sequence_gap" (plist-get err :code)))
      ;; Upstream ui_error details are objects: alist keys in Elisp.
      (should (equal 1 (alist-get 'expected (plist-get err :details))))
      (should (equal 5 (alist-get 'actual (plist-get err :details)))))))

(ert-deftest consortium-rlm-session-mismatch-error ()
  (let* ((v0 (consortium-rlm-tests--view))
         (frame `((protocol . "prolog_agent_ui_v1")
                  (kind . "event")
                  (session_id . "session_2")
                  (seq . 1)
                  (event_id . "evt_1")
                  (event_type . "run_started")
                  (payload . ((run_id . "run_9"))))
                )
         (outcome (consortium-rlm-client-apply-event v0 frame)))
    (should-not (plist-get outcome :ok))
    (should (equal "session_mismatch" (plist-get (plist-get outcome :error) :code)))))

;;; Reducer: tools, approvals, questions, subagents ----------------------

(ert-deftest consortium-rlm-tool-lifecycle-upsert ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "tool_started" '((tool_id . "tool_1") (name . "project_search") (arguments . ((query . "rlm_authority"))))))
         (v2 (consortium-rlm-tests--apply! v1 2 "tool_output" '((tool_id . "tool_1") (output . ((matches . 3))))))
         (v3 (consortium-rlm-tests--apply! v2 3 "tool_finished" '((tool_id . "tool_1") (outcome . ((status . "ok") (matches . 3))))))
         (tools (plist-get v3 :tools)))
    (should (equal 1 (length tools)))
    (let ((tool (car tools)))
      (should (equal "project_search" (alist-get 'name tool)))
      (should (equal "finished" (alist-get 'status tool)))
      (should (equal 3 (alist-get 'matches (alist-get 'outcome tool)))))))

(ert-deftest consortium-rlm-unknown-tool-reduced-generically ()
  ;; A tool name is data: unknown names reduce like any other tool.
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "tool_started" '((tool_id . "tool_9") (name . "mystery_linter") (arguments . ((mode . "strict"))))))
         (v2 (consortium-rlm-tests--apply! v1 2 "tool_finished" '((tool_id . "tool_9") (outcome . ((status . "ok") (warnings . 0)))))))
    (should (equal 1 (length (plist-get v2 :tools))))))

(ert-deftest consortium-rlm-approval-lifecycle ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "approval_required" '((approval_id . "approval_1") (tool_id . "tool_2") (diff . ((path . "prolog/rlm_authority.pl") (added . 4) (removed . 1))) (choices . ["approve_diff" "allow_once" "allow_session"]))))
         (v2 (consortium-rlm-tests--apply! v1 2 "approval_resolved" '((approval_id . "approval_1") (decision . "allow_once"))))
         (approval (car (plist-get v2 :approvals))))
    (should (equal "resolved" (alist-get 'status approval)))
    (should (equal "allow_once" (alist-get 'decision approval)))))

(ert-deftest consortium-rlm-question-lifecycle ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "question_required" '((question_id . "question_1") (prompt . "Profile?") (choices . ["authority"]))))
         (v2 (consortium-rlm-tests--apply! v1 2 "question_answered" '((question_id . "question_1") (answer . "authority")))))
    (should (equal "answered" (alist-get 'status (car (plist-get v2 :questions)))))))

(ert-deftest consortium-rlm-subagent-lifecycle ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "subagent_started" '((subagent_id . "subagent_1") (role . "verifier"))))
         (v2 (consortium-rlm-tests--apply! v1 2 "subagent_finished" '((subagent_id . "subagent_1") (outcome . "ok")))))
    (should (equal "finished" (alist-get 'status (car (plist-get v2 :subagents)))))))

;;; Reducer: verification, usage, traces, effects ------------------------

(ert-deftest consortium-rlm-verification-usage-trace-records ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "verification" '((name . "authority") (outcome . ((status . "pass") (tests . 42))))))
         (v2 (consortium-rlm-tests--apply! v1 2 "usage" '((input_tokens . 1200) (output_tokens . 340))))
         (v3 (consortium-rlm-tests--apply! v2 3 "trace" '((trace_id . "trace_1") (span . "verify"))))
         (v4 (consortium-rlm-tests--apply! v3 4 "effect_indeterminate" '((effect_id . "effect_1") (detail . ((reason . "transport_lost")))))))
    (should (equal 1 (length (plist-get v4 :verification))))
    (should (equal 1200 (alist-get 'input_tokens (plist-get v4 :usage))))
    (should (equal 1 (length (plist-get v4 :traces))))
    (should (equal 1 (length (plist-get v4 :indeterminate-effects))))))

(ert-deftest consortium-rlm-verification-bounded-at-256 ()
  (let ((view (consortium-rlm-tests--view))
        (seq 0))
    (dotimes (_ 260)
      (setq seq (1+ seq)
            view (consortium-rlm-tests--apply! view seq "verification" `((name . "v") (outcome . ((n . ,seq)))))))
    (should (equal 256 (length (plist-get view :verification))))
    ;; Oldest records are dropped: first kept is n=5, newest n=260 last.
    (should (equal 5 (alist-get 'n (alist-get 'outcome (car (plist-get view :verification))))))
    (should (equal 260 (alist-get 'n (alist-get 'outcome (car (last (plist-get view :verification)))))))))

(ert-deftest consortium-rlm-usage-replaces-not-appends ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "usage" '((input_tokens . 10) (output_tokens . 5))))
         (v2 (consortium-rlm-tests--apply! v1 2 "usage" '((input_tokens . 20) (output_tokens . 9)))))
    (should (equal 20 (alist-get 'input_tokens (plist-get v2 :usage))))
    (should (equal 9 (alist-get 'output_tokens (plist-get v2 :usage))))))

;;; Reducer: run lifecycle -----------------------------------------------

(ert-deftest consortium-rlm-run-start-finish ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "run_started" '((run_id . "run_1") (task . "repair authority tests"))))
         (v2 (consortium-rlm-tests--apply! v1 2 "run_finished" '((outcome . ((status . "ok") (changed_files . 1)))))))
    (should (equal "finished" (plist-get v2 :status)))
    (should (equal "repair authority tests" (alist-get 'task (plist-get v2 :run))))
    (should (equal 1 (alist-get 'changed_files (alist-get 'outcome (plist-get v2 :run)))))))

;;; Reducer: extensions ---------------------------------------------------

(ert-deftest consortium-rlm-optional-unknown-event-retained ()
  (let* ((v0 (consortium-rlm-tests--view))
         (frame `((protocol . "prolog_agent_ui_v1")
                  (kind . "event")
                  (session_id . "session_1")
                  (seq . 1)
                  (event_id . "evt_1")
                  (event_type . "frontend_hint")
                  (payload . ((density . "compact")))
                  (extension . ((namespace . "agentprolog.canonical") (required . :json-false)))))
         (outcome (consortium-rlm-client-apply-event v0 frame))
         (view (plist-get outcome :ok)))
    (should view)
    (should (equal 1 (length (plist-get view :extensions))))
    (should (equal 1 (plist-get view :at-seq)))))

(ert-deftest consortium-rlm-unknown-event-without-extension-fails ()
  (let* ((v0 (consortium-rlm-tests--view))
         (frame (consortium-rlm-tests--event-frame 1 "future_hint" '((x . 1))))
         (outcome (consortium-rlm-client-apply-event v0 frame)))
    (should-not (plist-get outcome :ok))
    (should (equal "unknown_event_without_extension" (plist-get (plist-get outcome :error) :code)))))

(ert-deftest consortium-rlm-required-extension-fails-closed ()
  (let* ((v0 (consortium-rlm-tests--view))
         (frame `((protocol . "prolog_agent_ui_v1")
                  (kind . "event")
                  (session_id . "session_1")
                  (seq . 1)
                  (event_id . "evt_1")
                  (event_type . "new_authority_semantics")
                  (payload . nil)
                  (extension . ((namespace . "future.ns") (required . t)))))
         (outcome (consortium-rlm-client-apply-event v0 frame)))
    (should-not (plist-get outcome :ok))
    (should (equal "unsupported_required_extension" (plist-get (plist-get outcome :error) :code)))))

;;; Reconnect ------------------------------------------------------------

(ert-deftest consortium-rlm-reconnect-snapshot-replaces-view ()
  (let* ((v0 (consortium-rlm-tests--view))
         (v1 (consortium-rlm-tests--apply! v0 1 "run_started" '((run_id . "run_1"))))
         (v2 (consortium-rlm-tests--apply! v1 2 "message_started" '((message_id . "msg_1") (role . "assistant")))))
    ;; Reconnect delivers a fresh canonical snapshot at seq 10.
    (let* ((snap `((protocol . "prolog_agent_ui_v1")
                   (kind . "snapshot")
                   (session_id . "session_1")
                   (snapshot_id . "snapshot_10")
                   (at_seq . 10)
                   (state . ((status . "running")
                             (run . ((run_id . "run_1")))
                             (messages . [])
                             (tools . [])
                             (approvals . [])
                             (questions . [])
                             (subagents . [])
                             (verification . [])
                             (usage . nil)
                             (traces . [])
                             (indeterminate_effects . [])
                             (extensions . [])))))
           (outcome (consortium-rlm-client-apply-snapshot v2 snap))
           (view (plist-get outcome :ok)))
      (should view)
      (should (equal 10 (plist-get view :at-seq)))
      ;; Old local message projection is gone: canonical state wins.
      ;; Upstream state_to_view copies state values as-is (empty list).
      (should (equal '() (plist-get view :messages)))
      ;; Overlapping events after the snapshot apply cleanly.
      (let ((view2 (consortium-rlm-tests--apply! view 11 "message_started" '((message_id . "msg_2") (role . "assistant")))))
        (should (equal 11 (plist-get view2 :at-seq)))))))

;;; Transport: NDJSON framing buffer --------------------------------------

(defun consortium-rlm-tests--framer (&optional capacity)
  "A test framer collecting frames as they are framed.
Return (FRAMER-COLLECTOR . COLLECT) where COLLECT is a closure
reading the frames collected so far (newest last)."
  (let* ((frames nil)
         (conn (consortium-rlm-process-make-framer
                (lambda (line)
                  (push line frames))
                capacity)))
    ;; Stable across repeated calls: reverse without draining.
    (cons conn (lambda () (reverse frames)))))

(ert-deftest consortium-rlm-framing-split-across-callbacks ()
  (cl-destructuring-bind (conn . collect) (consortium-rlm-tests--framer)
    (consortium-rlm-process-feed conn "{\"protocol\":\"prolog_")
    (consortium-rlm-process-feed conn "agent_ui_v1\",\"kind\":\"negotiate\"}\n")
    (should (equal 1 (length (funcall collect))))
    (should (equal "{\"protocol\":\"prolog_agent_ui_v1\",\"kind\":\"negotiate\"}" (car (funcall collect))))))

(ert-deftest consortium-rlm-framing-coalesced-records ()
  (cl-destructuring-bind (conn . collect) (consortium-rlm-tests--framer)
    (consortium-rlm-process-feed conn "{\"kind\":1}\n{\"kind\":2}\n{\"kind\":3}\n")
    (should (equal 3 (length (funcall collect))))
    (should (equal '("{\"kind\":1}" "{\"kind\":2}" "{\"kind\":3}") (funcall collect)))))

(ert-deftest consortium-rlm-framing-crlf-and-empty-lines ()
  (cl-destructuring-bind (conn . collect) (consortium-rlm-tests--framer)
    (consortium-rlm-process-feed conn "\r\n{\"kind\":1}\r\n\n")
    (should (equal 1 (length (funcall collect))))
    (should (equal "{\"kind\":1}" (car (funcall collect))))))

(ert-deftest consortium-rlm-framing-utf8-record-survives ()
  (cl-destructuring-bind (conn . collect) (consortium-rlm-tests--framer)
    ;; One record with multibyte payload; chunks are pre-decoded strings.
    (consortium-rlm-process-feed conn (encode-coding-string "{\"delta\":\"héllo→\"}\n" 'utf-8-unix))
    (should (equal 1 (length (funcall collect))))
    (should (equal "{\"delta\":\"héllo→\"}" (car (funcall collect))))))

(ert-deftest consortium-rlm-framing-malformed-line-flushed ()
  (cl-destructuring-bind (conn . collect) (consortium-rlm-tests--framer)
    ;; A malformed unterminated line is framed when the next line arrives,
    ;; then framing continues with the following record.
    (consortium-rlm-process-feed conn "{broken")
    (consortium-rlm-process-feed conn "junk\n{\"kind\":1}\n")
    (should (equal '("{brokenjunk" "{\"kind\":1}") (funcall collect)))))

(ert-deftest consortium-rlm-framing-buffer-cap-signals-overflow ()
  (cl-destructuring-bind (conn . collect) (consortium-rlm-tests--framer 100)
    ;; Pending buffer beyond capacity clears itself and signals overflow;
    ;; the framer keeps working for the next record.
    (should-error (consortium-rlm-process-feed conn (make-string 101 ?x)))
    (should-error (consortium-rlm-process-feed conn (make-string 101 ?x)))
    (consortium-rlm-process-feed conn "{\"kind\":1}\n")
    (should (equal 1 (length (funcall collect))))
    (should (equal "{\"kind\":1}" (car (funcall collect))))))

;;; Transport: encoding client frames -------------------------------------

(ert-deftest consortium-rlm-encode-command-frame ()
  (let* ((line (consortium-rlm-client-encode-command "s1" "req_1" "approval.decide"
                                                     '((approval_id . "approval_1") (decision . "allow_once"))))
         (frame (plist-get (consortium-rlm-tests--decode line) :ok)))
    (should (equal "command" (alist-get 'kind frame)))
    (should (equal "req_1" (alist-get 'request_id frame)))
    (should (equal "allow_once" (alist-get 'decision (alist-get 'payload frame))))))

(ert-deftest consortium-rlm-encode-negotiate-frame ()
  (let* ((line (consortium-rlm-client-encode-negotiate "req_1" nil '("native_file_buffers" "side_by_side_diff")))
         (frame (plist-get (consortium-rlm-tests--decode line) :ok)))
    (should (equal "negotiate" (alist-get 'kind frame)))
    (should (member "prolog_agent_ui_v1" (alist-get 'protocol_versions (alist-get 'payload frame))))))

(provide 'consortium-rlm-tests)
;;; consortium-rlm-tests.el ends here
