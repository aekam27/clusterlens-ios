# Query, export and collection tools — local implementation checkpoint

## User-facing paths

- Open a collection, then **Filter & export**, or choose **Build a filter, choose columns & export** from the raw Query workbench.
- Build ALL/ANY conditions with field, operator and typed value. Supported controls: equality/inequality, comparisons, an explicit JSON array for `$in`, and Boolean `$exists`.
- **Edit as raw JSON** serializes the builder into strict JSON/Extended JSON. Raw input stays intact. Returning to the limited builder explicitly confirms replacement with a new empty filter; complex raw syntax is never silently converted.
- Enter comma-separated column paths, or select suggestions from the current preview. Suggestions are sampled, not a complete schema. Empty selection means all fields for JSON; CSV requires explicit columns. Selected fields exclude `_id` unless explicitly selected.
- Preview and export sort by `_id` ascending/descending using simple collation. Compound sorting is not implemented. The existing raw workbench rejects compound sort rather than losing key order through a dictionary.
- The database collection list now has **Manage** for creating an ordinary empty collection or dropping one selected collection. Write unlock is required. Drop additionally requires typing the exact `database.collection` namespace before final confirmation.

## Export contract

Export captures connection, namespace, filter, projection, order, format and row limit. It starts a new live scan; it does not export only the visible preview page. Total matching count and final size are unknown, and no count query is issued. Concurrent server changes can affect the scan.

Limits are visible: **1–10,000 requested rows**, **50 MiB output**, and the existing native **20-document / 4 MiB page and 1 MiB individual-document** limits. The actor reserves its existing cursor during export and writes one document at a time. Queries on the same actor wait until export finishes or cancels. Cancellation is cooperative between native calls; an in-flight call must finish or time out. Failed/cancelled exports discard their partial temporary files. A row-limit completion is labeled; byte/document errors never return an apparently complete truncated file.

JSON is an array of canonical Extended JSON documents, retaining the native driver's BSON type wrappers. CSV uses fixed selected columns, CRLF record endings, quoted cells and doubled quotes. Potential spreadsheet formula cells (including headers) receive an apostrophe prefix. Nested objects/arrays selected as a whole are serialized as JSON text; traversal through an array path is rejected rather than silently dropping values. Missing fields are blank CSV cells; null is `null`. CSV is a textual interchange format, not a lossless BSON round-trip format.

Completed exports use iOS complete file protection in temporary storage. The share sheet lets the user save a copy. The app removes the temporary file when leaving the workspace or starting another export. A force-quit can leave an OS-managed temporary file until the system clears it; no app-start cleanup is claimed in this iteration.

## Validation and destructive-action boundaries

- JSON input is bounded to 256 KiB / 50 nesting levels. Duplicate object keys are rejected before dictionary decoding, including escaped equivalent keys.
- Shell code, constructors and regex literals are not evaluated; templates use Extended JSON. Server-side JavaScript operators/BSON code are rejected in both Swift and the native bridge. MongoDB still validates operator/Extended JSON semantics; no standalone implementation of MongoDB's grammar is claimed.
- Misplaced top-level conditions in the raw operation workbench are rejected instead of becoming an empty filter.
- Create/drop requests capture an exact namespace and use the existing revocable one-shot write permit. The native bridge independently checks namespace confirmation. Drop does not appear in a generic operation picker or replayable query history.
- Create/drop controls show permission/server errors. Network failures after dispatch may have unknown outcomes; the UI instructs inspection before retrying. No automatic retry or bulk destructive action is added.
- Synthetic mode still blocks all real connections and all write unlock/execution. It supports unfiltered top-level-field preview/export only and rejects other filters explicitly; it does not pretend to evaluate MongoDB queries.

## Evidence at this checkpoint

- **32 hosted XCTest tests pass** on the isolated iOS 27 simulator, including nine new query/export/collection tests. Evidence: `.native-build/query-tools-reviewed-tests.log` and `.xcresult`.
- **10 native bridge safety groups pass** under AddressSanitizer/UndefinedBehaviorSanitizer, using synthetic BSON only: `.native-build/query-tools-native.log`. Native dependency libraries are not sanitizer-instrumented.
- Existing standalone Foundation checks pass: `.native-build/query-tools-foundation-final.log`.
- **Unsigned Release iOS device build passes**: `.native-build/query-tools-release.log`.
- New tests cover exact Int64 builder values, repeated-field conditions, ambiguous/duplicate raw JSON, projection validation, 41-row JSON serialization, 35-row coordinator export across the visible-page boundary, fixed CSV schema and formula escaping, cancellation, byte-limit cleanup, and exact/revoked drop authorization.
- Existing DNS callback Sendable warning remains. No new signing identity, profile, database connection, real query, collection creation/drop, physical-device install or public push occurred.

## Focused UI QA handoff

Launch the Debug app on isolated iPhone/iPad simulators with `--synthetic-ui`. A subsequent synthetic UI pass verified selected filter, export, cancellation, collection-lock and iPad-layout flows; see [build-runtime-validation.md](build-runtime-validation.md) for exact evidence and remaining coverage. The checklist below remains useful for regression testing.

1. Discover both entry points; add/remove conditions and inspect typed controls. Switch to raw, edit it, and verify resetting the builder requires confirmation. Invalid/duplicate JSON should produce actionable errors.
2. Empty filter: preview pages, select `item, _id`, then export JSON/CSV with 35 rows. Inspect the final count/scope and share sheet. Do not share to a third party. Cancel a 1,000-row synthetic export during its 41-row fixture run and verify no completed file is offered.
3. Check field suggestions, CSV-without-columns rejection, invalid row limits, changed configuration versus captured preview/export state, and repeated exports.
4. Manage collections: inspect Create/Drop controls and exact namespace input. Synthetic write unlock must remain rejected. Do not execute any real collection action.
5. Check iPhone/iPad keyboard, large text, VoiceOver labels, layout and navigation/back/background behavior. Capture app-only synthetic screenshots.

Before release, actual filter/projection semantics, native export `getMore`/cursor cleanup, denied database roles, permission errors and create/drop outcomes require an authorized disposable server fixture. Physical-device performance/memory and complete accessibility QA remain gates. This checkpoint implements the capabilities; it does not establish production readiness or Compass parity.
