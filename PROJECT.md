# hey.el project tracker

**Status:** public development; dogfood and MELPA submission remain
**Target:** read-only HEY mail reader for Emacs
**CLI compatibility baseline:** HEY CLI 1.4.0
**Minimum Emacs:** 28.2
**Current stable CI target:** Emacs 30.2
**Local development build:** Emacs 31.1 development build

## Fixed decisions

- Read-only means no HEY mailbox or application-state mutation.
- Runtime uses only named, closed read-operation builders.
- The official origin is fixed to `https://app.hey.com`.
- Automated work uses synthetic fixtures and the fake CLI only.
- Raw mailbox data, account identifiers, credentials, and private searches must
  not enter agent/model context or Git.
- Public artifacts contain no machine-specific absolute paths.
- The public architecture is three files: model, CLI transport, and UI.
- Search positional text follows `--` in argv.
- Server metadata is sanitized before it can reach list rows or package-owned
  Markdown scaffolding.
- CLI 1.4.0 is the minimum runtime version; startup fails visibly on older or
  malformed version responses.
- An unusable HEY executable fails closed with package-owned remediation that
  distinguishes `exec-path` discovery from a configured `hey-executable`, names
  no path or operating-system error, and never falls back from an override.

## Approved UI choices

- Order list columns as Subject, Sender, Labels / collections, and When; omit
  summaries from list rows, and keep When last at its fixed preferred width
  rather than stretching it to the window edge.
- Show compact labels and collections with the complete values in help text,
  and clip the memberships cell to its column width.
- Mark unseen rows with a leading dot and bold subject. A posting from a source
  that reports read state is seen iff the CLI's `seen` field is literal JSON
  `true`; every other value is unseen. Search results have no authoritative
  `seen` field, so their read state stays unknown and they render without
  unseen styling.
- Follow the active Emacs theme through package-owned semantic faces that
  inherit standard faces; ship no fixed palette, fonts, or branded selection
  styling.
- Enable theme-owned buffer-local `hl-line-mode` in HEY lists by default, with
  `hey-highlight-current-row` as the public opt-out.
- Render valid posting-list timestamps as `HH:MM` today, `Mon D` earlier in
  the current year, or `Mon D, YYYY` otherwise.  Leave bundle timestamps blank
  when the row has no single readable topic, because one aggregate time does
  not describe every joined subject.
  Right-align timestamps inside the fixed-width When column in
  `hey-date-face`, which inherits `shadow`, and leave thread-entry timestamps
  unchanged.
- Give Subject first claim on flexible width up to a customizable 70-column
  maximum, truncate it with complete help text, and omit an all-empty
  memberships column until a loaded row contains a label or collection.
- Let Sender grow from its responsive baseline to a customizable 24-column
  maximum and retain the complete name in help text when truncated.
- Keep the When column 12 columns wide, place it immediately after the last
  visible content column, and leave surplus window width empty to the right of
  the table.
- Reserve a two-column right gutter so an ordinary layout stops two columns
  short of the window edge.  Column floors win when a window is too narrow to
  spare it: the minimal layout stops at its irreducible 16-column width, and
  narrower windows overflow it rather than losing a column floor.
- Do not add date grouping or new package-branded colors.
- Open with `RET` in the same window and `o` in another window.
- Use explicit `M` for load more; resize never fetches data.
- Show `[Load more]` as an in-buffer standard-button control at the bottom of a
  list whenever a continuation is unconsumed; `M` remains the keyboard path to
  the same action.
- Use `n`/`p` for posting rows and thread-entry boundaries; keep `SPC`/`DEL`
  as ordinary scrolling.
- Keep thread folding, origin-list next/previous, preview, and richer dispatch
  deferred until dogfood evidence supports them.

## Human gates

- [x] Use the MIT License and `https://github.com/codingquark/hey.el`.
- [x] Approve the fake-backed list/thread interaction prototype before local
      config integration or any real HEY CLI invocation.
- [x] Authorize authenticated testing against already-seen mail.
- [x] Perform authenticated testing against already-seen mail.
- [x] Separately approve any unseen-thread test.
- [x] Approve public remote creation.
- [x] Approve the `v0.1.0` release tag and MELPA submission.

## Milestones

- [x] Review the source plan and pinned CLI contract.
- [x] M0: repository bootstrap, metadata, test harness, and isolated build.
- [x] M1: frozen model/callback interfaces, pure model, closed builders,
      synthetic fixtures, and fake async adapter.
- [x] M2 implementation: fake-backed list/thread prototype, approved above.
- [x] M3: real async transport with cancellation, limits, diagnostics, and
      environment/cwd isolation.
- [x] M4 implementation: smallest complete reader for boxes, bundles, threads,
      refresh, pagination, partial reads, URL handoff, and failure states.
- [x] M5 implementation: account switching, search, labels, and collections.
- [ ] M6: dogfood, evidence-driven refinement, and user-approved publication.
      Package construction, clean-install verification, publication approval,
      and the v0.1.0 tag are complete. MELPA submission waits until 2026-10-03,
      then remains subject to MELPA review.

## Active work

Do not open the MELPA pull request before 2026-10-03, when the repository
satisfies MELPA's one-month public-maintenance requirement.  Remaining work is
evidence-driven dogfood refinement and MELPA review.

## Ideas

Move an item to active work when starting it; remove it when complete.

## Acceptance evidence

