# Identity and Recovery

How a person gets an identifier other homes know them by, how its keys are kept and rotated, how the printed kit brings it back on a fresh installation, and what each loss costs. The person's own settings page (**Settings → Your identity**) shows all of it; every change there is an operation through the home's gate, and the command line reaches the same operations.

---

## Keys, Identifier and Directory

Your home holds two keys for you, created at your first sign-in:

- the **live key**, which signs what you send to other homes: a sign-in at another home, and the certificates of your devices;
- the **operational key**, which only rotates the live key.

Both are sealed at your home, each under its own purpose, apart from every athanor's vault. The separation is a limit on what each is used for, not a second line of defense: both sit behind the same home, so whoever takes the home's machine and its keyring takes both. That is why recovery does not rest on either.

**Enrolling** gives you an identifier (`per_…`), the hash of the first entry of your identity's log. It never changes. The log lives at one **directory**, which orders every change of your keys; homes that rely on your identity read your current keys there, never from your home, which may be the stolen one. A person who never enrolls keeps their keys, their home and their local devices, and never touches a directory.

Your home's settings page shows your identifier, the directory, and the head of your log (its `key_epoch`: the entry that introduced your current live key).

### Choosing the directory

The deployment names the directory its people enroll at, explicitly, in `CYFR_DIRECTORY_URL`: an `https` URL with no hosted default. No operation, page or person chooses another one. Unset, everything else works, local pairing included, and enrolling says which setting the operator owes.

Choosing a directory is choosing how long an identity lasts:

- **While it cannot be reached**, rotating your key, recovering and other homes' checks of your identity wait. Each relying home keeps serving your work from the head it last verified for `identity_freshness_seconds` (300 by default), then pauses it with a sentence saying so; your own home keeps working, and your session and devices stand.
- **If it is gone for good**, rotation, recovery and other homes' trust in your identity end for every identifier it orders. No identity moves to another directory, and there is no re-enrollment under another one: other homes invite you again through another door.

The directory holds your public keys, your recovery policy and your log. It holds no private key, no home address, no thread, no contact list and no list of the homes your devices saved. It is trusted to keep one consistent order and to answer honestly; signatures stop it forging anything, but a dishonest directory could withhold an update or keep answering an old head as current, and nothing detects that.

Any CYFR node can serve one (`CYFR_DIRECTORY_SERVE=writer`, or `mirror` for a read-only copy of a store it shares). Putting the only writer on the home it recovers loses that recovery when the home is lost. An operator serving a public directory owns its storage quota and its retention: each identifier's log is kept for good and only grows (`CYFR_DIRECTORY_MAX_IDENTITIES`, `CYFR_DIRECTORY_LOG_BYTES` and the recovery reserve bound it), and its requests are bounded per source and per installation. CYFR runs no hosted directory: a directory a deployment names is one its operator, or someone they trust, runs.

The directory's URL is public, and a relying home reads it from your identity. A directory hosted on your own home tells every home you sign in at where that home is.

---

## Enrolling and the Printed Kit

Enrollment is drawn only in your home's system layer, never in an app, and asks for a fresh confirmation (`devices-guide.md`). Before anything is asked, its form says what you commit to: the directory, what its loss means, what losing every kit means, and what a recovery restores. The confirmation's preview says the same.

1. The browser draws your kit's secret, 32 random bytes, and holds it for this one request; it is sent to your home under that request alone, and again, unchanged, once you confirm.
2. Your home registers your identity at the directory. A lost answer is retried with the same request and the same first entry, so it registers once.
3. The **kit** appears in the prompt: three lines.

   - **Identifier** — `per_…`
   - **Directory** — the directory's URL
   - **Recovery secret** — the secret that signs a recovery

   Print them or write them down, and keep them apart from your devices. The prompt shows them until you say they are saved.
4. **I saved this kit** erases the secret at your home for good. Until then, **Show kit** on the settings page shows it again, each time under a fresh confirmation; after, nothing can show it.

The three lines are everything a recovery of the identity needs. They never pass through an app, an address, the browser's storage or a log.

Until the directory accepts your enrollment, only the browser that began it holds the kit's secret. If that browser lost it (closed, reloaded or gone) before the directory answered, the settings page offers **Abandon and start again**: the unfinished enrollment ends, and you enroll anew with a new kit under a new identifier. A first entry the directory may already have registered stays there unused, under an identifier nobody holds a kit for. Once the directory has accepted it, your identity is registered and **Show kit** shows its kit instead.

