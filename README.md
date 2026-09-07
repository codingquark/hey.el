# hey.el

`hey.el` is a read-only Emacs interface to the official HEY CLI.  It browses
boxes and bundles, searches mail, reads threads, and navigates labels and
collections without exposing mailbox mutation commands.

The project is maintained at <https://github.com/codingquark/hey.el>.

## Requirements

- Emacs 28.2 or newer
- `markdown-mode` 2.8 or newer
- HEY CLI 1.4.0 or newer

Authentication is owned by the HEY CLI.  The package does not accept or store
bearer tokens.

Box, bundle, contact-thread, label, and collection postings count as seen only
when the CLI returns literal JSON `true` in their `seen` field; `false`, `null`,
a missing field, or any other value is unseen.  Search results carry no
authoritative `seen` field, so they are presented as neither seen nor unseen.

## Installation

Until the MELPA recipe is accepted, install the current release directly from
the repository with Emacs 29 or newer:

```elisp
(package-vc-install "https://github.com/codingquark/hey.el")
```

After the recipe is accepted, refresh MELPA and run `M-x package-install RET
hey RET` (or use `:ensure t` with `use-package`).

For development, add the checkout to `load-path` and let `use-package`
discover the autoloaded entry command:

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

### Locating the HEY CLI

The CLI is resolved lazily, when a request needs it: with the default nil
`hey-executable`, `hey` is looked up in `exec-path`, so installing it after
Emacs started needs a restart or an `exec-path` update.  Set `hey-executable`
to an absolute local executable to skip that lookup; while it is set there is
no fallback to another `hey`, so a stale or mistyped override fails loudly.

When the CLI cannot be used, `M-x hey` still opens the list and names the case
that failed and what to change; press `g` to retry.  Guidance is package-owned,
so candidate paths and operating-system errors stay out of the buffer.

## Synthetic demo

After `make bootstrap`, launch the complete asynchronous reader without a HEY
installation, credentials, mailbox data, subprocess, or network access:

```sh
emacs -Q -L test/tmp/elpa/markdown-mode-2.8 -L . \
  -l test/hey-demo.el -f hey-demo
```

Useful keys are `RET`/`o` to open, `n`/`p` to move, `g` to refresh, `M` or the
`[Load more]` control at the bottom of the list to load more, `B` for boxes,
`a` for accounts, `L`/`C` for labels/collections, `/` for search, `b`/`y` for
validated HEY URLs, `?` for mode help, and `q` to return.

`make install-check` exercises a clean installation of the built package.

## Appearance

Run `M-x customize-group RET hey` to adjust the package options and faces,
including the current-row highlight.  Theme authors can customize
`hey-unseen-face`, `hey-date-face`, `hey-label-face`,
`hey-collection-face`, `hey-thread-subject-face`,
`hey-metadata-label-face`, `hey-status-face`, `hey-warning-face`, and
`hey-error-face` without replacing the list, header-line, or Markdown faces
owned by their respective modes.

Header lines add `hey-header-account-face`, `hey-header-source-face`,
`hey-header-subject-face`, `hey-header-count-face`,
`hey-header-updated-face`, `hey-header-separator-face`,
`hey-header-status-face`, `hey-header-warning-face`, and
`hey-header-error-face` for account, source, subject, row count, last
refresh, separator, and state text.  Each inherits `header-line`, which supplies
the theme's header background and other attributes as a fallback; a
meaning-bearing face ahead of it, or a custom face setting, still wins.  No
header line prints the package name; buffer names such as
`*HEY: 101 / Imbox*` and the `HEY-List` and `HEY-Thread` modes identify it.

Lists follow a Subject, Sender, Labels / collections, and When scan order.
Subject receives flexible width up to 70 columns by default; customize
`hey-list-subject-max-width` to change the cap.  Sender grows up to 24 columns;
customize `hey-list-sender-max-width` to change its cap.  Truncated subjects and
senders retain their full text in help.  The subdued When column right-aligns
today's time or a compact date inside its fixed 12 columns and sits directly
after the last content column; surplus window width stays empty to the right of
the table, which stops two columns short of the window edge while the column
floors allow it.
Bundle rows without one readable topic leave When blank: the CLI supplies one
timestamp for the aggregate, not an authoritative time for every subject joined
in that row.  `RET` uses the bundle contact's read-only thread list when
available, so already-read bundled mail remains reachable.  Summaries stay out
of rows.

When the current source has another page ready, the list offers `[Load more]`
at the bottom of the table; push it with `RET` or mouse-2, or press `M`.  The
control uses the standard `button` face, so it follows the active theme.

## Read-only and privacy boundary

The Emacs package has a closed allowlist of read operations.  It does not
provide compose, reply, draft, seen/unseen, move, label mutation, screening,
trash, spam, or other write commands.  Opening a validated HEY application URL
is an explicit handoff to the official application, where write actions may be
available.

The package adds no body cache and does not persist search text.  The CLI can
still refresh or migrate its own credentials, create an installation ID, update
its HTTP revalidation cache, record its last-run version, and refresh CLI-owned
copies of its agent `SKILL.md` when the CLI version changes.  Ordinary CLI
startup may also remove stale self-upgrade sidecar files and its lock beside
the CLI executable.  These CLI-owned operational side effects are independent
of mailbox mutation.

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
never a fallback to an installed `hey` program.  Tests which exercise a nil
`hey-executable` stub the discovery lookup.

The package target creates a deterministic multi-file tar archive in `dist/`.
Only `hey.el`, `hey-cli.el`, `hey-model.el`, `LICENSE`, and a generated
`hey-pkg.el` descriptor enter that artifact.  The descriptor is derived from
the package headers in `hey.el`; it is not tracked in the repository.

See `docs/read-only-plan.md` for the architecture, scope, security properties,
and validation rules.

## License

`hey.el` is available under the MIT License. See `LICENSE`.
