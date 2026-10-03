# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.PlatformSettingsTest do
  @moduledoc """
  The platform settings as the host runs them (`Cyfr.Platform.Settings`):
  the boot's apply, the compare-and-set writes and their refusals, the
  listing, the pins a claim records and retires, and the settings process
  that applies the log level in store-revision order.

  The log level, the execution-slot caps, the pins and the claim switch
  are process-wide, so this file runs alone and puts each back.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.PlatformSettings, as: Store
  alias Cyfr.Bus.SettingsChanged
  alias Cyfr.Platform.Settings

  @terms [
    {Settings, :active},
    {Settings, :boot_revision},
    {Settings, :level_from_row}
  ]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    level = Logger.level()
    pinned = Application.get_env(:cyfr, :deployment_pinned)
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    slots = Application.get_env(:cyfr, :crucible_max_concurrent)
    terms = for key <- @terms, do: {key, :persistent_term.get(key, :absent)}

    on_exit(fn ->
      Logger.configure(level: level)
      restore(:cyfr, :deployment_pinned, pinned)
      restore(:arca, :control_plane_claim_enabled, claim)
      restore(:cyfr, :crucible_max_concurrent, slots)
      for {key, value} <- terms, do: restore(key, value)
      Store.invalidate(:all)
    end)

    Application.put_env(:cyfr, :deployment_pinned, [])
    Store.invalidate(:all)

    ctx =
      Sanctum.Context.build(
        user_id: "ops-#{System.unique_integer([:positive])}",
        provider: "github",
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true,
        platform_admin: true
      )

    {:ok, ctx: ctx}
  end

  defp restore(key, :absent), do: :persistent_term.erase(key)
  defp restore(key, value), do: :persistent_term.put(key, value)
  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp revision do
    {:ok, %{revision: revision}} = Store.all()
    revision
  end

  defp listed(key) do
    {:ok, %{settings: settings}} = Settings.list()
    Enum.find(settings, &(&1.key == key))
  end

  # A row changed behind the accessor's back, as a peer's write is: the
  # cache here is not told.
  defp write_behind(key, value) do
    from(r in "platform_settings", where: r.key == ^key)
    |> Arca.Repo.update_all(set: [value: Jason.encode!(value)])
  end

  # The settings changes announced so far, in order, as `{setting, op}`.
  defp announced do
    receive do
      %SettingsChanged{kind: :changed, setting: setting, op: op} -> [{setting, op} | announced()]
    after
      0 -> []
    end
  end

  defp start_process(opts) do
    name = :"settings_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Settings, Keyword.merge([name: name, member: "m@test", poll_ms: 3_600_000], opts)}
      )

    {pid, name}
  end

  defp lease!(node, generation) do
    now = DateTime.utc_now()

    Arca.Repo.insert_all(Arca.Schemas.CellLease, [
      %{
        node: node,
        owner: "boot-" <> node,
        generation: generation,
        fence: 1,
        lease_until: DateTime.add(now, 60, :second),
        taken_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  describe "set and reset" do
    test "set validates through the roster, records who, and raises the revision", %{ctx: ctx} do
      before = revision()

      assert {:ok, %{key: "mcp_rate_limit_max", value: 240, revision: next, pending: false}} =
               Settings.set(ctx, "mcp_rate_limit_max", "240")

      assert next == before + 1

      assert {:ok, %{value: 240, set_by: set_by, revision: ^next}} =
               Store.get("mcp_rate_limit_max")

      assert set_by == ctx.user_id
      assert Store.effective("mcp_rate_limit_max") == {:ok, 240}
    end

    test "a value under a limit's floor is refused naming its range, and nothing is written",
         %{ctx: ctx} do
      before = revision()

      assert Settings.set(ctx, "crucible_max_concurrent", "31") ==
               {:error,
                {:invalid, "crucible_max_concurrent",
                 "must be a whole number of executions from 32 to 1000000"}}

      assert {:error, {:invalid, "mcp_rate_limit_max", _form}} =
               Settings.set(ctx, "mcp_rate_limit_max", "0")

      assert Store.get("crucible_max_concurrent") == {:error, :not_found}
      assert revision() == before
    end

    test "the recovery reserve stays below the log quota, read as each takes effect now",
         %{ctx: ctx} do
      before = revision()

      # Against the default quota.
      assert Settings.set(ctx, "directory_recovery_reserve_bytes", "1073741824") ==
               {:error,
                {:invalid, "directory_recovery_reserve_bytes",
                 "must be below directory_log_bytes (1073741824)"}}

      assert revision() == before

      # Against a stored reserve: the quota cannot fall to it or under it.
      assert {:ok, %{value: 1_048_576}} =
               Settings.set(ctx, "directory_recovery_reserve_bytes", "1048576")

      assert Settings.set(ctx, "directory_log_bytes", "1048576") ==
               {:error,
                {:invalid, "directory_log_bytes",
                 "must be above directory_recovery_reserve_bytes (1048576)"}}

      assert {:ok, %{value: 1_048_577}} = Settings.set(ctx, "directory_log_bytes", "1048577")

      # Resetting the reserve to its default would put it above the quota.
      assert Settings.reset(ctx, "directory_recovery_reserve_bytes") ==
               {:error,
                {:invalid, "directory_recovery_reserve_bytes",
                 "must be below directory_log_bytes (1048577)"}}

      assert Store.effective("directory_recovery_reserve_bytes") == {:ok, 1_048_576}

      # The quota back at its default, the reserve resets.
      assert {:ok, _} = Settings.reset(ctx, "directory_log_bytes")
      assert {:ok, %{value: 10_485_760}} = Settings.reset(ctx, "directory_recovery_reserve_bytes")
    end

    test "the bound reads the store the write is conditioned on, never this member's cache",
         %{ctx: ctx} do
      # This member caches the default quota.
      assert Store.effective("directory_log_bytes") == {:ok, 1_073_741_824}

      # A peer lowers the quota and raises the store revision; nothing here
      # hears of it, and the cache still answers the default.
      next = revision() + 1

      Arca.Repo.insert_all(Arca.PlatformSettings.Row, [
        %{
          key: "directory_log_bytes",
          value: Jason.encode!(536_870_912),
          revision: next,
          set_by: "peer",
          set_at: DateTime.utc_now()
        }
      ])

      from(r in "platform_settings", where: r.key == "$revision")
      |> Arca.Repo.update_all(set: [revision: next])

      assert Store.effective("directory_log_bytes") == {:ok, 1_073_741_824}

      assert Settings.set(ctx, "directory_recovery_reserve_bytes", "900000000") ==
               {:error,
                {:invalid, "directory_recovery_reserve_bytes",
                 "must be below directory_log_bytes (536870912)"}}

      assert Store.get("directory_recovery_reserve_bytes") == {:error, :not_found}
      assert revision() == next
    end

    test "a key the roster does not declare is refused", %{ctx: ctx} do
      assert Settings.set(ctx, "no_such_setting", "1") == {:error, :unknown_key}
      assert Settings.reset(ctx, "no_such_setting") == {:error, :unknown_key}
    end

    test "a key the environment pins is refused for set and reset", %{ctx: ctx} do
      Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 5}])

      assert Settings.set(ctx, "max_athanors", "9") == {:error, :pinned}
      assert Settings.reset(ctx, "max_athanors") == {:error, :pinned}
      assert Store.get("max_athanors") == {:error, :not_found}
    end

    test "two writers against one revision: the second is refused stale", %{ctx: ctx} do
      read = revision()

      assert {:ok, _} = Settings.set(ctx, "device_label", "first", revision: read)

      assert Settings.set(ctx, "device_label", "second", revision: read) ==
               {:error, :stale}

      assert {:ok, %{value: "first"}} = Store.get("device_label")
    end

    test "a set carrying the revision read before a reset is refused stale", %{ctx: ctx} do
      assert {:ok, %{revision: set_at}} = Settings.set(ctx, "session_ttl_hours", "24")

      assert {:ok, %{revision: reset_at}} =
               Settings.reset(ctx, "session_ttl_hours", revision: set_at)

      assert reset_at == set_at + 1

      assert Settings.set(ctx, "session_ttl_hours", "48", revision: set_at) == {:error, :stale}
      assert Store.get("session_ttl_hours") == {:error, :not_found}
      assert Store.effective("session_ttl_hours") == {:ok, 720}
    end

    test "a reset of an inheriting key deletes its row rather than writing what it inherits",
         %{ctx: ctx} do
      assert {:ok, _} = Settings.set(ctx, "mcp_rate_limit_max", "300")
      assert {:ok, _} = Settings.set(ctx, "api_rate_limit_max", "500")
      before = revision()

      assert {:ok, %{value: nil, revision: next}} = Settings.reset(ctx, "api_rate_limit_max")
      assert next == before + 1
      assert Store.get("api_rate_limit_max") == {:error, :not_found}
      assert Store.effective("api_rate_limit_max") == {:ok, nil}

      # A reset of a key with no row still raises the revision.
      assert {:ok, %{revision: again}} = Settings.reset(ctx, "api_rate_limit_max")
      assert again == next + 1
    end

    test "a cap set refuses the next creation over it, with no restart", %{ctx: ctx} do
      {:ok, count} = Sanctum.Tenancy.Athanors.count()
      mint = fn -> Sanctum.Tenancy.Athanors.create_group(ctx.user_id, "Capped") end

      assert {:ok, %{pending: false}} = Settings.set(ctx, "max_athanors", count + 1)
      assert {:ok, _} = mint.()

      assert {:error, {:limit_reached, :max_athanors, cap}} = mint.()
      assert cap == count + 1

      # Reset reads the default again, which is no cap.
      assert {:ok, _} = Settings.reset(ctx, "max_athanors")
      assert {:ok, _} = mint.()
    end

    test "a restart-scoped set is answered pending and applies nothing now", %{ctx: ctx} do
      running = Application.get_env(:cyfr, :crucible_max_concurrent)

      assert {:ok, %{pending: true, value: 64}} =
               Settings.set(ctx, "crucible_max_concurrent", "64")

      assert Application.get_env(:cyfr, :crucible_max_concurrent) == running
      assert %{pending: true, desired: 64, source: "operator"} = listed("crucible_max_concurrent")
    end

    test "a store that cannot write refuses the set and leaves the running value", %{ctx: ctx} do
      assert {:ok, %{revision: at}} = Settings.set(ctx, "health_ready_cache_ms", "1000")
      assert Store.effective("health_ready_cache_ms") == {:ok, 1000}

      Arca.Repo.query!("DROP TABLE platform_settings")

      ExUnit.CaptureLog.capture_log(fn ->
        assert Settings.set(ctx, "health_ready_cache_ms", "2000", revision: at) ==
                 {:error, :unavailable}

        assert Settings.set(ctx, "health_ready_cache_ms", "2000") == {:error, :unavailable}
      end)

      assert Store.effective("health_ready_cache_ms") == {:ok, 1000}
    end
  end

  describe "list" do
    test "each setting's source, the desired revision and this member", %{ctx: ctx} do
      Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 5}])
      assert {:ok, _} = Settings.set(ctx, "mcp_rate_limit_max", "240")

      assert {:ok, listing} = Settings.list()
      assert listing.revision == revision()
      assert listing.ttl_ms == Store.ttl_ms()
      assert length(listing.settings) == length(Cyfr.Platform.Settings.Roster.entries())

      me = Atom.to_string(node())
      assert [%{member: ^me, revision: observed}] = listing.members
      assert is_integer(observed)

      by_key = Map.new(listing.settings, &{&1.key, &1})

      assert %{source: "deployment", value: 5, desired: 5, pins: [%{member: ^me, value: 5}]} =
               by_key["max_athanors"]

      assert %{source: "operator", value: 240, set_by: set_by, revision: at} =
               by_key["mcp_rate_limit_max"]

      assert set_by == ctx.user_id and at == listing.revision

      assert %{source: "default", value: 50, default: 50, pending: false, divergent: false} =
               by_key["max_groups_per_person"]

      assert %{value: level} = by_key["log_level"]
      assert level == Atom.to_string(Logger.level())
    end

    test "a store that cannot answer is unavailable" do
      Arca.Repo.query!("DROP TABLE platform_settings")

      ExUnit.CaptureLog.capture_log(fn ->
        assert Settings.list() == {:error, :unavailable}
      end)
    end
  end

  describe "the boot's apply" do
    test "applies restart rows and the log level, keeps a pin, refuses an invalid row" do
      at = revision()
      {:ok, at} = Store.put("crucible_max_concurrent", 64, at, "ops")
      {:ok, at} = Store.put("crucible_max_concurrent_per_tenant", 0, at, "ops")
      {:ok, _at} = Store.put("log_level", "error", at, "ops")
      Application.put_env(:cyfr, :deployment_pinned, [{"crucible_max_concurrent_per_tenant", 3}])

      assert Settings.apply() == :ok

      assert Application.get_env(:cyfr, :crucible_max_concurrent) == 64
      assert Logger.level() == :error
      assert %{value: 64, pending: false} = listed("crucible_max_concurrent")

      assert %{value: 3, desired: 3, source: "deployment"} =
               listed("crucible_max_concurrent_per_tenant")

      # A row the validator refuses is logged and the configured value kept.
      Application.put_env(:cyfr, :deployment_pinned, [])
      {:ok, _} = Store.put("crucible_max_concurrent", 5, revision(), "ops")

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          assert Settings.apply() == :ok
        end)

      assert log =~ "crucible_max_concurrent must be a whole number"
      assert Application.get_env(:cyfr, :crucible_max_concurrent) == 64
      assert %{value: 64, desired: 5, pending: true} = listed("crucible_max_concurrent")
    end

    test "an unreadable store refuses the boot" do
      Arca.Repo.query!("DROP TABLE platform_settings")

      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise RuntimeError, ~r/platform settings could not be read/, &Settings.apply/0
      end)
    end
  end

  describe "the settings process" do
    test "applies the log level in store-revision order, never an older over a newer" do
      {pid, name} = start_process(claimed: false)
      base = revision() + 100

      send(
        pid,
        SettingsChanged.new(:changed,
          setting: "log_level",
          revision: base + 2,
          op: :put,
          value: "error"
        )
      )

      _ = :sys.get_state(pid)
      assert Logger.level() == :error

      # Late, and older than what it runs at: dropped.
      send(
        pid,
        SettingsChanged.new(:changed,
          setting: "log_level",
          revision: base + 1,
          op: :put,
          value: "debug"
        )
      )

      _ = :sys.get_state(pid)
      assert Logger.level() == :error

      # Another key's newer change moves the observed revision, not the level.
      send(
        pid,
        SettingsChanged.new(:changed,
          setting: "device_label",
          revision: base + 3,
          op: :put,
          value: "x"
        )
      )

      assert GenServer.call(name, :observed)["m@test"] == base + 3
      assert Logger.level() == :error

      send(
        pid,
        SettingsChanged.new(:changed, setting: "log_level", revision: base + 4, op: :delete)
      )

      _ = :sys.get_state(pid)
      # A reset applies the default effective/1 answers, not the level this
      # member booted with (the suite boots at :warning).
      assert Logger.level() == :info
    end

    test "a change it hears drops the cached value, whatever its revision" do
      {:ok, _} = Store.put("opus_watch_misses", 4, revision(), "ops")
      assert Store.effective("opus_watch_misses") == {:ok, 4}

      write_behind("opus_watch_misses", 7)
      assert Store.effective("opus_watch_misses") == {:ok, 4}

      {pid, _name} = start_process(claimed: false)

      send(
        pid,
        SettingsChanged.new(:changed,
          setting: "opus_watch_misses",
          revision: 1,
          op: :put,
          value: 7
        )
      )

      _ = :sys.get_state(pid)

      assert Store.effective("opus_watch_misses") == {:ok, 7}
    end

    test "each member's observed revision is kept, the highest heard" do
      {pid, name} = start_process(claimed: false)

      send(pid, SettingsChanged.new(:observed, member: "peer@test", revision: 9))
      send(pid, SettingsChanged.new(:observed, member: "peer@test", revision: 8))
      observed = GenServer.call(name, :observed)

      assert observed["peer@test"] == 9
      assert Map.has_key?(observed, "m@test")
    end

    test "a member that missed the message converges on its poll" do
      {pid, _name} = start_process(claimed: true)

      {:ok, at} = Store.put("log_level", "error", revision(), "ops")
      send(pid, :poll)
      _ = :sys.get_state(pid)
      assert Logger.level() == :error

      {:ok, _at} = Store.delete("log_level", at)
      send(pid, :poll)
      _ = :sys.get_state(pid)
      # A reset applies the default effective/1 answers, not the level this
      # member booted with (the suite boots at :warning).
      assert Logger.level() == :info
    end

    test "writes this member's pinned values as the deployment's rows, and clears one no pin holds" do
      Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 7}])
      {_pid, _name} = start_process(claimed: true)

      assert {:ok, %{value: 7, set_by: "deployment"}} = Store.get("max_athanors")
      assert Store.effective("max_athanors") == {:ok, 7}

      Application.put_env(:cyfr, :deployment_pinned, [])
      stop_supervised!(Settings)
      {_pid, _name} = start_process(claimed: true)

      assert Store.get("max_athanors") == {:error, :not_found}
    end

    test "a pin that breaks a bound against the stored values refuses the boot, naming its variable",
         %{ctx: ctx} do
      assert {:ok, _} = Settings.set(ctx, "directory_recovery_reserve_bytes", "900000000")
      Application.put_env(:cyfr, :deployment_pinned, [{"directory_log_bytes", 536_870_912}])

      # The boot's start, linked as a supervisor's child is: its refusal is
      # the start's answer, and the exit it sends is trapped here.
      opts = [name: :"settings_#{System.unique_integer([:positive])}", member: "m@test"]
      trapping = Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Settings.start_link(opts ++ [poll_ms: 3_600_000, claimed: true])
        end)

      Process.flag(:trap_exit, trapping)

      assert {:error, {%RuntimeError{message: message}, _stacktrace}} = result

      assert message ==
               "[Cyfr] FATAL: CYFR_DIRECTORY_LOG_BYTES must be above " <>
                 "directory_recovery_reserve_bytes (900000000)."

      # Nothing was written: the quota still reads its default.
      assert Store.get("directory_log_bytes") == {:error, :not_found}

      # A reserve under the pinned quota boots, and the pin is written.
      assert {:ok, _} = Settings.set(ctx, "directory_recovery_reserve_bytes", "1048576")
      {_pid, _name} = start_process(claimed: true)
      assert {:ok, %{value: 536_870_912, set_by: "deployment"}} = Store.get("directory_log_bytes")
    end

    test "removing a deployment row that would leave a stored value beyond a bound refuses the boot, naming both settings",
         %{ctx: ctx} do
      Application.put_env(:cyfr, :deployment_pinned, [{"directory_log_bytes", 4_294_967_296}])
      {_pid, _name} = start_process(claimed: true)
      assert {:ok, _} = Settings.set(ctx, "directory_recovery_reserve_bytes", "2147483648")
      stop_supervised!(Settings)

      # The quota's pin is gone: its row's removal would expose the
      # default quota under the stored reserve.
      Application.put_env(:cyfr, :deployment_pinned, [])
      opts = [name: :"settings_#{System.unique_integer([:positive])}", member: "m@test"]
      trapping = Process.flag(:trap_exit, true)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          Settings.start_link(opts ++ [poll_ms: 3_600_000, claimed: true])
        end)

      Process.flag(:trap_exit, trapping)

      assert {:error, {%RuntimeError{message: message}, _stacktrace}} = result

      assert message ==
               "[Cyfr] FATAL: directory_recovery_reserve_bytes (2147483648) must be below " <>
                 "directory_log_bytes (1073741824); pin CYFR_DIRECTORY_RECOVERY_RESERVE_BYTES " <>
                 "or CYFR_DIRECTORY_LOG_BYTES to restore the bound."

      # Nothing was removed: the deployment's quota still stands.
      assert {:ok, %{value: 4_294_967_296, set_by: "deployment"}} =
               Store.get("directory_log_bytes")

      # Pinning the reserve under the default quota restores the bound:
      # the boot writes the reserve's pin and removes the quota's row.
      Application.put_env(:cyfr, :deployment_pinned, [
        {"directory_recovery_reserve_bytes", 1_048_576}
      ])

      {_pid, _name} = start_process(claimed: true)

      assert {:ok, %{value: 1_048_576, set_by: "deployment"}} =
               Store.get("directory_recovery_reserve_bytes")

      assert Store.get("directory_log_bytes") == {:error, :not_found}
    end

    test "each settlement write leaves the bounds held, whatever way the pins move" do
      reserve = "directory_recovery_reserve_bytes"
      quota = "directory_log_bytes"
      :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.settings_changed())

      # {the earlier boot's pins, the next boot's, the order its writes take}
      cases = [
        # The quota lowered under the reserve's row, whose pin is gone.
        {[{quota, 3_221_225_472}, {reserve, 2_147_483_648}], [{quota, 1_610_612_736}],
         [{reserve, :delete}, {quota, :put}]},
        # Both pins gone: the quota's default is under the reserve's row.
        {[{quota, 3_221_225_472}, {reserve, 2_147_483_648}], [],
         [{reserve, :delete}, {quota, :delete}]},
        # Both lowered, the new quota under the old reserve.
        {[{quota, 104_857_600}, {reserve, 52_428_800}],
         [{quota, 41_943_040}, {reserve, 20_971_520}], [{reserve, :put}, {quota, :put}]},
        # Both raised, the new reserve over the old quota.
        {[{quota, 41_943_040}, {reserve, 20_971_520}],
         [{quota, 104_857_600}, {reserve, 52_428_800}], [{quota, :put}, {reserve, :put}]}
      ]

      for {earlier, next, order} <- cases do
        Application.put_env(:cyfr, :deployment_pinned, earlier)
        {_pid, _name} = start_process(claimed: true)
        stop_supervised!(Settings)
        _earlier = announced()

        Application.put_env(:cyfr, :deployment_pinned, next)
        {_pid, _name} = start_process(claimed: true)
        stop_supervised!(Settings)

        # Each write is announced as it commits, so the order is what every
        # member could read in between.
        assert announced() == order, "from #{inspect(earlier)} to #{inspect(next)}"
      end
    end
  end

  describe "pins" do
    test "a conflict is another live member's different value for a key this one pins" do
      live = [
        %{key: "log_level", member: "b@h", generation: 2, value: "debug"},
        %{key: "max_athanors", member: "b@h", generation: 2, value: 5},
        %{key: "log_level", member: "a@h", generation: 1, value: "info"}
      ]

      mine = [{"log_level", "error"}, {"max_athanors", 5}]

      assert Settings.conflicts(mine, "a@h", live) == [{"log_level", "error", "b@h", "debug"}]
      assert Settings.conflicts([{"log_level", "debug"}], "a@h", live) == []
    end

    test "a pin is live only under the generation its member's slot holds now" do
      pins = [
        %{key: "k", member: "a@h", generation: 3, value: 1},
        %{key: "k", member: "b@h", generation: 1, value: 1},
        %{key: "k", member: "c@h", generation: 1, value: 1}
      ]

      members = [%{node: "a@h", generation: 3}, %{node: "b@h", generation: 2}]
      assert Settings.live(pins, members) == [hd(pins)]
    end

    test "the claim retires its slot's earlier pins and a dead member's, and records its own" do
      me = "me-#{System.unique_integer([:positive])}@h"
      peer = "peer-#{System.unique_integer([:positive])}@h"
      dead = "dead-#{System.unique_integer([:positive])}@h"
      lease!(peer, 4)

      :ok = Store.record_pin("log_level", me, 1, "debug")
      :ok = Store.record_pin("log_level", peer, 4, "debug")
      :ok = Store.record_pin("log_level", dead, 2, "debug")
      Application.put_env(:cyfr, :deployment_pinned, [{"max_athanors", 5}])

      assert Settings.claimed(%{node: me, generation: 2}) == :ok

      {:ok, pins} = Store.pins()

      held =
        for pin <- pins, pin.member in [me, peer, dead], do: {pin.member, pin.key, pin.generation}

      assert Enum.sort(held) == Enum.sort([{me, "max_athanors", 2}, {peer, "log_level", 4}])
    end

    test "a live member's different pin refuses the boot naming both; agreement boots" do
      Application.put_env(:arca, :control_plane_claim_enabled, true)
      peer = "peer-#{System.unique_integer([:positive])}@h"
      lease!(peer, 1)
      :ok = Store.record_pin("log_level", peer, 1, "debug")

      Application.put_env(:cyfr, :deployment_pinned, [{"log_level", :error}])

      error = assert_raise RuntimeError, &Settings.check_pins!/0
      assert error.message =~ "CYFR_LOG_LEVEL pins log_level"
      assert error.message =~ peer
      assert error.message =~ Atom.to_string(node())

      Application.put_env(:cyfr, :deployment_pinned, [{"log_level", :debug}])
      assert Settings.check_pins!() == :ok

      # A pin on a peer and none here is a divergence, not a refusal.
      Application.put_env(:cyfr, :deployment_pinned, [])
      assert Settings.check_pins!() == :ok
    end
  end
end