### Every copy is a key

Anyone holding a copy of a kit can replace your keys, and the directory cannot tell your copy from theirs: each recovery replaces the keys the one before it installed, so whoever recovers last holds the identity. A kit stays one of your identity's kits for good; no kit is ever taken out of the set. Keep kits as you would keep the deed to something.

### More than one kit

Add a second kit before you rely on one (**Add another printed kit**). It is signed by a kit you hold now, whose recovery secret you type into the prompt; the new kit's secret is drawn in the browser as the first was, and delivered and acknowledged the same way. Either kit alone recovers the identity. Adding a kit moves your log's head, so every other home ends the sessions and device certificates it bound to your previous head, as a rotation does; your passkeys there stay.

A printed kit is the only recovery holder. No device holds recovery material.

---

## Rotating the Live Key

**Rotate the live key** replaces the live key, under a fresh confirmation, through one durable attempt: a lost answer is reconciled against the directory's log and never rotates twice. The operational key stays. Every other home ends the sessions, device certificates and pending confirmations it bound to the old key within `identity_freshness_seconds`. Your devices paired at this home renew with the key each stored and keep working; see `devices-guide.md`.

If a recovery or another rotation replaced the keys first, the attempt ends without changing anything here, and says so.

---

## Restoring on a Fresh Installation

A restore brings your identity back onto an empty installation from one kit. It is not an operation, since no person exists there yet, and it needs the installation's own capability besides the kit:

1. The operator sets `CYFR_RESTORE_TOKEN` on the fresh installation (`openssl rand -hex 32`) and gives you the token. While it is set, the installation's first sign-in is reserved for a restore: no door, an administrator's included, signs anyone in first.
2. Open `https://<installation>/restore`, and type the token and the kit's three lines. The browser sends them to that installation alone, the token in a request header; nothing goes into an address or the browser's storage, and the form is emptied once the restore completes or you clear it.
3. The installation checks the token first, then that the kit is one of your identity's kits now, before it claims anything. A wrong token or a mistyped kit spends nothing.
4. It stages new keys and asks the directory to recover your identity onto them. Each step is durable: if the installation stops partway, sending the same kit under the same token again resumes from the step it reached, and the page does that itself while the restore is underway.
5. Before it uses the new keys, it reads your log again. If a later recovery already replaced them, the restore ends as **superseded** and activates nothing; restore again from your kit under a new token.
6. It creates you on the installation, with no door yet, and signs you in.

The token restores one identity, once. Another kit under the same token is refused, and so is the same kit after the restore ended; the operator sets a new token to start again. An installation that already holds a person refuses a restore.

### After a restore

