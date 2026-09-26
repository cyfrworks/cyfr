# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PlatformSettingsTest do
  @moduledoc """
  The platform settings store and its one accessor: uninstalled until the
  host installs its declaration, then the default, then the row; writes
  compare-and-set on the store revision; each member's pins retired by
  member and generation; and, when the cache has expired and the store
  cannot answer, a `:refuse` key refused and a `:serve` key served its
  last value with the catalogued event.

  The installation and the cache are process-wide terms, so this runs
  alone and puts back whatever installation it found. A store that cannot
  answer is made by renaming the table inside the test's own sandbox
  transaction, which the sandbox rolls back; on PostgreSQL the failed
  statement ends the transaction, so each case does it last.
  """

  use ExUnit.Case, async: false

  # The refused and stale reads log the database error they rode through.
  @moduletag :capture_log

  alias Arca.PlatformSettings

  @defaults %{
    "a_cap" => %{default: 50, stale: :refuse},
    "a_rate" => %{default: 120, stale: :serve},
    "a_label" => %{default: nil, stale: :serve},
    "a_level" => %{default: :info, stale: :serve}
  }

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    before = PlatformSettings.installed()

    on_exit(fn ->
      if before,
        do: PlatformSettings.install_defaults!(before),
        else: PlatformSettings.uninstall()
    end)

    PlatformSettings.install_defaults!(@defaults)
    :ok
  end

  defp revision do
    {:ok, %{revision: revision}} = PlatformSettings.all()
    revision
  end

  # The cached value of `key`, aged past the cache's lifetime, so the next
  # read must ask the store.
  defp expire(key) do
    {value, _read_at} = :persistent_term.get({PlatformSettings, :value, key})
    aged = System.monotonic_time(:millisecond) - PlatformSettings.ttl_ms() - 1
    :persistent_term.put({PlatformSettings, :value, key}, {value, aged})
  end

  defp break_store! do
    Arca.Repo.query!("ALTER TABLE platform_settings RENAME TO platform_settings_away")
  end

  describe "before the host installs the declaration" do
    test "every key is uninstalled, and nothing is read" do
      PlatformSettings.uninstall()

      assert PlatformSettings.installed() == nil
      assert PlatformSettings.effective("a_cap") == {:error, :uninstalled}
      assert PlatformSettings.effective("anything") == {:error, :uninstalled}
    end
  end

  describe "effective/1" do
    test "a key the declaration does not name is unknown" do
      assert PlatformSettings.effective("not_a_setting") == {:error, :unknown_key}
      assert PlatformSettings.effective(PlatformSettings.revision_key()) == {:error, :unknown_key}
    end

    test "a key with no row is its default, in the shape a stored value takes" do
      assert PlatformSettings.effective("a_cap") == {:ok, 50}
      assert PlatformSettings.effective("a_label") == {:ok, nil}
      # An atom default reads as its name, as it would once stored.
      assert PlatformSettings.effective("a_level") == {:ok, "info"}
    end

    test "a row is the value, and a reset reads the default again" do
      rev = revision()
      assert {:ok, next} = PlatformSettings.put("a_cap", 7, rev, "operator@example.com")
      assert next == rev + 1
      assert PlatformSettings.effective("a_cap") == {:ok, 7}

      assert {:ok, after_reset} = PlatformSettings.delete("a_cap", next)
      assert after_reset == next + 1
      assert PlatformSettings.effective("a_cap") == {:ok, 50}
    end

    test "a cached value is answered until it is invalidated or expires" do
      assert PlatformSettings.effective("a_rate") == {:ok, 120}

      # A write from another member reaches this one's cache only through
      # the invalidation or the cache's lifetime.
      {1, _} =
        Arca.Repo.insert_all(PlatformSettings.Row, [
          %{key: "a_rate", value: "240", revision: 99, set_at: DateTime.utc_now()}
        ])

      assert PlatformSettings.effective("a_rate") == {:ok, 120}
      assert :ok = PlatformSettings.invalidate("a_rate")
      assert PlatformSettings.effective("a_rate") == {:ok, 240}

      {1, _} = Arca.Repo.update_all(row("a_rate"), set: [value: "360"])
      assert PlatformSettings.effective("a_rate") == {:ok, 240}
      expire("a_rate")
      assert PlatformSettings.effective("a_rate") == {:ok, 360}

      {1, _} = Arca.Repo.update_all(row("a_rate"), set: [value: "480"])
      assert :ok = PlatformSettings.invalidate(:all)
      assert PlatformSettings.effective("a_rate") == {:ok, 480}
    end

    test "installing again drops every cached value" do
      assert PlatformSettings.effective("a_cap") == {:ok, 50}
      PlatformSettings.install_defaults!(%{@defaults | "a_cap" => %{default: 60, stale: :refuse}})
      assert PlatformSettings.effective("a_cap") == {:ok, 60}
    end

    test "an expired :refuse key whose store cannot answer is unavailable, never stale" do
      assert PlatformSettings.effective("a_cap") == {:ok, 50}
      expire("a_cap")
      break_store!()

      assert PlatformSettings.effective("a_cap") == {:error, :unavailable}
    end

    test "an expired :serve key whose store cannot answer serves its last value and says so" do
      ref = :telemetry_test.attach_event_handlers(self(), [PlatformSettings.stale_event()])
      on_exit(fn -> :telemetry.detach(ref) end)

      rev = revision()
      {:ok, _} = PlatformSettings.put("a_rate", 240, rev, nil)
      assert PlatformSettings.effective("a_rate") == {:ok, 240}
      expire("a_rate")
      break_store!()

      assert PlatformSettings.effective("a_rate") == {:ok, 240}
      assert_received {[:cyfr, :platform_settings, :stale_served], ^ref, %{count: 1}, %{key: "a_rate"}}

      # Never read before the store went, a :serve key serves its default.
      assert PlatformSettings.effective("a_label") == {:ok, nil}
      assert_received {[:cyfr, :platform_settings, :stale_served], ^ref, %{count: 1}, %{key: "a_label"}}
    end
  end

  describe "the store revision" do
    test "the baseline creates it at zero, and every write raises it by one" do
      rev = revision()
      assert rev >= 0

      assert {:ok, r1} = PlatformSettings.put("a_cap", 1, rev, nil)
      assert {:ok, r2} = PlatformSettings.put("a_rate", 2, r1, "someone")
      assert {:ok, r3} = PlatformSettings.delete("a_label", r2)
      assert [r1, r2, r3] == [rev + 1, rev + 2, rev + 3]

      assert {:ok, %{revision: ^r3, settings: settings}} = PlatformSettings.all()
      assert Enum.map(settings, & &1.key) == ["a_cap", "a_rate"]

      assert {:ok, %{value: 1, revision: ^r1, set_by: nil}} = PlatformSettings.get("a_cap")
      assert {:ok, %{value: 2, revision: ^r2, set_by: "someone"}} = PlatformSettings.get("a_rate")
      assert PlatformSettings.get("a_label") == {:error, :not_found}
    end

    test "a write that read an older revision changes nothing" do
      rev = revision()
      assert {:ok, next} = PlatformSettings.put("a_cap", 1, rev, nil)

      assert PlatformSettings.put("a_cap", 2, rev, nil) == {:error, :stale}
      assert PlatformSettings.delete("a_cap", rev) == {:error, :stale}
      assert revision() == next
      assert {:ok, %{value: 1}} = PlatformSettings.get("a_cap")
    end

    test "a deleted key set again cannot make an old revision current" do
      rev = revision()
      {:ok, r1} = PlatformSettings.put("a_cap", 1, rev, nil)
      {:ok, r2} = PlatformSettings.delete("a_cap", r1)
      {:ok, r3} = PlatformSettings.put("a_cap", 3, r2, nil)

      assert {:ok, %{revision: ^r3}} = PlatformSettings.get("a_cap")
      assert PlatformSettings.put("a_cap", 9, r1, nil) == {:error, :stale}
    end

    test "the reserved row is no setting's, and a value JSON cannot hold is refused" do
      key = PlatformSettings.revision_key()
      rev = revision()

      assert PlatformSettings.get(key) == {:error, :reserved}
      assert PlatformSettings.put(key, 1, rev, nil) == {:error, :reserved}
      assert PlatformSettings.delete(key, rev) == {:error, :reserved}
      assert PlatformSettings.put("a_cap", {:not, :json}, rev, nil) == {:error, :unencodable}
      assert revision() == rev
    end

    test "the store cannot answer: a database error, not a stale write" do
      rev = revision()
      break_store!()
      assert PlatformSettings.put("a_cap", 1, rev, nil) == {:error, :database_error}
    end
  end

  describe "the pins" do
    test "recorded per key and member, replaced by the member's later record" do
      member = "cyfr@pin-#{System.unique_integer([:positive])}"

      assert :ok = PlatformSettings.record_pin("a_cap", member, 3, 10)
      assert :ok = PlatformSettings.record_pin("a_rate", member, 3, 240)
      assert :ok = PlatformSettings.record_pin("a_cap", member, 4, 11)

      assert {:ok, pins} = PlatformSettings.pins()

      assert Enum.filter(pins, &(&1.member == member)) == [
               %{key: "a_cap", member: member, generation: 4, value: 11},
               %{key: "a_rate", member: member, generation: 3, value: 240}
             ]
    end

    test "retired by member and generation: this member's older pins go, nothing else" do
      member = "cyfr@a-#{System.unique_integer([:positive])}"
      other = "cyfr@b-#{System.unique_integer([:positive])}"

      :ok = PlatformSettings.record_pin("a_cap", member, 2, 10)
      :ok = PlatformSettings.record_pin("a_rate", member, 5, 240)
      :ok = PlatformSettings.record_pin("a_cap", other, 2, 10)

      assert PlatformSettings.retire_pins(member, 2) == {:ok, 1}

      {:ok, pins} = PlatformSettings.pins()
      mine = for pin <- pins, pin.member in [member, other], do: {pin.key, pin.member}
      assert Enum.sort(mine) == Enum.sort([{"a_rate", member}, {"a_cap", other}])

      assert PlatformSettings.retire_pins(member, 5) == {:ok, 1}
      assert PlatformSettings.retire_pins(member, 5) == {:ok, 0}
    end
  end

  describe "install_defaults!/1" do
    test "refuses a declaration that is not a default and a stale policy per key" do
      for bad <- [
            %{"k" => %{default: 1}},
            %{"k" => %{default: 1, stale: :maybe}},
            %{k: %{default: 1, stale: :serve}},
            %{PlatformSettings.revision_key() => %{default: 1, stale: :serve}}
          ] do
        assert_raise ArgumentError, fn -> PlatformSettings.install_defaults!(bad) end
      end

      assert_raise Protocol.UndefinedError, fn ->
        PlatformSettings.install_defaults!(%{"k" => %{default: {:a, :tuple}, stale: :serve}})
      end
    end
  end

  describe "the tables" do
    test "both are the fingerprinted baseline's and no athanor's" do
      [baseline] =
        Path.wildcard(Path.expand("../../priv/repo/migrations/*_baseline.exs", __DIR__))

      source = File.read!(baseline)

      for table <- ~w(platform_settings settings_pins) do
        assert source =~ "create table(:#{table}"
        assert table in Arca.TenantTables.not_athanor_scoped()
        refute table in Arca.TenantTables.roster()
      end

      assert :ok = Arca.SchemaFingerprint.verify()
    end
  end

  defp row(key) do
    import Ecto.Query
    from(r in "platform_settings", where: r.key == ^key)
  end
end
