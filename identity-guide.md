# Identity and Recovery

How a person gets an identifier any CYFR knows them by, how its keys are kept and rotated, how the printed kit brings it back on a fresh installation, and what each loss costs. The person's own settings page (**Settings → Your identity**) shows all of it; every change there is an operation through CYFR's gate, and the command line reaches the same operations.

---

## Keys, Identifier and Directory

Your CYFR holds two keys for you, created when it made you (its setup, an invitation, or signing up while its allowlist admits everyone; a sign-in method such as GitHub, Google or an OIDC issuer only unlocks the person who linked it, and never makes or recovers one):

- the **live key**, which signs what you send to any other CYFR: a sign-in at another CYFR, and the certificates of your devices;
- the **operational key**, which only rotates the live key.

Both are sealed at your CYFR, each under its own purpose, apart from every athanor's vault. The separation is a limit on what each is used for, not a second line of defense: both sit behind the same CYFR, so whoever takes its machine and its keyring takes both. That is why recovery does not rest on either.

**Enrolling** gives you an identifier (`per_…`), the hash of the first entry of your identity's log. It never changes. The log lives at one **directory**, which orders every change of your keys; every CYFR that relies on your identity reads your current keys there, never from your own CYFR, which may be the stolen one. A person who never enrolls keeps their keys, their CYFR and their local devices, and never touches a directory.

Your CYFR's settings page shows your identifier, the directory, and the head of your log (its `key_epoch`: the hash of the entry at the log's head, which every rotation and every recovery moves).

A **handle** is a name at the registry, cyfr.run, that names your identifier; it is also your personal namespace for publishing components. Setup offers one, never required: the setup page, and Settings later, check a handle live against the registry's answer (taken or free), and a free one you choose runs the enrollment, which registers your identity at the directory and prints your kit. The handle waits in your preferences, and is claimed only once you say the kit is saved; a taken one asks for another and the enrollment stands, and a registry that does not answer leaves Settings offering "Claim @name". From the command line you claim it with `cyfr registry claim <handle>`, a request your live key signs, so claiming one needs an enrolled identity; no sign-in method or provider token is sent to the registry. Asked for a handle, the registry answers its identifier, its directory and, only if you publish it, your CYFR's address; publishing is off by default (`registry.publish_address`). The answer carries no keys: they are read at your directory, so a handle reassigned to someone else carries none of your keys with it.

### Choosing the directory

The deployment names the directory its people enroll at in `CYFR_DIRECTORY_URL`, an `https` URL that defaults to `https://cyfr.run`, the directory CYFR hosts. An operator may name another; no operation, page or person chooses one.

Choosing a directory is choosing how long an identity lasts:

- **While it cannot be reached**, rotating your key, recovering and every other CYFR's checks of your identity wait. Each CYFR that relies on your identity keeps serving your work from the head it last verified for `identity_freshness_seconds` (300 by default), then pauses it with a sentence saying so; your own CYFR keeps working, and your session and devices stand.
- **If it is gone for good**, rotation, recovery and every other CYFR's trust in your identity end for every identifier it orders. No identity moves to another directory, and there is no re-enrollment under another one: every other CYFR invites you again with another sign-in method.

The directory holds your public keys, your recovery policy and your log. It holds no private key, no address of your CYFR, no thread, no contact list and no list of the addresses your devices saved. It is trusted to keep one consistent order and to answer honestly; signatures stop it forging anything, but a dishonest directory could withhold an update or keep answering an old head as current, and nothing detects that.

Any CYFR can serve one (`CYFR_DIRECTORY_SERVE=writer`, or `mirror` for a read-only copy of a store it shares). Putting the only writer on the CYFR it recovers loses that recovery when that CYFR is lost. An operator serving a public directory owns its storage quota and its retention: each identifier's log is kept for good and only grows (`CYFR_DIRECTORY_MAX_IDENTITIES`, `CYFR_DIRECTORY_LOG_BYTES` and the recovery reserve bound it), and its requests are bounded per source and per installation. The default, `https://cyfr.run`, is the one CYFR runs; a deployment that names another relies on its operator, or someone they trust, to run it.

The directory's URL is public, and a CYFR that relies on your identity reads it from that identity. A directory hosted on your own CYFR tells every CYFR you sign in at where your own CYFR is.

---

## Enrolling and the Printed Kit

Enrollment is drawn only in your CYFR's system layer, never in an app, and asks for a fresh confirmation (`devices-guide.md`). Before anything is asked, its form says what you commit to: the directory, what its loss means, what losing every kit means, and what a recovery restores. The confirmation's preview says the same.

