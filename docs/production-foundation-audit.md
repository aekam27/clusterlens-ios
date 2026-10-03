# Production foundation audit — 2026-10-03

## Scope and direction

Inspected public `origin/main` at `d6f0919` (merged multi-connection workspace), including SwiftUI, session coordination, the C bridge, Keychain storage, DNS expansion, tests, vendored headers, and native build script. The original checkout was clean and was left untouched. Changes are isolated on `codex/production-foundation` in a separate checkout. No database connections, Keychain reads, production queries, public pushes, or paid services were used during this work.

The product target is now a comprehensive mobile MongoDB client with Compass-level usefulness and separately scoped Atlas capabilities. Direct database access and safe read-only defaults remain foundations; they do not exclude editing, administration, analysis or bulk workflows. See the [verified feature matrix and phased roadmap](compass-atlas-roadmap.md). “Scale” means handling large collections without loading them wholesale, bounded retained results, a controlled number of live connections, and reliable repeated foreground/background sessions. It does not mean a hosted service, multi-tenancy, or an asserted database throughput level.

The first implementation step was a dependable collection browser with explicit bounds, cursor pagination, expandable document rows and clear connection/error states. The roadmap now expands to comprehensive query/edit/admin/analysis workflows with deliberate write safeguards. A SaaS backend is not implied by that goal; Atlas cloud administration needs a separately authorized integration.

## Findings and this iteration

| Priority | Evidence in baseline | Change / remaining limit |
| --- | --- | --- |
| Critical | `QueryOperation.aggregate.isWrite` is false; `cl_mongo_execute` submitted arbitrary pipelines. `$out`/`$merge` could write without the write unlock or confirmation. | Reject `$out`/`$merge` recursively in Swift and native BSON before driver execution. Aggregation stays read-only, even when writes are unlocked. Conservative key inspection also rejects these keys in literal data. |
| High | `MongoConnectionString.expanded` preserved `tls=false`; the bridge configured a CA only when TLS was already enabled and accepted verification bypass options. | Add TLS before DNS work for both schemes; reject disabling TLS or certificate/hostname/revocation checks. Repeat enforcement after native URI parsing. Always use the bundled CA. Plaintext local servers are intentionally unsupported. |
| High | A document-count limit did not bound byte size. Distinct and single-document replies had no serialization budget. | Reject individual BSON or expanded JSON over 1 MiB; reject cursor JSON over 4 MiB. Apply document budget to findOne, distinct, and write replies as well. Oversized responses fail explicitly without returning a partial successful preview. Driver receive buffers and temporary JSON allocations remain outside this budget. |
| High | No socket timeout or server execution limit; URI values could request unlimited/very long waits. | Selection/connect/socket ceilings are 12/10/15 seconds; smaller positive URI values are retained. Read commands get `maxTimeMS:10000`; find/aggregate/collection-list cursors request batches of 20. Aggregation uses `allowDiskUse:false`. These are separate limits, not a total wall-clock deadline. |
| High | `reconnect` could publish after disconnect/removal; refresh could overwrite another session's error; an authentication completion could re-enable writes after relock. | Token-check reconnect completions, invalidate before disconnect/removal, discard stale refresh completions, and generation-check authentication. Failed credential deletion leaves the profile visible with an error. Full lifecycle injection tests remain a gate. |
| Medium | Startup reconnected every saved profile concurrently. | Reconnect only the active profile at launch; others reconnect when selected. Already live sessions remain live when switching. No hard live-session ceiling or idle eviction yet. |
| Medium | Missing/malformed write filters fell back to `{}` and could mutate an arbitrary first match. | Update/delete require a non-empty object filter at both boundaries. This does not prove uniqueness; specific `_id` filters remain recommended. |
| Medium | History and query entry had count limits but no input byte budget. | Reject encoded query input above 256 KiB, with an editor check before JSON decoding. Existing history files are not migrated or trimmed by bytes. |
| Medium | UI showed a single pretty-printed result without a bounded-preview label. | Add explicit preview copy for find/aggregate and clear old results before a new query. Pagination and virtualized document rows remain future work. |

## Architecture findings and launch gates

