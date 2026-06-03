# Security and Privacy

Vesper is a local-first iOS photo curation app. The core ranking pipeline runs on device and does not require uploading photos to a hosted AI scoring service.

## Data Handling

- Full-resolution photos are analyzed locally.
- Reference photos and feedback history are stored locally with SwiftData.
- Optional anonymous feedback upload is gated by user opt-in.
- Optional uploaded thumbnails are resized, JPEG-compressed, and capped before upload.
- Firebase config files are not committed to this repository.

## Backend Protections

The Firestore rules in `firestore.rules` are intentionally narrow:

- Reads are denied.
- Updates and deletes are denied.
- Creates require Firebase App Check.
- Required fields and field types are validated.
- String fields and optional thumbnail payloads are size-capped.
- All other collections are denied by default.

## Secrets

Do not commit:

- `Vesper/GoogleService-Info.plist`
- `.env` files
- service account keys
- private keys
- credentials JSON files

If a key or credential is ever accidentally committed, rotate it immediately and remove it from git history before making the repository public.
