# Read-only HEY integration for Emacs

**Status:** read-only reader implemented; dogfood and MELPA submission remain
**Last updated:** 2026-09-04
**Package:** `hey` (`hey.el`)
**Scope:** read-only mail browsing only
**Repository:** <https://github.com/codingquark/hey.el>
**License:** MIT

This document records the architecture, scope, and decisions for the
Emacs-native interface to the official `hey` CLI.

## Executive decision

Build a small, carefully designed Emacs package around the official CLI, but do
not build a complete HEY client.

The first release is strictly read-only:

- select linked account;
- browse HEY mail boxes;
- search mail;
- read threads;
- use labels and collections as alternate read sources;
- copy or open validated HEY application URLs.

The package must not contain commands for composing, replying, creating drafts,
marking seen/unseen, moving, bubbling, labeling, screening, trashing, spamming,
or otherwise mutating server state.

The interface uses idiomatic Emacs text navigation, minibuffer completion,
stable buffers, responsive layouts, copy/search behavior, and predictable
window management.

The primary `hey` command opens the configured account's Imbox directly in the
list view. Account, box, label, collection, and search selection are deliberate
commands within that reading workflow, not a mandatory landing-page step.

## Why a CLI adapter

- HEY does not support IMAP or POP, so mu4e, Notmuch, Gnus, and ordinary mail
  synchronization cannot act as a HEY client.
- No maintained HEY Emacs package exists in MELPA or MELPA Stable.
- The official CLI exposes JSON envelopes, documented exit statuses, Markdown
  bodies, explicit account selection, and documented continuation controls.
- The CLI is evolving quickly, so the Emacs package must isolate its command and
  JSON contracts instead of allowing raw CLI shapes throughout the UI.

Primary sources:

- <https://github.com/basecamp/hey-cli>
- <https://github.com/basecamp/hey-cli/releases>
- <https://github.com/basecamp/hey-cli/blob/main/API-COVERAGE.md>
- <https://www.hey.com/faqs/>
- <https://melpa.org/packages/archive-contents>
- <https://stable.melpa.org/packages/archive-contents>

## Current local facts

The compatibility baseline is HEY CLI 1.4.0, release commit
`980cdc2021cbf672d4735ba0243e9a2c0568a465`. Source-contract review also used
commit `db24d024a42fa389728a152db925d705245c4fed`; its intervening changes from
the release are documentation-only.

The package supports Emacs 28.2 or newer. CI exercises Emacs 28.2 and the
current stable release, Emacs 30.2. Machine-specific binaries, checkout paths,
and private research provenance belong only in the ignored local project
ledger.

HEY CLI 1.4.0 owns an ETag revalidation cache under the platform cache
directory (commonly `~/.cache/hey-cli/http`). Every read still revalidates, and
login/logout clears the cache.

## Scope boundary

### Allowed CLI operations for the first release

Only endpoint-specific wrappers for these operations should exist:

- `hey version --json`
- `hey auth status --json`
- `hey account list --json`
- `hey box list --json`
- `hey box view ... --json`
- `hey bundle view ... --json`
- `hey search ... --json`
- `hey thread read <topic_id> --allow-partial --json`
- `hey label list --json`
- `hey label view ... --json`
- `hey collection list --json`
- `hey collection view ... --json`

`thread read` is a GET-only read path. Seen state has a separate POST endpoint,
so opening a thread in `hey` must not mark it seen. `bundle view` is admitted
because ordinary box results can contain bundle rows with no `topic_id`; it is
the read-only route to those rows' unseen child threads.

Other additive 1.4.0 read surfaces—`contact threads`, specialized
`set-aside` views, `search filters`, Screener history/listing, and attachment
metadata—stay deferred. A future milestone must add each one explicitly rather
than widening the generic runner.

### Explicitly excluded from the first release

- seen/unseen;
- move/Bubble Up and Set Aside group management;
- label, collection, or workflow mutations;
- trash/spam/ignore;
- Screener decisions;
- compose/reply/bulk-reply/forward/draft creation or sending;
- thread sharing/unsharing;
- attachment listing or download;
- contacts;
- workflows;
- clips and snippets;
- watch/notifications;
- calendar, events, todos, habits, time tracking, and HEY Journal;
- gptel/MCP access to mailbox contents;
- automatic Org or Denote synchronization.

Opening a validated `https://app.hey.com/...` URL is allowed as an explicit
handoff to the official application. A TUI launcher is deferred during the
strict read-only phase because the TUI itself exposes mutation commands.

## Architectural principles

1. **Read-only by construction.** Read-only means no HEY mailbox or
   application-state mutation. The CLI may still refresh or migrate its own
   credentials, create an install ID, update its ETag cache, record its
   last-run version, and refresh CLI-owned copies of its agent skill when the
   CLI version changes. Ordinary startup may also remove stale CLI-owned
   self-upgrade staging files and its upgrade lock. Do not add a writable
   capability flag or a generic interactive command runner. Only read endpoint
   builders exist.
2. **One representation per layer.** CLI JSON is normalized once. Views never
   inspect raw JSON keys.
3. **Pure core, effectful edge.** Command construction, normalization, and row
   rendering are pure and fixture-testable. Process and buffer operations remain
   at the edges.
4. **Buffer-local sessions.** Account, source, query, accumulated records,
   source-specific continuation state, request generation, loading state, and
   parent buffer are buffer-local.
5. **Identity, not position.** Refresh restores point by composite record key,
   then falls back to line/column.
6. **No shell strings.** Runtime commands are executable-plus-argv lists.
7. **Privacy by default.** The Emacs package adds no body cache or file
   persistence and avoids verbose logging and accidental message/search history.
   HEY CLI 1.4.0 independently keeps an ETag revalidation cache under the
   platform cache directory. It may also write a last-run-version sentinel and
   refresh installed agent-skill files that the CLI can prove it owns. The
   package must document this CLI-owned persistence rather than claiming the
   overall stack never writes to disk.
8. **One display funnel and one refresh funnel.** Window policy and refresh
   lifecycle are centralized instead of being reimplemented per command.
9. **Emacs-native, not web-layout mimicry.** Use buffers, minibuffer completion,
   familiar navigation, and optional windows—not a permanent browser-like
   sidebar.
10. **Fixture-driven development.** Contract-informed fixtures, the pure
    model/builders, and a fake asynchronous adapter validate the UI without
    live transport.

## Package dependency graph

Use three files:

