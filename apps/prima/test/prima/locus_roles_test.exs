# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusRolesTest do
  @moduledoc """
  The role table and its vector file (`tests/fixtures/locus_roles.json`)
  are one table: the file holds the module's values, value by value and
  in its order, under exactly its keys. And the table is one a node can
  run: no two roles share a name, a pool, a service, a container, a
  network, a user prefix, a port or a guard, and no guard is named as a
  service; their uid ranges are disjoint and none holds the release's uid;
  every isolation is one the keeper knows; a role whose spawns share the
  island's network has a guard and the runtime, whose runners have none,
  has none; the image serves one of the roles; and each fixed address,
  the endpoint's loopback listener's on its network and its proxy
  listener's, Caddy's and Tailscale's on edge, lies in its subnet, outside
  the range the subnet's other containers draw from, and apart from the
  others.
  """
  use ExUnit.Case, async: true

  alias Prima.{KeeperProtocol, LocusRoles}

  @vectors Path.expand("../../../../tests/fixtures/locus_roles.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @release_keys ~w(bin edge_address edge_caddy_address edge_ip_range edge_network edge_subnet
                   edge_tailscale_address endpoint_address endpoint_ip_range endpoint_network
                   endpoint_subnet home_root image_role run_dir run_size uid user)
  @role_keys ~w(container first_uid guard home_size isolation last_uid name network pool port
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

  test "no two roles share a name, a pool, a service, a container, a network, a user prefix, a port or a guard" do
    roles = LocusRoles.roles()

    for fact <- [:name, :pool, :service, :container, :network, :user_prefix, :port] do
      values = Enum.map(roles, &Map.fetch!(&1, fact))
      assert Enum.uniq(values) == values, "#{fact} repeats: #{inspect(values)}"
    end

    guards = for %{guard: guard} <- roles, guard != nil, do: guard
    assert Enum.uniq(guards) == guards, "guard repeats: #{inspect(guards)}"
    assert guards -- Enum.map(roles, & &1.service) == guards, "a guard is named as a service"
  end

  # The runtime's runners have no network, so nothing of theirs leaves to
  # be guarded; a build or a backend shares its island's network and
  # leaves through the island's guard.
  test "a role whose spawns share the island's network has a guard, and the runtime has none" do
    for role <- LocusRoles.roles() do
      if role.isolation == nil do
        assert is_binary(role.guard) and role.guard != "", "#{role.name} has no guard"
      else
        assert role.guard == nil, "#{role.name}'s isolated spawns need no guard"
      end
    end
  end

  test "the endpoint's fixed address lies in its subnet, outside the range the other containers draw from" do
    %{endpoint_subnet: subnet, endpoint_ip_range: range, endpoint_address: address} =
      LocusRoles.release()

    assert_fixed(subnet, range, address)
  end

  test "edge's three fixed addresses lie in its subnet, outside its range, and apart" do
    release = LocusRoles.release()

    addresses = [
      release.edge_address,
      release.edge_caddy_address,
      release.edge_tailscale_address
    ]

    for address <- addresses,
        do: assert_fixed(release.edge_subnet, release.edge_ip_range, address)

    assert Enum.uniq(addresses) == addresses

    {endpoint, endpoint_bits} = cidr(release.endpoint_subnet)
    {edge, edge_bits} = cidr(release.edge_subnet)
    bits = min(endpoint_bits, edge_bits)

    refute Bitwise.bsr(endpoint, 32 - bits) == Bitwise.bsr(edge, 32 - bits),
           "the endpoint's and edge's subnets overlap"
  end

  defp assert_fixed(subnet, range, address) do
    {base, bits} = cidr(subnet)
    {range_base, range_bits} = cidr(range)
    {value, 32} = cidr(address <> "/32")
    last = base + Bitwise.bsl(1, 32 - bits) - 1

    assert range_bits > bits and
             Bitwise.bsr(range_base, 32 - bits) == Bitwise.bsr(base, 32 - bits),
           "#{range} is not a part of #{subnet}"

    assert Bitwise.bsr(value, 32 - bits) == Bitwise.bsr(base, 32 - bits),
           "#{address} is not in #{subnet}"

    refute Bitwise.bsr(value, 32 - range_bits) == Bitwise.bsr(range_base, 32 - range_bits),
           "#{address} is in #{range}"

    refute value in [base, base + 1, last],
           "#{address} is the subnet's network, gateway or broadcast address"
  end

  # An IPv4 address with a prefix length, the address as an integer.
  defp cidr(text) do
    [address, bits] = String.split(text, "/")
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(address))
    <<value::32>> = <<a, b, c, d>>
    {value, String.to_integer(bits)}
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
