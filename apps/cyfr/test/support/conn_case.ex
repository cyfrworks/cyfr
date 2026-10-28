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

  A request is authenticated only when it carries a credential. A sync
  test or module tagged `auth: :person` gets a `conn` that carries the
  test person's bearer (`authenticate_as/2`); `auth: :none` or no tag
  gives a bare `conn`, which reaches the plug as an anonymous caller.
  `auth` on an async test raises, because the provider that reads the
  bearer is global application environment.

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
  Puts the test person's bearer on `conn`, with `overrides` merged into
  the person's context (`Emissary.TestAuthProvider.bearer/1`). It replaces
  any Authorization header, and `recycle/1` carries it to the next request.
  """
  @spec authenticate_as(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def authenticate_as(%Plug.Conn{} = conn, overrides \\ []) do
    Plug.Conn.put_req_header(
      conn,
      "authorization",
      "Bearer " <> Emissary.TestAuthProvider.bearer(overrides)
    )
  end

  @doc """
  The `conn` a test's tags ask for: the test person's bearer under
  `auth: :person`, a bare conn under `auth: :none` or no tag. It raises
  for `auth` on an async test and for any other `auth` value, before the
  setup touches the sandbox or the auth provider.
  """
  @spec conn_for(map()) :: Plug.Conn.t()
  def conn_for(tags) when is_map(tags) do
    if tags[:async] == true and Map.has_key?(tags, :auth) do
      raise ArgumentError,
            "`auth` is tagged on an async test: the auth provider is global " <>
              "application environment, so only a sync test may authenticate"
    end

    conn = %{
      Phoenix.ConnTest.build_conn()
      | secret_key_base: Application.fetch_env!(:cyfr, CyfrWeb.Endpoint)[:secret_key_base]
    }

    case tags[:auth] do
      :person -> authenticate_as(conn)
      none when none in [nil, :none] -> conn
      other -> raise ArgumentError, "unknown `auth` tag #{inspect(other)}: use :person or :none"
    end
  end

  setup tags do
    conn = conn_for(tags)
    Cyfr.Test.Sandbox.setup!(tags)

    # The test auth provider claims only the bearer `authenticate_as/2`
    # puts on a conn, so a bare conn stays anonymous.
    # Global app env is not concurrency-safe, so only sync tests get the
    # provider (the async ConnCase users don't touch auth). On exit, restore
    # the test-env BASELINE (unset — config/test.exs sets no
    # :bearer_provider) rather than a captured "original": a capture taken
    # mid-run can be another module's temporary value, and restoring it
    # leaks the provider into later suites.
    unless tags[:async] do
      on_exit(fn -> Application.delete_env(:sanctum, :bearer_provider) end)
      Application.put_env(:sanctum, :bearer_provider, Emissary.TestAuthProvider)
    end

    {:ok, conn: conn}
  end
end
