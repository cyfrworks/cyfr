# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.CidrTest do
  use ExUnit.Case, async: true

  alias Sanctum.Cidr

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

    test "IPv6 membership — the case the old IPv4-only policy copy silently missed" do
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

  describe "link_local?/1 (strict union — IPv4 169.254/16 AND IPv6 fe80::/10)" do
    test "IPv4 link-local" do
      assert Cidr.link_local?({169, 254, 169, 254})
      refute Cidr.link_local?({169, 253, 0, 1})
      refute Cidr.link_local?({10, 0, 0, 1})
    end

    test "IPv6 fe80::/10 — the case the old policy link-local check omitted" do
      assert Cidr.link_local?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert Cidr.link_local?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
      refute Cidr.link_local?({0xFEC0, 0, 0, 0, 0, 0, 0, 1})
      refute Cidr.link_local?({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped IPv6 link-local" do
      assert Cidr.link_local?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0x0001})
      refute Cidr.link_local?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
    end
  end
end
