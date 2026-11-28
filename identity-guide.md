# Identity and Recovery

How a person has one account for every CYFR they use: their name, their identifier, the keys their devices keep and their recovery code; how a CYFR admits them; what each loss costs and how they come back. The account itself lives at an account service, cyfr.run unless the operator names another, and is changed on its account pages or from a device: a CYFR's setup link or an invitation link, opened in a browser, and **Set up CYFR** on the box's screen or in the CYFR app make one, and `/account/add` adds a device to it. No CYFR holds any of its keys: **Settings → Your name** shows the name and identifier that CYFR knows you by, **Settings → Keys on your account** lists your account's keys and your sessions at that CYFR, and the devices guide ([devices-guide.md](devices-guide.md)) covers devices and confirming changes.

---

## Your Account

You have one account, and every CYFR you use admits that same account:

- **Your name** (`@mira`) is how people find you: an administrator or someone in a shared thread adds you by it, and it is your personal namespace for publishing components. It is 1 to 39 lowercase letters and digits joined by single hyphens, it is yours for life, and nobody else can take it. It is never released and never changes: someone who wants another name makes another account.
- **Your identifier** (`per_…`) is the hash of the first entry of your account's log, and never changes. Settings shows it; no other page asks for it.
- **Your keys** are the passkeys your phones and computers keep for you and the keys your devices hold under their own PIN or passphrase. They live only there: no CYFR holds a key of yours, and the account service holds only their public halves.
- **Your recovery code** holds one more key, which replaces any of the others. You keep it, apart from your devices.

The account service keeps your account's log: every change to its keys, in one order, each signed by a key the log already lists. The log is public. A key in it carries no name or address; a passkey added from the account pages also names its maker when your browser reports one, such as Apple Passwords or a YubiKey model, so a CYFR can show which passkey is which. It serves the account pages, where your passkeys live, and answers your name with your identifier. It stores nothing else: no address of any CYFR you use, no email, no session and no list of where you sign in. Each CYFR reads your keys there and decides for itself whether to let you in.

### The account pages

The account service serves these pages, `https://cyfr.run/account/…` unless your CYFR names another. The box's screen and the CYFR app also make an account ([Creating Your Account](#creating-your-account)), and add themselves to one through `/account/add` ([devices-guide.md](devices-guide.md)):

| Page | What you do there |
|---|---|
| `/account/new` | Create your account: your name, your recovery code, your first passkey |
| `/account/sign` | Sign in to a CYFR, or confirm a change there, with your passkey; a CYFR sends you here |
| `/account/add` | Add a device to your account, from the code the device shows |
| `/account/devices` | See the passkeys and devices on your account, and remove one |
| `/account/recover` | With your recovery code: add a passkey, remove a key, add another recovery code, or replace everything |

A CYFR sends your browser to `/account/sign` and `/account/new` with its request in the address's fragment, which no server receives, and they send you back only to the CYFR that asked. For a sign-in or a confirmation the page tells the account service nothing: it never learns where you sign in. Your browser keeps the pages from your first visit, so they still open while the account service cannot be reached (see [When the Account Service Cannot Be Reached](#when-the-account-service-cannot-be-reached)).

### Which account service

A CYFR sends its people to one account service, the one `CYFR_DIRECTORY_URL` names, `https://cyfr.run` unless the operator names another, and reads every account it admits there. An account lives at one account service, and signs in at the CYFRs that use that one.

Any CYFR can serve its own account service (`CYFR_DIRECTORY_SERVE=writer`, the [configuration guide](configuration-guide.md)) and name itself in `CYFR_DIRECTORY_URL` and `CYFR_REGISTRY_URL`. Its people's passkeys then live at that CYFR's address, and every account made there names it, so it keeps its address for good, and losing it loses every account it serves. Its operator can close an account for good: every CYFR that admitted it then ends its sessions and devices, and its name stays reserved.

Such a CYFR serves its people's accounts and names, and no component registry: no component search, no publish tokens, no registry policies and no component storage. Its athanors fill from what CYFR ships, and the components that ship still pull and are still found: a search answers the local matches and says its results are incomplete. What needs the registry does not work there: a pull of a published component, a sync of push tokens on the Registry page, and a publish, which refuses for want of the push token a sync would have minted.

