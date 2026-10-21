# The file-offer proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a file
reaches another person only by an offer they accept (`ARCHITECTURE.md`
§5.1), as a snapshot taken when it was offered, and that the storage counts
move as the offer's lifecycle states (`Arca.FileOffers` holds both). The home is one
`cyfr` release on a SQLite cell, `home.test`, behind the harness's HTTPS
front (`browser_home`). `fixture.exs` signs three people in, as the release
fixture's door does (`tests/release-boot/fixture.exs` `person`): the
sender, an operator by the deployment's own list, who lets the other two
in at the door (`door.allow`); the recipient, seated with the sender in a
group the sender creates (`athanor.create`, `member.add`); and the
outsider, who sits in no athanor but their own. It writes the sender's
three files under `data/reports/` (`file.write`), each call through the
gate under the person's own session, and waits until each person's own
athanor is filled, since its fill writes into the tree the counts are read
from.

`proof.mjs` drives the three people in Chromium, each in a browser context
of their own, on the Files page and its topbar, as each sees them: picking
files and the person in the picker (`send_copy`), the recipient's Inbox and
the topbar's count, `accept` with the folder the form shows, `decline`, the
sender's `withdraw`, and the sender's `edit` and `save` of an offered
original. It asks `run.sh` for the home's part of a step through its output
directory (`ask-N.json`, answered `answer-N.json`): writing the sender's
files, and reading back, under each person's own actor, the offer and
receipt rows, each athanor's storage usage, each snapshot's and custody
copy's byte count, every file each snapshot stores, as the size and
SHA-256 of the bytes read there, and the accepted copy's bytes at the path
its receipt records, as a digest and a size. Those reads are
`fixture.exs`'s, which answers digests and sizes and serializes no file's
bytes.

An offer and an acceptance copy bytes in the release itself, so the
harness's lack of an execution engine and a model costs this proof
nothing: no step starts a run, and nothing received is executed. A received
component or script is bytes, installed and granted by nothing, and this
proof makes no claim to run one.

The release is built by hand, as `tests/release-boot/release.sh`'s
`release_build` builds it but without fetching dependencies
(`MIX_ENV=prod MIX_BUILD_PATH=_build/prod_release_boot_sqlite
CYFR_DATABASE=sqlite mix compile && mix assets.deploy && mix release cyfr
--overwrite`), and the proof runs with `RELEASE_BOOT_SKIP_BUILD=1`.
`VAULT_PROOF_VIEWPORT` is `desktop` (1280×900, the default) or `720x720`;
every person's browser context has that viewport, and the result records
it. `run.sh` writes `file-offer-proof.json` and `file-offer-proof.md` into
`PROOF_OUT`.

## Steps

Each step is one row; the proof fails when a row does not hold, and stops at
the first row a later one rests on. The sender offers three files, one
offer each: `alpha.txt` (1,536 bytes), `beta.txt` (2,560) and `gamma.txt`
(3,584). Every count is the whole tree of the person's own athanor, as the
storage cap walks it. The sender slug of the default folder
`data/inbox/<sender slug>` is the sender's namespace when it is one storage
path segment, and their person id otherwise.

**What is hashed, and when.** A snapshot *holds its original* when the
fixture, reading as the sender everything stored under the offer's
`payloads/offers/<offer id>/`, finds exactly that offer's one file, whose
size and SHA-256, computed from the bytes it read there, are those of the
bytes the proof uploaded. The digest the offer row records is checked as
the row's own fact, never as the snapshot's. Every snapshot still open is
hashed:

- after each offer: `alpha.txt`'s; then `alpha.txt`'s and `beta.txt`'s;
  then all three;
- after the sender's edit of `alpha.txt`: all three;
- just before each offer's end releases its snapshot: all three before
  the withdrawal of `gamma.txt`, `alpha.txt`'s and `beta.txt`'s before the
  acceptance of `alpha.txt`, and `beta.txt`'s before its decline.

After each end, the offer's snapshot stores nothing. The accepted copy is
hashed once it has landed, at the path its receipt records. The proof has
no expiry step.

