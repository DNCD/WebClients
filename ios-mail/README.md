# MailClient for iOS

A native SwiftUI mail-only client for Proton accounts. It talks to the same API as the web client in
this repository and does all encryption on the device.

The API calls are ported from `packages/shared/lib/api/*`. The send pipeline follows
`packages/shared/lib/mail/send/*`. OpenPGP and SRP come from Proton's own iOS bindings
([`protoncore_ios`](https://github.com/ProtonMail/protoncore_ios): GopenPGP + go-srp).

## Features

| Area | Supported |
| --- | --- |
| Sign-in | SRP password auth, TOTP two-factor, two-password (mailbox password) accounts, token refresh |
| Session | Tokens and derived key passphrases kept in the Keychain (device-only); the password is never stored |
| Reading | Inbox, Drafts, Sent, Starred, Archive, Spam, Trash, All Mail; paging; search; pull to refresh |
| Messages | Decrypts plain text, HTML and PGP/MIME bodies; HTML is shown with JavaScript off |
| Tracker protection | Blocks tracking pixels and cleans tracking links (see below); a green shield on the message and in the list shows what was blocked |
| Actions | Mark read/unread, archive, move to trash, delete from trash |
| Sending | Plain-text compose and reply. Proton recipients are end-to-end encrypted; other recipients get mail in clear over TLS |

Not implemented yet: attachments (viewing and sending), HTML compose, custom labels and folders,
conversation view, push notifications, human verification (CAPTCHA) and FIDO2 security keys at sign-in,
PGP to external recipients' keys, key transparency, and signature verification.

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
  App/        entry point, config, sign-in state machine (SessionModel)
  API/        URLSession client (headers, error envelope, token refresh), models, multipart form
  Auth/       SRP login, 2FA, key passphrase derivation
  Crypto/     key unlocking (user key → address keys), send-package encryption
  Mail/       message list/read/actions/send, minimal MIME parser
  Privacy/    link cleaning, HTML rewriting, tracker lookup, proxy image loader
  Storage/    Keychain
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