The account service is trusted to keep each log in one order and to answer honestly. Signatures stop it forging a change, but a dishonest service could withhold a change or keep answering an old log as current, and nothing detects that.

### Updating a CYFR

`cyfr update` removes from `.env` each setting the release the CYFR leaves shipped in its `.env.example` that the new release's `.env.example` does not declare, and names them; a setting still holding the old `.env.example`'s value takes the new one's where it changed, and is named with it. A `CYFR_` setting added to `.env` by hand that the new release does not read refuses the boot, which names it: remove it.

---

## Creating Your Account

### In a browser

A CYFR's setup link and its invitation links offer **Create your account** beside **Sign in with your account**. It opens `/account/new`, carrying that CYFR's sign-in request:

1. **Your name.** Type it after the `@`, and accept the terms when the account service names them. **Create your account** checks the name there and says when it is taken, then makes your passkey: your browser asks where to keep it. A browser that cannot make a usable passkey stops here, before you have saved anything, and says so.
2. **Your recovery code.** The page draws your recovery secret in the browser and shows your code: one line, `CYFR-` followed by fourteen groups of eight letters and digits. It spells your identifier and your recovery secret, with a check that catches a typo. **Copy** it into your password manager, or **Print** it.
3. **I saved it** sends everything: the page registers your account, adds the passkey to it and claims your name. Nothing is sent before it.
4. **Continue to** the CYFR that sent you asks for your passkey once more, and takes you back there signed in.

A tab closed before **I saved it** sent nothing and kept nothing; the passkey it made stays in your passkey manager on no account, and you can remove it there. One closed after it keeps what it signed in this browser for 24 hours: open the page again, and **Finish creating your account** asks for the recovery code you saved and goes on from where it stopped, without making anything twice. If someone took your name a moment before, the page says your account is made and asks for another name; if the terms changed meanwhile, it asks you to accept them again. Your account and your code never depend on the name.

Your recovery code never passes through an address, a server or the browser's storage; the page holds it in memory until it is done and drops it.

### On a box or in the CYFR app

A CYFR box with its own screen makes your account at setup: **Set up CYFR** takes your name, a PIN (or the passphrase it shows) and the terms, and shows your recovery code as a QR code to scan or print; **I saved it** makes the account with the box as its first device, and **Open CYFR** opens it. The CYFR app, with **Use this computer's key** or on Linux, makes one the same way with the computer as its first device, at the CYFR it connected to, which admits you by its own rules ([devices-guide.md](devices-guide.md#the-cyfr-app)).

---

## Your Recovery Code

The code is everything a recovery needs: your identifier and a secret that is a key of your account. Use it at `/account/recover`. Type it, and the page shows the passkeys and devices on your account and offers:

- **Add a passkey**: type your name, and your browser makes a new passkey on your account.
- **Remove** next to any passkey or device: it stops signing for you.
- **Add another recovery code**: a new code, shown and saved before it is added. Either code then works alone. Only a recovery code adds another.
- **Replace everything**: removes every passkey, device and recovery code from your account and gives you one new code, shown and saved before anything is sent. Then add a passkey on the same page.

Each change is signed in the page by the key your code holds and sent to the account service; one whose answer is lost is sent again unchanged, and lands once. The code stays in page memory and is dropped when the page closes.

### Every copy is a key

Anyone holding a copy of your recovery code can do everything above, at once and without asking you: the account service cannot tell your copy from theirs. A code you lose stays valid until you replace everything with a code you still hold. Keep it as you would keep the deed to something, apart from your devices, and add a second code before you rely on one.

---

## Signing In at a CYFR

**Sign in with your account** on a CYFR's sign-in page sends your browser to `/account/sign`, which says "Sign in to" that CYFR's address. Your passkey signs that CYFR's request, and the browser returns there; the CYFR checks the signature against your account's keys, asks its own allowlist, and signs you in. The request is that CYFR's own, bound to the browser that asked, used once, and gone after five minutes. The box's screen, and the CYFR app using the computer's key, sign in the same way on their own, after their local unlock ([devices-guide.md](devices-guide.md)).

