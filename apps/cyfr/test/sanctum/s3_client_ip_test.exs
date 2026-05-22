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

    original = Application.get_env(:cyfr, :trust_x_forwarded_for)

    on_exit(fn ->
      if original == nil,
        do: Application.delete_env(:cyfr, :trust_x_forwarded_for),
        else: Application.put_env(:cyfr, :trust_x_forwarded_for, original)
    end)

    :ok
  end

  defp conn(remote_ip, xff \\ nil) do
    headers = if xff, do: [{"x-forwarded-for", xff}], else: []
    %Plug.Conn{remote_ip: remote_ip, req_headers: headers}
  end

  describe "X-Forwarded-For trust boundary" do
    test "XFF is IGNORED by default (spoofing cannot defeat an allowlist)" do
      Application.delete_env(:cyfr, :trust_x_forwarded_for)
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "1.2.3.4")) == "10.0.0.5"
    end

    test "XFF is honored only when explicitly trusted" do
      Application.put_env(:cyfr, :trust_x_forwarded_for, true)
      assert ClientIp.resolve(conn({10, 0, 0, 5}, "1.2.3.4, 9.9.9.9")) == "1.2.3.4"
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

      {:ok, %{key: key}} =
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
  end
end
