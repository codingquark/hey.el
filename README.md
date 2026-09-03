# hey.el

`hey.el` is a read-only Emacs interface to the official HEY CLI.  It is being
built as a focused mail reader: browse boxes and bundles, search, inspect
threads, and navigate labels or collections without exposing mailbox mutation
commands.

The project is under active local development and is not published yet.
Repository hosting and licensing are still explicit human decisions.

## Requirements

- Emacs 28.1 or newer;
- `markdown-mode` 2.8 or newer;
- the official HEY CLI, with version 1.4.0 as the initial compatibility
  baseline.

Authentication remains owned by the HEY CLI.  The package does not accept or
store bearer tokens.

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
global keybindings.

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
update its HTTP revalidation cache.  Those CLI-owned operational side effects
are independent of mailbox mutation.

## Development

The complete local gate is:

```sh
make check
```

`make bootstrap` installs the pinned `markdown-mode` 2.8 dependency and
`package-lint` into an isolated directory under `test/tmp`.  To use an existing
2.8 checkout or installation instead, provide its directory:

```sh
make MARKDOWN_MODE_DIR=/path/to/markdown-mode-2.8 check
```

Individual targets are `test`, `compile`, `lint`, `package`, and
`install-check`.  Every automated test binds `hey-executable` to the
repository's scenario-driven fake executable; a missing fake is a hard failure,
never a fallback to an installed `hey` program.

The package target creates a deterministic multi-file tar archive in `dist/`.
Only `hey.el`, `hey-cli.el`, `hey-model.el`, and `hey-pkg.el` enter that
artifact.

See `docs/read-only-plan.md` for the architecture, scope, security properties,
and milestone gates.
