# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AuthorityExecutionCharacterizationTest do
  # The surviving characterization: a real probe binary executed under a
  # bootstrap-minted consent through the production DB source. Its legacy
  # twin (the profile-less path's characterization) retired with that
  # path; every property here is the authority path's intended behavior.
  use ExUnit.Case, async: false

  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Source

  @moduletag timeout: 120_000

  @telemetry_event [:opus, :runtime, :authority_entered]
  @probe_node "formula:local.nested-probe"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "authority_char_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    # The production source, not the Memory fixture: bootstrap writes real
    # rows and the loader reads them back.
    Application.put_env(:cyfr, :consent_source, Source.DB)

    ctx = Sanctum.TestContext.local()
    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    on_exit(fn ->
      File.rm_rf!(test_path)
      Application.put_env(:cyfr, :consent_source, Source.Memory)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx}
  end

  defp attach_witness do
    handler_id = "char-witness-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:authority_entered, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp collect_witnesses(acc) do
    receive do
      {:authority_entered, metadata} -> collect_witnesses([metadata | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end

  test "a self-invoking chain rides D2: every level keeps the consented authority", %{ctx: ctx} do
    attach_witness()

    {:ok, run_result} =
      Opus.run_root(ctx, nil, Probe.probe_ref(), %{"op" => "chain", "depth" => 2, "leaf" => nil})

    assert run_result.status == :completed

    witnesses = collect_witnesses([])
    # Root plus two self-invoked descendants, all bound to the same node
    # under the same profile — a component is not a boundary against
    # itself, and unlike the legacy suite nothing here ran on ambient
    # permissions.
    chain_events = Enum.filter(witnesses, &(&1.authority.cursor == {:bound, @probe_node}))
    assert length(chain_events) >= 3

    depths = chain_events |> Enum.map(& &1.authority.depth) |> Enum.sort()
    assert [0, 1, 2] = Enum.take(depths, 3)

    for event <- chain_events do
      assert event.authority.profile_id
      assert event.plane == :guest
      assert event.authority.resources != :none
    end

    # Every descendant row carries the root's activation digest; only the
    # root row carries the graph.
    import Ecto.Query

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
      Opus.run_root(ctx, nil, Probe.probe_ref(), %{
        "op" => "emit",
        "events" => [%{"note" => "one"}]
      })

    assert run_result.status == :completed

    events = Opus.ExecutionEventBuffer.since(run_result.metadata.execution_id, 0, ctx.athanor_id)
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
      Opus.run_root(ctx, nil, Probe.probe_ref(), %{
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
      Opus.run_root(ctx, nil, Probe.probe_ref(), %{
        "op" => "call",
        "request" => %{"tool" => "webhook", "action" => "list", "args" => %{}}
      })

    assert run_result.status == :completed

    assert %{"error" => %{"type" => "dispatch_error", "message" => message}} =
             Jason.decode!(run_result.output["result_raw"])

    assert message =~ "Denied by chain authority"
  end
end
