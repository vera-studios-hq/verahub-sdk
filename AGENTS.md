# VeraHub SDKs — agent and contributor guide

What the SDKs are: [README.md](README.md). This file covers how they are built.

## Layout

- The Swift package sits at the root (`Package.swift`, `Sources/`, `Tests/`), because Swift
  Package Manager reads the manifest there. The Kotlin SDK goes to `kotlin/` and the TypeScript
  SDK to `js/`, each ported from the Swift SDK against the same fixtures.
- `spec/publisher.json`: the publisher spec the SDKs are built against, copied from a
  deployment's public URL. `spec/source.json` names the VeraHub commit it came from; each release
  names it in its notes.
- `fixtures/`: JSON taken from the spec's examples, which every SDK must parse: `responses/`
  (`<operationId>.<status>.json`), `requests/` (`<operationId>.json`), and `problems/`
  (`<code>.json`). Never edit them by hand.

## The spec and the fixtures

- `scripts/sync-spec <commit> [<spec URL>]` copies the spec, records the commit, and rewrites the
  fixtures and their copy in the preview module (`Sources/VeraHubPreview/Fixtures.swift`). The
  default URL is the development deployment, which serves the newest spec.
- `scripts/fixtures --check` fails when the fixtures and the spec differ; CI runs it.
- Build against what the spec states. A route the deployment has not built answers `501`; the
  tests against a deployment pass with a note for it.

## Rules for every SDK

- Hand-written, with its own public types; the HTTP and JSON layer is internal, so it can be
  replaced without changing what apps see. Swift has no third-party dependency.
- Nothing on disk: no identifiers, events, or response cache. Storage would need publishers to be
  told first.
- The `VeraHub-Client` header carries exactly `sdk`, `os`, `app`, `build`, `device`, `locale`, and
  `tz`, as ASCII strings of at most 128 characters. A new value is announced to publishers before
  an SDK sends it.
- Every `/v1/me` request sends `VeraHub-Expected-User` with the client's `userId`, and every
  request that returns benefits names the benefit kinds the SDK can show (`benefitKinds`).
- Requests carry only fields the spec names, and leave an optional field out instead of sending
  `null`; the API refuses unknown fields.
- The token is refreshed only after `401` `user-token-expired`, once per request, with one call
  of the callback for concurrent requests. A signed-out client returns nothing, also for answers
  that arrive after the sign-out.
- Transient answers (`429`, `500`, `502`, `503`, `504`, a timeout, a lost connection) are retried
  up to three attempts; `Retry-After` is honoured up to 10 seconds, and a longer one fails the
  call.
- Offer views: one second at least half visible, once per feed load and offer, only with
  analytics consent and after the consent was sent; `sentAt` is stamped at each attempt. The
  queue is in memory, sent every 5 seconds, at 20 events, and when the app goes to the
  background; an event is dropped after 3 failed sends. Views queued before analytics consent
  was withdrawn never leave, also when it is given again, and views of a feed load more than 23
  hours old are not counted or sent (the API takes them for 24 hours).
- Ids from outside (an offer id from a deep link) are one encoded path segment; an id no offer can
  have is `offerNotFound` without a request. One list item the SDK cannot read is skipped and
  logged, not a failed page.
- Background sends (consent, events) recheck before every attempt, and abandon it when the client
  signed out, the analytics consent is withdrawn (events), or a newer consent exists (consent).
  After a transient failure or a refused token they pause for 5 seconds, doubling to 5 minutes
  (at least the `Retry-After`) until a send succeeds or the consent changes; after a permanent
  refusal (other 4xx) they stop, and drop the queue, until the consent changes.
- Logs are off by default and never contain a token or a code.

## Commands

- `scripts/check`: the quality gate, as CI runs it (fixtures, shellcheck,
  `swift format lint --strict`, a build with warnings as errors, the tests). Without Swift on
  `PATH` it runs in the official Swift image with Podman or Docker. Run it before every commit.
- `swift test --filter <Suite>/<test>`: one test.
- Untested: CI runs the tests on Linux and macOS 15 only, so the iOS 15 to 17 Foundation (date
  parsing, `URL` strictness) is compiled for but never executed.
- Tests against a deployment: set `VERAHUB_API_URL` and `VERAHUB_API_KEY` (a publisher API key of
  a test app there) and run `swift test --filter VeraHubIntegrationTests`. CI runs them against
  the development deployment, whose seeded test app's key is public on purpose, and against the
  sandbox when the `VERAHUB_SANDBOX_API_KEY` secret is set.
- `scripts/check-prefixed-tags`: proves Swift Package Manager ignores tags such as
  `android-1.4.2`; CI runs it with Xcode's toolchain.

## Versions and releases

- Semantic versioning, `0.x` while the API is in preview. The SDKs share major and minor versions,
  so a version means the same features on every platform; patch versions run per platform.
- Swift tags are bare (`0.1.0`); the other SDKs' tags carry a prefix (`android-1.4.2`,
  `js-1.4.2`). Swift Package Manager ignores tags that are not semantic versions: checked with
  Swift 6.4.2 on Linux, and by CI with Xcode on every run.
- A Swift release: set `VeraHubClient.sdkVersion`, add the version's section to `CHANGELOG.md`,
  merge, then run the Release workflow on `main` with the version. It checks both, that the tag
  is new, and that CI passed on the commit, tags it, and publishes the release with notes naming
  the spec's commit.
