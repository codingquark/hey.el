# hey.el project tracker

**Status:** public development; awaiting human already-seen validation
**Target:** read-only HEY mail reader for Emacs
**CLI compatibility baseline:** HEY CLI 1.4.0
**Minimum Emacs:** provisionally 28.2 (the exact oldest CI target)
**Current stable CI target:** Emacs 30.2
**Local development build:** Emacs 31.1 development build

## Fixed decisions

- Read-only means no HEY mailbox or application-state mutation.
- Runtime uses only named, closed read-operation builders.
- The official origin is fixed to `https://app.hey.com` for v1.
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

## Approved prototype choices

- Show summary text only in the wide list layout; progressively remove it at
  narrower breakpoints.
- Show compact labels and collections with the complete values in help text.
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
- Render valid posting-list timestamps in local time as `Today HH:MM`,
  `Yesterday HH:MM`, or `YYYY-MM-DD`, preserving sanitized malformed text and
  blank missing values while leaving thread timestamps unchanged.
- Split wide-layout flexible width three-to-two between Subject and Summary,
  truncate both with complete help text, and omit an all-empty memberships
  column until a loaded row contains a label or collection; continue to
  prioritize subjects in narrower layouts.
- Do not add date grouping or new package-branded colors.
- Open with `RET` in the same window and `o` in another window.
- Use explicit `M` for load more; resize never fetches data.
- Use `n`/`p` for posting rows and thread-entry boundaries; keep `SPC`/`DEL`
  as ordinary scrolling.
- Keep thread folding, origin-list next/previous, preview, and richer dispatch
  deferred until dogfood evidence supports them.

## Human gates

- [x] Use the MIT License and `https://github.com/codingquark/hey.el`.
- [x] Approve the fake-backed list/thread interaction prototype before local
      config integration or any real HEY CLI invocation.
- [x] Authorize authenticated testing against already-seen mail.
- [ ] Perform authenticated testing against already-seen mail.
- [ ] Separately approve any unseen-thread test.
- [x] Approve public remote creation.
- [x] Approve the `v0.1.0` release tag and MELPA submission.

## Milestones

- [x] Review the source plan and pinned CLI contract.
- [x] M0: repository bootstrap, metadata, test harness, and isolated build.
- [x] M1: frozen model/callback interfaces, pure model, closed builders,
      synthetic fixtures, and fake async adapter.
- [x] M2 implementation: fake-backed list/thread prototype. Human approval is
      still open above.
- [x] M3: real async transport with cancellation, limits, diagnostics, and
      environment/cwd isolation.
- [x] M4 implementation: smallest complete reader for boxes, bundles, threads,
      refresh, pagination, partial reads, URL handoff, and failure states. Live
      human validation remains open.
- [x] M5 implementation: account switching, search, labels, and collections.
- [ ] M6: evidence-backed refinement after human prototype review and dogfood;
      the approved scanability packet covers current-row highlighting,
      humanized dates, and subject-first responsive columns.
- [ ] M7: dogfood and user-approved publication. Package construction, clean
      install verification, publication approval, and the v0.1.0 tag are
      complete. MELPA submission is gated until the public repository is one
      month old on 2026-10-03, then remains subject to MELPA review.

## Active work packets

The M6 scanability packet approved from the Modus/Elfeed comparison is complete
and passes the full local gate. v0.1.0 is tagged and the exact MELPA recipe is
validated. Do not open the MELPA pull request before 2026-10-03, when the
repository satisfies MELPA's one-month public-maintenance checklist item.
Remaining work includes human-performed authenticated already-seen-mail
validation, further evidence-driven dogfood refinement, and MELPA submission
and review.

## Acceptance evidence

- Parent full gate, local pinned dependency cache, rerun after the M6
  scanability packet under the local Emacs 31.1 development build:
  `make check` — 89/89 ERT,
  strict byte compilation, checkdoc/package-lint, read-only audit, package, and
  fresh install all passed.
- Parent clean offline gate used a fresh ELPA directory plus the two documented
  checksum-pinned archive overrides — the same 74/74 and all build stages
  passed without dependency network access.
- The current package artifact has SHA-256
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
- The user approved theme-owned current-row highlighting, humanized dates, and
  subject-first column allocation after comparing the HEY and Elfeed views;
  date grouping and new branded colors remain intentionally excluded.
- The user approved bounded three-to-two Subject/Summary allocation after
  wide-screen dogfood showed that either unbounded field could dominate a row.
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
- Independent security review confirmed the current builders expose no mailbox
  mutation route and that prior cleanup, process-orphan, path, fake-boundary,
  and audit-bypass findings were remediated.
- No authenticated HEY command, mailbox read, or HEY service network request
  was run.
