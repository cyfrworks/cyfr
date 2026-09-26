# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ClientIpTest do
  @moduledoc """
  The trusted hop count `Sanctum.ClientIp` strips is the configured one,
  and nothing else: a missing or malformed count is zero hops, the socket
  peer, never a default that trusts a hop the chain's writer chose.
  """

  # Replaces the proxy trust in the application environment.
  use ExUnit.Case, async: false

  alias Sanctum.ClientIp

  @keys [:trust_x_forwarded_for, :trusted_proxy_hops, :trusted_proxy_cidrs]

  setup do
    originals = for key <- @keys, do: {key, Application.get_env(:sanctum, key)}

    on_exit(fn ->
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:sanctum, key)
        {key, value} -> Application.put_env(:sanctum, key, value)
      end)
    end)

    Enum.each(@keys, &Application.delete_env(:sanctum, &1))
    Application.put_env(:sanctum, :trust_x_forwarded_for, true)
    :ok
  end

  defp conn(remote_ip, xff),
    do: %Plug.Conn{remote_ip: remote_ip, req_headers: [{"x-forwarded-for", xff}]}

  defp connect_info(address, xff),
    do: %{peer_data: %{address: address}, x_headers: [{"x-forwarded-for", xff}]}

  test "with no hop count configured, the trust strips nothing: the socket peer is the client" do
    assert ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8")) == "172.18.0.2"

    assert ClientIp.from_connect_info(connect_info({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8")) ==
             "172.18.0.2"
  end

  test "a hop count that is not a whole number from 0 to 16 is zero hops, never one" do
    for bad <- [-1, 17, 1.0, "1", :one, [1]] do
      Application.put_env(:sanctum, :trusted_proxy_hops, bad)

      assert ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8")) == "172.18.0.2",
             "trusted_proxy_hops=#{inspect(bad)}"
    end
  end

  test "the configured count is the one stripped, up to 16" do
    chain = Enum.map_join(1..17, ", ", &"10.0.0.#{&1}")

    for hops <- [0, 1, 2, 16] do
      Application.put_env(:sanctum, :trusted_proxy_hops, hops)
      expected = if hops == 0, do: "192.0.2.1", else: "10.0.0.#{18 - hops}"
      assert ClientIp.resolve(conn({192, 0, 2, 1}, chain)) == expected, "hops=#{hops}"
    end
  end
end
