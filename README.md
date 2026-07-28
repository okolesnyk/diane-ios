# diane-ios

SwiftUI iOS app for [Diane](../diane-docs/) — the family-member remote: sign in
as yourself, see your day, check off chores and routines, spend your stars, and
get chore reminders over APNs. The wall kiosk stays the web app.

## Layout

- `project.yml` — XcodeGen manifest; `Diane.xcodeproj` is generated and
  git-ignored. Regenerate with `scripts/generate.sh` after changing it.
- `Diane/` — the app target (SwiftUI, iOS 17+).
- `DianeKit/` — local Swift package: the API client generated at build time by
  swift-openapi-generator from the vendored spec, plus hand-written glue
  (bearer middleware, Keychain session store, SSE stream client).
- `DianeKit/Sources/DianeKit/openapi.yaml` — the vendored contract, the single
  committed copy. Refresh via `scripts/update-spec.sh` (copies from a sibling
  `../diane-server` checkout, or pass a released-asset URL). Never edit it here.
- `Tests/DianeTests` — app-target unit tests (simulator).
  `DianeKit/Tests/DianeKitTests` — package tests (run on the mac host too).

## First run

```sh
brew install xcodegen
scripts/update-spec.sh
scripts/generate.sh
open Diane.xcodeproj
```

CLI build/test (also what CI runs — a breaking spec change fails generation
loudly):

```sh
xcodebuild -project Diane.xcodeproj -scheme Diane \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```

## App icon

Source artwork lives in `artwork/`; the shipped icon is generated from it:

```sh
scripts/set-app-icon.swift artwork/diane-icon.png
```

The script trims the artwork's transparent margin and drop shadow, squares
it, flattens it onto its own backdrop colour, and writes an opaque 1024pt
PNG into `Diane/Resources/Assets.xcassets/AppIcon.appiconset`. iOS draws the
rounded mask itself and rejects icons with an alpha channel, so never point
the catalog at raw artwork. Pass `--no-trim` to keep a full-bleed source
exactly as-is.

## Push notifications

Bundle id `dev.stilltesting.diane` — this is also the `APNS_TOPIC` the
server-side notifier needs. Real device pushes additionally need the Apple
Developer team set in Signing & Capabilities and the `.p8` key configured in
diane-infra (`APNS_KEY_*` — see the runbook §Notifications). The app registers
its token via `POST /api/v1/devices` after member sign-in.
