# hey.el project tracker

**Status:** active local development; unpublished
**Target:** read-only HEY mail reader for Emacs
**CLI compatibility baseline:** HEY CLI 1.4.0
**Minimum Emacs:** provisionally 28.1 (required by markdown-mode 2.8)
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

## Human gates

- [ ] Choose license and repository hosting/URL.
- [ ] Approve the fake-backed list/thread interaction prototype before real
      transport is connected to the UI.
- [ ] Approve and perform authenticated testing against already-seen mail.
- [ ] Separately approve any unseen-thread test.
- [ ] Approve public remote creation, release tag, and MELPA submission.

## Milestones

- [x] Review the source plan and pinned CLI contract.
- [ ] M0: repository bootstrap, metadata, test harness, and isolated build.
- [ ] M1: frozen model/callback interfaces, pure model, closed builders,
      synthetic fixtures, and fake async adapter.
- [ ] M2: fake-backed list/thread prototype and human UX approval.
- [ ] M3: real async transport with cancellation, limits, diagnostics, and
      environment/cwd isolation.
- [ ] M4: smallest complete reader for boxes, bundles, threads, refresh,
      pagination, partial reads, URL handoff, and failure states.
- [ ] M5: account switching, search, labels, and collections.
- [ ] M6: evidence-backed layout, folding, navigation, and accessibility polish.
- [ ] M7: dogfood, package-install verification, release documentation, and
      user-approved release.

## Active work packets

1. Orchestrator: sanitize and correct the canonical plan; freeze interfaces.
2. Model writer: `hey-model.el`, model fixtures, `test/hey-model-test.el`.
3. Transport writer: `hey-cli.el`, fake executable/support, process tests.
4. UI writer: starts only after shared interfaces are frozen; `hey.el` and UI
   tests against the fake adapter.

## Acceptance evidence

Record exact commands and outcomes here at each milestone. Child-agent reports
are leads; only reviewed diffs and rerun parent tests count as completion.

