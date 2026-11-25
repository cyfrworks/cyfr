# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.Sandbox do
  @moduledoc """
  The database sandbox for one test.

  `start_owner!/1` starts a sandbox owner of its own — not the test
  process — so work the test leaves behind still has a connection while it
  is stopped, and stops it before the owner goes. A sync test runs in
  shared mode and alone; an async test shares the pool with its
  neighbours, so its own process is allowed explicitly and nothing is
  swept for it.

  The owner's rollback is also the end of every platform setting the test
  wrote, and the settings cache (`Arca.PlatformSettings`) is one per node:
  a value read inside the test's transaction, by the test or by work still
  ending before the owner goes, stays cached for the cache's lifetime. So
  when the store's revision the transaction reads at its end is not the
  one the store holds once the owner is gone, every cached value is aged
  and the next read asks the store as it stands. Both are read at the end,
  so the transaction reads nothing it did not read before: on SQLite a
  transaction that has read answers busy where one that has not waits.

  This is the owner protocol and nothing else. `Cyfr.Test.Sandbox` builds
  on it: the umbrella's suite also has to lend the connection to the
  dynamic supervisors the apps above start, and to stop the work running
  on them before the owner goes, which is knowledge Arca does not have.
  """

  import Ecto.Query, only: [from: 2]

  @doc """
  Check a connection out for this test and register its release.

  `tags` is the test's own — `:async` decides whether the checkout is
  shared with every process or lent to this one. `:ownership_timeout`, when
  present, overrides the repo's timeout for this checkout alone.
  """
  @spec start_owner!(map()) :: pid()
  def start_owner!(tags \\ %{}) do
    shared? = not Map.get(tags, :async, false)
    if shared?, do: await_writers()

    opts =
      tags |> Map.take([:ownership_timeout]) |> Map.to_list() |> Keyword.put(:shared, shared?)

    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, opts)
    # Registered first of the test's, so it runs last: after the work the
    # test left has stopped, which may read a setting as it ends.
    ExUnit.Callbacks.on_exit(fn ->
      # Read through the owner by a process of its own, so this one, which
      # reads the store once the owner is gone, holds no allowance of it.
      read =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self())
          settings_revision()
        end)

      inside = Task.await(read, :infinity)

      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
      after_rollback = Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, &settings_revision/0)
      if inside != after_rollback, do: Arca.PlatformSettings.invalidate(:all)
    end)

    unless shared?, do: Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self())
    owner
  end

  # The settings store's revision, or :unread where it cannot be read (a
  # test that broke the store).
  defp settings_revision do
    key = Arca.PlatformSettings.revision_key()
    # arca:unscoped-ok the platform's settings are no athanor's: one store revision.
    Arca.Repo.one(from(r in "platform_settings", where: r.key == ^key, select: r.revision))
  rescue
    _unread -> :unread
  catch
    :exit, _unread -> :unread
  end

  # A sync test runs alone, but not on a quiet store: `stop_owner/1`
  # answers once the owner before it is gone, and the pool rolls that
  # owner's transaction back on its connection afterwards, as it does each
  # async test's when the async tests end. On SQLite a transaction that has
  # read does not wait for a write lock another connection holds; its
  # first write answers busy at once. So a sync test starts once no other
  # connection holds the write lock, taken and given back on a connection
  # outside the sandbox, which waits for it as any writer does.
  defp await_writers do
    if Arca.Repo.adapter() == Ecto.Adapters.SQLite3 do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fn ->
        {:ok, :ok} = Arca.Repo.locking_transaction(fn -> :ok end)
      end)
    end

    :ok
  end

  @doc "The owner, for a test that starts no work of its own."
  @spec setup!(map()) :: pid()
  def setup!(tags \\ %{}), do: start_owner!(tags)
end
