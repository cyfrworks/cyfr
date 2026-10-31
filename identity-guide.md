# Identity and Recovery

How a person gets the name and identifier every CYFR knows them by, how their keys are kept and rotated, how their recovery code brings them back on a fresh installation, and what each loss costs. The person's own settings page (**Settings → Your name**) shows all of it; every change there is an operation through CYFR's gate, and the command line reaches the same operations.

---

## Your Name, Identifier and Keys

Your CYFR makes you when it admits you: its setup, an invitation, or signing up while its allowlist admits everyone. A sign-in method such as GitHub, Google or an OIDC issuer only unlocks the person who linked it, and never makes or recovers one. It holds two keys for you, made at that moment:

- the **live key**, which signs what you send to any other CYFR: a sign-in at another CYFR, and the certificates of your devices;
- the **operational key**, which only rotates the live key.

Both are sealed at your CYFR, each under its own purpose, apart from every athanor's vault. The separation is a limit on what each is used for, not a second line of defense: both sit behind the same CYFR, so whoever takes its machine and its keyring takes both. That is why recovery does not rest on either.

The same admission registers your identity at cyfr.run and claims your **name** there. Your **identifier** (`per_…`) is the hash of the first entry of your identity's log, and never changes. The log lives at one directory, cyfr.run's unless the operator names another (below), which orders every change of your keys; every CYFR that relies on your identity reads your current keys there, never from your own CYFR, which may be the stolen one.

Your name (`@mira`) is how people find you: an administrator or a member adds you by it, and it is your personal namespace for publishing components. It is yours for life: nobody else can take it, it is never released, and it cannot be changed. Someone who wants another name makes another identity, with its own keys and recovery code. cyfr.run answers a name with the identifier it names, never with keys or an address: your keys are read at the directory, and no address of any CYFR is kept there. Every CYFR stores the identifier a name named when it was given, never the name, as the key to your access.

Settings shows your name, and your identifier once, for the command line; no other default page shows the identifier or asks for it.

### Choosing the directory

The deployment names the directory its people are registered at in `CYFR_DIRECTORY_URL`, an `https` URL that defaults to `https://cyfr.run`, the directory CYFR hosts. An operator may name another; no operation, page or person chooses one.

Choosing a directory is choosing how long an identity lasts:

- **While it cannot be reached**, rotating your key, recovering and every other CYFR's checks of your identity wait. Each CYFR that relies on your identity keeps serving your work from the head it last verified for `identity_freshness_seconds` (300 by default), then pauses it with a sentence saying so; your own CYFR keeps working, and your session and devices stand.
- **If it is gone for good**, rotation, recovery and every other CYFR's trust in your identity end for every identifier it orders. No identity moves to another directory: every other CYFR invites you again with another sign-in method.

The directory holds your public keys, your recovery policy and your log. It holds no private key, no address of your CYFR, no thread, no contact list and no list of the addresses your devices saved. It is trusted to keep one consistent order and to answer honestly; signatures stop it forging anything, but a dishonest directory could withhold an update or keep answering an old head as current, and nothing detects that.

Any CYFR can serve one (`CYFR_DIRECTORY_SERVE=writer`, or `mirror` for a read-only copy of a store it shares). Putting the only writer on the CYFR it recovers loses that recovery when that CYFR is lost. An operator serving a public directory owns its storage quota and its retention: each identifier's log is kept for good and only grows (`CYFR_DIRECTORY_MAX_IDENTITIES`, `CYFR_DIRECTORY_LOG_BYTES` and the recovery reserve bound it), and its requests are bounded per source and per installation. The default, `https://cyfr.run`, is the one CYFR runs; a deployment that names another relies on its operator, or someone they trust, to run it.

The directory's URL is public, and a CYFR that relies on your identity reads it from that identity. A directory hosted on your own CYFR tells every CYFR you sign in at where your own CYFR is.

---

## Your Name and Recovery Code

Every person a CYFR makes meets the same two screens, at setup, on an invitation link, and when signing up at a CYFR whose allowlist admits everyone.

