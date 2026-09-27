# MailClient for iOS

A native SwiftUI mail-only client for Proton accounts. It talks to the same API as the web client in
this repository and does all encryption on the device.

The API calls are ported from `packages/shared/lib/api/*`. The send pipeline follows
`packages/shared/lib/mail/send/*`. OpenPGP and SRP come from Proton's own iOS bindings
([`protoncore_ios`](https://github.com/ProtonMail/protoncore_ios): GopenPGP + go-srp).

## Features

| Area | Supported |
| --- | --- |
| Accounts | Several Proton accounts, one-tap switching, **unified inbox** ("All Inboxes") with per-account tags, per-account unread badges |
| Sign-in | SRP password auth, TOTP two-factor, two-password (mailbox password) accounts, token refresh |
| Offline | Mail lists, messages and attachments metadata cached in an on-device SQLite store; recent messages (7 days to 1 year, configurable) are downloaded and decrypted for offline reading; read/unread, star, move, label, archive, trash work offline and sync later; mail composed offline waits in the **Outbox** and sends on reconnect |
| Sync | Incremental sync through the event stream (`core/v5/events`), like the web client; full resync when the server asks |
| Search | Operators: `from:` `to:` `subject:` `in:` `has:attachment` `is:unread/read/starred` `before:` `after:` `newer_than:7d` `older_than:1y` `"exact phrase"` `-exclude`. Server search for metadata plus **full-text body search** over downloaded mail (SQLite FTS5); works offline |
| Reading | Plain text, HTML and PGP/MIME; tracker protection (below); Reply, Reply All, Forward; move to folders, apply labels, star, spam |
| Attachments | Tap to preview (Quick Look), share, **Save to Files** (one or all); attach from Files or Photos when composing (25 MB limit); encrypted like the web client |
| Contacts | Recipient autocomplete from Proton contacts (cached offline), the iPhone's Contacts (with permission) and recent correspondents; "Add Sender to Contacts" |
| Filters | Server-side filters like the web's Settings → Filters: list, enable/disable, delete, and create rules (sender/recipient/subject/attachments × contains/is/begins/ends/not → move to folder, label, mark read, star). Rules are compiled to Sieve and validated by the server |
| Notifications | New-mail notifications with Mark as Read / Archive actions, for Inbox, chosen folders or VIP senders only; quiet hours; hide previews; app badge |
| Customisation | Light / Dark / System theme; list density (compact, comfortable, spacious); avatars on/off; subject lines; four configurable swipe actions (archive, trash, read, star, spam, move to inbox); delete confirmation; auto-load images |
| Sending | Plain-text compose; Proton recipients are end-to-end encrypted; others get mail in clear over TLS |

Not implemented yet: HTML compose, conversation (thread) view, human verification (CAPTCHA) and FIDO2
security keys at sign-in, PGP to external recipients' keys, key transparency, signature verification,
creating Proton contacts (senders are saved to iOS Contacts), and instant push.

### About notifications

Proton's push service needs a device registration API that isn't in this repository, so new mail is
found by the sync loop: every 30 seconds while the app is open, and through iOS background app refresh
when it isn't. iOS decides when background refresh runs (typically every 15 minutes or more, less
when the battery is low), so notifications can be delayed.

### About offline storage

The cache lives in `Application Support/Accounts/<id>/mail.sqlite` with iOS data protection
(`completeUntilFirstUserAuthentication`, so background refresh can sync). Decrypted bodies and the
outbox are additionally sealed with AES-GCM using a per-account key in the Keychain. The full-text
index has to hold searchable words from downloaded mail. Signing out of an account deletes its
database and keys.

## Tracker protection

Ported from the web client's spy-tracker feature:

- **Tracking images.** Remote images never load directly from the sender. Every image URL in the
  HTML is rewritten to `pm-proxy://`, and direct `http(s)` loads are blocked by a WebKit content
  rule. The app asks Proton's image proxy which images are trackers (`GET core/v4/images?DryRun=1`,
  answered in the `x-pm-tracker-provider` header, like `loadFakeProxy` on the web). Tiny or hidden
  images also count as tracking pixels. When you tap **Load**, images come through the proxy
  (`DryRun=0`), which hides your IP address.
- **Tracking links.** `utm_*`, `fbclid`, `gclid`, `mc_eid`, HubSpot, Marketo and similar
  parameters are removed from links in HTML and plain-text mail, like `getUTMTrackersFromURL`.
- **Shield badge.** Opened messages show "N trackers blocked · N links cleaned", with a details
  sheet listing each tracker company and cleaned link. The list shows a green shield on messages
  where something was blocked. These counts are kept on the device (message ID → counts only),
  so a message gets its badge once it has been opened.

## Build

Requirements: Xcode 16+, iOS 17+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios-mail
brew install xcodegen
xcodegen generate
open MailClient.xcodeproj
```

Xcode will ask you to trust ProtonCore's SwiftLint build plugin the first time; allow it. On the
command line, pass `-skipPackagePluginValidation`.

The first package resolution clones `protoncore_ios`, which includes prebuilt Go crypto frameworks, so
it takes a while.

Before you ship, set these in `project.yml`:

- `PRODUCT_BUNDLE_IDENTIFIER`: your bundle ID.
- `PM_APP_VERSION`: sent as the `x-pm-appversion` header. Proton identifies API clients by this value
  and may reject unknown ones (for example with an "app version" error). Use an identifier Proton
  accepts for your client.

CI (`.github/workflows/ios-mail.yml`) generates the project, then builds it and runs the unit tests on
an iOS simulator. The crypto tests use the real GopenPGP bindings to round-trip draft and send-package
encryption.

## Layout

```
MailClient/
  App/        entry point, settings, accounts and sign-in, notifications
  API/        URLSession client (headers, error envelope, token refresh), models, multipart form
  Auth/       SRP login, 2FA, key passphrase derivation
  Crypto/     key unlocking (user key → address keys), send-package encryption
  Mail/       mail API, sync engine (events, outbox, offline actions), search, filters, contacts, MIME
  Privacy/    link cleaning, HTML rewriting, tracker lookup, proxy image loader
  Storage/    Keychain, SQLite wrapper, per-account offline store (FTS5)
  Views/      SwiftUI screens
MailClientTests/
```

## How it works

1. **Login**: `POST core/v4/auth/info` returns the SRP parameters. go-srp computes the client proof,
   `POST core/v4/auth` checks it, and the app verifies the server's proof before trusting the session.
   `POST core/v4/auth/2fa` follows when two-factor is on.
2. **Keys**: the user key passphrase is bcrypt(password, key salt), last 31 characters
   (`core/v4/keys/salts`). The user key decrypts each address key's `Token`, which is that key's
   passphrase (`core/v4/addresses`).
3. **Reading**: `GET mail/v4/messages?LabelID=…` lists messages and `GET mail/v4/messages/{id}` fetches
   one. The body is decrypted with the keys of its address.
4. **Sending**: create a draft (body encrypted to yourself), look up each recipient with
   `GET core/v4/keys/all`, then `POST mail/v4/messages/{id}` with a `text/plain` package. The package
   has one symmetrically encrypted body, a key packet for each Proton recipient, and the clear session
   key if any recipient is external.

## License

GPL-3.0, like the rest of this repository. An App Store release must comply with the GPL.
