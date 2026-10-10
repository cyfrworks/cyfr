# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusRolesTest do
  @moduledoc """
  The role table and its vector file (`tests/fixtures/locus_roles.json`)
  are one table: the file holds the module's values, value by value and
  in its order, under exactly its keys. And the table is one a node can
  run: no two roles share a name, a pool, a service, a container, a
  network, a user prefix or a port; their uid ranges are disjoint and none
  holds the release's uid; every isolation is one the keeper knows; and
  the image serves one of the roles.
  """
  use ExUnit.Case, async: true

  alias Prima.{KeeperProtocol, LocusRoles}

  @vectors Path.expand("../../../../tests/fixtures/locus_roles.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @release_keys ~w(bin home_root image_role run_dir run_size uid user)
  @role_keys ~w(container first_uid home_size isolation last_uid name network pool port
                profile service user_prefix)

  # The file's spelling of a value of the module: atoms as their names,
  # a uid range as its first and last uid.
  defp spelled(nil), do: nil
  defp spelled(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp spelled(value), do: value

  defp spelled_release(release),
    do: Map.new(release, fn {key, value} -> {to_string(key), spelled(value)} end)

  defp spelled_role(role) do
    {uids, role} = Map.pop!(role, :uids)

    role
    |> Map.new(fn {key, value} -> {to_string(key), spelled(value)} end)
    |> Map.merge(%{"first_uid" => uids.first, "last_uid" => uids.last})
  end

  test "the vector file is the table, value by value, under exactly its keys" do
    assert @vectors |> Map.keys() |> Enum.sort() == ["comment", "release", "roles"]
    assert @vectors["release"] |> Map.keys() |> Enum.sort() == @release_keys

    for role <- @vectors["roles"] do
      assert role |> Map.keys() |> Enum.sort() == @role_keys, "#{role["name"]}'s keys"
    end

    assert @vectors["release"] == spelled_release(LocusRoles.release())
    assert @vectors["roles"] == Enum.map(LocusRoles.roles(), &spelled_role/1)
  end

  test "the roles are named in their order, and a role the release lacks is refused by name" do
    roles = LocusRoles.roles()

    assert LocusRoles.names() == [:runtime, :builds, :backends]
    assert LocusRoles.names() == Enum.map(roles, & &1.name)

    for role <- roles, do: assert(LocusRoles.role!(role.name) == role)

    assert_raise ArgumentError, ~r/:workers is not a role of the locus release/, fn ->
      LocusRoles.role!(:workers)
    end
  end

  test "no two roles share a name, a pool, a service, a container, a network, a user prefix or a port" do
    roles = LocusRoles.roles()

    for fact <- [:name, :pool, :service, :container, :network, :user_prefix, :port] do
      values = Enum.map(roles, &Map.fetch!(&1, fact))
      assert Enum.uniq(values) == values, "#{fact} repeats: #{inspect(values)}"
    end
  end

  test "the uid ranges are disjoint, ascending, and none holds the release's uid" do
    ranges = Enum.map(LocusRoles.roles(), & &1.uids)
    release_uid = LocusRoles.release().uid

    for range <- ranges do
      assert range.step == 1 and range.first <= range.last, inspect(range)
      refute release_uid in range, "#{inspect(range)} holds the release's uid #{release_uid}"
    end

    for {a, i} <- Enum.with_index(ranges), b <- Enum.drop(ranges, i + 1) do
      assert Range.disjoint?(a, b), "#{inspect(a)} and #{inspect(b)} overlap"
    end
  end

  test "every isolation is one the keeper knows, and the image serves one of the roles" do
    for role <- LocusRoles.roles() do
      assert role.isolation == nil or role.isolation in KeeperProtocol.isolations(),
             "#{role.name}'s isolation #{inspect(role.isolation)}"
    end

    assert LocusRoles.release().image_role in LocusRoles.names()
  end
end
