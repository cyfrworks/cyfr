# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GenServerCatchallTest do
  @moduledoc """
  Every named GenServer with a catch-all `handle_info/2` survives an
  unexpected message and logs it BOUNDED.

  Discovers named GenServers using `Cyfr.UnexpectedMessage.log/3` and
  requires each to have a behavioral probe or an explicit exemption.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @unexpected_msg :unexpected_test_message

  # Probed live: named, started by the app under test.
  @genservers [
    {Aqua.Loop.Worker, "Loop.Worker"},
    {Cyfr.Ops.Catalog, "Catalog"},
    {Emissary.MCP.ResourceRegistry, "ResourceRegistry"},
    {Arca.Cache.Sweeper, "Sweeper"},
    {Prism.TelemetryBridge, "TelemetryBridge"},
    {Arca.AuditHandler, "AuditHandler"},
    {Prism.TinctureRegistry, "TinctureRegistry"},
    {Cyfr.RecordSink, "RecordSink"},
    {Cyfr.RateLimiter, "RateLimiter"},
    {Cyfr.Execution.Rates, "Rates"},
    {Cyfr.Execution.Slots, "Slots"},
    {Cyfr.Execution.Events.Sequence, "Events.Sequence"}
  ]

  # Named adopters not probed live, each with the reason it cannot be:
  # gated off (returns :ignore) or not started in the test environment.
  @not_probed %{
    Cyfr.RetentionScheduler => "gated by :retention_scheduler_enabled",
    Cyfr.Schedules.Scheduler => "gated by :cron_scheduler_enabled",
    Cyfr.ControlPlane => "gated by :control_plane_claim_enabled",
    Cyfr.Execution.Sweeper => "gated by :execution_sweeper_enabled",
    Cyfr.Execution.WorkerWatch => "gated by :worker_watch_enabled",
    Emissary.MCP.ExternalServerReconciler => "gated by :external_server_reconciler_enabled",
    Emissary.MCP.Bridge => "started only when an MCP bridge URL and key are configured",
    Emissary.MCP.RunningTasks => "probing would race real request tracking",
    Arca.Overlay.UnitLock => "holds live commit locks — a probe interleaves them",
    Sanctum.Consent.Proof.Memory => "started only when the memory proof store is configured",
    Sanctum.Consent.Source.Memory => "never supervised — a test starts it per case",
    Sanctum.Authority.BudgetGuard => "guards live invoke budgets"
  }

  # Classify GenServers requiring fixture setup before catch-all probing.

  describe "catch-all handle_info/2" do
    for {mod, label} <- @genservers do
      test "#{label} (#{mod}) survives unexpected message and logs warning" do
        mod = unquote(mod)
        pid = Process.whereis(mod)

        if is_nil(pid) do
          flunk("#{inspect(mod)} is not running — cannot test catch-all handle_info/2")
        end

        assert Process.alive?(pid), "#{inspect(mod)} should be alive before sending message"

        log =
          capture_log(fn ->
            send(pid, @unexpected_msg)
            :sys.get_state(pid)
          end)

        assert Process.alive?(pid),
               "#{inspect(mod)} should still be alive after receiving unexpected message"

        assert log =~ "unexpected message",
               "Expected #{inspect(mod)} to log 'unexpected message', got: #{inspect(log)}"

        assert log =~ inspect(@unexpected_msg),
               "Expected log to contain #{inspect(@unexpected_msg)}, got: #{inspect(log)}"
      end
    end
  end

  describe "an execution's event buffer" do
    # One unnamed buffer per execution, so it is probed on an instance of
    # its own. It reads the execution's row for its durable prefix when it
    # starts, so it needs the sandbox connection.
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
      :ok
    end

    for message <- [@unexpected_msg, {:random, "payload"}] do
      test "survives #{inspect(message)} and logs it" do
        id = "exec_catchall_#{System.unique_integer([:positive])}"
        {:ok, pid} = GenServer.start_link(Cyfr.Execution.Events, {id, "ath_catchall"}, [])

        assert capture_log(fn ->
                 send(pid, unquote(Macro.escape(message)))
                 :sys.get_state(pid)
               end) =~ "unexpected message"

        assert Process.alive?(pid)
        GenServer.stop(pid)
      end
    end
  end

  describe "an execution's attempt" do
    # One unnamed attempt per open execution, registered under its id, so
    # it is probed on an instance of its own.
    for message <- [@unexpected_msg, {:random, "payload"}] do
      test "survives #{inspect(message)} and logs it" do
        ctx = Sanctum.TestContext.local()
        record = Cyfr.Execution.Record.new(ctx, "catalyst:local.catchall:0.1.0", %{})

        {:ok, pid} =
          Cyfr.Execution.Attempt.open(
            execution_id: record.id,
            attempt: record.attempt,
            ctx: ctx,
            authority: Cyfr.Authority.zero(),
            component_ref: "catalyst:local.catchall:0.1.0",
            close: %Cyfr.Execution.Close{ctx: ctx, record: record}
          )

        assert capture_log(fn ->
                 send(pid, unquote(Macro.escape(message)))
                 :sys.get_state(pid)
               end) =~ "unexpected message"

        assert Process.alive?(pid)
      end
    end
  end

  describe "the roster derives from the adopters" do
    # Static analysis over every lib file, like its sibling seam tests.
    # They read the whole tree concurrently under a full-suite run and the
    # default 60s deadline is a file-IO race, not a property of the check.
    @tag timeout: :infinity
    test "every named cyfr-app adopter is probed or excused" do
      root = Path.expand("../../../..", __DIR__)

      rostered =
        MapSet.union(
          MapSet.new(@genservers, fn {mod, _} -> mod end),
          MapSet.new(Map.keys(@not_probed))
        )

      adopters =
        for path <- Cyfr.Test.SourceTree.files!(Path.join(root, "apps/cyfr/lib/**/*.ex")),
            source = Cyfr.Test.SourceTree.read(path),
            String.contains?(source, "Cyfr.UnexpectedMessage.log(__MODULE__"),
            # Two spellings register the app-wide name, and matching only the
            # first hid `Sanctum.Authority.BudgetGuard` — a real adopter —
            # from this roster entirely, which made its `@not_probed` row
            # inert rather than load-bearing.
            String.match?(source, ~r/name: __MODULE__|:name, __MODULE__/),
            [_, mod] <-
              Regex.scan(~r/defmodule ([\w.]+) do/, source, capture: :all) |> Enum.take(1),
            do: Module.concat([mod])

      missing = Enum.reject(adopters, &MapSet.member?(rostered, &1))

      assert missing == [],
             "named GenServers adopted Cyfr.UnexpectedMessage without joining this " <>
               "test's roster (probe them, or excuse them with a reason): #{inspect(missing)}"
    end
  end

  describe "the helper's inspect is bounded" do
    test "a huge term logs a bounded line" do
      huge = %{blob: String.duplicate("x", 1_000_000), list: Enum.to_list(1..100_000)}

      log = capture_log(fn -> Cyfr.UnexpectedMessage.log(__MODULE__, huge) end)

      assert log =~ "unexpected message"

      assert String.length(log) < 2_000,
             "the unexpected-message line is unbounded (#{String.length(log)} chars) — " <>
               "the helper exists to keep a stray huge term out of the log"
    end
  end
end
