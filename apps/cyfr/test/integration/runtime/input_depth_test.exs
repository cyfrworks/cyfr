# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.InputDepthTest do
  @moduledoc """
  A run's input nests at most `Prima.RunnerControl.max_input_depth/0`
  arrays and objects, the input object itself the first: the runner reads
  an input no deeper. CYFR refuses a deeper input where the run is
  admitted (`Opus.Admission`), whichever way it came: a root run, an MCP
  tool call in process, and the same call over HTTP. The refusal names the
  bound, and no row, attempt or runner is taken for it. An input at the
  bound is admitted and reaches the runner, which reads it whole.
  """

  use Emissary.Web.ConnCase, async: false

  @moduletag auth: :person
  @moduletag timeout: 120_000

  alias Opus.Provider

  @echo File.read!(
          Path.expand("../../../../locus/test/support/runtime/test_wasm/echo.wasm", __DIR__)
        )
  @ref "reagent:local.depth-echo:0.1.0"
  @max Prima.RunnerControl.max_input_depth()
  @output_refused "Component returned invalid JSON output: it is nested deeper than " <>
                    "#{@max - 1} levels"
  @refused "Input nests arrays and objects deeper than #{@max} levels, " <>
             "the most a run's input may nest"

  setup do
    test_path = Path.join(System.tmp_dir!(), "input_depth_#{System.unique_integer([:positive])}")
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf!(test_path) end)

    ctx = Sanctum.TestContext.local(:api)
    Sanctum.TestContext.ready!(ctx.athanor_id)

    {:ok, _component} =
      Arca.Test.UnitFixtures.ship_bytes!(ctx, @echo, %{
        name: "depth-echo",
        version: "0.1.0",
        type: "reagent",
        description: "Answers its input unchanged"
      })

    {:ok, _bootstrapped} = Sanctum.Consent.Bootstrap.run(ctx)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, ctx: ctx}
  end

  # An object `levels` deep, the input object itself the first.
  defp nested(levels),
    do: Enum.reduce(2..levels//1, %{"leaf" => true}, fn _level, inner -> %{"a" => inner} end)

  defp executions(ctx) do
    import Ecto.Query

    Arca.Repo.aggregate(
      from(e in Arca.Schemas.Execution, where: e.athanor_id == ^ctx.athanor_id),
      :count
    )
  end

  test "a root run of an input one level past the bound is refused, and no row is made",
       %{ctx: ctx} do
    id = Prima.UUID7.execution_id()

    assert {:error, {:invalid_argument, @refused}} =
             Opus.run_root(ctx, :default, @ref, nested(@max + 1), execution_id: id)

    assert Arca.Repo.get(Arca.Schemas.Execution, id) == nil
    # arca:unscoped-ok: the test reads that no attempt exists for an id it minted.
    assert Arca.Repo.get_by(Arca.Schemas.ExecutionAttempt, execution_id: id) == nil
  end

  test "an MCP tool call of an input past the bound is refused with the bound's sentence",
       %{ctx: ctx} do
    before = executions(ctx)

    # The tool answers an admission's refusal as every input refusal is
    # answered: the gate's class, then the sentence.
    assert {:error, "authority_error: " <> @refused} =
             Provider.handle("execution", ctx, %{
               "action" => "run",
               "reference" => @ref,
               "input" => nested(@max + 1)
             })

    assert executions(ctx) == before
  end

  test "the same call over HTTP is answered as a failed tool call naming the bound",
       %{conn: conn, ctx: ctx} do
    before = executions(ctx)

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> mcp_post(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "execution",
          "arguments" => %{
            "action" => "run",
            "reference" => @ref,
            "input" => nested(@max + 1)
          }
        }
      })
      |> json_response(200)

    assert response["result"]["isError"] == true
    assert [%{"text" => text}] = response["result"]["content"]
    assert text =~ @refused
    assert executions(ctx) == before
  end

  test "an input at the bound is admitted and the runner reads it whole", %{ctx: ctx} do
    # One level under the bound runs and answers itself: the guest echoes
    # its input, and a guest's output nests at most one level less than
    # an input may.
    input = nested(@max - 1)
    assert {:ok, %{output: ^input}} = Opus.run_root(ctx, :default, @ref, input, [])

    # At the bound the runner took the input and ran the guest, whose echo
    # is past the output's bound: the run fails on its output, never on its
    # input.
    id = Prima.UUID7.execution_id()

    assert {:error, @output_refused} =
             Opus.run_root(ctx, :default, @ref, nested(@max), execution_id: id)

    assert %{status: "failed"} = Arca.Repo.get(Arca.Schemas.Execution, id)
  end
end
