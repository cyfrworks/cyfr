# Devices and Fresh Confirmation

How a person pairs a phone or another browser with CYFR, how that device stays connected, how a command line is signed in by their approval, and how a sensitive change is confirmed from any device of theirs. A paired device shows CYFR's pages and prompts and holds a key of its own; it holds no store, vault or person key.

---

## Local and Remote People

CYFR records whether a person's keys are **local** (held at this CYFR) or **remote** (held at another CYFR that admitted them). Everything in this guide works for a local person with no directory and no recovery kit: local pairing, local passkeys and local confirmation use the keys this CYFR stores.

A remote person signs in at this CYFR with their CYFR identity, and this CYFR reads their identity's current head from the directory their identity names, never from their own CYFR: when they sign in, before each of their fresh confirmations, and within `identity_freshness_seconds` for everything else. Past that bound with the directory unreachable, their work here pauses with a sentence saying so; their session and devices stand. A rotation or a recovery of their keys ends the sessions, device certificates and pending confirmations this CYFR bound to the old keys.

A remote member confirms a change at the group's CYFR with a fresh method there, as anyone does (below): a passkey registered there, or a fresh sign-in with a sign-in method of theirs that CYFR can ask again. A sign-in with their CYFR identity, however recent, is none of these and registers none by itself. A member who holds none of them there cannot enter a credential into its vault, pair a device or link a sign-in method there until that CYFR's platform administrator authorizes a passkey they register; a member who holds one confirms their next passkey themselves. A recovery of the member's keys retires the passkeys registered and the sign-in methods linked there before it, at that CYFR's next fresh read of their identity, and their next passkey again needs the administrator unless another fresh method remains to them; an ordinary rotation of their live key keeps those passkeys and sign-in methods, and so does adding another printed kit.

A remote member's device pairs at the group's CYFR only under a certificate their own CYFR issued for it, naming the device's client id from the pairing there, the device's key, the group's CYFR and the athanor. The group's CYFR checks it against their identity's current head, read live from their directory, and refuses the pairing without one. Every later request from the device is checked against that head within `identity_freshness_seconds`, and a head that has moved retires the certificate.

- **Certifying.** Opened on a pairing code of the group's CYFR, the device learns that the member's keys are at another CYFR and asks for that CYFR's address. It keeps the code and its key pair for the code's five minutes, and takes the member to their CYFR's `/carry` page, which shows the group's CYFR, the athanor and the client it would certify the device for and does nothing until they press **Certify**. Certifying is a sensitive change there, confirmed with a fresh proof at their CYFR. Their CYFR then sends the browser back to the `/pair` page of the group's CYFR with the certificate in the address's fragment, and the device completes its pairing with it. The device takes a certificate there only within five minutes of the member naming their CYFR, and only one that CYFR issued for this device's key, its client, the group's CYFR and the athanor; any other link, crafted or stale, changes nothing.
- **Renewing.** The group's CYFR does not renew such a certificate. At half its life the device renews it at the member's CYFR, by `fetch` from the `/pair` page of the group's CYFR with no cookie or other credential (`POST <their CYFR>/certify/v1/renew`): the certificate only says which certification it renews, their CYFR answers a challenge, and the device's proof of its key over that challenge is answered with the replacement. No confirmation is asked. The device then connects to the group's CYFR again under the replacement; the group's CYFR records nothing for it. The device signs only the member's CYFR's renewal challenge for its own key and client, and on its channel to the group's CYFR only that CYFR's own challenge, so no relayed challenge buys a proof of its key. `/pair` is the one CYFR page allowed to connect to other HTTPS origins, for this.
- **Certifying again.** A rotation or a recovery of the member's keys ends every certification their CYFR made under the old keys. The group's CYFR then refuses the device's certificate, their CYFR refuses its renewal, and the device offers to certify it again at their CYFR, under a fresh confirmation there, with that CYFR's address filled in and editable, since after a restore their CYFR may be another one. When the group's CYFR refuses the certificate and their CYFR cannot be reached to renew it three times in a row, as when it was lost and they restored elsewhere, the device makes the same offer and keeps trying their CYFR meanwhile. A certificate brought back from their CYFR replaces the device's own only once the group's CYFR accepts it.

---

## Pairing a Device

1. On the new device, open `https://<host>/pair`. The page makes the device's key pair first, before anything is asked of CYFR. Its private key cannot be exported, and the browser keeps it across reloads. The page shows the key's code, its digest in groups of four characters, with a QR code of it.
2. On a device of yours signed in to this CYFR, open **Devices** in the shell. The prompt lists the devices you paired in this athanor, each with when it was paired and when its certificate renews.
3. Type the new device's code, with or without its spaces, and choose **Pair a device**. Pairing is a sensitive change, so it waits for a fresh confirmation (above), whose preview names the code: check it is the one the new device shows. Once confirmed, the prompt shows a QR code and the link `https://<host>/pair#code=<secret>`, the code it is for, and when it expires. `cyfr pair <code>` does the same from the command line and prints the link.
4. Open the link on the new device, in the browser that showed the code, by scanning the QR code or typing the link. The secret is in the link's fragment, which a browser never sends to a server; the `/pair` page reads it and removes it from the address at once. The page sends this CYFR the secret, the device's public key and its digest, signs the challenge CYFR answers with, and receives the device's client id and first certificate. It then connects the device channel under that certificate.

