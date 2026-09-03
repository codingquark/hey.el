# hey.el project tracker

**Status:** automated prototype complete; awaiting human UX gate; unpublished
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

## Prototype choices awaiting human approval

- Show summary text only in the wide list layout; progressively remove it at
  narrower breakpoints.
- Show compact labels and collections with the complete values in help text.
- Mark unseen rows with a leading dot and bold subject; unknown state is not
  presented as unseen.
- Open with `RET` in the same window and `o` in another window.
- Use explicit `M` for load more; resize never fetches data.
- Use `n`/`p` for posting rows and thread-entry boundaries; keep `SPC`/`DEL`
  as ordinary scrolling.
- Keep thread folding, origin-list next/previous, preview, and richer dispatch
  deferred until dogfood evidence supports them.

## Human gates

- [ ] Choose license and repository hosting/URL.
- [ ] Approve the fake-backed list/thread interaction prototype before local
      config integration or any real HEY CLI invocation.
- [ ] Approve and perform authenticated testing against already-seen mail.
- [ ] Separately approve any unseen-thread test.
- [ ] Approve public remote creation, release tag, and MELPA submission.

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
- [ ] M6: evidence-backed refinement after human prototype review and dogfood.
- [ ] M7: dogfood and user-approved publication. Package construction and clean
      install verification are complete.

## Active work packets

All implementation packets are complete. Remaining work is deliberately gated
on human interaction review, authenticated already-seen-mail validation, and
publication decisions.

## Acceptance evidence

- Parent full gate, local pinned dependency cache:
  `make EMACS=/Applications/Emacs.app/Contents/MacOS/Emacs check` — 74/74 ERT,
  strict byte compilation, checkdoc/package-lint, read-only audit, package, and
  fresh install all passed.
- Parent clean offline gate used a fresh ELPA directory plus the two documented
  checksum-pinned archive overrides — the same 74/74 and all build stages
  passed without dependency network access.
- Independent quality review rebuilt the artifact twice with identical SHA-256
  `5813ebddedb0bdd61c7e25ed9549a7c7895d803b1e51dfdf238e5d028e8229b0`.
- The archive contains exactly `hey.el`, `hey-cli.el`, `hey-model.el`, and
  `hey-pkg.el`.
- Independent security review confirmed the current builders expose no mailbox
  mutation route and that prior cleanup, process-orphan, path, fake-boundary,
  and audit-bypass findings were remediated.
- No authenticated HEY command, mailbox read, or live network request was run.
