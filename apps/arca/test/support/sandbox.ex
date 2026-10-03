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

  This is the owner protocol and nothing else. `Cyfr.Test.Sandbox` builds
  on it: the umbrella's suite also has to lend the connection to the
  dynamic supervisors the apps above start, and to stop the work running
  on them before the owner goes, which is knowledge Arca does not have.
  """

  @doc """
  Check a connection out for this test and register its release.

  `tags` is the test's own — `:async` decides whether the checkout is
  shared with every process or lent to this one.
  """
  @spec start_owner!(map()) :: pid()
  def start_owner!(tags \\ %{}) do
    shared? = not Map.get(tags, :async, false)
    if shared?, do: await_writers()
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, shared: shared?)
    ExUnit.Callbacks.on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    unless shared?, do: Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, self())
    owner
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