| Step | What holds |
|---|---|
| `picker` | the sender's picker, each of the three times it opens, lists the recipient alone: never the outsider, never the sender |
| `offered` | each offer, sent from the picker, is one `file_offers` row, `offered`, from the sender to the recipient, with the file's size and the original's digest; after each offer, every snapshot offered so far holds its original; the sender's usage grows by exactly the file's size; the sender's page lists it waiting, with its withdraw |
| `notice` | each offer reaches the recipient's Files page, open since before it was made, without a reload: its Inbox lists it with its file and the default folder `data/inbox/<sender slug>`, and the topbar counts it (1, 2, then 3 offers) |
| `edited` | the sender opens `alpha.txt`, already offered, edits it to 1,024 other bytes and saves it; reopened, it reads the edit; every snapshot, `alpha.txt`'s included, still holds its original, and the sender's usage moves by the edit alone |
| `withdrawn` | the sender withdraws `gamma.txt`'s offer before the recipient acts on it, every open snapshot holding its original just before: its row ends `withdrawn`, it leaves the recipient's open page (2 offers), no receipt or custody copy is written for it, its snapshot is released and the sender's usage returns by it |
| `accepted` | the recipient accepts `alpha.txt`'s offer into the folder the form shows, both open snapshots holding their originals just before: its rows end `accepted`; one receipt, `completed`, records `data/inbox/<sender slug>/<offer id>/alpha.txt`; the bytes there, read back under the recipient's actor and opened on the recipient's page, are the original's at offer time, not the sender's edit; the snapshot is released and the sender's usage returns by it; the recipient's usage grows by the file once, its custody copy released; the sender's page shows it accepted, with no withdraw |
| `declined` | the recipient declines `beta.txt`'s offer, its snapshot holding its original just before: its row ends `declined`, the recipient's Inbox is empty and the count gone, the snapshot is released and the sender's usage returns by it; `data/inbox/<sender slug>/` holds the accepted offer's folder alone, so nothing landed for the declined or the withdrawn one; the sender's page, never reloaded, shows each offer's end |
| `outsider` | the outsider's Files page, open from the start and never reloaded, shows no offer, no receipt and no count at any step; no row names them and their usage never moves; the recipient's picker lists the sender alone; a picker edited in the sender's browser to name the outsider is refused, and no offer, row or snapshot is written |
| `storage` | step by step, each person's usage moved as above and by nothing else, ending with the sender's moved by the edit alone, the recipient's by the accepted file once and the outsider's not at all, and no snapshot or custody copy left |

## Shown elsewhere

The cases this proof cannot reach through the browser: the race, crash,
uncertain-publication and custody cases of an acceptance
(`Arca.FileOffers`), each a test of its owner's, which this proof neither
runs nor claims. `run.sh` finds each in the tree, by file and test name,
before the run, and the result lists them with the line found.

| Claim | Test file | Test name | Owner |
|---|---|---|---|
| race: a completer paused past its lease and a successor publish the transfer once, and the stale one, refused at its next row write, publishes and releases nothing | `apps/arca/test/arca/file_offers_test.exs` | `a stale completer cannot publish or release another claimant's custody` | `Arca.FileOffers` |
| crash and uncertain publication: a kill at each of the four points between the acceptance's commit and `completed` is finished by the receipts sweep from the recorded path, the offered snapshot landing once and the custody copy released | `apps/cyfr/test/arca/providers/files_test.exs` | `acceptance publishes the offered snapshot once across a crash and retry` | `Arca.FileOffers` |
| custody: the sender's athanor purged between the commit and publication, the transfer completes from the recipient's custody copy, beside a file of the recipient's own and never over it | `apps/cyfr/test/cyfr/files_test.exs` | `accepted custody survives sender purge without overwriting recipient bytes` | `Arca.FileOffers` |

None of the three is a case of the storage cap, whose own cases are
`apps/cyfr/test/arca/providers/files_test.exs`'s "an acceptance past the
recipient's cap is refused: nothing written, the offer open" and "a
publication the cap refuses waits as a receipt, then lands once space
frees", and `apps/arca/test/arca/file_offers_test.exs`'s "copies each file
into the sender's snapshot, under the sender's cap, until it ends". This
proof's cell sets no storage cap, so it shows what the cap counts, never a
refusal.

## Declared coverage limit

The unchanged shipped model artifact → production
`Opus.Host.AttachedFetch` → local provider stand-in composition is
**uncovered**. The current artifacts hard-code provider HTTPS origins
(`seed/components/catalysts/local/openai/1.4.1/src/src/lib.rs:13` and its
peers); `Opus.Host.Egress.pin/3` has a resolver option which the actual
host never passes (`apps/cyfr/lib/opus/host/egress.ex:94`). The
existing suites found in `seed_model_catalysts_test.exs`,
`model_contract_test.exs`, `TwoServices`, `tests/locus-runtime-image/` and
`Sanctum.Test.Resolver` do not provide an end-to-end local
replacement for that production path. `tests/locus-runtime-image/runners.py`'s
scenario `shipped_model_attached_request` exercises the shipped artifact
with a scripted host; `attached_fetch_test.exs` and `model_contract_test.exs`
exercise production attachment with controlled fixture guests. Neither is
reported as the full composition, and this proof starts no runner and
sends no request to a provider. No live provider account or credentials,
TLS bypass, endpoint parameter or new resolver/transport override is used.
This is an explicit test-coverage limitation, not a claim that the
composition passed.