The `/pair` page reads no session: a sign-in cookie the browser still holds, even another person's, does not choose who the device belongs to. The invitation does.

A browser that already holds a paired device asks before a pairing link replaces it. Keeping the device connects as before. Replacing it is a choice you make: the device's key and certificate are erased from the browser first, and the old device stays listed under **Devices** until you revoke it.

### The pairing link is bound to one device

The link pairs only the device whose code you approved: the invitation names the digest of that device's key, and CYFR refuses every other key, even one that proves itself, before it issues anything. A link opened in another browser, or after the device made a new key, is refused with that reason; approve the code it shows now. The link's secret is 128 random bits, lives five minutes, is stored only as a hash, and is used once. The passkey or paired device that confirmed the pairing must still stand when the device completes it; one revoked meanwhile leaves the link unusable. A link that was already used, or has expired, is refused with that reason; show a new one.

If the browser closes after CYFR paired the device but before the answer arrived, the device was paired once and holds no certificate. The same link then answers that the code was already used: show a new code, and revoke the unused device from the list.

---

## Staying Connected

A device certificate names the device's key, its client, the CYFR and athanor, and when it expires. It is signed by your live key at this CYFR.

- **Lifetime.** A certificate lives `device_cert_seconds` (one hour by default). The device renews at half that, over its open connection, and keeps working under the old certificate until the replacement verifies. A remote member's device renews at their own CYFR instead, as above.
- **Expiry is strict** on this CYFR's clock. `clock_skew_seconds` applies only to a certificate's not-before time and never extends its life. The channel closes at the instant the certificate expires unrenewed.
- **Sleep.** A device that wakes, or reconnects, with an expired certificate renews before it sends anything else. Nothing else is sent until CYFR answers that the device stands.
- **Streams.** A connected device listens for your confirmations. When this CYFR cannot check the device's standing in time to pass on a change, or the device falls behind, the stream ends and the device opens it again and reads what is waiting.
- **Rotation.** After your live key rotates, existing certificates no longer verify. The device reconnects and renews with the key it stored: CYFR challenges that key afresh, checks the paired device still stands, and issues a replacement. The old certificate only says which device is asking; it authorizes nothing. An installation restored without the device's record needs the device paired again.
- **Revocation.** Revoking a device from **Devices** needs a fresh confirmation. The device's channel closes at its next request, or within 30 seconds; every stream it holds ends first, and it is told its pairing ended. A renewal never revives a revoked device.

Revocation erases nothing already shown on the device. Until revocation or expiry, what the device shows and its unexpired certificate are the exposure of a lost device.

---

## Signing In a Command Line

`cyfr login` signs the command line in by your approval in Prism.

1. The command line asks this CYFR for a sign-in, prints a link, `https://<host>/cli#code=<secret>`, and a code of eight characters, and waits. The secret is in the link's fragment, which a browser never sends to a server; the `/cli` page reads it and removes it from the address at once.
2. Open the link in a browser signed in to this CYFR, on the same machine or another device. Prism asks you to approve the command line on the machine it names and shows the code. Approve only if it is the code your terminal shows: a link someone else sent you shows theirs.
3. Approving issues a session that outlives the one you approve from, so it is a sensitive change (above), confirmed with your passkey, a fresh sign-in or on a device you paired, and its preview names the machine and the code again.
4. The command line receives its own session, saves it under the context it used (`--context`, or the current one), and says who signed in. It acts as you, in the athanor shown in the approval preview, until you revoke it or it has gone `session_ttl_hours` without use (30 days by default).

The link signs in once and lives five minutes. A link already used, expired, or one the command line stopped waiting for is refused with that reason: run `cyfr login` again. Not signed in to Prism, you are sent to sign in first; then open the link again, while the command line still waits. Ctrl-C, or the link's expiry, withdraws the sign-in, so an approval after that signs nothing in and one that landed first is ended. A command line killed outright leaves its sign-in to expire, and a session an approval gave it meanwhile is held by no one: revoke it under **Devices**.

**Devices** lists every command line signed in as you, by the machine it named and when it signed in, `cyfr login --provider` sign-ins included. Revoking one needs only your session and ends it; `cyfr logout` ends the command line's own. When the command line needs you to confirm something, it tells you to confirm on your screen, where the request names it as the command line on its machine.

