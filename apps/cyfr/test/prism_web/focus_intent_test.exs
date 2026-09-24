# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.FocusIntentTest do
  @moduledoc """
  A `ui.*.focus` intent is only real if the page it lands on reads the key
  it carries.

  Checks that pages consume the focus parameters emitted by `Aqua.Intents`
  and interpreted by `PrismWeb.ActiveContext`, displaying the resource
  identified in the URL.

  This walks the seam end to end for every intent, without a hand-kept list
  of pages: mint the path through `Aqua.Intents`, hand it to a real
  `PrismWeb.ThreadPaneLive` the way the runner does and take the path
  it pushes to the browser — the athanor in focus prefixed, a global page
  left alone — ask the router which LiveView serves it, and require that
  module's source to read every query key the mint produced. The roster
  below is the intents, not the wiring — and the first test fails if an
  intent is added without one.
  """

  use PrismWeb.ConnCase, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Sanctum.Tenancy.Athanors

  # Each `ui.*.focus` kind with arguments good enough to mint its path. The
  # values are shape-checked by `Aqua.Intents` (id prefixes, id-safe
  # characters), so they cannot be arbitrary.
  @intents [
    %{kind: "ui.activity.focus", args: %{"id" => "req_abc123"}},
    %{kind: "ui.execution.focus", args: %{"id" => "exec_abc123"}},
    %{kind: "ui.schedule.focus", args: %{"id" => "sched_abc123"}},
    %{kind: "ui.component.focus", args: %{"ref" => "tincture:acme/widget@1.0.0"}},
    %{kind: "ui.tincture.focus", args: %{"publisher" => "acme", "name" => "widget"}},
    %{kind: "ui.mcp_server.focus", args: %{"name" => "filesystem"}}
  ]

  defp root, do: Path.expand("../../../..", __DIR__)

  # One pane on the person's own estate, on a thread of its own, in the mode whose nav shows
  # every page: what it pushes for a navigate is what the browser would
  # follow.
  setup %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    estate = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: estate.id}
    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

    # A kept catalogue: the pane must not spawn a model-listing run whose
    # writes outlive this test and lock the next one's setup out of SQLite.
    :ok = PrismWeb.ModelCatalog.remember(estate.id, %{"models" => %{}})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(estate.id) end)

    {:ok, pane, _} =
      live_isolated(conn, PrismWeb.ThreadPaneLive,
        session: %{"athanor_id" => estate.id, "thread_id" => thread.id, "ui_mode" => "dev"}
      )

    {:ok, pane: pane, thread: thread, user: user, estate: estate}
  end

  defp pushed(%{pane: pane, thread: thread, user: user}, intent) do
    send(pane.pid, %Cyfr.Bus.ThreadEvent{
      athanor_id: thread.athanor_id,
      thread_id: thread.id,
      kind: :intents,
      data: %{intents: [intent], user_id: user.user_id}
    })

    render(pane)
    assert_push_event(pane, "aqua:intents", %{intents: [%{kind: "navigate", to: to}]})
    to
  end

  defp served_by(path) do
    # The router is the SSOT for which module serves the path — naming the
    # module here would let a re-route silently move the page out from
    # under the intent.
    assert %{plug: Phoenix.LiveView.Plug, log_module: module} =
             Phoenix.Router.route_info(EmissaryWeb.Router, "GET", path, "example.com"),
           "#{path} is served by no live route"

    module
  end

  test "every focus intent the assistant can mint is on the roster" do
    minted =
      Path.join(root(), "apps/cyfr/lib/aqua/intents.ex")
      |> Prima.Test.SourceTree.read()
      |> then(&Regex.scan(~r/validate\(%\{"kind" => "(ui\.[a-z_]+\.focus)"\}/, &1))
      |> Enum.map(fn [_, kind] -> kind end)
      |> Enum.sort()

    rostered = @intents |> Enum.map(& &1.kind) |> Enum.sort()

    assert minted == rostered,
           """
           `Aqua.Intents` mints focus intents this test does not check:

             only in actions.ex: #{inspect(minted -- rostered)}
             only on the roster:  #{inspect(rostered -- minted)}

           Add the new intent to `@intents` with arguments that pass its own
           validation. A focus intent whose page ignores its key navigates
           and does nothing, which is the defect this test exists to catch.
           """
  end

  for %{kind: kind, args: args} <- @intents do
    test "#{kind} lands on a page that reads what it carries", %{estate: estate} = context do
      assert {:ok, %{kind: "navigate", to: path} = intent} =
               Aqua.Intents.validate(Map.put(unquote(Macro.escape(args)), "kind", unquote(kind)))

      # `Aqua.Intents` mints the page-relative path; the pane prefixes the
      # athanor in focus before handing it to the client, the same split
      # `PrismWeb.ActiveContext.strip_focus/1` undoes.
      to = pushed(context, intent)
      assert to == PrismWeb.Focus.path(Athanors.route_slug(estate), path)

      uri = URI.parse(to)
      module = served_by(uri.path)

      source =
        root()
        |> Path.join(Path.relative_to(module.__info__(:compile)[:source], root()))
        |> Prima.Test.SourceTree.read()

      # A path-segment intent (`/components/:ref`) needs no query key: the
      # route itself carries the resource and Phoenix hands it over.
      for {key, _value} <- URI.decode_query(uri.query || "") do
        assert source =~ ~s|params["#{key}"]|,
               """
               #{unquote(kind)} navigates to #{path}, but #{inspect(module)}
               never reads `params[#{inspect(key)}]`.

               The intent is inert: the assistant moves the person to a page
               that shows the same list it showed before, while
               `PrismWeb.ActiveContext` tells the command palette a resource
               IS focused. Read the key in `handle_params/3` and put the page
               in the state a click on that row would have produced.
               """
      end
    end
  end

  test "a global page is pushed as it is, with no estate in its address",
       %{estate: estate, thread: thread} = context do
    path = PrismWeb.ChatLive.chat_path(Athanors.route_slug(estate), thread.id)
    assert PrismWeb.Nav.global?(path)

    assert {:ok, %{kind: "navigate", to: ^path} = intent} =
             Aqua.Intents.validate(%{"kind" => "ui.navigate", "path" => path})

    assert pushed(context, intent) == path
    assert served_by(URI.parse(path).path) == PrismWeb.ChatLive
  end
end
