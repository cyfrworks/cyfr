# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GenServerCatchallTest do
  @moduledoc """
  Every named GenServer with a catch-all `handle_info/2` survives an
  unexpected message and logs its shape, bounded and without its values.

  Discovers named GenServers using `Cyfr.LoggerContext.unexpected/3` and
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
    {Cyfr.TelemetryBridge, "TelemetryBridge"},
    {Aqua.ScheduleNotes, "ScheduleNotes"},
    {Cyfr.StandingWatch, "StandingWatch"},
    {Arca.AuditHandler, "AuditHandler"},
    {Prism.TinctureRegistry, "TinctureRegistry"},
    {Arca.RecordSink, "RecordSink"},
    {Cyfr.RateLimiter, "RateLimiter"},
    {Cyfr.Execution.Slots, "Slots"},
    {Cyfr.Execution.Events.Sequence, "Events.Sequence"},
    {Compendium.Provisioning, "Provisioning"},
    {Compendium.ProjectionReconciler, "ProjectionReconciler"}
  ]

  # Named adopters not probed live, each with the reason it cannot be:
  # gated off (returns :ignore) or not started in the test environment.
  @not_probed %{
    Cyfr.RetentionScheduler => "gated by :retention_scheduler_enabled",
    Cyfr.Schedules.Scheduler => "gated by :cron_scheduler_enabled",
    Cyfr.Cell => "gated by :control_plane_claim_enabled",
    Cyfr.Execution.Sweeper => "gated by :execution_sweeper_enabled",
    Cyfr.Execution.ArchiveWatch => "gated by :execution_archive_watch_enabled",
    Cyfr.Execution.WorkerWatch => "gated by :worker_watch_enabled",
    Emissary.MCP.ExternalServerReconciler => "gated by :external_server_reconciler_enabled",
    Emissary.MCP.Bridge => "started only when an MCP bridge URL and key are configured",
    Emissary.MCP.RunningTasks => "probing would race real request tracking",
    Sanctum.Consent.Proof.Memory => "started only when the memory proof store is configured",
    Sanctum.Authority.BudgetGuard => "guards live invoke budgets"
  }

  # The libs the control plane's release holds. Opus's and Locus's adopters
  # run in their own VMs and are rostered by their own suites.
  @release_libs ~w(apps/cyfr/lib apps/arca/lib apps/sanctum/lib)

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
    test "every named adopter of the helper is probed or excused" do
      root = Path.expand("../../../..", __DIR__)

      rostered =
        MapSet.union(
          MapSet.new(@genservers, fn {mod, _} -> mod end),
          MapSet.new(Map.keys(@not_probed))
        )

      adopters =
        for dir <- @release_libs,
            path <- Cyfr.Test.SourceTree.files!(Path.join([root, dir, "**/*.ex"])),
            source = Cyfr.Test.SourceTree.read(path),
            String.contains?(source, "Cyfr.LoggerContext.unexpected(__MODULE__"),
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
             "named GenServers adopted Cyfr.LoggerContext.unexpected/3 without joining this " <>
               "test's roster (probe them, or excuse them with a reason): #{inspect(missing)}"
    end
  end

  describe "the helper logs a message's shape" do
    # The line from the module prefix to its end: what the helper wrote,
    # without the formatter's timestamp and level.
    defp helper_line(log) do
      [line] = Regex.run(~r/\[Cyfr\.GenServerCatchallTest\] unexpected message: .*/, log)
      line
    end

    test "a huge term logs a bounded line" do
      huge = %{blob: String.duplicate("x", 1_000_000), list: Enum.to_list(1..100_000)}

      log = capture_log(fn -> Cyfr.LoggerContext.unexpected(__MODULE__, huge) end)

      assert log =~ "unexpected message"
      refute log =~ "xxxx"

      assert String.length(helper_line(log)) <= 200,
             "the unexpected-message line is unbounded (#{String.length(log)} chars) — " <>
               "the helper exists to keep a stray huge term out of the log"
    end

    test "a secret-bearing message logs its shape and never the secret" do
      secret = "sk-live-4f9a1c2e7b0d4e6f8a1b3c5d7e9f0a2b"

      messages = [
        {:thread_event, %{"content" => secret}},
        %{token: secret, athanor_id: "ath_1"},
        %URI{userinfo: secret, host: "example.com"},
        secret,
        [secret, {:credential, secret}],
        {secret, :tail}
      ]

      for message <- messages do
        log = capture_log(fn -> Cyfr.LoggerContext.unexpected(__MODULE__, message) end)

        assert log =~ "unexpected message"
        refute log =~ "sk-live", "the log carried the secret: #{log}"
      end
    end

    test "the shape names the tuple's tag and arity, the struct's module and keys" do
      log = capture_log(fn -> Cyfr.LoggerContext.unexpected(__MODULE__, {:ping, 1, 2}) end)
      assert helper_line(log) =~ "tuple :ping/3"

      log = capture_log(fn -> Cyfr.LoggerContext.unexpected(__MODULE__, %URI{host: "h"}) end)
      assert helper_line(log) =~ "%URI{:authority, :fragment, :host"
      refute log =~ ~s("h")

      map = Map.new(1..20, &{:"key_#{String.pad_leading(to_string(&1), 2, "0")}", &1})
      log = capture_log(fn -> Cyfr.LoggerContext.unexpected(__MODULE__, map) end)
      assert helper_line(log) =~ "map/20 [:key_01,"
      assert log =~ ":key_10]"
      refute log =~ ":key_11"
    end

    test "the level is the caller's" do
      # The suite logs at :warning; this synchronous test lowers it and
      # puts it back.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          Cyfr.LoggerContext.unexpected(__MODULE__, :sibling_broadcast, :debug)
        end)

      assert log =~ "[debug]"
      assert helper_line(log) =~ ":sibling_broadcast"
    end
  end
end
