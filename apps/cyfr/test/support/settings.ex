# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.Settings do
  @moduledoc """
  The suite's one way to set a platform setting: a row in the store, as an
  operator's write leaves it, read back through
  `Arca.PlatformSettings.effective/1` like every reader reads it.

  `install!/0` installs the roster's defaults with the suite's own values
  over them (`suite/0`): the test helper calls it once, after the boot
  installed the roster's. `put/2` validates the value with the roster's
  validator, stores it at the current store revision and drops the key's
  cached value; `reset/1` deletes the row and drops the cached value, so
  the key reads its installed default again.

  A row lives in the calling test's sandbox transaction and is gone when
  that test's connection is checked in, but the accessor's cache is one
  per node: `put/2` drops the key's cached value again when the test
  exits, and only a synchronous test, which runs alone, may call it. A
  caller that reaches no connection checks one out, owned by the test
  process.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias Arca.PlatformSettings, as: Store
  alias Cyfr.Platform.Settings.Roster

  # Controller suites drive hundreds of `/mcp` requests from one address
  # within one window, and a subscription stream would otherwise stay open
  # to the production bound: short enough that the graceful close is what
  # the assertions observe.
  @suite %{"mcp_rate_limit_max" => 1_000_000, "mcp_subscription_max_ms" => 50}

  @doc "The values the suite installs over the roster's defaults."
  @spec suite() :: %{String.t() => term()}
  def suite, do: @suite

  @doc "Install the roster's defaults with `suite/0` over them."
  @spec install!() :: :ok
  def install! do
    Roster.defaults()
    |> Map.new(fn {key, declared} ->
      case Map.fetch(@suite, key) do
        {:ok, value} -> {key, %{declared | default: value}}
        :error -> {key, declared}
      end
    end)
    |> Store.install_defaults!()
  end

  @doc """
  Store `value` under the rostered `key` for the rest of the calling test.
  A value the roster's validator refuses fails the test.
  """
  @spec put(String.t(), term()) :: :ok
  def put(key, value) when is_binary(key) do
    validated =
      case Roster.fetch(key) do
        {:ok, %{validator: validator}} ->
          case validator.(value) do
            {:ok, validated} -> validated
            {:error, form} -> flunk("#{key}=#{inspect(value)} #{form}")
          end

        :error ->
          flunk("#{inspect(key)} is not a rostered setting")
      end

    connect!()
    ExUnit.Callbacks.on_exit({__MODULE__, key}, fn -> Store.invalidate(key) end)

    {:ok, %{revision: revision}} = Store.all()
    {:ok, _next} = Store.put(key, validated, revision, "test")
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
    connect!()
    {:ok, %{revision: revision}} = Store.all()
    {:ok, _next} = Store.delete(key, revision)
    Store.invalidate(key)
  end

  # A process that reaches a connection already (its own, an allowance or
  # a shared owner's) writes through it, so every process the test shares
  # it with reads the row; only one with none checks one out.
  defp connect! do
    Arca.Repo.query!("SELECT 1")
    :ok
  rescue
    DBConnection.OwnershipError -> :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
  end
end
