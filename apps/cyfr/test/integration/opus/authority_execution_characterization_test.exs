# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.AuthorityExecutionCharacterizationTest do
  # Execute a real probe under bootstrap consent loaded from the database.
  # What each run's guest entered with is the authority its runner was
  # handed, at its attach or at its admission, read on the suite's wire.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Cyfr.Test.TwoServices
  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.Bootstrap

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    test_path = Path.join(System.tmp_dir!(), "authority_char_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    # The production source, not the Memory fixture: bootstrap writes real
    # rows and the loader reads them back.

    ctx = Sanctum.TestContext.local()
    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, ctx: ctx}
  end

  test "a pinned profile id from another estate is not found, not rooted", %{ctx: ctx} do
    {:ok, %{profile_id: profile_id}} =
      Cyfr.Execution.authority_for(ctx, :default, @probe_node)

    # The one place an agent-authored string selects an authority is the
    # approved `execution.run`/`run_stream` arm, which forwards
    # args["profile"] verbatim. The containment is that candidates load
    # for the CALLER's focused estate — so a profile id minted elsewhere
    # answers not-found instead of rooting a foreign authority.
    elsewhere = %{ctx | athanor_id: "ath_b"}

    assert {:error, {:not_found, ^profile_id}} =
             Cyfr.Execution.authority_for(elsewhere, {:id, profile_id}, @probe_node)

    # At home the same id resolves: the refusal above is scoping, not the
    # id's form.
    assert {:ok, %{profile_id: ^profile_id}} =
             Cyfr.Execution.authority_for(ctx, {:id, profile_id}, @probe_node)
  end

  test "a self-invoking chain keeps the consented authority at every level", %{ctx: ctx} do
    {:ok, run_result} =
      Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{
        "op" => "chain",
        "depth" => 2,
        "leaf" => nil
      })

    assert run_result.status == :completed

    root_id = run_result.metadata.execution_id

    run =
      Arca.Repo.all(
        from(e in Arca.Execution, where: e.root_execution_id == ^root_id, select: e.id)
      )

    # Root plus two self-invoked descendants, all bound to the same node
    # under the same profile — a component is not a boundary against
    # itself, and unlike the legacy suite nothing here ran on ambient
    # permissions.
    authorities = Enum.map(run, &TwoServices.entered/1)
    assert length(authorities) == 3
    assert Enum.all?(authorities, &(&1.cursor == {:bound, @probe_node}))
    assert authorities |> Enum.map(& &1.depth) |> Enum.sort() == [0, 1, 2]

    for authority <- authorities do
      assert authority.profile_id
      assert authority.resources != :none
    end

    # Every descendant row carries the root's activation digest; only the
    # root row carries the graph.
    root_row = Arca.Repo.get(Arca.Execution, run_result.metadata.execution_id)
    assert root_row.activation_digest
    assert root_row.activation_graph

    children =
      Arca.Repo.all(
        from(e in Arca.Execution,
          where: e.parent_execution_id == ^run_result.metadata.execution_id
        )
      )

    assert children != []

    for child <- children do
      assert child.activation_digest == root_row.activation_digest
      assert child.activation_graph == nil
    end
  end

  test "guest emits are attributed: origin and emitting node in the envelope", %{ctx: ctx} do
    {:ok, run_result} =
      Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{
        "op" => "emit",
        "events" => [%{"note" => "one"}]
      })

    assert run_result.status == :completed

    events =
      Cyfr.Execution.Events.since(run_result.metadata.execution_id, {0, 0}, ctx.athanor_id)

    emit = Enum.find(events, &(&1.type == "emit"))

    assert emit != nil
    # The deliberate diff from the legacy five-key envelope: a consumer can
    # always tell a guest-authored event from the host's.
    assert emit.origin == "guest"
    assert emit.node == @probe_node

    terminal = Enum.find(events, &(&1.type != "emit"))
    assert terminal == nil or terminal.origin == "host"
  end

  test "an in-chain control-plane tool call passes the full conjunction", %{ctx: ctx} do
    # component.search is in the probe's expanded ingress tools (bootstrap
    # expanded the manifest allowlist), the action is in-chain-annotated,
    # and the caller identity holds the permission — all three legs.
    {:ok, run_result} =
      Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{
        "op" => "call",
        "request" => %{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "nested-probe"}
        }
      })

    assert run_result.status == :completed

    assert %{"status" => "completed"} = Jason.decode!(run_result.output["result_raw"])
  end

  test "an in-chain tool outside the consent's edge is denied", %{ctx: ctx} do
    # webhook.list is in-chain-annotated but outside the probe's expanded
    # tools, so the chain authority's transition relation refuses the
    # dispatch — with the shim allowlist gone this is the only layer, and
    # its verdict reaches the guest as an encoded error naming the
    # authority denial.
    {:ok, run_result} =
      Cyfr.Execution.run_root(ctx, :default, Probe.probe_ref(), %{
        "op" => "call",
        "request" => %{"tool" => "webhook", "action" => "list", "args" => %{}}
      })

    assert run_result.status == :completed

    assert %{"error" => %{"type" => "dispatch_error", "message" => message}} =
             Jason.decode!(run_result.output["result_raw"])

    assert message =~ "Denied by chain authority"
  end
end
