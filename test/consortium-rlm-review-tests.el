;;; consortium-rlm-review-tests.el --- region review surface tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'consortium-rlm-review)

(defun consortium-rlm-review-tests--kill-generated ()
  "Kill every Consortium review buffer this suite created."
  (dolist (buffer (buffer-list))
    (when (string-match-p "\\`\\*Consortium Review" (buffer-name buffer))
      (kill-buffer buffer))))

(defun consortium-rlm-review-tests--source-buffer (text &optional file)
  "Return a buffer holding TEXT, visiting FILE when given."
  (if file
      (let ((buffer (find-file-noselect file)))
        (with-current-buffer buffer
          (erase-buffer)
          (insert text)
          buffer))
    (let ((buffer (get-buffer-create
                   (generate-new-buffer-name "consortium-review-src"))))
      (with-current-buffer buffer
        (erase-buffer)
        (insert text)
        buffer))))

;;; Rubric data -----------------------------------------------------------

(ert-deftest consortium-rlm-review-default-rubrics-have-checklists ()
  (dolist (rubric consortium-rlm-review-rubrics)
    (should (stringp (car rubric)))
    (should (>= (length rubric) 2))
    (dolist (item (cdr rubric))
      (should (and (stringp item) (> (length item) 0))))))

(ert-deftest consortium-rlm-review-org-checklist-is-ai-free-data ()
  (let ((lines (consortium-rlm-review--org-checklist "grill")))
    (should (= (length lines)
               (length (cdr (assoc "grill" consortium-rlm-review-rubrics)))))
    (dolist (line lines)
      (should (string-match-p "\\`- \\[ \\] " line)))))

;;; Region context --------------------------------------------------------

(ert-deftest consortium-rlm-review-region-context-records-anchor ()
  (let* ((file (expand-file-name "src.el" temporary-file-directory))
         (buffer (progn
                   (with-temp-file file (insert "the quick brown fox"))
                   (find-file-noselect file))))
    (unwind-protect
        (with-current-buffer buffer
          (let ((context (consortium-rlm-review--context 5 9)))
            (should (equal (plist-get context :file) file))
            (should (= (plist-get context :beg) 5))
            (should (= (plist-get context :end) 9))
            (should (equal (plist-get context :text) "quic"))
            (should (= (plist-get context :beg-line) 1))))
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer)
      (delete-file file))))

;;; Manual rubric path (zero AI) ------------------------------------------

(ert-deftest consortium-rlm-review-manual-works-with-ai-off ()
  (let ((consortium-rlm-ui-session nil))
    (cl-letf (((symbol-function 'consortium-rlm-ui-connect)
               (lambda () (error "manual review must not touch the daemon"))))
      (let ((source (consortium-rlm-review-tests--source-buffer
                     "(defun add (a b) (+ a b))\n(defun sub (a b) (- a b))")))
        (unwind-protect
            (progn
              (with-current-buffer source
                (let ((review (consortium-rlm-review-region-manual
                               (point-min) (point-max) "grill")))
                  (with-current-buffer review
                    (should (string-match-p "grill" (buffer-string)))
                    (should (string-match-p "- \\[ \\] " (buffer-string)))
                    (should (string-match-p "(defun sub" (buffer-string))))
                  (with-current-buffer source
                    (should (equal (buffer-string)
                                   "(defun add (a b) (+ a b))\n(defun sub (a b) (- a b))"))))))
          (kill-buffer source)
          (consortium-rlm-review-tests--kill-generated))))))

(ert-deftest consortium-rlm-review-manual-prompts-for-rubric ()
  (let ((consortium-rlm-ui-session nil))
    (cl-letf (((symbol-function 'consortium-rlm-ui-connect)
               (lambda () (error "manual review must not touch the daemon")))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "ponytail-review")))
      (let ((source (consortium-rlm-review-tests--source-buffer "simple body")))
        (unwind-protect
            (with-current-buffer source
              (let ((review (consortium-rlm-review-region-manual 1 11)))
                (with-current-buffer review
                  (should (string-match-p "ponytail-review" (buffer-string))))))
          (kill-buffer source)
          (consortium-rlm-review-tests--kill-generated))))))

;;; AI path (budgeted daemon run, lineage, anchored findings) -------------

