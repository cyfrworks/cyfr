# Devices and Fresh Confirmation

How a CYFR box sets itself up and unlocks on its own screen, how a command line on a Linux machine or Pi becomes one of a person's devices, how a device stays connected, how passkeys sit beside the devices in one list, and how a sensitive change is confirmed from any device of theirs. A paired device holds a key of its own under a local unlock, a PIN or a passphrase; it holds no store, vault or person key. A browser holds no key of its own: it signs in and confirms with a passkey.

---

## Local and Remote People

CYFR records whether a person's keys are **local** (held at this CYFR) or **remote** (held at another CYFR that admitted them). A local person's pairing, passkeys and confirmation use the keys this CYFR stores.

A remote person signs in at this CYFR with their CYFR identity, and this CYFR reads their identity's current head from the directory their identity names, never from their own CYFR: when they sign in, before each of their fresh confirmations, and within `identity_freshness_seconds` for everything else. Past that bound with the directory unreachable, their work here pauses with a sentence saying so; their session and devices stand. A rotation or a recovery of their keys ends the sessions, device certificates and pending confirmations this CYFR bound to the old keys.

A remote person confirms a change at the CYFR they joined from their own CYFR, with no passkey or device there and nobody's authorization. The change's request offers **Confirm at your CYFR**: type your CYFR's address, and its `/carry` page opens with the change as the CYFR you joined stored it, which does nothing until you press **Confirm**. Your passkey or a device of yours there confirms it, never a sign-in or a code. Your CYFR then signs, with your identity's live key, that you confirmed that one request, for that CYFR and athanor, valid for a minute, and sends the browser back to that CYFR's `/confirm` page with it in the address's fragment. That CYFR checks it against your identity's head read live from your directory and confirms the request; the page that asked then completes the change. A device of yours certified for that CYFR also confirms there with its own unlock, under the head your directory names at that moment. A sign-in with your CYFR identity, however recent, proves nothing by itself. A recovery of your keys retires the passkeys registered and the sign-in methods linked there before it, at that CYFR's next fresh read of your identity; an ordinary rotation of your live key keeps them, and so does adding another recovery code.

A remote person's device pairs at the CYFR they joined only under a certificate their own CYFR issued for it, naming the device's client id from the pairing there, the device's key, the CYFR they joined and the athanor. The CYFR they joined checks it against their identity's current head, read live from their directory, and refuses the pairing without one. Every later request from the device is checked against that head within `identity_freshness_seconds`, and a head that has moved retires the certificate.

- **Approving it there.** The CYFR they joined opens the pairing for the device's code under their fresh confirmation, which they give at their own CYFR as above when they hold no device there yet.
- **Certifying.** The command line pairing there learns that the person's keys are at another CYFR and asks for that CYFR's address once. It must already be a device of theirs at that CYFR: it unlocks its own key there and asks their CYFR to certify the new key, which is a sensitive change there, confirmed in the terminal with a fresh unlock or on another device of theirs. It completes the pairing with that certificate, carried by the command line itself, never through a browser.
- **Renewing.** The CYFR they joined does not renew such a certificate. At half its life the device renews it at the person's own CYFR (`POST <their CYFR>/certify/v1/renew`): the certificate only says which certification it renews, their CYFR answers a challenge, and the device's proof of its key over that challenge is answered with the replacement. No confirmation is asked. The device then connects to the CYFR they joined again under the replacement, which that CYFR records once it verifies, so the device confirms there under the certificate it holds.
- **Certifying again.** A rotation or a recovery of their keys ends every certification their CYFR made under the old keys. The CYFR they joined then refuses the device's certificate, their CYFR refuses its renewal, and the device is certified again at their CYFR the same way, under a fresh confirmation there.

---

## The Box's Own Screen

A CYFR box with its own screen (`cyfr screen on`) sets itself up and signs you in there, with no phone, Google account or security key. Its screen holds a key of its own, protected by a local unlock: on a box with a TPM, a six-digit PIN unlocks a key the TPM keeps sealed and counts wrong PINs for; on a box without one, a passphrase of six generated words unlocks a key encrypted on its disk. The PIN or passphrase never leaves the box.

1. **Setup.** The screen shows whether the box's system and data disks are encrypted. Then type your name and your PIN or passphrase twice. The box makes its key, enrolls it as your first device under the setup token, and shows your recovery code as a QR code or prints it; keep it off the box. Press **I saved it**, and the screen opens Prism, signed in as you. If the answer to the enrollment is lost, the box finds its committed device again by proving the same key; it never makes a second you.
2. **Unlocking.** The screen starts locked, whatever its browser kept. Unlocking proves your key to CYFR on the box's own channel, which answers a one-time ticket; the browser spends it once for a session (`/auth/device/complete`). The session lasts one minute at a time and only the box's channel extends it, never past its certificate, so a copied cookie, a reboot, a dead shell or a lost connection ends it within a minute.
3. **Locking.** The **Lock** control, five minutes without local input, suspend, and the browser or the shell exiting lock the screen: the session ends at once and the screen asks for the PIN again. A lock is final for that session; unlocking makes a new one.
4. **Confirming on this device.** A change that needs a fresh confirmation offers **Confirm on this device**. The screen's own page shows the change as CYFR stored it, not as the asking page described it, and asks for your PIN or passphrase again before it signs; cancelling, waiting it out or a changed preview signs nothing. The page that asked then completes the change and reports its result.

