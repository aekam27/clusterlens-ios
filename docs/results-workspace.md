# Results workspace

Browse and Filter & export now share a selected-field results view. On an iPhone
it uses two-column record cards; regular-width iPad layouts use a horizontal
table. Accessibility text sizes use a single-column card layout. The Columns
menu chooses one to eight fields and preserves explicit choices across pages.
Changing display columns performs no database query.

Tap a value or record to open the read-only inspector. Objects and arrays expand
in place, null differs from Missing, and canonical BSON values retain their
exact strings and type labels. Copy complete Extended JSON is explicit. Filter
& export can copy display columns into the existing editor; applying a filter
or approving an export remains a separate action.

## Bounds and compatibility

- Existing current-page, cursor and serialized-JSON limits remain in place.
- Field suggestions sample at most 20 records, 200 visited keys, four levels and
  80 resulting paths. They are a page sample, not schema discovery. Literal-dot
  keys and array traversal are omitted; the full record inspector retains them.
- Cells summarize objects/arrays and clip strings to 120 characters without
  serializing the entire record. The inspector shows up to 100 children per
  branch and 12 levels. Leaf previews are capped at 4,096 characters; explicit
  copying includes the complete selected value.
- Display column choices are session/view state, not newly persisted settings.
  Existing saved query settings continue to work independently.
- No credentials, live MongoDB data, network policy or write permissions changed.
  The richer fictional dataset exists only in the DEBUG synthetic fixture.

## Validation scope

Verified locally: 49 offline core tests, 60 iOS unit tests, the full synthetic UI
workflow on both iPhone and iPad simulators, and an unsigned ARM64 Release
simulator build. Core and iOS counts overlap. The pre-existing native archive
does not support x86_64 simulator linking. No physical-device validation.

ResultProjectionTests cover missing/null, nested paths, array boundaries, exact
BSON numeric text, long values, bounded suggestions and compatibility with the
existing projection/CSV paths. ResultsWorkflowTests drives the actual app with
`--synthetic-ui`: select columns, inspect array/object values, distinguish null,
and advance to the next page while retaining the chosen columns.

The screenshot fixture captures real SwiftUI views with fictional records;
it is separate from the full-app synthetic UI screenshots. Neither is a mockup.
There is no live database or physical-device performance claim.

A diagnostic within ResultProjectionTests compares the previous
filtered-preview formatting expressions (two full JSON encodes for each expanded
record) with selected-field summaries. With 20 fictional records totaling
2,242,043 JSON bytes and four columns, ten Debug iterations had median times
11.84 ms and 0.0635 ms respectively on this Mac. This measures formatting work
only. The old disclosure view could defer formatting until expansion, and the
new display shows different information; these numbers are not an end-to-end
app speedup or network benchmark. No timing threshold is asserted.

Build and test with the checked-in Xcode scheme; regenerate with XcodeGen after
editing project.yml. The UI target always launches the fictional fixture. This
checkpoint is local source, not an App Store or signed-device release.
