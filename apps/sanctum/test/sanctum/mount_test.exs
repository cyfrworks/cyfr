# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MountTest do
  @moduledoc """
  The reads the programs controller makes of program rows
  (`Sanctum.Mount`).
  """

  use ExUnit.Case, async: false

  alias Sanctum.Mount
  alias Sanctum.TestContext

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
      entry = row!(ctx, %{name: "claude"})
      elsewhere = row!(ctx, %{name: "codex"})

      bound = fn key, id ->
        %{binding_key: key, mcp_server_id: id, binding_digest: "sha256:b"}
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

    # A brain that is a program names its row by name on the agent's index
    # row, with no consent edge to it: a name a deleted row no longer
    # answers and a replacement answers again, so it names no agent here.
    # The threads its sessions lived in are found by the row they store
    # (`Arca.ThreadStorage.forget_sessions/3`).
    test "agents_mounting/2 names no agent whose brain is a program, by the row's name or id",
         %{ctx: ctx} do
      entry = row!(ctx, %{name: "claude"})

      agent!(ctx, "coder", nil, "claude")
      agent!(ctx, "stale", nil, entry.id)
      agent!(ctx, "plain", "catalyst:local.brain")

      assert {:ok, []} = Mount.agents_mounting(ctx.athanor_id, entry.id)
      assert {:ok, []} = Mount.agents_mounting(ctx.athanor_id, "mcp_none")
    end
  end

  # The agent `name`'s index row, its brain `catalyst_ref` or the program
  # `program` it names.
  defp agent!(ctx, name, catalyst_ref, program \\ nil) do
    Arca.Repo.insert!(%Arca.Schemas.Agent{
      id: "agt_#{System.unique_integer([:positive])}",
      athanor_id: ctx.athanor_id,
      name: name,
      kind: "role",
      revision_digest: "sha256:rev",
      capability_digest: "sha256:cap",
      catalyst_ref: catalyst_ref,
      program: program,
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