(ert-deftest consortium-rlm-review-ai-starts-budgeted-run ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         (sent))
    (cl-letf (((symbol-function 'consortium-rlm-ui-connect)
               (lambda () session))
              ((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line sent))))
      (let ((source (consortium-rlm-review-tests--source-buffer
                     "(defun add (a b) (+ a b))")))
        (unwind-protect
            (with-current-buffer source
              (consortium-rlm-review-region-ai 1 22)
              (should (= (length sent) 1))
              (let* ((frame (json-parse-string (car sent)
                                               :object-type 'alist
                                               :array-type 'list))
                     (params (cdr (assq 'params frame))))
                (should (equal (cdr (assq 'method frame)) "start"))
                (should (string-match-p "(defun add" (cdr (assq 'task params))))
                (should (assq 'budget (cdr (assq 'options params)))))
              (should consortium-rlm-review--pending-request))
          (kill-buffer source)
          (consortium-rlm-review-tests--kill-generated))))))

(ert-deftest consortium-rlm-review-ai-renders-anchored-findings-on-finish ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         (sent))
    (cl-letf (((symbol-function 'consortium-rlm-ui-connect)
               (lambda () session))
              ((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line sent))))
      (let ((source (consortium-rlm-review-tests--source-buffer
                     "(defun add (a b) (+ a b))")))
        (unwind-protect
            (with-current-buffer source
              (consortium-rlm-review-region-ai 1 22)
              (should consortium-rlm-review--pending-request)
              (funcall (cdr consortium-rlm-review--pending-request)
                       t '((run_id . "run_9")))
              (let ((view (list :status "finished"
                                :messages
                                (list (list '(id . "m1")
                                            '(role . "assistant")
                                            '(text . "Finding: off-by-one risk")
                                            '(status . "complete"))))))
                (consortium-rlm-review--handle-event
                 session "run_9" "run_finished" '((outcome . "ok")) view))
              (should-not consortium-rlm-review--pending-request)
              (let ((review (get-buffer "*Consortium Review: consortium-review-src*")))
                (should review)
                (with-current-buffer review
                  (should (string-match-p "run_9" (buffer-string)))
                  (should (string-match-p "Finding: off-by-one risk" (buffer-string)))
                  (should (string-match-p "(defun add" (buffer-string)))))
              (with-current-buffer source
                (should (equal (buffer-string)
                               "(defun add (a b) (+ a b))"))))
          (kill-buffer source)
          (consortium-rlm-review-tests--kill-generated))))))

(ert-deftest consortium-rlm-review-ai-ignores-other-runs ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         (sent))
    (cl-letf (((symbol-function 'consortium-rlm-ui-connect)
               (lambda () session))
              ((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line sent))))
      (let ((source (consortium-rlm-review-tests--source-buffer "body")))
        (unwind-protect
            (with-current-buffer source
              (consortium-rlm-review-region-ai 1 4)
              (funcall (cdr consortium-rlm-review--pending-request)
                       t '((run_id . "run_9")))
              (consortium-rlm-review--handle-event
               session "run_other" "run_finished" '((outcome . "ok"))
               (list :status "finished" :messages nil))
              (should (assoc "run_9" consortium-rlm-review--pending))
              (should-not (get-buffer
                           "*Consortium Review: consortium-review-src*")))
          (kill-buffer source)
          (consortium-rlm-review-tests--kill-generated))))))

(ert-deftest consortium-rlm-review-ai-error-keeps-review-buffer-clean ()
  (let* ((session (consortium-rlm-session--make :name "t"))
         (sent))
    (cl-letf (((symbol-function 'consortium-rlm-ui-connect)
               (lambda () session))
              ((symbol-function 'consortium-rlm-session--send)
               (lambda (_s line) (push line sent))))
      (let ((source (consortium-rlm-review-tests--source-buffer "body")))
        (unwind-protect
            (with-current-buffer source
              (consortium-rlm-review-region-ai 1 4)
              (funcall (cdr consortium-rlm-review--pending-request)
                       nil '((code . "start_failed") (details . "boom")))
              (should-not consortium-rlm-review--pending-request)
              (should-not (get-buffer
                           "*Consortium Review: consortium-review-src*")))
          (kill-buffer source)
          (consortium-rlm-review-tests--kill-generated))))))

;;; Local disposition record ----------------------------------------------

(ert-deftest consortium-rlm-review-record-appends-locally ()
  (let* ((record-dir (make-temp-file "consortium-reviews" t))
         (consortium-rlm-ui-session nil)
         (consortium-rlm-review-record-directory record-dir))
    (let ((source (consortium-rlm-review-tests--source-buffer "text to review")))
      (unwind-protect
          (with-current-buffer source
            (let ((review (consortium-rlm-review-region-manual 1 14 "grill")))
              (with-current-buffer review
                (consortium-rlm-review-record))
              (let* ((files (directory-files record-dir t "^[^.]+"))
                     (record (car files)))
                (should (= (length files) 1))
                (should (string-match-p
                         "grill"
                         (with-temp-buffer
                           (insert-file-contents record)
                           (buffer-string)))))))
        (kill-buffer source)
        (consortium-rlm-review-tests--kill-generated)
        (delete-directory record-dir t)))))

;;; Entry surface ---------------------------------------------------------

(ert-deftest consortium-rlm-review-region-entry-exists ()
  (should (functionp 'consortium-rlm-review-region))
  (should (commandp 'consortium-rlm-review-region-manual))
  (should (commandp 'consortium-rlm-review-region-ai)))

(provide 'consortium-rlm-review-tests)
;;; consortium-rlm-review-tests.el ends here
