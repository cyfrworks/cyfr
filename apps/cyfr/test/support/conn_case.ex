# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use EmissaryWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint EmissaryWeb.Endpoint

      use EmissaryWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import EmissaryWeb.ConnCase
    end
  end

  @doc """
  POST a JSON-RPC message to `/mcp` as a conforming client.

  Every request must declare its protocol version twice — in the
  `MCP-Protocol-Version` header and in `params._meta` — and the two must agree.
  Encoding that in one helper keeps the rule in a single place: a test asserts
  what it is about, and the next protocol revision is one edit here rather than
  eighty across the suite.

  Tests that deliberately send a malformed or non-conforming request should call
  `post/3` directly instead.
  """
  def mcp_post(conn, body) when is_map(body) do
    conn
    |> Plug.Conn.put_req_header("mcp-protocol-version", Emissary.MCP.Protocol.version())
    |> put_mcp_routing_headers(body)
    |> Phoenix.ConnTest.dispatch(EmissaryWeb.Endpoint, :post, "/mcp", conform_mcp_body(body))
  end

  defp put_mcp_routing_headers(conn, body) do
    conn =
      case body["method"] do
        method when is_binary(method) -> Plug.Conn.put_req_header(conn, "mcp-method", method)
        _ -> conn
      end

    case Emissary.MCP.Protocol.named_subject(body) do
      name when is_binary(name) -> Plug.Conn.put_req_header(conn, "mcp-name", name)
      _ -> conn
    end
  end

  defp conform_mcp_body(%{"method" => _} = body) do
    params = Map.get(body, "params") || %{}

    meta = %{
      Emissary.MCP.Protocol.meta_protocol_version_key() => Emissary.MCP.Protocol.version(),
      Emissary.MCP.Protocol.meta_client_info_key() => %{"name" => "test", "version" => "0.0.0"},
      Emissary.MCP.Protocol.meta_client_capabilities_key() => %{}
    }

    Map.put(body, "params", Map.put(params, "_meta", meta))
  end

  defp conform_mcp_body(body), do: body

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    end

    # Allow tasks spawned via Emissary.TaskSupervisor to access the DB sandbox
    # (async work started by request handling calls Arca.Repo).
    case Process.whereis(Emissary.TaskSupervisor) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), pid)
      nil -> :ok
    end

    # Set test auth provider so sessions get authenticated: true.
    # Tests that need unauthenticated contexts can override per-test.
    # Restore on exit so the setting never leaks into later test files (a
    # lingering provider flips operator-only conveniences off and breaks
    # unrelated suites — e.g. external server URL validation).
    original_auth_provider = Application.get_env(:cyfr, :auth_provider)
    Application.put_env(:cyfr, :auth_provider, Emissary.TestAuthProvider)

    on_exit(fn ->
      if original_auth_provider,
        do: Application.put_env(:cyfr, :auth_provider, original_auth_provider),
        else: Application.delete_env(:cyfr, :auth_provider)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
