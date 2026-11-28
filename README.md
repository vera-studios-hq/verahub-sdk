# VeraHub SDKs

The SDKs for apps that show VeraHub offers: the Swift SDK for iOS, with Kotlin for Android and
TypeScript to follow in this repository.

> **Preview.** Versions `0.x` follow the publisher API while it is being built, and can change
> between minor versions. Routes not built yet answer `501`.

## Swift

iOS 15 or later, Xcode 16 or later. No third-party dependencies, and nothing written to disk.

### Add the package

In Xcode, **File › Add Package Dependencies…**, enter
`https://github.com/vera-studios-hq/verahub-sdk`, and add:

- `VeraHub` to your app target;
- `VeraHubPreview`, sample data for building screens without a backend, where you build and
  preview them. It does not belong in the app you release.

With `Package.swift`:

```swift
.package(url: "https://github.com/vera-studios-hq/verahub-sdk", from: "0.1.0"),
```

### Build a screen on sample data

`VeraHubPreview` gives you a client that answers from sample offers, categories, and holdings,
with no network and no token. Its codes start with `PREVIEW-` and work in no shop.

```swift
import SwiftUI
import VeraHub
import VeraHubPreview

struct OfferList: View {
  let client: VeraHubClient
  @State private var feed: PagedList<Offer>?
  @State private var offers: [Offer] = []

  var body: some View {
    List(offers) { offer in
      VStack(alignment: .leading) {
        Text(offer.brand.name).font(.headline)
        Text(offer.valueText)
        Text(offer.title)
      }
      .onAppear { client.offerBecameVisible(offer) }
      .onDisappear { client.offerBecameHidden(offer) }
    }
    .task { await loadFirstPage() }
    .refreshable { await loadFirstPage() }
  }

  private func loadFirstPage() async {
    let feed = client.offers()
    self.feed = feed
    offers = (try? await feed.loadNext()) ?? []
  }
}

#Preview {
  OfferList(client: VeraHubPreview().client)
}
```

`onAppear` stands in for your own visibility detection here: report an offer visible when at
least half of it is on screen, and hidden when less than half is.

### Create the client for a signed-in user

Your app never holds a VeraHub API key. Your backend asks VeraHub for a user token with its key
(`POST /v1/user-tokens`) and passes it to your app; the client asks for one through a callback.

```swift
let client = VeraHubClient(
  environment: .sandbox,
  userId: user.id,
  consent: Consent(analytics: user.allowsAnalytics, personalisation: user.allowsPersonalisation)
) { userId in
  try await myBackend.verahubToken(for: userId)
}
```

- Create one client per signed-in user and keep it. When the user signs out or another user
  signs in, call `client.signOut()` and create a new client.
- The client asks your callback for a token when it starts (it sends the consent then), when
  VeraHub says the token expired, and again, with growing pauses for its own background sends,
  after VeraHub refused a token or the callback threw. Every request names the `userId`, and VeraHub refuses a token of
  another user, so one user never sees another's codes.
- Pass consent changes with `client.updateConsent(_:)`. Without analytics consent, no offer view
  leaves the device; a send under way stops at its next attempt when the consent is withdrawn or
  the user signs out.
- Use `.sandbox` while you build and test, `.production` in the app you release; the tokens must
  come from the same environment.

### Offers, categories, and the detail

```swift
let feed = client.offers(category: "sports-outdoors")   // a new feed load
let firstPage = try await feed.loadNext()
if await !feed.isComplete {
  let nextPage = try await feed.loadNext()               // the SDK keeps the cursor
}

let categories = try await client.categories()           // hide those with offerCount 0
let detail = try await client.offerDetail(for: offer)    // also offerDetail(offerId:) for a deep link
```

Report each offer of a list with `offerBecameVisible(_:)` and `offerBecameHidden(_:)`. An offer
visible for one second counts as one view, once per feed load; the SDK keeps the timer, sends the
views in batches, and drops them when the user has not given analytics consent. When VeraHub or
the connection fails, it sends again after pauses growing from 5 seconds to 5 minutes; when VeraHub
refuses the consent or the views for good, it stops sending until the consent changes.

### Reveal a coupon

```swift
switch try await client.reveal(benefit) {
case .revealed(let holding, _), .alreadyHeld(let holding, _):
  show(code: holding.coupon?.code, clickOut: holding.clickOut)
case .cooldown(let holding, let nextRevealAt):
  show(code: holding.coupon?.code, newCodeFrom: nextRevealAt)
case .unavailable(let reason):
  showUnavailable(reason)                                // soldOut, limitReached(until:), …
}

let holdings = client.holdings()                         // what the user holds, newest first
let firstHoldings = try await holdings.loadNext()
```

Open a click-out URL unaltered in the system browser or an in-app browser tab
(`SFSafariViewController`), never in a web view.

### Errors

Calls throw `VeraHubError`; branch on its `kind`:

| Kind                 | What happened                                                         |
| -------------------- | --------------------------------------------------------------------- |
| `noConnection`       | The device is offline.                                                |
| `serviceUnavailable` | VeraHub cannot answer now, also after retrying.                       |
| `signedOut`          | The client was signed out; create a new one.                          |
| `userDeleted`        | Your backend deleted the user at VeraHub.                             |
| `userMismatch`       | The token callback returned a token of another user; nothing shown.   |
| `offerNotFound`      | The offer or benefit is no longer listed; reload.                     |
| `sdkUnsupported`     | This SDK version is no longer served; update it.                      |
| `misconfigured`      | An invalid `userId`, or tokens of another environment.                |
| `unexpected`         | An answer this SDK version does not understand; quote the request id. |

Its `message` is for developers; show users your own words. An error your token callback throws
is rethrown unchanged. A reveal that gives no code is a result, not an error.

To see what the SDK does, pass `logLevel: .info` (or `.debug`) and filter the console for the
subsystem `io.verahub.sdk`. Logs never contain a token or a code.

## Versions

The SDKs use semantic versioning. Swift releases are tagged `x.y.z`; the other SDKs' tags carry a
prefix (`android-x.y.z`), which Swift Package Manager ignores. Each release names the publisher
spec it was built against: `spec/source.json` in the repository, and the release notes.

## Licence

MIT, see [LICENSE](LICENSE).
