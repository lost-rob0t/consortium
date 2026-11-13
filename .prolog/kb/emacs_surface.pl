% Emacs surface knowledge: verified, reusable project facts.

architecture(region_review_surface,
  'emacs/consortium-rlm-review.el: region -> transient offering a manual
   rubric path (static local checklist data from ponytail-review/grill/
   impeccable; zero AI; works with the daemon fully off) and an AI path
   (budgeted daemon run through consortium-rlm-ui-connect with recorded
   run-id lineage; findings render anchored in their own org buffer).
   The AI path wraps the session event hook once and restores the prior
   hook when the reviewed run finishes; forwarding to the saved hook
   keeps approval/question prompts working during review runs.  Source
   buffers are never mutated; nothing auto-posts; dispositions record
   locally through consortium-rlm-review-record as org files.').

discovery(unwind_protect_byte_compile_warning,
  'A byte-compile warning "`unwind-protect\' without unwind forms" means
   the cleanup forms were parsed as siblings of the unwind-protect, not
   forms of it: one closing paren too many on the body form consumed the
   unwind-protect itself.  check-parens and total-balance scans still pass
   because the file balances overall.  To see the form the compiler really
   has, advise byte-compile-warn-x around byte-compile-file and print the
   POS argument; then fix the specific closing-paren count on the body
   form''s last line.  Seen while writing test/consortium-rlm-review-tests.el.').
