# Devices and Fresh Confirmation

How a CYFR box's own screen, or a computer with the CYFR app, becomes a device of your account, how it is added by approval, how it stays connected at each CYFR, how your passkeys sit beside your devices, and how a sensitive change is confirmed by a key of yours. A device holds one key of your account under a local unlock, a PIN or a passphrase, and serves every CYFR you use; it holds no store, vault or other key. A browser holds no key of its own: it signs in and confirms with your passkey, through the account pages ([identity-guide.md](identity-guide.md)).

---

## A Device's Key

A device keeps one key, made on it and never exported, for every CYFR it signs in to, in `~/.cyfr/device` under your login on that machine, which the box's screen and the CYFR app share.

- **On a machine with a security chip**, the chip seals the key under a six-digit PIN you choose, and allows eight wrong tries, then one every ten minutes.
- **On a machine without one**, the key is encrypted on its disk under a passphrase of six words drawn for you and shown once; write it down. Six digits alone never protect a key on disk.

The PIN or passphrase never leaves the device: a CYFR checks the key's signature, never the PIN. A key unlocked in memory is the limit of this protection: malware running on an unlocked device can copy it and sign until you remove the key from your account.

---

## Adding a Device to Your Account

A device joins your account by your approval, never by a link it is handed:

1. **On the device**, on the box's screen or in the CYFR app, choose **Add this device to my account**. It makes its key under its PIN or passphrase first, then shows the key's code (16 letters and digits), the account service's address, and a QR code of the account page that adds it (`/account/add`).
2. **Approve it with your passkey on another device of yours.** On a phone or computer where you use your passkey, scan the QR code or open its address: the page asks "Add this device to your account?" and shows the code. Approve only if it shows the same code at the account service's address the device named, then **Add with your passkey**: the first passkey prompt names your account and the second signs the addition.
3. **Type your name on the device** and press **I approved it**, which waits until your account lists its key. Then the device goes on by itself.

Nothing is approved at a CYFR. A device's first connection to each CYFR introduces it: it names its key and your account, signs the request that CYFR answers with after its own unlock, and the CYFR checks the signature against your account's keys, admits you by its own rules, and issues the device a certificate of its own. A device that makes a new account with **Set up CYFR** ([identity guide](identity-guide.md)) is that account's first key and needs no approval.

---

## The Box's Own Screen

A CYFR box with its own screen (`cyfr screen on`) sets itself up and signs you in there, with no phone or security key, through a key of its own under its local unlock.

1. **Setup.** The screen says when the box's system disk or CYFR's data volume is not encrypted, or when that cannot be told. **Set up CYFR** makes your account with the box as its first device and shows your recovery code as a QR code to scan or print; keep it off the box. **Add this device to my account** adds the box to an account you already have instead (above). Either way, on a CYFR nobody has set up yet the box brings the setup token with it, so that account becomes the installation's first person; on one already set up it brings nothing, and the CYFR's allowlist decides.
2. **Unlocking.** The screen starts locked, whatever its browser kept. Unlocking proves the box's key to CYFR on the box's own channel, which answers a one-time ticket; the browser spends it once for a session (`/auth/device/complete`). The session lasts one minute at a time and only the box's channel extends it, never past its certificate, so a copied cookie, a reboot, a dead shell or a lost connection ends it within a minute.
3. **Locking.** The **Lock** control, five minutes without touch, key or pointer input (whatever is playing on the screen), suspend, and the browser or the shell exiting lock the screen (a screen that cannot tell when to lock stays locked and says why on its page): the session ends at once and the screen asks for the PIN or passphrase again. A lock is final for that session; unlocking makes a new one.
4. **Confirming on this device.** A change that needs a fresh confirmation offers **Confirm on this device**. The screen's own page shows the change as CYFR stored it, not as the asking page described it, and asks for your PIN or passphrase again before it signs; cancelling signs nothing.

**Devices** in Prism's shell lists the box with what holds its key and, from what it reported within the last minute, whether its disks are encrypted. A box that keeps its data unencrypted is named as one: whoever takes it reads everything, so keep it where only people you trust can reach it, or install Ubuntu again with disk encryption turned on. The box changes no disk or boot setting; an encrypted Ubuntu installation still asks for its passphrase at boot. **Devices** also lists each passkey a browser asks to add to your account, with its code, which a device of yours approves ([identity-guide.md](identity-guide.md#signing-in-at-a-cyfr)).

