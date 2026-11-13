;;; consortium-rlm-client.el --- prolog_agent_ui_v1 codec and reducer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Pure prolog_agent_ui_v1 protocol layer for the Consortium Emacs
;; workbench: NDJSON codec, frame validation, and the canonical
;; client-side reducer mirroring upstream `ui_v1_apply_snapshot',
;; `ui_v1_apply_event' and `ui_v1_replay' semantics.
;;
;; Pinned upstream revision: lost-rob0t/prolog-rlm
;; a89175bf925df3afa358f8d05a370fe2a03e2117.
;;
;; This module owns no UI and performs no I/O.  The reducer enforces
;; authoritative server sequence numbers: duplicates are ignored,
;; forward gaps are protocol errors, and unknown events fail closed
;; unless they carry an optional extension descriptor.  Reconnect
;; always replaces the view from a canonical snapshot.

;;; Code:

(require 'json)
(require 'cl-lib)

(defconst consortium-rlm-client-protocol "prolog_agent_ui_v1"
  "Wire identifier of the canonical frontend protocol.")

(defconst consortium-rlm-client-max-bounded-list 256
  "Upstream bounded-collection cap for snapshot state collections.")

(defconst consortium-rlm-client-known-event-types
  '("run_started" "message_started" "text_delta" "message_completed"
    "tool_started" "tool_output" "tool_finished"
    "approval_required" "approval_resolved"
    "question_required" "question_answered"
    "subagent_started" "subagent_finished"
    "verification" "usage" "trace" "effect_indeterminate"
    "run_finished")
  "Known semantic event types at the pinned upstream revision.")

(defconst consortium-rlm-client-snapshot-state-fields
  '(status run messages tools approvals questions subagents
           verification usage traces indeterminate_effects extensions)
  "Required canonical snapshot state fields.")

(define-error 'consortium-rlm-error
  "Consortium RLM error")

