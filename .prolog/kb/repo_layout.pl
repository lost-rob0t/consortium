% Repository layout and verification bookkeeping conventions that surprise
% fresh checkouts.

repo_layout(prolog_bookkeeping_tracking,
  '.prolog/facts.kb, .prolog/verify.pl, .prolog/result.json and chosen
   run journals (.prolog/runs/run-*.pl) are COMMITTED (force-added), while
   .prolog/.gitignore lists .prolog/runs/, .prolog/facts.kb and
   .prolog/verify.pl with paths that never match (gitignore entries are
   relative to the .gitignore location), so those entries are ineffective.
   Consequences: git status shows untracked ?? runs/<RunId>/ evidence
   directories and modified facts.kb/verify.pl after prolog-verify runs;
   that is expected bookkeeping, not accidental litter.  Never delete a
   ?? runs/<RunId>/ directory as cleanup; evidence.pl inside is the
   machine record for its run.  Durable .prolog/kb/** is normal tracked
   content and affects the worktree digest.').
