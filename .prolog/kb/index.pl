% Consortium durable knowledge base. One obvious loader; focused files.
% Each file owns its own relation names (SWI redefines cross-file
% predicates on load, so shared names across files are avoided here).
:- ensure_loaded('emacs_surface.pl').
:- ensure_loaded('ci_cancel_barrier.pl').
:- ensure_loaded('repo_layout.pl').
