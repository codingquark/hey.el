# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

- Stop presenting `/` search results as unseen. Search responses carry no
  authoritative `seen` field, so their read state is now `unknown` and their
  rows show neither the unseen marker nor `hey-unseen-face`; box, bundle,
  label, and collection postings keep the true-only seen rule.
- Explain a missing or unusable HEY CLI actionably: `exec-path` discovery names
  the CLI baseline and how to install or point at it, an invalid
  `hey-executable` says how to correct or clear it without any fallback, and a
  process-start `file-missing` is classified only after revalidating the
  resolved executable, so no path or operating-system text reaches the list.

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