```text
hey-model.el     pure records, JSON normalization, formatting
        ^
        |
hey-cli.el       closed read-command builders and async transport
        ^
        |
hey.el           public entry point plus list/thread presentation
```

`hey.el` is both the natural library loaded by `use-package hey` and the
UI/public API. This preserves the pure model/transport seams without adding a
facade whose only purpose is another `require`. Split a future UI module only
if Milestone 6 makes this file genuinely unwieldy.

Avoid dependency cycles and free references to custom variables defined in an
unloaded module. The CLI layer exposes named read operations backed by a closed
verb/flag allowlist; its generic process primitive remains private.

Repository files:

```text
hey.el
hey-cli.el
hey-model.el
test/hey-cli-test.el
test/hey-model-test.el
test/hey-test.el
test/fixtures/hey/*.json
docs/read-only-plan.md
README.md
CHANGELOG.md
LICENSE
AGENTS.md
Makefile
.github/workflows/ci.yml
```

These paths are relative to the package repository root. Keeping the libraries
there supports direct checkout loading, package building, and MELPA packaging.

Future write or calendar support must not be inserted into these files merely
for convenience. Candidate future modules are `hey-compose.el` and
`hey-calendar.el`, each requiring separate design review.

## Normalized model

Use `cl-defstruct` or similarly explicit records. Raw plists/hash tables stop at
the normalization boundary.

### Account

- stable account ID;
- display name;
- email/address when supplied;
- whether it represents all accounts.

### Source

- immutable source key derived from kind/account/source/query;
- kind: box, bundle, search, label, or collection;
- account ID;
- stable source ID/name; for boxes, command argv uses the CLI `kind` slug or
  numeric ID while the human `name` is display-only;
- display title;
- search query/filter data held only in memory;
- continuation kind and value: an opaque `next_page` string for box, bundle,
  label, and collection views, or the next positive integer page for search;
- set of continuation values already consumed, for loop detection;
- exhausted flag.

Pagination is scroll-oriented extension, not page flipping: “load more” uses
the source's continuation contract and appends another response. Box, bundle,
label, and collection views pass the returned opaque `next_page` value back
through `--page`; search generates the next positive integer `--page` value.
Refresh returns to the first response/page and replaces the accumulated
records. There is no previous-page stack.

### Posting

- composite row key, including account identity;
- account ID;
- optional posting `id` (search results can omit it when no active box item
  exists);
- optional thread `topic_id` (a bundled box posting can omit it);
- subject;
- normalized contacts/sender display;
- summary/snippet;
- created/updated time;
- seen state (`seen`, `unseen`, or `unknown`) for display only: posting
  sources which report read state are seen iff the CLI's `seen` field is
  literal JSON `true`, and every other value is unseen; sources whose rows
  carry no authoritative `seen` field, such as search, stay `unknown` rather
  than being shown as unseen;
- ordered label ID/name records from posting `folders` when supplied;
- ordered collection ID/name records when supplied;
- optional validated application URL;
- ordered matching-message metadata for search results;
- original ordering index if needed.

Every server-controlled metadata string is sanitized once during
normalization. Strip terminal escape sequences, C0/C1 controls (except the
ordinary spacing needed inside message bodies), embedded newlines from
single-line metadata, and Unicode bidi controls before values reach list rows,
headers, help text, or the package-owned Markdown scaffold. Body Markdown has a
separate containment path and is never treated as trusted metadata.

Posting ID and topic ID must never be inferred from or substituted for one
another. `thread read` accepts `topic_id` only; passing a posting `id` returns a
`not_found` error. A bundled posting without `topic_id` opens a nested
`bundle view` list using its posting `id`, and only a child posting with a
`topic_id` can open a thread.

Composite row identities are exact:

- ordinary box, bundle, label, and collection postings use
  `(account-id posting-id)` and reject rows without a posting ID;
- search rows use `(account-id topic-id)` and reject rows without a topic ID;
- the literal `all` account filter remains part of identity, because the CLI
  payload does not reliably expose the originating linked account for every
  row;
- ordering index is presentation metadata only and is never an identity
  fallback.

Normalization is source-specific:

- box, bundle, label, and collection postings map `name` to subject and use
  their posting-level contacts, summary, timestamps, seen state, labels,
  collection memberships, and app URL;
- search maps `subject` directly, requires `topic_id`, treats posting `id` as
  optional, retains all returned `messages`, and derives row sender, snippet,
  and optional app URL from the first matching message in CLI order. The CLI
  search contract exposes no authoritative `seen` field, so search read state
  stays `unknown` even if a stray `seen` value appears in a response, and
  search never shows a row it cannot corroborate as unseen. Search does not
  currently supply reliable thread labels or collection memberships; leave
  them unknown rather than issuing per-result enrichment requests. Search row
  identity is account plus `topic_id`.

### Thread and entry

The CLI's successful `thread read` envelope has a flat, oldest-first entry
array in `data`, not a thread object. Build the normalized thread by combining:

- account ID and display name, requested `topic_id`, subject, and source display
  name from the request/origin row;
- ordered unique senders derived from the returned entries;
- label and collection membership plus a known/unknown availability state from
  the origin posting;
- the ordered entries from `data`;
- a validated application URL from an entry when supplied, retained as a
  command target rather than rendered as thread metadata;
- the envelope-level partial-read notice.

Entry:

