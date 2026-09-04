# Internal interfaces

This document defines the frozen seams between the three libraries. Changes to
these names or callback shapes require orchestrator review.

## JSON representation

The CLI layer parses JSON with string-keyed alists, lists for arrays, `nil` for
JSON null, and the symbol `hey-json-false` for JSON false. Raw alists never
cross into `hey.el`; model normalizers are the only consumers.

## Model records

`hey-model.el` provides these `cl-defstruct` types and generated accessors:

- `hey-account`: `id name email all-p`
- `hey-auth-status`: `authenticated account-id`
- `hey-version`: `version source`
- `hey-source`: `key kind account-id id title query continuation-kind
  continuation consumed exhausted current-page`
- `hey-membership`: `id name`
- `hey-match`: `id sender timestamp summary app-url`
- `hey-posting`: `key kind account-id id topic-id contact-id subject contacts
  summary timestamp seen labels collections app-url matches original-index`
- `hey-entry`: `id sender timestamp body summary body-state app-url`
- `hey-thread`: `account-id account-name topic-id subject source-title senders
  labels labels-known-p collections collections-known-p entries app-url notice`
- `hey-error`: `category message code hint exit-status`

Posting read state is source-specific. Box, bundle, contact-thread, label, and
collection postings are binary: the model normalizes a posting to `seen` only
when the CLI's `seen` field is literal JSON `true`; JSON `false`, `null`, a missing
field, or any other value normalizes to `unseen`. Search results carry no
authoritative `seen` field, so a search posting always normalizes to `unknown`
even when a stray `seen` value is present. Only explicit `unseen` receives the
unseen list presentation.

Required public pure functions:

- `hey-model-sanitize-metadata STRING`
- `hey-model-validate-app-url STRING`
- `hey-model-resolve-body-url STRING`
- `hey-model-normalize-accounts ENVELOPE`
- `hey-model-normalize-auth-status ENVELOPE`
- `hey-model-normalize-version ENVELOPE`
- `hey-model-normalize-boxes ENVELOPE ACCOUNT-ID`
- `hey-model-normalize-labels ENVELOPE ACCOUNT-ID`
- `hey-model-normalize-collections ENVELOPE ACCOUNT-ID`
- `hey-model-normalize-postings ENVELOPE SOURCE`
- `hey-model-normalize-thread ENVELOPE CONTEXT`
- `hey-model-envelope-notice ENVELOPE`
- `hey-model-format-memberships MEMBERSHIPS MAX-WIDTH`
- `hey-model-format-posting-timestamp TIMESTAMP NOW`
- `hey-model-posting-row POSTING LAYOUT`
- `hey-model-thread-markdown THREAD`

`LAYOUT` is one of four symbols with these exact vector shapes:

- `wide`: `[date sender subject memberships summary]`
- `medium`: `[date sender subject memberships]`
- `narrow`: `[sender subject memberships date]`
- `minimal`: `[sender subject date]`

The memberships cell lists labels first and collections with distinct
presentation; its `help-echo` exposes the complete untruncated memberships.
`hey-model-format-posting-timestamp` requires an explicit `NOW` value so the
model remains pure; the UI supplies one clock snapshot for a complete list
render.

`CONTEXT` for thread normalization is a plist containing only normalized
origin data: `:account-id`, `:account-name`, `:topic-id`, `:subject`,
`:source-title`, `:labels`, `:labels-known-p`, `:collections`, and
`:collections-known-p`.

Posting identities are `(ACCOUNT-ID POSTING-ID)` for box/bundle/contact-thread/
label/collection results and `(ACCOUNT-ID TOPIC-ID)` for search. Malformed records
missing the required ID are omitted and reported through a returned warning
list rather than assigned a positional identity. Normalizers return a plist
with `:value` and `:warnings` so malformed input remains non-fatal.

## Command builders

`hey-cli.el` provides pure builders returning argv without the executable:

- `hey-cli-build-version`
- `hey-cli-build-auth-status`
- `hey-cli-build-account-list`
- `hey-cli-build-box-list ACCOUNT-ID`
- `hey-cli-build-box-view ACCOUNT-ID BOX &optional PAGE`
- `hey-cli-build-bundle-view ACCOUNT-ID POSTING-ID &optional PAGE`
- `hey-cli-build-contact-threads ACCOUNT-ID CONTACT-ID &optional PAGE`
- `hey-cli-build-search ACCOUNT-ID QUERY &optional PAGE`
- `hey-cli-build-thread-read ACCOUNT-ID TOPIC-ID`
- `hey-cli-build-label-list ACCOUNT-ID`
- `hey-cli-build-label-view ACCOUNT-ID LABEL-ID &optional PAGE`
- `hey-cli-build-collection-list ACCOUNT-ID`
- `hey-cli-build-collection-view ACCOUNT-ID COLLECTION-ID &optional PAGE`

All builders pin the exact official origin and add `--json`. Account-sensitive
builders add an explicit account. Search emits every flag before `-- QUERY`.
IDs and cursors are validated data strings; no public generic builder exists.

## Async transport

The UI calls named functions with this common tail:

```elisp
(OWNER SOURCE-KEY GENERATION SUCCESS FAILURE)
```

Operation-specific arguments precede that tail. `SUCCESS` receives one parsed
success envelope. `FAILURE` receives one `hey-error`. Completion happens at
most once and only while `OWNER` is live. UI source/generation matching remains
the UI's final commit check as well.

Named functions mirror every builder, without `build-`, for example
`hey-cli-box-view` and `hey-cli-thread-read`. The private
`hey-cli--start-process` is the only real subprocess primitive. Tests and the
synthetic demo override named operations, never the private primitive.

## UI session state

List buffers hold buffer-local `hey--account`, `hey--source`, `hey--records`,
`hey--generation`, `hey--request`, `hey--loading`, `hey--stale`,
`hey--last-refreshed`, and `hey--error`. Thread buffers hold one normalized
thread plus an origin plist. Public buffer names never contain subjects or
queries.

The UI has one `hey--refresh` funnel and one `hey-display-buffer` funnel. It
uses only normalized records and named CLI operations.
