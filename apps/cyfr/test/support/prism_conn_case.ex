# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConnCase do
  @moduledoc """
  Test case for the Prism (LiveView) surface.

  Checks out the SQL sandbox (shared mode for sync tests, so LiveView
  processes and supervised tasks can hit the repo), imports
  `Phoenix.LiveViewTest`, and provides helpers to sign a test user in the
  way the browser does — a `Sanctum.Session` row, a claimed personal
  namespace, a membership — and mount authenticated LiveViews.
  """

  use ExUnit.CaseTemplate

  # The Plug session key that carries the Sanctum session token. Held in one
  # place so the harness follows the endpoint when the key changes.
  @session_key "session_token"

  using do
    quote do
      @endpoint PrismWeb.Endpoint

      use PrismWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PrismWeb.ConnCase
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    end

    # LiveViews spawn work on these supervisors (session refresh, AQUA calls,
    # MCP tool dispatch); let that work reach the sandbox connection.
    for name <- [Prism.TaskSupervisor, Emissary.TaskSupervisor] do
      case Process.whereis(name) do
        pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), pid)
        nil -> :ok
      end
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "The Plug session key the harness writes the Sanctum session token under."
  def session_key, do: @session_key

  @doc """
  A distinct test person: IdP-composite `user_id`, email, and a personal
  namespace slug. Every call yields a new identity.
  """
  def test_user(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        user_id: "github|https://github.com|#{n}",
        email: "user#{n}@example.com",
        namespace: "testns#{n}"
      },
      Map.new(attrs)
    )
  end

  @doc """
  Record a claimed personal namespace for `user` in the CredentialStore, the
  way the cyfr.run probe/claim does — a session restores as authenticated
  only when the user has one.
  """
  def claim_namespace!(%{user_id: user_id, namespace: slug}) do
    :ok =
      Compendium.Registry.CredentialStore.put(
        user_id,
        Compendium.Registry.canonical_host(),
        slug,
        %{
          type: :push_token,
          token: "cyfr_pt_test_#{slug}",
          namespace: slug,
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          label: "test"
        }
      )

    :ok
  end

  @doc """
  Sign `user` in: claim their namespace (unless `claim: false`), give them a
  membership in the seeded workspace, create a `Sanctum.Session`, and put the
  token in the Plug session. Returns the conn.
  """
  def log_in_user(conn, user, opts \\ []) do
    if Keyword.get(opts, :claim, true), do: claim_namespace!(user)

    {:ok, _membership} =
      Sanctum.Tenancy.Memberships.ensure(user.user_id,
        scope: "project",
        org_id: Arca.Tenant.local_org(),
        project_id: Arca.Tenant.default_project()
      )

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        email: user.email,
        provider: "github",
        namespace: user.namespace,
        org_id: Arca.Tenant.local_org(),
        project_id: Arca.Tenant.default_project(),
        permissions: [:*],
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.Session.create(ctx)

    Plug.Test.init_test_session(conn, %{@session_key => session.token})
  end

  @doc """
  Mount `path` as an authenticated LiveView, asserting the mount succeeded.
  Returns `{view, html}`. A macro because `live/2` needs the caller's
  `@endpoint`.
  """
  defmacro live_authenticated(conn, path) do
    quote do
      {:ok, view, html} = live(unquote(conn), unquote(path))
      {view, html}
    end
  end
end
