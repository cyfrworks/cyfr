# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GuardTableTest do
  @moduledoc """
  The island egress guard (`apps/locus/keeper/guard/cyfr-guard.sh`) holds
  `Prima.Cidr.address_table/0`, the table the control plane's own outbound
  calls are held to, and installs exactly it beside the island's own
  rows, in the guard's order: for the namespace's own processes, the
  control plane, the island's subnets, the service's own loopback and the
  deployment's private hosts; and for the spaces, what every route is held
  to (the metadata, the control plane and the island's subnets; then the
  private rows), the jumps to each route's chain and to its replies, the
  refusal of all else from or into a space, of both families, the jumps of
  the connections to the island's own addresses to the roles' forwarding,
  and the masquerade of the route range the guard chose. It refuses to
  start on a host API it cannot read.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Cyfr.Gen.GuardTable

  @control_plane "172.16.230.2"
  @targets ["10.9.8.0/24", "fd12:3456::/64"]

  test "the guard's address table is Prima.Cidr's" do
    script = File.read!(GuardTable.path())

    assert script == GuardTable.splice(script),
           "cyfr-guard.sh does not hold Prima.Cidr.address_table/0 — run `mix cyfr.gen.guard_table`"
  end

  test "the guard installs every metadata and private row of Prima.Cidr and the island's own rows, in order" do
    {output, 0} =
      System.cmd("sh", [GuardTable.path(), "rules"],
        env: [
          {"CYFR_GUARD_CONTROL_PLANE", @control_plane},
          {"CYFR_PRIVATE_EGRESS_TARGETS", Enum.join(@targets, ",")}
        ],
        stderr_to_stdout: true
      )

    lines = String.split(output, "\n", trim: true)
    rules = Enum.filter(lines, &String.match?(&1, ~r/^ip6?tables /))

    # The island's subnets are this host's, which the guard reads from the
    # kernel and logs as it adds each, and so is the route range it chose
    # beside them.
    subnets = for "[cyfr-guard] island subnet " <> subnet <- lines, do: subnet
    addresses = for "[cyfr-guard] island address " <> address <- lines, do: address
    [range] = for "[cyfr-guard] routes take " <> range <- lines, do: range
    assert range =~ ~r{^10\.\d+\.0\.0/16$}

    %{metadata: metadata, private: private} = Prima.Cidr.address_table()
    private = Enum.reject(private, &(&1 in metadata))
    v4_subnets = Enum.reject(subnets, &v6?/1)

    assert rules ==
             [
               "iptables -N CYFR_GUARD",
               "ip6tables -N CYFR_GUARD",
               "iptables -N CYFR_GUARD_REFUSE",
               "iptables -N CYFR_GUARD_PRIVATE",
               "iptables -N CYFR_GUARD_ROUTES",
               "iptables -N CYFR_GUARD_REPLIES",
               "iptables -A OUTPUT -j CYFR_GUARD",
               "ip6tables -A OUTPUT -j CYFR_GUARD",
               # Into a space, nothing but the ICMP answering its refusals.
               "iptables -A CYFR_GUARD -o sp+ -p icmp -m conntrack --ctstate RELATED -j ACCEPT",
               "iptables -A CYFR_GUARD -o sp+ -j REJECT --reject-with icmp-admin-prohibited",
               "ip6tables -A CYFR_GUARD -o sp+ -j REJECT --reject-with icmp6-adm-prohibited",
               "iptables -A CYFR_GUARD -m conntrack ! --ctstate NEW -j ACCEPT",
               "ip6tables -A CYFR_GUARD -m conntrack ! --ctstate NEW -j ACCEPT"
             ] ++
               rejects("CYFR_GUARD", metadata) ++
               [
                 "iptables -A CYFR_GUARD -d #{@control_plane}/32 -j REJECT --reject-with icmp-admin-prohibited"
               ] ++
               rejects("CYFR_GUARD", v4_subnets) ++
               rejects("CYFR_GUARD", Enum.filter(subnets, &v6?/1)) ++
               [
                 "iptables -A CYFR_GUARD -o lo -j RETURN",
                 "ip6tables -A CYFR_GUARD -o lo -j RETURN",
                 "iptables -A CYFR_GUARD -d 10.9.8.0/24 -j RETURN",
                 "ip6tables -A CYFR_GUARD -d fd12:3456::/64 -j RETURN"
               ] ++
               rejects("CYFR_GUARD", private) ++
               rejects("CYFR_GUARD_REFUSE", Enum.reject(metadata, &v6?/1)) ++
               [
                 "iptables -A CYFR_GUARD_REFUSE -d #{@control_plane}/32 -j REJECT --reject-with icmp-admin-prohibited"
               ] ++
               rejects("CYFR_GUARD_REFUSE", v4_subnets) ++
               rejects("CYFR_GUARD_PRIVATE", Enum.reject(private, &v6?/1)) ++
               [
                 "iptables -A FORWARD -i sp+ -j CYFR_GUARD_ROUTES",
                 "iptables -A FORWARD -i sp+ -j REJECT --reject-with icmp-admin-prohibited",
                 "iptables -A FORWARD -o sp+ -j CYFR_GUARD_REPLIES",
                 "iptables -A FORWARD -o sp+ -j REJECT --reject-with icmp-admin-prohibited",
                 "iptables -A INPUT -i sp+ -p tcp -m conntrack --ctstate DNAT --ctdir REPLY -j CYFR_GUARD_ROUTES",
                 "iptables -A INPUT -i sp+ -j REJECT --reject-with icmp-admin-prohibited",
                 "ip6tables -A FORWARD -i sp+ -j REJECT --reject-with icmp6-adm-prohibited",
                 "ip6tables -A FORWARD -o sp+ -j REJECT --reject-with icmp6-adm-prohibited",
                 "ip6tables -A INPUT -i sp+ -j REJECT --reject-with icmp6-adm-prohibited",
                 "iptables -t nat -N CYFR_GUARD_ROLES"
               ] ++
               Enum.flat_map(addresses, fn address ->
                 [
                   "iptables -t nat -A PREROUTING -d #{address}/32 ! -i sp+ -p tcp -j CYFR_GUARD_ROLES",
                   "iptables -t nat -A OUTPUT -d #{address}/32 -p tcp -j CYFR_GUARD_ROLES"
                 ]
               end) ++
               [
                 "iptables -t nat -A POSTROUTING -s #{range} ! -o sp+ -j MASQUERADE"
               ]

    # The island's own addresses are this namespace's addresses on its
    # subnets.
    assert Enum.all?(addresses, fn address -> Enum.any?(v4_subnets, &within?(address, &1)) end)
  end

  # Core's host API is one address and port on the island's subnets; the
  # guard starts on one it reads so, logging it, and refuses to start on any
  # other value, naming it.
  test "the guard refuses to start on a host API that is not an address and port of the island's subnets" do
    rules = fn host_api ->
      System.cmd("sh", [GuardTable.path(), "rules"],
        env: [{"CYFR_GUARD_CONTROL_PLANE", @control_plane}, {"CYFR_GUARD_HOST_API", host_api}],
        stderr_to_stdout: true
      )
    end

    {output, 0} = rules.("")
    refute output =~ "host API"

    assert [address | _] =
             for(
               "[cyfr-guard] island address " <> address <- String.split(output, "\n"),
               do: address
             ),
           "this host has no IPv4 address on a subnet of its own: #{output}"

    {output, 0} = rules.("#{address}:4300")
    assert output =~ "[cyfr-guard] host API #{address}:4300 passes private roles"

    for bad <- [
          address,
          "#{address}:0",
          "#{address}:065",
          "#{address}:65536",
          "#{address}:4300:1",
          "#{address}:http",
          "192.0.2.1:4300",
          "#{address}.1:4300",
          "[::1]:4300"
        ] do
      {output, status} = rules.(bad)
      assert status != 0, "a host API of #{inspect(bad)} was taken: #{output}"
      assert output =~ "[cyfr-guard] error: CYFR_GUARD_HOST_API is '#{bad}'"
      refute output =~ ~r/^iptables /m
    end
  end

  defp within?(address, cidr) do
    [base, bits] = String.split(cidr, "/")
    shift = 32 - String.to_integer(bits)
    Bitwise.bsr(ipv4(base), shift) == Bitwise.bsr(ipv4(address), shift)
  end

  defp ipv4(text) do
    {:ok, {a, b, c, d}} = :inet.parse_ipv4strict_address(String.to_charlist(text))
    <<n::32>> = <<a, b, c, d>>
    n
  end

  # The route range is the first /16 of 10.0.0.0/8 from 10.213.0.0/16 on that
  # no route of the namespace and no private host overlaps: one that does
  # is passed over and logged naming what it overlaps.
  test "the guard's route range passes over a /16 a private host overlaps, naming it" do
    {output, 0} =
      System.cmd("sh", [GuardTable.path(), "rules"],
        env: [
          {"CYFR_GUARD_CONTROL_PLANE", @control_plane},
          {"CYFR_PRIVATE_EGRESS_TARGETS", "10.213.4.0/24,10.214.0.9"}
        ],
        stderr_to_stdout: true
      )

    assert output =~
             "[cyfr-guard] 10.213.0.0/16 overlaps 10.213.4.0/24: the routes take another range"

    assert output =~
             "[cyfr-guard] 10.214.0.0/16 overlaps 10.214.0.9: the routes take another range"

    assert [range] =
             for("[cyfr-guard] routes take " <> range <- String.split(output, "\n"), do: range)

    refute range in ["10.213.0.0/16", "10.214.0.0/16"]

    {all, status} =
      System.cmd("sh", [GuardTable.path(), "rules"],
        env: [
          {"CYFR_GUARD_CONTROL_PLANE", @control_plane},
          {"CYFR_PRIVATE_EGRESS_TARGETS", "10.0.0.0/8"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0
    assert all =~ "error: no /16 of 10.0.0.0/8 is free for the routes of the spaces"
    assert all =~ "10.213.0.0/16: 10.0.0.0/8"
  end

  test "the guard's table holds every range the island must refuse" do
    script = File.read!(GuardTable.path())

    for range <- ~w(169.254.0.0/16 100.100.100.200/32 192.0.0.192/32 fe80::/10 fd00:ec2::254/128) do
      assert range in table(script, "METADATA"), range
    end

    for range <-
          ~w(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 0.0.0.0/8 100.64.0.0/10 192.0.0.0/24
             198.18.0.0/15 224.0.0.0/4 240.0.0.0/4 fc00::/7 64:ff9b:1::/48 ff00::/8) do
      assert range in table(script, "PRIVATE"), range
    end
  end

  # The metadata or private rows of both families, as the guard's block
  # spells them.
  defp table(script, class) do
    for family <- ["V4", "V6"],
        [_, rows] <- Regex.scan(~r/^#{class}_#{family}='\n(.*?)'$/ms, script),
        row <- String.split(rows, "\n", trim: true),
        do: row
  end

  defp rejects(chain, ranges) do
    Enum.map(ranges, fn range ->
      if v6?(range),
        do: "ip6tables -A #{chain} -d #{range} -j REJECT --reject-with icmp6-adm-prohibited",
        else: "iptables -A #{chain} -d #{range} -j REJECT --reject-with icmp-admin-prohibited"
    end)
  end

  defp v6?(range), do: String.contains?(range, ":")
end