**Devices** shows the box as one of your devices, with what holds its key and, from what it reported within the last minute, whether its disks are encrypted. A box that keeps its data unencrypted is named as one: whoever takes it reads everything. The box changes no disk or boot setting; an encrypted Ubuntu installation still asks for its passphrase at boot. Revoking the box from **Devices** ends its session at once.

Restoring onto a replacement box enrolls its screen as your first device, from the restore's own session and within its window (`reauth_seconds`), with a new key; the old box's key is never moved. After a backup restore, the old box's screen stays suspended until your recovery code re-enables it.

A key unlocked in memory is the limit of this protection: malware running on an unlocked box can copy it and sign until you revoke the box.

---

## Pairing a Device

1. On the new device, run `cyfr login` on a command line (below), or set up the box's own screen. It makes the device's key first, under its PIN or passphrase, before anything is asked of CYFR. It shows the key's code, its digest in groups of four characters, and a QR code of `https://<host>/devices/add#key=<digest>`.
2. Scan that QR code with the camera of a device of yours signed in to this CYFR: it opens **Add a device**, which opens **Devices** with the code filled in. On a device without a camera, open **Devices** in the shell and type or paste the code, with or without its spaces. The prompt lists the devices you paired in this athanor, each with when it was paired, what holds its key and when its certificate renews.
3. Check that the code is the one the new device shows and choose **Pair a device**. Pairing is a sensitive change, so it waits for a fresh confirmation (above), whose preview names the code again. Once confirmed, the prompt shows a QR code and the link `https://<host>/pair#code=<secret>`, the code it is for, and when it expires. `cyfr pair <code>` does the same from the command line and prints the link.
4. Paste the link into the new device. The secret is in the link's fragment, which a browser never sends to a server; opened in a browser, the `/pair` page says the link is for a command line or a box's screen and pairs nothing. The device sends this CYFR the secret, its public key and its digest, what holds its key and its name, signs the challenge CYFR answers with, and receives its client id and first certificate. It then connects the device channel under that certificate.

A browser pairs nothing: it holds no key of its own under a local unlock. It signs in with a passkey, which **Devices** lists as one of your ways in (below), or, if your identity is at another CYFR, from that CYFR. Who a device belongs to is the invitation's to say, never a cookie the device holds.

### The pairing link is bound to one device

The link pairs only the device whose code you approved: the invitation names the digest of that device's key, and CYFR refuses every other key, even one that proves itself, before it issues anything. A link opened in another browser, or after the device made a new key, is refused with that reason; approve the code it shows now. The link's secret is 128 random bits, lives five minutes, is stored only as a hash, and is used once. The passkey or paired device that confirmed the pairing must still stand when the device completes it; one revoked meanwhile leaves the link unusable. A link that was already used, or has expired, is refused with that reason; show a new one.

If the answer is lost after CYFR paired the device, the device was paired once. Within the link's five minutes the same device asks again with the same link and is answered that pairing; past them, show a new code and revoke the unused device from the list.

---

## Staying Connected

A device certificate names the device's key, its client, the CYFR and athanor, and when it expires. It is signed by your live key at this CYFR.

- **Lifetime.** A certificate lives `device_cert_seconds` (one hour by default). The device renews at half that, over its open connection, and keeps working under the old certificate until the replacement verifies. A remote person's device renews at their own CYFR instead, as above.
- **Expiry is strict** on this CYFR's clock. `clock_skew_seconds` applies only to a certificate's not-before time and never extends its life. The channel closes at the instant the certificate expires unrenewed.
- **Sleep.** A device that wakes, or reconnects, with an expired certificate renews before it sends anything else. Nothing else is sent until CYFR answers that the device stands.
- **Streams.** A connected device listens for your confirmations. When this CYFR cannot check the device's standing in time to pass on a change, or the device falls behind, the stream ends and the device opens it again and reads what is waiting.
- **A new address.** A certificate names this CYFR's address. After the CYFR moves to a new address, a device paired at the old one is not recognised there: pair it again at the current address, and revoke the old entry. The box's own screen enrolls again through the setup link.
- **Rotation.** After your live key rotates, existing certificates no longer verify. The device reconnects and renews with the key it stored: CYFR challenges that key afresh, checks the paired device still stands, and issues a replacement. The old certificate only says which device is asking; it authorizes nothing. An installation restored without the device's record needs the device paired again.
- **Revocation.** Revoking a device from **Devices** needs a fresh confirmation; revoking a passkey there revokes it wherever it synced (below). The device's channel closes at its next request, or within 30 seconds; every stream it holds ends first, and it is told its pairing ended. A renewal never revives a revoked device.

