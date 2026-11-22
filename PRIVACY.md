# Soma Relay privacy policy

Last updated: 2026-11-21. Publisher: Soma Labs.

Soma Relay is built so that we know as little about you as possible. This page explains what the app and our relay node handle.

## No account

You do not give us a name, phone number or email address. Your identity is a key pair created on your device. The display name you choose is only shared with the people you add.

## Your messages

Messages, photos, voice notes, videos, files and calls are end-to-end encrypted on your device before they leave it. Nobody else can read them, including Soma Labs and the operators of any relay node.

If you set a profile photo, it is sent only to your contacts and to the groups you are in, end-to-end encrypted like a message. The node never sees it.

Your conversations, contacts and media are stored only on your device, in an encrypted local database. Deleting the app deletes them. We have no copy.

## What a relay node sees

When you use the Internet path, your device connects to a relay node. The node Soma Labs runs, and any node you choose to use instead, handles:

- Sealed envelopes addressed to a mailbox id derived from a key. The node cannot open them and does not learn who sent them.
- Encrypted attachments, stored as opaque blobs.
- Your IP address, as for any Internet connection. It is used for rate limiting and is not stored with your messages.
- If you choose to publish a handle (like `name@node`), the public card attached to it, so others can find you.

Undelivered envelopes and blobs are deleted after 14 days. Delivered envelopes are deleted on delivery.

## Mesh and SMS

On the mesh, nearby phones running Soma Relay carry encrypted envelopes they cannot read. Broadcasts use a tag that changes every hour so your phone cannot be tracked by them.

If you use the SMS fallback, the message is encrypted before it goes into the SMS. Your carrier sees that an SMS was sent and to which number, as with any SMS.

## Permissions

The app asks for the camera (QR codes, video calls, photos), the microphone (calls, voice notes), the photo library (sending and saving photos), and the local network and Bluetooth (the mesh). It never reads your address book. Each one is used only for the feature you use.

## Analytics and tracking

None. The app contains no analytics, advertising or tracking code.

## Children

Soma Relay is not directed at children under 13.

## Contact

Questions: open an issue at https://github.com/soma-intelligence/soma-relay or write to opensource@somalabs.me.