(define-error 'consortium-rlm-protocol-error
  "Invalid prolog_agent_ui_v1 record"
  'consortium-rlm-error)

;;; Error plumbing --------------------------------------------------------

(defun consortium-rlm-client--error-outcome (code details)
  "Build an (:error PLIST) outcome with CODE and DETAILS."
  (list :error
        (list :code code
              :message (concat "Invalid prolog_agent_ui_v1 record: " code)
              :details details)))

(defun consortium-rlm-client--fault (code details)
  "Signal a protocol fault with CODE and DETAILS."
  (signal 'consortium-rlm-protocol-error
          (list (consortium-rlm-client--error-plist code details))))

(defun consortium-rlm-client--error-plist (code details)
  (list :code code
        :message (concat "Invalid prolog_agent_ui_v1 record: " code)
        :details details))

(defun consortium-rlm-client--condition-error (condition)
  "Normalize a signaled protocol CONDITION into its error plist."
  (if (and (consp condition)
           (eq (car condition) 'consortium-rlm-protocol-error))
      (cadr condition)
    condition))

(defmacro consortium-rlm-client--catch (body)
  "Run BODY, catching protocol faults into an (:error PLIST) outcome."
  `(condition-case err
       ,body
     (consortium-rlm-protocol-error
      (list :error (consortium-rlm-client--condition-error err)))))

;;; Validation helpers ----------------------------------------------------

(defun consortium-rlm-client--string (dict key)
  (let ((value (alist-get key dict)))
    (unless (stringp value)
      (consortium-rlm-client--fault "invalid_string_field" (list (cons 'field key))))
    value))

(defun consortium-rlm-client--id (dict key)
  (let ((value (alist-get key dict)))
    (unless (and (stringp value) (> (length value) 0) (<= (length value) 200))
      (consortium-rlm-client--fault "invalid_id" (list (cons 'field key))))
    value))

(defun consortium-rlm-client--dict (dict key)
  (let ((value (alist-get key dict)))
    (unless (listp value)
      (consortium-rlm-client--fault "invalid_object_field" (list (cons 'field key))))
    value))

;;; Frame validation ------------------------------------------------------

(defun consortium-rlm-client-decode-line (line)
  "Decode one NDJSON LINE into (list :ok frame) or (list :error plist)."
  (condition-case nil
      (let ((frame (json-parse-string line
                                      :object-type 'alist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object :json-false)))
        (consortium-rlm-client--catch (consortium-rlm-client-validate frame)))
    (json-error
     (list :error (list :code "ndjson_codec_error"
                        :message "Failed to decode NDJSON frame"
                        :details nil)))))

(defun consortium-rlm-client-validate (frame)
  "Validate FRAME against the v1 contract, returning an outcome list."
  (consortium-rlm-client--catch
   (consortium-rlm-client--validate frame)))

(defun consortium-rlm-client--validate (frame)
  (unless (and (stringp (alist-get 'protocol frame))
               (string= (alist-get 'protocol frame)
                        consortium-rlm-client-protocol))
    (consortium-rlm-client--fault "invalid_field" '((field . protocol))))
  (let ((kind (consortium-rlm-client--string frame 'kind)))
    (pcase kind
      ("negotiate" (consortium-rlm-client--validate-negotiate frame))
      ("snapshot" (consortium-rlm-client--validate-snapshot frame))
      ("event" (consortium-rlm-client--validate-event frame))
      ("command" (consortium-rlm-client--validate-command frame))
      ("result" (consortium-rlm-client--validate-result frame))
      ("error" (consortium-rlm-client--validate-error frame))
      (_ (consortium-rlm-client--fault "unknown_frame_kind"
                                       (list (cons 'kind kind))))))
  (list :ok frame))

(defun consortium-rlm-client--validate-negotiate (frame)
  (consortium-rlm-client--id frame 'request_id)
  (let* ((payload (consortium-rlm-client--dict frame 'payload))
         (versions (alist-get 'protocol_versions payload)))
    (unless (and (listp versions) (cl-every #'stringp versions))
      (consortium-rlm-client--fault
       "invalid_list_field" '((field . protocol_versions))))
    (unless (member consortium-rlm-client-protocol versions)
      (consortium-rlm-client--fault
       "protocol_version_not_offered" (list (cons 'offered versions))))))

(defun consortium-rlm-client--validate-snapshot (frame)
  (consortium-rlm-client--id frame 'session_id)
  (consortium-rlm-client--id frame 'snapshot_id)
  (let ((at-seq (alist-get 'at_seq frame)))
    (unless (and (integerp at-seq) (>= at-seq 0))
      (consortium-rlm-client--fault
       "invalid_integer_field" '((field . at_seq))))
    (consortium-rlm-client--dict frame 'state)))

(defun consortium-rlm-client--validate-event (frame)
  (consortium-rlm-client--id frame 'session_id)
  (let ((seq (alist-get 'seq frame)))
    (unless (and (integerp seq) (> seq 0))
      (consortium-rlm-client--fault
       "invalid_integer_field" '((field . seq))))
    (consortium-rlm-client--id frame 'event_id)
    (let ((event-type (consortium-rlm-client--string frame 'event_type)))
      (consortium-rlm-client--dict frame 'payload)
      (unless (member event-type consortium-rlm-client-known-event-types)
        (consortium-rlm-client--validate-extension frame event-type)))))

(defun consortium-rlm-client--validate-extension (frame event-type)
  (let ((extension (alist-get 'extension frame)))
    (if (and (listp extension)
             (stringp (alist-get 'namespace extension))
             (memq (alist-get 'required extension) '(t :json-false nil)))
        (when (eq (alist-get 'required extension) t)
          (consortium-rlm-client--fault
           "unsupported_required_extension"
           (list (cons 'event_type event-type)
                 (cons 'namespace (alist-get 'namespace extension)))))
      (consortium-rlm-client--fault
       "unknown_event_without_extension"
       (list (cons 'event_type event-type))))))

(defun consortium-rlm-client--validate-command (frame)
  (consortium-rlm-client--id frame 'session_id)
  (consortium-rlm-client--id frame 'request_id)
  (consortium-rlm-client--string frame 'command)
  (consortium-rlm-client--dict frame 'payload))

(defun consortium-rlm-client--validate-result (frame)
  (consortium-rlm-client--id frame 'session_id)
  (consortium-rlm-client--id frame 'request_id)
  (let ((status (consortium-rlm-client--string frame 'status)))
    (unless (member status '("ok" "rejected"))
      (consortium-rlm-client--fault
       "invalid_result_status" (list (cons 'status status)))))
  (consortium-rlm-client--dict frame 'payload))

(defun consortium-rlm-client--validate-error (frame)
  (consortium-rlm-client--id frame 'session_id)
  (consortium-rlm-client--string frame 'code)
  (consortium-rlm-client--string frame 'message)
  (consortium-rlm-client--dict frame 'details))

;;; Encoding --------------------------------------------------------------

(defun consortium-rlm-client-encode-command (session-id request-id command payload)
  "Encode a command frame line for SESSION-ID, REQUEST-ID, COMMAND, PAYLOAD."
  (json-encode
   (list (cons 'protocol consortium-rlm-client-protocol)
         '(kind . "command")
         (cons 'session_id session-id)
         (cons 'request_id request-id)
         (cons 'command command)
         (cons 'payload (or payload (list))))))

(defun consortium-rlm-client-encode-negotiate (request-id required optional)
  "Encode a negotiate frame line with REQUEST-ID, REQUIRED, OPTIONAL caps."
  (json-encode
   (list (cons 'protocol consortium-rlm-client-protocol)
         '(kind . "negotiate")
         (cons 'request_id request-id)
         (cons 'payload
               (list (cons 'protocol_versions
                           (list consortium-rlm-client-protocol))
                     (cons 'required_capabilities (or required (list)))
                     (cons 'optional_capabilities (or optional (list))))))))

;;; Canonical view ----------------------------------------------------------

(defun consortium-rlm-client-initial-view (session-id)
  "Return the initial canonical view for SESSION-ID."
  (list :protocol consortium-rlm-client-protocol
        :session-id session-id
        :at-seq 0
        :status "idle"
        :run nil
        :messages nil
        :tools nil
        :approvals nil
        :questions nil
        :subagents nil
        :verification nil
        :usage nil
        :traces nil
        :indeterminate-effects nil
        :extensions nil))

(defun consortium-rlm-client--as-list (value)
  "Normalize VALUE to a list; wire arrays decode as lists."
  (if (vectorp value) (append value nil) value))

(defun consortium-rlm-client--snapshot-view (validated)
  "Build a canonical view from VALIDATED snapshot frame data."
  (let ((state (alist-get 'state validated)))
    (dolist (field consortium-rlm-client-snapshot-state-fields)
      (unless (assq field state)
        (consortium-rlm-client--fault
         "invalid_snapshot_state" (list (cons 'missing field)))))
    (list :protocol consortium-rlm-client-protocol
          :session-id (alist-get 'session_id validated)
          :at-seq (alist-get 'at_seq validated)
          :status (alist-get 'status state)
          :run (alist-get 'run state)
          :messages (consortium-rlm-client--as-list (alist-get 'messages state))
          :tools (consortium-rlm-client--as-list (alist-get 'tools state))
          :approvals (consortium-rlm-client--as-list (alist-get 'approvals state))
          :questions (consortium-rlm-client--as-list (alist-get 'questions state))
          :subagents (consortium-rlm-client--as-list (alist-get 'subagents state))
          :verification (consortium-rlm-client--as-list (alist-get 'verification state))
          :usage (alist-get 'usage state)
          :traces (consortium-rlm-client--as-list (alist-get 'traces state))
          :indeterminate-effects (consortium-rlm-client--as-list
                                  (alist-get 'indeterminate_effects state))
          :extensions (consortium-rlm-client--as-list (alist-get 'extensions state)))))

(defun consortium-rlm-client--kind-check (frame expected)
  "Return error outcome when FRAME is not of kind EXPECTED."
  (unless (string= expected (alist-get 'kind frame))
    (list :error (list :code (concat "expected_" expected)
                       :message (concat "Expected " expected " frame")
                       :details (list (cons 'kind (alist-get 'kind frame)))))))

(defun consortium-rlm-client--session-check (frame session-id what)
  "Return error outcome when FRAME session mismatches SESSION-ID."
  (unless (string= session-id (alist-get 'session_id frame))
    (list :error (list :code "session_mismatch"
                       :message (concat what " belongs to another session")
                       :details (list (cons 'expected session-id)
                                      (cons 'actual
                                            (alist-get 'session_id frame)))))))

(defun consortium-rlm-client-apply-snapshot (view frame)
  "Apply canonical snapshot FRAME to VIEW, replacing local projection."
  (pcase (consortium-rlm-client-validate frame)
    (`(:error ,err) (list :error err))
    (`(:ok ,validated)
     (or (consortium-rlm-client--kind-check validated "snapshot")
         (consortium-rlm-client--session-check
          validated (plist-get view :session-id) "Snapshot")
         (consortium-rlm-client--catch
          (list :ok (consortium-rlm-client--snapshot-view validated)))))
    (_ (list :error (consortium-rlm-client--error-plist
                     "internal_validate_outcome" nil)))))

(defun consortium-rlm-client-apply-event (view frame)
  "Apply event FRAME to canonical VIEW honoring sequence discipline."
  (pcase (consortium-rlm-client-validate frame)
    (`(:error ,err) (list :error err))
    (`(:ok ,validated)
     (or (consortium-rlm-client--kind-check validated "event")
         (consortium-rlm-client--session-check
          validated (plist-get view :session-id) "Event")
         (consortium-rlm-client--sequence-step view validated)))))

(defun consortium-rlm-client--sequence-step (view validated)
  (let ((seq (alist-get 'seq validated)))
    (cond
     ((<= seq (plist-get view :at-seq))
      (list :ok view))
     ((/= seq (1+ (plist-get view :at-seq)))
      (list :error
            (list :code "sequence_gap"
                  :message "Event stream has a sequence gap"
                  :details (list (cons 'expected (1+ (plist-get view :at-seq)))
                                 (cons 'actual seq)))))
     (t
      (consortium-rlm-client--catch
       (list :ok (consortium-rlm-client--reduce validated view)))))))

(defun consortium-rlm-client-replay (snapshot events)
  "Replay SNAPSHOT then EVENTS into a canonical view."
  (pcase (consortium-rlm-client-apply-snapshot
          (consortium-rlm-client-initial-view
           (alist-get 'session_id snapshot))
          snapshot)
    (`(:error ,err) (list :error err))
    (`(:ok ,view)
     (let ((current view)
           (failure nil))
       (while (and events (not failure))
         (pcase (consortium-rlm-client-apply-event current (car events))
           (`(:error ,err) (setq failure err))
           (`(:ok ,next)
            (setq current next)
            (setq events (cdr events)))))
       (if failure
           (list :error failure)
         (list :ok current))))))

;;; Reducer ---------------------------------------------------------------

(defun consortium-rlm-client--reduce (frame view)
  "Reduce one validated event FRAME into a new canonical VIEW."
  (let ((event-type (alist-get 'event_type frame))
        (payload (alist-get 'payload frame))
        (seq (alist-get 'seq frame)))
    (consortium-rlm-client--finish-reduce
     (pcase event-type
       ("run_started"
        (list :status "running" :run payload))
       ("message_started"
        (list :messages
              (consortium-rlm-client--upsert
               (list (cons 'id (consortium-rlm-client--payload-id payload 'message_id))
                     (cons 'role (consortium-rlm-client--payload-string payload 'role))
                     '(text . "")
                     '(status . "streaming"))
               (plist-get view :messages))))
       ("text_delta"
        (list :messages
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'message_id)
               (plist-get view :messages)
               (lambda (message)
                 (consortium-rlm-client--merge-item
                  message
                  (list (cons 'text
                              (concat (alist-get 'text message "")
                                      (alist-get 'delta payload)))))))))
       ("message_completed"
        (list :messages
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'message_id)
               (plist-get view :messages)
               (lambda (message)
                 (consortium-rlm-client--merge-item message '((status . "complete")))))))
       ("tool_started"
        (list :tools
              (consortium-rlm-client--upsert
               (consortium-rlm-client--with-id payload 'tool_id "running")
               (plist-get view :tools))))
       ("tool_output"
        (list :tools
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'tool_id)
               (plist-get view :tools)
               (lambda (tool)
                 (consortium-rlm-client--merge-item
                  tool (list (cons 'output (alist-get 'output payload))))))))
       ("tool_finished"
        (list :tools
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'tool_id)
               (plist-get view :tools)
               (lambda (tool)
                 (consortium-rlm-client--merge-item
                  tool (list '(status . "finished")
                             (cons 'outcome (alist-get 'outcome payload))))))))
       ("approval_required"
        (list :approvals
              (consortium-rlm-client--upsert
               (consortium-rlm-client--with-id payload 'approval_id "pending")
               (plist-get view :approvals))))
       ("approval_resolved"
        (list :approvals
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'approval_id)
               (plist-get view :approvals)
               (lambda (approval)
                 (consortium-rlm-client--merge-item
                  approval (list '(status . "resolved")
                                 (cons 'decision (alist-get 'decision payload))))))))
       ("question_required"
        (list :questions
              (consortium-rlm-client--upsert
               (consortium-rlm-client--with-id payload 'question_id "pending")
               (plist-get view :questions))))
       ("question_answered"
        (list :questions
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'question_id)
               (plist-get view :questions)
               (lambda (question)
                 (consortium-rlm-client--merge-item
                  question (list '(status . "answered")
                                 (cons 'answer (alist-get 'answer payload))))))))
       ("subagent_started"
        (list :subagents
              (consortium-rlm-client--upsert
               (consortium-rlm-client--with-id payload 'subagent_id "running")
               (plist-get view :subagents))))
       ("subagent_finished"
        (list :subagents
              (consortium-rlm-client--update-item
               (consortium-rlm-client--payload-id payload 'subagent_id)
               (plist-get view :subagents)
               (lambda (subagent)
                 (consortium-rlm-client--merge-item subagent '((status . "finished")))))))
       ("verification"
        (list :verification
              (consortium-rlm-client--append-bounded
               (plist-get view :verification) payload)))
       ("usage"
        (list :usage payload))
       ("trace"
        (list :traces
              (consortium-rlm-client--append-bounded
               (plist-get view :traces) payload)))
       ("effect_indeterminate"
        (list :indeterminate-effects
              (consortium-rlm-client--append-bounded
               (plist-get view :indeterminate-effects) payload)))
       ("run_finished"
        (let* ((run (plist-get view :run))
               (merged (if (listp run) (append payload run) payload)))
          (list :status "finished" :run merged)))
       (_
        (list :extensions
              (consortium-rlm-client--append-bounded
               (plist-get view :extensions)
               (list (cons 'event_type (alist-get 'event_type frame))
                     (cons 'extension (alist-get 'extension frame))
                     (cons 'payload payload))))))
     view seq)))

(defun consortium-rlm-client--finish-reduce (field-updates view seq)
  "Merge FIELD-UPDATES into VIEW bumping its cursor to SEQ."
  (let ((next (plist-put view :at-seq seq))
        (updates field-updates))
    (while updates
      (setq next (plist-put next (car updates) (cadr updates))
            updates (cddr updates)))
    next))

(defun consortium-rlm-client--with-id (payload id-key status)
  "Build an item from PAYLOAD with its ID-KEY promoted and STATUS."
  (let ((id (consortium-rlm-client--payload-id payload id-key)))
    (cons (cons 'id id)
          (cons '(status . nil)
                (cons (cons 'status status)
                      payload)))))

(defun consortium-rlm-client--merge-item (item updates)
  "Merge UPDATE pairs into ITEM without duplicating keys."
  (let ((result updates))
    (dolist (pair item)
      (unless (assq (car pair) updates)
        (setq result (append result (list pair)))))
    result))

(defun consortium-rlm-client--payload-id (payload key)
  (let ((value (alist-get key payload)))
    (unless (and (stringp value) (> (length value) 0) (<= (length value) 200))
      (consortium-rlm-client--fault "invalid_id" (list (cons 'field key))))
    value))

(defun consortium-rlm-client--payload-string (payload key)
  (let ((value (alist-get key payload)))
    (unless (stringp value)
      (consortium-rlm-client--fault "invalid_string_field" (list (cons 'field key))))
    value))

(defun consortium-rlm-client--update-item (id items update)
  "Update the item with ID in ITEMS via UPDATE, preserving order."
  (let ((result nil)
        (found nil)
        (tail items))
    (while tail
      (let ((item (car tail)))
        (if (and (listp item) (equal (alist-get 'id item) id))
            (progn
              (setq found t)
              (setq result (cons (funcall update item) result)))
          (setq result (cons item result))))
      (setq tail (cdr tail)))
    (unless found
      (consortium-rlm-client--fault
       "replay_missing_entity" (list (cons 'id id))))
    (nreverse result)))

(defun consortium-rlm-client--upsert (item items)
  "Upsert ITEM into ITEMS by id, preserving order."
  (let ((id (alist-get 'id item)))
    (if (cl-some (lambda (existing)
                   (and (listp existing) (equal (alist-get 'id existing) id)))
                 items)
        (consortium-rlm-client--update-item
         id items (lambda (_existing) item))
      (append items (list item)))))

(defun consortium-rlm-client--append-bounded (items item)
  "Append ITEM to ITEMS capping length at the upstream bound."
  (let ((all (append items (list item))))
    (if (> (length all) consortium-rlm-client-max-bounded-list)
        (nthcdr (- (length all) consortium-rlm-client-max-bounded-list) all)
      all)))

(provide 'consortium-rlm-client)
;;; consortium-rlm-client.el ends here
