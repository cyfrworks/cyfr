# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ConnCase do
  @moduledoc """
  Test case for the Prism (LiveView) surface.

  Starts the SQL sandbox (`Cyfr.Test.Sandbox`: shared for sync tests, so
  LiveView processes and supervised tasks can hit the repo), imports
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
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Make `athanor_id` an estate a turn can run in: the shipped tree and
  bundle copied in, indexed, the baseline consent the soul pins minted —
  as a fill leaves it — and a key connected to the Claude catalyst, which
  its runs unseal when they attach. `user_id` is a member whose seat the
  bootstrap runs under.
  """
  def ready_estate!(athanor_id, user_id) do
    turn_env!()
    ctx = %{Sanctum.TestContext.local() | user_id: user_id, athanor_id: athanor_id}
    {:ok, _} = Sanctum.Tenancy.Members.ensure(user_id, scope: "athanor", athanor_id: athanor_id)
    :ok = Sanctum.TestContext.shipped!(athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
    # The soul roots: the consent a turn pins exists, whoever minted it.
    {:ok, _} = Cyfr.Execution.authority_for(ctx, :default, Compendium.AgentSource.soul_ref())

    Sanctum.Test.ConsentFixtures.bind_key!(ctx, "catalyst:local.claude", %{
      "ANTHROPIC_API_KEY" => "sk-test"
    })

    ctx
  end

  # A turn pins the consent the fill minted into the durable source, from
  # the repository's own seed; restored on exit.
  defp turn_env! do
    keys = [:seed_path]
    prev = Map.new(keys, &{&1, Application.get_env(:arca, &1)})
    Application.put_env(:arca, :seed_path, Path.expand("../../../../seed", __DIR__))

    ExUnit.Callbacks.on_exit(fn ->
      for {key, value} <- prev do
        if value,
          do: Application.put_env(:arca, key, value),
          else: Application.delete_env(:arca, key)
      end
    end)
  end

  @doc """
  Dispatch this test's runs to the scripted worker service, scripting the
  bundled Claude catalyst: starting it puts its endpoint ahead of the
  configured worker services, which are restored on exit. Answers the
  scripted worker service's pid.
  """
  def script_model!(items \\ []) do
    previous = Application.get_env(:cyfr, :workers)

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:cyfr, :workers, previous)
    end)

    ExUnit.Callbacks.start_supervised!(
      {Cyfr.Test.ScriptedWorker, ref: "catalyst:local.claude", script: items}
    )
  end

  @doc "A `model/chat@1` reply with `text` alone."
  def model_reply(text) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }
  end

  @doc "A `model/chat@1` reply with one tool call."
  def model_call(id, name, args) do
    %{
      "content" => [%{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}],
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 2}
    }
  end

  @doc "The chat requests the scripted model answered, oldest first."
  def model_requests do
    Cyfr.Test.ScriptedWorker.calls()
    |> Enum.filter(&(&1.input["operation"] == "chat"))
    |> Enum.map(& &1.input["params"])
  end

  @doc "The text of every block of every message of a chat request."
  def request_text(request) do
    request["messages"]
    |> Enum.flat_map(& &1["content"])
    |> Enum.map(&(&1["text"] || &1["content"] || ""))
    |> Enum.join("\n")
  end

  @doc "The Plug session key the harness writes the Sanctum session token under."
  def session_key, do: @session_key

  @doc """
  A distinct test person, signed in once: `user_id` is their own id (the
  `users` row is minted here), `identity` the IdP key that names them,
  plus an email and a personal namespace slug. Every call yields a new
  person.
  """
  def test_user(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    attrs = Map.new(attrs)
    identity = Map.get(attrs, :identity, "github|https://github.com|#{n}")
    email = Map.get(attrs, :email, "user#{n}@example.com")

    {:ok, row} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: identity,
        provider: "github",
        email: email,
        verified: true,
        name: Map.get(attrs, :name)
      })

    Map.merge(
      %{user_id: row.id, identity: identity, email: email, namespace: "testns#{n}"},
      Map.drop(attrs, [:identity, :name])
    )
  end

  @doc """
  Record a claimed personal namespace for `user` on their users row, the
  way the cyfr.run probe/claim does.
  """
  def claim_namespace!(%{user_id: user_id, namespace: slug}) do
    {:ok, row} = Sanctum.Tenancy.Users.get(user_id)
    {:ok, _} = Sanctum.Tenancy.Users.set_namespace(row, slug)
    :ok
  end

  @doc """
  Sign `user` in: claim their namespace (unless `claim: false`), seat them in
  their own athanor (or `opts[:athanor_id]`), create a `Sanctum.Session`, and
  put the token in the Plug session. Returns the conn.

  The seat is the person's own estate, as it is in production — no estate is
  shared server-wide, so two signed-in test users are strangers to each other
  unless a test seats them together. The estate is remembered for this test
  process so `athanor_path/2` and `mount_athanor/3` name the same one.
  """
  def log_in_user(conn, user, opts \\ []) do
    if Keyword.get(opts, :claim, true), do: claim_namespace!(user)

    athanor_id = Keyword.get_lazy(opts, :athanor_id, fn -> own_athanor!(user).id end)
    Process.put(:prism_test_athanor_id, athanor_id)

    {:ok, _membership} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: athanor_id)

    # The estate holds what the server ships, as a fill leaves it.
    :ok = Sanctum.TestContext.shipped!(athanor_id)

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

    {:ok, session} = Sanctum.TestContext.create_session(ctx)

    Plug.Test.init_test_session(conn, %{@session_key => session.token})
  end

  # The person's own athanor, minted the way admission does: one per owner,
  # slugged from their namespace. Idempotent, so repeated sign-ins in one
  # test reuse it.
  defp own_athanor!(user) do
    case Sanctum.Tenancy.Athanors.get_by_owner(user.user_id) do
      {:ok, athanor} ->
        athanor

      {:error, :not_found} ->
        name = user[:namespace] || user.user_id
        {:ok, slug} = Sanctum.Tenancy.Athanors.person_slug(user[:namespace], name)

        {:ok, athanor} =
          Sanctum.Tenancy.Athanors.create(%{
            kind: "person",
            name: name,
            slug: slug,
            owner_user_id: user.user_id,
            created_by: user.user_id
          })

        # Signed in on an estate that is set up, which is what a console
        # test is about; filling one is `Sanctum.Provisioning`'s own suite.
        {:ok, provisioned} = Sanctum.Tenancy.Athanors.mark_provisioned(athanor)
        provisioned
    end
  end

  @doc """
  The athanor `log_in_user/3` seated this test's person in — the estate the
  page helpers name by default.
  """
  def seated_athanor do
    id =
      Process.get(:prism_test_athanor_id) ||
        raise "no athanor in focus — call log_in_user/3 first, or pass one explicitly"

    {:ok, athanor} = Sanctum.Tenancy.Athanors.get(id)
    athanor
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
  The page path for an athanor: `/a/<route>` + `suffix`. Takes an athanor, a
  route string (for a test that names one without seating anybody), or
  nothing — which is the estate `log_in_user/3` seated this test's person
  in. The empty suffix is the athanor's chat, which lives in the chat zone
  (`/chat?a=<route>`).
  """
  def athanor_path(suffix, athanor \\ nil)

  def athanor_path(suffix, nil), do: athanor_path(suffix, seated_athanor())

  def athanor_path(suffix, route) when is_binary(route) do
    case suffix do
      "" -> PrismWeb.ChatLive.chat_path(route)
      "?c=" <> id -> PrismWeb.ChatLive.chat_path(route, id)
      _ -> PrismWeb.Focus.path(route, suffix)
    end
  end

  def athanor_path(suffix, athanor),
    do: athanor_path(suffix, Sanctum.Tenancy.Athanors.route_slug(athanor))

  @doc """
  Mount `suffix` under the athanor in focus (the seated one by default); returns
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
