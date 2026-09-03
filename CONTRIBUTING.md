# Contributing

Read `AGENTS.md`, `PROJECT.md`, `docs/read-only-plan.md`, and
`docs/interfaces.md` before changing the package.  The design record and frozen
interfaces are part of the implementation contract.

Keep changes within the strict read-only boundary.  New CLI operations require
an explicit design review; do not add generic command runners, shell command
strings, mailbox mutations, or capability toggles that expose writes.

Never use an authenticated HEY command while developing or testing.  Do not
inspect CLI caches or add mailbox bodies, private search terms, account IDs,
credentials, or machine-specific paths to source, fixtures, logs, issues, or
commits.  Tests must use only synthetic data and the repository fake executable.

Source responsibilities are deliberately narrow:

- `hey-model.el` owns pure records, normalization, sanitization, and formatting;
- `hey-cli.el` owns closed argv builders and asynchronous transport;
- `hey.el` owns public commands and list/thread presentation.

Use lexical binding, two-space indentation, lower-case hyphenated symbols, and
the `hey-` prefix.  Public functions and variables need docstrings.  Raw JSON
must stop at the model boundary.

Before requesting review, run:

```sh
make check
```

If `markdown-mode` 2.8 is already available locally, pass its containing
directory as `MARKDOWN_MODE_DIR`.  Describe the user-visible result and the
checks you ran.  UI changes also need the relevant interactive exercise, but
authenticated testing remains a separately approved human gate.

The public repository and MIT license are approved. Do not create a release
tag or submit the package to MELPA without separate explicit approval.
