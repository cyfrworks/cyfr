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

  @host_api Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
  @external_resource @host_api
  @vectors @host_api |> File.read!() |> Jason.decode!()

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

  test "the credential roster a hop strips is what an attached request refuses, and no more" do
    request = %{
      "call_id" => "AAECAwQFBgcICQoLDA0ODw",
      "connection" => "api_key",
      "method" => "GET",
      "url" => "https://api.example.test/v1",
      "purpose" => "fetch"
    }

    roster =
      Network.credential_headers() ++ Enum.map(Network.credential_headers(), &String.upcase/1)

    for name <- roster do
      assert Network.strip_credentials([{name, "v"}, {"accept", "*/*"}]) == [{"accept", "*/*"}],
             name

      assert Prima.AttachedRequest.read(Map.put(request, "headers", [[name, "v"]])) ==
               {:error, :credential_header_refused},
             name
    end

    # A name that only ends like a credential leaves with no hop to another
    # origin, and is the guest's own on an attached request.
    for name <- ["X-Session-Token", "X-Signing-Key", "X-Client-Secret", "Idempotency-Key"] do
      assert Network.strip_credentials([{name, "v"}]) == [], name

      assert {:ok, _request} =
               Prima.AttachedRequest.read(Map.put(request, "headers", [[name, "v"]]))
    end

    assert {:ok, _request} =
             Prima.AttachedRequest.read(Map.put(request, "headers", [["accept", "*/*"]]))
  end

  test "the framing and override rosters are tests/fixtures/host_api.json's, and each is refused" do
    assert @vectors["framing_headers"] == Network.framing_headers()
    assert @vectors["override_headers"] == Network.override_headers()
    assert @vectors["override_prefixes"] == Network.override_prefixes()

    request = %{
      "call_id" => "AAECAwQFBgcICQoLDA0ODw",
      "connection" => "api_key",
      "method" => "GET",
      "url" => "https://api.example.test/v1",
      "purpose" => "fetch"
    }

    prefixed = Enum.map(@vectors["override_prefixes"], &(&1 <> "anything"))

    for name <- @vectors["framing_headers"] ++ @vectors["override_headers"] ++ prefixed,
        spelled <- [name, String.upcase(name)] do
      assert Network.framing_or_override_header?(spelled), spelled

      assert Prima.AttachedRequest.read(Map.put(request, "headers", [[spelled, "v"]])) ==
               {:error, {:invalid_request, spelled}},
             spelled
    end

    for name <- ["accept", "x-forwarded", "x-hosted", "authorization", nil] do
      refute Network.framing_or_override_header?(name), inspect(name)
    end
  end

  test "a request's Host is its host, an IPv6 literal bracketed, with a port only off the default" do
    for {url, host} <- [
          {"http://api.test/x", "api.test"},
          {"http://api.test:80/x", "api.test"},
          {"https://api.test:443/x", "api.test"},
          {"http://api.test:443/x", "api.test:443"},
          {"https://api.test:8443/x", "api.test:8443"},
          {"HTTPS://Api.Test:8443/x", "Api.Test:8443"},
          {"http://[::1]:8080/x", "[::1]:8080"},
          {"https://[2001:db8::1]/x", "[2001:db8::1]"},
          {"http://127.0.0.1:4000/", "127.0.0.1:4000"}
        ] do
      assert Network.host_header(URI.parse(url)) == host, url
    end

    assert Network.host_header(%URI{scheme: "https", host: "::1", port: 8443}) == "[::1]:8443"
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
