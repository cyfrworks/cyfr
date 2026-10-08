# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.Settings do
  @moduledoc """
  The platform settings Sanctum reads, for a suite with no host to install
  them.

  The host declares every setting and installs the declaration at its
  boot. This suite boots Arca and Sanctum alone, so `install!/0` installs
  the declaration of the settings Sanctum reads (`defaults/0`, held equal
  to the host's roster by `Cyfr.PlatformSettingsRosterTest`) when nothing
  is installed, and records what the boot installed (`boot_installation/0`,
  `nil` without a host). Where a host booted, its declaration stands.

  `put/2` stores a value at the current store revision and drops the key's
  cached value; `reset/1` deletes the row. A row lives in the calling
  test's sandbox transaction, but the accessor's cache is one per node:
  `put/2` drops the key's cached value again when the test exits, and only
  a synchronous test, which runs alone, may call it.
  """

  alias Arca.PlatformSettings, as: Store

  @boot {__MODULE__, :boot_installation}

  @defaults %{
    "max_athanors" => %{default: nil, stale: :refuse},
    "max_groups_per_person" => %{default: 50, stale: :refuse},
    "max_pairs_per_person" => %{default: 200, stale: :refuse},
    "max_members_per_group" => %{default: nil, stale: :refuse},
    "max_threads_per_athanor" => %{default: 1000, stale: :refuse},
    "mint_per_hour" => %{default: nil, stale: :refuse},
    "athanor_storage_bytes" => %{default: nil, stale: :refuse},
    "session_ttl_hours" => %{default: 720, stale: :refuse},
    "webhook_max_skew_seconds" => %{default: 300, stale: :refuse},
    "directory_serve" => %{default: :off, stale: :refuse},
    "directory_max_identities" => %{default: 100_000, stale: :refuse},
    "directory_log_bytes" => %{default: 1_073_741_824, stale: :refuse},
    "directory_recovery_reserve_bytes" => %{default: 10_485_760, stale: :refuse},
    "identity_freshness_seconds" => %{default: 300, stale: :refuse},
    "device_cert_seconds" => %{default: 3_600, stale: :refuse},
    "clock_skew_seconds" => %{default: 60, stale: :refuse},
    "confirmation_seconds" => %{default: 300, stale: :refuse},
    "reauth_seconds" => %{default: 300, stale: :refuse},
    "instance_entry_person_daily" => %{default: 1_000, stale: :refuse},
    "instance_entry_total_daily" => %{default: 2_000, stale: :refuse}
  }

  @doc "The declaration of the settings Sanctum reads."
  @spec defaults() :: Store.installed()
  def defaults, do: @defaults

  @doc "Install `defaults/0` unless a boot installed a declaration."
  @spec install!() :: :ok
  def install! do
    installed = Store.installed()
    :persistent_term.put(@boot, installed)
    if installed == nil, do: Store.install_defaults!(@defaults), else: :ok
  end

  @doc "The declaration the boot installed before `install!/0`, `nil` for none."
  @spec boot_installation() :: Store.installed() | nil
  def boot_installation, do: :persistent_term.get(@boot, nil)

  @doc "Store `value` under `key` for the rest of the calling test."
  @spec put(String.t(), term()) :: :ok
  def put(key, value) when is_binary(key) do
    ExUnit.Callbacks.on_exit({__MODULE__, key}, fn -> Store.invalidate(key) end)
    {:ok, %{revision: revision}} = Store.all()
    {:ok, _next} = Store.put(key, value, revision, "test")
    Store.invalidate(key)
  end

  @doc """
  Read `key` once and age its cached value past the cache's lifetime, so
  the next read asks the store again.
  """
  @spec expire(String.t()) :: :ok
  def expire(key) when is_binary(key) do
    {:ok, _value} = Store.effective(key)
    cache = {Store, :value, key}
    {value, _read_at} = :persistent_term.get(cache)
    :persistent_term.put(cache, {value, System.monotonic_time(:millisecond) - Store.ttl_ms() - 1})
  end

  @doc """
  Make the store unable to answer for the rest of the calling test, by
  renaming its table inside the test's own sandbox transaction, which the
  sandbox rolls back. On PostgreSQL the next failed statement ends the
  transaction, so a test does this last among its database steps.
  """
  @spec break_store!() :: :ok
  def break_store! do
    ExUnit.Callbacks.on_exit({__MODULE__, :break_store}, fn -> Store.invalidate(:all) end)
    Arca.Repo.query!("ALTER TABLE platform_settings RENAME TO platform_settings_away")
    :ok
  end

  @doc "Delete `key`'s row, so it reads its installed default again."
  @spec reset(String.t()) :: :ok
  def reset(key) when is_binary(key) do
    {:ok, %{revision: revision}} = Store.all()
    {:ok, _next} = Store.delete(key, revision)
    Store.invalidate(key)
  end
end