In the CYFR app on macOS and Windows, **Sign in with your passkey** opens that CYFR's sign-in page, and `/account/sign` opens in a window of the app's own, which shows only the account service's sign-in and recovery pages and returns the answer only to the CYFR window that asked. When the CYFR names an account service other than cyfr.run, the app shows its address and asks you to approve it before anything is sent there ([devices-guide.md](devices-guide.md#the-cyfr-app)). Each CYFR the app keeps has its own sign-in on this computer, tied to its exact address, port included: signing in or out at one leaves every other as it was, and switching between them signs you out of none. Signing out signs you out of the CYFR you are on alone, and so does a failed deletion of your account there. **Forget this CYFR on this computer** erases that CYFR's sign-in here and nothing at the CYFR itself.

A browser that holds no passkey of yours, as one does when you made your account on a CYFR box, has two ways on once it is refused: **Add a passkey with your recovery code**, or **No passkey in this browser?**, which asks your name, makes a passkey for that account in this browser and returns it to the CYFR, which shows its code. On your box's screen, or in the CYFR app unlocked with the computer's key, **Your devices** shows "A browser asks to add a passkey" with that code: check it is the same, press **Approve**, and type that device's PIN or passphrase; its key adds the passkey to your account. Then sign in again in the browser with the new passkey. A passkey nobody approves adds nothing and is forgotten after five minutes.

A sign-in with a passkey lasts until you sign out, until it goes unused for the CYFR's `session_ttl_hours` (30 days unless its administrator changed it), or until about 30 days after you signed in, however much you use it, whichever comes first. It lasts as long in the CYFR app, through quitting it and opening it again.

Each CYFR decides who it admits:

- **Its setup** admits its first person, who administers it, through the setup link or the box's own screen, and then opens nothing.
- **An invitation** admits whoever redeems it, once (below).
- **Its allowlist** admits an account its administrator allowed by name on **Settings → Server allowlist**, or anyone while it holds `*`. A deny always wins.

Your first sign-in at a CYFR makes you a person there, with an athanor of your own. Your passkeys and devices sign you in at every CYFR that admits you, and you register nothing at each one.

### Your name at a CYFR

A CYFR records your name once the account service confirms the name is your account's: at a sign-in, it asks the account service which name your identifier holds, so your first sign-in there names you; when you create your account from an invitation link and keep the name it offered; or when you type it under **Settings → Your name → Finish your name**, which is the way back when the account service could not be reached at sign-in. Until then that CYFR has no name for you.

### Confirming a change

