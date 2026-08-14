# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S3ClientIpTest do
  @moduledoc """
  Phase 2 S3: `Sanctum.ClientIp` is the single client-IP resolver applying the
  X-Forwarded-For trust boundary. It NEVER returns nil — a no-IP context
  yields "0.0.0.0", which fails an API-key allowlist *closed*. This closes the
  tincture-path bypass where a nil client_ip silently disabled the allowlist.
  """
  use ExUnit.Case, async: false

  alias Sanctum.ClientIp

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    originals =
      for key <- [:trust_x_forwarded_for, :trusted_proxy_hops, :trusted_proxy_cidrs] do
        {key, Application.get_env(:cyfr, key)}
      end

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:cyfr, key)
        {key, value} -> Application.put_env(:cyfr, key, value)
      end)
    end)

    :ok
  end

  defp conn(remote_ip, xff \\ nil) do
    headers =
      case xff do
        nil -> []
        list when is_list(list) -> Enum.map(list, &{"x-forwarded-for", &1})
        value -> [{"x-forwarded-for", value}]
      end

    %Plug.Conn{remote_ip: remote_ip, req_headers: headers}
  end

  describe "X-Forwarded-For trust boundary" do
    test "XFF is IGNORED by default (spoofing cannot defeat an allowlist)" do
      Application.delete_env(:cyfr, :trust_x_forwarded_for)
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "1.2.3.4")) == "10.0.0.5"
    end

    test "trusted XFF resolves the RIGHTMOST untrusted hop, not the client-claimed left" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      # Chain is [claimed..., appended-by-proxy, socket]; with the default of
      # 1 trusted hop (the socket peer), the proxy-appended entry wins.
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "1.2.3.4, 9.9.9.9")) == "9.9.9.9"
    end

    test "a client-prepended XFF entry cannot spoof the resolved IP" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      # Attacker at 8.8.8.8 sends "X-Forwarded-For: 203.0.113.9"; Caddy appends
      # the peer it saw. The spoofed leftmost entry must never be selected.
      assert ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8")) == "8.8.8.8"
    end

    test "trusted_proxy_hops=2 strips two proxy layers" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      Application.put_env(:cyfr, :trusted_proxy_hops, 2)
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "1.2.3.4, 9.9.9.9, 10.0.0.9")) == "9.9.9.9"
    end

    test "trusted_proxy_hops=0 (trust on, no proxy) resolves the socket peer" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      Application.put_env(:cyfr, :trusted_proxy_hops, 0)
      assert ClientIp.resolve(conn({203, 0, 113, 7}, "1.2.3.4")) == "203.0.113.7"
    end

    test "trusted_proxy_cidrs strips any number of matching trailing hops" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      Application.put_env(:cyfr, :trusted_proxy_cidrs, ["10.0.0.0/8", "172.16.0.0/12"])

      assert ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 10.0.0.9")) == "203.0.113.9"
    end

    test "XFF chains split across multiple header instances are joined" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      assert ClientIp.resolve(conn({10, 0, 0, 5}, ["1.2.3.4", "203.0.113.9"])) == "203.0.113.9"
    end

    test "hop count exceeding the chain falls back to remote_ip" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      Application.put_env(:cyfr, :trusted_proxy_hops, 7)
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "1.2.3.4")) == "10.0.0.5"
    end

    test "trusted but absent/invalid XFF falls back to remote_ip" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      assert ClientIp.resolve(conn({10, 0, 0, 5})) == "10.0.0.5"
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "not-an-ip")) == "10.0.0.5"
    end
  end

  describe "never nil — fail-closed contract" do
    test "a non-tuple / unresolvable remote_ip yields \"0.0.0.0\", not nil" do
      assert ClientIp.resolve(conn(nil)) == "0.0.0.0"
      assert ClientIp.resolve(conn(:bogus)) == "0.0.0.0"
    end

    test "deterministic for a given conn (single SSOT for every caller)" do
      c = conn({203, 0, 113, 7})
      assert ClientIp.resolve(c) == ClientIp.resolve(c)
      assert ClientIp.resolve(c) == "203.0.113.7"
    end
  end

  describe "the closed bypass: allowlist is enforced, not skipped" do
    test "an allowlisted key with an unresolvable IP is REJECTED (was: bypassed)" do
      ctx = Sanctum.TestContext.local()

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{name: "ip-key", ip_allowlist: ["203.0.113.0/24"]})

      # Pre-S3 the tincture path passed client_ip: nil here, and
      # ApiKey.validate skips the allowlist when client_ip is nil → {:ok,_}.
      # Now ClientIp.resolve yields "0.0.0.0", which is not in the allowlist.
      no_ip = ClientIp.resolve(conn(nil))
      assert no_ip == "0.0.0.0"
      assert Sanctum.ApiKey.validate(key, client_ip: no_ip) == {:error, :ip_not_allowed}

      # Sanity: an in-allowlist IP still authenticates.
      assert {:ok, _} =
               Sanctum.ApiKey.validate(key, client_ip: ClientIp.resolve(conn({203, 0, 113, 9})))
    end

    test "a spoofed leftmost XFF entry cannot satisfy the allowlist behind a proxy" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      ctx = Sanctum.TestContext.local()

      {:ok, %{api_key: key}} =
        Sanctum.ApiKey.create(ctx, %{name: "xff-key", ip_allowlist: ["203.0.113.0/24"]})

      # Attacker at 8.8.8.8 claims an allowlisted IP; the proxy appends the
      # real peer. Resolution must pick 8.8.8.8 and the allowlist must reject.
      spoofed = ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8"))
      assert spoofed == "8.8.8.8"
      assert Sanctum.ApiKey.validate(key, client_ip: spoofed) == {:error, :ip_not_allowed}

      # The same topology with a genuinely allowlisted client authenticates.
      real = ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9"))
      assert real == "203.0.113.9"
      assert {:ok, _} = Sanctum.ApiKey.validate(key, client_ip: real)
    end
  end
end
