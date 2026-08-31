# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.EndpointSocketTest do
  @moduledoc """
  Pins what the `/live` socket is told about its caller.

  The LiveView socket is handled by `EmissaryWeb.Endpoint` before the
  router (`router.ex` says so where it explains why `PrismWeb.LiveAuth`
  exists), so it passes no plug at all — not `MCPRateLimit`, not
  `AuthRateLimit`. A LiveView that starts an anonymous device flow
  (`PrismWeb.LoginLive`, `PrismWeb.RegistryLive`) is therefore the only
  thing standing between one address and the server-wide sign-in budget,
  and `Sanctum.ClientIp.from_connect_info/1` can only resolve an address
  the socket was configured to carry.

  This cannot be asserted from a LiveView test: `Phoenix.LiveViewTest`
  builds `connect_info` from the test conn rather than from this
  declaration, so a socket that carries nothing still resolves an address
  under test and fails only in production. Hence a direct assertion on
  `__sockets__/0`.
  """

  use ExUnit.Case, async: true

  @required [:peer_data, :x_headers]

  test "the /live socket carries the connect_info ClientIp needs, on both transports" do
    {"/live", Phoenix.LiveView.Socket, opts} =
      Enum.find(EmissaryWeb.Endpoint.__sockets__(), &match?({"/live", _, _}, &1))

    for transport <- [:websocket, :longpoll] do
      connect_info = opts |> Keyword.fetch!(transport) |> Keyword.fetch!(:connect_info)

      missing = @required -- connect_info

      assert missing == [],
             """
             The /live #{transport} transport does not carry #{inspect(missing)}.

             Without it `Sanctum.ClientIp.from_connect_info/1` answers
             "0.0.0.0" for every console visitor, so the anonymous device
             flows on this socket share one bucket and a single caller can
             deny sign-in to everyone. LiveView tests will NOT catch this.
             """

      assert Keyword.has_key?(connect_info, :session),
             "the /live #{transport} transport must still carry the session"
    end
  end
end
