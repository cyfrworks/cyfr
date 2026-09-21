# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Execution.Host.StorageTest.GatedAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A put or a usage walk waits for its release while a test process is
  # registered under its gate's name.
  def put(actor, path, content) do
    gate(:host_storage_put_gate)
    Arca.Adapters.Local.put(actor, path, content)
  end

  def usage(actor, path) do
    gate(:host_storage_usage_gate)
    Arca.Adapters.Local.usage(actor, path)
  end

  defp gate(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      gate ->
        send(gate, {:gated, name, self()})

        receive do
          {:release, ^name} -> :ok
        end
    end
  end
end

defmodule Cyfr.Execution.Host.StorageTest.AnsweringAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # A store whose answer is chosen by the file's name: it cannot say whether
  # it wrote `unknown.txt`, keeps losing the append to `contended.txt`, and
  # refuses `refused.txt` outright.
  def put(actor, path, content),
    do: answer(path) || Arca.Adapters.Local.put(actor, path, content)

  def append(actor, path, content),
    do: answer(path) || Arca.Adapters.Local.append(actor, path, content)

  defp answer(path) do
    case List.last(path) do
      "unknown.txt" -> {:error, :unknown}
      "contended.txt" -> {:error, :precondition_failed}
      "refused.txt" -> {:error, :eacces}
      _ -> nil
    end
  end
end

defmodule Cyfr.Execution.Host.StorageTest do
  @moduledoc """
  A runner's `storage`, `fetch_artifact` and `record_denial` host calls act
  for its attempt, never for what the call names: a validly signed storage
  write outside the attempt's consented scope is refused on CYFR and writes
  nothing, an artifact is answered only by the attempt's own digest, and a
  denial is recorded for the attempt's component in its athanor.

  A storage write is accepted only while the attempt holds its row, decided
  with the record of its intent: a cancel or takeover that commits first
  refuses it and leaves no bytes and no intent. One that commits while the
  store call is in flight never waits for the store: it settles the intent
  uncertain with its own row, and the guest is answered `storage_uncertain`,
  as it is when the store cannot say what it did. A store's refusal and an
  append's exhausted conflict are failed intents and their own guest errors.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob.Edge
  alias Cyfr.Execution.Host.StorageTest.{AnsweringAdapter, GatedAdapter}
  alias Cyfr.Test.AttemptFixtures

  @math_wasm_path Path.expand("../../../support/test_wasm/math.wasm", __DIR__)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    Arca.Cache.init()
    Arca.Cache.delete_match({:scope_usage, :_, :_, :_})

    test_dir =
      Path.join(System.tmp_dir!(), "host_storage_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    previous = Map.new([:base_path, :storage_adapter], &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      for {key, value} <- previous do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)

    :ok
  end

  defp attached(paths, actions \\ ["read", "write", "append", "list", "delete", "exists"]) do
    edge = %Edge{storage: %{paths: paths, actions: actions}}
    AttemptFixtures.attached!(authority: %{Authority.zero() | resources: edge})
  end

  defp write(path, text),
    do: %{"action" => "write", "path" => path, "content" => Base.encode64(text)}

  defp storage(fixture, args), do: AttemptFixtures.call(fixture, "storage", args)

  defp gated_adapter, do: Application.put_env(:arca, :storage_adapter, GatedAdapter)

  defp row(fixture), do: Arca.Repo.get!(Arca.Execution, fixture.execution_id)

  defp intents(fixture),
    do:
      Arca.ExecutionAttempts.write_intents(
        Cyfr.Actor.in_athanor(fixture.athanor_id),
        fixture.attempt
      )

  describe "storage" do
    test "a validly signed operation outside the consented scope is refused on CYFR and writes nothing" do
      fixture = attached(["data/reports/"], ["read", "write"])

      for {path, type} <- [
            {"data/secrets/key.json", "storage_path_denied"},
            {"data/reports/../secrets/key.json", "storage_path_denied"},
            {"/data/reports/x.txt", "storage_path_denied"},
            {"aqua/agent.json", "storage_path_denied"},
            {"threads/thread_1/x.txt", "storage_path_denied"},
            {"components/catalysts/moonmoon69/x/1.0.0/catalyst.wasm", "storage_path_denied"}
          ] do
        assert %{"error" => "guest_error", "type" => ^type} =
                 storage(fixture, write(path, "forged"))
      end

      assert %{"error" => "guest_error", "type" => "action_denied"} =
               storage(fixture, %{"action" => "delete", "path" => "data/reports/x.txt"})

      for segments <- [
            ["data", "secrets", "key.json"],
            ["data", "reports", "x.txt"],
            ["aqua", "agent.json"],
            ["threads", "thread_1", "x.txt"],
            ["components", "catalysts", "moonmoon69", "x", "1.0.0", "catalyst.wasm"]
          ],
          do: refute(Arca.exists?(Sanctum.Context.actor(fixture.ctx), segments))

      assert %{"ok" => %{"written" => true}} =
               storage(fixture, write("data/reports/q3.txt", "granted"))

      assert {:ok, "granted"} =
               Arca.get(Sanctum.Context.actor(fixture.ctx), ["data", "reports", "q3.txt"])
    end

    test "an operation a runner's parse could not have produced is lost, and the attempt keeps running" do
      fixture = attached(["data/"])

      for args <- [
            %{"action" => "truncate", "path" => "data/a.txt"},
            %{"action" => "write", "path" => "data/a.txt", "content" => 42},
            %{"action" => "read"},
            %{"path" => "data/a.txt"}
          ] do
        assert %{"error" => "lost"} = storage(fixture, args)
      end

      assert %{"ok" => %{"written" => true}} = storage(fixture, write("data/a.txt", "still held"))
    end

    test "after a cancel or a takeover a write is lost and leaves no bytes" do
      cancelled = attached(["data/"])

      assert %{"ok" => %{"written" => true}} =
               storage(cancelled, write("data/before.txt", "kept"))

      assert {:ok, %{cancelled: true}} =
               Cyfr.Execution.cancel(cancelled.ctx, cancelled.execution_id)

      for args <- [
            write("data/after.txt", "late"),
            write("data/before.txt", "overwritten"),
            %{"action" => "delete", "path" => "data/before.txt"}
          ] do
        assert %{"error" => "lost"} = storage(cancelled, args)
      end

      taken = attached(["data/"])

      {:ok, _successor} =
        Arca.ExecutionAttempts.takeover(
          Cyfr.Actor.in_athanor(taken.athanor_id),
          taken.execution_id,
          boot_id: Cyfr.Boot.id(),
          lease_until: Arca.ExecutionAttempts.lease_until()
        )

      assert %{"error" => "lost"} = storage(taken, write("data/stale.txt", "late"))

      refute Arca.exists?(Sanctum.Context.actor(cancelled.ctx), ["data", "after.txt"])
      refute Arca.exists?(Sanctum.Context.actor(cancelled.ctx), ["data", "stale.txt"])

      assert {:ok, "kept"} =
               Arca.get(Sanctum.Context.actor(cancelled.ctx), ["data", "before.txt"])
    end

    test "a cancel that commits after a write's checks and before the write refuses it" do
      fixture = attached(["data/"])
      gated_adapter()
      Process.register(self(), :host_storage_usage_gate)

      writer = Task.async(fn -> storage(fixture, write("data/between.txt", "late")) end)

      # The write has passed the row check and stands in the scope's usage
      # walk, before it writes.
      assert_receive {:gated, :host_storage_usage_gate, walker}, 5_000
      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(fixture.ctx, fixture.execution_id)
      send(walker, {:release, :host_storage_usage_gate})

      assert %{"error" => "lost"} = Task.await(writer)
      refute Arca.exists?(Sanctum.Context.actor(fixture.ctx), ["data", "between.txt"])
      assert row(fixture).status == "cancelled"
    end

    test "a cancel while a write is in flight does not wait for the store, and the write is uncertain" do
      fixture = attached(["data/"])
      gated_adapter()
      Process.register(self(), :host_storage_put_gate)

      writer = Task.async(fn -> storage(fixture, write("data/in-flight.txt", "landed")) end)
      assert_receive {:gated, :host_storage_put_gate, putter}, 5_000

      # The intent stands, no transaction does: the cancel commits at once
      # and settles the intent with its terminal row.
      assert [%{state: "pending", op: "put", path: "data/in-flight.txt", bytes: 6}] =
               intents(fixture)

      assert {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(fixture.ctx, fixture.execution_id)
      assert row(fixture).status == "cancelled"
      assert [%{state: "uncertain", reason: "cancelled"}] = intents(fixture)

      refute Arca.Adapters.Local.exists?(Sanctum.Context.actor(fixture.ctx), [
               "data",
               "in-flight.txt"
             ])

      send(putter, {:release, :host_storage_put_gate})

      assert %{"error" => "guest_error", "type" => "storage_uncertain", "message" => message} =
               Task.await(writer)

      assert message =~ "data/in-flight.txt"
      assert [%{state: "uncertain", reason: "cancelled"}] = intents(fixture)
      assert row(fixture).status == "cancelled"

      # The attempt no longer holds its row: its next write is lost.
      assert %{"error" => "lost"} = storage(fixture, write("data/next.txt", "late"))
      refute Arca.exists?(Sanctum.Context.actor(fixture.ctx), ["data", "next.txt"])
    end

    test "a takeover while a write is in flight leaves it uncertain under the stale fence" do
      fixture = attached(["data/"])
      gated_adapter()
      Process.register(self(), :host_storage_put_gate)

      writer = Task.async(fn -> storage(fixture, write("data/stale.txt", "stale")) end)
      assert_receive {:gated, :host_storage_put_gate, putter}, 5_000

      {:ok, %{attempt: %{fence: 2}}} =
        Arca.ExecutionAttempts.takeover(
          Cyfr.Actor.in_athanor(fixture.athanor_id),
          fixture.execution_id,
          boot_id: Cyfr.Boot.id(),
          lease_until: Arca.ExecutionAttempts.lease_until()
        )

      send(putter, {:release, :host_storage_put_gate})

      assert %{"error" => "guest_error", "type" => "storage_uncertain"} = Task.await(writer)
      assert [%{state: "uncertain", reason: "taken_over", fence: 1}] = intents(fixture)
    end

    @tag :capture_log
    test "a store that cannot say, one that refused and an append that kept losing are told apart" do
      fixture = attached(["data/"])
      Application.put_env(:arca, :storage_adapter, AnsweringAdapter)
      append = &%{"action" => "append", "path" => &1, "content" => Base.encode64("x")}

      assert %{"error" => "guest_error", "type" => "storage_uncertain"} =
               storage(fixture, write("data/unknown.txt", "x"))

      assert %{"error" => "guest_error", "type" => "storage_uncertain"} =
               storage(fixture, append.("data/unknown.txt"))

      assert %{"error" => "guest_error", "type" => "storage_conflict"} =
               storage(fixture, append.("data/contended.txt"))

      assert %{"error" => "guest_error", "type" => "storage_error"} =
               storage(fixture, write("data/refused.txt", "x"))

      assert %{"ok" => %{"written" => true}} = storage(fixture, write("data/fine.txt", "x"))

      assert [
               {"put", "data/unknown.txt", "uncertain", "unknown_outcome"},
               {"append", "data/unknown.txt", "uncertain", "unknown_outcome"},
               {"append", "data/contended.txt", "failed", "precondition_failed"},
               {"put", "data/refused.txt", "failed", "eacces"},
               {"put", "data/fine.txt", "confirmed", nil}
             ] == for(i <- intents(fixture), do: {i.op, i.path, i.state, i.reason})

      # An uncertain write ends nothing: the attempt still holds its row.
      assert row(fixture).status == "running"
    end

    test "a write racing a cancel is written before the terminal row, lost with nothing written, or uncertain" do
      outcomes =
        for n <- 1..20 do
          fixture = attached(["data/"])
          path = ["data", "race-#{n}.txt"]

          writer = Task.async(fn -> storage(fixture, write(Enum.join(path, "/"), "raced")) end)

          canceller =
            Task.async(fn ->
              Process.sleep(Enum.random(0..3))
              {:ok, %{cancelled: true}} = Cyfr.Execution.cancel(fixture.ctx, fixture.execution_id)
              {Arca.exists?(Sanctum.Context.actor(fixture.ctx), path), intents(fixture)}
            end)

          written = Task.await(writer)
          {existed_at_cancel, intents_at_cancel} = Task.await(canceller)

          # The terminal row never leaves an intent pending.
          refute Enum.any?(intents_at_cancel, &(&1.state == "pending"))

          case written do
            %{"ok" => %{"written" => true}} ->
              assert existed_at_cancel, "a write answered written landed after the terminal row"
              assert [%{state: "confirmed"}] = intents(fixture)
              :landed

            %{"error" => "lost"} ->
              refute existed_at_cancel
              refute Arca.exists?(Sanctum.Context.actor(fixture.ctx), path)
              assert [] = intents(fixture)
              :refused

            %{"error" => "guest_error", "type" => "storage_uncertain"} ->
              assert [%{state: "uncertain", reason: "cancelled"}] = intents(fixture)
              :uncertain
          end
        end

      assert Enum.all?(outcomes, &(&1 in [:landed, :refused, :uncertain]))
    end
  end

  describe "fetch_artifact" do
    test "answers the bytes of the attempt's own component, and nothing by another digest" do
      ctx = Sanctum.TestContext.local()
      wasm = File.read!(@math_wasm_path)

      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: "host-storage-artifact",
          version: "0.1.0",
          type: "reagent"
        })

      digest = Cyfr.Digest.sha256(wasm)
      fixture = AttemptFixtures.attached!(ctx: ctx, digest: digest)

      assert %{"ok" => encoded} =
               AttemptFixtures.call(fixture, "fetch_artifact", %{"digest" => digest})

      assert Base.decode64!(encoded) == wasm

      other = AttemptFixtures.attached!(ctx: ctx)

      assert %{"error" => "not_found"} =
               AttemptFixtures.call(other, "fetch_artifact", %{"digest" => digest})

      # The attempt's own digest, with no artifact in the registry.
      assert %{"error" => "not_found"} =
               AttemptFixtures.call(other, "fetch_artifact", %{
                 "digest" => Cyfr.Digest.sha256(other.component_ref)
               })

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "fetch_artifact", %{"digest" => 42})
    end
  end

  describe "record_denial" do
    defp rows(fixture) do
      {:ok, rows} = Arca.PolicyLog.list(athanor_id: fixture.athanor_id, limit: 50)
      Enum.filter(rows, &(&1.component_ref == fixture.component_ref))
    end

    test "records a policy refusal for the attempt's component, bounded, and ignores any other" do
      fixture = AttemptFixtures.attached!()

      assert %{"ok" => true} =
               AttemptFixtures.call(fixture, "record_denial", %{
                 "type" => "private_ip_blocked",
                 "message" => String.duplicate("x", 5_000)
               })

      assert %{"ok" => true} =
               AttemptFixtures.call(fixture, "record_denial", %{
                 "type" => "invalid_json",
                 "message" => "Invalid JSON request"
               })

      assert [row] = rows(fixture)
      assert row.event_type == "denied"
      assert row.decision == "denied"
      assert row.component_type == "catalyst"
      assert String.length(row.decision_reason) == 1_024

      assert %{"error" => "lost"} =
               AttemptFixtures.call(fixture, "record_denial", %{"type" => "domain_blocked"})
    end
  end
end
