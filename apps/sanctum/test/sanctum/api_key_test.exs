defmodule Sanctum.ApiKeyTest do
  use ExUnit.Case, async: false

  alias Sanctum.ApiKey
  alias Sanctum.Context

  @public_prefix "cyfr_pk_"
  @secret_prefix "cyfr_sk_"
  @admin_prefix "cyfr_ak_"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    {:ok, ctx: Context.local()}
  end

  describe "create/2" do
    test "creates a new API key with proper format (default public type)", %{ctx: ctx} do
      {:ok, result} = ApiKey.create(ctx, %{name: "test-key", scope: ["execution"]})

      assert result.name == "test-key"
      assert result.type == :public
      assert String.starts_with?(result.key, @public_prefix)
      assert result.scope == ["execution"]
      assert result.created_at != nil
    end

    test "creates public key with explicit type", %{ctx: ctx} do
      {:ok, result} = ApiKey.create(ctx, %{name: "public-key", type: :public, scope: []})

      assert result.type == :public
      assert String.starts_with?(result.key, @public_prefix)
    end

    test "creates secret key", %{ctx: ctx} do
      {:ok, result} = ApiKey.create(ctx, %{name: "secret-key", type: :secret, scope: []})

      assert result.type == :secret
      assert String.starts_with?(result.key, @secret_prefix)
    end

    test "creates admin key", %{ctx: ctx} do
      {:ok, result} = ApiKey.create(ctx, %{name: "admin-key", type: :admin, scope: []})

      assert result.type == :admin
      assert String.starts_with?(result.key, @admin_prefix)
    end

    test "returns error for invalid key type", %{ctx: ctx} do
      assert {:error, {:invalid_key_type, :invalid}} =
               ApiKey.create(ctx, %{name: "bad-key", type: :invalid, scope: []})
    end

    test "generates unique keys", %{ctx: ctx} do
      {:ok, r1} = ApiKey.create(ctx, %{name: "key1", scope: []})
      {:ok, r2} = ApiKey.create(ctx, %{name: "key2", scope: []})

      assert r1.key != r2.key
    end

    test "returns error for duplicate name", %{ctx: ctx} do
      {:ok, _} = ApiKey.create(ctx, %{name: "duplicate", scope: []})
      assert {:error, :already_exists} = ApiKey.create(ctx, %{name: "duplicate", scope: []})
    end

    test "returns error without name", %{ctx: ctx} do
      assert {:error, "name is required"} = ApiKey.create(ctx, %{scope: []})
    end

    test "creates key with rate limit", %{ctx: ctx} do
      {:ok, result} = ApiKey.create(ctx, %{
        name: "limited-key",
        scope: ["execution"],
        rate_limit: "100/1m"
      })

      assert result.name == "limited-key"
    end
  end

  describe "get/2" do
    test "retrieves key by name with redacted value", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{name: "test-key", scope: ["execution"]})
      {:ok, retrieved} = ApiKey.get(ctx, "test-key")

      assert retrieved.name == "test-key"
      assert retrieved.type == :public
      assert String.ends_with?(retrieved.key_prefix, "...")
      assert String.starts_with?(retrieved.key_prefix, @public_prefix)
      # Full key should not be returned
      refute retrieved.key_prefix == created.key
    end

    test "retrieves secret key with correct type", %{ctx: ctx} do
      {:ok, _created} = ApiKey.create(ctx, %{name: "secret-key", type: :secret, scope: []})
      {:ok, retrieved} = ApiKey.get(ctx, "secret-key")

      assert retrieved.type == :secret
      assert String.starts_with?(retrieved.key_prefix, @secret_prefix)
    end

    test "returns error for non-existent key", %{ctx: ctx} do
      assert {:error, :not_found} = ApiKey.get(ctx, "nonexistent")
    end
  end

  describe "list/1" do
    test "returns empty list when no keys exist", %{ctx: ctx} do
      {:ok, keys} = ApiKey.list(ctx)
      assert keys == []
    end

    test "returns all non-revoked keys", %{ctx: ctx} do
      ApiKey.create(ctx, %{name: "key1", scope: []})
      ApiKey.create(ctx, %{name: "key2", scope: []})
      ApiKey.create(ctx, %{name: "key3", scope: []})

      {:ok, keys} = ApiKey.list(ctx)

      assert length(keys) == 3
      names = Enum.map(keys, & &1.name)
      assert "key1" in names
      assert "key2" in names
      assert "key3" in names
    end

    test "excludes revoked keys", %{ctx: ctx} do
      ApiKey.create(ctx, %{name: "active", scope: []})
      ApiKey.create(ctx, %{name: "revoked", scope: []})
      ApiKey.revoke(ctx, "revoked")

      {:ok, keys} = ApiKey.list(ctx)

      assert length(keys) == 1
      assert hd(keys).name == "active"
    end

    test "returns keys sorted by creation time", %{ctx: ctx} do
      ApiKey.create(ctx, %{name: "first", scope: []})
      :timer.sleep(10)
      ApiKey.create(ctx, %{name: "second", scope: []})

      {:ok, keys} = ApiKey.list(ctx)

      names = Enum.map(keys, & &1.name)
      assert names == ["first", "second"]
    end
  end

  describe "revoke/2" do
    test "revokes an existing key", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{name: "to-revoke", scope: []})

      assert :ok = ApiKey.revoke(ctx, "to-revoke")

      # Validate should fail
      assert {:error, :revoked} = ApiKey.validate(created.key)
    end

    test "returns error for non-existent key", %{ctx: ctx} do
      assert {:error, :not_found} = ApiKey.revoke(ctx, "nonexistent")
    end
  end

  describe "rotate/2" do
    test "generates new key value preserving type", %{ctx: ctx} do
      {:ok, original} = ApiKey.create(ctx, %{name: "rotating", scope: ["execution"]})
      {:ok, rotated} = ApiKey.rotate(ctx, "rotating")

      assert rotated.name == "rotating"
      assert rotated.type == :public
      assert rotated.key != original.key
      assert String.starts_with?(rotated.key, @public_prefix)
      assert rotated.rotated_at != nil
    end

    test "preserves secret key type on rotation", %{ctx: ctx} do
      {:ok, _original} = ApiKey.create(ctx, %{name: "secret-rotating", type: :secret, scope: []})
      {:ok, rotated} = ApiKey.rotate(ctx, "secret-rotating")

      assert rotated.type == :secret
      assert String.starts_with?(rotated.key, @secret_prefix)
    end

    test "preserves admin key type on rotation", %{ctx: ctx} do
      {:ok, _original} = ApiKey.create(ctx, %{name: "admin-rotating", type: :admin, scope: []})
      {:ok, rotated} = ApiKey.rotate(ctx, "admin-rotating")

      assert rotated.type == :admin
      assert String.starts_with?(rotated.key, @admin_prefix)
    end

    test "old key no longer works after rotation", %{ctx: ctx} do
      {:ok, original} = ApiKey.create(ctx, %{name: "rotating", scope: []})
      {:ok, _rotated} = ApiKey.rotate(ctx, "rotating")

      assert {:error, :invalid_key} = ApiKey.validate(original.key)
    end

    test "new key works after rotation", %{ctx: ctx} do
      {:ok, _original} = ApiKey.create(ctx, %{name: "rotating", scope: ["execution"]})
      {:ok, rotated} = ApiKey.rotate(ctx, "rotating")

      {:ok, validated} = ApiKey.validate(rotated.key)
      assert validated.name == "rotating"
      assert validated.scope == ["execution"]
    end

    test "returns error for non-existent key", %{ctx: ctx} do
      assert {:error, :not_found} = ApiKey.rotate(ctx, "nonexistent")
    end
  end

  describe "validate/1" do
    test "validates active key and returns metadata with type", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{
        name: "valid-key",
        scope: ["execution", "read"],
        rate_limit: "50/1m"
      })

      {:ok, validated} = ApiKey.validate(created.key)

      assert validated.name == "valid-key"
      assert validated.type == :public
      assert validated.scope == ["execution", "read"]
      assert validated.rate_limit == "50/1m"
    end

    test "validates secret key and returns correct type", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{name: "secret-valid", type: :secret, scope: []})

      {:ok, validated} = ApiKey.validate(created.key)

      assert validated.type == :secret
    end

    test "validates admin key and returns correct type", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{name: "admin-valid", type: :admin, scope: []})

      {:ok, validated} = ApiKey.validate(created.key)

      assert validated.type == :admin
    end

    test "detects key type from prefix", %{ctx: ctx} do
      {:ok, pk} = ApiKey.create(ctx, %{name: "pk", type: :public, scope: []})
      {:ok, sk} = ApiKey.create(ctx, %{name: "sk", type: :secret, scope: []})
      {:ok, ak} = ApiKey.create(ctx, %{name: "ak", type: :admin, scope: []})

      {:ok, pk_val} = ApiKey.validate(pk.key)
      {:ok, sk_val} = ApiKey.validate(sk.key)
      {:ok, ak_val} = ApiKey.validate(ak.key)

      assert pk_val.type == :public
      assert sk_val.type == :secret
      assert ak_val.type == :admin
    end

    test "returns error for invalid key format", %{ctx: _ctx} do
      assert {:error, :invalid_key_format} = ApiKey.validate("invalid_key")
    end

    test "returns error for key with unknown prefix", %{ctx: _ctx} do
      assert {:error, :invalid_key_format} = ApiKey.validate("cyfr_zz_abc123456789012345678901")
    end

    test "returns error for non-existent key", %{ctx: _ctx} do
      fake_key = @public_prefix <> "nonexistent12345678901234"
      assert {:error, :invalid_key} = ApiKey.validate(fake_key)
    end

    test "returns error for revoked key", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{name: "revoked-key", scope: []})
      ApiKey.revoke(ctx, "revoked-key")

      assert {:error, :revoked} = ApiKey.validate(created.key)
    end
  end

  describe "IP allowlist" do
    test "creates key with IP allowlist", %{ctx: ctx} do
      {:ok, result} = ApiKey.create(ctx, %{
        name: "admin-with-ip",
        type: :admin,
        scope: [],
        ip_allowlist: ["192.168.1.0/24", "10.0.0.1"]
      })

      assert result.name == "admin-with-ip"
      assert result.type == :admin
    end

    test "validate allows key without IP check when no allowlist", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{name: "no-ip-key", scope: []})

      {:ok, validated} = ApiKey.validate(created.key)
      assert validated.name == "no-ip-key"

      # Also works with explicit IP
      {:ok, validated2} = ApiKey.validate(created.key, client_ip: "1.2.3.4")
      assert validated2.name == "no-ip-key"
    end

    test "validate allows matching IP in allowlist", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{
        name: "ip-allowed-key",
        type: :admin,
        scope: [],
        ip_allowlist: ["192.168.1.10", "10.0.0.0/8"]
      })

      # Exact match
      {:ok, validated1} = ApiKey.validate(created.key, client_ip: "192.168.1.10")
      assert validated1.name == "ip-allowed-key"

      # CIDR match
      {:ok, validated2} = ApiKey.validate(created.key, client_ip: "10.255.255.255")
      assert validated2.name == "ip-allowed-key"
    end

    test "validate rejects non-matching IP", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{
        name: "ip-restricted-key",
        type: :admin,
        scope: [],
        ip_allowlist: ["192.168.1.0/24"]
      })

      assert {:error, :ip_not_allowed} = ApiKey.validate(created.key, client_ip: "10.0.0.1")
    end

    test "validate without client_ip bypasses IP check", %{ctx: ctx} do
      {:ok, created} = ApiKey.create(ctx, %{
        name: "ip-key-no-check",
        type: :admin,
        scope: [],
        ip_allowlist: ["192.168.1.0/24"]
      })

      # Without client_ip, IP check is bypassed
      {:ok, validated} = ApiKey.validate(created.key)
      assert validated.name == "ip-key-no-check"
    end

    test "ip_allowlist is included in list output", %{ctx: ctx} do
      ApiKey.create(ctx, %{
        name: "key-with-ips",
        scope: [],
        ip_allowlist: ["192.168.1.0/24"]
      })

      {:ok, keys} = ApiKey.list(ctx)
      key = Enum.find(keys, &(&1.name == "key-with-ips"))

      assert key.ip_allowlist == ["192.168.1.0/24"]
    end
  end

  describe "ip_allowed?/2" do
    test "exact IP match" do
      assert ApiKey.ip_allowed?("192.168.1.10", ["192.168.1.10"])
      refute ApiKey.ip_allowed?("192.168.1.11", ["192.168.1.10"])
    end

    test "CIDR /24 match" do
      assert ApiKey.ip_allowed?("192.168.1.0", ["192.168.1.0/24"])
      assert ApiKey.ip_allowed?("192.168.1.255", ["192.168.1.0/24"])
      refute ApiKey.ip_allowed?("192.168.2.1", ["192.168.1.0/24"])
    end

    test "CIDR /8 match" do
      assert ApiKey.ip_allowed?("10.0.0.1", ["10.0.0.0/8"])
      assert ApiKey.ip_allowed?("10.255.255.255", ["10.0.0.0/8"])
      refute ApiKey.ip_allowed?("11.0.0.1", ["10.0.0.0/8"])
    end

    test "CIDR /32 match (single IP)" do
      assert ApiKey.ip_allowed?("192.168.1.10", ["192.168.1.10/32"])
      refute ApiKey.ip_allowed?("192.168.1.11", ["192.168.1.10/32"])
    end

    test "multiple patterns in allowlist" do
      allowlist = ["192.168.1.0/24", "10.0.0.0/8", "172.16.0.1"]

      assert ApiKey.ip_allowed?("192.168.1.50", allowlist)
      assert ApiKey.ip_allowed?("10.20.30.40", allowlist)
      assert ApiKey.ip_allowed?("172.16.0.1", allowlist)
      refute ApiKey.ip_allowed?("8.8.8.8", allowlist)
    end

    test "empty allowlist rejects all" do
      refute ApiKey.ip_allowed?("192.168.1.10", [])
    end

    test "IPv6 exact match" do
      assert ApiKey.ip_allowed?("2001:db8::1", ["2001:db8::1"])
      refute ApiKey.ip_allowed?("2001:db8::2", ["2001:db8::1"])
    end

    test "IPv6 CIDR /64 match" do
      assert ApiKey.ip_allowed?("2001:db8:85a3::1", ["2001:db8:85a3::/64"])
      assert ApiKey.ip_allowed?("2001:db8:85a3::ffff:ffff:ffff:ffff", ["2001:db8:85a3::/64"])
      refute ApiKey.ip_allowed?("2001:db8:85a4::1", ["2001:db8:85a3::/64"])
    end

    test "IPv6 CIDR /48 match" do
      assert ApiKey.ip_allowed?("2001:db8:abcd::1", ["2001:db8:abcd::/48"])
      assert ApiKey.ip_allowed?("2001:db8:abcd:ffff::1", ["2001:db8:abcd::/48"])
      refute ApiKey.ip_allowed?("2001:db8:abce::1", ["2001:db8:abcd::/48"])
    end

    test "IPv6 loopback" do
      assert ApiKey.ip_allowed?("::1", ["::1"])
      refute ApiKey.ip_allowed?("::2", ["::1"])
    end

    test "mixed IPv4 and IPv6 allowlist" do
      allowlist = ["192.168.1.0/24", "2001:db8::/32"]

      assert ApiKey.ip_allowed?("192.168.1.50", allowlist)
      assert ApiKey.ip_allowed?("2001:db8:abcd::1", allowlist)
      refute ApiKey.ip_allowed?("10.0.0.1", allowlist)
      refute ApiKey.ip_allowed?("2001:db9::1", allowlist)
    end
  end

  describe "sequential operations" do
    test "sequential key operations succeed", %{ctx: ctx} do
      for i <- 1..3 do
        {:ok, _} = ApiKey.create(ctx, %{name: "seq-key-#{i}", scope: []})
      end

      {:ok, keys} = ApiKey.list(ctx)
      names = Enum.map(keys, & &1.name)

      for i <- 1..3 do
        assert "seq-key-#{i}" in names
      end
    end
  end
end
