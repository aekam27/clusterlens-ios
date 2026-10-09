# Build and runtime validation — 2026-10-03

## Automated results

The application sources in this review branch are identical to the locally tested implementation. Publication changes only consolidate history and remove private workstation/device/artifact details from documentation. Builds used Xcode **27.0 (27A266a)** with iOS 27.0 SDKs.

| Check | Result |
| --- | --- |
| Debug arm64 iOS simulator app compile/link | PASS |
| Hosted XCTest on an isolated iOS 27 simulator | **32 tests, 0 failures** |
| Synthetic native bridge safety groups, ASan/UBSan | **10 groups pass** |
| Standalone Foundation fixture checks | PASS |
| Unsigned Release arm64 iOS device compile/link | PASS |
| Authorized development-signed physical iPhone install | Installed version **0.3.0, build 1**; synthetic launch accepted and process observed running |

The native dependency libraries were not sanitizer-instrumented. The physical-device evidence establishes installation and process startup, not a visual UI, performance or database pass. No App Store/TestFlight upload or distribution validation was performed. Intel simulator support was not tested; vendored driver slices target arm64. The existing DNS callback Sendable warning remains before adopting strict Swift 6 concurrency.

Local build logs and test result bundles are excluded from the repository. No signing identity, provisioning profile, device identifier, test export, private screenshot reference or machine-specific path is included in this publication.

## Synthetic fixture contract

In a **Debug** scheme, add `--synthetic-ui`. Fixture startup skips saved profiles, history, legacy migration and Keychain reads. Connections and write unlock are rejected; fixture history remains in memory. The flag/backend are compiled out of Release.

`fixture_store.orders` has 41 documents; `empty` has none; `error` throws; `slow` delays three seconds for cancellation checks. The raw query workbench returns an explicitly labeled fixed fixture response. New filtered preview/export supports an empty filter and top-level fields only and rejects unsupported emulation. It does not implement MongoDB query semantics.

## Manual simulator observations

Isolated iPhone and iPad simulators were used. Earlier checks verified first-run setup and concealed connection input, local malformed-URI rejection, exact large integer display, expandable canonical Extended JSON, 20/20/1 paging, empty/error/retry flows, browse cancellation/restart, query formatting/templates, synthetic history, and background/resume after a completed query. The corrected QA banner and singular document label were visually verified. These checks did not contact a server.

The subsequent query/export UI pass inspected the same application sources as this review branch. Existing automated logs were reviewed during that manual pass rather than tests being rerun by the UI reviewer.

### Verified manual behavior

- **Visual/raw filter:** adding `item` Equals Text `Fixture order 1` serialized to an explicit `$and` filter. The Text pattern template produced Extended JSON `$regularExpression`. Returning to the builder displayed a replacement warning; Keep raw filter retained the template, and Start new filter reset it. This verifies the explicit reset contract, not a bidirectional parser for arbitrary filters.
- **Validation:** committed duplicate-key JSON produced `Duplicate JSON object keys are not supported. Use explicit $and conditions for repeated fields.` A valid nonempty filter produced the synthetic backend's explicit unsupported-filter message. Actual MongoDB evaluation was not attempted.
- **Preview/selection:** an empty filter displayed 20 fixture rows. Suggestions exposed `_id`, `item`, and `synthetic`, labeled as samples from the current page. Selecting `item` and `_id` populated the selection, and the export review captured those exact columns and the namespace. Changed configuration displayed the reminder to apply the filter again; exhaustive filtered paging and descending-order UI tests were not completed.
- **Cross-page JSON:** a 35-row export from the 20-row preview completed with 2,444 bytes and a requested-row-limit label. The native share sheet opened and was dismissed without an external share. Parsed output contained exactly 35 records, only `item` and `_id`, sequential fixture names, and exact `$numberLong` strings from `9007199254740993` through `9007199254741027`.
- **Repeated CSV:** a subsequent 35-row CSV export completed with 2,140 bytes. Inspection found header `item,_id`, 35 data records, 36 CRLF endings, two columns per record, and quoted canonical Extended JSON identifiers. The earlier temporary JSON file was removed when the new export began. Formula escaping is covered by existing automated tests; these particular UI fixtures did not contain formula-like cells.
- **Invalid limits:** requested row counts 0 and 10,001 produced `Choose between 1 and 10,000 export rows.` Dismissing the export review outside its popover did not start an export.
- **Cancellation:** a 1,000-row CSV request was cancelled while the 41-row synthetic fixture was still exporting (11 rows visible in progress). The screen reported `Export cancelled. The partial file was discarded.`, offered no completed share action, and inspection found no `ClusterLens-*` export remaining in the simulator temporary directory.
- **Collection guard:** Create displayed the target and disabled review while locked. Unlock returned `Writes stay locked in synthetic QA mode.` Drop displayed its destructive warning and required exact `fixture_store.orders`; even after typing it, Review drop stayed disabled while locked. Returning left the four fixture collections intact. No biometric prompt or collection mutation occurred.
- **iPad layout:** the new filter form and added condition rendered in portrait and supported landscape. At text-size setting 11, the banner and form text enlarged, and dragging scrolled to the export limit/explanation and Review export action. Text size was restored to 3; VoiceOver remained off. Back returned to the paused collection browser. This was a targeted inspection, not an exhaustive large-text pass across all controls.