---

## The CYFR App

The CYFR app shows CYFR in a window of its own on Linux, macOS or Windows, connected to a CYFR that runs elsewhere; the computer needs no Docker. Its packages are not signed or published with a release yet, and setting up CYFR on the computer itself comes in a later version of the app.

1. **Connect.** Open the app, type the CYFR's address under **Connect to a CYFR**, and press **Connect**; the app fills in the address it last connected to. It reads which account service that CYFR signs its people in at. When that is not cyfr.run, the app shows the account service's full address beside the CYFR's and asks once: press **Go on** only if you expected that address, and **Cancel** sends nothing there. The app remembers your answer while that CYFR names the same account service, and asks again once it names another. The app connects to one CYFR at a time: to connect to another, quit it and open it again.
2. **Sign in with your passkey** (macOS and Windows). The CYFR's own sign-in page opens, and its **Sign in with your account** opens the account service's page in a window of its own, which shows only the account service's sign-in and recovery pages; your passkey signs there, and the answer goes back only to the CYFR window that asked ([identity guide](identity-guide.md#signing-in-at-a-cyfr)). **Confirm with a passkey** opens that same window. On Windows, Windows Hello keeps the passkey; on macOS, Touch ID comes with the signed Mac package, and until then use this computer's key.
3. **Use this computer's key** (the only way on Linux). The app shows the device's pages, as the box's screen does: **Set up CYFR** makes a new account with the computer as its first key, and **Add this device to my account** adds it to the account you have, approved on another device of yours that shows the same code at the same account service (above). From then on its PIN or passphrase unlocks it, **Open CYFR** opens it, and its session and **Confirm on this device** work as on the box's screen.
4. **Locking.** The app locks when the computer locks or sleeps, when one of its pages stops, and, with this computer's key, when you press **Lock** in CYFR's top bar: it closes CYFR's windows, forgets the key it unlocked, and asks you to sign in again. It also signs CYFR's session out at the CYFR, however you signed in; when the CYFR does not confirm the sign-out, the app says so, and that sign-in stands until it expires or you sign it out under **Settings → Keys on your account**. Quitting the app signs out the same way. Leaving the computer idle does not lock the app; the computer's own lock does. On Linux, where the app cannot tell when the computer locks or sleeps, its first page says so. Unlocking again needs your passkey, or the computer's PIN or passphrase.
5. **A company sign-in.** The app does not offer one. At a CYFR that requires it, the app says "This CYFR requires company sign-in. Open its address in a browser to continue." once you have signed in, or added the computer to your account: open the CYFR's address in a browser instead.

The app never gives a page your camera, microphone, screen or other devices.

---

## Staying Connected

A device certificate is one CYFR's own word that a device of your account is admitted there. It names the device's key, its client there, your account and the athanor, and that CYFR signs it with a key of its own that no other CYFR reads.

- **Lifetime.** A certificate lives `device_cert_seconds` (one hour by default). The device renews at half that, over its open connection, and keeps working under the old certificate until the replacement verifies.
- **Expiry is strict** on that CYFR's clock. `clock_skew_seconds` (60 by default) applies only to a certificate's not-before time and never extends its life. The channel closes at the instant the certificate expires unrenewed.
- **Sleep.** A device that wakes, or reconnects, with an expired certificate renews by proving its key before it sends anything else.
- **Streams.** When a CYFR cannot check the device's standing in time to pass on a change, or the device falls behind, the stream ends and the device opens it again and reads what is waiting.
- **Your account's keys.** Every request the device makes is checked against your account's keys as that CYFR last read them, within `identity_freshness_seconds` (five minutes by default). Removing the device's key from your account ends its certificates and sessions at each CYFR once that CYFR reads the removal, and replacing everything with your recovery code ends all of them. A device whose key was removed says so at its next unlock and shows the same key's code and QR code again; approving it adds that same key back, and no new key is made.
- **Signing it out of one CYFR.** **Sign out this device** under **Devices** in Prism's shell needs a fresh confirmation. The device's channel there closes within 30 seconds, ending its streams and its session. Its key stays on your account, so its next unlock introduces it to that CYFR again: to end a device everywhere, remove its key from your account. **Settings → Keys on your account** lists the device by its name, with its sessions at that CYFR; **Sign out** there ends one session alone and leaves the device's channel connected.

