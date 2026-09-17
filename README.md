# hey.el — Read HEY mail in Emacs

`hey.el` is a read-only interface to [HEY](https://www.hey.com/) through its
[official CLI](https://github.com/basecamp/hey-cli). Browse boxes, bundles,
labels, and collections; search mail; read threads; and save attachments.
Opening a thread leaves its read state unchanged.

- Package name: `hey`
- [Source code and issues](https://github.com/codingquark/hey.el)
- [Change log](CHANGELOG.md)

## Installation

The package requires Emacs 28.2 or newer, `markdown-mode` 2.8 or newer, and
HEY CLI 1.4.3 or newer. Install the CLI and sign in using the
[official instructions](https://help.hey.com/article/1189-using-ai-agents-with-hey).
Authentication belongs to the CLI; there are no tokens to configure in Emacs.

On Emacs 29 or newer, evaluate:

```elisp
(package-vc-install "https://github.com/codingquark/hey.el")
```

For Emacs 28.2 or a development checkout, install `markdown-mode` 2.8 or
newer, clone this repository, and add the following to your initialization
file, replacing `/path/to/hey.el` with the checkout's directory:

```elisp
(add-to-list 'load-path "/path/to/hey.el")
(autoload 'hey "hey" nil t)
```

## Getting started

Run `M-x hey` to open the Imbox for the account selected in the CLI. Move to
an entry with `n` or `p`, press `RET` to read it, and press `q` to return.
Use `B` to choose another box or `/` to search mail.

The package defines no global key bindings. After installation, an optional
`use-package` configuration gives the entry command a key:

```elisp
(use-package hey
  :ensure nil
  :commands hey
  :bind ("C-c h" . hey))
```

Set `hey-account` to a linked account ID or `"all"` to choose the starting
account, and `hey-initial-box` to choose the starting box. Changing accounts
with `a` affects only the current list session.

Emacs finds the `hey` executable through `exec-path`. If it cannot find the
CLI, update `exec-path` or set `hey-executable` to its absolute local path.
An invalid explicit path does not fall back to another executable. Startup
errors appear in the list buffer; press `g` to retry after correcting them.

## Reading mail

In the mail list, the following keys are available:

| Key | Command | Action |
| --- | --- | --- |
| `RET` | `hey-open` | Open the entry in this window |
| `o` | `hey-open-other-window` | Open the entry in another window |
| `n` / `p` | `hey-next-row` / `hey-previous-row` | Move between entries |
| `g` | `hey-refresh` | Fetch the list again from its first page |
| `M` | `hey-load-more` | Load the next page |
| `B` | `hey-choose-box` | Choose a box |
| `a` | `hey-choose-account` | Choose an account |
| `L` | `hey-choose-label` | Choose a label |
| `C` | `hey-choose-collection` | Choose a collection |
| `/` | `hey-search` | Search the current account |

When more results are available, the list also has a `[Load more]` button.
Activate it with `RET` or mouse-2. Opening a bundle shows its contact's seen
and unseen mail when available.

The header counts unread entries among the displayed results: `3/20` means
three unread out of twenty displayed. Search results have unknown read state
and show `?/20`; an empty list shows `0/0`. Outside search, mail counts as
seen only when the CLI explicitly reports it as seen.

In a thread, `n` and `p` move between messages, `SPC` and `DEL` scroll, and
`A` lists the thread's attachments. The following keys act on body links:

| Key | Command | Action |
| --- | --- | --- |
| `RET` | `hey-follow-link` | Open the link at point |
| `l` | `hey-show-link` | Show the link destination in the echo area |
| `c` | `hey-copy-link` | Copy the link destination |

The destination also appears when point enters a link. Long echo previews
end with an ellipsis; copying and opening always use the complete destination.
Customize `hey-link-echo-max-width` to change the 80-column preview limit;
narrow windows reduce it further. Root-relative links resolve to
`https://app.hey.com`; non-web schemes stay inert.

Both list and thread buffers provide `b` to open the corresponding HEY URL,
`y` to copy it, `q` to return, and `?` for mode help. These URLs stay limited
to the official HEY application, where you can reply or make other mailbox
changes.

## Saving attachments

Press `A` in a loaded thread to see its attachments, then `s` or `RET` to
save the selected file. Choose a new local destination: saving never replaces
an existing file, directory, or symlink, and does not open the saved file.

In the attachment list, `g` refreshes, `c` cancels a download, and `q` returns
to the thread while the download continues. Killing the attachment buffer
cancels its download. The header shows when saving is active, and the echo
area reports the result.

Saving requires a filesystem that supports hard links. Downloads use a
temporary `.hey-attachment-*` directory beside the destination, which is
removed after completion or cancellation. A crash may leave this directory
behind. The timeout is 120 seconds; customize
`hey-attachment-save-timeout-seconds` to change it.

## Customization

Run `M-x customize-group RET hey RET` to browse the options and faces. Use
`C-h v` to read an option's documentation.

Lists show Subject, Sender, Labels / collections, and When. Narrow windows
omit memberships; the smallest layout keeps Subject and When. Customize
`hey-list-subject-max-width` and `hey-list-sender-max-width` to change the
column widths of 70 and 24. Truncated values remain available in
help text. Dates show today's time or a compact date; bundles without a
single topic leave the date blank.

Faces inherit from the active theme. Customize `hey-unseen-face`,
`hey-date-face`, `hey-label-face`, and `hey-collection-face` for list entries,
`hey-thread-subject-face` for thread headings, and the `hey-header-*` faces
for header elements. Unseen and collection markers convey meaning alongside
color. Set `hey-highlight-current-row` to nil to disable the row highlight.

## Privacy

`hey.el` reads mailbox and application state without changing it. Saving an
attachment writes a local file at your request. The package adds no mail
body cache, does not persist search text, and neither accepts nor stores
bearer tokens.

The package never fetches body links or previews their destinations.
Opening a link delegates to `browse-url`. Echoed link destinations stay out
of the `*Messages*` log.

The CLI manages its own authentication and operational files. It can refresh
or migrate credentials, create an installation ID, update its HTTP cache,
record its last-run version, refresh CLI-owned agent skills after an upgrade,
and remove stale self-upgrade files and locks. Read-only access to your
mailbox does not prevent these CLI-owned writes.

## Development

Run the full check before submitting a change:

```sh
make check
```

This runs tests, byte compilation, lint, the read-operation audit, packaging,
and a clean installation check. Tests use synthetic fixtures and the
repository's fake CLI. A missing fake is an error; tests never fall back to
an installed `hey`. CLI compatibility is checked against its source and
fixtures. Authenticated validation is a separate human check, and attachment
user testing remains outstanding.

`make bootstrap` installs checksum-pinned `markdown-mode` 2.8 and
`package-lint` 0.26 under `test/tmp`. To use an existing Markdown installation,
pass `MARKDOWN_MODE_DIR=/path/to/markdown-mode-2.8`. For an offline bootstrap,
set `MARKDOWN_MODE_ARCHIVE` and `PACKAGE_LINT_ARCHIVE` to the archives specified
in `tools/bootstrap.el`; checksum verification still applies. Set `EMACS` to
choose an Emacs executable.

Individual targets are `test`, `compile`, `lint`, `read-only-check`, `package`,
and `install-check`. The package archive in `dist/` contains the three runtime
libraries, `LICENSE`, and a generated `hey-pkg.el` derived from the headers in
`hey.el`.

To try the interface with sample mail, run this from the checkout after
`make bootstrap`:

```sh
emacs -Q -L test/tmp/elpa/markdown-mode-2.8 -L . \
  -l test/hey-demo.el -f hey-demo
```

The demo needs no HEY installation or credentials and uses no subprocesses or
network. It lists sample attachments but does not save them.

Read [AGENTS.md](AGENTS.md) for contribution guidelines. Include Emacs and
HEY CLI versions in bug reports, and use synthetic or sanitized examples
instead of private mail.

## License

`hey.el` is available under the [MIT License](LICENSE).
