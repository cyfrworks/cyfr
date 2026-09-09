# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionProvenanceTest do
  # Who invoked a child decides what its row keeps of its output. The
  # record shapes it from `parent_reference`; these tests reach the record
  # through the executor, the way production does, so a hop that drops
  # the reference is caught here and not only in a record built by hand.
  use ExUnit.Case, async: false

  alias Opus.Test.NestedExecution, as: Probe
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Source

  @moduletag timeout: 120_000

  setup do
    test_path = Path.join(System.tmp_dir!(), "provenance_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :consent_source, Source.DB)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    :ok = Probe.publish_probe!(ctx)
    {:ok, _} = Bootstrap.run(ctx)

    on_exit(fn ->
      File.rm_rf!(test_path)
      Application.put_env(:cyfr, :consent_source, Source.Memory)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx}
  end

  defp run(ctx, opts) do
    {:ok, result} =
      Opus.Executor.run(
        ctx,
        Probe.probe_ref(),
        %{"op" => "echo"},
        [type: :formula, authority: Sanctum.Authority.zero()] ++ opts
      )

    assert result.status == :completed
    row = Arca.Repo.get(Arca.Execution, result.metadata.execution_id)
    {row, Jason.decode!(row.output)}
  end

  test "a child the assistant invoked keeps a digest of its reply, never the reply", %{ctx: ctx} do
    {row, output} =
      run(ctx,
        parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
        parent_reference: "formula:local.aqua:1.0.7"
      )

    assert output["envelope"] == "v1"
    assert is_binary(output["output_hash"])
    refute Map.has_key?(output, "op")

    # ...and it is the transcript's, not the payload store's.
    assert Arca.Repo.get_by(Arca.Schemas.ExecutionPayload, execution_id: row.id) == nil
  end

  test "any other execution's result stays on its row and is retained as a payload", %{ctx: ctx} do
    {row, output} = run(ctx, [])

    refute Map.has_key?(output, "envelope")

    assert %{kind: "result", digest: digest} =
             Arca.Repo.get_by(Arca.Schemas.ExecutionPayload, execution_id: row.id)

    assert {:ok, _payload, bytes} = Arca.ExecutionPayloads.get(ctx, row.id, "result")
    assert Cyfr.Digest.sha256(bytes) == digest
    assert Jason.decode!(bytes) == output
  end
end