1. **Exact BSON value preservation — addressed in the follow-up:** native results now use canonical Extended JSON and plain signed-64-bit integer input uses `Int64`. Numeric fixtures pass through BSON → Swift formatting → BSON with type/bit comparisons. Wider plain-number input is rejected with Extended JSON guidance. Device/UI validation and broader BSON-type fixtures remain release gates.
2. **Session lifetime and cancellation:** the actor serializes handle access, but synchronous C networking occupies a cooperative executor thread. Task cancellation checks prevent starting already-cancelled work; Cancel read now discards late results before Swift decoding and keeps the workbench busy until native work returns. These checks do not interrupt an active driver call. DNS has a 10-second timeout but no cancellation handler, and the current compiler warns about a non-Sendable DNS context capture. Introduce a dedicated blocking executor, injectable client/auth/storage protocols, cancellable DNS, total operation deadlines, and stale-result tests across backgrounding/removal. Do not destroy a native handle from another thread while it is executing.
3. **Write authorization at dispatch — addressed in the follow-up:** confirmations capture immutable operation/input/connection data and a revocable one-shot permit is consumed immediately before native dispatch. Relock, switch, removal, and active reconnect revoke pending authorization. Revocation cannot undo a dispatch already accepted. Test the complete SwiftUI/background/authentication flow on devices; host fixtures cover snapshot mismatch, replay, relock, and connection/generation mismatch. Never automatically retry writes after an ambiguous socket failure. MongoDB least-privilege roles remain necessary.
4. **Bounded browsing — first implementation in the third checkpoint:** regular collection browsing now uses a retained cursor, explicit closure, `_id` ascending/simple collation, one current page, lazy rows and one expanded document. There is no `skip` or requery-based continuation. Filtered paging, snapshot/read-concern policy, indexing guidance and device memory/UI measurements remain gates. Count, distinct, sort, and group can still be expensive on the server despite small output. Add explain/index guidance and projection help. Database/collection lists currently stop at 500/2,000 entries without continuation.
5. **Connections and repeated sessions:** measure simultaneous sessions and set an evidence-based live-session ceiling/idle eviction policy. Test airplane mode, cellular/Wi-Fi transitions, TLS failures, SRV changes, foreground/background loops, disconnect during connect, and repeated connect/remove cycles. Do not claim a supported session count without measurements.
6. **Credential/storage review:** device-only, non-synchronizing Keychain and protected, backup-excluded metadata/history are good foundations. History may contain sensitive filter/document values. Add opt-out/retention controls and byte limits. Audit native logging and error messages for credentials/query content. Review malformed URI parsing, IPv6 display, SRV record termination and parent-domain edge cases. Some persistence errors are still ignored. The bundled Mozilla CA file needs an update policy; it is not the platform trust store.
7. **Dependencies/build:** versions in this checkout are C driver 2.3.3 and OpenSSL 3.6.3. The OpenSSL download is checksum-checked, but reproducible native artifacts, immutable source provenance, security advisory monitoring, CA freshness checks, and an SBOM/update owner remain launch gates. No dependency version bump was attempted. Current native script builds only arm64 simulator/device driver slices; validate any Intel simulator requirement separately. Preserve upstream license notices.
8. **Release validation:** require a clean iOS simulator/device build, the complete XCTest suite, UI and accessibility QA on iPhone/iPad, leak/RSS measurements, transport integration tests with a synthetic local TLS fixture, denied-write-role tests, and an external security/privacy review. TestFlight/App Store policy/privacy work follows these gates; nothing was submitted or installed here.

## Current build/runtime status

The earlier toolchain blocker below is resolved. Xcode 27.0 (27A266a) was available outside the default developer-tool search location; initial toolchain discovery was incomplete. The baseline app built and passed 21 hosted XCTest tests. The synthetic QA iteration passes 23 tests and an unsigned Release device build. Partial iPhone UI QA is complete. See [current evidence and remaining gates](build-runtime-validation.md). Earlier paragraphs are historical verification records, not the current build status.

## Initial verification on this host

- Native bridge: six synthetic test groups pass with `-Wall -Wextra -Werror`, AddressSanitizer, and UndefinedBehaviorSanitizer on the bridge/test translation unit. Cases cover nested aggregation writes, TLS settings/timeout bounds, BSON and expanded JSON sizes, exact total-byte boundary, a 101-document synthetic cursor capped at 100, and early rejection before native client use. The locally built dependency libraries themselves were not sanitizer-instrumented.
- The native harness uses the existing driver 2.3.3 source, copied into the ignored workspace build directory. Host libraries were built with TLS transport disabled, and no valid query was sent to a server. This verifies policy and serialization, not TLS handshakes or the vendored iOS binaries.
- `scripts/test-foundation.sh`: executable Swift fixture checks for TLS, aggregation/filter rules, connection attempt invalidation, query templates/Extended JSON, and synthetic SRV option handling. No XCTest runtime, Keychain, or network access is needed.
- The coordinator, direct client, persistence wrapper, and Foundation sources typecheck using the installed macOS SDK. Swift parsing and C syntax checks also pass; these are not iOS application builds. Existing DNS Sendable warnings remain.
- Full XCTest is blocked: `unable to resolve module dependency: 'XCTest'`. Xcode build/simulator QA is blocked: active developer directory is `/Library/Developer/CommandLineTools`; `xcodebuild` reports that Xcode is required. No Xcode app is installed in `/Applications`. Earlier README build/test claims describe previous work, not verification of this branch.

