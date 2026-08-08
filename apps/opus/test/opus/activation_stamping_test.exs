# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.ActivationStampingTest do
  # Activation recording is dark: nothing reads these columns yet, and an
  # activation that cannot be resolved must never affect an execution.
  use ExUnit.Case, async: false

  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Source

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"

  setup do
    test_path = Path.join(System.tmp_dir!(), "activation_stamp_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))
    Application.put_env(:cyfr, :consent_source, Source.DB)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

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
    assert Map.has_key?(graph, @probe_node)

    # The stored graph is the canonical form the digest was taken over.
    assert Sanctum.JCS.hash_binary(row.activation_graph) == row.activation_digest
  end

  test "a nested child execution carries the root's digest and no graph", %{ctx: ctx} do
    # A real in-chain child via the probe's self-invoking chain op: the
    # child's graph is a subgraph of its root's, so only the digest is
    # repeated — and it arrives over the authority chain, never over a
    # guest-controlled channel.
    {:ok, _output, result} =
      Probe.run_probe(ctx, %{"op" => "chain", "depth" => 1, "leaf" => nil})

    import Ecto.Query

    root = execution_row(result.metadata.execution_id)
    assert root.activation_digest != nil
    assert root.activation_graph != nil

    children =
      Arca.Repo.all(
        from(e in Arca.Execution, where: e.parent_execution_id == ^result.metadata.execution_id)
      )

    assert children != []

    for child <- children do
      assert child.activation_digest == root.activation_digest
      assert child.activation_graph == nil
    end
  end

  test "an unresolvable activation leaves the execution untouched", %{ctx: ctx} do
    # Erase the probe's release digest: its activation is now incomplete.
    {:ok, _} =
      Arca.Repo.query(
        "UPDATE components SET release_digest = NULL WHERE name = 'nested-probe'",
        []
      )

    Arca.Cache.delete_match({:component_meta, :_, :_, :_})

    # The consent loader would refuse this as drift, so best-effort
    # stamping is exercised where it still runs: a direct execution under
    # an authority that carries no activation of its own.
    {:ok, result} =
      Opus.Executor.run(ctx, Probe.probe_ref(), %{"op" => "echo"},
        type: :formula,
        authority: Sanctum.Authority.zero()
      )

    assert result.status == :completed

    row = execution_row(result.metadata.execution_id)
    assert row.activation_digest == nil
    assert row.activation_graph == nil
  end
end
