# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.TransportTest do
  @moduledoc """
  What may be replayed, and what may not.

  The registry API has no idempotency key, so a retry of a POST that the
  server already processed mints a second push token, or 409s a person against
  their own successful namespace claim. The transport therefore decides by
  method AND by how the attempt failed: a request that never left this host is
  always safe to repeat; an ambiguous one is only safe for idempotent methods.
  """

  use ExUnit.Case, async: false

  alias Compendium.OCI.Errors
  alias Compendium.Registry.Transport

  # Resolvable and inside the test private-egress allowlist; the Req stub
  # answers before anything is actually dialled.
  @url "http://127.0.0.1:9/v1/thing"

  setup do
    Req.default_options(plug: {Req.Test, :registry_transport})
    on_exit(fn -> Req.default_options([]) end)
    :ok
  end

  defp stub(fun) do
    parent = self()

    Req.Test.stub(:registry_transport, fn conn ->
      send(parent, :attempt)
      fun.(conn)
    end)
  end

  defp attempts do
    receive do
      :attempt -> 1 + attempts()
    after
      0 -> 0
    end
  end

  describe "an ambiguous failure — the server may have acted" do
    test "a POST is not replayed" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Errors{}} = Transport.request(:post, @url, [], "{}")
      assert attempts() == 1
    end

    test "a PATCH is not replayed either" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Errors{}} = Transport.request(:patch, @url, [], "{}")
      assert attempts() == 1
    end

    test "a GET is replayed — repeating a read creates nothing" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Errors{}} = Transport.request(:get, @url, [], nil)
      assert attempts() == 3
    end

    test "a 5xx does not replay a POST" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

      assert {:error, %Errors{}} = Transport.request(:post, @url, [], "{}")
      assert attempts() == 1
    end

    test "a 5xx does replay a GET" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

      assert {:error, %Errors{}} = Transport.request(:get, @url, [], nil)
      assert attempts() == 3
    end
  end

  describe "a request that never reached the server" do
    test "a POST is replayed — nothing can have acted on it" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Errors{}} = Transport.request(:post, @url, [], "{}")
      assert attempts() == 3
    end
  end

  describe "429" do
    test "is replayed for a POST — the server said it refused, not that it acted" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 429, "slow down") end)

      assert {:error, %Errors{}} = Transport.request(:post, @url, [], "{}")
      assert attempts() == 3
    end

    test "waits at least as long as Retry-After asks" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "1")
        |> Plug.Conn.send_resp(429, "slow down")
      end)

      {elapsed_us, _} = :timer.tc(fn -> Transport.request(:get, @url, [], nil) end)

      # Two backoffs before giving up; the header's 1s dominates the 500ms
      # exponential default, so the floor is 2s rather than 1.5s.
      assert elapsed_us >= 2_000_000
    end
  end

  describe "a success" do
    test "is returned as a Finch-shaped 4-tuple, once" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, ~s({"ok":true})) end)

      assert {:ok, 200, headers, ~s({"ok":true})} = Transport.request(:get, @url, [], nil)
      assert is_list(headers)
      assert attempts() == 1
    end

    test "a 4xx is handed back rather than retried — the caller interprets it" do
      stub(fn conn -> Plug.Conn.send_resp(conn, 404, "nope") end)

      assert {:ok, 404, _headers, "nope"} = Transport.request(:get, @url, [], nil)
      assert attempts() == 1
    end
  end
end