## Reproduce

```bash
# macOS Command Line Tools, no downloads or server required:
scripts/test-foundation.sh

# Existing MongoDB C Driver 2.3.3 source; local build only:
CLUSTERLENS_DRIVER_SOURCE=/path/to/mongo-c-driver scripts/test-native-safety.sh

# On a host with Xcode/XCTest:
swift test
xcodebuild -project ios/ClusterLens.xcodeproj -scheme ClusterLens \
  -destination 'platform=iOS Simulator,name=<installed simulator>' test
```

The Swift package tests Foundation policies only; the Xcode project remains the actual app build. The native test script does not fetch dependencies, modify vendored frameworks, or install system packages.

## Proposed milestones (no deadline estimate)

1. Land these bounded safety changes after review and Xcode verification.
2. Make lifecycle and write authorization testable; close cancellation, lossless BSON, and immutable-confirmation gates.
3. Build paged read-only browsing and measure memory/UI behavior on synthetic large collections/documents.
4. Validate networking, privacy, dependencies, and release readiness on devices before any production-data pilot.

Reference: MongoDB's [C driver TLS documentation](https://www.mongodb.com/docs/languages/c/c-driver/current/libmongoc/guides/configuring_tls/) explains the native certificate and hostname validation controls. Implementation was checked against the vendored 2.3.3 headers and matching local source rather than assuming a newer API.

## Resumed checkpoint verification

After the Mac reconnected, the saved diff was reviewed and the offline Swift/native checks, model/client typecheck, native header syntax check, and whitespace check were repeated successfully. At that earlier checkpoint, Xcode had not yet been discovered (resolved above). Final review removed `batchSize` from `listDatabases`, whose reply is an array rather than a server cursor. No app/simulator or TLS-handshake validation is implied by the host checks.

## Second local checkpoint — exact values and query dispatch

- Canonical Extended JSON preserves int32/int64, Decimal128, double (including negative zero and NaN), and date values at the native/Swift boundary. Plain integer editor values use `Int64`, including values above 2^53. Numbers outside the supported plain-number range require an explicit Extended JSON wrapper; no implicit large-number rounding is allowed on that decode path.
- The workbench prepares an immutable request before presenting confirmation. The coordinator checks the current connection and authorization generation; the client consumes a revocable, one-shot permit immediately before calling the C bridge. No lock is held during networking. This defines the dispatch boundary: a write accepted before revocation may still complete.
- Read cancellation prevents queued calls and discards results returned after cancellation before Swift decoding. It does not close the handle from another thread, interrupt synchronous I/O, or promise rollback. Writes have no Cancel button and acknowledged outcomes are retained.
- No cursor pagination was added in this iteration: preserving numeric IDs and exact confirmed queries was a prerequisite. Paging, result virtualization, a dedicated blocking executor, cancellable DNS, and a measured session budget remain the next scaling work.
- Validation: **8 executable Swift groups**, **7 native safety groups** under bridge/test ASan+UBSan, and an end-to-end native → Swift → native numeric fixture pass. The fixture checks BSON numeric types and values/bit patterns by key, so Swift's sorted formatting cannot hide precision changes. Model/client typechecking, C syntax against vendored iOS headers, SwiftUI/XCTest source parsing, and whitespace checks pass. The existing DNS Sendable warning remains.
- Xcode, full XCTest execution, iOS app linking, simulator/device runtime, UI behavior, real TLS handshakes, and live database behavior remain unverified. No database or Keychain was accessed by these checks.

Run `scripts/test-foundation.sh`, `scripts/test-native-safety.sh`, then `scripts/test-numeric-roundtrip.sh` to reproduce the second checkpoint's offline checks. The last script uses the two executables built by the first scripts. Both checkpoints are local commits; no public push or merge is authorized by this work.

## Third local checkpoint — paged collection browsing

The collection browser now opens a read-only native cursor and advances it. The query workbench and its write-confirmation guards remain separate and intact. This implements one browsing workflow within the broader Compass-level client target. Saved queries, context labels, richer editing/analysis and explicit sharing/privacy affordances are part of the broader roadmap; nothing shares automatically.

