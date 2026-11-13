# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ConnCase do
  @moduledoc """
  The case template for tests that send requests through
  `CyfrWeb.Endpoint`: it imports `Phoenix.ConnTest`, `Plug.Conn` and the
  verified routes, builds the case's `conn` from its tags (`conn_for/1`),
  and starts the case's sandbox owner (`Cyfr.Test.Sandbox.setup!/1`,
  shared unless the case is async), so every write the case makes is
  rolled back when it ends.

  ## Authentication

  A request is authenticated only when it carries a credential the
  product issued. A sync test or module tagged `auth: :person` gets a
  `conn` that carries a session of the test athanor's person
  (`authenticate_as/1`); `auth: :none` or no tag gives a bare `conn`,
  which reaches the plug as an anonymous caller. `auth` on an async test
  raises: the person is one row, which concurrent sandboxes would contend
  for.

  The `conn` carries the endpoint's `secret_key_base`, as the endpoint
  sets it on every request it serves, so a test that calls a plug or a
  controller action directly signs and encrypts cookies as a request does.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CyfrWeb.Endpoint

      use CyfrWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CyfrWeb.ConnCase
    end
  end

  @doc """
  Puts the bearer of a new session on `conn`: a session of the person who
  owns the test athanor (`Sanctum.TestContext.owner!/0`), focused there,
  minted by `Sanctum.Session.create/2` as a sign-in mints one, so the
  fixtures a test writes through `Sanctum.TestContext.local/0` are the
  signed-in person's athanor's. It replaces any Authorization header, and
  `recycle/1` carries it to the next request.
  """
  @spec authenticate_as(Plug.Conn.t()) :: Plug.Conn.t()
  def authenticate_as(%Plug.Conn{} = conn) do
    person = Sanctum.TestContext.owner!()

    {:ok, %{token: token}} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: person.id,
          provider: "local",
          athanor_id: Sanctum.TestContext.athanor_id(),
          permissions: Sanctum.Context.person_permissions(),
          auth_method: :oidc
        )
      )

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  @doc """
  The `conn` a test's tags ask for: a session's bearer under
  `auth: :person` (`authenticate_as/1`), a bare conn under `auth: :none`
  or no tag. It raises for `auth` on an async test and for any other
  `auth` value, before the setup touches the sandbox.
  """
  @spec conn_for(map()) :: Plug.Conn.t()
  def conn_for(tags) when is_map(tags) do
    if tags[:async] == true and Map.has_key?(tags, :auth) do
      raise ArgumentError,
            "`auth` is tagged on an async test: the test athanor's person is one " <>
              "row, so only a sync test may sign in as them"
    end

    case tags[:auth] do
      :person -> :ok
      none when none in [nil, :none] -> :ok
      other -> raise ArgumentError, "unknown `auth` tag #{inspect(other)}: use :person or :none"
    end

    %{
      Phoenix.ConnTest.build_conn()
      | secret_key_base: Application.fetch_env!(:cyfr, CyfrWeb.Endpoint)[:secret_key_base]
    }
  end

  setup tags do
    conn = conn_for(tags)
    Cyfr.Test.Sandbox.setup!(tags)

    # The session is minted inside the sandbox the case just started, so
    # its rows go when the test does.
    conn = if tags[:auth] == :person, do: authenticate_as(conn), else: conn

    {:ok, conn: conn}
  end
end
