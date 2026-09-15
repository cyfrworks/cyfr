# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.CidrTest do
  use ExUnit.Case, async: true

  alias Cyfr.Cidr

  describe "parse_ip/1" do
    test "parses IPv4 and IPv6" do
      assert {:ok, {10, 0, 0, 1}} = Cidr.parse_ip("10.0.0.1")
      assert {:ok, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}} = Cidr.parse_ip("2001:db8::1")
    end

    test "rejects junk and non-binary" do
      assert :error = Cidr.parse_ip("not-an-ip")
      assert :error = Cidr.parse_ip(nil)
      assert :error = Cidr.parse_ip(123)
    end
  end

  describe "parse_cidr/1 (family-bounded, fail-closed)" do
    test "parses valid IPv4 / IPv6 CIDRs" do
      assert {:ok, {{10, 0, 0, 0}, 8}} = Cidr.parse_cidr("10.0.0.0/8")
      assert {:ok, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}} = Cidr.parse_cidr("2001:db8::/32")
    end

    test "rejects out-of-range / cross-family / malformed prefixes" do
      assert :error = Cidr.parse_cidr("192.168.1.0/99")
      assert :error = Cidr.parse_cidr("192.168.1.0/-1")
      # IPv6-width prefix on an IPv4 address must not collapse the mask
      assert :error = Cidr.parse_cidr("1.2.3.0/64")
      assert :error = Cidr.parse_cidr("10.0.0.0")
      assert :error = Cidr.parse_cidr("garbage/8")
      assert :error = Cidr.parse_cidr(nil)
    end
  end

  describe "ip_in_cidr?/2" do
    test "IPv4 membership (tuple and string)" do
      assert Cidr.ip_in_cidr?({10, 1, 2, 3}, "10.0.0.0/8")
      assert Cidr.ip_in_cidr?("10.1.2.3", "10.0.0.0/8")
      refute Cidr.ip_in_cidr?({192, 168, 1, 1}, "10.0.0.0/8")
    end

    test "checks IPv6 subnet membership" do
      assert Cidr.ip_in_cidr?("2001:db8::1", "2001:db8::/32")
      refute Cidr.ip_in_cidr?("2001:dead::1", "2001:db8::/32")
    end

    test "/0 matches any same-family address, /32 is exact" do
      assert Cidr.ip_in_cidr?({8, 8, 8, 8}, "0.0.0.0/0")
      assert Cidr.ip_in_cidr?({1, 2, 3, 4}, "1.2.3.4/32")
      refute Cidr.ip_in_cidr?({1, 2, 3, 5}, "1.2.3.4/32")
    end

    test "IPv4-mapped IPv6 address matches the equivalent IPv4 CIDR" do
      assert Cidr.ip_in_cidr?({0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203}, "10.0.0.0/8")
    end

    test "real IPv6 address vs IPv4 CIDR is a family mismatch (no match)" do
      refute Cidr.ip_in_cidr?("2001:db8::1", "10.0.0.0/8")
    end

    test "invalid inputs fail closed" do
      refute Cidr.ip_in_cidr?("nope", "10.0.0.0/8")
      refute Cidr.ip_in_cidr?({10, 0, 0, 1}, "10.0.0.0/99")
      refute Cidr.ip_in_cidr?({10, 0, 0, 1}, :not_a_string)
    end
  end

  describe "match?/2 (exact-or-CIDR)" do
    test "exact match by parsed equality (string or tuple)" do
      assert Cidr.match?("10.0.0.1", "10.0.0.1")
      assert Cidr.match?({10, 0, 0, 1}, "10.0.0.1")
      refute Cidr.match?("10.0.0.2", "10.0.0.1")
    end

    test "CIDR entry routes through ip_in_cidr?/2" do
      assert Cidr.match?("10.1.2.3", "10.0.0.0/8")
      refute Cidr.match?("192.168.1.1", "10.0.0.0/8")
    end

    test "junk fails closed" do
      refute Cidr.match?("10.0.0.1", "garbage")
      refute Cidr.match?(:x, "10.0.0.1")
    end
  end

  describe "ip_in_network?/3" do
    test "direct tuple test and fail-closed guards" do
      assert Cidr.ip_in_network?({10, 1, 2, 3}, {10, 0, 0, 0}, 8)
      # family mismatch
      refute Cidr.ip_in_network?({10, 1, 2, 3}, {0, 0, 0, 0, 0, 0, 0, 0}, 8)
      # out-of-range prefix
      refute Cidr.ip_in_network?({10, 1, 2, 3}, {10, 0, 0, 0}, 99)
      refute Cidr.ip_in_network?(:bad, {10, 0, 0, 0}, 8)
    end
  end

  describe "metadata?/1" do
    test "IPv4 link-local" do
      assert Cidr.metadata?({169, 254, 169, 254})
      refute Cidr.metadata?({169, 253, 0, 1})
      refute Cidr.metadata?({10, 0, 0, 1})
    end

    test "recognizes IPv6 fe80::/10 as link-local" do
      assert Cidr.metadata?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert Cidr.metadata?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
      refute Cidr.metadata?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      refute Cidr.metadata?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped IPv6 link-local" do
      assert Cidr.metadata?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0x0001})
      refute Cidr.metadata?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
    end

    test "every IPv6 form embedding 169.254.169.254 is metadata, and its public twin is not" do
      forms = [
        # ::a9fe:a9fe, IPv4-compatible
        {{0, 0, 0, 0, 0, 0, 0xA9FE, 0xA9FE}, {0, 0, 0, 0, 0, 0, 0x0808, 0x0808}},
        # ::ffff:0:a9fe:a9fe, IPv4-translated
        {{0, 0, 0, 0, 0xFFFF, 0, 0xA9FE, 0xA9FE}, {0, 0, 0, 0, 0xFFFF, 0, 0x0808, 0x0808}},
        # 64:ff9b::a9fe:a9fe, NAT64 well-known prefix
        {{0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE}, {0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808}},
        # 64:ff9b:1::a9fe:a9fe, local-use NAT64 at /96
        {{0x64, 0xFF9B, 1, 0, 0, 0, 0xA9FE, 0xA9FE}, {0x64, 0xFF9B, 1, 0, 0, 0, 0x0808, 0x0808}},
        # 64:ff9b:1:a9fe:a9:fe00::, local-use NAT64 at /48
        {{0x64, 0xFF9B, 1, 0xA9FE, 0x00A9, 0xFE00, 0, 0},
         {0x64, 0xFF9B, 1, 0x0808, 0x0008, 0x0800, 0x0808, 0x0808}},
        # 64:ff9b:1:a9:fe:a9fe::, local-use NAT64 at /56
        {{0x64, 0xFF9B, 1, 0x00A9, 0x00FE, 0xA9FE, 0, 0},
         {0x64, 0xFF9B, 1, 0x0008, 0x0008, 0x0808, 0x0808, 0x0808}},
        # 64:ff9b:1:0:a9:fea9:fe00:0, local-use NAT64 at /64
        {{0x64, 0xFF9B, 1, 0, 0x00A9, 0xFEA9, 0xFE00, 0},
         {0x64, 0xFF9B, 1, 0x0808, 0x0008, 0x0808, 0x0808, 0x0808}},
        # 2002:a9fe:a9fe::1, 6to4
        {{0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 1}, {0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 1}},
        # 2001:0:a9fe:a9fe::, Teredo server
        {{0x2001, 0, 0xA9FE, 0xA9FE, 0, 0, 0, 0},
         {0x2001, 0, 0x0808, 0x0808, 0, 0, 0xF7F7, 0xF7F7}},
        # 2001:0:808:808::5601:5601, Teredo client (inverted)
        {{0x2001, 0, 0x0808, 0x0808, 0, 0, 0x5601, 0x5601},
         {0x2001, 0, 0x0808, 0x0808, 0, 0, 0xF7F7, 0xF7F7}},
        # 2001:db8::5efe:a9fe:a9fe, ISATAP
        {{0x2001, 0xDB8, 0, 0, 0, 0x5EFE, 0xA9FE, 0xA9FE},
         {0x2001, 0xDB8, 0, 0, 0, 0x5EFE, 0x0808, 0x0808}},
        # 2001:db8::200:5efe:a9fe:a9fe, ISATAP with a global IPv4 flag
        {{0x2001, 0xDB8, 0, 0, 0x200, 0x5EFE, 0xA9FE, 0xA9FE},
         {0x2001, 0xDB8, 0, 0, 0x200, 0x5EFE, 0x0808, 0x0808}}
      ]

      for {metadata, public} <- forms do
        assert Cidr.metadata?(metadata), inspect(metadata)
        assert Cidr.private_ip?(metadata), inspect(metadata)
        refute Cidr.metadata?(public), inspect(public)
      end
    end

    test "the metadata endpoints outside link-local, and their embedded forms" do
      assert Cidr.metadata?({100, 100, 100, 200})
      assert Cidr.metadata?({192, 0, 0, 192})
      assert Cidr.metadata?({0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254})
      assert Cidr.metadata?({0x64, 0xFF9B, 0, 0, 0, 0, 0x6464, 0x64C8})
      assert Cidr.metadata?({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x00C0})

      refute Cidr.metadata?({100, 100, 100, 201})
      refute Cidr.metadata?({192, 0, 0, 193})
      refute Cidr.metadata?({0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0255})
    end
  end

  describe "embedded_ipv4/1" do
    test "reads the IPv4 address each standard embedding carries" do
      assert Cidr.embedded_ipv4({0, 0, 0, 0, 0, 0, 0x0A00, 0x0001}) == [{10, 0, 0, 1}]
      assert Cidr.embedded_ipv4({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}) == [{10, 0, 0, 1}]
      assert Cidr.embedded_ipv4({0, 0, 0, 0, 0xFFFF, 0, 0x0A00, 0x0001}) == [{10, 0, 0, 1}]
      assert Cidr.embedded_ipv4({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001}) == [{10, 0, 0, 1}]
      assert Cidr.embedded_ipv4({0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 1}) == [{10, 0, 0, 1}]
    end

    test "reads local-use NAT64 at every placement a prefix within the /48 can use" do
      # 64:ff9b:1:c000:2:21:: at /48, and each other placement of its bits
      assert Cidr.embedded_ipv4({0x64, 0xFF9B, 1, 0xC000, 0x0002, 0x2100, 0, 0}) == [
               {192, 0, 2, 33},
               {0, 2, 33, 0},
               {2, 33, 0, 0},
               {0, 0, 0, 0}
             ]

      assert {192, 0, 2, 33} in Cidr.embedded_ipv4(
               {0x64, 0xFF9B, 1, 0x00C0, 0x0000, 0x0221, 0, 0}
             )

      assert {192, 0, 2, 33} in Cidr.embedded_ipv4(
               {0x64, 0xFF9B, 1, 0, 0x00C0, 0x0002, 0x2100, 0}
             )

      assert {192, 0, 2, 33} in Cidr.embedded_ipv4({0x64, 0xFF9B, 1, 0, 0, 0, 0xC000, 0x0221})
    end

    test "any other address carries none" do
      assert Cidr.embedded_ipv4({10, 0, 0, 1}) == []
      assert Cidr.embedded_ipv4({0x2607, 0xF8B0, 0x4004, 0x800, 0, 0, 0, 0x200E}) == []
      assert Cidr.embedded_ipv4({0x64, 0xFF9B, 0, 1, 0, 0, 0x0A00, 0x0001}) == []
      assert Cidr.embedded_ipv4({0, 0, 0, 0, 1, 0xFFFF, 0x0A00, 0x0001}) == []
    end
  end

  describe "private_ip?/1" do
    test "IPv4 private ranges" do
      assert Cidr.private_ip?({127, 0, 0, 1})
      assert Cidr.private_ip?({10, 0, 0, 1})
      assert Cidr.private_ip?({10, 255, 255, 255})
      assert Cidr.private_ip?({172, 16, 0, 1})
      assert Cidr.private_ip?({172, 31, 255, 255})
      assert Cidr.private_ip?({192, 168, 0, 1})
      assert Cidr.private_ip?({192, 168, 255, 255})
      assert Cidr.private_ip?({169, 254, 169, 254})
      assert Cidr.private_ip?({0, 0, 0, 0})
    end

    test "IPv4 public ranges" do
      refute Cidr.private_ip?({8, 8, 8, 8})
      refute Cidr.private_ip?({1, 1, 1, 1})
      refute Cidr.private_ip?({142, 250, 80, 46})
      refute Cidr.private_ip?({172, 32, 0, 1})
    end

    test "IPv6 loopback" do
      assert Cidr.private_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 unspecified" do
      assert Cidr.private_ip?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "IPv6 unique local (fc00::/7)" do
      assert Cidr.private_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert Cidr.private_ip?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 link-local (fe80::/10)" do
      assert Cidr.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert Cidr.private_ip?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped IPv6 private" do
      # ::ffff:10.0.0.1
      assert Cidr.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      # ::ffff:169.254.169.254
      assert Cidr.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
    end

    test "IPv4 CGNAT (100.64.0.0/10, RFC 6598)" do
      assert Cidr.private_ip?({100, 64, 0, 1})
      assert Cidr.private_ip?({100, 127, 255, 255})
      refute Cidr.private_ip?({100, 63, 255, 255})
      refute Cidr.private_ip?({100, 128, 0, 0})
    end

    test "IPv4 reserved blocks" do
      # 192.0.0.0/24 IETF protocol assignments
      assert Cidr.private_ip?({192, 0, 0, 170})
      refute Cidr.private_ip?({192, 0, 1, 1})
      # 198.18.0.0/15 benchmarking
      assert Cidr.private_ip?({198, 18, 0, 1})
      assert Cidr.private_ip?({198, 19, 255, 255})
      refute Cidr.private_ip?({198, 20, 0, 1})
      # multicast + reserved + broadcast
      assert Cidr.private_ip?({224, 0, 0, 251})
      assert Cidr.private_ip?({239, 255, 255, 255})
      assert Cidr.private_ip?({240, 0, 0, 1})
      assert Cidr.private_ip?({255, 255, 255, 255})
      refute Cidr.private_ip?({223, 255, 255, 255})
    end

    test "NAT64 well-known prefix embeds the IPv4 verdict (64:ff9b::/96)" do
      # 64:ff9b::a9fe:a9fe ≡ 169.254.169.254 behind a NAT64 gateway
      assert Cidr.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE})
      # 64:ff9b::a00:1 ≡ 10.0.0.1
      assert Cidr.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0A00, 0x0001})
      # 64:ff9b::808:808 ≡ 8.8.8.8 — public stays public
      refute Cidr.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "6to4 embeds the IPv4 verdict (2002::/16)" do
      # 2002:a9fe:a9fe:: ≡ 169.254.169.254
      assert Cidr.private_ip?({0x2002, 0xA9FE, 0xA9FE, 0, 0, 0, 0, 1})
      # 2002:808:808:: ≡ 8.8.8.8
      refute Cidr.private_ip?({0x2002, 0x0808, 0x0808, 0, 0, 0, 0, 1})
    end

    test "IPv4-compatible and IPv4-translated forms embed the IPv4 verdict" do
      # ::a00:1 ≡ 10.0.0.1, ::7f00:1 ≡ 127.0.0.1
      assert Cidr.private_ip?({0, 0, 0, 0, 0, 0, 0x0A00, 0x0001})
      assert Cidr.private_ip?({0, 0, 0, 0, 0, 0, 0x7F00, 0x0001})
      refute Cidr.private_ip?({0, 0, 0, 0, 0, 0, 0x0808, 0x0808})
      # ::ffff:0:c0a8:101 ≡ 192.168.1.1
      assert Cidr.private_ip?({0, 0, 0, 0, 0xFFFF, 0, 0xC0A8, 0x0101})
      refute Cidr.private_ip?({0, 0, 0, 0, 0xFFFF, 0, 0x0808, 0x0808})
    end

    test "local-use NAT64 (64:ff9b:1::/48) is private as a whole" do
      assert Cidr.private_ip?({0x64, 0xFF9B, 1, 0, 0, 0, 0x0808, 0x0808})
      assert Cidr.private_ip?({0x64, 0xFF9B, 1, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
      refute Cidr.private_ip?({0x64, 0xFF9B, 2, 0, 0, 0, 0x0808, 0x0808})
    end

    test "IPv6 public" do
      refute Cidr.private_ip?({0x2607, 0xF8B0, 0x4004, 0x800, 0, 0, 0, 0x200E})
    end
  end
end
