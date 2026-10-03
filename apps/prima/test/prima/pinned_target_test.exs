# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.PinnedTargetTest do
  @moduledoc """
  A pin is exactly its seven members, each validated as it is written and
  read: an id, an IP literal that parses and the family that matches it,
  the URL's scheme and a port of 1 to 65535, a hostname or bracketed IPv6
  literal, and an expiry. An `egress_pin` request is a URL with a host and
  a purpose, naming the pin it came from for a redirect and for nothing
  else.
  """

  use ExUnit.Case, async: true

  alias Prima.PinnedTarget

  @pin %PinnedTarget{
    id: "pin_Vx1",
    ip: "203.0.113.10",
    family: 4,
    scheme: "https",
    port: 443,
    host: "api.example.test",
    expires_at: 1_789_305_279_602
  }

  test "a valid pin writes to its seven members and reads back to itself" do
    for pin <- [
          @pin,
          %{
            @pin
            | ip: "2001:db8::20",
              family: 6,
              host: "[2001:db8::20]",
              scheme: "http",
              port: 8080
          },
          %{@pin | ip: "::ffff:203.0.113.10", family: 6},
          %{@pin | host: "API.Example.test.", port: 1},
          %{@pin | host: "203.0.113.10", port: 65_535, expires_at: 0},
          %{@pin | host: "svc_internal", id: String.duplicate("A", 128)}
        ] do
      assert PinnedTarget.valid?(pin), Prima.LoggerContext.shape(pin)
      wire = PinnedTarget.to_wire(pin)
      assert Enum.sort(Map.keys(wire)) == ~w(expires_at family host id ip port scheme)
      assert {:ok, ^pin} = PinnedTarget.read(wire |> Jason.encode!() |> Jason.decode!())
    end
  end

  test "every field is validated, on the way out and on the way in" do
    wire = PinnedTarget.to_wire(@pin)

    for bad <- [
          %{@pin | id: ""},
          %{@pin | id: String.duplicate("A", 129)},
          %{@pin | id: "pin id"},
          %{@pin | id: "pin="},
          %{@pin | ip: "203.0.113"},
          %{@pin | ip: "203.0.113.256"},
          %{@pin | ip: " 203.0.113.10"},
          %{@pin | ip: "api.example.test"},
          %{@pin | ip: {203, 0, 113, 10}},
          %{@pin | family: 6},
          %{@pin | ip: "2001:db8::1"},
          %{@pin | family: "4"},
          %{@pin | scheme: "ftp"},
          %{@pin | scheme: "HTTPS"},
          %{@pin | port: 0},
          %{@pin | port: 65_536},
          %{@pin | port: "443"},
          %{@pin | host: ""},
          %{@pin | host: "api..example.test"},
          %{@pin | host: "-api.example.test"},
          %{@pin | host: "api.example.test\n"},
          %{@pin | host: "api.example.test:443"},
          %{@pin | host: "user@api.example.test"},
          %{@pin | host: String.duplicate("a", 64) <> ".test"},
          %{@pin | host: "2001:db8::1"},
          %{@pin | host: "[203.0.113.10]"},
          %{@pin | host: "[2001:db8::1]]"},
          %{@pin | host: "["},
          %{@pin | expires_at: -1},
          %{@pin | expires_at: 9_007_199_254_740_992},
          %{@pin | expires_at: 1.0}
        ] do
      refute PinnedTarget.valid?(bad), Prima.LoggerContext.shape(bad)
      assert_raise ArgumentError, fn -> PinnedTarget.to_wire(bad) end

      bad_wire = Map.new(Map.from_struct(bad), fn {k, v} -> {Atom.to_string(k), v} end)
      assert :error = PinnedTarget.read(bad_wire)
    end

    assert :error = PinnedTarget.read(Map.delete(wire, "expires_at"))
    assert :error = PinnedTarget.read(Map.put(wire, "resolved_from", "dns"))
    assert :error = PinnedTarget.read(Map.new(wire, fn {k, v} -> {String.to_atom(k), v} end))
    assert :error = PinnedTarget.read(@pin)
    assert :error = PinnedTarget.read(nil)
    refute PinnedTarget.valid?(Map.from_struct(@pin))
  end

  test "a request is a URL with a host and a purpose, and a redirect names its pin" do
    assert {:ok, args} = PinnedTarget.request_args("https://api.example.test/x?y=1", :fetch)
    assert args == %{"url" => "https://api.example.test/x?y=1", "purpose" => "fetch"}

    assert {:ok, %{url: "https://api.example.test/x?y=1", purpose: :fetch, from: nil}} =
             PinnedTarget.read_request(args)

    assert {:ok, %{purpose: :stream, from: nil}} =
             PinnedTarget.read_request(%{
               "url" => "http://[2001:db8::20]:8080/",
               "purpose" => "stream"
             })

    assert {:ok, redirect} =
             PinnedTarget.request_args("https://api.example.test/2", :redirect, "pin_Vx1")

    assert {:ok, %{purpose: :redirect, from: "pin_Vx1"}} = PinnedTarget.read_request(redirect)

    for bad <- [
          %{"url" => "ftp://api.example.test/", "purpose" => "fetch"},
          %{"url" => "https:///x", "purpose" => "fetch"},
          %{"url" => "//api.example.test/", "purpose" => "fetch"},
          %{"url" => "https://api.example.test/", "purpose" => "resolve"},
          %{"url" => "https://api.example.test/", "purpose" => :fetch},
          %{"url" => "https://api.example.test/", "purpose" => "redirect"},
          %{"url" => "https://api.example.test/", "purpose" => "redirect", "from" => "not a pin"},
          %{"url" => "https://api.example.test/", "purpose" => "fetch", "from" => "pin_Vx1"},
          %{"url" => "https://api.example.test/", "purpose" => "fetch", "extra" => 1},
          %{"url" => "https://api.example.test/"},
          %{"purpose" => "fetch"},
          ["https://api.example.test/", "fetch"],
          nil
        ] do
      assert {:error, :malformed} = PinnedTarget.read_request(bad), Prima.LoggerContext.shape(bad)
    end

    assert :error = PinnedTarget.request_args("https://api.example.test/", :fetch, "pin_Vx1")
    assert :error = PinnedTarget.request_args("https://api.example.test/", :redirect)
    assert :error = PinnedTarget.request_args("file:///etc/passwd", :fetch)
  end

  test "the refusals and purposes are the wire's names, and a pin expires after its instant" do
    assert PinnedTarget.refusals() ==
             [:denied, :metadata, :resolution, :redirect_credentials, :malformed]

    assert PinnedTarget.purposes() == [:fetch, :stream, :redirect]
    refute PinnedTarget.expired?(@pin, @pin.expires_at)
    assert PinnedTarget.expired?(@pin, @pin.expires_at + 1)
    assert PinnedTarget.address(@pin) == {203, 0, 113, 10}

    assert PinnedTarget.address(%{@pin | ip: "2001:db8::20", family: 6}) ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x20}
  end
end
