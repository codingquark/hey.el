# hey.el

`hey.el` is a read-only Emacs interface to the official HEY CLI.  It is being
built as a focused mail reader: browse boxes and bundles, search, inspect
threads, and navigate labels or collections without exposing mailbox mutation
commands.

The project is under active development at
<https://github.com/codingquark/hey.el>. It is not released to MELPA yet.

## Requirements

- Emacs 28.2 or newer (provisional until the release gate);
- `markdown-mode` 2.8 or newer;
- the official HEY CLI, with version 1.4.0 as the initial compatibility
  baseline.

Authentication remains owned by the HEY CLI.  The package does not accept or
store bearer tokens.

A posting is seen only when the CLI returns literal JSON `true` in its `seen`
field. `false`, `null`, a missing field, or any other value is shown as unseen.

## Development-checkout installation

Add the checkout to `load-path` and let `use-package` discover the autoloaded
entry command:

```elisp
(add-to-list 'load-path (expand-file-name "/path/to/hey.el"))

(use-package hey
  :ensure nil
  :commands hey)
```

Run `M-x hey` to open the configured account's Imbox.  The package installs no
global keybindings.  Startup requires HEY CLI 1.4.0 or newer and presents a
buffer-local error when authentication, account selection, or the version
preflight fails.

## Synthetic prototype review

After `make bootstrap`, launch the complete asynchronous reader without a HEY
installation, credentials, mailbox data, subprocess, or network access:

```sh
emacs -Q -L test/tmp/elpa/markdown-mode-2.8 -L . \
  -l test/hey-demo.el -f hey-demo
```

Useful keys are `RET`/`o` to open, `n`/`p` to move, `g` to refresh, `M` to load
more, `B` for boxes, `a` for accounts, `L`/`C` for labels/collections, `/` for
search, `b`/`y` for validated HEY URLs, `?` for mode help, and `q` to return.

A clean built-package installation is exercised by `make install-check`; it is
separate from this convenient checkout workflow.

## Read-only and privacy boundary

The Emacs package has a closed allowlist of read operations.  It does not
provide compose, reply, draft, seen/unseen, move, label mutation, screening,
trash, spam, or other write commands.  Opening a validated HEY application URL
is an explicit handoff to the official application, where write actions may be
available.

The package adds no body cache and does not persist search text.  The CLI can
still refresh or migrate its own credentials, create an installation ID, and
update its HTTP revalidation cache.  HEY CLI 1.4.0 also records its last-run
version and may refresh CLI-owned copies of its agent `SKILL.md` after a
successful command when the CLI version changes.  Ordinary CLI startup may
also remove its own stale self-upgrade sidecar files and lock beside the CLI
executable.  Those CLI-owned operational side effects are independent of
mailbox mutation.

## Development

The complete local gate is:

```sh
make check
```

`make bootstrap` installs checksum-pinned `markdown-mode` 2.8 and
`package-lint` 0.26 artifacts into an isolated directory under `test/tmp`.
To use an existing 2.8 checkout or installation instead, provide its directory:

```sh
make MARKDOWN_MODE_DIR=/path/to/markdown-mode-2.8 check
```

For an offline clean bootstrap, set `MARKDOWN_MODE_ARCHIVE` and
`PACKAGE_LINT_ARCHIVE` to the exact archives named in `tools/bootstrap.el`;
their pinned SHA-256 digests are still enforced.

Individual targets are `test`, `compile`, `lint`, `package`, and
`install-check`.  Every automated test binds `hey-executable` to the
repository's scenario-driven fake executable; a missing fake is a hard failure,
never a fallback to an installed `hey` program.

The package target creates a deterministic multi-file tar archive in `dist/`.
Only `hey.el`, `hey-cli.el`, `hey-model.el`, `hey-pkg.el`, and `LICENSE` enter
that artifact.

See `docs/read-only-plan.md` for the architecture, scope, security properties,
and milestone gates.

## License

`hey.el` is available under the MIT License. See `LICENSE`.