On a machine where no one can approve it in Prism, `cyfr login --provider github` (or `google`) signs in with the provider's device flow instead.

`cyfr open` opens Aqua in your browser and nothing more. No session travels from the command line to a browser: a link that signed a browser in would be your session in the hands of whoever held it. Sign in there as you always do.

---

## Fresh Confirmation

Using what was granted, making a grant and answering an agent's approval need only your session. A short list of sensitive changes needs a fresh confirmation every time, for every person: entering or rotating a credential, widening where a credential may go or what a component may read of it (narrowing needs only your session), issuing or rotating a credential that outlives the session (an API key, a webhook secret, registry push tokens, which `cyfr registry sync` and verifying a publisher namespace mint, or a command line's session), pairing a device, revoking one, recovery material, rotating your live key, a remote sign-in assertion, linking or unlinking a sign-in method, and registering or removing a passkey.

Asking for one opens a pending confirmation of that exact change, shown with a preview CYFR stores: the change, what it concerns, the athanor and the CYFR. It lives `confirmation_seconds` (five minutes by default). The client that asked holds a secret for it that no other client sees, and only that client completes the change; every other client names the request by its public ref.

### On every device of yours

The shell, the console pages that ask for these changes (API keys, webhooks and the vault), and each paired device listen for your confirmations, and each shows a request as it opens: the preview, and which client asked (a browser and how it signed in, a paired device, an API key, or an app). Check the preview and who asked before you confirm. The page that asked marks the request as its own and shows it waiting, then approved once confirmed anywhere, then the change's actual outcome. A typed credential stays in the page's own form while it waits and is submitted again once confirmed; the server never holds it. Cancelling ends the request, and so does dismissing your own waiting request.

### Proofs

A proof covers that one request, is used once and expires with it.

- **A passkey** registered at this CYFR, asserting over the request. Face ID, a fingerprint or a security key.
- **A fresh sign-in** at the identity provider you signed in with, forced to ask you again. It opens in a new tab, so the asking page stays. The provider must report when you signed in. The page it returns to shows the change again, and confirms only when you approve it in a browser signed in as you.
- **A code sent to your verified email** is not offered: CYFR has no mail transport.

A paired device offers a passkey and a fresh sign-in it begins, which opens in a new tab and is approved there in a browser signed in to this CYFR; each counts as given on that device. A client with no person behind it, an app frame or an API key, shows no confirm control; where one asks, it offers to request confirmation, and you confirm on another of your devices.

### Adding a device, a passkey or a sign-in method

Once you hold a passkey or a paired device at this CYFR, three changes need a confirmation from one of them: pairing another device (or certifying one for another CYFR), registering another passkey, and linking a sign-in method. Your passkey's assertion qualifies, and so does a confirmation you give on a device you paired, whichever proof it uses there, a fresh sign-in it begins included. A fresh sign-in, asked for from a browser that is not a paired device confirms every other change but not these: their request offers only what qualifies and says to confirm with your passkey or on a device you paired.

Before your first passkey or device, a fresh sign-in confirms the first one, once. Whichever lands first, your first passkey or your first paired device, closes that path for good: revoking every passkey and device later does not reopen it. If you lose them all, recover with your recovery kit or through this CYFR's platform administrator (below).

### Passkeys are per CYFR

A passkey is registered at one CYFR, under that CYFR's host as its relying party, and confirms changes only there. No CYFR accepts another CYFR's passkey, and changing this CYFR's host needs a new registration. Your first passkey may be registered from a recent sign-in through one of this CYFR's own sign-in methods (`reauth_seconds`, five minutes by default) only while you hold no other fresh method here; otherwise, and for every later passkey, registering or removing one is itself a sensitive change confirmed with a method you already hold, and once a passkey or a paired device exists here, registering another is confirmed with one of them (above). If you lose every way to confirm, this CYFR's platform administrator can authorize a new passkey for you; you and your athanors' members are told.

---

## When CYFR's Address Changes

CYFR's address is its tailnet name, its domain, or `localhost` when only its own computer reaches it, and it changes when `cyfr access` moves CYFR to another mode or name. Before it makes such a change, `cyfr access` lists what stops working:

1. **Passkeys.** A passkey made at the old address stops working, since its relying party is the old host (above). Each person registers one at the new address, which this CYFR's platform administrator authorizes, as when every way to confirm is lost.
2. **Paired devices.** Pair every device again, at the new address.
3. **Clients and callbacks.** Update the redirect address in OAuth apps you registered (vault credentials, an OIDC issuer), the URL your webhook senders call, CLI contexts and MCP clients.
4. **Saved addresses.** Every other CYFR and device that saved the old address needs the new one.

Your CYFR identity does not change. With tailnet access, choose CYFR's machine name once, for this reason: a new name is a new address.