A change that needs a fresh confirmation, such as making an API key, is confirmed by a key of your account: **Confirm with a passkey** opens `/account/sign` in a new tab, which says "Confirm a change at" that CYFR, and your passkey signs that one request; a device of yours confirms after its own unlock. A sign-in, however recent, confirms nothing. The [devices guide](devices-guide.md#fresh-confirmation) lists what needs one.

### Joining by an invitation link

An invitation link admits someone to a CYFR without opening it to everyone. The platform administrator creates one on **Settings** (**Invite to this CYFR**); anyone in a shared thread creates one that also seats the newcomer there, from the thread's header. The link is `<CYFR address>/invite#<code>`: it is shown once, works once, expires after seven days, and the CYFR keeps only the code's hash.

The page names who invited you, and to which thread. **Sign in with your account** signs you in with the account you have; **Create your account** makes one first, with any name the invitation offers filled in, which you may change. Either redeems the invitation: it makes you a person there, with your own athanor, if you are not one yet, seats you in the thread, and lets your identifier in from then on, so you sign in later without the link. That entry shows in the CYFR's allowlist, where its administrator can remove it. A deny always wins: an account the CYFR denies is refused, and the invitation stays unspent.

A link that has expired, been used or been revoked, whose issuer has since left the thread or been denied, or that was made before the CYFR was restored from a backup, says "This invitation can no longer be used."

- **Leaving a shared thread**, or being removed from it, ends that seat and nothing else. Your athanor there and its sessions and devices are untouched.
- **A new browser or device** starts with no saved addresses: you open each CYFR by its address or an invitation, and sign in there with the same account.

---

## When the Account Service Cannot Be Reached

A CYFR reads your account's keys again once `identity_freshness_seconds` (five minutes by default) have passed since it last read them, and at once for a key it has not seen on your account before, so a passkey or device you just added signs in straight away. Removing a key reaches each CYFR at its next read: within that bound it ends there every session, certificate and pending confirmation the key signed for, and replacing everything ends all of yours.

When the account service cannot be reached past that bound, what a CYFR does follows its browser address (`CYFR_BROWSER`):

- **A CYFR at a domain**, through Caddy or your own proxy, pauses your protected work there, with a sentence saying so, and a new sign-in waits, until the account service answers again.
- **A CYFR with no browser address or a tailnet one** keeps admitting the people it holds on the keys it last read, and reads them again the next time the account service answers, so a key removed meanwhile keeps working there until then. A device signs in as always. A browser signs in only if it opened the account pages before, since it keeps them from that visit. An account that CYFR never read is refused until the service answers.

---

## When a CYFR Is Restored from a Backup

Putting a backup back is the operator's `cyfr restore`, which declares it, and the CYFR retires the authority the backup carried before it admits anything. No CYFR holds a key of yours, so your passkeys and devices still sign you in, unless the restored CYFR serves your account service (below). When you next open it:

- **You sign in again.** Every session there ended.
- **Your devices connect again.** Every device connected there was suspended and its certificate revoked; each comes back by connecting as it did the first time, with the same key, and nothing needs approving.
- **Re-enable your API keys and webhooks** from the restore checklist on your pages, each under a fresh confirmation.
- **Consent again, and rotate.** Every component's grant asks for consent again from the checklist, and every stored credential needs rotating where it came from and entering again, since the backup's copy may be known. The restore revokes every key you shared: share it again once you have rotated it. Every invitation link still open was revoked. A run open at the backup ended uncertain and is never resumed; start it again.

A CYFR that serves its own account service keeps its people's account logs in its database, which the snapshot holds, so a restore puts each log back as the snapshot held it. A change made after the snapshot (a key added or removed, a recovery code added, everything replaced, an account made) is gone from that service until its person makes it again: a key removed since is listed again until then, and a CYFR that read the later log pauses that person's work there, since the restored log does not hold what it read. Your devices keeping their keys does not keep the log.

---

## Your Saved Addresses Are Your Device's

The address of each CYFR you use, saved as a tab, a bookmark, a command line's context or the CYFR app's last connection, belongs to the device that saved it. No CYFR and no account service stores, synchronizes or backs up your list, and a new browser starts with none. Saving an address grants no access, and forgetting one revokes nothing: you add each address again from a device that still holds it, from your bookmarks or from an invitation, and sign in at each CYFR with your account.

---

## What Each Loss Costs

| You lost | What still works | How you come back |
|---|---|---|
| A passkey, or the phone or computer that kept it | Your other passkeys, your devices and your recovery code | Remove it at `/account/devices` with another passkey, or at `/account/recover` with your recovery code, and add a new passkey at `/account/recover`. A passkey your platform synced to your other phones and computers is still there. Until you remove it, whoever unlocks the phone or computer that keeps it signs in as you. |
| A device | Your passkeys, your other devices and your recovery code | Remove its key at `/account/devices` or `/account/recover`: until then it signs, at every CYFR that admits you, for whoever knows its PIN or passphrase. |
| Every passkey and device | Your account and your name, through your recovery code | At `/account/recover`: add a passkey, and remove the lost keys. |
| A recovery code, with another one | Everything | Add a new code with the one you hold. The lost code stays valid until you replace everything with a code you hold: until then, whoever finds it can take your account. |
| Your only recovery code | Your passkeys and devices | Nothing adds a code without one. Your account stands on its passkeys and devices alone: keep more than one, on more than one machine. |
| A CYFR you use | Your account, your name and every other CYFR | Your account was never there, unless that CYFR serves your account service (next row). The CYFR's own data comes back only from its backup; a CYFR made anew admits you again by its setup or an invitation, with a new athanor. |
| The account service, for good | A local or tailnet CYFR's work, on the keys it last read | No key can be added, removed or recovered, and a public CYFR pauses your work. Make a new account at another account service, and be admitted again by each CYFR. |
| Every passkey, every device and every recovery code at once | Nothing of the account | Start again as a new person, with a new name: a new account, admitted again by each CYFR. |