Signing out erases nothing already shown on the device. Until its key is removed, what the device shows and what its unlocked key signs are the exposure of a lost device.

---

## Passkeys

A passkey lives at the account service, whose address is its relying party, so one passkey signs you in and confirms your changes at every CYFR that uses that account service. Your phone or computer keeps it under its own screen lock, and your platform may sync it to your other phones and computers through your Apple, Google or password manager account.

**Settings → Keys on your account** lists every key of your account, as its log lists them: each passkey by its maker and the date it was added ("Apple Passwords passkey, added 8 Nov 2026"), and each device by the name it gave. A passkey's maker is what your browser reported when you made it; a passkey whose browser said nothing, or made before makers were recorded, reads as a passkey. Under each key are its sessions at that CYFR: the browser and system, when it signed in and when it was last seen. **Sign out** next to a session ends that session alone; the key stays on your account and can sign in again. Removing a key is `/account/devices`, with another passkey, or `/account/recover`, with your recovery code, and that ends it at every CYFR; the card links there. A session a passkey signed in lasts as any browser sign-in's does, since no CYFR can see when the phone or computer locks.

---

## Fresh Confirmation

Using what was granted and making a grant need only your session. A short list of sensitive changes needs a fresh confirmation every time, for every person:

- entering or rotating a credential, and widening where a credential may go or what a component may read of it (narrowing needs only your session);
- sharing a key, or widening who it is shared with;
- issuing or rotating a credential that outlives the session: an API key, a webhook secret, or registry push tokens minted under a stored push token;
- revoking a device connected at that CYFR;
- re-enabling an API key or a webhook after a declared restore;
- for the platform administrator of a CYFR that serves its own account service, closing an account there.

A request to the registry that your passkey signs, over the exact operation the account page shows in words, is that operation's own confirmation: **Sync push tokens** and verifying a publisher namespace on the Registry page ask nothing more.

Asking for one opens a pending confirmation of that exact change, shown with a preview CYFR stores: the change, what it concerns, the athanor and the CYFR. It lives `confirmation_seconds` (five minutes by default). The client that asked holds a secret for it that no other client sees, and only that client completes the change; every other client names the request by its public ref.

### On every device of yours

Prism's desktop and the pages that ask for these changes (API keys, webhooks, the vault, the registry and Settings among them), in a browser or on the box's screen, show each request as it opens: the preview, and which client asked (a browser, a device, an API key, or an app). Check the preview and who asked before you confirm. The page that asked marks the request as its own and shows it waiting, then approved once confirmed anywhere, then the change's actual outcome. A typed credential stays in the page's own form while it waits and is submitted again once confirmed; the server never holds it. Cancelling ends the request, and so does dismissing your own waiting request.

### Proofs

A proof covers that one request, is used once and expires with it. Only a key of your account gives one, checked against your account's keys at that moment:

- **A passkey**: **Confirm with a passkey** opens the account page in a new tab, which says "Confirm a change at" that CYFR's address, and your passkey signs that one request, with your face, fingerprint or screen lock.
- **A device of yours**: the box's own screen, or the CYFR app on a computer you unlocked with its PIN or passphrase, signs the request's stored digest with its key, after you unlock it again on its own page (above).

A sign-in, however recent, proves nothing by itself, and neither does a company sign-in. A client with no person behind it, an app frame or an API key, shows no confirm control; where one asks, it offers to request confirmation, and you confirm on a device of yours.

---

## When CYFR's Address Changes

CYFR's address is its tailnet name, its domain, or `localhost` when only its own computer reaches it, and it changes when `cyfr access` moves CYFR to another mode or name. Your account and its passkeys do not change: they live at the account service, not at CYFR's address.

1. **Sessions.** Every browser signs in again at the new address, with the same passkey.
2. **Devices.** The box's screen drops the certificate it held for the old address at its next unlock and introduces itself at the new one with the same key, and the CYFR app does so once you connect it to the new address; nothing is approved.
3. **Clients and callbacks.** Update the redirect address in OAuth apps you registered (vault credentials, a company's sign-in issuer), the URL your webhook senders call, the command line's contexts and MCP clients.
4. **Saved addresses.** Every device that saved the old address needs the new one.

A CYFR that serves its own account service is the exception: its people's passkeys live at its address, and every account made there names it, so it keeps its address for good. With tailnet access, choose CYFR's machine name once: a new name is a new address.
