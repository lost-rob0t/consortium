;;; consortium_emacs_tests.el --- ERT entry for the Consortium emacs stack -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

;;; Commentary:

;; Entry point for `nix flake check' emacs-client-tests.  The protocol-
;; pinned stack (client / process / session / ui) is the single canonical
;; Emacs surface; the retired async client (`consortium.el') was removed
;; and its tests superseded by these suites.

;;; Code:

(require 'ert)

(let ((test-dir (file-name-directory load-file-name)))
  (load (expand-file-name "consortium-rlm-tests.el" test-dir))
  (load (expand-file-name "consortium-rlm-session-tests.el" test-dir))
  (load (expand-file-name "consortium-rlm-config-tests.el" test-dir))
  (load (expand-file-name "consortium-rlm-dsl-tests.el" test-dir))
  (load (expand-file-name "consortium-rlm-tools-tests.el" test-dir))
  (load (expand-file-name "consortium-rlm-ui-tests.el" test-dir))
  (load (expand-file-name "consortium-rlm-review-tests.el" test-dir)))

(provide 'consortium_emacs_tests)
;;; consortium_emacs_tests.el ends here
