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

## Approved prototype choices

- Show summary text only in the wide list layout; progressively remove it at
  narrower breakpoints.
- Show compact labels and collections with the complete values in help text.
- Mark unseen rows with a leading dot and bold subject. A posting is seen iff
  the CLI's `seen` field is literal JSON `true`; every other value is unseen.
- Follow the active Emacs theme through package-owned semantic faces that
  inherit standard faces; ship no fixed palette, fonts, or branded selection
  styling.
- Enable theme-owned buffer-local `hl-line-mode` in HEY lists by default, with
  `hey-highlight-current-row` as the public opt-out.
- Render valid posting-list timestamps in local time as `Today HH:MM`,
  `Yesterday HH:MM`, or `YYYY-MM-DD`, preserving sanitized malformed text and
  blank missing values while leaving thread timestamps unchanged.
- Give subjects the available responsive width and omit an all-empty
  memberships column until a loaded row contains a label or collection at a
  wide or medium breakpoint; omit memberships in narrower layouts.
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
      install verification, and publication approval are complete; upstream
      submission remains to be accepted by MELPA.

## Active work packets

The M6 scanability packet approved from the Modus/Elfeed comparison is complete
and passes the full local gate. Publication of v0.1.0 and a MELPA recipe is
approved. Remaining work includes human-performed authenticated
already-seen-mail validation, further evidence-driven dogfood refinement, and
MELPA review.

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
- The user approved the fake-backed list, bundle, and thread interaction on
  2026-09-03 and authorized proceeding to an already-seen-mail validation.
- The user approved theme-owned current-row highlighting, humanized dates, and
  subject-first column allocation after comparing the HEY and Elfeed views;
  date grouping and new branded colors remain intentionally excluded.
- The downstream literate Emacs configuration loads the development checkout,
  binds `C-c e` to `hey`, and passes its required batch startup smoke test.
- Public hosting is approved at `https://github.com/codingquark/hey.el` under
  the MIT License; the user approved the v0.1.0 tag and MELPA submission on
  2026-09-03.
- The archive contains exactly `hey.el`, `hey-cli.el`, `hey-model.el`,
  `LICENSE`, and a generated `hey-pkg.el` descriptor.
- Independent security review confirmed the current builders expose no mailbox
  mutation route and that prior cleanup, process-orphan, path, fake-boundary,
  and audit-bypass findings were remediated.
- No authenticated HEY command, mailbox read, or live network request was run.
