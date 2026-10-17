# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CidrTest do
  use ExUnit.Case, async: true

  alias Prima.Cidr

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

    test "IPv6 multicast (ff00::/8) is private, and no metadata" do
      assert Cidr.private_ip?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
      assert Cidr.private_ip?({0xFF0E, 0, 0, 0, 0, 0, 0, 0x101})
      assert Cidr.private_ip?({0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
      refute Cidr.metadata?({0xFF02, 0, 0, 0, 0, 0, 0, 1})
      refute Cidr.private_ip?({0xFEFF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 public" do
      refute Cidr.private_ip?({0x2607, 0xF8B0, 0x4004, 0x800, 0, 0, 0, 0x200E})
    end
  end

  describe "address_table/0" do
    test "holds each range of both classes, IPv4 first" do
      %{metadata: metadata, private: private} = Cidr.address_table()

      assert Enum.take(metadata, 5) ==
               ~w(169.254.0.0/16 100.100.100.200/32 192.0.0.192/32 fe80::/10 fd00:ec2::254/128)

      assert Enum.take(private, 15) ==
               ~w(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 0.0.0.0/8
                  100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
                  fc00::/7 fe80::/10 64:ff9b:1::/48 ff00::/8)

      assert Enum.reject(metadata ++ private, &String.contains?(&1, ":")) ==
               Enum.take(metadata, 3) ++ Enum.take(private, 11)

      # Embedded forms: NAT64 of 10.0.0.0/8, Teredo's inverted client of it,
      # ISATAP of 192.0.0.192.
      assert "64:ff9b::a00:0/104" in private
      assert "2001::f500:0/ffff:ffff::ff00:0" in private
      assert "::5efe:c000:c0/::ffff:ffff:ffff:ffff" in metadata
      # A row another row of its class contains is left out: ::1 sits in
      # ::/104, the IPv4-compatible form of 0.0.0.0/8.
      refute "::1/128" in private
      assert "::/104" in private
    end

    test "an address is in a class exactly when it falls in one of the class's rows" do
      %{metadata: metadata, private: private} = Cidr.address_table()
      metadata = Enum.map(metadata, &table_row/1)
      private = Enum.map(private, &table_row/1)
      :rand.seed(:exsss, {7, 11, 13})

      samples =
        Enum.flat_map(metadata ++ private, &near/1) ++
          for(_ <- 1..3000, do: random_ip(32)) ++ for(_ <- 1..3000, do: random_ip(128))

      for {width, bits} <- samples do
        ip = to_ip(width, bits)
        assert Cidr.metadata?(ip) == in_table?(metadata, width, bits), inspect(ip)
        assert Cidr.private_ip?(ip) == in_table?(private, width, bits), inspect(ip)
      end
    end
  end

  describe "embedded_ipv4/1 under several embeddings" do
    test "reads each embedding an address matches" do
      # 2001:0:808:808::5efe:a00:1, Teredo (server 8.8.8.8, client
      # 245.255.255.254 inverted) and ISATAP (10.0.0.1)
      assert Cidr.embedded_ipv4({0x2001, 0, 0x0808, 0x0808, 0, 0x5EFE, 0x0A00, 0x0001}) ==
               [{8, 8, 8, 8}, {245, 255, 255, 254}, {10, 0, 0, 1}]

      assert Cidr.private_ip?({0x2002, 0x0808, 0x0808, 0, 0x200, 0x5EFE, 0xA9FE, 0xA9FE})
      assert Cidr.metadata?({0x2002, 0x0808, 0x0808, 0, 0x200, 0x5EFE, 0xA9FE, 0xA9FE})
    end
  end

  # A row of the table as {width, value, mask}, parsed here rather than by
  # the module under test.
  defp table_row(row) do
    [address, suffix] = String.split(row, "/")
    {width, value} = parse(address)

    mask =
      case Integer.parse(suffix) do
        {length, ""} -> Bitwise.bsl(Bitwise.bsl(1, length) - 1, width - length)
        _ -> suffix |> parse() |> elem(1)
      end

    {width, value, mask}
  end

  defp parse(text) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(text))
    size = if tuple_size(ip) == 4, do: 8, else: 16

    {tuple_size(ip) * size,
     ip |> Tuple.to_list() |> Enum.reduce(0, &(Bitwise.bsl(&2, size) + &1))}
  end

  defp in_table?(rows, width, bits),
    do:
      Enum.any?(rows, fn {w, value, mask} -> w == width and Bitwise.band(bits, mask) == value end)

  # Addresses at a row's edges and inside it, and each just outside it:
  # the row's value with one fixed bit flipped.
  defp near({width, value, mask}) do
    free = Bitwise.bxor(mask, Bitwise.bsl(1, width) - 1)

    inside =
      [value, Bitwise.bor(value, free)] ++
        for(_ <- 1..8, do: Bitwise.bor(value, Bitwise.band(random_bits(width), free)))

    outside =
      for bit <- 0..(width - 1),
          Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0,
          do:
            Bitwise.bxor(
              Bitwise.bor(value, Bitwise.band(random_bits(width), free)),
              Bitwise.bsl(1, bit)
            )

    Enum.map(inside ++ outside, &{width, &1})
  end

  defp random_ip(width), do: {width, random_bits(width)}
  defp random_bits(width), do: :rand.uniform(Bitwise.bsl(1, width)) - 1

  defp to_ip(32, bits),
    do: List.to_tuple(for(i <- 3..0//-1, do: Bitwise.band(Bitwise.bsr(bits, i * 8), 0xFF)))

  defp to_ip(128, bits),
    do: List.to_tuple(for(i <- 7..0//-1, do: Bitwise.band(Bitwise.bsr(bits, i * 16), 0xFFFF)))
end