- **Register a passkey first.** The restore's session may register your first passkey within `reauth_seconds` of when the restore signed you in; keeping the page open does not extend that window. If it closes with no passkey registered, the restore page proves the kit again under a new challenge (**Prove the kit again**) for a new window, without restoring anything twice.
- **Then link your doors** (GitHub, Google or your organization's sign-in) from the settings page. Linking a door needs your session, a sign-in with that door, and a fresh confirmation: the new passkey.
- **Pair your devices again.** A device paired with your old home is not known here; its old certificate is refused, and it pairs anew.
- **Add your homes back.** See below.

A restore brings back your identity alone. It restores no private data (a backup does that) and no membership another home revoked.

---

## Your Saved Homes Are Your Device's

The homes you visit, as tabs and bookmarks, belong to each of your devices. No home stores, synchronizes or backs up that list, and a new browser starts with none. Saving an address grants no membership, and forgetting one revokes nothing.

So a recovery, or a new device, restores no list of homes: you add each address again, from a device that still holds it, from your bookmarks, or from an invitation, and sign in at each home. Each home keeps your memberships there on its own.

### Signing in at another home

Signing in at another home with your CYFR identity begins at your own home, which you name by its address, and both homes show the same short code so you can tell your sign-in is the one you started. Each home learns the other's address: the home you sign in at learns where your home is, and your home learns where you signed in. Neither learns your saved homes. See `devices-guide.md` for how such a home admits you, and for your passkeys there.

---

## Joining a Home That Is Not Your Own

A hub, or anyone's home, lets you in by your identifier (`per_…`, shown on your settings page), as it lets in an email address: its platform administrator allows your identifier at its door, and a member invites it to an athanor there. Nothing about this reaches your own home, and nothing at the hub learns your keys.

1. Open the hub's address. On its sign-in page, under **Sign in with your CYFR**, give your own home's address. The hub sends you there; a link someone sends you only fills that form, and never begins or confirms anything.
2. At your home's `/carry` page, press **Begin**: the sign-in is for that one hub. Sign in at your home first if you are not.
3. The hub shows a short code, and your home's confirmation names the same code. Confirm at your home with a fresh proof only if they match. Your home signs an assertion for that hub's challenge alone, and the browser takes it back.
4. The hub reads your identity at the directory your identity names, which need not be the hub's own, checks the assertion under your current keys, admits you, and makes you a member of the athanors you were invited to. Your home's `/carry` page records that you were admitted, and sends you on to the hub.

No cookie or session crosses from one home to the other, and no home keeps a list of the homes you sign in at. A step that is interrupted, a closed tab or a lost answer, resumes from your home's `/carry` page (**Resume**), under the same sign-in; a sign-in already admitted answers with the session it made, never a second one. **Cancel** ends one you no longer want.

At the hub, a sign-in through the CYFR door is not a fresh proof. Register a passkey there for the changes that need one: its administrator authorizes your first one (`Passkeys at Each Home` below). To pair a phone with the hub, open the hub's pairing code on it: the phone asks for your home's address, you certify it at your home under a fresh confirmation there, and it comes back and pairs. It renews its certificate at your home by proving its key, with no confirmation, until your keys change (`devices-guide.md`).

- **Leaving one athanor**, or being removed from it, ends that membership, your sessions bound to it and the devices you paired for it. Your other athanors at the hub, and your own home, are untouched.
- **After you rotate your live key**, the hub ends your sessions there within its `identity_freshness_seconds` (five minutes by default); sign in again. Your passkeys at the hub stay, and your devices there are certified again at your home.
- **After a recovery**, the hub ends your sessions there within the same bound, and with them the passkeys and device certificates bound to the old keys. Sign in again, naming your home's new address if it moved; your next passkey at the hub is authorized by its administrator again, and your devices are certified again at your home.
- **With your identity's directory unreachable**, the hub keeps admitting you on the head it last read for its `identity_freshness_seconds`, then pauses your protected work there with a sentence saying so, until the directory answers again. A new sign-in waits for the directory.
- **A new browser or device** starts with no saved homes and imports none: you open each home by its address or an invitation, and sign in there.

### Where joining is proven

The join proof (`tests/join-proof/`) runs every step in Chromium on the desktop, and a paired device's steps again in Chromium at a 720×720 touch viewport; in Firefox and WebKit it runs the sign-in at the hub, the carry between the homes and a second browser profile, each fresh confirmation those need given on a device paired in Chromium. Steps that use a passkey run in Chromium alone, whose virtual authenticator the proof drives. In-app browsers and mail clients that rewrite links are not covered.

---

## Passkeys at Each Home

A passkey belongs to the one home it was registered at, under that home's host, and proves things only there. Register one at each home where you confirm changes.

At a home that is not your own, a member who signed in only through the CYFR door holds no fresh method there. Their first passkey at that home is authorized by its platform administrator, who confirms that exact registration with a fresh proof of their own; the member and the administrator are told. A recovery of the member's identity retires the passkeys registered at that home before it, so the next one again needs the administrator; an ordinary rotation of the live key, or adding a printed kit, keeps them.

---

## What Each Loss Costs

| You lost | What still works | How you come back |
|---|---|---|
| A device | Everything else | Revoke it under **Devices**; pair a new one. Until revocation or expiry, what it showed and its certificate are the exposure. |
| A sign-in door | Your other doors and passkeys | Sign in another way and link a new door. Your last door goes only while you keep another way in. |
| A passkey | Your doors, your other passkeys | Register another; at another home with no fresh method left, its administrator authorizes it. |
| Your home, with a kit | Your identity, at the directory | Restore on a fresh installation from the kit, then re-pair devices and re-add homes. |
| A kit, with your home | Everything | Add another kit with a kit you still hold. The lost kit stays one of your identity's kits: whoever finds it can replace your keys, and no kit is ever taken out of the set. |
| Every kit, with your home | Your identity and home, with no way to recover them | Nothing can add a kit: a kit is added only by a kit. Keep the home safe; there is no re-enrollment. |
| The directory, for good | Your home, and local work | Rotation, recovery and other homes' trust end. Other homes invite you again through another door. |
| Your home, every kit and your online keys at once | Nothing of the identity | Start again as a new person: a new identity, invited again by each home. |
