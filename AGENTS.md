# Repository Guidelines

## Scope and safety

This repository implements an Emacs reader for the official HEY CLI. The first
release is read-only by construction: it may read HEY mailbox/application data,
but it must not expose or build commands that mutate mailbox or application
state. CLI-owned authentication refresh, credential migration, install-ID
creation, and HTTP cache updates are operational side effects, not mailbox
mutations, and must be documented accurately.

Never run an authenticated HEY command, capture live mailbox data, or inspect
private CLI caches during automated or agent-driven work. Tests must bind
`hey-executable` to the repository's fake executable and must fail closed if it
is unavailable. Synthetic or deliberately sanitized fixtures only.

## Architecture

- `hey-model.el`: pure records, normalization, sanitization, formatting.
- `hey-cli.el`: closed read-command builders and private async transport.
- `hey.el`: public entry point and list/thread presentation.

Raw JSON stops at the model boundary. UI code must not inspect CLI JSON keys.
Runtime commands are executable-plus-argv lists, never shell strings. Only
named read operations may reach the private process primitive.

## Project workflow

`docs/read-only-plan.md` is the canonical design record and `PROJECT.md` is the
live milestone tracker. Update both when an implementation decision changes.
Keep machine-specific paths and private research references in the ignored
`.project-local.md`, never in public artifacts.

Give concurrent writers disjoint path sets. The orchestrator reviews every
diff, integrates changes, and runs the relevant checks. Human approval gates in
`PROJECT.md` are not agent-completable.

## Build and test

Use `make check` as the full local gate. Narrow targets are `make test`,
`make compile`, `make lint`, `make package`, and `make install-check`.
Development and CI tests must not resolve or execute the user's installed
`hey` binary.

Emacs Lisp uses lexical binding, two-space indentation, lower-case hyphenated
symbols, and the `hey-` prefix. Public functions and variables need docstrings.
Keep package dependencies explicit and support Emacs 28.2 or newer unless a
reviewed implementation need raises the floor.

## Git and release policy

Use short imperative commit subjects and keep commits logically scoped. Do not
configure a remote, push, tag, publish, submit to MELPA, or add a legal license
grant without explicit user approval.