1. **Your name.** Type it after the `@`. A name is 1 to 39 lowercase letters and digits joined by single hyphens. The field checks it at cyfr.run as you type and says whether it is free or taken; **Create a passkey** stays off while it is taken or misspelt. If cyfr.run does not answer, the name is checked again when it is created.
2. **Create a passkey.** The passkey's registration is the one proof that makes you: in one transaction your CYFR makes you, your keys, your own athanor and the passkey, and the browser draws your recovery secret, 32 random bytes, which your CYFR seals until you save it. Nothing is sent to cyfr.run before that transaction commits.
3. **Your recovery code.** The second screen says "Registering @mira at cyfr.run." while your CYFR registers your identity at the directory and claims your name, then shows your **recovery code**: one line, `CYFR-` followed by fourteen groups of eight letters and digits. It spells your identifier and your recovery secret, with a check that catches a typo, so it is everything a recovery needs and nothing else. Copy it into your password manager, or print the page.
4. **I saved it** erases the secret at your CYFR for good and signs you in. From then on nothing can show that code again.

The four taps are the button, the passkey dialog, **Copy** and **I saved it**. If cyfr.run does not answer, the second screen says so and offers **Try again**. If someone took your name a moment before, or cyfr.run keeps it for itself, the screen asks for another name and **Use this name** claims it. Your person and your recovery attempt are kept from the first transaction, so a closed tab or a reload loses nothing: sign in with the passkey you made, and Settings shows the same screen, finishes the registration and offers **Show your recovery code**, under one passkey confirmation.

On a headless server, `cyfr login --setup` makes the first person the same way, with the setup token as its proof: it takes the name from `--name` or asks "Your name: @", prints your recovery code once your name is registered, and waits for Enter before it signs the command line in. The code stays in the terminal's scrollback until you clear it. A second `cyfr login --setup` before the code is saved shows the same code.

Your recovery code never passes through an app, an address, the browser's storage or a log.

### Every copy is a key

Anyone holding a copy of your recovery code can replace your keys, and the directory cannot tell your copy from theirs: each recovery replaces the keys the one before it installed, so whoever recovers last holds the identity. A recovery may replace the set of recovery codes too: a code stays valid only until a recovery names a set without it, and whoever recovers last decides the set. Keep it as you would keep the deed to something, apart from your devices.

### More than one recovery code

Add a second recovery code before you rely on one (**Add another recovery code** in Settings, offered again right after setup). A recovery code you hold approves the new one: you type it into the prompt, and the change asks a fresh confirmation. The new code is shown, copied and saved as the first was. Either code alone recovers the identity. Adding a code moves your log's head, so every other CYFR ends the sessions and device certificates it bound to your previous head, as a rotation does; your passkeys there stay.

Only a code you hold adds another, and no device holds recovery material.

---

## Rotating the Live Key

**Rotate the live key** replaces the live key, under a fresh confirmation, through one durable attempt: a lost answer is reconciled against the directory's log and never rotates twice. The operational key stays. Every other CYFR ends the sessions, device certificates and pending confirmations it bound to the old key within `identity_freshness_seconds`. Your devices paired at this CYFR renew with the key each stored and keep working; see `devices-guide.md`.

If a recovery or another rotation replaced the keys first, the attempt ends without changing anything here, and says so.

---

## Restoring on a Fresh Installation

A restore brings your identity back onto an empty installation from one recovery code. It is not an operation, since no person exists there yet, and it needs the installation's own capability besides the code:

1. The operator sets `CYFR_RESTORE_TOKEN` on the fresh installation (`openssl rand -hex 32`) and gives you the token. While it is set, the installation's first person is reserved for the restore: setup makes no one first, and the restored person is the installation's administrator.
2. Open `https://<installation>/restore`, and type the token and your recovery code. The browser sends them to that installation alone, the token in a request header; nothing goes into an address or the browser's storage, and the form is emptied once the restore completes or you clear it.
3. The installation checks the token first, then reads your identity at the directory it names (`CYFR_DIRECTORY_URL`, so it must be the directory your identity was registered at), and checks that the code is one of your identity's recovery codes now, before it claims anything. A wrong token, a code with a typo (the page says so) or a code that is no longer valid spends nothing.
4. It stages new keys and asks the directory to recover your identity onto them. Each step is durable: if the installation stops partway, sending the same code under the same token again resumes from the step it reached, and the page does that itself while the restore is underway.
5. Before it uses the new keys, it reads your log again. If a later recovery already replaced them, the restore ends as **superseded** and activates nothing; restore again from your recovery code under a new token.
6. It creates you on the installation, with no sign-in method yet, and signs you in.