- string entry/message ID;
- sender;
- timestamp (currently minute precision without an offset; preserve it and do
  not use it to reorder the CLI's entry array);
- Markdown body;
- body state (`hydrated`, `bodyless`, `over_limit`, `failed`, etc.);
- attachment metadata for display only if later admitted to scope.

Always pass `--allow-partial` to `thread read`. It does not change the GET-only
nature of the request; it permits bounded index truncation and unreadable or
oversized individual bodies to return the readable portion plus an envelope
notice. Authentication, rate-limit, network, and server failures remain normal
failures.

Normalizers must tolerate absent keys, nulls, empty subjects, unknown boolean
representations, and additional future keys.

## CLI and process contract

### Invocation

- Resolve `hey` lazily with a configurable executable override.
- Reject remote executables and remote `default-directory` values.
- Fail closed on an unusable executable with distinct package-owned remediation:
  discovery names the CLI baseline and how to install it, restart Emacs, or set
  `hey-executable`; an unusable override names that option as what to correct or
  clear and states that no fallback is taken. Neither case borrows the other's
  remedy. Failures travel through the ordinary asynchronous `configuration`
  channel, never as a raw signal and never with a candidate path, environment
  value, or operating-system text, and the list owns the one retry affordance.
- Re-validate a resolved executable only to classify a `file-missing` from
  `make-process`: gone means it became unavailable, still valid keeps the
  generic start failure because the operating system may name the working
  directory.
- Name the CLI baseline once as `hey-cli-minimum-version` so the version
  preflight and discovery guidance cannot disagree.
- Run every subprocess from a dedicated private local working directory rather
  than inheriting the requesting buffer's `default-directory`. The directory
  stores no mail, configuration, credentials, or cache data and may remain
  empty; it exists only to keep repository-local `.hey/config.json` discovery
  independent of the current Emacs buffer.
- Expose the location as `hey-working-directory`. Choose its default through a
  platform-appropriate per-user state location; on XDG systems,
  `~/.local/state/emacs/hey/` is an example, not a hard-coded universal path.
- Ensure the directory is local, outside Git worktrees, and has no
  `.hey/config.json` in its ancestry. Create it with mode `0700` where
  supported.
  Explicit `--base-url` and `--account` flags override valid repository values,
  but a malformed local file is parsed before those flags are applied; the
  neutral working directory also protects future invocations if the CLI adds
  more repository-local settings.
- Pin `--base-url https://app.hey.com`; it is not customizable. Validated
  application URLs must use that exact HTTPS origin, with no userinfo or custom
  port.
- Pass `--account <id|all>` on every account-sensitive request.
- Never call `hey account use`.
- Add `--json` explicitly. Never emit `--quiet`, `--jq`, `--ids-only`,
  `--count`, `--markdown`, `--html`, or `--styled`; the adapter consumes one
  envelope representation and reads Markdown bodies from JSON.
- Use `make-process` with `:connection-type 'pipe` and argv lists.

### Environment

Copy `process-environment` per request, then:

- set `HEY_NONINTERACTIVE=1`;
- remove inherited `HEY_TOKEN`;
- remove inherited `HEY_BASE_URL`;
- remove inherited `HEY_ACCOUNT_ID`;
- preserve `HEY_NO_KEYRING` so users who intentionally selected the CLI's file
  credential backend keep using their stored authentication;
- remove inherited `HEY_DEBUG`;
- remove inherited `HEY_THEME`;
- remove inherited `HEY_CABLE_URL`;
- remove inherited `HEY_SETUP_AGENT`;
- rely on CLI-owned stored authentication. Removing `HEY_TOKEN` intentionally
  excludes environment-only bearer-token authentication.

Never invoke `hey auth token` and never duplicate the token into auth-source or
Emacs variables.

### Lifecycle

Each request receives:

- a unique, query-free process name;
- unique temporary stdout and stderr buffers;
- a requesting-buffer reference;
- an immutable source key;
- a monotonically increasing request generation;
- a timeout timer;
- success and failure callbacks that may complete exactly once.

Rules:

- parse ordinary JSON only on terminal `exit`/`signal` process state;
- parse a successful JSON envelope from stdout on exit zero;
- on nonzero exit, treat empty stdout plus a valid JSON error envelope on
  stderr as an ordinary CLI failure, not malformed output;
- otherwise distinguish process signal, timeout, nonzero exit without a valid
  envelope, malformed JSON, and a successful envelope;
- cancel timeout timers in the sentinel;
- kill request buffers after parsing;
- cancel requests when their owner buffer dies or changes source;
- commit a callback only when buffer, source key, and request generation still
  match;
- suppress stale or duplicate callbacks;
- never update the UI optimistically;
- retain existing rows as visibly stale during refresh and after failure;
- update “last refreshed” only after success;
- bound captured output;
- never signal a raw error from a process sentinel; return it to the owning
  interactive command/UI state.

### Diagnostics

Provide a small ephemeral `*hey-log*` buffer, but redact aggressively:

- log operation kind, duration, exit status, and error category;
- do not log stdout;
- do not log bodies;
- do not log search text;
- do not log email addresses or subjects;
- do not log the auth-status `install_id` device identifier;
- discard envelope `breadcrumbs` at normalization because they can contain
  write-command suggestions;
- discard and never log signed stream names, update channels, history/sync URLs,
  and other credentialed synchronization metadata not needed by a read view;
- do not enable `HEY_DEBUG` or `--verbose` by default.

A list or thread buffer may show a concise nonfatal banner with a command to
inspect the redacted log.

Search prompts use non-recording minibuffer history so `savehist-mode` cannot
persist queries. The active query exists only in buffer-local source state. It
must not appear in process names, diagnostics, public buffer names, or the
savehist file.

Search builders place every option before a literal `--`, followed by the
positional query, so a query beginning with a dash is data rather than a flag.

## Major-mode family

There is no need to force the list and thread buffers into a single inheritance
chain. Emacs major modes have single inheritance, while the correct parents
differ by view. Share setup functions and composed keymaps instead.

### `hey-list-mode`

Derived from `tabulated-list-mode`.

Responsibilities:

- box/bundle/search/label/collection results;
- direct package entry and asynchronous loading/error/empty states;
- responsive columns;
- compact label and collection presentation;
- stable row identity;
- source-specific cursor or numeric-page pagination;
- source/account state;
- asynchronous refresh.

### `hey-thread-mode`

Derived from `markdown-view-mode`, with `markdown-mode` required explicitly.

Responsibilities:

- generated read-only Markdown thread;
- per-entry headers and metadata;
- entry boundaries recorded with markers/text properties independent of
  Markdown heading syntax;
- navigation and folding against those boundaries, so headings inside an email
  body cannot be mistaken for HEY entries;
- links and explicit HEY handoff;
- no local file, backup, autosave, or persistent body cache.

Override inherited `q`, `n`, `p`, `SPC`, and `DEL` to honor HEY entry boundaries
and normal `quit-window` behavior. Clear the inherited `TAB` bindings until the
folding experiment is approved. Preserve an explicit path for validated link
traversal and activation.

Use a restrictive package-owned keymap instead of inheriting markdown-mode's
editing, export, preview, or external-process commands. Disable inherited mouse
link activation, remote image display, math rendering, and native code-block
fontification. Keyboard and mouse link activation both pass through the same
package validator; unsupported, local-file, remote-file, and unsafe-scheme
targets remain inert.

Both modes share a `hey-common-map` by keymap composition where practical and
use a shared display/refresh API.

The package installs no global keybindings. It exposes the public entry command
`hey` and public mode maps; the mode-local bindings below are conventional
defaults that users may override.

### Theme integration

The reader follows the active Emacs theme rather than shipping a HEY-branded
palette. It does not set fixed foregrounds, backgrounds, fonts, branded
selection styling, or variable-pitch text. Standard `tabulated-list`,
`header-line`, `hl-line`, Markdown, link, and mode-line faces remain owned by
Emacs, the user's theme, and `markdown-mode`. `hey-list-mode` enables
buffer-local `hl-line-mode` by default for a clear current row;
`hey-highlight-current-row` is the public boolean opt-out and does not define
or replace the selection face.

Package-owned semantic faces provide stable customization hooks for unseen
subjects, labels, collections, thread-subject emphasis, metadata labels,
ordinary status text, partial-result warnings, and operation failures. Each
inherits a standard Emacs face and specifies no color directly. Model-owned
row formatters define and apply row faces; the UI library defines faces used by
buffer-state rendering and thread overlays.

The public face names are `hey-unseen-face`, `hey-label-face`,
`hey-collection-face`, `hey-thread-subject-face`,
`hey-metadata-label-face`, `hey-status-face`, `hey-warning-face`, and
`hey-error-face`.

Meaning never depends on color alone: unseen mail retains its marker and
weight, collections retain the `◇` marker, and warnings and failures retain
explicit text. Changing themes or customizing a face updates existing buffers
through symbolic face properties and requires no data refresh.

## UX design

### 1. Summary/list buffer

`M-x hey` immediately creates or reuses the initial `hey-list-mode` buffer and
shows its loading state while preflight and the first page run asynchronously.
Users may assign their own global binding to `hey` in their Emacs configuration.
There is no mandatory home or account-selection buffer.

Initial selection is customizable:

- `hey-account` defaults to `nil`, meaning use the CLI's global configured
  account reported by `hey auth status --json`; repository-local and inherited
  environment account overrides are intentionally ignored;
- `"all"` or a linked account ID explicitly overrides the CLI selection for
  package requests;
- `hey-initial-box` defaults to `"imbox"`;
- after resolution, pass the account explicitly on every account-sensitive
  request;
- never prompt during ordinary startup and never silently fall back from an
  unavailable explicit account customization;
- `a` changes account for the current list session without calling
  `hey account use`, rewriting `hey-account`, or changing CLI configuration.

Account, box, label, and collection selection use ordinary `completing-read`,
gaining Vertico/Orderless behavior automatically. Fetch alternate-source
inventories only when their commands are invoked. Mail search similarly starts
from the list buffer and uses the minibuffer without persistent history.

Example status header and wide layout:

```text
HEY · Personal · Imbox · 37 shown · updated 11:42
  Date             Sender             Subject              Labels           Summary
● Today 10:31      Alice Example      Design review moved  Work, Planning   Friday works…
  Yesterday 07:56  Basecamp           Receipt for HEY      Receipts         Your receipt…

[Load more]
```

Example narrow layout:

```text
HEY · Personal · Imbox · 37 shown
  Sender              Subject                              Date
● Alice Example       Design review moved                  Today 10:31
  Basecamp            Receipt for HEY                      Yesterday 07:56

[Load more]
```

Rules:

- unseen is expressed primarily by weight plus a restrained marker, not a
  theme-dependent bright color; only an explicit `unseen` state earns that
  presentation, so a literal JSON `true` `seen` value and `unknown` read state
  both render without it;
- valid posting-list timestamps render in the user's local time as
  `Today HH:MM`, `Yesterday HH:MM`, or `YYYY-MM-DD` for older dates; missing
  values remain blank, an unparseable value falls back to its sanitized source
  text, and thread timestamps remain unchanged; the UI supplies one explicit
  clock snapshot to the pure model formatter for each complete list render;
- one logical posting per row;
- a bundled posting without `topic_id` is shown distinctly and opens its
  read-only `bundle view` child list; external URL handoff remains available
  when the posting supplies a valid application URL;
- full sender, subject, and summary values remain available through row
  help/details when visually truncated; `/` performs server search rather than
  pretending local isearch can inspect text that was not inserted;
- render posting `folders` as compact labels in a subdued face, with collection
  membership visually distinct rather than presented as another label;
- reserve trailing space for labels, compact overflow as `Receipts, Travel +2`,
  and expose the complete memberships through row details or `help-echo`;
- in the wide layout, split the flexible width three-to-two between subject and
  summary and visually truncate both with their complete values in help text;
  when all currently loaded normalized rows have no labels or collections,
  omit the memberships column and share its width between those two columns,
  restoring the column when a later loaded row has membership data; medium,
  narrow, and minimal layouts continue to give their remaining width to the
  subject, with narrow and minimal layouts omitting memberships;
- when memberships exist, they take display priority over summary: wide layouts
  add summary, narrower layouts remove it first, and only extremely narrow
  layouts may omit the compact membership column;
- never fetch per-thread metadata merely to enrich a row; search rows leave
  unavailable label and collection data empty rather than guessing or issuing
  N+1 requests;
- fixed-width breakpoints continue to select which columns appear, while the
  selected layout budgets all available width without horizontal takeover;
- choose the minimum width among visible windows showing the buffer and never
  issue a network request for resize;
- use `tabulated-list-use-header-line` nil so `tabulated-list` inserts its
  column headings as the first in-buffer line while preserving identity-aware
  `(tabulated-list-print t)` redraw;
- reserve the real, sticky `header-line-format` for account, source, row count,
  loading/stale/error state, and last successful refresh; adapt or abbreviate it
  by width and never include private search text; a source with an unconsumed
  next page contributes no status word;
- offer continuation as an in-buffer `[Load more]` text button below the table
  and its footer notices, built with the standard `button` APIs and bound to the
  same load-more funnel as `M`; show it only for loaded rows with an unconsumed
  continuation and no request in flight, anchor point on the last loaded row
  when it is pushed, and keep a failed append retryable;
- place initial point after the in-buffer column heading and make row-navigation
  commands skip every non-row status or heading line;
- local column sorting stays disabled because sorting one accumulated prefix of
  a server-paginated mailbox would be misleading;
- do not group rows by date or introduce new branded colors; humanized dates
  and theme-owned current-row highlighting provide the approved scanability
  improvements without changing navigation or pagination semantics;
- use the mode line only as a conventional fallback; do not repurpose
  `tab-line-format`, which belongs to the user's buffer/tab workflow;
- empty, loading, exhausted, partial, and failed states must be designed rather
  than represented by a blank buffer; actionable failures also appear in the
  buffer instead of existing only in the compact header.

List keys:

```text
RET       open thread in the same window
o         open thread in another window
n / p     next / previous row
g         refresh from the first source page
M         load more using the source's cursor or numeric page,
          or push the `[Load more]` control with RET / mouse-2
B         choose box
/         search
a         choose account
b         open validated HEY URL externally
y         copy validated HEY URL
?         help/dispatcher
q         quit/bury according to display context
```

`b` is explicitly an external handoff: the `hey` package remains read-only,
but the official HEY application it opens supports mutations.

No marking or batch selection exists in a read-only interface.

### 2. Thread buffer

Conceptual layout:

```text
Subject:         Design review moved
Senders:         Alice Example, Bob Example
Messages shown:  4
Account:         Personal
Opened from:     Imbox
Labels:          Work, Planning
Collections:     Product launch

────────────────────────────────────────

## Alice Example — Tue 2 Sep, 09:10
From: alice@example.net

The review has moved to Friday…

## codingquark — Tue 2 Sep, 10:31

Friday works for me…
```

Rules:

- body data comes from JSON as Markdown;
- begin with a compact, copyable metadata preamble whose stable field order is
  subject, senders, messages shown, account, origin, labels, and collections;
- borrow Denote's explicit, aligned metadata vocabulary without using literal
  Org `#+` syntax, YAML, or a Markdown table;
- call the derived entry authors `Senders`, not `Participants`, because the CLI
  does not expose complete To/Cc recipient data;
- `Messages shown` is the number of returned entries, not a claim about the
  server-side thread total; keep the partial-read notice separately visible;
- `Opened from` describes navigation provenance, such as Imbox, a label, or
  Search, and never includes private search text;
- render `none` for known-empty label or collection membership, but omit a
  membership field whose state is unknown for a search-derived or directly
  opened thread; never fetch memberships merely to complete the preamble;
- use a subdued face for metadata labels and a prominent face for the subject;
  values wrap with a hanging indent instead of being truncated;
- escape server-provided metadata before inserting it into the package-owned
  Markdown scaffold so subjects or sender names cannot forge its structure;
- use a compact sticky header such as
  `HEY · Personal · Imbox · Design review moved · 4 shown`, abbreviating or
  omitting lower-priority parts at narrow widths;
- do not render an `Open in HEY` URL or a one-off key hint in the preamble.
  `b` opens the stored validated application URL, `y` copies it, and `?` plus
  normal mode help provide consistent command discovery; unavailable URLs fail
  clearly in the echo area;
- every message has a package-owned entry boundary independent of headings
  appearing inside its Markdown body;
- links remain navigable and copyable; root-relative body links are resolved
  against the pinned base URL before activation, and unsupported schemes or
  invalid resolved URLs remain inert;
- body text behaves like ordinary Emacs text for search, copy, narrowing, and
  selection;
- keep older-message collapsing deferred until dogfood evidence supports it;
- no message is marked seen;
- body text is never written to a package cache.

Core thread keys:

```text
n / p     next / previous HEY entry
SPC / DEL scroll normally
RET       activate link at point where applicable
y         copy HEY URL
b         open HEY URL externally
q         return with `quit-window`
?         mode help
```

`TAB`/`S-TAB` folding, `M-n`/`M-p` neighboring-thread navigation, and automatic
boundary crossing by `SPC`/`DEL` remain Milestone 6 experiments and are not
bound before their interaction behavior is approved.

The origin record contains list buffer, immutable source key, composite row ID,
known label/collection memberships, and origin window. Neighbor navigation
resolves records at command time and fails clearly if the origin is gone or
stale.

### 3. Window policy

Centralize all display through `hey-display-buffer`.

Default:

- list views use the selected window;
- `RET` opens a thread in the selected window and preserves origin/point;
- `o` opens and selects the thread in another window;
- `q` calls `quit-window`, with a documented bury/kill policy;
- the display funnel takes an explicit same-window/other-window intent rather
  than interpreting prefix arguments.

A reusable preview pane is not a default. It is a Milestone 6 prototype because
Notmuch demonstrates that persistent message-window ownership creates a large
amount of lifecycle and keymap plumbing. If added, it must be opt-in and must
not rearrange unrelated user windows unexpectedly.

## Refresh and pagination

- `g` and `revert-buffer` funnel into one asynchronous refresh function.
- `tabulated-list-entries` remains a pure function over buffer-local normalized
  records; the synchronous-shaped revert hook never performs network work.
- The process callback updates records and calls `(tabulated-list-print t)`.
- A refresh re-fetches the first response for the current
  account/source/query—not the default Imbox—and replaces accumulated rows
  only after success.
- For box, bundle, label, and collection views, `M` consumes the response's
  opaque `next_page` value and appends records. Accept only a cursor returned by
  the current source session.
- For search, accept the current page reported in envelope metadata and
  generate the next positive integer `--page`; search does not return or use an
  opaque cursor. An empty result page definitively exhausts the source. `--all`
  is not used because it may fetch up to 100 pages and defeats incremental
  display.
- Cursor-paginated builders omit `--limit`: HEY CLI 1.4.0 intentionally omits
  `next_page` when an explicit limit truncates a fetched page, because that
  partial page cannot be resumed safely.
- Opaque cursors are never treated as page numbers. Reject repeated opaque
  cursors, suppress duplicate rows by composite identity on every append, and
  detect a non-advancing cursor response whose rows add no new identities.
  Numeric search pages may overlap as server results change, so deduplicate
  them by account plus `topic_id` while continuing until an empty page.
- The `[Load more]` button and `M` use the same load-more path. The button hides
  while a request is in flight.
- Point restoration uses `(tabulated-list-print t)`, which restores by row ID.
  Add window-start handling only if interactive multi-window tests require it.
- Refresh/loading errors retain stale rows and show their state; first load uses
  a non-row loading presentation.
- Do not fetch `--all` by default.
- Resize only recalculates formatting from cached normalized records.

## Buffer naming

Names must be state-derived but not derived from untrusted full subjects.
Examples:

```text
*HEY: all / Imbox*
*HEY: personal / Search*
*HEY thread: 12345*
```

Use `list-buffers-directory` or a similar display annotation for query/source
context rather than inserting private search text into globally visible buffer
names.

One source/account session should normally reuse its existing buffer. Multiple
search sessions may be unique without embedding the full search text in names.

## Development and delivery plan

Development happens in a standalone public Git repository. This is a
stage-gated execution plan for the orchestrating agent, not a promise that one
milestone equals one coding session or one commit.

The orchestrator owns architecture, integration, final verification, commit
structure, and release claims. Subagents may inspect, implement bounded
disjoint work, or review, but their completion reports are evidence to verify,
not proof by themselves.

### Repository workflow

The repository uses this MELPA-friendly layout:

```text
hey.el
hey-cli.el
hey-model.el
test/hey-test.el
test/hey-cli-test.el
test/hey-model-test.el
test/hey-test-helper.el
test/bin/hey
test/fixtures/hey/*.json
docs/read-only-plan.md
README.md
CHANGELOG.md
LICENSE
AGENTS.md
Makefile
.github/workflows/ci.yml
.elpaignore
```

This file is the canonical design record. Development may load the checkout
directly, while `make install-check` verifies the built package in an isolated
Emacs environment.

### Agent execution protocol

Every implementation work packet must name:

- its precise objective and the files it may change;
- its dependencies on unfinished work;
- the architectural and read-only invariants it must preserve;
- the tests or observable evidence required for acceptance;
- whether live HEY access is forbidden or explicitly approved.

Use read-only scouts for source and precedent inspection. Give writing agents
disjoint files or separate Git worktrees; never let two agents edit the same
implementation path concurrently. The orchestrator inspects every real diff,
reruns relevant tests, integrates logical commits, and keeps the shared branch
green. Pushes require an agreed repository and branch policy; tags, releases,
and MELPA submissions remain explicit user-approved gates.

Agents and local or remote language models may see source code plus synthetic
or deliberately sanitized fixtures. They must not receive raw mailbox bodies,
private search terms, credentials, account identifiers, or CLI caches. An
approved live capture is performed by the user or a local non-LLM script into
ignored private files, sanitized locally, and reviewed by the user before any
agent consumes or commits it.

No automated test may resolve or invoke the installed `hey` executable. Tests
bind `hey-executable` to a fake executable and fail closed if the fake is
missing. No agent may capture live fixtures, run authenticated mailbox checks,
or probe an unseen thread without explicit approval for that exact session.

Human decisions are required for:

- unresolved interaction and visual-design choices;
- any live mailbox or seen-state experiment;
- expansion of the read allowlist or any write behavior;
- the supported Emacs floor, release tags, and MELPA submission.

Track these explicitly in `PROJECT.md`. Development builds may use provisional
version and compatibility metadata, but the project must not create a release
tag or MELPA submission before those decisions are recorded.

### Milestone 0 — repository bootstrap

Create the standalone repository and establish:

- package headers, lexical binding, provided features, and an autoloaded `hey`
  entry command;
- README, changelog, contribution guidance, and repository-local
  `AGENTS.md`;
- an Emacs version policy based on APIs actually required rather than the local
  Emacs 31.1 installation alone;
- the installed HEY CLI 1.4.0 release as the compatibility target, with
  the newer pinned source checkout used only as corroborating evidence;
- declared package dependencies, including `markdown-mode`;
- an ERT runner, shared test helper, scenario-driven fake executable, and CI
  matrix for every automated process test;
- a pinned multi-file package-build workflow with an explicit runtime-file
  allowlist and a generated `hey-pkg.el` derived from the main library headers;
  the generated descriptor is not tracked, and tests, fixtures, local ledgers,
  `AGENTS.md`, Makefile, and CI files must not enter the package artifact;
- the canonical copy of this plan and fixture provenance documentation.

**Automated gate:** under isolated `emacs -Q`, load and byte-compile all three
libraries, find the `hey` autoload, and run a trivial fake-backed ERT suite.

**Orchestrator gate:** inspect the built package contents and confirm that
tests, fixtures, machine paths, and development-only files are not runtime
dependencies.

**Human gate:** confirm the public repository location, license, and supported
Emacs floor before publishing package metadata.

### Milestone 1 — executable contract, pure foundation, and fake adapter

Freeze the first implementation contract against the installed CLI version and
pinned source evidence, then implement the dependencies the prototype needs:

- normalized account, source, posting, thread, entry, continuation, and error
  representations;
- the closed executable-plus-argv allowlist;
- the asynchronous callback and envelope interface;
- success, error, cancellation, timeout, and stale-callback behavior;
- adversarial synthetic fixtures for nulls, missing and additional keys,
  malformed envelopes, partial threads, pagination, Unicode, bidi text, and
  Markdown headings inside message bodies;
- explicit records, metadata sanitization, defensive normalization, and pure
  formatting in `hey-model.el`;
- exact closed command builders in `hey-cli.el`;
- a scenario-driven fake asynchronous adapter and shared test helper. The fake
  records argv, cwd, and selected non-secret environment facts and can control
  chunking, delays, stderr, exit status, signals, and output size.

Synthetic fixtures are the default. Capture only a specific missing response
shape after user approval, sanitize it before it reaches an agent or Git, and
record only non-private CLI version and command-shape provenance.

**Automated gate:** model, builder, fixture, and fake-adapter tests pass; no
builder can construct a write operation; every spawned executable is the
absolute fake path; and a test with the fake missing fails closed rather than
falling through to the real `hey` executable.

### Milestone 2 — fake-backed interaction prototype

Build list and thread prototypes against the fake asynchronous adapter before
connecting the UI to the real transport. Exercise:

- direct loading into the configured account's Imbox;
- `B` box selection and session-local `a` account selection;
- normal postings, bundles, and loading/empty/partial/stale/error states;
- compact label and collection metadata;
- sticky list status plus in-buffer column headings;
- the aligned thread preamble, partial-thread notice, and sticky orientation
  header;
- refresh, load more, bundle expansion, thread opening, and origin-position
  restoration;
- discoverable `b`/`y` URL handoff through minimal mode help;
- narrow, medium, wide, split-window, and long-thread behavior;
- delayed and out-of-order callbacks without stale-buffer corruption.

Record every open UX question as accepted or deferred. In particular, decide
summary visibility, label width, unseen styling, same-window `RET`, thread
collapse, `SPC` boundary behavior, and explicit `M` load-more behavior. Preview
remains a later optional experiment and does not expand this milestone.

**Automated gate:** fake-backed UI exercises pass without network access, keep
identity and point stable, and issue no transport request during resize.

**Human gate:** complete the task-based review and approve the core interaction
choices. Agents may demonstrate alternatives and test mechanics but cannot
self-certify that a layout or key behavior is pleasant.

### Milestone 3 — real asynchronous transport foundation

Implement:

- the asynchronous `make-process` transport behind the already-frozen named
  read operations in `hey-cli.el`;
- request generation/source checks, cancellation, diagnostics, environment
  sanitization, neutral working directory, and output limits;
- the complete process test suite, still using only the fake executable.

Real transport work begins only after the fake-backed UI contract is approved.
UI code must never inspect raw CLI JSON, and replacing the fake adapter must not
change the accepted presentation interface.

**Automated gate:** all pure and process tests pass under isolated Emacs, byte
compilation introduces no unexplained warnings, every recorded argv is in the
read allowlist, and no test attempts real network access.

**Review gate:** an independent reviewer inspects the actual diff for routes
around the command allowlist; the orchestrator verifies the finding against the
code and tests.

### Milestone 4 — smallest complete reader

Connect the accepted UI to the real read transport for:

- CLI version, authentication, and configured-account resolution;
- direct prompt-free entry into the configured account's Imbox;
- every ordinary box through `B`;
- bundle expansion required by box rows;
- thread reading and return to the originating row identity;
- refresh and source-specific append pagination;
- partial-thread presentation;
- row label/collection display without enrichment requests;
- validated `b`/`y` URL handoff plus the help needed to discover it;
- complete loading, empty, stale, and error behavior.

Boxes, minimal help, partial-thread messaging, and URL handoff are part of this
coherent reader slice. They are not deferred or implemented again as polish.

**Automated gate:** fake-backed UI tests pass; the test harness proves it used
only the fake executable; package loading and byte compilation stay clean.

**Human gate:** after explicit approval, the user performs one authenticated
read-only session against already-seen mail and confirms list → thread →
return, bundle reading, box switching, refresh, pagination, help, and failure
recovery without a terminal. Testing an unseen thread remains separately
approved.

### Milestone 5 — remaining first-release sources

Add:

- session-local account switching;
- free-text search;
- label and collection inventories and source views;
- source-specific continuation and deduplication for every added source.

Labels and collections already appear as row metadata in Milestone 4; only
browsing them as sources is deferred here. Search continues to leave their
membership unknown rather than performing per-row enrichment.

**Automated gate:** every operation in the documented read allowlist has exact
argv, normalization, process, and buffer tests, including silent-fallback and
cross-account/source isolation cases.

**Human gate:** the user's task-based authenticated review confirms account,
search, label, and collection navigation without cross-source state leakage.

### Milestone 6 — dogfood, refinement, and publication

Implemented refinements include responsive columns, theme-owned row
highlighting, and humanized list dates. The following remain evidence-driven:

- thread folding and origin-list next/previous navigation;
- complete keyboard and accessibility review;
- customization options that solve observed needs;
- body-link refinements and optional `org-store-link` integration;
- an optional preview or richer dispatcher with its own acceptance decision.

Do not add CLI surfaces or mutation commands through refinement work. Use the
development checkout as the normal reader and fix observed defects before
adding scope.

Package construction, clean-install verification, release approval, and the
v0.1.0 tag are complete. MELPA submission waits until the repository satisfies
the public-maintenance requirement on 2026-10-03. Before submission:

- keep the supported Emacs matrix green;
- install the built package into a fresh temporary `package-user-dir` under
  `emacs -Q`;
- verify metadata, dependencies, autoloads, the Emacs floor, commentary,
  license, URL, and byte compilation;
- confirm fixtures and package files contain no private data or machine paths;
- keep installation, configuration, command, privacy, cache, troubleshooting,
  and read-only documentation current;
- revalidate the MELPA recipe.

**Gate:** checkdoc, package-lint, byte compilation, ERT, manual narrow/wide and
keyboard-only exercises, and a clean-clone package check pass.

The project stops at a stable read-only reader. Write support requires a new
design and safety review rather than another item in this delivery plan.

## Testing and validation

### Pure tests

- exact argv for every allowed operation, including box `kind` versus display
  name and the absence of forbidden output flags;
- no write verb can be built;
- JSON null/false/missing/additional-key handling;
- source-specific box/bundle/search normalization, true-only seen handling for
  posting sources, and `unknown` read state for search rows;
- posting label and collection normalization, including absent memberships in
  search results;
- posting/topic/account ID separation, including missing IDs and rejecting
  posting IDs in thread-read builders;
- flat thread-entry envelope plus origin-context assembly;
- thread preamble field ordering, sender deduplication, messages-shown count,
  known-empty versus unknown memberships, escaping, and hanging indentation;
- composite identity construction;
- date/contact/subject/summary/label formatting and compact overflow;
- absolute and root-relative URL validation;
- narrow/medium/wide row vectors;
- append continuation, exhaustion, reset, and repeated/non-advancing
  continuation behavior;
- row identity preservation after reorder/removal.

### Process tests with a fake CLI

- success envelope on stdout split across arbitrary chunks;
- malformed JSON;
- valid error envelope on stderr with empty stdout;
- unexpected stderr on both success and failure;
- exit codes 1–8 and unknown exits;
- signals and timeouts;
- stale callbacks;
- owner-buffer death;
- concurrent independent reads;
- environment sanitization;
- neutral local cwd used regardless of the requesting buffer, without
  discovering trusted or malformed repository configuration;
- dropping breadcrumbs, install IDs, and unused sync metadata;
- Unicode and leading-dash positional values;
- output limit.
- executable discovery and override failures: undiscovered `hey` and every
  unusable override class, each sanitized and failing without a search-path
  fallback or a spawned process; nil `hey-executable` discovery still driving a
  real request through the fake; process-start classification with cleanup.

### Buffer/UI tests

- mode inheritance and read-only state;
- keymaps contain no mutation commands;
- `hey` enters the configured Imbox list without an account prompt;
- nil and explicit `hey-account` values resolve correctly, and an unavailable
  explicit account does not silently fall back;
- a missing CLI reaches the list as its package-owned remediation, with the
  retry affordance contributed exactly once by the list;
- `B` invokes box selection without changing CLI configuration;
- bundle rows expand without substituting posting IDs for topic IDs;
- posting labels and collections render distinctly, compact predictably, expose
  complete memberships, and cause no per-row enrichment requests;
- wide subject and summary cells split flexible width three-to-two, truncate
  with complete help text, and keep the configured table within the window;
  the memberships column disappears only while every loaded row lacks
  memberships, and pagination can restore it without a transport request
  beyond the requested page load;
- list mode uses theme-owned buffer-local `hl-line-mode` by default and honors
  the public opt-out without changing global highlight state;
- valid list dates cover local today, calendar-day yesterday (including
  month/year boundaries), and older-date forms, while explicit offsets,
  missing values, and malformed timestamp fallbacks remain stable;
- sticky header state reflects account, source, loading/staleness, count, and
  successful refresh without exposing private search text, and the in-buffer
  `[Load more]` control tracks unconsumed continuations, hides itself while a
  request is in flight, and anchors appends on the last loaded row;
- initial point and `n`/`p` skip the in-buffer table heading and status lines;
- refresh preserves identity and visible-window behavior;
- resize changes columns without invoking transport;
- private query/subject data is excluded from buffer names and logs;
- empty/loading/error/partial state rendering;
- thread preamble and sticky-header rendering at narrow and wide widths;
- thread headings, links, body-state notices, and outline behavior;
- `b` and `y` use only a validated stored HEY URL, remain discoverable through
  mode help, and do not require rendering that URL in the thread body.

### Standalone package validation

The package repository must provide one documented command, expected to be
`make check`, that runs the same checks locally and in CI. It must cover:

1. ERT with `hey-executable` bound to the fake executable;
2. byte compilation with no unexplained warnings;
3. `checkdoc` and `package-lint`;
4. a static assertion that only closed read-operation builders reach the
   private process primitive;
5. package construction followed by installation and `(require 'hey)` under
   `emacs -Q` with a fresh temporary `package-user-dir`;
6. the minimum supported Emacs version and the current stable Emacs in CI;
7. inspection of the built artifact for private fixtures, machine paths,
   undeclared dependencies, and development-only files.

No automated test may resolve or invoke the real HEY CLI, contact a real
account, or depend on an external Emacs configuration.

Authenticated validation is a separate, explicitly approved manual session.
Use already-seen mail by default and record which read-only workflows were
exercised without retaining message content. An unseen-thread probe requires
its own approval.

## Precedents inspected

Research used disposable clones. Re-clone from the public URLs and exact
commits below when fresh source evidence is required.

### CLI-backed packages

- Himalaya Emacs: <https://github.com/dantecatalfamo/himalaya-emacs>
  - inspected commit `e308694ef60b211bad2a70c46a1566ef0b985f2e`;
  - useful small transport example;
  - reject its shared global process buffers, raw plist use throughout the UI,
    global session state, duplicate runners, and weak tests.
- Kubel: <https://github.com/abrochard/kubel>
  - inspected commit `ceb35d50e7ff736a7a707e22407cd9542bf50ffd`;
  - adopt buffer-local session ideas, process/error presentation, and
    ID-preserving redraw lessons;
  - reject shell-command strings, text-table parsing, rendered-text identity,
    and split sync/async command semantics.

### Mail/feed UX

- Elfeed: <https://github.com/emacs-elfeed/elfeed>
  - installed version 4.2.0, xref commit
    `737c1d6d2649b1ff82c5e2d2d9891a7caeac3835`;
  - clone inspected at `e61600ac3ec738b617109440304772bd02f031ba`;
  - adopt list-first entry, compact trailing tags, sticky status presentation,
    identity-based position restoration, resize-aware relayout, reader/list
    coordination, and capped-result affordances.
- Notmuch: <https://github.com/notmuch/notmuch>
  - inspected commit `f5e58cdb9b93b10ac32379b36b452532a32b8ece`;
  - adopt thread collapsing lessons; defer its home/landing-page concept unless
    a future HEY dashboard has useful aggregate information rather than links;
  - reject fixed widths and default persistent preview-pane complexity.

### Exemplary infrastructure

- Magit: <https://github.com/magit/magit>
  - inspected commit `659f89955cf60fe3d4326d881c412df06c69680d`;
  - adopt the display funnel, refresh funnel, and state-derived buffers.
- Transient: <https://github.com/magit/transient>
  - inspected commit `0cacc84ff0c7df126e194666ff8b8a1e6082e796`;
  - use only when a real dispatcher/infix need appears.
- Built-in `tabulated-list-mode` and Package Menu in Emacs 31.1;
  - chosen for row-shaped summary views and identity-aware redraw; use its
    in-buffer heading so the real header line remains available for list status.
- Built-in `vtable` in Emacs 31.1;
  - rejected as the foundation because it is not a major mode, supplies less
    refresh/window integration, and is still evolving.
- `magit-section`;
  - use only as architectural inspiration; avoid taking the dependency unless
    collapsible heterogeneous sections later prove valuable.

## Research provenance

The design incorporates prior reviews of HEY CLI 1.4.0, Himalaya, Kubel,
Elfeed, Notmuch, Magit, Transient, `tabulated-list-mode`, and `vtable` at the
pinned public commits above. Machine-specific source paths and private agent
artifact references are retained only in the ignored local project ledger.

Accepted review findings include the closed read allowlist, three-file package,
generation-plus-source race checks, append pagination, package-owned thread
entry boundaries, mode-local `RET`/`o` and `b`/`y` key conventions, private
search history, task-based async prototypes, metadata sanitization, strict link
validation, and a cautious responsive-layout experiment.

## Rejected approaches

- full HEY reimplementation;
- IMAP/Maildir bridge;
- raw HTTP calls bypassing the official CLI;
- MCP/gptel as the human mail interface;
- a mandatory home or account-selection buffer before the primary list;
- one global stateful HEY buffer;
- a global minor mode as the primary UI;
- shared stdout/stderr process buffers;
- synchronous network calls in UI paths;
- shell command strings;
- raw JSON plists in rendering code;
- subject/query-derived public buffer names;
- automatic `--all` fetching;
- polling or notifications;
- mandatory persistent three-pane layout;
- vtable as the package foundation;
- early dependency on magit-section;
- write commands hidden behind a customization toggle.

## Recovery checklist

After context loss, resume in this order:

1. Read this document completely; this copy, in the package repository, is
   canonical.
2. Read `AGENTS.md` before changing the package.
3. Inspect `git status`; do not overwrite existing dirty work.
4. Identify the last completed milestone and rerun its automated gate before
   continuing.
5. Before using CLI source as evidence, inspect a clean HEY CLI checkout, read
   its `AGENTS.md`, and record the exact commit being consulted in the ignored
   local ledger.
6. Consult "Precedents inspected" and "Research provenance" when a design
   question reopens.
7. Obtain explicit user approval before any live capture, authenticated manual
   validation, or seen-state probe. Raw mailbox data must not enter an agent or
   model context.
8. Give concurrent writers disjoint paths, and have the orchestrator inspect
   the integrated diff and rerun its tests.
9. Maintain the strict read-only allowlist through release.
