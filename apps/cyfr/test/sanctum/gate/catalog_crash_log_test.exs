# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.CatalogCrashLogTest do
  @moduledoc """
  A tool handler that crashes or exits is logged by its reason with every
  frame and call reduced to its arity (`Prima.LogFilter.inspect_reason/2`):
  the caller's context and the tool's arguments, which the handler's frame
  and the call it made carry, never reach the log line.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Sanctum.Catalog

  @email "planted-email-5b2c@example.test"
  @value "planted-argument-e81f"

  defmodule Probe do
    @moduledoc false
    @behaviour Prima.Provider

    alias Prima.{Arg, Operation}

    @impl true
    def service, do: "probe"

    @impl true
    def tools do
      [
        Operation.tool(
          for action <- ~w(put call) do
            Operation.new(
              "crash_log_probe",
              action,
              "A tool that crashes or exits",
              [Arg.new("value", :string, required: true)],
              kind: :execute,
              planes: [:external]
            )
          end
        )
      ]
    end

    # No clause for "put": the handler's frame holds the context and the
    # arguments it was called with. "call" exits naming the call it made.
    @impl true
    def handle(_tool, _ctx, %{"action" => "call", "value" => value}) do
      target = spawn(fn -> Process.sleep(1_000) end)
      GenServer.call(target, {:put, value}, 20)
    end
  end

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    :ok
  end

  test "a supervised handler's crash names the handler by arity, never the context or arguments" do
    {result, log} = call("put", runner: :supervised)

    assert {:error, {:uncertain, _sentence}} = result
    assert log =~ "[Sanctum.Dispatch] Tool crash_log_probe exited: "
    assert log =~ "Sanctum.Gate.CatalogCrashLogTest.Probe, :handle, 3,"
    refute log =~ @email
    refute log =~ @value
  end

  test "an inline handler's exit names the call it made by arity, never its request" do
    {result, log} = call("call", runner: :inline)

    assert {:error, {:uncertain, _sentence}} = result
    assert log =~ "{GenServer, :call, 3}"
    refute log =~ @value
  end

  defp call(action, opts) do
    ctx = %{Sanctum.TestContext.local() | email: @email}

    Catalog.with_providers([Probe], fn ->
      with_log(fn ->
        Sanctum.Gate.call_external(
          "crash_log_probe",
          ctx,
          %{"action" => action, "value" => @value},
          opts
        )
      end)
    end)
  end
end
