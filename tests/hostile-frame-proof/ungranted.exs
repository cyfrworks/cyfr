# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The containment proof's tincture that waits for a grant, evaluated inside
# the running server by `bin/cyfr rpc` (tests/hostile-frame-proof/run.sh):
# the owner profile of the person's local tincture NAME, written as one a
# person consented to and whose consent no longer answers — `needs_consent`
# — the one profile a frame open refuses as `:ungranted`, which the shell
# answers with its grant prompt. Only the profile's standing is written
# here, through Arca's one production mint; the grant the proof's person
# makes is the console's own walk. Answers one line, `UNGRANTED=` and the
# profile's id.

fn [user_id, name] ->
  {:ok, user} = Sanctum.Tenancy.Users.get(user_id)

  ctx =
    Sanctum.Context.build(
      user_id: user.id,
      email: user.email,
      provider: "github",
      athanor_id: nil,
      permissions: Sanctum.Context.person_permissions()
    )

  {:ok, ctx} = Sanctum.Tenancy.resolve_status(%{ctx | namespace: user.namespace}, force: true)
  profile_id = Prima.UUID7.generate_id("prof")

  {:ok, _} =
    Arca.ConsentStorage.mint_profile_with_revision(
      %{
        id: profile_id,
        athanor_id: ctx.athanor_id,
        source_ref: "tincture:local." <> name,
        kind: "owner",
        label: "default",
        status: "needs_consent"
      },
      %{
        profile_id: profile_id,
        revision: 1,
        scope: "versionless",
        pinned_version: "",
        invoke_mode: "open_inert",
        shape_digest: "sha256:" <> String.duplicate("0", 64),
        commit_digest: "sha256:" <> String.duplicate("0", 64),
        blob_digest: Prima.JCS.hash_binary("{}"),
        resolved_policy: "{}",
        activation: Jason.encode!(%{}),
        admitted_origins: [:interactive],
        granted_by: user.id,
        granted_via: "interactive"
      },
      []
    )

  "UNGRANTED=" <> profile_id
end
