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

  # The Plug session key that carries the Sanctum session token — the one
  # the auth callback writes on the one endpoint.
  @session_key "sanctum_session_token"

  using do
    quote do
      @endpoint EmissaryWeb.Endpoint

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
    # MCP tool dispatch); let that work reach the sandbox connection — and
    # stop whatever is still running when the test ends, or a straggler
    # holding the sandbox connection makes the next test's first write
    # find the database busy.
    supervisors =
      for name <- [Prism.TaskSupervisor, Emissary.TaskSupervisor],
          pid = Process.whereis(name),
          is_pid(pid) do
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, self(), pid)
        pid
      end

    on_exit(fn ->
      for sup <- supervisors, child <- Task.Supervisor.children(sup) do
        Task.Supervisor.terminate_child(sup, child)
      end
    end)

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
  membership in Home (or `opts[:athanor_id]`), create a `Sanctum.Session`,
  and put the token in the Plug session. Returns the conn.
  """
  def log_in_user(conn, user, opts \\ []) do
    if Keyword.get(opts, :claim, true), do: claim_namespace!(user)

    athanor_id =
      Keyword.get_lazy(opts, :athanor_id, fn -> Sanctum.Tenancy.Athanors.home!().id end)

    {:ok, _membership} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: athanor_id)

    ctx =
      Sanctum.Context.build(
        user_id: user.user_id,
        email: user.email,
        provider: "github",
        namespace: user.namespace,
        athanor_id: athanor_id,
        permissions: [:*],
        scope: :athanor,
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

  @doc """
  The page path for an athanor: `/a/<route>` + `suffix`. Defaults to Home,
  where `log_in_user/3` seats the person.
  """
  def athanor_path(suffix, athanor \\ nil) do
    athanor = athanor || Sanctum.Tenancy.Athanors.home!()
    PrismWeb.Focus.path(athanor, suffix)
  end

  @doc "Mount `suffix` under the athanor in focus (Home by default); returns `{view, html}`."
  defmacro mount_athanor(conn, suffix, athanor \\ nil) do
    quote do
      {:ok, view, html} =
        live(unquote(conn), PrismWeb.ConnCase.athanor_path(unquote(suffix), unquote(athanor)))

      {view, html}
    end
  end
end
