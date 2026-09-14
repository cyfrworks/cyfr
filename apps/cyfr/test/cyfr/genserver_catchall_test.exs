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
    {Cyfr.Ops.Catalog, "Catalog"},
    {Emissary.MCP.ResourceRegistry, "ResourceRegistry"},
    {Arca.Cache.Sweeper, "Sweeper"},
    {Prism.TelemetryBridge, "TelemetryBridge"},
    {Arca.AuditHandler, "AuditHandler"},
    {Prism.TinctureRegistry, "TinctureRegistry"},
    {Cyfr.RecordSink, "RecordSink"},
    {Cyfr.RateLimiter, "RateLimiter"}
  ]

  # Named adopters not probed live, each with the reason it cannot be:
  # gated off (returns :ignore) or not started in the test environment.
  @not_probed %{
    Cyfr.RetentionScheduler => "gated by :retention_scheduler_enabled",
    Cyfr.Schedules.Scheduler => "gated by :cron_scheduler_enabled",
    Cyfr.ControlPlane => "gated by :control_plane_claim_enabled",
    Emissary.MCP.ExternalServerReconciler => "gated by :external_server_reconciler_enabled",
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
            # Give the GenServer time to process the message
            Process.sleep(50)
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
