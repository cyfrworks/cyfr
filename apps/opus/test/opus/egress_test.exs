# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.EgressTest do
  @moduledoc """
  A guest's outbound request connects to the address CYFR pinned for it,
  and to nothing else: the engine asks its attempt's host for the pin,
  resolves no name itself, and builds the connection to exactly the
  pinned address with the hostname kept for TLS and the fail-closed
  transport policy set. A metadata address is refused even when the host
  answers one; a pin that names another target than the URL is refused;
  the host's own refusals are answered as the guest's typed errors, marked
  as the host's. A pin is reused for the same attempt, purpose and target
  until its `expires_at`, and asked for again after it. Every pin here is
  the scripted host's, from the table each test sets.
  """

  use ExUnit.Case, async: true

  alias Opus.Egress
  alias Opus.Test.ScriptedHost

  setup do
    host = ScriptedHost.start!()
    {:ok, host: host, client: ScriptedHost.attempt!(host).client}
  end

  test "a pin is asked of the host, and the connection goes to its address with the hostname kept",
       %{host: host, client: client} do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10"})

    assert {:ok, pinned} = Egress.pin(client, "https://public.test:8443/path?q=1")

    assert [%{args: args}] = ScriptedHost.requests(host, "egress_pin")
    assert args == %{"url" => "https://public.test:8443/path?q=1", "purpose" => "fetch"}

    assert pinned.ip == "203.0.113.10"
    assert pinned.ip_tuple == {203, 0, 113, 10}
    assert pinned.uri.host == "public.test"
    assert pinned.target.host == "public.test"
    assert pinned.from == nil

    assert pinned.req_opts[:url] == "https://203.0.113.10:8443/path?q=1"
    assert pinned.req_opts[:connect_options][:hostname] == "public.test"
    assert pinned.req_opts[:redirect] == false
    assert pinned.req_opts[:retry] == false
    assert pinned.req_opts[:compressed] == false
    assert pinned.req_opts[:decode_body] == false
    assert pinned.req_opts[:receive_timeout] == 30_000
  end

  test "the caller's protocols, transport options and timeout ride along", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10"})

    assert {:ok, %{req_opts: opts}} =
             Egress.pin(client, "http://public.test/",
               protocols: [:http1],
               transport_opts: [verify: :verify_none],
               receive_timeout: 5
             )

    assert opts[:connect_options][:protocols] == [:http1]
    assert opts[:connect_options][:transport_opts] == [verify: :verify_none]
    assert opts[:receive_timeout] == 5
  end

  test "a family 4 pin is a plain literal, a family 6 pin a bracketed one", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{"dual.test" => "203.0.113.20", "v6only.test" => "2001:db8::30"})

    assert {:ok, %{ip: "203.0.113.20", target: %{family: 4}, req_opts: opts}} =
             Egress.pin(client, "https://dual.test/x")

    assert opts[:url] == "https://203.0.113.20/x"

    assert {:ok, %{target: %{family: 6}} = pinned} =
             Egress.pin(client, "https://v6only.test:8080/x")

    assert pinned.ip_tuple == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x30}
    assert pinned.req_opts[:url] == "https://[2001:db8::30]:8080/x"
    assert pinned.req_opts[:connect_options][:hostname] == "v6only.test"

    # An IPv6 literal URL keeps its literal for the connection's identity.
    ScriptedHost.pins(host, %{"2001:db8::40" => "2001:db8::40"})
    assert {:ok, pinned} = Egress.pin(client, "http://[2001:db8::40]:8080/x")
    assert pinned.target.host == "[2001:db8::40]"
    assert pinned.req_opts[:url] == "http://[2001:db8::40]:8080/x"
  end

  test "the engine sends to exactly the address the pin names, private or not", %{
    host: host,
    client: client
  } do
    # The private-address policy is the host's: whatever it pins, the
    # engine connects to, and to nothing it resolved itself.
    ScriptedHost.pins(host, %{"private.test" => "10.0.0.5", "localhost" => "127.0.0.1"})

    assert {:ok, %{ip: "10.0.0.5", req_opts: opts}} = Egress.pin(client, "http://private.test/")
    assert opts[:url] == "http://10.0.0.5/"
    assert opts[:connect_options][:hostname] == "private.test"

    assert {:ok, %{ip: "127.0.0.1"}} = Egress.pin(client, "http://localhost:4000/")
  end

  test "a metadata address is refused inside the engine even when the host pins one", %{
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
               Egress.pin(client, "http://metadata.test/latest")

      assert message =~ "metadata IP"
    end

    # Refused, the pin is not kept: the next request asks again.
    ScriptedHost.pins(host, %{"metadata.test" => "203.0.113.9"})
    assert {:ok, %{ip: "203.0.113.9"}} = Egress.pin(client, "http://metadata.test/latest")
  end

  test "the host's refusals are the guest's typed errors, marked as the host's", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{
      "private.test" => :denied,
      "metadata.test" => :metadata,
      "odd.test" => :malformed
    })

    assert {:refused, :private_ip_blocked, message} = Egress.pin(client, "http://private.test/")
    assert message =~ "private.test"

    assert {:refused, :private_ip_blocked, message} = Egress.pin(client, "http://metadata.test/")
    assert message =~ "metadata IP"

    assert {:refused, :dns_error, "DNS resolution failed for nonexistent.test"} =
             Egress.pin(client, "https://nonexistent.test/")

    assert {:refused, :invalid_request, _} = Egress.pin(client, "https://odd.test/")
  end

  test "a host that cannot answer is the engine's refusal, not the host's", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "egress_pin", [{:error, :unavailable}, {:error, :lost}])

    assert {:error, :dns_error, message} = Egress.pin(client, "https://public.test/")
    assert message =~ "could not be pinned"

    assert {:error, :dns_error, message} = Egress.pin(client, "https://public.test/")
    assert message =~ "not current"
  end

  test "a pin that names another target than the URL is refused", %{host: host, client: client} do
    ScriptedHost.script(host, "egress_pin", fn _args, _caller ->
      {:ok,
       %{
         "id" => "pin_other",
         "ip" => "203.0.113.10",
         "family" => 4,
         "scheme" => "https",
         "port" => 443,
         "host" => "elsewhere.test",
         "expires_at" => System.system_time(:millisecond) + 30_000
       }}
    end)

    assert {:error, :dns_error, message} = Egress.pin(client, "https://public.test/")
    assert message =~ "pinned elsewhere"

    assert {:error, :dns_error, _} = Egress.pin(client, "http://public.test:443/")
  end

  test "a pin is reused for the same attempt, purpose and target until it expires", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10", "other.test" => "203.0.113.11"})

    assert {:ok, first} = Egress.pin(client, "https://public.test/a")
    assert {:ok, second} = Egress.pin(client, "https://PUBLIC.test/b?c=d")
    assert second.target == first.target
    assert second.req_opts[:url] == "https://203.0.113.10/b?c=d"
    assert length(ScriptedHost.requests(host, "egress_pin")) == 1

    # Another port, scheme, host or purpose is another target.
    assert {:ok, _} = Egress.pin(client, "https://public.test:8443/a")
    assert {:ok, _} = Egress.pin(client, "http://public.test/a")
    assert {:ok, _} = Egress.pin(client, "https://other.test/a")
    assert {:ok, _} = Egress.pin(client, "https://public.test/a", purpose: :stream)
    assert length(ScriptedHost.requests(host, "egress_pin")) == 5

    # Another attempt holds none of this one's pins.
    other = ScriptedHost.attempt!(host).client
    assert {:ok, _} = Egress.pin(other, "https://public.test/a")
    assert length(ScriptedHost.requests(host, "egress_pin")) == 6
  end

  test "a pin past its expires_at is used for its own request and asked for again after", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10"}, expires_in: -1)

    assert {:ok, first} = Egress.pin(client, "https://public.test/a")
    assert {:ok, second} = Egress.pin(client, "https://public.test/a")
    assert first.target.id != second.target.id
    assert length(ScriptedHost.requests(host, "egress_pin")) == 2
  end

  test "a redirect's next hop is pinned from the pin it came from, once", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{"public.test" => "203.0.113.10", "other.test" => "203.0.113.11"})

    assert {:ok, origin} = Egress.pin(client, "https://public.test/start")
    refute Egress.cross_origin?(origin)

    :ok = Egress.redirected(client, origin, "https://public.test/start", "/moved")
    :ok = Egress.redirected(client, origin, "https://public.test/start", "https://other.test/x")

    assert {:ok, same} = Egress.pin(client, "https://public.test/moved")
    assert same.from == origin.target
    refute Egress.cross_origin?(same)

    assert {:ok, cross} = Egress.pin(client, "https://other.test/x")
    assert cross.from == origin.target
    assert Egress.cross_origin?(cross)

    assert [_fetch, hop1, hop2] = ScriptedHost.requests(host, "egress_pin")
    from = origin.target.id

    assert hop1.args == %{
             "url" => "https://public.test/moved",
             "purpose" => "redirect",
             "from" => from
           }

    assert hop2.args == %{
             "url" => "https://other.test/x",
             "purpose" => "redirect",
             "from" => from
           }

    # The hop is consumed: a later request there is a request of its own.
    assert {:ok, again} = Egress.pin(client, "https://other.test/x")
    assert again.from == nil
  end

  test "a hop is cross-origin by its scheme, host or effective port, as Prima compares them", %{
    host: host,
    client: client
  } do
    ScriptedHost.pins(host, %{
      "public.test" => "203.0.113.10",
      "2001:db8::20" => "2001:db8::20",
      "2001:0db8:0:0:0:0:0:20" => "2001:db8::20"
    })

    hop = fn origin, request_url, to ->
      :ok = Egress.redirected(client, origin, request_url, to)
      assert {:ok, pinned} = Egress.pin(client, to)
      assert pinned.from == origin.target
      pinned
    end

    assert {:ok, origin} = Egress.pin(client, "https://public.test/start")

    for {to, cross?} <- [
          {"https://public.test:443/same", false},
          {"https://PUBLIC.test/case", false},
          {"https://public.test:8443/port", true},
          {"http://public.test/scheme", true}
        ] do
      assert Egress.cross_origin?(hop.(origin, "https://public.test/start", to)) == cross?, to
    end

    # An IPv6 literal is one host however it is spelled.
    assert {:ok, v6} = Egress.pin(client, "http://[2001:db8::20]:8080/events", purpose: :stream)

    spelled =
      hop.(v6, "http://[2001:db8::20]:8080/events", "http://[2001:0db8:0:0:0:0:0:20]:8080/n")

    refute Egress.cross_origin?(spelled)

    assert Egress.cross_origin?(
             hop.(v6, "http://[2001:db8::20]:8080/events", "http://[2001:db8::20]:8081/n")
           )
  end

  test "a scheme other than http or https, and a missing host, are invalid URLs, asked of no one",
       %{host: host, client: client} do
    assert {:error, :invalid_url, "blocked URL scheme: ftp"} =
             Egress.pin(client, "ftp://example.com/")

    assert {:error, :invalid_url, "missing URL scheme"} = Egress.pin(client, "example.com/path")
    assert {:error, :invalid_url, "missing hostname"} = Egress.pin(client, "http:///path")
    assert ScriptedHost.requests(host, "egress_pin") == []
  end
end
