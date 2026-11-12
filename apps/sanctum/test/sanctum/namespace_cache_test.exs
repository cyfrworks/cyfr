# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.NamespaceCacheTest do
  @moduledoc """
  The namespace read at its shipped bound (`Sanctum.Namespace`): every
  suite configuration turns the cache off, so here the setting is absent
  and the code's own minute applies. A read within the minute is served
  from the cache, the write that records a claim drops it, and a read
  after the minute asks the users row again. At the suites' 0 the entry
  is expired on arrival, so every read asks the row.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Namespace
  alias Sanctum.Tenancy.Users

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Cache.init()
    Prima.Test.Env.delete_app_env(:sanctum, :namespace_cache_ttl_ms)
    :ok
  end

  defp person do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|ns-cache-#{n}",
        provider: "github",
        email: "ns-cache#{n}@example.com",
        verified: true
      })

    user
  end

  # A change to the row that `Users.set_namespace/2`'s invalidation never
  # sees, so what a read answers next tells the cache from the row.
  defp write_below!(user_id, slug) do
    {:ok, _} =
      Arca.Schemas.User
      |> Arca.Repo.get!(user_id)
      |> Ecto.Changeset.change(namespace: slug)
      |> Arca.Repo.update()
  end

  defp entry(user_id), do: :ets.lookup(Arca.Cache.table_name(), {:namespace_slug, user_id})

  test "a read within the shipped minute is the cache's, and the claim's own write drops it" do
    person = person()
    {:ok, claimed} = Users.set_namespace(person, "first-ns")

    assert Namespace.lookup(person.id) == "first-ns"

    # The slug is kept for the code's minute.
    [{_key, "first-ns", expires_at}] = entry(person.id)
    left = expires_at - System.monotonic_time(:millisecond)
    assert left > 50_000 and left <= 60_000

    write_below!(person.id, "second-ns")
    assert Namespace.lookup(person.id) == "first-ns"

    {:ok, _} = Users.set_namespace(claimed, "third-ns")
    assert Namespace.lookup(person.id) == "third-ns"
  end

  test "a read after the minute asks the users row again" do
    person = person()
    {:ok, _} = Users.set_namespace(person, "first-ns")
    assert Namespace.lookup(person.id) == "first-ns"

    write_below!(person.id, "second-ns")
    assert Namespace.lookup(person.id) == "first-ns"

    # The minute is spent: the entry's expiry is moved to now.
    true =
      :ets.update_element(
        Arca.Cache.table_name(),
        {:namespace_slug, person.id},
        {3, System.monotonic_time(:millisecond)}
      )

    assert Namespace.lookup(person.id) == "second-ns"
  end

  test "at 0, the suites' setting, every read asks the row" do
    Prima.Test.Env.put_app_env(:sanctum, :namespace_cache_ttl_ms, 0)
    person = person()
    {:ok, _} = Users.set_namespace(person, "first-ns")

    assert Namespace.lookup(person.id) == "first-ns"

    write_below!(person.id, "second-ns")
    assert Namespace.lookup(person.id) == "second-ns"
  end
end
