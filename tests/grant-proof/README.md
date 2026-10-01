# The grant proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a grant
made in Prism holds exactly what the person chose and admits exactly the
runs it names. The home is one `cyfr` release on a SQLite cell,
`home.test`, behind the harness's HTTPS front (`browser_home`). One person
is signed in by the release fixture's door (`tests/release-boot/fixture.exs`
`person`), and their local tincture `grant-probe` (`tinctures/grant-probe/`)
asks for two hosts, a folder and a key it can go without. `proof.mjs`
drives the person in Chromium; it asks `run.sh` for the home's part of a
step through its output directory (`ask-N.json`, answered `answer-N.json`):
publishing a version, reading a grant's head and the consent walk's plan,
asking the loader for an admission as a run started on Prism's path is
admitted, revoking the profile, and previewing decisions from the command
line (`cyfr call profile`, built from `apps/codex`, with the person's
session as its credential). Those reads are `fixture.exs`'s.

The harness runs no execution engine and no model, so `run.sh` never starts
a run: an admission is the loader's answer
(`Crucible.authority_for/3`), not a dispatched execution.

The release is built by hand, as `tests/release-boot/release.sh`'s
`release_build` builds it but without fetching dependencies
(`MIX_ENV=prod MIX_BUILD_PATH=_build/prod_release_boot_sqlite
CYFR_DATABASE=sqlite mix compile && mix assets.deploy && mix release cyfr
--overwrite`), and the proof runs with `RELEASE_BOOT_SKIP_BUILD=1`.

## Steps

Each step is one row; the proof fails when a row does not hold, and stops at
the first row a later one rests on.

| Step | What holds |
|---|---|
| `prism_grant` | the person grants grant-probe from its Components row, in the system layer's grant prompt: `interactive` is the one origin ticked; unticking the host `beta.grant.test` sends that host and the egress row reads narrowed; the trusted picker narrows the folder to one inside the ask (`data/probe/notes/`); the head is revision 1, admitting `interactive` alone and granting `alpha.grant.test` alone and that folder alone |
| `cli_digest` | the command line's preview of exactly the decisions the sheet sent answers the commit digest the head was committed under |
| `background` | version 1.1.0 asks to keep running when hidden: the plan's shape digest moves, the loader asks the person's run to grant again (`consent_required`), and the prompt shows the background row, starting from the origins the head admits; granted, the head is revision 2 and the run is admitted under it |
| `reworded` | version 1.2.0 only rewords its need's reason: the shape digest is the head's, the run is admitted under revision 2, and nothing is asked |
| `revocation` | the profile revoked in the console: the first admission asked after the revocation's answer is refused, on the member that committed it |

## Pending a worker beside the release

The steps that need an execution engine or a model run in the suite, which
has both:

| Step | Where it is shown |
|---|---|
| a run over the API refused, then admitted once the grant names `programmatic`, within its other bounds | `apps/cyfr/test/crucible/provider_test.exs` ("the origin a run over the API runs under") |
| a scheduled root refused until the grant names `schedule`, its child refused with it | `apps/cyfr/test/crucible/schedules/scheduler_test.exs` ("a fire under a grant that does not name schedule invokes nothing until it does"); a child of a scheduled root carries `schedule`: `apps/cyfr/test/cyfr/admission_origin_test.exs` |
| a programmatic turn queued, the cell restarted, the turn resumed and judged as `programmatic` | `apps/cyfr/test/aqua/runner_test.exs` ("the origin a turn resumes under", "a line under another origin") |
| a narrowed grant refusing the domain it dropped | `apps/cyfr/test/sanctum/consent/blob_builder_test.exs` ("what is granted is what runs: the loaded edge refuses what was dropped") |
| an approval bound to one execution and one path refusing another path, another execution and a call after its deadline | `apps/cyfr/test/aqua/approvals_test.exs` ("a bounded standing approval"), `apps/sanctum/test/sanctum/tool_grants_test.exs` (`admits?/2`) |

## Record

Recorded on 2026-10-02 on `p1` by `run.sh`, Chromium 153.

| Step | Chromium | What the record shows |
|---|---|---|
| `prism_grant` | held | origins ticked: `interactive` alone; the host box unticked sent `toggle_value` with `choice` `beta.grant.test`, and the egress row read narrowed; head revision 1, admitting `interactive`, domains `alpha.grant.test`, paths `data/probe/notes/` |
| `cli_digest` | held | both `sha256:937a06d9de69b6defe89abed20493adeed7d445197e05baafd41a6434010281d` |
| `background` | held | the loader answered `consent_required`; the prompt's frame row read "Keeps running in the background when hidden", `interactive` kept; revision 2, then admitted under it |
| `reworded` | held | the same shape digest; admitted under revision 2's consent |
| `revocation` | held | refused at the first admission asked, 93 µs after the revocation's answer (`no_profile`); earlier runs 108 µs and 92 µs |
