# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.TransportTest do
  @moduledoc """
  The OCI transport on the shared retry policy: ambiguous failures are
  idempotency-gated, a 401 surfaces for re-login rather than negotiating,
  and an SSRF refusal is never dialled at all.
  """

  use ExUnit.Case, async: false

  alias Compendium.OCI.Errors
  alias Compendium.OCI.Transport

  @url "http://127.0.0.1:9/v2/testns/thing/blobs/uploads/"
  @registry "oci.test"
  @repository "testns/thing"

  setup do
    Req.default_options(plug: {Req.Test, :oci_transport})
    on_exit(fn -> Req.default_options([]) end)
    :ok
  end

  defp stub(fun) do
    parent = self()

    Req.Test.stub(:oci_transport, fn conn ->
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

  defp request(method, body \\ nil) do
    Transport.request_url(nil, method, @url, @registry, @repository, [], body)
  end

  test "a success passes through untouched" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 202, "") end)

    assert {:ok, 202, _headers, ""} = request(:post, "")
    assert attempts() == 1
  end

  test "a 5xx GET is retried to the budget" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)

    assert {:error, %Errors{}} = request(:get)
    assert attempts() == 3
  end

  test "a 5xx POST is not replayed — the server may have acted" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)

    assert {:error, %Errors{}} = request(:post, "")
    assert attempts() == 1
  end

  test "an ambiguous transport error gates on the method the same way" do
    stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Errors{}} = request(:post, "")
    assert attempts() == 1

    stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Errors{}} = request(:head)
    assert attempts() == 3
  end

  test "a 429 retries for any method, honouring Retry-After" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(429, "slow down")
    end)

    assert {:error, %Errors{}} = request(:post, "")
    assert attempts() == 3
  end

  test "a 401 surfaces for re-login after one attempt — no negotiation" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

    assert {:error, %Errors{}} = request(:get)
    assert attempts() == 1
  end

  test "an SSRF refusal is never dialled" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, "never reached") end)

    assert {:error, %Errors{}} =
             Transport.request_url(nil, :get, "http://169.254.169.254/v2/x", @registry, @repository)

    assert attempts() == 0
  end
end
