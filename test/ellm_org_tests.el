;;; ellm_org_tests.el --- ERT tests for ELLM Org context -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Consortium contributors
;; SPDX-License-Identifier: GPL-2.0-or-later

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'ellm)
(require 'ellm-tools)
(require 'ellm-org)

(ert-deftest ellm-context-buffer-keeps-structured-provenance ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/ellm-buffer.org")
    (insert "alpha\nbeta\n")
    (let ((context (ellm-context-buffer)))
      (should (eq (alist-get 'kind context) 'buffer))
      (should (equal (alist-get 'content context) "alpha\nbeta\n"))
      (should
       (equal
        (alist-get 'file (alist-get 'source context))
        "/tmp/ellm-buffer.org"))
      (should
       (equal
        (alist-get 'buffer (alist-get 'source context))
        (buffer-name))))))

(ert-deftest ellm-context-region-uses-explicit-bounds ()
  (with-temp-buffer
    (insert "zero one two")
    (let ((context (ellm-context-region 6 9)))
      (should (eq (alist-get 'kind context) 'region))
      (should (equal (alist-get 'content context) "one"))
      (should (equal (alist-get 'bounds context) '(6 . 9))))))

(ert-deftest ellm-context-project-reuses-project-api ()
  (let ((fake-project 'fake-project))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&optional _maybe-prompt) fake-project))
              ((symbol-function 'project-root)
               (lambda (project)
                 (should (eq project fake-project))
                 "/tmp/project/"))
              ((symbol-function 'project-files)
               (lambda (project)
                 (should (eq project fake-project))
                 '("/tmp/project/a.el"
                   "/tmp/project/b.org"))))
      (let ((context (ellm-context-project)))
        (should (eq (alist-get 'kind context) 'project))
        (should (equal (alist-get 'root context) "/tmp/project/"))
        (should
         (equal
          (alist-get 'files context)
          '("a.el" "b.org")))))))

(ert-deftest ellm-context-org-subtree-uses-org-boundaries ()
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\nBody\n** Child\nChild body\n* Next\nNope\n")
    (goto-char (point-min))
    (search-forward "Body")
    (let ((context (ellm-context-org-subtree)))
      (should (eq (alist-get 'kind context) 'org-subtree))
      (should (equal (alist-get 'heading context) "Parent"))
      (should
       (equal
        (alist-get 'content context)
        "* Parent\nBody\n** Child\nChild body\n")))))

(ert-deftest ellm-context-org-document-preserves-document-text ()
  (with-temp-buffer
    (org-mode)
    (insert "#+title: Note\n\n* Heading\nBody\n")
    (let ((context (ellm-context-org-document)))
      (should (eq (alist-get 'kind context) 'org-document))
      (should (equal (alist-get 'title context) "Note"))
      (should
       (equal
        (alist-get 'content context)
        "#+title: Note\n\n* Heading\nBody\n")))))

(ert-deftest ellm-context-roam-recent-is-graceful-without-org-roam ()
  (cl-letf (((symbol-function 'ellm-org-roam-available-p)
             (lambda () nil)))
    (let ((context (ellm-context-roam-recent 7)))
      (should (eq (alist-get 'kind context) 'org-roam-recent))
      (should-not (alist-get 'available context))
      (should-not (alist-get 'documents context)))))

(ert-deftest output-org-tree-is-model-callable-and-gets-current-input ()
  (let* ((input
          '(((title . "One")
             (content . "Alpha"))
            ((title . "Two")
             (content . "Beta"))))
         (text
          (ellm-call-tool
           'output-org-tree
           '((heading . "Recent work"))
           input)))
    (should
     (equal
      text
      "* Recent work\n** One\nAlpha\n** Two\nBeta\n"))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (let ((tree (org-element-parse-buffer)))
        (should
         (equal
          (org-element-map tree 'headline
            (lambda (headline)
              (org-element-property :raw-value headline)))
          '("Recent work" "One" "Two")))))))

(ert-deftest output-org-tree-honors-explicit-input-override ()
  (let ((text
         (ellm-call-tool
          'output-org-tree
          '((input . (((title . "Override")
                       (content . "Used"))))
            (heading . "Root"))
          '(((title . "Current")
             (content . "Ignored"))))))
    (should (string-match-p "\*\* Override" text))
    (should-not (string-match-p "Current" text))))

(ert-deftest output-org-tree-insert-destination-mutates-current-buffer-explicitly ()
  (with-temp-buffer
    (let ((result
           (ellm-call-tool
            'output-org-tree
            '((heading . "Inserted")
              (destination . "insert"))
            "Body")))
      (should (equal result "* Inserted\nBody\n"))
      (should (equal (buffer-string) result)))))

(provide 'ellm-org-tests)
;;; ellm_org_tests.el ends here
