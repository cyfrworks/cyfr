# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.EgressTest do
  @moduledoc """
  The control plane's outbound arm over `Cyfr.Network.pin/2`.

  What the decision refuses is `Cyfr.NetworkTest`'s, in the contracts,
  where the decision lives. What is here is that the transport refuses
  BEFORE it connects — a refused destination must never reach `Req` — and
  that the streaming ceiling it hands the collector behaves on a real
  `Req.Response`, which is why these cases sit in the app that has `req`.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Egress
  alias Cyfr.Test.Resolver

  @resolver [resolver: Resolver]

  describe "pinned_request/5 SSRF + DNS-rebinding guard" do
    # The security contract: a private or metadata resolution is rejected BEFORE
    # any connection, and the connection (when allowed) targets the validated IP
    # — so there is no second DNS resolution to rebind.
    test "blocks loopback before connecting" do
      assert {:error, msg} = Egress.pinned_request(:get, "http://127.0.0.1/")
      assert msg =~ "private IP"
    end

    test "always blocks the metadata endpoint" do
      assert {:error, msg} =
               Egress.pinned_request(:get, "http://169.254.169.254/latest/meta-data/",
                 private_policy: :allow_all
               )

      assert msg =~ "metadata IP"
    end

    test "rejects non-http(s) schemes" do
      assert {:error, msg} = Egress.pinned_request(:get, "file:///etc/passwd")
      assert msg =~ "blocked URL scheme"
    end

    test "returns a DNS error for an unresolvable host" do
      assert {:error, msg} =
               Egress.pinned_request(:get, "https://nonexistent.test/", [], nil, @resolver)

      assert msg == "DNS resolution failed for nonexistent.test: :nxdomain"
    end
  end

  describe "Cyfr.BoundedBody on the pinned transport's Req.Response" do
    test "collects into a Req.Response and halts past the ceiling" do
      collector = Cyfr.BoundedBody.collector(4)

      {:cont, {_req, resp}} = collector.({:data, "1234"}, {:req, %Req.Response{}})
      assert Cyfr.BoundedBody.read(resp, 4) == {:ok, "1234"}

      {:halt, {_req, resp}} = collector.({:data, "5"}, {:req, resp})
      assert Cyfr.BoundedBody.read(resp, 4) == {:error, {:response_too_large, 5, 4}}
    end
  end
end
