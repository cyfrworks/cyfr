# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.EgressTest do
  @moduledoc """
  A guest's outbound request connects to the address CYFR pinned for it,
  and to nothing else: the relay's service end asks the attempt's host
  for the pin (`Locus.Runtime.HostClient.egress_pin/3`), resolves no name
  itself, and builds the connection to exactly the pinned address with
  the hostname kept for TLS and the fail-closed transport policy set
  (`Locus.Runtime.Egress.connect_options/3`). A metadata address is
  refused even when the host answers one, and a pin names a URL only when
  it names the URL's own scheme, host and port (`Locus.Runtime.Egress.names?/2`).
  Every pin here is the scripted host's, from the table each test sets.
  """

  use ExUnit.Case, async: true

  alias Locus.Runtime.{Egress, HostClient}
  alias Locus.Runtime.Test.ScriptedHost

  setup do
    host = ScriptedHost.start!()
    {:ok, host: host, client: ScriptedHost.attempt!(host).client}
  end

  # The pin the host answers for `url`, and the connection the relay's
  # service end makes for it with `opts`.
  defp pinned(client, url, opts \\ []) do
    {:ok, target} = HostClient.egress_pin(client, url)
    Egress.connect_options(target, URI.parse(url), opts)
  end

  test "a pin is asked of the host, and the connection goes to its address with the hostname kept",
       %{host: host, client: client} do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10"})

    assert {:ok, connection} = pinned(client, "https://public.test:8443/path?q=1")

    assert [%{args: args}] = ScriptedHost.requests(host, "egress_pin")
    assert args == %{"url" => "https://public.test:8443/path?q=1", "purpose" => "fetch"}

    assert connection.ip == "203.0.113.10"
    assert connection.ip_tuple == {203, 0, 113, 10}
    assert connection.uri.host == "public.test"

    opts = connection.req_opts
    assert opts[:url] == "https://203.0.113.10:8443/path?q=1"
    assert opts[:connect_options][:hostname] == "public.test"
    assert opts[:redirect] == false
    assert opts[:retry] == false
    assert opts[:compressed] == false
    assert opts[:decode_body] == false
    assert opts[:receive_timeout] == 30_000
  end

  test "the caller's protocols and timeout ride along, and the socket reads at most 64 KiB at a time",
       %{host: host, client: client} do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10"})

    assert {:ok, %{req_opts: opts}} =
             pinned(client, "http://public.test/",
               protocols: [:http1],
               transport_opts: [verify: :verify_none],
               receive_timeout: 5
             )

    assert opts[:connect_options][:protocols] == [:http1]
    assert opts[:connect_options][:transport_opts] == Egress.transport_opts()
    assert Egress.transport_opts()[:buffer] == 65_536
    assert opts[:receive_timeout] == 5
  end

  test "a family 4 pin is a plain literal, a family 6 pin a bracketed one", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{"dual.test" => "203.0.113.20", "v6only.test" => "2001:db8::30"})

    assert {:ok, %{ip: "203.0.113.20", req_opts: opts}} = pinned(client, "https://dual.test/x")
    assert opts[:url] == "https://203.0.113.20/x"

    assert {:ok, connection} = pinned(client, "https://v6only.test:8080/x")
    assert connection.ip_tuple == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x30}
    assert connection.req_opts[:url] == "https://[2001:db8::30]:8080/x"
    assert connection.req_opts[:connect_options][:hostname] == "v6only.test"

    # An IPv6 literal URL keeps its literal for the connection's identity.
    ScriptedHost.pins(host, %{"2001:db8::40" => "2001:db8::40"})
    assert {:ok, target} = HostClient.egress_pin(client, "http://[2001:db8::40]:8080/x")
    assert target.host == "[2001:db8::40]"

    assert {:ok, %{req_opts: opts}} =
             Egress.connect_options(target, URI.parse("http://[2001:db8::40]:8080/x"), [])

    assert opts[:url] == "http://[2001:db8::40]:8080/x"
  end

  test "the relay sends to exactly the address the pin names, private or not", %{
    host: host,
    client: client
  } do
    # The private-address policy is the host's: whatever it pins, the
    # relay connects to, and to nothing it resolved itself.
    ScriptedHost.pins(host, %{"private.test" => "10.0.0.5", "localhost" => "127.0.0.1"})

    assert {:ok, %{ip: "10.0.0.5", req_opts: opts}} = pinned(client, "http://private.test/")
    assert opts[:url] == "http://10.0.0.5/"
    assert opts[:connect_options][:hostname] == "private.test"

    assert {:ok, %{ip: "127.0.0.1"}} = pinned(client, "http://localhost:4000/")
  end

  test "a metadata address is refused by the relay's connection even when the host pins one", %{
    host: host,
    client: client
  } do
    for ip <- [
          "169.254.169.254",
          "fd00:ec2::254",
          "fe80::1",
          "64:ff9b::a9fe:a9fe",
          "2002:a9fe:a9fe::1"
        ] do
      ScriptedHost.pins(host, %{"metadata.test" => ip})

      assert {:error, :private_ip_blocked, message} =
               pinned(client, "http://metadata.test/latest")

      assert message =~ "metadata IP"
    end
  end

  test "the relay's connection refuses a metadata address whatever pin it is handed" do
    pin = %Prima.PinnedTarget{
      id: "pin_meta",
      ip: "169.254.169.254",
      family: 4,
      scheme: "http",
      port: 80,
      host: "metadata.test",
      expires_at: System.system_time(:millisecond) + 60_000
    }

    uri = %URI{scheme: "http", host: "metadata.test", port: 80, path: "/latest"}

    assert {:error, :private_ip_blocked, message} = Egress.connect_options(pin, uri, [])
    assert message =~ "metadata IP"
  end

  test "a pin names a URL only by its own scheme, host and effective port" do
    pin = %Prima.PinnedTarget{
      id: "pin_public",
      ip: "203.0.113.10",
      family: 4,
      scheme: "https",
      port: 443,
      host: "public.test",
      expires_at: System.system_time(:millisecond) + 30_000
    }

    for {url, named?} <- [
          {"https://public.test/", true},
          {"https://PUBLIC.test:443/case", true},
          {"https://elsewhere.test/", false},
          {"https://public.test:8443/port", false},
          {"http://public.test:443/scheme", false}
        ] do
      assert Egress.names?(pin, URI.parse(url)) == named?, url
    end
  end
end
