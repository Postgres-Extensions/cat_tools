# Claude Development Notes

This file contains guidance for Claude Code when working in this repository.
It is excluded from distributions via `.gitattributes export-ignore`.

## CI Monitoring After Every Push

**REQUIRED**: After every `git push`, immediately start a background task to
monitor the CI run for that push. If you pushed to both pgxntool and
pgxntool-test, start a background task for each repo — do not monitor them
sequentially.

Use `gh run watch` or poll with `gh run list` / `gh pr checks` in the
background task. Report failures to the user as soon as they are detected;
do not wait for all jobs to finish before reporting.

## Multiple Concurrent Sessions

It is common to have multiple Claude Code sessions open simultaneously across
pgxntool and pgxntool-test. To avoid cross-session interference:

**If you are asked to do something on an existing PR that you did not open or
are not already working on in this session, immediately ask for confirmation
before proceeding.** For example: "I see PR #32 exists. Were you asking me to
work on that, or did you mean to send this to a different session?"

This applies to: editing PR branches, pushing to them, closing/reopening them,
adding commits, modifying PR descriptions, or any other PR-level action.
