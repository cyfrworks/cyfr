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
    # The sandbox owner is its own process, not the test: the work a page
    # leaves behind (a conversation runner finishing a turn, a task on one
    # of the supervisors below) is stopped from `on_exit`, which runs after
    # the test process is gone. Were the test the owner, that work would
    # lose its connection first, crash, and be restarting when the teardown
    # reaches it. Callbacks run last-registered first, so the owner is
    # stopped only after everything that used it has been.
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Arca.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    # LiveViews spawn work on these supervisors (session refresh, AQUA calls,
    # MCP tool dispatch); let that work reach the sandbox connection — and
    # stop whatever is still running when the test ends, or a straggler
    # holding the sandbox connection makes the next test's first write
    # find the database busy.
    supervisors =
      for name <- [Prism.TaskSupervisor, Emissary.TaskSupervisor],
          pid = Process.whereis(name),
          is_pid(pid) do
        Ecto.Adapters.SQL.Sandbox.allow(Arca.Repo, owner, pid)
        pid
      end

    on_exit(fn ->
      for sup <- supervisors, child <- Task.Supervisor.children(sup) do
        Task.Supervisor.terminate_child(sup, child)
      end

      # Conversation runners the chat page started idle out on their own,
      # which is far too late for the next test's sandbox.
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Prism.ConversationSupervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(Prism.ConversationSupervisor, pid)
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
  Record a claimed personal namespace for `user` on their users row, the
  way the cyfr.run probe/claim does — a session restores as authenticated
  only when the row carries one.
  """
  def claim_namespace!(%{user_id: user_id, namespace: slug} = user) do
    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: user_id,
        provider: "github",
        email: Map.get(user, :email),
        verified: true,
        name: nil
      })

    {:ok, _} = Sanctum.Tenancy.Users.set_namespace(row, slug)
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
      {:ok, view, _mount_html} = live(unquote(conn), unquote(path))
      {view, PrismWeb.ConnCase.settled_render(view)}
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

  @doc """
  Mount `suffix` under the athanor in focus (Home by default); returns
  `{view, html}` where `html` is the settled page — rendered after the
  paint-then-load views' `:load` message has been served.
  """
  defmacro mount_athanor(conn, suffix, athanor \\ nil) do
    quote do
      {:ok, view, _mount_html} =
        live(unquote(conn), PrismWeb.ConnCase.athanor_path(unquote(suffix), unquote(athanor)))

      {view, PrismWeb.ConnCase.settled_render(view)}
    end
  end

  @doc """
  Render the settled page: data-heavy views paint a frame and load in a
  `:load` message, and the topbar child does the same — a render call is
  served after those messages, so what this returns is the page a person
  actually sees, and no load is still mid-query when the test exits (a
  LiveView killed mid-query poisons the shared SQLite sandbox connection
  for the next test).
  """
  def settled_render(view) do
    html = Phoenix.LiveViewTest.render(view)

    case Phoenix.LiveViewTest.find_live_child(view, "topbar") do
      nil -> html
      child -> Phoenix.LiveViewTest.render(child) && Phoenix.LiveViewTest.render(view)
    end
  end
end
