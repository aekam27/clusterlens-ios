# Security model

ClusterLens connects an iPhone directly to MongoDB. That is convenient, but it places a database credential on the device and exposes the cluster endpoint to the phone's network. Treat the app as a developer/admin tool, not as a general consumer database client.

## Secrets

- Every complete MongoDB connection string is stored as a separate iOS Keychain item with this-device-only accessibility and synchronization explicitly disabled.
- Saved connection profiles contain only the friendly name, hostname, discovery type, and random connection ID—not usernames or passwords.
- The profile index and query history use complete file protection and are excluded from device backups.
- Connection strings are never added to query history or normal UI labels.
- `.env`, build products, Xcode user data, and local dependency build directories are excluded from source packages.

## Network protections

- Atlas connections use TLS by default, including connection strings expanded from `mongodb+srv://`.
- SRV targets are accepted only when they remain inside the seed hostname's trusted parent domain.
- Atlas Network Access remains the network boundary. Allow only the IP ranges genuinely needed.
- Do not disable TLS or certificate validation in production.

## Query protections

- Find and aggregation output is capped before it reaches SwiftUI.
- Write operations are hidden until device-owner authentication succeeds.
- Every write requires a separate confirmation.
- Write access relocks when the app leaves the foreground or switches connections.
- MongoDB roles remain the final authorization boundary; biometrics do not add server-side permission.

## Recommended deployment

- Create a dedicated, least-privilege MongoDB user.
- Prefer read-only roles and a non-production cluster.
- Rotate every saved database password if the device is lost or compromised.
- Keep iOS, the MongoDB driver, and OpenSSL updated.
- Avoid `0.0.0.0/0` in the Atlas IP access list.
- Commission an external security review before handling production data.

## Reporting a vulnerability

Do not include connection strings, credentials, customer data, or live cluster hostnames in a public issue. Share a minimal reproduction with all sensitive values replaced.