The token restores one identity, once. Another identity's code under the same token is refused, and so is the same code after the restore ended; the operator sets a new token to start again. An installation that already holds a person refuses a restore.

### After a restore

- **Register a passkey first.** The restore's session may register your first passkey within `reauth_seconds` of when the restore signed you in; keeping the page open does not extend that window. If it closes with no passkey registered, the restore page proves your recovery code again under a new challenge (**Check your recovery code again**) for a new window, without restoring anything twice.
- **Then link your sign-in methods** (GitHub, Google or your organization's sign-in) from the settings page. Linking one needs your session, a sign-in with it, and a fresh confirmation: the new passkey.
- **Pair your devices again.** A device paired with your old CYFR is not known here; its old certificate is refused, and it pairs anew.
- **Add your saved addresses back.** See below.

A restore brings back your identity alone. It restores no private data (a backup does that) and no membership another CYFR revoked.

### When your CYFR is restored from a backup

Putting a backup back is a different thing: the operator runs `cyfr restore`, which declares it, and your CYFR retires the authority the backup carried before it admits anything. When you next open it:

- **You sign in again.** Every session ended. Your passkeys and paired devices are suspended, so neither signs you in or confirms anything until you re-enable it. Sign in with GitHub, Google or your organization's sign-in; your first confirmation is a fresh sign-in with the same method.
- **No sign-in method left?** Open `https://<your CYFR>/restore` and use **Recover after a restore**: type your recovery code. It stays in the browser, which reads your identifier and secret from it and signs your CYFR's challenge with the secret; your CYFR checks the signature against your identity read fresh from its directory. It answers a short credential that re-enables your passkeys, devices, keys and webhooks, and nothing else. Without your recovery code, a platform administrator authorizes a passkey you register for you instead.
- **Re-enable from the checklist.** The system layer lists what the restore suspended. Re-enabling a passkey or a device needs a fresh sign-in with GitHub, Google or your organization's sign-in, or your recovery code, never the passkey or device itself; once one is re-enabled, or a fresh one registered or paired under such a proof, your recovery is over and it confirms as before. A platform administrator can also end your recovery; what the restore suspended stays suspended. API keys and webhooks are re-enabled the same way.
- **Consent again, and rotate.** Every component's grant asks for consent again from the checklist, and every stored credential needs re-entering after you rotate it where it came from, since the backup's copy may be known. A run open at the backup ended uncertain and is never resumed; start it again.
- **Groups wait for everyone.** A group with a member still recovering admits no new member until each has. Someone who signs in only through GitHub, Google or an organization's sign-in, with no passkey or device, has nothing to recover and holds no group up. Removing someone and leaving work as before.

---

## Your Saved Addresses Are Your Device's

The address of each CYFR you visit, saved as a tab or a bookmark, belongs to the device that saved it. No CYFR stores, synchronizes or backs up your list of saved addresses, and a new browser starts with none. Saving an address grants no membership, and forgetting one revokes nothing.

So a recovery, or a new device, restores no list of saved addresses: you add each address again, from a device that still holds it, from your bookmarks, or from an invitation, and sign in at each CYFR. Each CYFR keeps your memberships there on its own.

### Signing in at another CYFR

Signing in at another CYFR with your CYFR identity begins at your own CYFR. On the other CYFR's sign-in page, **Sign in from your CYFR** opens one field, **Your CYFR**: type your CYFR's address, and **Continue** takes you there. The field is filled for you when a link brought you with your address in it, or when this browser signed in from that page before: it remembers the address you last continued with, for that CYFR's page alone, and nothing else. If the browser no longer holds the attempt when you come back (it lasts five minutes, and a newer one replaces it), begin again. Both CYFRs show the same short code so you can tell your sign-in is the one you started. Each learns the other's address, as the page says: the CYFR you sign in at learns where your own CYFR is, keeps it for that sign-in alone and shows it on no page to someone not signed in, and your own CYFR learns where you signed in. Neither learns your list of saved addresses, and cyfr.run learns neither. See `devices-guide.md` for how such a CYFR admits you, and for your passkeys there.

---

## Joining a CYFR That Is Not Your Own

Any CYFR that is not your own, a household's or a team's included, lets you in by your name (`@mira`): its platform administrator adds you to its allowlist, and a member adds you to an athanor there, or sends you an invitation link (below). The command line also takes your identifier (`per_…`, shown once in your settings). Either way the CYFR you join keeps the identifier your name names when you are added, never the name. Nothing about this reaches your own CYFR, and nothing at the CYFR you join learns your keys.

1. Open the address of the CYFR you join. On its sign-in page, choose **Sign in from your CYFR** and type your own CYFR's address. It sends you there; a link someone sends you only fills that field, and never begins or confirms anything.
2. At your CYFR's `/carry` page, press **Begin**: the sign-in is for that one CYFR. Sign in at your CYFR first if you are not.
3. The CYFR you join shows a short code, and your CYFR's confirmation names the same code. Confirm at your CYFR with a fresh proof only if they match. Your CYFR signs an assertion for the other CYFR's challenge alone, and the browser takes it back.
4. The CYFR you join reads your identity at the directory your identity names, which need not be its own, checks the assertion under your current keys, admits you, and makes you a member of the athanors you were invited to. Your CYFR's `/carry` page records that you were admitted, and sends you on to the CYFR you joined.

No cookie or session crosses from one CYFR to the other, and no CYFR keeps a list of where you sign in. A step that is interrupted, a closed tab or a lost answer, resumes from your CYFR's `/carry` page (**Resume**), under the same sign-in; a sign-in already admitted answers with the session it made, never a second one. **Cancel** ends one you no longer want.

At the CYFR you join, signing in with your CYFR identity is not a fresh proof. Register a passkey there for the changes that need one: its administrator authorizes your first one (`Passkeys at Each CYFR` below). To pair a phone there, open that CYFR's pairing code on the phone: the phone asks for your CYFR's address, you certify it at your CYFR under a fresh confirmation there, and it comes back and pairs. It renews its certificate at your CYFR by proving its key, with no confirmation, until your keys change (`devices-guide.md`).

- **Leaving one athanor**, or being removed from it, ends that membership, your sessions bound to it and the devices you paired for it. Your other athanors there, and your own CYFR, are untouched.
- **After you rotate your live key**, the CYFR you joined ends your sessions there within its `identity_freshness_seconds` (five minutes by default); sign in again. Your passkeys there stay, and your devices there are certified again at your CYFR.
- **After a recovery**, the CYFR you joined ends your sessions there within the same bound, and with them the passkeys and device certificates bound to the old keys. Sign in again, typing your CYFR's new address if it moved; your next passkey there is authorized by its administrator again, and your devices are certified again at your CYFR.
- **With your identity's directory unreachable**, the CYFR you joined keeps admitting you on the head it last read for its `identity_freshness_seconds`, then pauses your protected work there with a sentence saying so, until the directory answers again. A new sign-in waits for the directory.
- **A new browser or device** starts with no saved addresses and imports none: you open each CYFR by its address or an invitation, and sign in there.

### Joining by an invitation link

An invitation link admits someone new to a CYFR, or someone who already has a CYFR name. A member creates one for a group they sit in, on **Members**, where a name nobody holds yet offers a link with that name filled in; the platform administrator may also create one that names no group. The link is `<CYFR address>/invite#<code>`: it is shown once, works once, expires after seven days, and the CYFR keeps only the code's hash.

- **Someone new.** The page names who invited you and to which group, and shows the two screens of [Your Name and Recovery Code](#your-name-and-recovery-code), with the name field filled from the invitation. Your passkey makes you, your keys, your own athanor and your seat in the group at that CYFR. The identity made this way is held by that CYFR, as one made by its setup is.
- **Someone with a CYFR name.** **Already have a CYFR name? Sign in with it.** opens that CYFR's sign-in page with the invitation kept, and **Sign in from your CYFR** signs you in from your own CYFR as above. The sign-in redeems the invitation: it seats you in the group, and lets your identifier in from then on, so you sign in later without the link. That entry shows in the CYFR's allowlist, where its administrator can remove it. A deny always wins: an identity the CYFR denies is refused, the invitation stays unspent, and a deny written later outranks the entry the invitation left.

A link that has expired, been used or been revoked, whose issuer has since left the group or been denied (it stays dead if they are let back in), or that was made before the CYFR was restored from a backup, says it can no longer be used; signing in from your CYFR with it still signs in someone that CYFR already lets in, and grants nothing more.

### When a CYFR Requires Your Company's Sign-in

A CYFR run for a company may require each person there to sign in with their company's account as well: once, or again every set number of days. That sign-in is a condition of being there. It is not a way to sign in, and it is not your identity. You still sign in with your passkey, a paired device, your CYFR identity or a linked sign-in method, and you keep each of them.

While your company sign-in is missing or past its days, every page of that CYFR sends you to its company page. **Sign in with your company** takes you to your company's sign-in and back, and **Sign out** ends your session. Nothing else there opens until your company sign-in stands, and the API keys you made and the devices you paired there are refused. Your session, API keys, devices and memberships all stay, and work again once you sign in with your company.

The CYFR binds your company account to you by the subject your company's sign-in names for it, never by an email address. A company account already bound to someone else there is refused, and once one is bound to you, another is refused too. No CYFR merges two people because their email addresses match, and a company sign-in never makes or unlocks a person. When the CYFR moves to another company configuration (another issuer, client or organization), everyone there signs in with their company again, and the new sign-in replaces the old binding.

### Where joining is proven

The join proof (`tests/join-proof/`) runs every step in Chromium on the desktop, and a paired device's steps again in Chromium at a 720×720 touch viewport; in Firefox and WebKit it runs the sign-in at the group's CYFR, the carry between the person's own CYFR and the group's, and a second browser profile, each fresh confirmation those need given on a device paired in Chromium. Steps that use a passkey run in Chromium alone, whose virtual authenticator the proof drives. In-app browsers and mail clients that rewrite links are not covered.

---

## Passkeys at Each CYFR

A passkey belongs to the one CYFR it was registered at, under that CYFR's host, and proves things only there. Register one at each CYFR where you confirm changes.

At a CYFR that is not your own, a member who signed in only with their CYFR identity holds no fresh method there. Their first passkey at that CYFR is authorized by its platform administrator, who confirms that exact registration with a fresh proof of their own; the member and the administrator are told. A recovery of the member's identity retires the passkeys registered at that CYFR before it, so the next one again needs the administrator; an ordinary rotation of the live key, or adding a recovery code, keeps them.

---

## What Each Loss Costs

| You lost | What still works | How you come back |
|---|---|---|
| A device | Everything else | Revoke it under **Devices**; pair a new one. Until revocation or expiry, what it showed and its certificate are the exposure. |
| A sign-in method | Your other sign-in methods and passkeys | Sign in another way and link a new one. Your last sign-in method goes only while you keep another way in. |
| A passkey | Your sign-in methods, your other passkeys | Register another; at another CYFR with no fresh method left, its administrator authorizes it. |
| Your CYFR, with a recovery code | Your identity and your name, at cyfr.run | Restore on a fresh installation from the code, then re-pair devices and re-add saved addresses. |
| A recovery code, with your CYFR | Everything | Add another recovery code with one you still hold. The lost code stays valid until a recovery names a set without it: until then whoever finds it can replace your keys, and whoever recovers last decides the set. |
| Every recovery code, with your CYFR | Your identity and your CYFR, with no way back if your CYFR is lost | Nothing can add a recovery code: only a code you hold adds another. Keep your CYFR safe. |
| The directory, for good | Your CYFR, and local work | Rotation, recovery and every other CYFR's trust end. Every other CYFR invites you again with another sign-in method. |
| Your CYFR, every recovery code and your online keys at once | Nothing of the identity | Start again as a new person, with a new name: a new identity, invited again by each CYFR. |
