# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LocusRolesTest do
  @moduledoc """
  The role table and its vector file (`tests/fixtures/locus_roles.json`)
  are one table: the file holds the module's values, value by value and
  in its order, under exactly its keys. And the table is one a node can
  run: no two roles share a name, a key, a user, a uid, a pool, a user
  prefix, a port or a run folder; each role's user, key, run folder and
  home root follow from its name; their uid ranges, the role users' uids
  and the kept group's gid are apart; every reach is one the keeper
  knows; the runtime alone is private, its spawns relay spaces and every
  other role's routed; the backends role alone keeps homes; and each
  fixed address, the endpoint's loopback listener's on its network, its
  proxy listener's, Caddy's and Tailscale's on edge, and the host API's on
  the Locus network, lies in its subnet, outside the range the subnet's
  other containers draw from, and apart from the others.
  """
  use ExUnit.Case, async: true

  alias Prima.LocusRoles

  @vectors Path.expand("../../../../tests/fixtures/locus_roles.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @release_keys ~w(bin container edge_address edge_caddy_address edge_ip_range edge_network
                   edge_subnet edge_tailscale_address endpoint_address endpoint_ip_range
                   endpoint_network endpoint_subnet guard guard_container home_root
                   host_api_address ip_range memory network run_dir run_size service subnet)
  @role_keys ~w(first_uid home_root home_size kept_first_uid kept_gid kept_group kept_last_uid
                kept_root kept_volume key last_uid memory name pool port private reach run_dir
                run_size uid user user_prefix)
  @release_memory_keys ~w(byte_cost keeper_read_bytes keeper_read_copies relay_queue_bytes
                          socket_queue_bytes)
  @role_memory_keys ~w(answering fetch_head_bytes fetch_read_ahead_bytes fetch_read_bytes freed_segments_bytes unread)

  # The file's spelling of a value of the module: atoms as their names, a
  # map under its keys' names, a uid range as its first and last uid.
  defp spelled(nil), do: nil
  defp spelled(boolean) when is_boolean(boolean), do: boolean
  defp spelled(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp spelled(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), spelled(value)} end)

  defp spelled(value), do: value

  defp spelled_release(release),
    do: Map.new(release, fn {key, value} -> {to_string(key), spelled(value)} end)

  defp spelled_role(role) do
    {uids, role} = Map.pop!(role, :uids)
    {kept, role} = Map.pop!(role, :kept_uids)

    role
    |> Map.new(fn {key, value} -> {to_string(key), spelled(value)} end)
    |> Map.merge(%{"first_uid" => uids.first, "last_uid" => uids.last})
    |> Map.merge(%{"kept_first_uid" => kept && kept.first, "kept_last_uid" => kept && kept.last})
  end

  test "the vector file is the table, value by value, under exactly its keys" do
    assert @vectors |> Map.keys() |> Enum.sort() == ["comment", "release", "roles"]
    assert @vectors["release"] |> Map.keys() |> Enum.sort() == @release_keys

    assert @vectors["release"]["memory"] |> Map.keys() |> Enum.sort() == @release_memory_keys

    for role <- @vectors["roles"] do
      assert role |> Map.keys() |> Enum.sort() == @role_keys, "#{role["name"]}'s keys"

      assert role["memory"] |> Map.keys() |> Enum.sort() == @role_memory_keys,
             "#{role["name"]}'s memory keys"
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

  test "no two roles share a name, a key, a user, a uid, a pool, a prefix, a port or a run folder" do
    roles = LocusRoles.roles()

    for fact <- [:name, :key, :user, :uid, :pool, :user_prefix, :port, :run_dir, :home_root] do
      values = Enum.map(roles, &Map.fetch!(&1, fact))
      assert Enum.uniq(values) == values, "#{fact} repeats: #{inspect(values)}"
    end

    release = LocusRoles.release()
    assert release.guard != release.service and release.guard_container != release.container
  end

  # The keeper starts a role from its key, runs it as `locus-<name>`, and
  # gives it `<run root>/<name>` and `<home root>/<name>`: each follows
  # from the role's name.
  test "a role's key, user, run folder and home root follow from its name" do
    release = LocusRoles.release()

    for %{name: name} = role <- LocusRoles.roles() do
      assert role.key == "LOCUS_#{name |> Atom.to_string() |> String.upcase()}_KEY"
      assert role.user == "locus-#{name}"
      assert role.run_dir == Path.join(release.run_dir, Atom.to_string(name))
      assert role.home_root == Path.join(release.home_root, Atom.to_string(name))
    end
  end

  # The runtime's runners reach nothing but their relays, and its process
  # alone reaches core's host API; a build or a program leaves through the
  # route the guard makes for its space.
  test "the runtime alone is private and relays, the others route, and the backends alone keep homes" do
    assert Enum.map(LocusRoles.roles(), &{&1.name, &1.reach, &1.private}) ==
             [runtime: "relay", builds: "routed", backends: "routed"]
             |> Enum.map(fn {name, reach} -> {name, reach, name == :runtime} end)

    for role <- LocusRoles.roles() do
      kept = [role.kept_root, role.kept_volume, role.kept_uids, role.kept_group, role.kept_gid]
      assert Enum.all?(kept, &(&1 == nil)) == (role.name != :backends), "#{role.name}'s kept"
    end
  end

  test "the host API's fixed address lies in the Locus network's subnet, outside its range" do
    %{subnet: subnet, ip_range: range, host_api_address: address} = LocusRoles.release()
    assert_fixed(subnet, range, address)
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

  test "the uid ranges are disjoint, ascending, and hold no role user's uid or the kept group's gid" do
    roles = LocusRoles.roles()
    ranges = Enum.flat_map(roles, &Enum.reject([&1.uids, &1.kept_uids], fn r -> r == nil end))
    ids = Enum.map(roles, & &1.uid) ++ for(%{kept_gid: gid} <- roles, gid != nil, do: gid)

    assert Enum.uniq(ids) == ids

    for range <- ranges do
      assert range.step == 1 and range.first <= range.last, inspect(range)
      for id <- ids, do: refute(id in range, "#{inspect(range)} holds #{id}")
    end

    for {a, i} <- Enum.with_index(ranges), b <- Enum.drop(ranges, i + 1) do
      assert Range.disjoint?(a, b), "#{inspect(a)} and #{inspect(b)} overlap"
    end
  end

  # The backends role alone keeps output unread; only the runtime fetches
  # for its runners, so only it names a fetch's figures and the segments
  # its VM keeps of the largest answers it relays.
  test "the backends role alone has an unread bound, the runtime alone a fetch's figures" do
    for role <- LocusRoles.roles() do
      memory = role.memory
      assert is_integer(memory.answering) and memory.answering > 0, "#{role.name}'s answering"
      assert memory.unread != nil == (role.name == :backends), "#{role.name}'s unread"

      for figure <- [
            :fetch_read_bytes,
            :fetch_read_ahead_bytes,
            :fetch_head_bytes,
            :freed_segments_bytes
          ] do
        assert memory[figure] != nil == (role.name == :runtime), "#{role.name}'s #{figure}"
      end
    end

    # A held byte costs at least itself.
    assert LocusRoles.release().memory.byte_cost >= 1.0
  end

  test "every reach is one the keeper knows" do
    for role <- LocusRoles.roles() do
      assert role.reach in LocusRoles.reaches(), "#{role.name}'s reach #{inspect(role.reach)}"
    end
  end
end