- Parent full gate, local pinned dependency cache, rerun after the M6
  scanability packet under the local Emacs 31.1 development build:
  `make check` — 89/89 ERT,
  strict byte compilation, checkdoc/package-lint, read-only audit, package, and
  fresh install all passed.
- Parent clean offline gate used a fresh ELPA directory plus the two documented
  checksum-pinned archive overrides — the same 74/74 and all build stages
  passed without dependency network access.
- The v0.1.0 release artifact has SHA-256
  `d14a9ff8f9ad17accd0bdcd812ba439f5ddcfd78697bfe21dee63bc07a36054a`.
- A fresh clone of release commit `32e2816` passed `make check`: 89/89 ERT,
  strict byte compilation, Checkdoc/package-lint, read-only audit,
  deterministic packaging, and fresh installation. The artifact digest matched
  the primary checkout.
- GitHub Actions passed on both the release commit push and the v0.1.0 tag push.
- The exact recipe `(hey :fetcher github :repo "codingquark/hey.el" :files
  (:defaults "LICENSE"))` built successfully through MELPA's snapshots and
  releases channels. Both generated archives installed cleanly; the releases
  channel selected v0.1.0.
- MELPA's current pull-request template requires one month of maintenance in a
  public repository. This repository's history starts on 2026-09-03, so the
  recipe pull request is truthfully eligible on 2026-10-03.
- The user approved the fake-backed list, bundle, and thread interaction on
  2026-09-03 and authorized proceeding to an already-seen-mail validation.
- The user approved theme-owned current-row highlighting and humanized dates.
  On 2026-09-04, further dogfood replaced the Subject/Summary split with a
  subject-first scan order and a compact, subdued timestamp.  The same session
  then removed the window-edge anchor: When keeps its preferred width after the
  last content column, and surplus width stays empty.  Date grouping and new
  branded colors remain intentionally excluded.
- Dogfood exposed bundle rows whose joined subjects outlived the aggregate
  posting timestamp and whose unseen-only expansion returned no rows.  Bundle
  rows without one readable topic now omit the misleading When value and use
  the CLI 1.4.0 read-only contact-thread source when a contact ID is present;
  the unseen-only bundle source remains the safe fallback.
- Bundle correction packet: `make check` passed from `main` under the local
  Emacs 31.1 build (103/103 ERT, strict compile, lint, read-only audit, package,
  install).  The package artifact has SHA-256
  `c9a140c51b541d78e7b48b656727c4989fa228e74d822720715dee63f2b16641`.
- The CLI search command serializes `id`, `topic_id`, `subject`, `updated_at`,
  and matching `messages` only, so search results have no authoritative `seen`
  field. Applying the true-only rule there showed every search hit as unseen,
  contradicting the same thread in its box; search read state is therefore
  `unknown` and renders plainly. A human-performed, schema-only live probe
  confirmed that search rows omit `seen`; no mailbox content, identifiers, or
  search text were retained.
- The downstream literate Emacs configuration loads the development checkout,
  binds `C-c e` to `hey`, and passes its required batch startup smoke test.
- Public hosting is approved at `https://github.com/codingquark/hey.el` under
  the MIT License; the user approved the v0.1.0 tag and MELPA submission on
  2026-09-03.
- The archive contains exactly `hey.el`, `hey-cli.el`, `hey-model.el`,
  `LICENSE`, and a generated `hey-pkg.el` descriptor.
- Executable-discovery UX packet: `make check` passed under the local Emacs 31.1
  build (96/96 ERT, strict compile, lint, read-only audit, package, install).
  Coverage pins both remediations, the absence of fallback, spawned processes,
  path and operating-system text, start-failure classification with cleanup, and
  exactly one retry affordance in the list.
- Load-more footer packet: `make check` passed under the local Emacs 31.1 build
  (101/101 ERT, strict compile, lint, read-only audit, package, install).
  Coverage pins the header status content, bottom-of-table `[Load more]`
  placement and visibility, `RET`/mouse-2 activation, point anchoring on the
  last loaded row, and retry after a failed append.
- Subject-first list layout packet: `make check` passed under the local Emacs
  31.1 build (103/103 ERT, strict compile, lint, read-only audit, package,
  install).
  Coverage pins the subject-first responsive order, customizable Subject and
  Sender caps, compact trailing timestamp, Summary omission, and exact model
  row shapes. The package artifact has SHA-256
  `0b8425b80d771a200ccf07e64c0cefb1d7093120de8c58f04e533933ef03a4b2`.
- Bundle contact-thread packet: `make check` passed under the local Emacs 31.1
  build (105/105 ERT, strict compile, lint, read-only audit, package, install).
  Coverage pins the closed contact-thread argv, cursor contract, normalized
  contact ID, bundle fallback choice, aggregate timestamp omission, and fake
  transport boundary. The package artifact has SHA-256
  `69339e205aa4fce59cc072b5356d3ba2356f3f5e80e61df0037edd03ce3c1cd0`.
- When-column alignment packet: `make check` passed under the local Emacs 31.1
  build (109/109 ERT, strict compile, lint, read-only audit, package, install).
  Coverage pins the fixed 12-column When width across breakpoints, the
  two-column right gutter in configured widths and in rendered rows, the
  16-column irreducible minimal table, memberships cells clipped to their
  column, and capped tables that stay narrower than the window instead of
  stretching the timestamp column to the edge.
- Independent security review found no mailbox mutation route or process,
  path-disclosure, fake-boundary, or audit-bypass defect.
- Automated and agent-driven work ran no authenticated HEY command, mailbox
  read, or HEY service network request.