### Pagination and ordering

- Regular `collection` entries open the pager; views/other collection types open the existing workbench. The pager offers Next, Restart, Cancel, individual document expansion/copy, and a link to Query for projections/filters. No new write path exists.
- The server query has `sort: {_id: 1}`, `collation: {locale: "simple"}`, `batchSize:21`, and `maxTimeMS:10000`. It has no `skip`, result `limit`, or `noCursorTimeout`. A normal collection's globally unique `_id` gives deterministic total order for an unchanged dataset. Duplicate `_id` values can exist across shards where global uniqueness is not enforced; their relative tie order is server-defined.
- Page boundaries retain one exact BSON lookahead document rather than computing a range predicate. Equal sort keys are not deduplicated. This avoids boundary errors caused by repeated range queries, large integer conversion, or excluding an equal key. A retained cursor still does not promise snapshot isolation: concurrent writes/deletes may affect results, and no cross-restart continuation guarantee is made.
- Next consumes the same cursor; the current page is released before loading. Cursor errors/expiry close the cursor and require an explicit restart. No retry silently starts a new scan.

### Resource bounds

| Resource | Bound / behavior |
| --- | --- |
| Current native/Swift page | Up to 20 documents; document-array JSON at most 4 MiB, plus a small response envelope |
| Individual document | At most 1 MiB in both BSON and canonical JSON; oversized documents stop browsing with projection guidance |
| Lookahead | At most one validated BSON document, at most 1 MiB; consumed exactly once on the next page |
| Page history | None; one current page plus integer counters, regardless of pages visited |
| Cursor ownership | At most one browsing cursor per native client; stale session IDs cannot close a replacement cursor |
| Display | Lazy SwiftUI List rows; one expanded document, at most 16,384 retained preview characters; collapsed `_id` labels at most 120 characters |
| Driver/network | Batch count 21 and inherited bounded socket waits; driver receive buffers are not a 4 MiB RSS guarantee |

BSON-to-JSON serialization, Swift decoding, response wrapping, SwiftUI retention during view updates, and full-document formatting/copying have temporary allocations. No peak RSS or frame-rate claim is made without device measurements. Already-live connections elsewhere in the app are still not globally capped.

### Lifecycle

Navigation away, app inactivity/backgrounding, Cancel, exhaustion, oversize/error, and disconnect close the native browsing cursor. Session IDs suppress late pages and prevent an old cleanup task from closing a newer cursor. Actor serialization owns the native handle. No cancellation path destroys a cursor/handle concurrently with a C call. An in-flight call (including cursor cleanup) may block until the driver returns or times out; queued/late cancelled work is discarded, and the UI does not permit another page request while its task is still finishing. Returning after pause requires Restart.

### Synthetic validation

- **9 native safety groups** pass with bridge/test AddressSanitizer and UndefinedBehaviorSanitizer. Paging fixtures cover 0, 1, 19, 20, 21, 40, 41, 101, and 1,001 documents; duplicate `_id` groups crossing a page boundary; precise int64 IDs above 2^53; cumulative byte boundaries with 1,000,000-byte payloads; explicit close, exhaustion, timeout replies and oversize cleanup.
- Native tests assert the exact sort/collation/batch/timeout options and absence of `skip`, `limit`, and timeout disabling. Synthetic cursor order is checked using independent monotonically increasing ordinals, verifying no boundary omission or duplication even when `_id` repeats. These tests validate consumption and configured order, not MongoDB's actual sort implementation.
- **9 executable Swift groups** pass, including replacement/release across 1,000 pages, stale-session rejection, page-count/byte validation, exact and bounded row labels. Added matching XCTest cases remain unexecuted on this host.
- Native page JSON decodes through the production Swift page model with exact `_id` and ordinal checks. Existing BSON → Swift → BSON numeric round trips continue to pass. Run the two base test scripts, then `scripts/test-pagination.sh` and `scripts/test-numeric-roundtrip.sh`.
- Model/client typechecking, C syntax checks against vendored headers, SwiftUI/XCTest source parsing and whitespace checks pass. The pre-existing DNS Sendable warning remains.

**Remaining gates at the pagination checkpoint (build/XCTest now resolved above):** full simulator/device UI and accessibility QA. Synthetic native cursors have cursor ID zero and all fixture data in `firstBatch`: real `getMore`, network interruption, remote `killCursors`, server sorting/collation, sharded/concurrent-change behavior, and real memory/scroll measurements are not validated. No real database, credentials or Keychain were accessed. No production-scale capacity claim or public push follows from these offline checks.
