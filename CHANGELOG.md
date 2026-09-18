# Changelog

## Unreleased

- Append new list rows without rebuilding existing rows, and update request
  status separately. Reuse formatted dates until the source, local date,
  timezone, or locale changes; explicit refresh clears the date cache.
- Keep loaded threads visible during refresh, preserve message-relative reading
  positions, and show cached contents with recovery guidance after failures.
- Fontify thread bodies as they become visible and preserve metadata faces
  during later fontification.
- Cache list header counts until rows change and navigate directly between
  message boundaries. Index attachment message context once per render.
- Reduce repeated metadata, membership, and date formatting work. Deduplicate
  attachments and thread senders with hash tables while preserving their order.
- Remove Unicode C1 controls from metadata as well as raw control bytes.
- Mark one thread read with `r` in list and thread buffers. Keep opening a
  thread free of mailbox changes. Retain posting identity, update matching
  rows after acknowledgment, and check read state without moving point.
- Admit only the explicit mark-read operation through the mailbox mutation
  boundary. Exercise it with synthetic mail in tests and the demo.
- Clear mark-read progress from the header when the write finishes. Keep
  successful requests quiet and report errors in the echo area without logging.
- Redraw only rows whose read state changes. Check loaded pages until all
  pending targets have a read state, preserving point and pagination.
- Show CLI recovery hints for failed mail reads and attachment operations.
  Keep download hints out of the message log.
- Open http and https body links with `RET` through `browse-url`; show their
  destinations with `l` and copy them with `c`. Root-relative links resolve
  to the official HEY origin; non-web schemes stay inert. The `b` and `y`
  targets remain limited to the official application.
- Preserve percent-encoded destinations and handle multiline link titles.
- Echo link destinations on entry without logging them to `*Messages*`.
  Truncate long previews with an ellipsis; copy and open complete destinations.
  Suppress competing Markdown Eldoc output only in HEY thread buffers.

## 0.3.0 - 2026-09-12

- List thread attachments with `A`, including embedded files and partial-read
  notices. Save to a new local file with `s` or `RET`; cancel with `c`.
  Returning to the thread keeps downloads running. Never replace destinations.
- Require HEY CLI 1.4.3 for attachment discovery and download fixes. Local
  saving requires a filesystem supporting hard links.
- Verify the downloaded attachment's identity, path, file type, and size
  before creating the destination. Clean up temporary downloads after the
  process stops, including on failure, cancellation, timeout, or buffer death.
- Preserve the return path from attachments through the thread to the mail
  list, including repeated visits and other-window displays on Emacs 28.2
  and newer.
- Show saving in the header only while a download runs. Report start and final
  results in the echo area.
- Ignore callbacks delivered during cancellation of a superseded request.
- Deduplicate first-page rows as well as appended results.
- Restrict thread metadata styling to the preamble.
- Consolidate documentation and shorten comments and docstrings.

## 0.2.0 - 2026-09-08

- Show unread/displayed header counts at every width. Use `?` for unknown read
  state and `0/0` for an empty list.
- Give each header element a separate `hey-header-*` face with `header-line`
  as a fallback. Prioritize failure over warning and ordinary state.
- Lead headers with account or source; omit the package name.
- Leave aggregate bundle timestamps blank. Open bundles through their
  contact's seen-and-unseen thread list when a contact ID is available.
- Order columns as Subject, Sender, Labels / collections, and When. Remove
  Summary. Cap flexible Subject and Sender widths at configurable 70 and 24
  columns. Keep When subdued and right-aligned in 12 columns.
- Leave spare width after the table and a two-column gutter while column
  minimums fit. The minimal table stops shrinking at 16 columns.
- Clip memberships to their column and retain full values in help text.
- Offer `[Load more]` below lists with another page. Accept `RET`, mouse-2,
  or `M`; hide the button during requests and after exhaustion. Anchor appends
  on the last loaded row.
- Leave search read state unknown because the CLI supplies no authoritative
  `seen` field. Retain the true-only seen rule for other sources.
- Distinguish missing-CLI and configured-path failures with actionable guidance
  that omits paths and operating-system errors.

## 0.1.0 - 2026-09-03

- Establish the three-library model, transport, and read-only UI architecture.
- Add synthetic fixtures, a fake CLI, isolated checks, deterministic packaging,
  and clean-install verification. Test Emacs 28.2 and 30.2 in CI.
- Reuse bundle buffers and make demo bundles expand to readable threads.
- Publish repository metadata and the MIT License.
- Support strict Checkdoc checks across the Emacs matrix and update the pinned
  checkout action for Node 24.
- Add theme-inheriting faces and optional current-row highlighting through
  `hey-highlight-current-row`.
- Treat a posting as seen only when the CLI returns literal JSON `true`.
- Show list dates as today, yesterday, or an ISO date, with safe fallbacks.
- Split flexible wide-layout space three-to-two between Subject and Summary;
  retain truncated values in help and omit all-empty memberships.
- Generate `hey-pkg.el` from package headers instead of tracking it.