Two low-impact observations remain for future refinement: prior validation feedback can remain after resetting the filter until another operation updates it; starting export after a preview removes that preview and may move the form's scroll position. Neither prevented the verified export/cancellation flows. No speculative UI fix was made.

## Physical-device boundary

After explicit user approval, the existing application was updated in place on a physical iPhone 17 Pro using an already configured development identity/profile. The signed Debug device build and strict signature verification passed. No new certificate/profile, provisioning update, security setting, persistent credential grant or Apple agreement was needed. Repository signing configuration remains unconfigured for other developers.

The device reported successful installation of version 0.3.0 (build 1), accepted a foreground launch with `--synthetic-ui`, and subsequently reported the application process running. No physical screenshot or visual UI pass is claimed. Saved user data and credentials were not opened. No uninstall, reset or app-data deletion was performed. The reported data-container identity changed; contents and Keychain preservation were not independently verified, and no retention or data-loss conclusion is inferred from that change alone.

## Reproduce on an isolated simulator

Use your installed Xcode developer directory and a fresh simulator identifier:

```sh
export DEVELOPER_DIR="/path/to/Xcode.app/Contents/Developer"
xcodebuild -project ios/ClusterLens.xcodeproj -scheme ClusterLens \
  -configuration Debug -destination 'platform=iOS Simulator,id=<fresh-device-id>' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO test
xcrun simctl launch <fresh-device-id> com.aekam.ClusterLens --synthetic-ui
xcodebuild -project ios/ClusterLens.xcodeproj -scheme ClusterLens \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

Native fixture scripts use existing local driver source and do not download dependencies or contact a database. See the [foundation audit](production-foundation-audit.md) and [query/export contract](query-export-collections.md).

## Remaining release gates

- Complete VoiceOver speech/focus/navigation, compact-phone/large-text coverage, every typed-filter control, CSV-without-columns UI validation, filtered preview paging/descending sorting, export background/resume, and iPad multitasking sizes.
- Validate real filter/projection semantics, TLS trust/hostname rejection, SRV/TXT, authentication, denied roles, cursor `getMore`/`killCursors`, cancellation/reconnect, collection create/drop outcomes and ambiguous write errors against an explicitly authorized disposable server.
- Measure RSS, leaks, scroll responsiveness, repeated sessions and large-document behavior on physical devices. Bounded result arrays do not establish a production capacity or throughput claim.
- Verify dependency provenance/reproducibility/update ownership, CA freshness, deployment-target compatibility, privacy and distribution requirements.

Synthetic write protection intentionally prevented create/drop dispatch and biometric unlocking tests. No real database connection, production query or collection mutation was performed. This review branch is not a production release or a claim of Compass/Atlas parity.

## Preview preservation follow-up — 2026-10-09

PR #2 is merged; this follow-up starts from main commit `4988600f9bd7eeacc051071c0278ec5561b104b8` on the local review branch `codex/preserve-query-preview`.

Applying invalid replacement input previously scheduled closure of the current cursor before query validation. The patch validates and prepares the replacement first, preserving the existing page and continuation on validation failure. Per-read delivery tokens prevent cancelled/superseded completions from publishing a page or retiring a newer session; operation guards also prevent late task cleanup/progress from changing a newer operation's UI state. Explicitly resetting the filter clears obsolete feedback. The previous page is still released when a valid new read begins, keeping the one-page retention bound. Cancellation does not interrupt an active native driver call, and the UI stays busy until that call returns or times out.

Validation performed on the patch:

- **38 hosted XCTest tests passed** on the isolated iOS simulator, including six new preview tests. A synthetic negative control replayed the former close-before-validation order and observed a closed continuation cursor. The corresponding fixed-path test rejected invalid input, retained the session, and then loaded the second 20-document page beginning at fixture order 21. Additional tests cover failed preparation during an in-flight read, superseded success/error delivery, duplicate completion, cancellation, and restart.
- **10 native bridge safety groups passed** with ASan/UBSan on the current bridge/test sources. Existing locally built driver libraries were reused; those libraries were not sanitizer-instrumented.
- Standalone Foundation checks, BSON → Swift → BSON numeric round-trip, and native-page → Swift pagination checks passed.
- Debug simulator compilation/linking and the **unsigned Release iOS device build passed**. The existing DNS callback Sendable warning remains.
- Logs and result bundles are kept under ignored `.native-build/`: `preview-regressions.log`, `preview-regressions.xcresult`, `preview-foundation.log`, `preview-numeric-roundtrip.log`, `preview-pagination.log`, and `preview-release.log`.

The negative control verifies the old operation ordering with the synthetic coordinator, not a manual recreation in the old UI or a real MongoDB transport test. The new UI integration compiled, but manual interaction/accessibility testing of this follow-up has not been performed. No performance conclusions are drawn from these runs. No live database, physical-device installation, credentials, remote push, merge or publication was involved in this follow-up.
