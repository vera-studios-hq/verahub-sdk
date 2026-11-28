# Changelog

Each version names the publisher spec it was built against: the VeraHub commit in
`spec/source.json`.

## 0.1.0

The first preview of the Swift SDK, to build screens on sample data.

- `VeraHubClient` for one end user: offers by feed load and category, categories, the offer
  detail, coupon reveal with its result, and holdings, each list paged by the SDK.
- The user token from your callback, refreshed once when it expires; every request names the
  user, so a token of another user is refused.
- Offer views from `offerBecameVisible(_:)` and `offerBecameHidden(_:)`, with consent.
- `VeraHubPreview`: a client on sample data, with no network and no backend.
