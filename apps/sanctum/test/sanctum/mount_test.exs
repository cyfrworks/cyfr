# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MountTest do
  @moduledoc """
  `Sanctum.Mount.resolve/5` answers the program row a run's binding of a
  login need names, whose id is its kept home's, never material, in
  order: the binding live (read, a `once` not consumed), a share refused,
  the row the athanor's own enabled, kept, driven program named as the
  manifest names the need's program, and only then the binding used, so a
  refused mount consumes nothing. Beside it, the reads the programs
  controller makes of program rows.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Sanctum.Mount
  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.TestContext

  @source "catalyst:local.mount-harness"
  @root "exec_mount_root"

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {person, _user} = TestContext.person!(TestContext.local())
    {:ok, ctx: person}
  end

  # A program row of the athanor, written as the row store writes one.
  defp row!(ctx, over \\ %{}) do
    attrs =
      Map.merge(
        %{
          id: Prima.UUID7.generate_id("mcp"),
          name: "claude",
          transport: "program",
          mark: "driven",
          home: "kept",
          enabled: true,
          epoch: 1,
          revision: 0,
          config_json: ~s({"command":"claude"}),
          athanor_id: ctx.athanor_id,
          created_by: ctx.user_id
        },
        over
      )

    Arca.Repo.insert!(struct(Arca.Schemas.McpServer, attrs))
  end

  # A head whose row at the binding's key holds its lifetime, and the
  # authority a run under it carries, binding `row_id` at that key on the
  # edge for the need. The head's row is read by its key alone
  # (`Sanctum.Attach`), so it is written as a binding through a label.
  defp bound!(ctx, row_id, opts \\ []) do
    edge_key = Keyword.get(opts, :edge_key, Blob.edge_key("catalyst:local.dep", "claude"))
    key = Blob.binding_key(@source, edge_key, nil)

    ref =
      Map.merge(
        %{binding_key: key, via_label: "folder", binding_digest: nil},
        Keyword.get(opts, :lifetime, %{})
      )

    {profile_id, consent_id} = head!(ctx, [ref])

    vault = %{
      entry_id: row_id,
      binding_digest: nil,
      scope: Keyword.get(opts, :scope, "athanor"),
      binding_key: key,
      attach: nil,
      projection: %{fields: %{}, scopes: []}
    }

    authority = %{
      Authority.zero()
      | profile_id: profile_id,
        consent_id: consent_id,
        resources: %Edge{vault: vault}
    }

    {authority, consent_id}
  end

  defp head!(ctx, refs) do
    profile_id = "prof-mount-#{System.unique_integer([:positive])}"
    consent_id = Prima.UUID7.generate_id("cons")

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: profile_id, source_ref: @source, kind: :owner, label: profile_id},
        %{
          id: consent_id,
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape-#{profile_id}",
          commit_digest: "sha256:commit-#{profile_id}",
          resolved_policy: "{}",
          activation: %{},
          vault_refs: refs
        }
      )

    {profile_id, consent_id}
  end

  defp consumed_by(consent_id) do
    Arca.Repo.one!(
      from(r in Arca.Schemas.ConsentVaultRef,
        where: r.consent_id == ^consent_id,
        select: r.consumed_by_root
      )
    )
  end

  @once %{lifetime: %{lifetime_kind: "once"}}

  describe "resolve/5" do
    test "answers the program row the binding names, whose id is the kept home's", %{ctx: ctx} do
      row = row!(ctx)
      {authority, _consent} = bound!(ctx, row.id)

      assert {:ok, mounted} = Mount.resolve(ctx, authority, "claude", "claude", @root)
      assert mounted.id == row.id
      assert mounted.home == "kept"
    end

    test "a once binding is consumed by the mount that is made, and only by it", %{ctx: ctx} do
      row = row!(ctx)
      {authority, consent_id} = bound!(ctx, row.id, Map.to_list(@once))

      assert consumed_by(consent_id) == nil
      assert {:ok, _} = Mount.resolve(ctx, authority, "claude", "claude", @root)
      assert consumed_by(consent_id) == @root

      # Its own root mounts again; another root is refused.
      assert {:ok, _} = Mount.resolve(ctx, authority, "claude", "claude", @root)

      assert {:error, :grant_expired} =
               Mount.resolve(ctx, authority, "claude", "claude", "exec_other")
    end

    test "a binding of another need is not this need's", %{ctx: ctx} do
      row = row!(ctx)

      {authority, consent_id} =
        bound!(
          ctx,
          row.id,
          [edge_key: Blob.edge_key("catalyst:local.dep", "gemini")] ++ Map.to_list(@once)
        )

      assert {:error, :connection_not_granted} =
               Mount.resolve(ctx, authority, "claude", "claude", @root)

      assert consumed_by(consent_id) == nil
    end

    test "an expired binding is refused before the row is read", %{ctx: ctx} do
      row = row!(ctx)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {authority, _consent} =
        bound!(ctx, row.id, lifetime: %{lifetime_kind: "until", expires_at: past})

      assert {:error, :grant_expired} = Mount.resolve(ctx, authority, "claude", "claude", @root)
    end

    test "a program's folder is never shared: a binding through a share is not granted, " <>
           "consuming nothing",
         %{ctx: ctx} do
      row = row!(ctx)
      {authority, consent_id} = bound!(ctx, row.id, [scope: "share"] ++ Map.to_list(@once))

      assert {:error, :connection_not_granted} =
               Mount.resolve(ctx, authority, "claude", "claude", @root)

      assert consumed_by(consent_id) == nil
    end

    test "a row that does not stand as the athanor's enabled, kept, driven program the " <>
           "manifest names is refused, consuming nothing",
         %{ctx: ctx} do
      # No row at all.
      {authority, consent_id} = bound!(ctx, "mcp_no-such-row", Map.to_list(@once))

      assert {:error, {:program_unavailable, "claude"}} =
               Mount.resolve(ctx, authority, "claude", "claude", @root)

      assert consumed_by(consent_id) == nil

      other = %{ctx | athanor_id: "ath_other_#{System.unique_integer([:positive])}"}

      for {over, program} <- [
            {%{enabled: false}, "claude"},
            {%{home: "scratch"}, "claude"},
            {%{mark: "mcp"}, "claude"},
            {%{transport: "http", mark: nil, url: "https://x.example/mcp"}, "claude"},
            {%{athanor_id: other.athanor_id}, "claude"}
          ] do
        row = row!(ctx, over)
        {authority, consent_id} = bound!(ctx, row.id, Map.to_list(@once))

        assert {:error, {:program_unavailable, ^program}} =
                 Mount.resolve(ctx, authority, "claude", program, @root),
               inspect(over)

        assert consumed_by(consent_id) == nil
        Arca.Repo.delete!(row)
      end
    end

    test "a row the manifest does not name for the need is another program's, consuming nothing",
         %{ctx: ctx} do
      row = row!(ctx)
      {authority, consent_id} = bound!(ctx, row.id, Map.to_list(@once))

      assert {:error, {:another_program, "claude"}} =
               Mount.resolve(ctx, authority, "claude", "codex", @root)

      assert consumed_by(consent_id) == nil
    end

    test "an anonymous caller is refused", %{ctx: ctx} do
      row = row!(ctx)
      {authority, _consent} = bound!(ctx, row.id)

      assert {:error, :anonymous_denied} =
               Mount.resolve(%{ctx | anonymous: true}, authority, "claude", "claude", @root)
    end
  end

  describe "the reads of program rows" do
    test "orphaned_homes/1 names each home no kept row of a live athanor holds, with its athanor",
         %{ctx: ctx} do
      kept = row!(ctx)
      scratch = row!(ctx, %{name: "scratchy", home: "scratch"})
      gone = row!(ctx, %{name: "gone"})
      Arca.Repo.delete!(gone)

      assert {:ok, orphans} = Mount.orphaned_homes([kept.id, scratch.id, gone.id])
      assert Enum.sort(orphans) == Enum.sort([{scratch.id, ctx.athanor_id}, {gone.id, nil}])

      Arca.Test.Actor.archive!(ctx.athanor_id)
      assert {:ok, orphans} = Mount.orphaned_homes([kept.id])
      assert orphans == [{kept.id, ctx.athanor_id}]
    end

    # An agent whose brain edge binds the row, or selects a profile of its
    # brain whose own ingress binds it, runs its brain in the home; one
    # whose edge to a hand binds it, or whose brain's profile binds it only
    # on an edge of the brain's own, does not.
    test "agents_mounting/2 names the agents whose brain edge reaches the binding", %{ctx: ctx} do
      entry = binding_target!(ctx)
      elsewhere = binding_target!(ctx)

      bound = fn key, id ->
        %{binding_key: key, vault_entry_id: id, binding_digest: "sha256:b"}
      end

      lent = fn key -> %{binding_key: key, via_label: "work", binding_digest: nil} end

      for {name, brain, ref} <- [
            {"member", "catalyst:local.brain:0.1.0",
             bound.("agent:local.member|catalyst:local.brain|claude|default", entry.id)},
            {"bare", "catalyst:local.brain",
             bound.("agent:local.bare|catalyst:local.brain|default", entry.id)},
            {"borrower", "catalyst:local.brain",
             lent.("agent:local.borrower|catalyst:local.brain|default")},
            {"handed", "catalyst:local.other",
             bound.("agent:local.handed|catalyst:local.brain|claude|default", entry.id)},
            {"lent", "catalyst:local.lender",
             lent.("agent:local.lent|catalyst:local.lender|default")}
          ] do
        agent!(ctx, name, brain)
        head!(ctx, "prof_mounting_#{name}", Prima.AgentRef.ref(name), "default", [ref])
      end

      head!(ctx, "prof_mounting_brain", "catalyst:local.brain", "work", [
        bound.("catalyst:local.brain|@ingress|default", entry.id)
      ])

      head!(ctx, "prof_mounting_lender", "catalyst:local.lender", "work", [
        bound.("catalyst:local.lender|@ingress|default", elsewhere.id),
        bound.("catalyst:local.lender|catalyst:local.hand|default", entry.id)
      ])

      agent!(ctx, "unbound", "catalyst:local.brain")

      assert {:ok, names} = Mount.agents_mounting(ctx.athanor_id, entry.id)
      assert Enum.sort(names) == ["bare", "borrower", "member"]
      assert {:ok, ["lent"]} = Mount.agents_mounting(ctx.athanor_id, elsewhere.id)
    end
  end

  # What a head's row names as its bound value: the consent store's rows
  # reference a vault entry, so the read of the edges binding one is shown
  # on an entry's id; `agents_mounting/2` passes the id through whole.
  defp binding_target!(ctx) do
    {:ok, view} =
      TestContext.create_signed_in_login(ctx, %{
        name: "login-#{System.unique_integer([:positive])}",
        program: "claude"
      })

    view
  end

  # The agent `name`'s index row, its brain `catalyst_ref`.
  defp agent!(ctx, name, catalyst_ref) do
    Arca.Repo.insert!(%Arca.Schemas.Agent{
      id: "agt_#{System.unique_integer([:positive])}",
      athanor_id: ctx.athanor_id,
      name: name,
      kind: "role",
      revision_digest: "sha256:rev",
      capability_digest: "sha256:cap",
      catalyst_ref: catalyst_ref,
      synced_at: DateTime.utc_now()
    })
  end

  # A profile of `source` under `label` whose head holds `refs`.
  defp head!(ctx, profile_id, source, label, refs) do
    {:ok, _} =
      Arca.Test.Writers.put_profile(%{
        id: profile_id,
        athanor_id: ctx.athanor_id,
        source_ref: source,
        kind: "owner",
        label: label,
        status: "active"
      })

    {:ok, _} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: ctx.athanor_id,
          profile_id: profile_id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.Digest.sha256("{}"),
          resolved_policy: "{}",
          activation: "{}",
          granted_by: "test",
          granted_via: "bootstrap"
        },
        refs,
        nil
      )
  end
end
