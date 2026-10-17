# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GuardTableTest do
  @moduledoc """
  The island egress guard (`apps/locus/keeper/guard/cyfr-guard.sh`) holds
  `Prima.Cidr.address_table/0`, the table the control plane's own outbound
  calls are held to, and installs exactly it beside the island's own
  rows: the control plane, the island's subnets, the spawns' reach into
  the namespace, the service's own loopback and the deployment's private
  hosts, in the guard's order.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Cyfr.Gen.GuardTable

  @pool "61000-61009"
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
          {"CYFR_GUARD_POOL", @pool},
          {"CYFR_GUARD_CONTROL_PLANE", @control_plane},
          {"CYFR_PRIVATE_EGRESS_TARGETS", Enum.join(@targets, ",")}
        ],
        stderr_to_stdout: true
      )

    lines = String.split(output, "\n", trim: true)
    rules = Enum.filter(lines, &String.match?(&1, ~r/^ip6?tables /))

    # The island's subnets are this host's, which the guard reads from the
    # kernel and logs as it adds each.
    subnets = for "[cyfr-guard] island subnet " <> subnet <- lines, do: subnet

    %{metadata: metadata, private: private} = Prima.Cidr.address_table()
    private = Enum.reject(private, &(&1 in metadata))

    assert rules ==
             [
               "iptables -N CYFR_GUARD",
               "ip6tables -N CYFR_GUARD",
               "iptables -A OUTPUT -j CYFR_GUARD",
               "ip6tables -A OUTPUT -j CYFR_GUARD",
               "iptables -A CYFR_GUARD -m conntrack ! --ctstate NEW -j RETURN",
               "ip6tables -A CYFR_GUARD -m conntrack ! --ctstate NEW -j RETURN"
             ] ++
               rejects(metadata) ++
               [
                 "iptables -A CYFR_GUARD -d #{@control_plane}/32 -j REJECT --reject-with icmp-admin-prohibited"
               ] ++
               rejects(Enum.reject(subnets, &v6?/1)) ++
               rejects(Enum.filter(subnets, &v6?/1)) ++
               [
                 "iptables -A CYFR_GUARD -m owner --uid-owner #{@pool} -m conntrack --ctorigdst 127.0.0.11 --ctorigdstport 53 -j RETURN",
                 "iptables -A CYFR_GUARD -m owner --uid-owner #{@pool} -m addrtype --dst-type LOCAL -j REJECT --reject-with icmp-admin-prohibited",
                 "ip6tables -A CYFR_GUARD -m owner --uid-owner #{@pool} -m addrtype --dst-type LOCAL -j REJECT --reject-with icmp6-adm-prohibited",
                 "iptables -A CYFR_GUARD -o lo -m owner ! --uid-owner #{@pool} -j RETURN",
                 "ip6tables -A CYFR_GUARD -o lo -m owner ! --uid-owner #{@pool} -j RETURN",
                 "iptables -A CYFR_GUARD -d 10.9.8.0/24 -j RETURN",
                 "ip6tables -A CYFR_GUARD -d fd12:3456::/64 -j RETURN"
               ] ++
               rejects(private)
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

  defp rejects(ranges) do
    Enum.map(ranges, fn range ->
      if v6?(range),
        do: "ip6tables -A CYFR_GUARD -d #{range} -j REJECT --reject-with icmp6-adm-prohibited",
        else: "iptables -A CYFR_GUARD -d #{range} -j REJECT --reject-with icmp-admin-prohibited"
    end)
  end

  defp v6?(range), do: String.contains?(range, ":")
end