1. The browser draws your kit's secret, 32 random bytes, and holds it for this one request; it is sent to your CYFR under that request alone, and again, unchanged, once you confirm.
2. Your CYFR registers your identity at the directory. A lost answer is retried with the same request and the same first entry, so it registers once.
3. The **kit** appears in the prompt: three lines.

   - **Identifier** — `per_…`
   - **Directory** — the directory's URL
   - **Recovery secret** — the secret that signs a recovery

   Print them or write them down, and keep them apart from your devices. The prompt shows them until you say they are saved.
4. **I saved this kit** erases the secret at your CYFR for good. Until then, **Show kit** on the settings page shows it again, each time under a fresh confirmation; after, nothing can show it.

The three lines are everything a recovery of the identity needs. They never pass through an app, an address, the browser's storage or a log.

Until the directory accepts your enrollment, only the browser that began it holds the kit's secret. If that browser lost it (closed, reloaded or gone) before the directory answered, the settings page offers **Abandon and start again**: the unfinished enrollment ends, and you enroll anew with a new kit under a new identifier. A first entry the directory may already have registered stays there unused, under an identifier nobody holds a kit for. Once the directory has accepted it, your identity is registered and **Show kit** shows its kit instead.

### Every copy is a key

Anyone holding a copy of a kit can replace your keys, and the directory cannot tell your copy from theirs: each recovery replaces the keys the one before it installed, so whoever recovers last holds the identity. A recovery may replace the set of kits too: a kit stays valid only until a recovery names a set without it, and whoever recovers last decides the set. Keep kits as you would keep the deed to something.

### More than one kit

Add a second kit before you rely on one (**Add another printed kit**). It is signed by a kit you hold now, whose recovery secret you type into the prompt; the new kit's secret is drawn in the browser as the first was, and delivered and acknowledged the same way. Either kit alone recovers the identity. Adding a kit moves your log's head, so every other CYFR ends the sessions and device certificates it bound to your previous head, as a rotation does; your passkeys there stay.

A printed kit is the only recovery holder. No device holds recovery material.

---

## Rotating the Live Key

**Rotate the live key** replaces the live key, under a fresh confirmation, through one durable attempt: a lost answer is reconciled against the directory's log and never rotates twice. The operational key stays. Every other CYFR ends the sessions, device certificates and pending confirmations it bound to the old key within `identity_freshness_seconds`. Your devices paired at this CYFR renew with the key each stored and keep working; see `devices-guide.md`.

If a recovery or another rotation replaced the keys first, the attempt ends without changing anything here, and says so.

---

## Restoring on a Fresh Installation

A restore brings your identity back onto an empty installation from one kit. It is not an operation, since no person exists there yet, and it needs the installation's own capability besides the kit:

1. The operator sets `CYFR_RESTORE_TOKEN` on the fresh installation (`openssl rand -hex 32`) and gives you the token. While it is set, the installation's first person is reserved for the restore: setup makes no one first, and the restored person is the installation's administrator.
2. Open `https://<installation>/restore`, and type the token and the kit's three lines. The browser sends them to that installation alone, the token in a request header; nothing goes into an address or the browser's storage, and the form is emptied once the restore completes or you clear it.
3. The installation checks the token first, then that the kit is one of your identity's kits now, before it claims anything. A wrong token or a mistyped kit spends nothing.
4. It stages new keys and asks the directory to recover your identity onto them. Each step is durable: if the installation stops partway, sending the same kit under the same token again resumes from the step it reached, and the page does that itself while the restore is underway.
5. Before it uses the new keys, it reads your log again. If a later recovery already replaced them, the restore ends as **superseded** and activates nothing; restore again from your kit under a new token.
6. It creates you on the installation, with no sign-in method yet, and signs you in.

The token restores one identity, once. Another kit under the same token is refused, and so is the same kit after the restore ended; the operator sets a new token to start again. An installation that already holds a person refuses a restore.

### After a restore