Revocation erases nothing already shown on the device. Until revocation or expiry, what the device shows and its unexpired certificate are the exposure of a lost device.

---

## The Command Line

`cyfr login` makes the command line on a Linux machine or a Pi one of your devices, as the box's own screen is. Nothing approves it from elsewhere.

1. On a machine this context has not paired, it makes the device's key and keeps it before it asks CYFR anything: sealed under a six-digit PIN in the machine's TPM where it has one, otherwise wrapped under a six-word passphrase it generates, entered twice. Six digits alone never protect a key on disk. It shows the key's code and its QR code.
2. Pair it from a device of yours (above) and paste the pairing link that device shows. A person new to this CYFR brings an invitation link instead, or, where this CYFR admits everyone, joins by the open admission. To set up a CYFR's first person at this terminal instead of the setup link, run `cyfr login --setup` in its directory, the only way on a headless CYFR (see the [identity guide](identity-guide.md)). The command line is then their first device.
3. From then on `cyfr login` asks for the PIN or passphrase, unlocks the key and starts your shell with a session of its own, which it keeps in memory and never writes to disk. The session lasts while that shell runs: its device channel keeps it, and leaving the shell, closing the terminal or losing the connection ends it within a minute. Locking, or revoking the device under **Devices**, ends it at once.
4. A change that needs a fresh confirmation can be confirmed in the terminal: it shows the change as CYFR stored it and asks for the PIN or passphrase again before it signs. You can confirm it on any other device of yours instead.

### A six-digit PIN your CYFR counts

A machine without a TPM can keep its key under a six-digit PIN instead of the passphrase, once it is one of your devices: `cyfr login --pin` unlocks with the passphrase or current PIN, asks for the new PIN twice, then asks a fresh confirmation, given in the terminal with the passphrase or current PIN or on another device of yours. Running it again replaces the PIN. The old passphrase or PIN stops opening the key when the command finishes: it saves the key under the new PIN and unlocks with it once, and that first unlock retires the old one. If the command stops before saving, the old one still opens the key; once it has saved, only the new PIN opens the key, even when that first unlock did not reach your CYFR; your CYFR then keeps the old PIN's count beside the new one until the new PIN's first unlock it takes.

The PIN never leaves the machine, and your CYFR never learns it. Each unlock sends your CYFR a blinded form of the PIN, and only your CYFR's answer, mixed with the PIN, opens the key. Your CYFR counts every attempt before it answers and makes the next one wait: one second after a wrong PIN, then two, doubling up to an hour, and an unlock that opens the key clears the count. It never locks you out for good. A copy of the machine's disk alone cannot guess the PIN: every guess goes through your CYFR, one counted attempt at a time.

- **Offline.** Unlocking needs your CYFR, the first unlock after a reboot and each fresh confirmation included: while it cannot be reached, the PIN opens nothing. Once unlocked, the key stays open until you lock or the machine restarts.
- **Another machine.** Your CYFR must be a different machine from the one the PIN protects. The box's own screen never offers a PIN this way, and `cyfr login --pin` refuses where your CYFR runs on the same machine, since both halves would sit on one disk.
- **What it does not stop.** Someone who has both the machine's disk and a copy of your CYFR's database can guess the PIN offline. A CYFR restored from a backup counts from where the backup left off, so the attempts made since are forgotten.
- **Revoking and restoring.** Revoking the device under **Devices** ends its PIN for good. After a backup restore the device is suspended, and its PIN opens nothing until your recovery re-enables the device.

`cyfr open` opens Prism in your browser through the shell's own one-time unlock ticket, as the box's screen does: no session is copied from the command line to the browser.

`cyfr login` is the command line's only sign-in: GitHub and Google sign a browser in, never the command line, and a session token saved in an older context opens nothing, so run `cyfr login` again. Unattended work, a CI job or a container, uses an API key (`cyfr --token`, see the README).

---

## Fresh Confirmation

Using what was granted, making a grant and answering an agent's approval need only your session. A short list of sensitive changes needs a fresh confirmation every time, for every person: entering or rotating a credential, widening where a credential may go or what a component may read of it (narrowing needs only your session), sharing a key or widening who it is shared with, issuing or rotating a credential that outlives the session (an API key, a webhook secret, registry push tokens, which `cyfr registry sync` and verifying a publisher namespace mint), pairing a device, revoking one, giving a device a PIN your CYFR counts, recovery material, rotating your live key, a remote sign-in assertion, linking or unlinking a sign-in method, and registering or removing a passkey.

