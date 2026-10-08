# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.VaultDenialTest do
  @moduledoc """
  A catalyst's `cyfr:vault/read` in the runner: a field its attach was
  handed is answered; a field name outside them is refused and reported
  to CYFR as a `secret_denied` `record_denial` of the run's attempt,
  carrying the name and nothing else; a name the contract bounds out (past
  256 bytes, or carrying a control byte) is refused, reported to no one
  and logged without the name. A field of an entry the node's edge binds
  whose value CYFR attaches to requests and never hands over, the default
  binding's or a named account's, is refused as `disclosure_refused`,
  reported as such, and the run goes on; a disclosed field and a
  publisher's provided value are answered as handed over. The runner
  emits no telemetry of its own for any of it: CYFR audits what it
  dispensed and what a runner reports.

  The guest is `test_wasm/hostile/vault_probe`, run by the runtime in this
  VM against a scripted host.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Opus.Test.ScriptedHost

  @probe File.read!(Path.expand("../support/test_wasm/hostile/vault_probe.wasm", __DIR__))
  @value "sk-probe-7c1d0e"
  @long String.duplicate("N", 257)

  defp probe(host) do
    Opus.Runtime.execute_component(@probe, %{"operation" => "probe"},
      component_type: :catalyst,
      preloaded_fields: %{"PROBE_KEY" => @value},
      component_ref: "catalyst:local.vault-probe:0.1.0",
      host: host,
      authority: Prima.Authority.zero(),
      limits: Prima.Authority.limits(Prima.Authority.zero())
    )
  end

  test "a field outside the projection is refused and reported by name; a name past the bound is not" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)
    handler = "vault-denial-#{System.unique_integer([:positive])}"
    test = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [[:cyfr, :opus, :secret, :accessed], [:cyfr, :opus, :secret, :denied]],
        &__MODULE__.emitted/4,
        test
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    log =
      capture_log(fn ->
        assert {:ok, %{"status" => 200, "data" => %{"read" => "OEEE"}}, _} =
                 probe(attempt.client)
      end)

    # One report, of the one well-formed name refused, for this attempt.
    assert [%{args: args, caller: caller}] = ScriptedHost.requests(host, "record_denial")
    assert args == %{"type" => "secret_denied", "message" => "PROBE_HIDDEN"}
    assert caller.execution_id == attempt.execution_id
    assert caller.attempt == attempt.attempt

    # The value crossed nowhere, and no request carries the bounded-out names.
    for request <- ScriptedHost.requests(host) do
      text = inspect(request, limit: :infinity, printable_limit: :infinity)
      refute text =~ @value
      refute text =~ @long
      refute text =~ "PROBE\nKEY"
    end

    assert log =~ "Field 'PROBE_HIDDEN' is outside the consent's projection"
    assert length(String.split(log, "asked its vault for a name that is no field name")) == 3
    refute log =~ @long
    refute log =~ "PROBE\nKEY"
    refute log =~ @value

    refute_received {:emitted, _event}
  end

  @doc false
  def emitted(event, _measurements, _metadata, test), do: send(test, {:emitted, event})

  # An edge binding the probe's entry under the need's attach rule,
  # projecting `fields`, with `named` accounts beside it.
  defp attached_edge(fields, named \\ %{}) do
    vault = %{
      entry_id: "ent_probe",
      binding_digest: "sha256:probe",
      scope: "athanor",
      binding_key: "catalyst:local.vault-probe|@ingress|default",
      destination: nil,
      attach: %{in: "header", name: "x-api-key", template: "{value}"},
      projection: %{fields: fields, scopes: []},
      named: named
    }

    %Prima.Authority.Blob.Edge{vault: vault}
  end

  defp probe(host, preloaded, edge) do
    Opus.Runtime.execute_component(@probe, %{"operation" => "probe"},
      component_type: :catalyst,
      preloaded_fields: preloaded,
      component_ref: "catalyst:local.vault-probe:0.1.0",
      host: host,
      edge: edge,
      authority: Prima.Authority.zero(),
      limits: Prima.Authority.limits(Prima.Authority.zero())
    )
  end

  test "a field CYFR attaches is refused as such and reported, and the run goes on; one handed over is answered" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host, component_type: :catalyst)

    second = %{
      entry_id: "ent_second",
      projection: %{fields: ["PROBE_HIDDEN"], scopes: []},
      attach: %{in: "header", name: "x-api-key", template: "{value}"}
    }

    # Attach-only: the edge projects both names and nothing was handed.
    log =
      capture_log(fn ->
        assert {:ok, %{"status" => 200, "data" => %{"read" => "EEEE"}}, _} =
                 probe(attempt.client, %{}, attached_edge(["PROBE_KEY"], %{"Second" => second}))
      end)

    assert [
             %{args: %{"type" => "disclosure_refused", "message" => "PROBE_KEY"}},
             %{args: %{"type" => "disclosure_refused", "message" => "PROBE_HIDDEN"}}
           ] = ScriptedHost.requests(host, "record_denial")

    assert log =~ "Field 'PROBE_KEY' is attached to requests by CYFR and never handed to"
    refute log =~ "access-denied"

    # A disclosed field, handed over at attach, is answered as ever, and a
    # name the edge projects nowhere is outside the projection.
    capture_log(fn ->
      assert {:ok, %{"data" => %{"read" => "OEEE"}}, _} =
               probe(attempt.client, %{"PROBE_KEY" => @value}, attached_edge(["PROBE_KEY"]))
    end)

    assert [_, _, %{args: %{"type" => "secret_denied", "message" => "PROBE_HIDDEN"}}] =
             ScriptedHost.requests(host, "record_denial")

    # A publisher's provided value is handed over and answered.
    provided = %Prima.Authority.Blob.Edge{
      vault: %{provided: %{destination: nil, values: %{"PROBE_KEY" => "pk"}, attach: nil}}
    }

    capture_log(fn ->
      assert {:ok, %{"data" => %{"read" => "OEEE"}}, _} =
               probe(attempt.client, %{"PROBE_KEY" => "pk"}, provided)
    end)

    for request <- ScriptedHost.requests(host) do
      refute inspect(request, limit: :infinity, printable_limit: :infinity) =~ @value
    end
  end

  test "without a host client the refusal still stands, and nothing is reported" do
    capture_log(fn ->
      assert {:ok, %{"data" => %{"read" => "OEEE"}}, _} = probe(nil)
    end)
  end
end
