# Repository guidelines

## Scope and safety

Build a read-only Emacs interface to the official HEY CLI. Do not
expose mailbox or application-state mutations, generic command
runners, or options that enable writes. New CLI operations require
explicit design review.

Attachment saving may write a user-selected local file. Never replace
an existing destination. Verify the staged file before publication
and remove only request-owned staging after the process stops.

Never run authenticated HEY commands, capture live mailbox data, or
inspect private CLI caches during automated or agent-driven work.
Use synthetic or deliberately sanitized fixtures. Tests must bind
`hey-executable` to the repository fake and fail if it is unavailable;
never resolve or fall back to the installed CLI.

The CLI owns authentication and operational writes such as credential
refresh, installation IDs, and HTTP caches. Document those effects
accurately; read-only refers to mailbox and application state.

## Code

- `hey-model.el`: pure records, normalization, sanitization, formatting.
- `hey-cli.el`: closed argv builders and private async transport.
- `hey.el`: public commands and list, thread, and attachment views.

Raw JSON stops at the model boundary. UI code uses normalized records.
Runtime commands are executable-plus-argv lists, never shell strings.
Only named operations may reach the private process primitive. Keep
the official origin fixed and authentication owned by the CLI.

Keep sessions buffer-local. Check source and generation before
committing callbacks; identify rows by composite keys. Preserve
metadata sanitization, body containment, validated link activation,
and request cleanup on cancellation or nonlocal exits. Do not persist
mail bodies or search text, or log response content and arguments.

Use lexical binding, two-space indentation, lower-case hyphenated
names, and the `hey-` prefix. Declare dependencies and support Emacs
28.2 or newer unless an approved change raises the minimum.

## Prose

Follow Denote and Modus themes: direct summaries, active voice, present
tense. Start function docstrings with an imperative summary; keep
simple ones to one line. Explain data shapes and non-obvious contracts
beside the code. Comments explain purpose or rationale.

Keep usage and development instructions in `README.md`, release
history in `CHANGELOG.md`, and validation evidence in commit or review
messages. Avoid separate documents that restate code or tests. Keep
machine paths and private research in the ignored `.project-local.md`.

## Workflow

Preserve unrelated worktree changes. Give concurrent writers disjoint
paths and review the integrated diff. Run `make check` before review;
it covers tests, compilation, lint, the read-operation audit, packaging,
and clean installation. Use synthetic data for UI exercises.

Authenticated validation is a separately approved human session;
unseen-thread tests need separate approval. Agents cannot complete
human acceptance gates. Attachment user testing remains outstanding;
live updates, folding, and preview remain deferred.

Use short imperative commit subjects and logically scoped commits.
Do not configure a remote, push, tag, publish, submit to MELPA, or add
a license grant without explicit user approval. Existing approval for
the v0.1.0 release and MELPA submission does not authorize new releases.
Do not submit to MELPA before 2026-10-03; recheck eligibility then.
