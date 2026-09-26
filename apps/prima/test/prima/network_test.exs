# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.NetworkTest do
  @moduledoc """
  An engine connects to the address CYFR pinned for it: `Prima.Network.pin/3`
  under `private_policy: :allow_all` builds the request options for a
  pinned target's address, private or public, keeping the URL's host for
  TLS and the Host header, and still refuses a metadata address. Nothing
  here resolves a name.
  """

  use ExUnit.Case, async: true

  alias Prima.{Network, PinnedTarget}

  defp pinned(url, ip, family) do
    {:ok, uri} = Network.parse_url(url)

    host =
      if family == 6 and match?({:ok, {_, _, _, _, _, _, _, _}}, Prima.Cidr.parse_ip(uri.host)),
        do: "[#{uri.host}]",
        else: uri.host

    pin = %PinnedTarget{
      id: "pin_1",
      ip: ip,
      family: family,
      scheme: uri.scheme,
      port: uri.port,
      host: host,
      expires_at: 1
    }

    assert PinnedTarget.valid?(pin)
    {uri, pin}
  end

  test "a pinned address is connected to exactly, under the URL's own identity" do
    for {url, ip, family, connect_url} <- [
          {"https://api.example.test/v1/items?page=2", "203.0.113.10", 4,
           "https://203.0.113.10/v1/items?page=2"},
          {"http://service.internal:8080/x", "10.1.2.3", 4, "http://10.1.2.3:8080/x"},
          {"https://stream.example.test/events", "2001:db8::20", 6,
           "https://[2001:db8::20]/events"},
          {"http://[2001:db8::20]:8080/events", "2001:db8::20", 6,
           "http://[2001:db8::20]:8080/events"}
        ] do
      {uri, pin} = pinned(url, ip, family)

      assert {:ok, %{req_opts: opts, ip: ^ip}} =
               Network.pin(uri, PinnedTarget.address(pin), private_policy: :allow_all)

      assert opts[:url] == connect_url
      assert opts[:connect_options][:hostname] == uri.host
      assert opts[:redirect] == false and opts[:retry] == false
    end
  end

  test "a metadata address is refused however it was pinned" do
    for {url, ip, family} <- [
          {"http://169.254.169.254/latest/meta-data/", "169.254.169.254", 4},
          {"http://metadata.example.test/", "100.100.100.200", 4},
          {"http://metadata.example.test/", "fd00:ec2::254", 6}
        ] do
      {uri, pin} = pinned(url, ip, family)

      assert {:error, :private_ip_blocked, message} =
               Network.pin(uri, PinnedTarget.address(pin), private_policy: :allow_all)

      assert message =~ "metadata IP"
    end
  end
end
