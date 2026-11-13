;;; consortium-rlm-process.el --- NDJSON pipe transport for Consortium -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Pipe transport for prolog_agent_ui_v1 NDJSON sessions.
;;
;; A persistent Prolog frontend server is started with `make-process'
;; over a pipe (never a PTY) using UTF-8 line coding.  The filter never
;; assumes that one callback delivers one protocol record: a framing
;; buffer carries partial records, multiple records per callback, CRLF
;; framing and empty lines.  Lines are decoded as UTF-8 with a raw
;; fallback so multibyte records survive chunk boundaries.
;;
;; A pending buffer beyond `consortium-rlm-process-frame-capacity'
;; signals `consortium-rlm-frame-overflow' and clears itself so the
;; transport can continue with the next record instead of wedging.

;;; Code:

(require 'cl-lib)

(defconst consortium-rlm-process-frame-capacity 8388608
  "Maximum pending NDJSON framing buffer size in characters.")

(define-error 'consortium-rlm-frame-overflow
  "Consortium NDJSON framing buffer overflow"
  'consortium-rlm-error)

(define-error 'consortium-rlm-error
  "Consortium RLM error")

(cl-defstruct (consortium-rlm-framer
               (:constructor consortium-rlm-process--framer)
               (:conc-name consortium-rlm-framer-))
  "NDJSON framing state."
  callback
  (buffer "")
  (capacity consortium-rlm-process-frame-capacity))

(defun consortium-rlm-process-make-framer (callback &optional capacity)
  "Return a framing buffer delivering complete lines to CALLBACK."
  (let ((framer (consortium-rlm-process--framer :callback callback)))
    (when capacity
      (setf (consortium-rlm-framer-capacity framer) capacity))
    framer))

(defun consortium-rlm-process-feed (framer chunk)
  "Feed CHUNK (decoded string or raw bytes) into FRAMER."
  (setf (consortium-rlm-framer-buffer framer)
        (concat (consortium-rlm-framer-buffer framer) chunk))
  (when (> (length (consortium-rlm-framer-buffer framer))
           (consortium-rlm-framer-capacity framer))
    (setf (consortium-rlm-framer-buffer framer) "")
    (signal 'consortium-rlm-frame-overflow
            (list :capacity (consortium-rlm-framer-capacity framer))))
  (let ((start 0)
        (buffer (consortium-rlm-framer-buffer framer)))
    (while (string-match "\n" buffer start)
      (let* ((raw-line (substring-no-properties
                        buffer start (match-beginning 0)))
             (line (consortium-rlm-process--decode-line raw-line)))
        (when (> (length line) 0)
          (funcall (consortium-rlm-framer-callback framer) line)))
      (setq start (match-end 0)))
    (setf (consortium-rlm-framer-buffer framer)
          (substring-no-properties buffer start))))

(defun consortium-rlm-process--decode-line (raw-line)
  "Decode RAW-LINE as UTF-8 when needed, stripping a trailing CR."
  (let ((line (if (string-suffix-p "\r" raw-line)
                  (substring-no-properties raw-line 0 -1)
                raw-line)))
    (condition-case nil
        (decode-coding-string line 'utf-8-unix)
      (error line))))

;;; Live process transport -------------------------------------------------

(cl-defstruct (consortium-rlm-connection
               (:constructor consortium-rlm-process--connection)
               (:conc-name consortium-rlm-connection-))
  "Live child-process transport."
  name
  process
  framer
  on-frame
  on-death)

(defun consortium-rlm-process-start (name program arguments on-frame on-death)
  "Start persistent pipe transport NAME running PROGRAM with ARGUMENTS.
ON-FRAME receives each complete UTF-8 NDJSON line; ON-DEATH receives
the process and an event string."
  (let ((conn (consortium-rlm-process--connection
               :name name
               :on-frame on-frame
               :on-death on-death))
        (framer nil))
    (setq framer
          (consortium-rlm-process-make-framer
           (lambda (line)
             (funcall (consortium-rlm-connection-on-frame conn) line))))
    (setf (consortium-rlm-connection-framer conn) framer)
    (setf (consortium-rlm-connection-process conn)
          (make-process
           :name name
           :command (cons program arguments)
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :filter (lambda (_process chunk)
                     (consortium-rlm-process--filter conn chunk))
           :sentinel (lambda (process event)
                       (unless (process-live-p process)
                         (funcall (consortium-rlm-connection-on-death conn)
                                  process event)))))
    conn))

(defun consortium-rlm-process--filter (conn chunk)
  "Feed decoded CHUNK from the live process into CONN's framer."
  (condition-case err
      (consortium-rlm-process-feed (consortium-rlm-connection-framer conn) chunk)
    (consortium-rlm-frame-overflow
     (when (process-live-p (consortium-rlm-connection-process conn))
       (delete-process (consortium-rlm-connection-process conn)))
     (funcall (consortium-rlm-connection-on-death conn)
              (consortium-rlm-connection-process conn)
              (format "frame_overflow: %s" (error-message-string err))))))

(defun consortium-rlm-process-send (conn line)
  "Send one complete frame LINE over CONN (newline framing added)."
  (let ((process (consortium-rlm-connection-process conn)))
    (unless (process-live-p process)
      (signal 'consortium-rlm-error (list :reason "process-not-live" :name (consortium-rlm-connection-name conn))))
    (process-send-string process (concat line "\n"))))

(defun consortium-rlm-process-stop (conn)
  "Stop the live transport CONN without waiting."
  (let ((process (consortium-rlm-connection-process conn)))
    (when (process-live-p process)
      (delete-process process)))
  (setf (consortium-rlm-connection-process conn) nil))

(provide 'consortium-rlm-process)
;;; consortium-rlm-process.el ends here