Asking for one opens a pending confirmation of that exact change, shown with a preview CYFR stores: the change, what it concerns, the athanor and the CYFR. It lives `confirmation_seconds` (five minutes by default). The client that asked holds a secret for it that no other client sees, and only that client completes the change; every other client names the request by its public ref.

### On every device of yours

The shell, the console pages that ask for these changes (API keys, webhooks and the vault), and each paired device listen for your confirmations, and each shows a request as it opens: the preview, and which client asked (a browser and how it signed in, a paired device, an API key, or an app). Check the preview and who asked before you confirm. The page that asked marks the request as its own and shows it waiting, then approved once confirmed anywhere, then the change's actual outcome. A typed credential stays in the page's own form while it waits and is submitted again once confirmed; the server never holds it. Cancelling ends the request, and so does dismissing your own waiting request.

### Proofs

A proof covers that one request, is used once and expires with it.

- **A passkey** registered at this CYFR, asserting over the request. Face ID, a fingerprint or a security key.
- **A device of yours**: the box's own screen or a command line signs the request's stored digest with its key, after you unlock it again on its own page or in the terminal (above).
- **Your own CYFR**, for a person whose identity is kept at another CYFR (above).
- **A fresh sign-in** at the identity provider you signed in with, forced to ask you again, or **a code sent to your verified email**, prove that you signed in or read a mailbox, not that you hold a key. They confirm only two things: your recovery while this CYFR recovers from a declared backup restore, and your first passkey or device before you ever held one. Outside those, the request does not offer them, and CYFR refuses one begun earlier. CYFR has no mail transport, so the code is not offered.

A client with no person behind it, an app frame or an API key, shows no confirm control; where one asks, it offers to request confirmation, and you confirm on another of your devices.

### Adding a device, a passkey or a sign-in method

Pairing another device (or certifying one for another CYFR), registering another passkey, linking a sign-in method and giving a device a PIN your CYFR counts each add a way to act as you. Once you hold a passkey or a device at this CYFR, each needs a confirmation from one of them, or, for a person whose identity is at another CYFR, from that CYFR.

Before your first passkey or device, a fresh sign-in or a code confirms the first one, once, and nothing else: a person who signed in with GitHub or Google and asks for any other sensitive change is told to add a passkey or a device first. Whichever lands first, your first passkey or your first paired device, closes that path for good: revoking every passkey and device later does not reopen it. If you lose them all, recover through this CYFR's platform administrator (below), or, after this CYFR was restored from a backup, with your recovery code.

### Passkeys in Devices

**Devices** lists each passkey beside your devices, labelled **Passkey**: one entry per passkey registered here, not per phone or computer. A passkey your platform may sync, to your other phones and computers through your Apple, Google or password manager account, says so. Revoking it from **Devices** revokes the passkey itself: it stops signing in and confirming on every machine it synced to, and the sessions it signed in end. A session a passkey signed in lasts as any sign-in's does, since CYFR cannot see when the phone or computer locks. A passkey never becomes a device key: it signs only WebAuthn's own requests, here.

### Passkeys are per CYFR

A passkey is registered at one CYFR, under that CYFR's host as its relying party, and confirms changes only there. No CYFR accepts another CYFR's passkey, and changing this CYFR's host needs a new registration. Your first passkey may be registered from a recent sign-in through one of this CYFR's own sign-in methods (`reauth_seconds`, five minutes by default) only while you hold no other fresh method here; otherwise, and for every later passkey, registering or removing one is itself a sensitive change confirmed with a method you already hold, and once a passkey or a paired device exists here, registering another is confirmed with one of them (above). If you lose every way to confirm, this CYFR's platform administrator can authorize a new passkey for you; you and the administrator are told.

---

## When CYFR's Address Changes

CYFR's address is its tailnet name, its domain, or `localhost` when only its own computer reaches it, and it changes when `cyfr access` moves CYFR to another mode or name. Before it makes such a change, `cyfr access` lists what stops working, unless no one is set up on CYFR yet to lose anything:

1. **Passkeys.** Passkeys made at the old address no longer sign anyone in, since their relying party is the old host (above). The setup link at the new address registers the administrator's passkey there; everyone else registers one, which an administrator authorizes.
2. **Paired devices.** Pair every device again, at the new address.
3. **Clients and callbacks.** Update the redirect address in OAuth apps you registered (vault credentials, an OIDC issuer), the URL your webhook senders call, CLI contexts and MCP clients.
4. **Saved addresses.** Every other CYFR and device that saved the old address needs the new one.

Your CYFR identity does not change. With tailnet access, choose CYFR's machine name once, for this reason: a new name is a new address.
