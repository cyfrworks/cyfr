# The grant proof

`run.sh` proves, on the browser harness (`tests/browser/`), that a grant
made in Prism holds exactly what the person chose and admits exactly the
runs it names. The home is one `cyfr` release on a SQLite cell,
`home.test`, behind the harness's HTTPS front (`browser_home`). One person
is signed in by the release fixture's door (`tests/release-boot/fixture.exs`
`person`), and their local tincture `grant-probe` (`tinctures/grant-probe/`)
asks for two hosts, a folder and a key it can go without, and lets the folder's files reach one host and its notes the other. `proof.mjs`
drives the person in Chromium; it asks `run.sh` for the home's part of a
step through its output directory (`ask-N.json`, answered `answer-N.json`):
publishing a version, reading a grant's head and the consent walk's plan,
asking the loader for an admission as a run started on Prism's path is
admitted, revoking the profile, and previewing decisions from the command
line (`cyfr call profile`, built from `apps/codex` with
`go build -mod=readonly`, with the person's session as its credential). Those reads are `fixture.exs`'s.

The harness runs no execution engine and no model, so `run.sh` never starts
a run: an admission is the loader's answer
(`Opus.authority_for/3`), not a dispatched execution.

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
| `prism_grant` | the grant prompt is a dialog whose accessible description in Chromium's accessibility tree begins with the prompt's own sentence, with keyboard focus inside the prompt; the person grants grant-probe from its Components row, in the system layer's grant prompt: `interactive` is the one origin ticked; unticking the host `beta.grant.test` sends that host and the egress row reads narrowed; the trusted picker narrows the folder to one inside the ask (`data/probe/notes/`); every exit is shown with the classes that may reach it (`alpha.grant.test` the folder's `files_by_grant`, `beta.grant.test` its `filed` notes); the head is revision 1, admitting `interactive` alone and granting `alpha.grant.test` alone, that folder alone and the flow to that host alone, the dropped host's flow gone with it |
| `cli_digest` | the command line's preview of exactly the decisions the sheet sent answers the commit digest the head was committed under |
| `background` | version 1.1.0 asks to keep running when hidden: the plan's shape digest moves, the loader asks the person's run to grant again (`consent_required`), and the prompt shows the background row, starting from the origins the head admits; granted, the head is revision 2 and the run is admitted under it |
| `reworded` | version 1.2.0 only rewords its need's reason: the shape digest is the head's, the run is admitted under revision 2, and nothing is asked |
| `flows` | version 1.3.0 lets outside material reach the host the person kept: the plan's shape digest moves, the loader asks the person's run to grant again (`consent_required`), and the prompt's exits row for that host names `outside` beside `files_by_grant`, the new flow unticked since a re-grant opens from the head's narrowing; ticked and granted, the head is revision 3, holds the flow and admits the run |
| `revocation` | the profile revoked in the console: the first admission asked after the revocation's answer is refused, on the member that committed it |

## Shown in the suite

The steps that need an execution engine or a model run in the suite, which
has both:

| Step | Where it is shown |
|---|---|
| a run over the API refused, then admitted once the grant names `programmatic`, within its other bounds | `apps/cyfr/test/opus/provider_test.exs` ("the origin a run over the API runs under") |
| a scheduled root refused until the grant names `schedule`, its child refused with it | `apps/cyfr/test/opus/schedules/scheduler_test.exs` ("a fire under a grant that does not name schedule invokes nothing until it does"); a child of a scheduled root carries `schedule`: `apps/cyfr/test/cyfr/admission_origin_test.exs` |
| a programmatic turn queued, the cell restarted, the turn resumed and judged as `programmatic` | `apps/cyfr/test/aqua/runner_test.exs` ("the origin a turn resumes under", "a line under another origin") |
| a narrowed grant refusing the domain it dropped | `apps/cyfr/test/sanctum/consent/blob_builder_test.exs` ("what is granted is what runs: the loaded edge refuses what was dropped") |
| an approval bound to one execution and one path refusing another path, another execution and a call after its deadline | `apps/cyfr/test/aqua/approvals_test.exs` ("a bounded standing approval"), `apps/sanctum/test/sanctum/tool_grants_test.exs` (`admits?/2`) |
