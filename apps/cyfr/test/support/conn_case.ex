# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule CyfrWeb.ConnCase do
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
  by setting `use CyfrWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
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

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    # Set test auth provider so sessions get authenticated: true.
    # Tests that need unauthenticated contexts can override per-test.
    # Global app env is not concurrency-safe, so only sync tests get the
    # provider (the async ConnCase users don't touch auth). On exit, restore
    # the test-env BASELINE (unset — config/test.exs sets no :auth_provider)
    # rather than a captured "original": a capture taken mid-run can be
    # another module's temporary value, and restoring it leaks the provider
    # into later suites (a lingering provider flips operator-only
    # conveniences off and breaks unrelated ones — e.g. external server URL
    # validation).
    unless tags[:async] do
      Application.put_env(:sanctum, :auth_provider, Emissary.TestAuthProvider)
      on_exit(fn -> Application.delete_env(:sanctum, :auth_provider) end)
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