- **Register a passkey first.** The restore's session may register your first passkey within `reauth_seconds` of when the restore signed you in; keeping the page open does not extend that window. If it closes with no passkey registered, the restore page proves the kit again under a new challenge (**Prove the kit again**) for a new window, without restoring anything twice.
- **Then link your sign-in methods** (GitHub, Google or your organization's sign-in) from the settings page. Linking one needs your session, a sign-in with it, and a fresh confirmation: the new passkey.
- **Pair your devices again.** A device paired with your old CYFR is not known here; its old certificate is refused, and it pairs anew.
- **Add your saved addresses back.** See below.

A restore brings back your identity alone. It restores no private data (a backup does that) and no membership another CYFR revoked.

### When your CYFR is restored from a backup

Putting a backup back is a different thing: the operator runs `cyfr restore`, which declares it, and your CYFR retires the authority the backup carried before it admits anything. When you next open it:

- **You sign in again.** Every session ended. Your passkeys and paired devices are suspended, so neither signs you in or confirms anything until you re-enable it. Sign in with GitHub, Google or your organization's sign-in; your first confirmation is a fresh sign-in with the same method.
- **No sign-in method left?** Open `https://<your CYFR>/restore` and use **Recover after a restore**: type your identifier and your kit's recovery secret. The secret stays in the browser, which signs your CYFR's challenge with it; your CYFR checks the signature against your identity read fresh from its directory. It answers a short credential that re-enables your passkeys, devices, keys and webhooks, and nothing else. An identity you never enrolled has no kit: a platform administrator authorizes a passkey you register for you instead.
- **Re-enable from the checklist.** The system layer lists what the restore suspended. Re-enabling a passkey or a device needs a fresh sign-in with GitHub, Google or your organization's sign-in, or the kit, never the passkey or device itself; once one is re-enabled, or a fresh one registered or paired under such a proof, your recovery is over and it confirms as before. A platform administrator can also end your recovery; what the restore suspended stays suspended. API keys and webhooks are re-enabled the same way.
- **Consent again, and rotate.** Every component's grant asks for consent again from the checklist, and every stored credential needs re-entering after you rotate it where it came from, since the backup's copy may be known. A run open at the backup ended uncertain and is never resumed; start it again.
- **Groups wait for everyone.** A group with a member still recovering admits no new member until each has. Someone who signs in only through GitHub, Google or an organization's sign-in, with no passkey or device, has nothing to recover and holds no group up. Removing someone and leaving work as before.

---

## Your Saved Addresses Are Your Device's

The address of each CYFR you visit, saved as a tab or a bookmark, belongs to the device that saved it. No CYFR stores, synchronizes or backs up your list of saved addresses, and a new browser starts with none. Saving an address grants no membership, and forgetting one revokes nothing.

So a recovery, or a new device, restores no list of saved addresses: you add each address again, from a device that still holds it, from your bookmarks, or from an invitation, and sign in at each CYFR. Each CYFR keeps your memberships there on its own.

### Signing in at another CYFR

Signing in at another CYFR with your CYFR identity begins at your own CYFR. On the other CYFR's sign-in page, **Sign in with your CYFR** offers the hosted CYFR, `https://my.cyfr.run`, as a button, and **I run my own CYFR** takes your handle (`@name`) or your CYFR's address. A handle works there only when you publish your address with it; otherwise the page asks for the address. The address a handle publishes only says where to go: the CYFR you sign in at keeps the identifier the handle names for the attempt, and refuses a sign-in that comes back as anyone else, so a published address that serves someone else signs nobody in. If the browser no longer holds that attempt when you come back (it lasts five minutes, and a newer one replaces it), begin again. Both CYFRs show the same short code so you can tell your sign-in is the one you started. Each learns the other's address: the CYFR you sign in at learns where your own CYFR is, and your own CYFR learns where you signed in. Neither learns your list of saved addresses. See `devices-guide.md` for how such a CYFR admits you, and for your passkeys there.

---

## Joining a CYFR That Is Not Your Own

Any CYFR that is not your own, a household's or a team's included, lets you in by your handle or your identifier (`per_…`, shown on your settings page): its platform administrator adds you to its allowlist, and a member adds you to an athanor there. Either way the CYFR you join keeps the identifier your handle names when you are added, never the handle, so a handle that later passes to someone else takes none of your access with it. Nothing about this reaches your own CYFR, and nothing at the CYFR you join learns your keys.

1. Open the address of the CYFR you join. On its sign-in page, under **Sign in with your CYFR**, choose **I run my own CYFR** and give your handle or your own CYFR's address. It sends you there; a link someone sends you only fills that form, and never begins or confirms anything.
2. At your CYFR's `/carry` page, press **Begin**: the sign-in is for that one CYFR. Sign in at your CYFR first if you are not.
3. The CYFR you join shows a short code, and your CYFR's confirmation names the same code. Confirm at your CYFR with a fresh proof only if they match. Your CYFR signs an assertion for the other CYFR's challenge alone, and the browser takes it back.
4. The CYFR you join reads your identity at the directory your identity names, which need not be its own, checks the assertion under your current keys, admits you, and makes you a member of the athanors you were invited to. Your CYFR's `/carry` page records that you were admitted, and sends you on to the CYFR you joined.

No cookie or session crosses from one CYFR to the other, and no CYFR keeps a list of where you sign in. A step that is interrupted, a closed tab or a lost answer, resumes from your CYFR's `/carry` page (**Resume**), under the same sign-in; a sign-in already admitted answers with the session it made, never a second one. **Cancel** ends one you no longer want.

At the CYFR you join, signing in with your CYFR identity is not a fresh proof. Register a passkey there for the changes that need one: its administrator authorizes your first one (`Passkeys at Each CYFR` below). To pair a phone there, open that CYFR's pairing code on the phone: the phone asks for your CYFR's address, you certify it at your CYFR under a fresh confirmation there, and it comes back and pairs. It renews its certificate at your CYFR by proving its key, with no confirmation, until your keys change (`devices-guide.md`).

- **Leaving one athanor**, or being removed from it, ends that membership, your sessions bound to it and the devices you paired for it. Your other athanors there, and your own CYFR, are untouched.
- **After you rotate your live key**, the CYFR you joined ends your sessions there within its `identity_freshness_seconds` (five minutes by default); sign in again. Your passkeys there stay, and your devices there are certified again at your CYFR.
- **After a recovery**, the CYFR you joined ends your sessions there within the same bound, and with them the passkeys and device certificates bound to the old keys. Sign in again, naming your CYFR's new address if it moved; your next passkey there is authorized by its administrator again, and your devices are certified again at your CYFR.
- **With your identity's directory unreachable**, the CYFR you joined keeps admitting you on the head it last read for its `identity_freshness_seconds`, then pauses your protected work there with a sentence saying so, until the directory answers again. A new sign-in waits for the directory.
- **A new browser or device** starts with no saved addresses and imports none: you open each CYFR by its address or an invitation, and sign in there.

### Joining by an invitation link

Someone with no CYFR identity of their own joins by an invitation link instead. A member creates one for a group they sit in, on **Members**; the platform administrator may also create one that names no group. The link is `<CYFR address>/invite#<code>`: it is shown once, works once, expires after seven days, and the CYFR keeps only the code's hash. Its page names who invited you and to which group, and **Create your identity here** makes your passkey, you, your keys and your own athanor at that CYFR, with your seat in the group. A link that has expired, been used or been revoked, whose issuer has since left the group or been denied (it stays dead if they are let back in), or that was made before the CYFR was restored from a backup, says it can no longer be used. The identity made this way is held by that CYFR, as one made by its setup is.

### Where joining is proven

The join proof (`tests/join-proof/`) runs every step in Chromium on the desktop, and a paired device's steps again in Chromium at a 720×720 touch viewport; in Firefox and WebKit it runs the sign-in at the group's CYFR, the carry between the person's own CYFR and the group's, and a second browser profile, each fresh confirmation those need given on a device paired in Chromium. Steps that use a passkey run in Chromium alone, whose virtual authenticator the proof drives. In-app browsers and mail clients that rewrite links are not covered.

---

## Passkeys at Each CYFR

A passkey belongs to the one CYFR it was registered at, under that CYFR's host, and proves things only there. Register one at each CYFR where you confirm changes.

At a CYFR that is not your own, a member who signed in only with their CYFR identity holds no fresh method there. Their first passkey at that CYFR is authorized by its platform administrator, who confirms that exact registration with a fresh proof of their own; the member and the administrator are told. A recovery of the member's identity retires the passkeys registered at that CYFR before it, so the next one again needs the administrator; an ordinary rotation of the live key, or adding a printed kit, keeps them.

---

## What Each Loss Costs

| You lost | What still works | How you come back |
|---|---|---|
| A device | Everything else | Revoke it under **Devices**; pair a new one. Until revocation or expiry, what it showed and its certificate are the exposure. |
| A sign-in method | Your other sign-in methods and passkeys | Sign in another way and link a new one. Your last sign-in method goes only while you keep another way in. |
| A passkey | Your sign-in methods, your other passkeys | Register another; at another CYFR with no fresh method left, its administrator authorizes it. |
| Your CYFR, with a kit | Your identity, at the directory | Restore on a fresh installation from the kit, then re-pair devices and re-add saved addresses. |
| A kit, with your CYFR | Everything | Add another kit with a kit you still hold. The lost kit stays valid until a recovery names a set without it: until then whoever finds it can replace your keys, and whoever recovers last decides the set. |
| Every kit, with your CYFR | Your identity and your CYFR, with no way to recover them | Nothing can add a kit: a kit is added only by a kit. Keep your CYFR safe; there is no re-enrollment. |
| The directory, for good | Your CYFR, and local work | Rotation, recovery and every other CYFR's trust end. Every other CYFR invites you again with another sign-in method. |
| Your CYFR, every kit and your online keys at once | Nothing of the identity | Start again as a new person: a new identity, invited again by each CYFR. |
