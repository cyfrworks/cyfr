# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NetworkPrivatePolicyTest do
  @moduledoc """
  Private egress is a named allowlist, not a deployment mode: with
  `allow_private: :policy` a private address is reachable only when the
  operator listed the host, the address, or a range that contains it.
  """
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:cyfr, :private_egress_targets)

    on_exit(fn ->
      if original,
        do: Application.put_env(:cyfr, :private_egress_targets, original),
        else: Application.delete_env(:cyfr, :private_egress_targets)
    end)

    :ok
  end

  test "an empty allowlist refuses every private target" do
    Application.put_env(:cyfr, :private_egress_targets, [])

    assert {:error, msg} =
             Cyfr.Network.validate_redirect_url("http://127.0.0.1:8001/mcp",
               allow_private: :policy
             )

    assert msg =~ "private IP"
    refute Cyfr.Network.private_allowed?("localhost", {127, 0, 0, 1})
  end

  test "a listed hostname, address or CIDR admits the target" do
    Application.put_env(:cyfr, :private_egress_targets, [
      "MCP-Bridge",
      "10.0.0.0/8",
      "192.168.1.5"
    ])

    assert Cyfr.Network.private_allowed?("mcp-bridge", {172, 18, 0, 3})
    assert Cyfr.Network.private_allowed?("db.internal", {10, 3, 4, 5})
    assert Cyfr.Network.private_allowed?("lights.local", {192, 168, 1, 5})
    refute Cyfr.Network.private_allowed?("other.internal", {192, 168, 1, 6})

    Application.put_env(:cyfr, :private_egress_targets, ["127.0.0.1"])

    assert :ok =
             Cyfr.Network.validate_redirect_url("http://127.0.0.1:8001/mcp",
               allow_private: :policy
             )
  end

  test "link-local is refused whatever the list says; explicit true and false keep their meaning" do
    Application.put_env(:cyfr, :private_egress_targets, ["169.254.0.0/16"])

    assert {:error, msg} =
             Cyfr.Network.validate_redirect_url("http://169.254.169.254/", allow_private: :policy)

    assert msg =~ "link-local"

    Application.put_env(:cyfr, :private_egress_targets, [])
    assert :ok = Cyfr.Network.validate_redirect_url("http://127.0.0.1:1/", allow_private: true)

    assert {:error, _} =
             Cyfr.Network.validate_redirect_url("http://127.0.0.1:1/", allow_private: false)

    assert {:error, _} = Cyfr.Network.validate_redirect_url("http://127.0.0.1:1/")
  end
end
