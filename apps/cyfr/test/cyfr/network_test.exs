defmodule Cyfr.NetworkTest do
  use ExUnit.Case, async: true

  alias Cyfr.Network

  describe "validate_redirect_url/2" do
    test "allows public HTTPS URLs" do
      # Uses a well-known public hostname that resolves to a public IP
      assert :ok = Network.validate_redirect_url("https://storage.googleapis.com/bucket/blob")
    end

    test "allows public HTTP URLs" do
      assert :ok = Network.validate_redirect_url("http://storage.googleapis.com/bucket/blob")
    end

    test "rejects file:// scheme" do
      assert {:error, "blocked URL scheme: file"} =
               Network.validate_redirect_url("file:///etc/passwd")
    end

    test "rejects ftp:// scheme" do
      assert {:error, "blocked URL scheme: ftp"} =
               Network.validate_redirect_url("ftp://evil.com/file")
    end

    test "rejects missing scheme" do
      assert {:error, "missing URL scheme"} =
               Network.validate_redirect_url("//no-scheme.com/path")
    end

    test "rejects missing hostname" do
      assert {:error, "missing hostname"} =
               Network.validate_redirect_url("https:///path-only")
    end

    test "blocks loopback 127.0.0.1" do
      assert {:error, msg} = Network.validate_redirect_url("http://127.0.0.1/metadata")
      assert msg =~ "private IP"
      assert msg =~ "127.0.0.1"
    end

    test "blocks link-local 169.254.169.254 (cloud metadata)" do
      assert {:error, msg} = Network.validate_redirect_url("http://169.254.169.254/latest/meta-data/")
      assert msg =~ "link-local IP"
      assert msg =~ "169.254.169.254"
    end

    test "169.254.x.x always blocked even with allow_private: true" do
      assert {:error, msg} =
               Network.validate_redirect_url("http://169.254.169.254/latest/meta-data/", allow_private: true)
      assert msg =~ "link-local IP"
    end

    test "allow_private: true permits 127.0.0.1" do
      assert :ok = Network.validate_redirect_url("http://127.0.0.1/v2/", allow_private: true)
    end

    test "allow_private: true permits localhost" do
      assert :ok = Network.validate_redirect_url("http://localhost/v2/", allow_private: true)
    end

    test "DNS failure returns error" do
      assert {:error, msg} =
               Network.validate_redirect_url("https://this-domain-definitely-does-not-exist-xyz123.invalid/path")
      assert msg =~ "DNS resolution failed"
    end
  end

  describe "private_ip?/1" do
    test "IPv4 private ranges" do
      assert Network.private_ip?({127, 0, 0, 1})
      assert Network.private_ip?({10, 0, 0, 1})
      assert Network.private_ip?({10, 255, 255, 255})
      assert Network.private_ip?({172, 16, 0, 1})
      assert Network.private_ip?({172, 31, 255, 255})
      assert Network.private_ip?({192, 168, 0, 1})
      assert Network.private_ip?({192, 168, 255, 255})
      assert Network.private_ip?({169, 254, 169, 254})
      assert Network.private_ip?({0, 0, 0, 0})
    end

    test "IPv4 public ranges" do
      refute Network.private_ip?({8, 8, 8, 8})
      refute Network.private_ip?({1, 1, 1, 1})
      refute Network.private_ip?({142, 250, 80, 46})
      refute Network.private_ip?({172, 32, 0, 1})
    end

    test "IPv6 loopback" do
      assert Network.private_ip?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 unspecified" do
      assert Network.private_ip?({0, 0, 0, 0, 0, 0, 0, 0})
    end

    test "IPv6 unique local (fc00::/7)" do
      assert Network.private_ip?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert Network.private_ip?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 link-local (fe80::/10)" do
      assert Network.private_ip?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert Network.private_ip?({0xFEBF, 0, 0, 0, 0, 0, 0, 1})
    end

    test "IPv4-mapped IPv6 private" do
      # ::ffff:10.0.0.1
      assert Network.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      # ::ffff:169.254.169.254
      assert Network.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
    end

    test "IPv6 public" do
      refute Network.private_ip?({0x2607, 0xF8B0, 0x4004, 0x800, 0, 0, 0, 0x200E})
    end
  end
end
