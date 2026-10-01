# Devices and Fresh Confirmation

How a person pairs a phone or another browser with a home, how that device stays connected, and how a sensitive change is confirmed from any device of theirs. A paired device is called a glass: it shows the home's pages and prompts and holds a key of its own; it holds no store, vault or person key.

---

## Local and Remote People

A home records whether a person's keys are **local** (held at this home) or **remote** (held at another home that admitted them). Everything in this guide works for a local person with no directory and no recovery kit: local pairing, local passkeys and local confirmation use the keys this home stores.

A remote person's pairing, passkeys and confirmations are refused at this home (`remote_identity_unavailable`) until the CYFR door is in place. A remote member has no fresh method at a hub until one is registered there: before they enter a credential into the hub's vault, pair a device or link a door at the hub, the hub's platform administrator must authorize their passkey's registration, and must do so again after every rotation or recovery of their keys, which retires the passkeys registered under the old ones.

---

## Pairing a Device

1. In the shell, open **Devices**. The prompt lists the devices you paired in this athanor, each with when it was paired and when its certificate renews.
2. Choose **Pair a device**. Pairing is a sensitive change, so it waits for a fresh confirmation (below). Once confirmed, the prompt shows a QR code and the same link, `https://<home>/pair#code=<code>`, with when it expires.
3. Open the link on the new device, by scanning the code or typing the link. The code is in the link's fragment, which a browser never sends to a server; the `/pair` page reads it and removes it from the address at once.
4. The page makes the device's key pair. Its private key cannot be exported, and the browser keeps it, with the device's certificate, across reloads. The page sends this home the code and the public key, signs the challenge the home answers with, and receives the device's client id and first certificate. It then connects the device channel under that certificate.

The `/pair` page reads no session: a sign-in cookie the browser still holds, even another person's, does not choose who the device belongs to. The code does.

A browser that already holds a paired device asks before a pairing link replaces it. Keeping the device connects as before. Replacing it is a choice you make: the device's key and certificate are erased from the browser first, and the old device stays listed under **Devices** until you revoke it.

### The pairing code is a bearer invitation

Whoever opens the link first, before it expires, pairs a device as you. The code is 128 random bits, lives five minutes, is stored only as a hash, and is used once. If a copy of the link reached anyone else, revoke the device it paired from **Devices**. A code that was already used, or has expired, is refused with that reason; show a new one.

If the browser closes after the home paired the device but before the answer arrived, the device was paired once and holds no certificate. The same link then answers that the code was already used: show a new code, and revoke the unused device from the list.

---

## Staying Connected

A device certificate names the device's key, its client, the home and athanor, and when it expires. It is signed by your live key at this home.

- **Lifetime.** A certificate lives `device_cert_seconds` (one hour by default). The device renews at half that, over its open connection, and keeps working under the old certificate until the replacement verifies.
- **Expiry is strict** on this home's clock. `clock_skew_seconds` applies only to a certificate's not-before time and never extends its life. The channel closes at the instant the certificate expires unrenewed.
- **Sleep.** A device that wakes, or reconnects, with an expired certificate renews before it sends anything else. Nothing else is sent until the home answers that the device stands.
- **Streams.** A connected device listens for your confirmations. When this home cannot check the device's standing in time to pass on a change, or the device falls behind, the stream ends and the device opens it again and reads what is waiting.
- **Rotation.** After your live key rotates, existing certificates no longer verify. The device reconnects and renews with the key it stored: the home challenges that key afresh, checks the paired device still stands, and issues a replacement. The old certificate only says which device is asking; it authorizes nothing. An installation restored without the device's record needs the device paired again.
- **Revocation.** Revoking a device from **Devices** needs a fresh confirmation. The device's channel closes at its next request, or within 30 seconds; every stream it holds ends first, and it is told its pairing ended. A renewal never revives a revoked device.

Revocation erases nothing already shown on the device. Until revocation or expiry, what the device shows and its unexpired certificate are the exposure of a lost device.

---

## Fresh Confirmation

Using what was granted, making a grant and answering an agent's approval need only your session. A short list of sensitive changes needs a fresh confirmation every time, for every person: entering or rotating a credential, issuing or rotating a credential that outlives the session (an API key or a webhook secret), pairing a device, revoking one, recovery material, rotating your live key, a remote sign-in assertion, linking or unlinking a door, and registering or removing a passkey.

Asking for one opens a pending confirmation of that exact change, shown with a preview the home stores: the change, what it concerns, the athanor and the home. It lives `confirmation_seconds` (five minutes by default). The client that asked holds a secret for it that no other client sees, and only that client completes the change; every other client names the request by its public ref.

### On every device of yours

The shell, the console pages that ask for these changes (API keys, webhooks and the vault), and each paired device listen for your confirmations, and each shows a request as it opens: the preview, and which client asked (a browser and how it signed in, a paired device, an API key, or an app). Check both before you confirm. The page that asked marks the request as its own and shows it waiting, then approved once confirmed anywhere, then the change's actual outcome. A typed credential stays in the page's own form while it waits and is submitted again once confirmed; the server never holds it. Cancelling ends the request, and so does dismissing your own waiting request.

### Proofs

A proof covers that one request, is used once and expires with it.

- **A passkey** registered at this home, asserting over the request. Face ID, a fingerprint or a security key.
- **A fresh sign-in** at the identity provider of the door you signed in with, forced to ask you again. It opens in a new tab, so the asking page stays. The provider must report when you signed in. The page it returns to shows the change again, and confirms only when you approve it in a browser signed in as you.
- **A code sent to your verified email**, where this home has a mail transport configured. Five wrong codes cancel the request.

A paired device offers a passkey and an email code. It has no session, so it cannot use a fresh sign-in; it says to use a signed-in browser for that. A client with no person behind it, an app frame or an API key, shows no confirm control; where one asks, it offers to request confirmation, and you confirm on another of your devices.

### Passkeys are per home

A passkey is registered at one home, under that home's host as its relying party, and confirms changes only there. No home accepts another home's passkey, and changing this home's host needs a new registration. Your first passkey may be registered from a recent sign-in through one of this home's own doors (`reauth_seconds`, five minutes by default); after that, registering or removing a passkey is itself a sensitive change. If you lose every way to confirm, this home's platform administrator can authorize a new passkey for you; you and your athanors' members are told.
