# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
unless Code.ensure_loaded?(Opus.Test.NestedExecution) do
defmodule Opus.Test.NestedExecution do
  @moduledoc """
  Builds real nested WASM executions from the checked-in `nested-probe`
  formula fixture (`test_wasm/nested_probe/`) — a fixture that actually
  executes as a Component Model binary rather than asserting failure
  paths.

  The probe is input-driven: `op` selects which `cyfr:formula/invoke`
  functions it exercises (`echo` / `call` / `spawn_await` /
  `spawn_await_all` / `emit` / `chain`), and `chain` self-invokes through
  `execution.run` for an N-deep nested execution. Raw host responses are
  echoed back verbatim for characterization.

  `allowed_tools` matters: the probe's dispatches run under a
  consent-rooted authority, and a tool outside the consented edge is
  denied. `publish_probe!/2` plants the probe in a private seed tree
  and registers it — a manifest `caps.tools` block that
  `Sanctum.Consent.Bootstrap` expands into the minted consent's
  ingress edge.
  """

  @probe_wasm Path.join(__DIR__, "test_wasm/nested_probe/nested_probe.wasm")
  @probe_ref "formula:local.nested-probe:0.1.0"
  @default_allowed_tools ["execution.run", "component.search"]

  def probe_ref, do: @probe_ref

  @doc """
  Plant the probe in a private seed tree and register it. Call from a
  setup block that has already pointed `:cyfr, :base_path` at a temp
  dir and checked out the SQL sandbox; run
  `Sanctum.Consent.Bootstrap.run/1` afterwards to mint the consent
  the probe executes under.
  """
  def publish_probe!(ctx, opts \\ []) do
    tools = Keyword.get(opts, :allowed_tools, @default_allowed_tools)
    Cyfr.Test.SeedBundle.isolate!()

    {:ok, _component} =
      Arca.Test.UnitFixtures.ship_and_register!(
        ctx,
        "formula",
        "local",
        "nested-probe",
        "0.1.0",
        manifest: %{
          "name" => "nested-probe",
          "version" => "0.1.0",
          "type" => "formula",
          "publisher" => "local",
          "description" => "Nested-execution characterization probe",
          "caps" => %{"tools" => tools}
        },
        wasm: File.read!(@probe_wasm)
      )

    :ok
  end

  @doc """
  Execute the probe through the consent-rooted path (`Cyfr.Execution.run_root/5`).
  Returns `{:ok, decoded_probe_output, raw_result}`.
  """
  def run_probe(ctx, input, opts \\ []) do
    case Cyfr.Execution.run_root(ctx, :default, @probe_ref, input, opts) do
      {:ok, result} -> {:ok, decode(result.output), result}
      other -> other
    end
  end

  defp decode(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> decoded
      _ -> output
    end
  end

  defp decode(output), do: output
end
end
