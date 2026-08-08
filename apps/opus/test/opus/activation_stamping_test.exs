# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.ActivationStampingTest do
  # Activation recording is dark: nothing reads these columns yet, and an
  # activation that cannot be resolved must never affect an execution.
  use ExUnit.Case, async: false

  alias Opus.Test.NestedExecution, as: Probe

  @moduletag timeout: 120_000

  setup do
    test_path = Path.join(System.tmp_dir!(), "activation_stamp_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    # Legacy-path runs need the auto-merged tool grant (no consent here).
    :ok = Probe.publish_probe!(ctx, grant: :setup_policy)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx}
  end

  defp execution_row(execution_id) do
    Arca.Repo.get(Arca.Execution, execution_id)
  end

  test "a root execution records its activation digest and graph", %{ctx: ctx} do
    {:ok, _output, result} = Probe.run_probe(ctx, %{"op" => "echo"})

    row = execution_row(result.metadata.execution_id)

    assert row.activation_digest != nil
    assert String.starts_with?(row.activation_digest, "sha256:")
    assert row.activation_graph != nil

    graph = Jason.decode!(row.activation_graph)
    assert Map.has_key?(graph, "formula:local.nested-probe")

    # The stored graph is the canonical form the digest was taken over.
    assert Sanctum.JCS.hash_binary(row.activation_graph) == row.activation_digest
  end

  test "a nested child execution records no activation", %{ctx: ctx} do
    # The MCP ingress refuses profile-less nesting, so the child is driven
    # the way every spawn layer ultimately does: the legacy path with the
    # parent id threaded through.
    {:ok, _output, result} = Probe.run_probe(ctx, %{"op" => "echo"})

    {:ok, _child_output, child_result} =
      Probe.run_probe(ctx, %{"op" => "echo"}, parent_execution_id: result.metadata.execution_id)

    root = execution_row(result.metadata.execution_id)
    child = execution_row(child_result.metadata.execution_id)

    assert root.activation_digest != nil
    # A child's graph is a subgraph of its root's, and a child cannot be
    # told its root's activation over a guest-controlled channel — so it
    # stamps nothing until the authority chain carries it.
    assert child.activation_digest == nil
    assert child.activation_graph == nil
  end

  test "an unresolvable activation leaves the execution untouched", %{ctx: ctx} do
    # Erase the probe's release digest: its activation is now incomplete.
    {:ok, _} =
      Arca.Repo.query(
        "UPDATE components SET release_digest = NULL WHERE name = 'nested-probe'",
        []
      )

    Arca.Cache.delete_match({:component_meta, :_, :_, :_})

    {:ok, output, result} = Probe.run_probe(ctx, %{"op" => "echo"})

    assert result.status == :completed
    assert output["op"] == "echo"

    row = execution_row(result.metadata.execution_id)
    assert row.activation_digest == nil
    assert row.activation_graph == nil
  end
end
