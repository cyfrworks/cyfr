# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.EgressTest do
  @moduledoc """
  The control plane's outbound arm over `Sanctum.Network.pin/2`.

  Runtime resolution and policy are covered by `Sanctum.NetworkTest`;
  the shared contract's pure address decisions have their own suite. What is here is that the transport refuses
  BEFORE it connects — a refused destination must never reach `Req` — and
  that the streaming ceiling it hands the collector behaves on a real
  `Req.Response`, which is why these cases sit in the app that has `req`.
  """
  use ExUnit.Case, async: true

  alias Sanctum.Egress
  alias Sanctum.Test.Resolver

  @resolver [resolver: Resolver]

  defmodule RebindingResolver do
    def getaddr(~c"rebind.test", :inet) do
      calls = Process.get({__MODULE__, :calls}, 0)
      Process.put({__MODULE__, :calls}, calls + 1)
      {:ok, if(calls == 0, do: {127, 0, 0, 1}, else: {169, 254, 169, 254})}
    end
  end

  test "the connection uses one resolution and returns redirects without forwarding credentials" do
    response =
      "HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    with_server(response, fn port ->
      assert {:ok, 302, headers, ""} =
               Egress.pinned_request(
                 :get,
                 "http://rebind.test:#{port}/start",
                 [{"authorization", "Bearer fixture-token"}],
                 nil,
                 resolver: RebindingResolver,
                 private_policy: :allow_all,
                 protocols: [:http1]
               )

      assert {"location", "http://169.254.169.254/"} in headers
      assert Process.get({RebindingResolver, :calls}) == 1
      assert_receive {:request, request}
      assert String.downcase(request) =~ "host: rebind.test:#{port}"
      assert String.downcase(request) =~ "authorization: bearer fixture-token"
    end)
  end

  test "the HTTP response is bounded during collection" do
    response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n12345"

    with_server(response, fn port ->
      assert {:error, {:response_too_large, 5, 4}} =
               Egress.pinned_request(:get, "http://127.0.0.1:#{port}/", [], nil,
                 private_policy: :allow_all,
                 max_response_bytes: 4
               )
    end)
  end

  defp with_server(response, run) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    caller = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
          send(caller, {:request, request})
          :ok = :gen_tcp.send(socket, response)
        after
          :gen_tcp.close(socket)
        end
      end)

    try do
      run.(port)
      Task.await(server, 5_000)
    after
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

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
               Egress.pinned_request(:get, "http://169.254.169.254/latest/meta-data/", [], nil,
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

  describe "Prima.BoundedBody on the pinned transport's Req.Response" do
    test "collects into a Req.Response and halts past the ceiling" do
      collector = Prima.BoundedBody.collector(4)

      {:cont, {_req, resp}} = collector.({:data, "1234"}, {:req, %Req.Response{}})
      assert Prima.BoundedBody.read(resp, 4) == {:ok, "1234"}

      {:halt, {_req, resp}} = collector.({:data, "5"}, {:req, resp})
      assert Prima.BoundedBody.read(resp, 4) == {:error, {:response_too_large, 5, 4}}
    end
  end
end
