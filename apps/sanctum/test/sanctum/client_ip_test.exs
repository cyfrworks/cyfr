# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ClientIpTest do
  @moduledoc """
  Whose forwarded headers `Sanctum.ClientIp` reads, and how many hops it
  strips.

  The listener that accepted a request decides: a forwarded header is read
  on the proxy listener alone, and only from the proxies the home's reach
  trusts, by address or by a hop count; on the loopback listener, and on a
  request no listener tagged, the client is the socket peer whatever the
  header says. A socket's `connect_info` carries the same decision through
  the tag header its listener set, and a tag a client could have written,
  a missing, duplicated or unknown one, reads as no listener. A missing or
  malformed count is zero hops, the socket peer, never a default that
  trusts a hop the chain's writer chose.

  Tags are put here as the listeners put them (`put_ingress/2`); the real
  listeners' tagging is `CyfrWeb.IngressTest`'s.
  """

  # Replaces the proxy trust in the application environment.
  use ExUnit.Case, async: false

  alias Sanctum.ClientIp

  setup do
    original = Application.fetch_env(:sanctum, :proxy_trust)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:sanctum, :proxy_trust, value)
        :error -> Application.delete_env(:sanctum, :proxy_trust)
      end
    end)

    Application.put_env(:sanctum, :proxy_trust, {:cidrs, ["172.16.234.3", "172.16.234.4"]})
    :ok
  end

  defp conn(remote_ip, xff, ingress \\ :proxy) do
    conn = %Plug.Conn{remote_ip: remote_ip, req_headers: [{"x-forwarded-for", xff}]}
    if ingress, do: ClientIp.put_ingress(conn, ingress), else: conn
  end

  defp connect_info(address, xff, tags) do
    %{
      peer_data: %{address: address},
      x_headers: [{"x-forwarded-for", xff} | Enum.map(tags, &{"x-cyfr-ingress", &1})]
    }
  end

  # Tailscale Serve at .4 replaced the client's header with the tailnet
  # peer it saw; the client wrote nothing the chain keeps.
  @serve {172, 16, 234, 4}
  @untrusted {172, 16, 234, 9}
  @forged "198.51.100.7, 100.101.102.103"

  describe "the proxy listener" do
    test "reads a trusted proxy's header: the hop it appended is the client" do
      assert ClientIp.resolve(conn(@serve, @forged)) == "100.101.102.103"
    end

    test "a peer outside the trusted proxies is the client, whatever it forwards" do
      assert ClientIp.resolve(conn(@untrusted, @forged)) == "172.16.234.9"
    end

    test "under a hop count strips that many hops, and trusts nothing in a local home" do
      Application.put_env(:sanctum, :proxy_trust, {:hops, 1})
      assert ClientIp.resolve(conn(@untrusted, @forged)) == "100.101.102.103"

      Application.put_env(:sanctum, :proxy_trust, :none)
      assert ClientIp.resolve(conn(@serve, @forged)) == "172.16.234.4"
    end
  end

  describe "the loopback listener and a request no listener tagged" do
    test "never read a forwarded header, from a trusted proxy's address or any other" do
      for peer <- [@serve, @untrusted, {127, 0, 0, 1}], ingress <- [:loopback, nil] do
        assert ClientIp.resolve(conn(peer, @forged, ingress)) == :inet.ntoa(peer) |> to_string(),
               "#{inspect(ingress)} from #{inspect(peer)}"
      end
    end

    test "a hop count trusts nothing there either" do
      Application.put_env(:sanctum, :proxy_trust, {:hops, 2})

      for ingress <- [:loopback, nil] do
        assert ClientIp.resolve(conn({127, 0, 0, 1}, @forged, ingress)) == "127.0.0.1"
      end
    end
  end

  describe "the tag" do
    test "is the listener's, replacing every copy of the header the client sent" do
      sent = %Plug.Conn{
        req_headers: [
          {"x-cyfr-ingress", "loopback"},
          {"accept", "*/*"},
          {"X-Cyfr-Ingress", "loopback"}
        ]
      }

      tagged = ClientIp.put_ingress(sent, :proxy)
      assert ClientIp.ingress(tagged) == :proxy
      assert tagged.req_headers == [{"x-cyfr-ingress", "proxy"}, {"accept", "*/*"}]

      # Tagged again, as no listener does, the last tag is the one.
      assert ClientIp.put_ingress(tagged, :loopback).req_headers ==
               [{"x-cyfr-ingress", "loopback"}, {"accept", "*/*"}]
    end

    test "a conn no listener tagged has no ingress, whatever header it carries" do
      conn = %Plug.Conn{req_headers: [{"x-cyfr-ingress", "loopback"}]}
      assert ClientIp.ingress(conn) == nil
      assert ClientIp.ingress(%Plug.Conn{private: %{cyfr_ingress: :elsewhere}}) == nil
    end
  end

  describe "the socket path" do
    test "reads the listener's one tag as resolve/1 reads the conn's" do
      assert ClientIp.from_connect_info(connect_info(@serve, @forged, ["proxy"])) ==
               "100.101.102.103"

      assert ClientIp.from_connect_info(connect_info(@untrusted, @forged, ["proxy"])) ==
               "172.16.234.9"

      assert ClientIp.from_connect_info(connect_info(@serve, @forged, ["loopback"])) ==
               "172.16.234.4"

      assert ClientIp.ingress_from_connect_info(connect_info(@serve, @forged, ["proxy"])) ==
               :proxy

      assert ClientIp.ingress_from_connect_info(connect_info(@serve, @forged, ["loopback"])) ==
               :loopback
    end

    test "a missing, duplicated or unknown tag is no listener, and no header is read" do
      for tags <- [[], ["proxy", "proxy"], ["loopback", "proxy"], ["Proxy"], ["edge"]] do
        info = connect_info(@serve, @forged, tags)
        assert ClientIp.ingress_from_connect_info(info) == nil, inspect(tags)
        assert ClientIp.from_connect_info(info) == "172.16.234.4", inspect(tags)
      end

      assert ClientIp.ingress_from_connect_info(%{}) == nil
      assert ClientIp.from_connect_info(%{}) == "0.0.0.0"
    end
  end

  describe "the hop count" do
    setup do
      Application.put_env(:sanctum, :proxy_trust, {:hops, 1})
      :ok
    end

    test "a hop count that is not a whole number from 0 to 16 is zero hops, never one" do
      for bad <- [-1, 17, 1.0, "1", :one, [1]] do
        Application.put_env(:sanctum, :proxy_trust, {:hops, bad})

        assert ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8")) == "172.18.0.2",
               "hops=#{inspect(bad)}"
      end

      for malformed <- [nil, true, {:hops}, {:cidrs, "10.0.0.0/8"}, [hops: 1]] do
        Application.put_env(:sanctum, :proxy_trust, malformed)

        assert ClientIp.resolve(conn({172, 18, 0, 2}, "203.0.113.9, 8.8.8.8")) == "172.18.0.2",
               "proxy_trust=#{inspect(malformed)}"
      end
    end

    test "the configured count is the one stripped, up to 16" do
      chain = Enum.map_join(1..17, ", ", &"10.0.0.#{&1}")

      for hops <- [0, 1, 2, 16] do
        Application.put_env(:sanctum, :proxy_trust, {:hops, hops})
        expected = if hops == 0, do: "192.0.2.1", else: "10.0.0.#{18 - hops}"
        assert ClientIp.resolve(conn({192, 0, 2, 1}, chain)) == expected, "hops=#{hops}"
      end
    end
  end
end
