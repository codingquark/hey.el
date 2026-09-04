# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Leave the date blank for bundle rows without one readable topic because one
  aggregate timestamp does not describe every joined subject.  Open them
  through the contact's read-only thread list when possible, including mail
  that the unseen-only bundle endpoint no longer returns.
- Show `[Load more]` below lists with another page.  `RET` or mouse-2 activates
  the control; `M` remains available.  The control hides during requests and
  after exhaustion, and activation keeps point on the last loaded row.
- Render `/` search results without seen or unseen styling because search
  responses have no authoritative `seen` field.  Other posting sources retain
  the true-only seen rule.
- Report a missing or unusable HEY CLI with package-owned guidance.  Discovery
  and configured-path failures remain distinct, and no candidate path or
  operating-system text reaches the list.

## 0.1.0 - 2026-09-03

- Establish the standalone three-library package structure.
- Add normalized model, closed read-command transport, and read-only UI seams.
- Add synthetic fixtures and a scenario-driven fake HEY executable.
- Add isolated test, compile, lint, deterministic package, and install checks.
- Add an Emacs 28.2 and 30.2 continuous-integration matrix.
- Reuse bundle buffers and make the synthetic bundle expand to readable
  threads instead of recursively producing another bundle.
- Publish project metadata and package licensing under the MIT License.
- Keep strict Checkdoc failures compatible with every supported Emacs target.
- Update the pinned checkout action to its Node 24-compatible release.
- Add theme-native semantic faces without imposing a package color palette.
- Treat a posting as seen only when the CLI's `seen` field is literal true.
- Highlight the current list row with the theme's `hl-line` face by default,
  with `hey-highlight-current-row` as the public opt-out.
- Humanize posting-list dates in local time as today, yesterday, or an ISO
  calendar date while retaining safe fallbacks for missing and malformed
  timestamps.
- Split wide-layout flexible width three-to-two between Subject and Summary,
  truncate both with complete help text, and omit the memberships column when
  every loaded row has no memberships.
- Generate package descriptors from `hey.el` metadata instead of tracking
  `hey-pkg.el`, matching MELPA packaging conventions.
