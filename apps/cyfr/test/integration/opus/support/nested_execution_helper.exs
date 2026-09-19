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
    `spawn_await_all` / `emit` / `chain` / `steps`), `chain` self-invokes
    through `execution.run` for an N-deep nested execution, and `steps`
    makes several of those calls in order, spawning, awaiting, polling and
    cancelling tasks as a test lists them. Raw host responses are echoed
    back verbatim for characterization.

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

    @doc "The probe's checked-in binary, beside its source, lock and README."
    def wasm_path, do: @probe_wasm

    @doc """
    The input of a probe run that asks for one catalog tool
    (`component.search`, which the probe's consent grants) and answers
    what the host said: a run a test can hold at its `tool_call` host call,
    its guest in the middle of its work.
    """
    def held_input do
      %{
        "op" => "call",
        "request" => %{
          "tool" => "component",
          "action" => "search",
          "args" => %{"query" => "nested-probe"}
        }
      }
    end

    @doc """
    Plant the probe in a private seed tree and register it. Call from a
    setup block that has already pointed `:cyfr, :base_path` at a temp
    dir and checked out the SQL sandbox; run
    `Sanctum.Consent.Bootstrap.run/1` afterwards to mint the consent
    the probe executes under. Options: `:allowed_tools` (its `caps.tools`),
    `:limits` (its `caps.limits`), `:dependencies` (the references its
    manifest names as static dependencies, each an edge of its consent),
    `:name` (default `nested-probe`: the same binary under another name)
    and `:isolate` (default true: point `:seed_path` at a fresh private
    tree first; false to plant beside what is there).
    """
    def publish_probe!(ctx, opts \\ []) do
      tools = Keyword.get(opts, :allowed_tools, @default_allowed_tools)
      name = Keyword.get(opts, :name, "nested-probe")
      if Keyword.get(opts, :isolate, true), do: Cyfr.Test.SeedBundle.isolate!()

      caps =
        case Keyword.get(opts, :limits) do
          nil -> %{"tools" => tools}
          limits -> %{"tools" => tools, "limits" => limits}
        end

      manifest =
        %{
          "name" => name,
          "version" => "0.1.0",
          "type" => "formula",
          "publisher" => "local",
          "description" => "Nested-execution characterization probe",
          "caps" => caps
        }
        |> then(fn manifest ->
          case Keyword.get(opts, :dependencies, []) do
            [] -> manifest
            refs -> Map.put(manifest, "dependencies", %{"static" => refs})
          end
        end)

      {:ok, _component} =
        Arca.Test.UnitFixtures.ship_and_register!(
          ctx,
          "formula",
          "local",
          name,
          "0.1.0",
          manifest: manifest,
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
