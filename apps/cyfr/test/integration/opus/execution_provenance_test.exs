# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/opus_service_helper.exs", __DIR__)
Code.require_file("support/nested_execution_helper.exs", __DIR__)

defmodule Opus.ExecutionProvenanceTest do
  # What a row keeps of an output and where the bytes go. These tests
  # reach the record through the executor, the way production does, so a
  # hop that drops the retention class is caught here and not only in a
  # record built by hand.
  use ExUnit.Case, async: false

  @moduletag :requires_opus

  setup_all do
    Cyfr.Test.Integration.Opus.ensure_started!()
    :ok
  end

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
      Cyfr.Execution.Dispatch.run(
        ctx,
        Probe.probe_ref(),
        %{"op" => "echo"},
        [type: :formula, authority: Cyfr.Authority.zero()] ++ opts
      )

    assert result.status == :completed
    row = Arca.Repo.get(Arca.Execution, result.metadata.execution_id)
    {row, Jason.decode!(row.output)}
  end

  test "a child a turn dispatched keeps its result under chat_step, an envelope on the row", %{
    ctx: ctx
  } do
    {row, output} =
      run(ctx,
        parent_execution_id: "exec_parent_#{System.unique_integer([:positive])}",
        retention_class: "chat_step"
      )

    assert output["envelope"] == "v1"
    assert is_binary(output["output_hash"])
    refute Map.has_key?(output, "op")

    assert %{kind: "result", retention_class: "chat_step", attempt: attempt} =
             Arca.Repo.get_by(Arca.Schemas.ExecutionPayload, execution_id: row.id, kind: "result")

    assert attempt == row.current_attempt
  end

  test "any other execution's result is an envelope on its row and bytes in the store", %{
    ctx: ctx
  } do
    {row, output} = run(ctx, [])

    assert output["envelope"] == "v1"

    assert %{kind: "result", retention_class: "api", digest: digest} =
             Arca.Repo.get_by(Arca.Schemas.ExecutionPayload, execution_id: row.id, kind: "result")

    assert digest == output["output_hash"]
    assert {:ok, _payload, bytes} = Arca.ExecutionPayloads.get(ctx, row.id, "result")
    assert Cyfr.Digest.sha256(bytes) == digest
    assert {:ok, %{output: %{"op" => "echo"} = joined}} = Cyfr.Execution.get(ctx, row.id)
    assert Jason.decode!(bytes) == joined
  end
end
