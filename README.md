# ClusterLens

ClusterLens is a native MongoDB explorer for iPhone and iPad. It connects directly to MongoDB using the wire protocol over TLS—similar to MongoDB Compass, but designed for a mobile screen.

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-111111)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![MongoDB C Driver](https://img.shields.io/badge/MongoDB%20C%20Driver-2.3.3-00ED64)

<p align="center">
  <img src="docs/clusterlens-direct-setup.png" alt="ClusterLens direct MongoDB connection screen on iPhone" width="360">
</p>

## What it does

- Connects with `mongodb://` and `mongodb+srv://` connection strings
- Keeps multiple MongoDB sessions live and switches between them from one connection manager
- Saves each connection for future launches without sending it to a ClusterLens server
- Resolves Atlas DNS SRV and TXT records directly on iOS
- Browses databases and collections, with forward-only document pages and lazy rows
- Runs `find`, `findOne`, aggregation, count, and distinct queries
- Preserves BSON types in canonical Extended JSON, including 64-bit integers, decimals, `$oid`, and `$date`
- Supports guarded insert, update, and delete operations
- Formats and copies results, with query timing and local history
- Stores every connection string in the non-synchronizing, this-device-only iOS Keychain
- Keeps query history scoped to the active connection
- Requires Face ID or the device passcode before enabling writes

## Architecture

```mermaid
flowchart LR
    A["ClusterLens on iPhone"] --> J["Multi-session coordinator"]
    J -->|"DNS SRV + TXT"| B["System DNS resolver"]
    J -->|"Independent wire-protocol sessions + TLS"| C["MongoDB clusters"]
    D["Device-only iOS Keychain"] -->|"one URI per connection"| J
    E["SwiftUI"] --> F["Small C bridge"]
    F --> G["MongoDB C Driver 2.3.3"]
    G --> H["OpenSSL 3.6.3"]
    I["Mozilla CA trust store"] --> H
```

There is no web gateway, proxy, or Atlas Data API in the connection path. The repository includes prebuilt iOS XCFrameworks for the MongoDB C driver and OpenSSL so the Xcode project builds without an extra native toolchain step. TLS peers are verified against the bundled Mozilla CA store; certificate verification is never disabled.

## On-device connection storage

ClusterLens 0.3 keeps one independent native client per live connection. Switching the active cluster does not close the other sessions, so returning to an already-connected cluster is immediate.

Each complete URI is stored under a separate random connection ID in the iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and Keychain synchronization disabled. The local profile index contains only the friendly name, hostname, SRV flag, and active ID. That index and query history use complete file protection and are excluded from device backups. ClusterLens has no account system, analytics backend, sync service, gateway, or connection-string API.

## Before connecting

1. In MongoDB Atlas, create a dedicated database user. Start with read-only access to only the databases you need.
2. In **Security → Network Access**, add the public IP currently used by the iPhone. Wi-Fi and cellular networks can have different, changing public IPs.
3. Copy the driver connection string from Atlas and replace the username and password placeholders.
4. Percent-encode reserved characters in usernames and passwords. For example, `@` becomes `%40` and `:` becomes `%3A`.

Avoid allowing `0.0.0.0/0` for normal use. It is convenient during a short test, but it exposes the cluster endpoint to connection attempts from the entire internet.

## Run the app

Requirements:

- macOS with Xcode 16 or newer
- iOS 17 or newer
- An Apple development team for installation on a physical iPhone

The generated Xcode project is included. Open `ios/ClusterLens.xcodeproj`, select your development team, choose an iPhone or Simulator, and run. Tap the connection card or server icon in Browse to add, switch, reconnect, disconnect, or remove saved connections.

To regenerate the project after editing `project.yml`:

```bash
brew install xcodegen
cd ios
xcodegen generate
open ClusterLens.xcodeproj
```

On the first screen, enter a friendly name and the complete connection string:

```text
mongodb+srv://username:password@cluster0.example.mongodb.net/?retryWrites=true&w=majority
```

## Why a connection string may fail

The most common causes are:

- **The previous app build expected a gateway URL.** Version 0.2 connects directly and accepts MongoDB connection strings.
- **Atlas Network Access does not include the iPhone's current public IP.** Add the IP used by the active Wi-Fi or cellular network.
- **The password contains reserved characters.** Percent-encode characters such as `@`, `:`, `/`, `?`, `#`, `[`, and `]`.
- **The database user or authentication database is wrong.** Verify the username, password, roles, and `authSource`.
- **The network blocks DNS SRV queries.** Try another network or use the standard multi-host `mongodb://` string provided by your cluster administrator.
- **The cluster is paused or TLS settings are incompatible.** Resume the Atlas cluster and keep TLS enabled.

The app converts driver failures into focused hints for authentication, DNS discovery, and Atlas IP allowlisting.

## Query examples

Find recent documents:

```json
{
  "filter": { "status": "active" },
  "projection": { "name": 1, "createdAt": 1 },
  "sort": { "createdAt": -1 },
  "limit": 50
}
```

Find by ObjectId:

```json
{
  "filter": {
    "_id": { "$oid": "507f1f77bcf86cd799439011" }
  }
}
```

Run an aggregation:

```json
{
  "pipeline": [
    { "$match": { "status": "active" } },
    { "$group": { "_id": "$plan", "customers": { "$sum": 1 } } },
    { "$sort": { "customers": -1 } }
  ]
}
```

Find and aggregation previews are capped at 100 documents in the native bridge. A document must fit within 1 MiB in both BSON and serialized JSON, and cursor output must fit within 4 MiB of JSON. Oversized previews fail with guidance to reduce the limit or use a projection. These are retained preview limits, not a guarantee about total app or server memory. Query input is limited to 256 KiB.

Read commands use a 10-second server execution limit. Connection selection, connection establishment, and socket waits have separate ceilings of 12, 10, and 15 seconds. These limits do not form one total deadline or guarantee immediate cancellation. Cancel read prevents queued work and discards late results; an in-flight native call must return or time out first. Aggregations cannot use `$out` or `$merge`, and do not enable disk spill.

Only the active saved profile reconnects on launch; other profiles reconnect when selected. Already live sessions remain open when switching. Both connection-string schemes require TLS and certificate/hostname verification; disabling TLS or verification is rejected.

### Paged collection browsing

Open a regular collection from Browse to start a read-only cursor sorted by `_id` ascending with simple collation. Tap **Next page** to advance, **Restart** to begin a new scan, or **Query** for filters/projections and other operations. Views and other collection types continue to open the query workbench.

Each page holds at most 20 documents and 4 MiB of serialized document JSON. The previous page is released before loading the next one; there is no growing result array, deep `skip`, or client-side range boundary. One validated lookahead document determines whether another page exists. Rows load lazily, one document expands at a time, and the expanded display previews at most 16,384 characters. **Copy document** copies the complete canonical document only when tapped.

The cursor closes on exhaustion, errors, cancellation, leaving the browser, backgrounding, or disconnect. Cancellation is cooperative: active I/O must return or time out. Failures and cursor expiry require Restart; there is no automatic query replay. This live scan is not a snapshot. Concurrent changes may produce omissions/repeats; `_id` ties across shards have server-defined tie ordering. Driver receive buffers, decoded Swift values, and temporary formatting allocations are outside the JSON byte budget. See [resource limits and validation gates](docs/production-foundation-audit.md#third-local-checkpoint--paged-collection-browsing).

### Exact numeric values

Native results use canonical Extended JSON, so BSON numeric types survive display, copying, and reuse:

```json
{ "_id": { "$numberLong": "9007199254740993" }, "amount": { "$numberDecimal": "1234567890.123456789012345678901234" } }
```

Plain integer input within the signed 64-bit range stays exact. For explicit doubles/decimals, or numbers outside the supported plain-number range, use `$numberDouble`/`$numberDecimal`. This also preserves numeric types that plain JSON cannot distinguish. Counts are returned as `$numberLong` values.

## Write safety

Write operations require all of the following:

1. the MongoDB user has the required write role;
2. writes are unlocked with Face ID or the device passcode;
3. the individual query is confirmed in the app against a captured operation, input, and connection.

Write authorization is rechecked at native dispatch. Relocking revokes queued writes; a write already accepted for dispatch may still complete. Writes relock whenever the app leaves the foreground. Update and delete require a non-empty filter; prefer a specific `_id`. Aggregation is always read-only in ClusterLens. Use a read-only MongoDB user unless mobile writes are genuinely needed.

## How the idea came to life with AI

The initial request was simple: “MongoDB Compass, but for iPhone.” AI was used as a pair programmer to shape the product, write the SwiftUI interface, generate the Xcode project, build the query model, and run the first simulator tests.

The first polished MVP was assembled in roughly **20 minutes**. After testing revealed that it accepted only a gateway URL, the app was reworked for a genuine direct connection. That revision took roughly **25 additional minutes** of active engineering: researching the available MongoDB drivers, cross-compiling the native C driver for iPhone and Simulator, adapting two unavailable iOS APIs, adding on-device SRV/TXT resolution, integrating TLS, and expanding the test suite.

The multi-connection 0.3 update added independent live clients, migration, device-only persistence, connection switching, and per-cluster history in roughly **15 more minutes**. The current version therefore represents about **60 minutes of AI-assisted active engineering**, based on the project build timestamps. The important part was not generating a screen quickly; it was validating the native networking path and being honest about the extra work required when the first architecture did not match the intended product.

## Verification

Previous revisions of the included project were validated with:

- an iPhone Simulator application build
- a physical-iPhone (`iphoneos`) compilation
- eleven passing unit tests
- verification that the app embeds and links the iOS OpenSSL framework

This foundation branch adds offline Swift checks (`scripts/test-foundation.sh`) and synthetic native bridge checks (`scripts/test-native-safety.sh`), plus a Foundation-only Swift package for XCTest-capable hosts. The current branch builds for the arm64 iOS simulator and as an unsigned Release iOS device app using Xcode 27.0. All 32 hosted XCTest tests pass on a fresh iOS 27.0 simulator. Selected synthetic iPhone/iPad browsing, filter and export workflows received manual UI QA; transport integration and physical-device validation remain open. See the [build and runtime record](docs/build-runtime-validation.md). See the [audit, validation limits, and launch gates](docs/production-foundation-audit.md).

Live cluster behavior still depends on your Atlas user, IP allowlist, DNS, and cluster configuration. Test first with a non-production cluster and a read-only account.

## Product direction

The goal is comprehensive MongoDB workflows with Compass-level usefulness and ease of use on iPhone/iPad, plus separately authorized Atlas capabilities. The current developer MVP is a foundation, not feature parity. See the [source-verified feature matrix and phased roadmap](docs/compass-atlas-roadmap.md) for implemented, partial, planned and gated workflows.

## Important status

This is a developer MVP, not an App Store release. MongoDB does not publish an official Swift driver for iOS; this project cross-compiles the current MongoDB C driver and adds an iOS-specific compatibility layer. Before production use, complete a privacy review, external security review, TestFlight testing, dependency update process, and App Store policy review.

## Dependencies and licenses

- MongoDB C Driver 2.3.3 — Apache License 2.0
- OpenSSL 3.6.3 XCFramework from `krzyzanowskim/OpenSSL-Package` — Apache License 2.0
- Mozilla CA certificate bundle distributed by curl — Mozilla Public License 2.0
- SwiftUI, LocalAuthentication, Security, and DNS-SD — Apple platform frameworks

See `THIRD_PARTY_NOTICES.md` and the vendored license files for details.

### Query, export and collection tools (foundation review branch)

The collection browser now links to a typed filter builder and raw Extended JSON filters, selectable columns, bounded JSON/CSV export with a chosen row limit, and guarded collection creation/removal. See [behavior, limits, validation and QA handoff](docs/query-export-collections.md). Selected synthetic UI workflows have been verified on iPhone/iPad simulators; complete accessibility and real transport checks remain open. An authorized physical-device update was installed and launched, without real database actions.
