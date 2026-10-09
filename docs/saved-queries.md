# Saved find queries

Filter & export can save the current validated filter, selected columns and `_id` sort under a name. Open **Saved queries** to inspect, load, rename or delete a preset. Loading uses the raw JSON editor so the complete filter survives; select **Apply filter and preview** to execute it. Saving, loading and managing presets do not execute queries, authorize writes or start an export. Any existing preview continues to use its captured query until a replacement is applied.

Presets are scoped to the saved connection's UUID plus the exact database and collection names. The same name can be used in another scope. A different connection with the same display name or hostname does not inherit presets. Duplicate names within a scope are rejected case-insensitively. Names are trimmed, contain no control characters, and are limited to 80 characters / 256 UTF-8 bytes.

## Storage and recovery

- `saved-find-presets.json` is a separate version-1 envelope in the app's Application Support directory. Existing connection profiles and query history are not migrated or changed by this feature. There was no earlier preset schema to migrate.
- The allowlisted record contains its UUID, scope, name, filter JSON, columns and descending-sort flag. Connection URIs, authentication settings, result documents and export settings are not copied. Recognizable MongoDB connection strings are rejected. Filter values can still contain sensitive information: this is not a general secret detector, so do not save secrets in filters or names.
- Writes are atomic and request complete iOS file protection. The containing directory is excluded from backups. Physical-device protection while locked still requires an authorized device test; simulator storage does not expose the file-protection attribute.
- Limits are 100 presets and 2 MiB encoded storage for the whole app, plus the existing per-query input/depth/column constraints. Reads are bounded to the file budget plus one byte. Filter inspection in the list shows at most 4,096 characters; loading retains the complete filter.
- Corrupt JSON, duplicate keys, invalid records, unexpected fields, oversized files and unsupported schema versions block mutations without overwriting the file. A failed reload preserves the last valid in-memory snapshot. Retry loads the file again; there is no automatic destructive reset or guessed version conversion.
- Save, rename and delete update the visible list only after the write succeeds. Synthetic UI mode uses an isolated memory store and does not read the user's preset file.

## Boundaries and next checks

This is a local repeat-session convenience, not shared query storage, synchronization or a performance claim. Only find filters are supported; saved aggregation pipelines and named export presets are future work. Removing a connection also removes its presets across namespaces. If preset storage is unavailable, credential/profile removal proceeds and an error reports incomplete preset cleanup; the existing file is preserved. Such retained records remain inaccessible under the removed UUID and count toward the global budget. A recovery-management UI is future work.

Before release, complete interactive save/load/rename/delete and VoiceOver focus testing, full large-text scrolling, storage-full/locked-device recovery, and authorized real-server semantics. Hosted layout attachments are visual evidence only; they do not establish gesture or screen-reader behavior. Test filters and namespaces are synthetic, and no database connection is needed for the preset tests.
