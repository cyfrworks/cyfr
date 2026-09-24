# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.SecretAuditTest do
  @moduledoc """
  What a runner does with a credential reaches the audit trail, which lives
  in the control plane: a runner is an OS process of its own, and nothing
  it emits reaches this VM.

  Host audits what it hands over: at the attach that claims a run's
  attempt, one `[:cyfr, :opus, :secret, :dispensed]` entry per field of the
  consented projection, by name, under the identity the attempt was
  admitted with, never a field the runner sent. An attach its runner
  retries after the answer was lost audits nothing again. A guest's read
  of a field outside the projection is refused in the runner and reported
  (`record_denial`, `secret_denied`), and Host audits it as
  `[:cyfr, :opus, :secret, :denied]` for the attempt whose call key signed
  the report; a name past its bound or carrying a control byte is audited
  by no one. No credential value is audited, logged, stored or published.

  The guest is `test_wasm/hostile/vault_probe` of Opus's suite, run by the
  Opus service in a runner over the suite's wire (`Cyfr.Test.TwoServices`);
  its vault entry holds three fields, and its projection grants two. The
  audit trail is read the way a deployment's own reads it: by attaching to
  `[:cyfr, :audit, :recorded]`, the one event `Arca.AuditHandler` emits per
  entry, already sanitized.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Cyfr.Test.{AttemptFixtures, ChatFixture, OpusService, TwoServices}

  @moduletag timeout: 120_000

  @probe Path.expand("../../../../opus/test/support/test_wasm/hostile/vault_probe.wasm", __DIR__)
  @node "catalyst:local.vault-probe"
  @ref "catalyst:local.vault-probe:0.1.0"

  @canary "sk-canary-3b9e61f0d2a74c58"
  @second "sk-second-a18c5e27f94b0d36"
  @hidden "sk-hidden-5d0f2c8b7e19a643"
  @fields %{"PROBE_KEY" => @canary, "PROBE_SECOND" => @second, "PROBE_HIDDEN" => @hidden}
  @projected ["PROBE_KEY", "PROBE_SECOND"]

  @dispensed [:cyfr, :opus, :secret, :dispensed]
  @denied [:cyfr, :opus, :secret, :denied]

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    run_dir = Path.join(System.tmp_dir!(), "secret_audit_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path]
    previous = Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)
    Application.put_env(:arca, :base_path, run_dir)

    # Every entry the audit trail records while this case runs, as a
    # deployment's own attach receives it.
    test = self()
    attach_id = "secret-audit-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      attach_id,
      [:cyfr, :audit, :recorded],
      fn _event, _measurements, %{audited: audited}, _config ->
        send(test, {:audited, audited})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(attach_id) end)

    ctx = Sanctum.TestContext.local()

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)

      for {{app, key}, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe), %{
        name: "vault-probe",
        version: "0.1.0",
        type: "catalyst",
        description: "Reads four field names from its vault"
      })

    {:ok, ctx: ctx}
  end

  # The probe's authority: its node's own limits, and an edge whose vault
  # resource projects two of the entry's three fields, pinned to an active
  # profile at its head consent so attach unseals it.
  defp authority(ctx) do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 100, "window" => "1m"},
              "max_concurrent_tasks" => 1,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{}}
          }
        }
      })

    profile = %{
      profile_id: "prof-vault-probe",
      consent_id: "consent-vault-probe",
      source_ref: @node,
      kind: :owner,
      invoke_mode: :open_inert,
      activation: %{@node => "sha256:act-vault-probe"}
    }

    {:ok, root} =
      Authority.root(profile, blob, ceiling: Sanctum.Policy.Ceiling.platform_ceiling())

    {%Authority{resources: %Edge{vault: vault}} = authority, _entry} =
      AttemptFixtures.vault_authority!(ctx, %{kind: "api_key", fields: @fields}, root)

    projected = %{vault | projection: %{fields: @projected, scopes: []}}
    %{authority | resources: %Edge{vault: projected}}
  end

  # Run the probe with the Opus service, watching the execution's events,
  # and answer its result, its id, what its stream and the executions topic
  # carried, and the log.
  defp probe!(ctx, authority) do
    id = Prima.UUID7.execution_id()
    :ok = Crucible.subscribe_events(id, ctx)
    actor = Sanctum.Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.executions(actor))

    {result, log} =
      with_log(fn ->
        Crucible.Dispatch.run(ctx, @ref, %{"operation" => "probe"},
          type: :catalyst,
          authority: authority,
          execution_id: id
        )
      end)

    %{result: result, id: id, bus: drain(), log: log}
  end

  # What the execution's stream and the executions topic carried: every
  # message but the sink's.
  defp drain do
    receive do
      message when not is_tuple(message) or elem(message, 0) != :audited ->
        [message | drain()]
    after
      200 -> []
    end
  end

  # Every entry the sink has received since this was last asked.
  defp audited do
    receive do
      {:audited, %Arca.Audit.Event{} = event} -> [event | audited()]
    after
      500 -> []
    end
  end

  defp of(entries, event, execution_id),
    do: Enum.filter(entries, &(&1.name == event and &1.metadata[:execution_id] == execution_id))

  # The identity every entry of the run carries: the attempt the host
  # verified, as its row and the assignment it signed name it.
  defp identity(ctx, id, authority) do
    row = Arca.ExecutionAttempts.current(Sanctum.Context.actor(ctx), id)
    [%{args: %{"assignment" => token}} | _] = TwoServices.calls(:attach, id)
    {:ok, assignment} = Prima.Assignment.read(token)

    %{
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id,
      execution_id: id,
      attempt: row.attempt,
      fence: row.fence,
      component_ref: assignment.component.ref,
      consent_id: authority.consent_id,
      runner: row.claimed_by,
      service: OpusService.service()
    }
  end

  defp values, do: Map.values(@fields)

  describe "through a runner" do
    test "the fields dispensed and the one refused are audited under the attempt's identity, and no value shows anywhere",
         %{ctx: ctx} do
      authority = authority(ctx)
      played = probe!(ctx, authority)

      assert {:ok, %{output: %{"status" => 200, "data" => %{"read" => "OEEE"}}}} = played.result
      mine = Enum.filter(audited(), &(&1.metadata[:execution_id] == played.id))
      identity = identity(ctx, played.id, authority)

      # One entry per projected field, by name, as Host handed them over at
      # attach; the field the projection leaves out is never dispensed.
      dispensed = of(mine, @dispensed, played.id)
      assert Enum.map(dispensed, & &1.metadata.field) == @projected

      for entry <- dispensed do
        assert Map.delete(entry.metadata, :field) == identity
        assert entry.athanor_id == ctx.athanor_id and entry.user_id == ctx.user_id
      end

      # The guest's read of the left-out field was refused in its runner and
      # reported; the names past the bound were reported to no one.
      assert [denied] = of(mine, @denied, played.id)
      assert denied.metadata == Map.put(identity, :field, "PROBE_HIDDEN")

      assert [%{args: %{"type" => "secret_denied", "message" => "PROBE_HIDDEN"}}] =
               TwoServices.calls(:record_denial, played.id)

      # Beside the run's own lifecycle entries, nothing else about a secret.
      assert Enum.count(mine, &match?([:cyfr, :opus, :secret | _], &1.name)) == 3

      # No value was audited, logged, stored, written or published.
      for value <- values() do
        assert ChatFixture.leaks(value, audit: mine, bus: played.bus, log: played.log) == [],
               value
      end

      # The scan finds what is there: a field name in the trail.
      assert {:term, :audit} in ChatFixture.leaks("PROBE_SECOND", audit: mine)
    end

    test "an attach its runner retries after the answer was lost audits each field once",
         %{ctx: ctx} do
      authority = authority(ctx)
      :ok = TwoServices.plan!(:attach, [:forward_then_drop])

      played = probe!(ctx, authority)

      assert {:ok, %{output: %{"data" => %{"read" => "OEEE"}}}} = played.result

      # The first attach was answered and the answer lost on the wire; the
      # runner attached again and was answered the same fields.
      assert [%{action: :forward_then_drop}, %{action: :forward, answer: %{"ok" => fields}}] =
               TwoServices.calls(:attach, played.id)

      assert fields |> Map.keys() |> Enum.sort() == @projected

      dispensed = of(audited(), @dispensed, played.id)
      assert Enum.map(dispensed, & &1.metadata.field) == @projected
    end
  end

  describe "at the host" do
    setup %{ctx: ctx} do
      {authority, _entry} =
        AttemptFixtures.vault_authority!(ctx, %{kind: "api_key", fields: %{"KEY" => @canary}})

      mine = AttemptFixtures.attached!(authority: authority)
      other = AttemptFixtures.attached!()
      {:ok, mine: mine, other: other}
    end

    defp deny(fixture, name, opts \\ []) do
      AttemptFixtures.call(
        fixture,
        "record_denial",
        %{"type" => "secret_denied", "message" => name},
        opts
      )
    end

    test "an attach audits each field once, and a repeat or another runner's attach audits nothing",
         %{mine: mine, other: other} do
      entries = audited()
      assert [entry] = of(entries, @dispensed, mine.execution_id)
      assert entry.metadata.field == "KEY"
      assert entry.metadata.runner == mine.runner
      assert entry.metadata.attempt == mine.attempt

      # An attempt whose edge projects nothing is handed nothing to audit.
      assert of(entries, @dispensed, other.execution_id) == []

      assert %{"ok" => %{"KEY" => @canary}} =
               AttemptFixtures.call(mine, "attach", %{"assignment" => mine.assignment})

      assert %{"error" => "replayed"} =
               AttemptFixtures.call(mine, "attach", %{"assignment" => mine.assignment},
                 runner: "runner_other"
               )

      assert of(audited(), @dispensed, mine.execution_id) == []
    end

    test "a denial is attributed to the attempt the call key signed for, whatever its body says",
         %{mine: mine, other: other} do
      body =
        Jason.encode!(%{
          "op" => "record_denial",
          "args" => %{
            "type" => "secret_denied",
            "message" => "NOT_GRANTED",
            "execution_id" => other.execution_id,
            "athanor_id" => "ath_forged",
            "component_ref" => other.component_ref
          }
        })

      assert %{"ok" => true} = AttemptFixtures.call(mine, "record_denial", %{}, body: body)

      entries = audited()
      assert [entry] = of(entries, @denied, mine.execution_id)
      assert entry.metadata.field == "NOT_GRANTED"
      assert entry.metadata.athanor_id == mine.athanor_id
      assert entry.metadata.component_ref == mine.component_ref
      assert entry.metadata.attempt == mine.attempt
      assert of(entries, @denied, other.execution_id) == []
    end

    @tag :capture_log
    test "a runner holding another attempt's call key cannot write an entry for this attempt",
         %{mine: mine, other: other} do
      # A header naming `other`, signed with `mine`'s call key, verifies as
      # neither.
      assert %{"error" => "lost"} = deny(other, "FORGED", call_key: mine.call_key)
      entries = audited()
      assert of(entries, @denied, other.execution_id) == []
      assert of(entries, @denied, mine.execution_id) == []

      # Its own attempt it can still report for.
      assert %{"ok" => true} = deny(mine, "OWN")
      assert [%{metadata: %{field: "OWN"}}] = of(audited(), @denied, mine.execution_id)
    end

    @tag :capture_log
    test "a name past its bound or carrying a control byte is refused and audits nothing",
         %{mine: mine} do
      for name <- [String.duplicate("N", 257), "PROBE\nKEY", "nul\0byte", "del\x7F", ""] do
        assert %{"error" => "lost"} = deny(mine, name), inspect(name)
      end

      assert of(audited(), @denied, mine.execution_id) == []

      # The attempt is untouched: a well-formed name is still audited.
      assert %{"ok" => true} = deny(mine, String.duplicate("N", 256))
      assert [_entry] = of(audited(), @denied, mine.execution_id)
    end
  end
end
