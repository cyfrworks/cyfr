# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Locus.Runtime.ActivationStampingTest do
  # Activation recording is dark: nothing reads these columns yet, and an
  # activation that cannot be resolved must never affect an execution.
  use ExUnit.Case, async: false

  alias Locus.Runtime.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.Bootstrap

  @moduletag timeout: 120_000

  @probe_node "formula:local.nested-probe"

  setup tags do
    test_path = Path.join(System.tmp_dir!(), "activation_stamp_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    Cyfr.Test.Sandbox.setup!(tags)

    ctx = Sanctum.TestContext.local(:api)
    :ok = Probe.publish_probe!(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @probe_node in minted

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    Sanctum.TestContext.ready!(ctx.athanor_id)

    {:ok, ctx: ctx}
  end

  defp execution_row(execution_id) do
    Arca.Repo.get(Arca.Schemas.Execution, execution_id)
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
    assert Prima.Digest.sha256(row.activation_graph) == row.activation_digest
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
        from(e in Arca.Schemas.Execution,
          where: e.parent_execution_id == ^result.metadata.execution_id
        )
      )

    assert children != []

    for child <- children do
      assert child.activation_digest == root.activation_digest
      assert child.activation_graph == nil
    end
  end

  test "an unresolvable activation refuses the run, which writes no execution", %{ctx: ctx} do
    # A stored manifest that does not decode leaves the probe's activation
    # unresolvable: the run is refused as that damage, and no execution
    # row is written for it.
    {:ok, _} =
      Arca.Repo.query(
        "UPDATE components SET manifest = '{not json' WHERE name = 'nested-probe'",
        []
      )

    Arca.Cache.delete_match({:component_meta, :_, :_})
    before = Arca.Repo.aggregate(Arca.Schemas.Execution, :count)

    assert {:error, {:corrupt, {:manifest, _ref}}} =
             Opus.Dispatch.run(ctx, Probe.probe_ref(), %{"op" => "echo"},
               type: "formula",
               authority: Prima.Authority.zero()
             )

    assert Arca.Repo.aggregate(Arca.Schemas.Execution, :count) == before
  end
end
