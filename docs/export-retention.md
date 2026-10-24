# Keep a completed export until its replacement succeeds

Previously starting another export immediately deleted the last completed
shareable file. A cancelled read or a failure while writing the replacement
therefore removed the earlier useful result as well.

The filter/export screen now owns a `DataExportState`. Beginning an attempt keeps
the completed result and its original namespace, column list, format, and row
summary visible under **Last completed export**. Only completion of the current
attempt replaces it and removes the old temporary file. Cancellation and failures
keep the completed file. A late or superseded completion is discarded. Leaving
the screen discards the retained file and revokes pending delivery.

The existing writer still removes incomplete output. Each export keeps its
10,000-row and 50-MiB limits. While replacing a file, one completed file and one
in-progress file may coexist (up to roughly 100 MiB together); this is a temporary
file lifecycle improvement, not durable export history or crash recovery.

Regression tests create real temporary JSON/CSV files and verify bytes and file
existence after writer failure, cancellation, supersession, replacement, repeated
completion, and screen cleanup. All 43 offline Swift tests and 53 iOS simulator tests pass. The iOS suite
also exercises the real SwiftUI result component with a fictional retained file.
The component capture is a layout fixture, not a full screen interaction recording
or a share-sheet usability test. No database connection was used. The unsigned Apple Silicon simulator Release build passes. A generic simulator
Release build cannot link x86_64 because the bundled MongoDB archive contains
arm64 objects only. Physical-device and real-server replacement-export checks
remain unverified.
