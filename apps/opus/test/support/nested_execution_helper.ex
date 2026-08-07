# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Opus.Test.NestedExecution do
  @moduledoc """
  Builds real nested WASM executions from the checked-in `nested-probe`
  formula fixture (`test_wasm/nested_probe/`) — the first fixture in the
  tree that actually executes as a Component Model binary rather than
  asserting failure paths.

  The probe is input-driven: `op` selects which `cyfr:formula/invoke`
  functions it exercises (`echo` / `call` / `spawn_await` /
  `spawn_await_all` / `emit` / `chain`), and `chain` self-invokes through
  `execution.run` for an N-deep nested execution. Raw host responses are
  echoed back verbatim for characterization.

  `allowed_tools` matters: `Sanctum.Policy` is deny-by-default for MCP
  tools, and the probe's dispatches go through real policy resolution.
  `publish_probe!/2` grants them the way bundled formulas do — a manifest
  `setup.policy.allowed_tools` block, auto-merged into the effective
  policy at read time by `Policy.Resolver` (the manifest-widening path the
  redesign deletes; using it here characterizes it).
  """

  @probe_wasm Path.join(__DIR__, "test_wasm/nested_probe/nested_probe.wasm")
  @probe_ref "formula:local.nested-probe:0.1.0"
  @default_allowed_tools ["execution.run", "component.search"]

  def probe_ref, do: @probe_ref

  @doc """
  Publish the probe into the current (sandboxed) registry and grant its
  tool allowlist. Call from a setup block that has already pointed
  `:cyfr, :base_path` at a temp dir and checked out the SQL sandbox.
  """
  def publish_probe!(ctx, opts \\ []) do
    tools = Keyword.get(opts, :allowed_tools, @default_allowed_tools)

    # :caps is the shape the re-released bundle speaks — a declared ask
    # the consent grants. :setup_policy is the legacy auto-merge path,
    # kept for the legacy characterization twin until it retires with
    # the plane it documents.
    grant_block =
      case Keyword.get(opts, :grant, :caps) do
        :caps -> %{"caps" => %{"tools" => tools}}
        :setup_policy -> %{"setup" => %{"policy" => %{"allowed_tools" => tools}}}
      end

    manifest =
      Jason.encode!(
        Map.merge(
          %{"name" => "nested-probe", "version" => "0.1.0", "type" => "formula"},
          grant_block
        )
      )

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe_wasm), %{
        name: "nested-probe",
        version: "0.1.0",
        type: "formula",
        description: "Nested-execution characterization probe",
        manifest: manifest
      })

    :ok
  end

  @doc """
  Execute the probe through the real path (`Opus.run/4`). Returns
  `{:ok, decoded_probe_output, raw_result}`.
  """
  def run_probe(ctx, input, opts \\ []) do
    case Opus.run(ctx, @probe_ref, input, opts) do
      {:ok, result} -> {:ok, decode(result.output), result}
      other -> other
    end
  end

  @doc "A real N-deep nested execution via the probe's `chain` op."
  def run_chain(ctx, depth, leaf \\ nil) do
    run_probe(ctx, %{"op" => "chain", "depth" => depth, "leaf" => leaf})
  end

  @doc """
  Walk a decoded `chain` output down to depth 0, returning one entry per
  level: `%{depth:, execution_id:, user_id:}` (the root level has neither
  id — they come from each `execution.run` response envelope).
  """
  def unwrap_chain(%{"op" => "chain", "depth" => 0} = leaf), do: [%{depth: 0, leaf: leaf}]

  def unwrap_chain(%{"op" => "chain", "depth" => depth, "result_raw" => raw}) do
    %{"status" => "completed", "output" => run_response} = Jason.decode!(raw)

    child_output = run_response["result"]

    entry = %{
      depth: depth,
      child_execution_id: run_response["execution_id"],
      child_user_id: run_response["user_id"],
      child_status: run_response["status"]
    }

    [entry | unwrap_chain(child_output)]
  end

  defp decode(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> decoded
      _ -> output
    end
  end

  defp decode(output), do: output
end
