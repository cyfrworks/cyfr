# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayerQuestionTest.Host do
  @moduledoc false
  # A page mounted through the context guard with the page's listening
  # layer, as the shell mounts it; `listen` mounts it as the desktop's
  # (`:own`) or the panel's (`false`) instead.
  use Phoenix.LiveView

  on_mount {CyfrWeb.ContextGuard, :protected}

  @impl true
  def mount(_params, session, socket),
    do: {:ok, assign(socket, test: session["test"], listen: Map.get(session, "listen", true))}

  @impl true
  def handle_info(message, socket) do
    send(socket.assigns.test, {:host, message})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.live_component
      module={PrismWeb.SystemLayer}
      id="system-layer"
      context={@context}
      listen={@listen}
    />
    """
  end
end

defmodule PrismWeb.SystemLayerQuestionTest do
  @moduledoc """
  A component's question as the page's layer draws it: on every open
  screen of the person's, one card per question however the read and the
  fact race; CYFR's frame around the component's words, which stay inside
  their block; each choice sending the answer it names, and a closed card
  "Don't allow", once; the card leaving when its question stops waiting;
  and "Always allow" for any caller through its fresh confirmation, drawn
  inside the card on the screen that asked and in front of the card on
  the others, the answer repeated exactly once.

  Questions are opened with no runner (`Cyfr.Test.QuestionFixtures`).
  """

  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  alias Cyfr.Test.QuestionFixtures, as: Q
  alias PrismWeb.SystemLayer.Prompt
  alias PrismWeb.SystemLayerQuestionTest.Host
  alias Sanctum.Context
  alias Sanctum.TestContext.Authenticator

  @answered [:cyfr, :sanctum, :question, :answered]

  setup %{conn: conn} do
    Q.isolate!()
    Sanctum.Test.Newcomers.directory!()

    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()

    ctx =
      Context.build(
        user_id: user.user_id,
        athanor_id: athanor.id,
        permissions: Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    component = Q.catalyst!(ctx)

    test = self()
    handler = "question-answered-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        @answered,
        fn _event, _measurements, meta, _config -> send(test, {:answered, meta.ref}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Each `question.answer` the gate admits, wherever it came from: a
    # repeat is counted where it is dispatched, not by what it won.
    dispatched = "question-dispatched-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        dispatched,
        [:cyfr, :sanctum, :decision, :admitted],
        fn _event, _measurements, meta, _config ->
          if meta[:tool] == "question" and meta[:action] == "answer",
            do: send(test, :answer_dispatched)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(dispatched) end)

    %{conn: conn, user: user, athanor: athanor, ctx: ctx, component: component}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp screen!(%{conn: conn, athanor: athanor}, session \\ %{}) do
    {:ok, view, _html} =
      live_isolated(conn, Host,
        session: Map.merge(%{"athanor_id" => athanor.id, "test" => self()}, session)
      )

    view
  end

  defp open_prompt(view) do
    case Regex.run(~r/data-prompt-id="([^"]+)"/, render(view)) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp shows!(view, prompt_id, what \\ "the card"),
    do: wait_until(fn -> open_prompt(view) == prompt_id end, 2_000, what)

  defp layer_assigns(view) do
    {by_cid, _ids, _next} = :sys.get_state(view.pid).components

    Enum.find_value(by_cid, fn {_cid, entry} ->
      if elem(entry, 0) == PrismWeb.SystemLayer and elem(entry, 1) == "system-layer",
        do: elem(entry, 2)
    end)
  end

  defp view_context(view), do: :sys.get_state(view.pid).socket.assigns.context

  defp choose(view, choice) do
    view |> element(~s([data-test="question-choice"][data-choice="#{choice}"])) |> render_click()
  end

  defp more(view), do: view |> element(~s([data-test="question-more"])) |> render_click()

  # A passkey's proof given from `view`: the layer opens the account pages
  # with the record's request, and the person's passkey answers it there.
  defp prove_here!(view, ref, authenticator) do
    view |> element(~s([data-test="confirm-passkey"][phx-value-ref="#{ref}"])) |> render_click()
    assert_push_event(view, "system_layer:hop", %{layer: "system-layer", url: url})
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, request} = fragment |> Prima.SignIn.parse_fragment() |> elem(1) |> Prima.SignIn.decode()
    ctx = view_context(view)
    account = Sanctum.TestContext.account!(ctx.user_id)
    answer = Authenticator.answer(authenticator, request, account.identifier)

    assert {:ok, %{purpose: :confirm, ref: ^ref}} =
             Sanctum.SignIn.answer(answer, {:session, ctx.session_token_hash})
  end

  # The ref of the confirmation the screen's card waits on.
  defp waited_ref(view) do
    [ref] = Map.keys(layer_assigns(view).panels)
    ref
  end

  defp end_views, do: Cyfr.Test.Sandbox.end_views()

  # The elements `selector` matches in rendered HTML or in one element.
  defp find(html, selector) when is_binary(html), do: find(LazyHTML.from_fragment(html), selector)
  defp find(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.to_list()

  # ---------------------------------------------------------------------------
  # Where it is drawn
  # ---------------------------------------------------------------------------

  describe "the card" do
    test "is drawn on two screens of the person, and on one opened while it waits", setup do
      first = screen!(setup)
      second = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)

      for view <- [first, second] do
        shows!(view, id)
        assert has_element?(view, "#system-layer-title", "tables wants to delete a table")

        assert has_element?(
                 view,
                 ~s([data-test="question-component"]),
                 "tables, published by local"
               )

        assert has_element?(view, ~s([data-test="question-caller"]), "you")
        # In the person's own time zone, as the layer's script writes it.
        assert has_element?(
                 view,
                 ~s([data-test="question-deadline"] time[data-local][datetime$="Z"])
               )

        assert has_element?(
                 view,
                 ~s([data-test="question-summary"]),
                 "Drop the table users in the project acme"
               )

        assert has_element?(view, ~s([data-test="question-operation"]), "DROP TABLE users;")
        assert length(find(render(view), ~s([data-test="question-choice"]))) == 4
      end

      # A screen opened while it waits reads it at its first open.
      third = screen!(setup)
      assert open_prompt(third) == id
      end_views()
    end

    test "is drawn by neither the desktop's layer nor the panel's", setup do
      desktop = screen!(setup, %{"listen" => :own})
      panel = screen!(setup, %{"listen" => false})
      page = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)

      shows!(page, Prompt.question_id(ref))
      assert open_prompt(desktop) == nil
      assert open_prompt(panel) == nil

      # Nor at an open of the stream: a desktop mounted while it waits.
      assert open_prompt(screen!(setup, %{"listen" => :own})) == nil
      end_views()
    end

    test "a fact heard again draws no second card", setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(view, id)

      ctx = view_context(view)
      actor = Context.actor(ctx)

      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.prompts(actor, ctx.user_id),
          Cyfr.Bus.Prompt.new(actor, :question, :opened, ref: ref)
        )

      render(view)
      assert %{current: %{id: ^id}, queue: []} = layer_assigns(view)
      end_views()
    end

    test "a stream opened again reads what waits and draws no second card", setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(view, id)

      # The listener's deadline: the layer opens the stream again and reads
      # every waiting question afresh.
      Phoenix.LiveView.send_update(view.pid, PrismWeb.SystemLayer,
        id: "system-layer",
        listen: :ended
      )

      render(view)
      assert %{current: %{id: ^id}, queue: [], listening: %{pid: pid}} = layer_assigns(view)
      assert is_pid(pid)
      end_views()
    end

    test "says who started the run in a person's words, and offers no switch for one unknown",
         setup do
      view = screen!(setup)

      for {caller, words, switch?} <- [
            {"agent:aqua", "the assistant aqua", true},
            {"tincture:local.board", "the app local.board", true},
            {"device:pcl_0123456789abcdef", "a paired device (…abcdef)", true},
            {"unknown", "someone CYFR does not know", false}
          ] do
        {run, ref} = Q.open!(setup.ctx, setup.component, caller: caller)
        shows!(view, Prompt.question_id(ref))
        assert has_element?(view, ~s([data-test="question-caller"]), words)
        more(view)
        assert has_element?(view, ~s([data-test="question-switch"])) == switch?
        Q.end!(setup.ctx, run, :withdrawn)
        wait_until(fn -> open_prompt(view) == nil end, 2_000, "the card gone")
      end

      end_views()
    end
  end

  describe "the pages that draw it" do
    # Every signed-in page of the console, mounted while a question and
    # another client's confirmation both wait: a page draws the question
    # exactly when it draws the confirmation, since one listening layer
    # draws both. A page with none (the legal page among them) draws
    # neither, and attention still lists the question.
    test "are the pages that draw another client's confirmation", setup do
      other = other_session!(setup.ctx)

      assert {:error, {:confirmation_required, %{id: id}}} =
               PrismWeb.Ops.call_tool(other, "vault/create", %{
                 "name" => "pages-#{System.unique_integer([:positive])}",
                 "kind" => "api_key",
                 "fields" => %{"KEY" => "x"},
                 "destination" => %{"hosts" => ["api.example.com"]}
               })

      confirmation = Prompt.confirmation_id(Prima.Confirmation.ref(id))
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      question = Prompt.question_id(ref)
      workspace = workspace!(setup.ctx)

      drawn =
        for {entry, url} <- signed_in_pages(workspace), into: %{} do
          ids = drawn_on(setup.conn, url)
          assert question in ids == confirmation in ids, "#{entry}: #{inspect(ids)}"
          {entry, question in ids}
        end

      # The pages and states that draw neither: no listening layer, a
      # redirect, or a workspace that is not there.
      neither = for {entry, false} <- drawn, do: entry

      assert Enum.sort(neither) ==
               Enum.sort([
                 "/chat",
                 "/a/:athanor/workspace/:id (missing)"
                 | Enum.map(
                     ~w(files activities enforcements executions reports builds tips legal),
                     &("/a/:athanor/" <> &1)
                   )
               ])

      # So the comparison above compares something on the pages that listen.
      assert drawn["/a/:athanor/vault"]
      assert drawn["/a/:athanor/components/:ref"]
      assert drawn["/a/:athanor/workspace/:id"]
      end_views()
    end

    # A workspace thread of the person's, as its opening leaves it.
    defp workspace!(ctx) do
      id = Prima.UUID7.generate_id("thread")
      now = DateTime.utc_now()

      {1, _} =
        Arca.Repo.insert_all(Arca.Schemas.Thread, [
          %{
            id: id,
            athanor_id: ctx.athanor_id,
            kind: "workspace",
            workspace_state: "done",
            workspace_outcome: "done",
            title: "Probe",
            created_by: Prima.Author.system(),
            last_message_at: now,
            inserted_at: now,
            updated_at: now
          }
        ])

      id
    end

    # Each signed-in route as a page to open, the workspace's twice: one
    # that is there and one that is not.
    defp signed_in_pages(workspace) do
      route = Sanctum.Tenancy.Athanors.route_slug(seated_athanor())

      for path <- signed_in_paths(),
          {entry, id} <-
            if(String.contains?(path, ":id"),
              do: [{path, workspace}, {path <> " (missing)", "wst_none"}],
              else: [{path, nil}]
            ) do
        url =
          path
          |> String.replace(":athanor", route)
          |> String.replace(":ref", "catalyst:local.tables:1.0.0")
          |> then(&if(id, do: String.replace(&1, ":id", id), else: &1))

        {entry, url}
      end
    end

    defp signed_in_paths do
      Cyfr.Boundaries.router().__routes__()
      |> Enum.filter(&(&1.metadata[:auth] == :browser_authenticated))
      |> Enum.map(& &1.path)
      |> Enum.uniq()
    end

    # The prompts every system layer of the page holds, open or waiting;
    # none for a route that sends the browser elsewhere.
    defp drawn_on(conn, url) do
      case live(conn, url) do
        {:ok, view, _html} ->
          render(view)
          {by_cid, _ids, _next} = :sys.get_state(view.pid).components

          for {_cid, entry} <- by_cid,
              elem(entry, 0) == PrismWeb.SystemLayer,
              %{current: current, queue: queue} = elem(entry, 2),
              prompt <- [current | queue],
              prompt != nil,
              do: prompt.id

        {:error, {_redirect, _to}} ->
          []
      end
    end

    defp other_session!(ctx) do
      {:ok, session} = Sanctum.TestContext.create_session(%{ctx | provider: "github"})

      {:ok, other} =
        Sanctum.Caller.establish(session.token, focus: ctx.athanor_id, refresh: false)

      other
    end
  end

  describe "a read that races the fact" do
    # The page mounts while its layer's first read of the waiting
    # questions is held in the page's own process, before the read
    # (`:admitted`, the gate's admission of `question.pending`) or just
    # after its query returned (`:read`). A question opens meanwhile, and
    # the read goes on only once its opened fact is queued behind it: the
    # read finds the question and the fact repeats it, or the read misses
    # it and the fact alone tells of it. Either way, one card.
    for {point, what} <- [admitted: "finds", read: "misses"] do
      test "draws one card when the read #{what} the question whose fact waits behind it",
           setup do
        {view, ref} = race_the_read!(setup, unquote(point))
        id = Prompt.question_id(ref)

        shows!(view, id)
        assert %{current: %{id: ^id}, queue: []} = layer_assigns(view)
        end_views()
      end
    end

    defp race_the_read!(setup, point) do
      test = self()

      helper =
        spawn_link(fn ->
          receive do
            {:read_held, view_pid} ->
              {_run, ref} = Q.open!(setup.ctx, setup.component)

              wait_until(
                fn -> queued?(view_pid, ref) end,
                2_000,
                "the opened fact queued behind the read"
              )

              send(test, {:asked, ref})
              send(view_pid, :release_read)
          end
        end)

      handler = "question-read-held-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler) end)

      event =
        if point == :admitted,
          do: [:cyfr, :sanctum, :decision, :admitted],
          else: [:arca, :repo, :query]

      :ok = :telemetry.attach(handler, event, &__MODULE__.hold_read/4, {handler, helper})
      view = screen!(setup)
      assert_receive {:asked, ref}, 5_000
      {view, ref}
    end

    defp queued?(pid, ref) do
      {:messages, messages} = Process.info(pid, :messages)

      Enum.any?(messages, fn message ->
        inspect(message, limit: :infinity) =~ ref and inspect(message) =~ "opened"
      end)
    end
  end

  @doc false
  # Holds the first process that reaches a read of the waiting questions
  # at the attached event, once, until released.
  def hold_read(event, _measurements, metadata, {handler, helper}) do
    if question_read?(event, metadata) do
      :telemetry.detach(handler)
      send(helper, {:read_held, self()})

      receive do
        :release_read -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  defp question_read?([:cyfr, :sanctum, :decision, :admitted], metadata),
    do: metadata.tool == "question" and metadata.action == "pending"

  defp question_read?([:arca, :repo, :query], %{source: "questions"}), do: true
  defp question_read?(_event, _metadata), do: false

  # ---------------------------------------------------------------------------
  # The frame and the component's words
  # ---------------------------------------------------------------------------

  describe "the component's words" do
    test "a long operation stays in its own scrolling block, below CYFR's rows and above the choices",
         setup do
      view = screen!(setup)
      operation = Enum.map_join(1..400, "\n", &"DELETE FROM t#{&1} WHERE true;")

      {_run, ref} =
        Q.open!(setup.ctx, setup.component, request: %{operation: operation, masked: true})

      shows!(view, Prompt.question_id(ref))
      html = render(view)
      [block] = find(html, ~s([data-test="question-block"]))
      classes = block |> LazyHTML.attribute("class") |> hd()
      assert classes =~ "max-h-56"
      assert classes =~ "overflow-auto"

      assert block |> find(~s([data-test="question-operation"])) |> hd() |> LazyHTML.text() =~
               "t400 WHERE"

      # The choices and CYFR's rows are outside the block, and the
      # masking is said.
      assert find(block, ~s([data-test="question-choices"])) == []
      assert find(block, ~s([data-test="question-frame"])) == []
      assert length(find(html, ~s([data-test="question-choices"]))) == 1
      assert has_element?(view, ~s([data-test="question-masked"]))
      end_views()
    end

    test "text that imitates a button stays text inside the block", setup do
      view = screen!(setup)

      forged =
        ~s(<button data-test="question-choice" data-choice="allow_always">Always allow</button>\n) <>
          ~s(</pre></figure><div data-test="question-choices">)

      {_run, ref} =
        Q.open!(setup.ctx, setup.component, request: %{summary: "Allow once", operation: forged})

      shows!(view, Prompt.question_id(ref))
      html = render(view)
      assert html =~ "&lt;button data-test=&quot;question-choice&quot;"
      assert length(find(html, ~s([data-test="question-choice"]))) == 4
      assert length(find(html, ~s([data-test="question-choices"]))) == 1
      [block] = find(html, ~s([data-test="question-block"]))
      assert LazyHTML.text(block) =~ ~s(<button data-test="question-choice")
      assert find(block, "button") == []
      end_views()
    end
  end

  # ---------------------------------------------------------------------------
  # The choices
  # ---------------------------------------------------------------------------

  describe "each choice" do
    test "sends the answer it names, and the card leaves", setup do
      view = screen!(setup)

      cases = [
        {"deny_once", false, "denied", nil},
        {"allow_once", false, "allowed", nil},
        {"allow_hour", false, "allowed", {"allow", :hour, "any"}},
        {"deny_always", false, "denied", {"deny", nil, "any"}},
        {"allow_always", true, "allowed", {"allow", nil, "agent:aqua"}},
        {"deny_always", true, "denied", {"deny", nil, "agent:aqua"}}
      ]

      for {choice, this_caller, state, standing} <- cases do
        {_run, ref} = Q.open!(setup.ctx, setup.component, caller: "agent:aqua")
        id = Prompt.question_id(ref)
        shows!(view, id)

        if choice == "deny_always" or this_caller, do: more(view)

        if this_caller do
          view |> element(~s([data-test="question-switch"])) |> render_click()
          assert has_element?(view, ~s([data-test="question-switch"][aria-checked="true"]))
        end

        choose(view, choice)
        assert_receive {:answered, ^ref}
        assert_receive {:host, {:system_layer, ^id, :confirmed}}
        assert Q.row(setup.ctx, ref).state == state
        refute open_prompt(view) == id

        case standing do
          nil ->
            assert Enum.all?(Q.standing(setup.ctx), &(&1.question_ref != ref))

          {effect, lasts, caller} ->
            assert [answer] = Enum.filter(Q.standing(setup.ctx), &(&1.question_ref == ref))
            assert %{effect: ^effect, caller: ^caller, action: "delete_table"} = answer

            case lasts do
              nil ->
                assert answer.until == nil

              :hour ->
                left = DateTime.diff(answer.until, DateTime.utc_now(), :second)
                assert left in 3500..3600
            end
        end

        # Each answer stands in the next ask's way: removed, so the next
        # question opens.
        for answer <- Q.standing(setup.ctx),
            do: :ok = Arca.Questions.delete_standing(Context.actor(setup.ctx), answer.id)
      end

      refute_received {:answered, _again}
      end_views()
    end

    test "an answer that lasts binds the words the question was asked under", setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      shows!(view, Prompt.question_id(ref))

      # A newer version rewords the action while the card waits.
      Q.catalyst!(setup.ctx, "tables", "2.0.0", [
        %{"name" => "delete_table", "title" => "delete every table"}
      ])

      choose(view, "allow_hour")
      assert_receive {:answered, ^ref}

      assert [%{declaration_digest: digest}] = Q.standing(setup.ctx)

      assert digest ==
               Prima.Manifest.Asks.digest(%{name: "delete_table", title: "delete a table"})

      end_views()
    end

    test "an answer that would last is refused once the component has left; once still answers",
         setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(view, id)

      :ok =
        Arca.ComponentStorage.delete_component(
          Context.actor(setup.ctx),
          "tables",
          "1.0.0",
          "local",
          "catalyst"
        )

      choose(view, "allow_hour")
      assert open_prompt(view) == id

      assert has_element?(
               view,
               ~s([role="alert"]),
               "This component is no longer installed, so this answer cannot be kept."
             )

      assert has_element?(view, ~s([data-test="question-choices"]))
      assert Q.standing(setup.ctx) == []
      refute_received {:answered, ^ref}

      choose(view, "allow_once")
      assert_receive {:answered, ^ref}
      assert Q.row(setup.ctx, ref).state == "allowed"
      assert Q.standing(setup.ctx) == []
      end_views()
    end

    test "closing the card without a choice is Don't allow, once", setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(view, id)

      view |> with_target("#system-layer") |> render_click("dismiss", %{"id" => id})

      assert_receive {:answered, ^ref}
      refute_receive {:answered, ^ref}, 200
      assert Q.row(setup.ctx, ref).state == "denied"
      assert Q.standing(setup.ctx) == []
      assert open_prompt(view) == nil
      assert_receive {:host, {:system_layer, ^id, :dismissed}}
      end_views()
    end
  end

  # ---------------------------------------------------------------------------
  # Leaving
  # ---------------------------------------------------------------------------

  describe "the card leaves" do
    test "when it is answered on another screen, and when its run ends, expired or withdrawn",
         setup do
      first = screen!(setup)
      second = screen!(setup)

      {_run, ref} = Q.open!(setup.ctx, setup.component)
      shows!(first, Prompt.question_id(ref))
      shows!(second, Prompt.question_id(ref))
      choose(first, "allow_once")
      wait_until(fn -> open_prompt(second) == nil end, 2_000, "answered elsewhere")

      for stage <- [:expired, :withdrawn] do
        {run, ref} = Q.open!(setup.ctx, setup.component)
        shows!(first, Prompt.question_id(ref))
        Q.end!(setup.ctx, run, stage)
        wait_until(fn -> open_prompt(first) == nil end, 2_000, "#{stage}")
      end

      end_views()
    end

    test "a question no longer waiting takes its card away when it is answered", setup do
      view = screen!(setup)
      {run, ref} = Q.open!(setup.ctx, setup.component)
      shows!(view, Prompt.question_id(ref))

      # The run ends and its announcement is lost: the answer is refused
      # as no longer waiting, and the card goes.
      {:ok, _ended} =
        Arca.Execution.record_end(
          Prima.Actor.in_athanor(setup.ctx.athanor_id),
          run.execution_id,
          "cancelled",
          %{completed_at: DateTime.utc_now(), duration_ms: 1},
          run.attempt_id,
          grant: :stored,
          verify: fn _grant -> :ok end
        )

      choose(view, "allow_once")
      assert open_prompt(view) == nil
      refute_received {:answered, ^ref}
      end_views()
    end
  end

  # ---------------------------------------------------------------------------
  # Who may read it
  # ---------------------------------------------------------------------------

  describe "a frame" do
    # A frame's context is the person's, under the frame credential's
    # surface, as `Sanctum.Caller`'s frame clause leaves it: one granted
    # `prompt.changes` hears a question's ref and nothing more, and cannot
    # exchange the ref for what the question says.
    test "is refused question.pending for a ref it heard", setup do
      {_run, ref} = Q.open!(setup.ctx, setup.component)

      frame = %{
        setup.ctx
        | auth_method: :tincture,
          frame: %{id: "fcr_card", tincture: "tincture:local.board:1.0.0"}
      }

      assert {:error, %{reason: {:consent_class_required, _surface}}} =
               Sanctum.Gate.call_external("question", frame, %{
                 "action" => "pending",
                 "ref" => ref
               })
    end
  end

  # ---------------------------------------------------------------------------
  # Always allow, for any caller
  # ---------------------------------------------------------------------------

  describe "always allow for any caller" do
    test "is confirmed inside the card that asked, and the answer is repeated once", setup do
      authenticator = Sanctum.TestContext.passkey!(setup.user.user_id)
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(view, id)

      choose(view, "allow_always")
      assert_received :answer_dispatched

      # The confirmation is drawn in the card, whose choices step aside.
      assert open_prompt(view) == id
      assert has_element?(view, ~s([data-test="question"]))
      assert has_element?(view, ~s([data-test="confirmation"][data-own="true"]))
      refute has_element?(view, ~s([data-test="question-choices"]))
      assert Q.row(setup.ctx, ref).state == "open"
      assert Q.standing(setup.ctx) == []

      prove_here!(view, waited_ref(view), authenticator)

      assert_receive {:answered, ^ref}, 2_000
      wait_until(fn -> open_prompt(view) == nil end, 2_000, "the card gone")
      assert Q.row(setup.ctx, ref).state == "allowed"
      assert [%{effect: "allow", caller: "any", until: nil}] = Q.standing(setup.ctx)
      refute_receive {:answered, ^ref}, 300

      # The answer was sent twice in all: asked, then repeated once.
      assert_received :answer_dispatched
      refute_received :answer_dispatched
      end_views()
    end

    test "a proof given while another question's confirmation stands in front of the card is repeated",
         setup do
      authenticator = Sanctum.TestContext.passkey!(setup.user.user_id)
      asking = screen!(setup)
      proving = screen!(setup)
      {_run, first} = Q.open!(setup.ctx, setup.component)
      shows!(asking, Prompt.question_id(first))
      choose(asking, "allow_always")
      original = waited_ref(asking)
      shows!(proving, Prompt.confirmation_id(original), "the first confirmation")

      # A second question, answered "Always allow" from the other screen:
      # its confirmation steps in front of the first card on the asking
      # screen, whose own confirmation still waits.
      {_run, second} =
        Q.open!(setup.ctx, setup.component, request: %{action: "delete_rows"})

      assert {:error, {:confirmation_required, %{id: second_id}}} =
               PrismWeb.Ops.call_tool(view_context(proving), "question/answer", %{
                 "ref" => second,
                 "answer" => %{"effect" => "allow", "lasts" => "always", "covers" => "any_caller"}
               })

      shows!(asking, Prompt.confirmation_id(Prima.Confirmation.ref(second_id)), "in front")
      assert Enum.any?(layer_assigns(asking).queue, &(&1.id == Prompt.question_id(first)))

      prove_here!(proving, original, authenticator)

      assert_receive {:answered, ^first}, 2_000
      assert Q.row(setup.ctx, first).state == "allowed"
      assert [%{action: "delete_table", caller: "any", until: nil}] = Q.standing(setup.ctx)
      assert Q.row(setup.ctx, second).state == "open"
      end_views()
    end

    for {fact, words} <- [
          voided: "The confirmation was withdrawn.",
          cancelled: "The confirmation was cancelled.",
          expired: "The confirmation expired."
        ] do
      test "a card's confirmation #{fact} while another's stands in front says so on that card alone",
           setup do
        asking = screen!(setup)
        proving = screen!(setup)
        {_run, first} = Q.open!(setup.ctx, setup.component)
        first_card = Prompt.question_id(first)
        shows!(asking, first_card)
        choose(asking, "allow_always")
        original = waited_ref(asking)

        # A second question's confirmation, asked from the other screen,
        # steps in front of the first card on the asking screen.
        {_run, second} =
          Q.open!(setup.ctx, setup.component, request: %{action: "delete_rows"})

        assert {:error, {:confirmation_required, %{id: second_id}}} =
                 PrismWeb.Ops.call_tool(view_context(proving), "question/answer", %{
                   "ref" => second,
                   "answer" => %{
                     "effect" => "allow",
                     "lasts" => "always",
                     "covers" => "any_caller"
                   }
                 })

        in_front = Prompt.confirmation_id(Prima.Confirmation.ref(second_id))
        shows!(asking, in_front, "in front")

        ctx = view_context(asking)
        actor = Context.actor(ctx)

        :ok =
          Cyfr.Bus.broadcast(
            actor,
            Cyfr.Bus.prompts(actor, ctx.user_id),
            Cyfr.Bus.Prompt.new(actor, :confirmation, unquote(fact), ref: original)
          )

        wait_until(
          fn -> not Map.has_key?(layer_assigns(asking).held, original) end,
          2_000,
          "the first confirmation's end"
        )

        # The confirmation in front, whose own record still waits, says
        # nothing of the first card's.
        assert open_prompt(asking) == in_front
        refute has_element?(asking, ~s([role="alert"]), unquote(words))

        # The first card, back once the one in front is closed, says it.
        asking |> with_target("#system-layer") |> render_click("dismiss", %{"id" => in_front})
        assert open_prompt(asking) == first_card
        assert has_element?(asking, ~s([data-test="question-said"]), unquote(words))
        assert has_element?(asking, ~s([data-test="question-choices"]))
        assert Q.row(setup.ctx, first).state == "open"
        end_views()
      end
    end

    test "withdrawn, the confirmation leaves the card and its choices come back unanswered",
         setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      shows!(view, Prompt.question_id(ref))
      choose(view, "allow_always")
      confirmation = waited_ref(view)
      ctx = view_context(view)
      actor = Context.actor(ctx)

      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.prompts(actor, ctx.user_id),
          Cyfr.Bus.Prompt.new(actor, :confirmation, :voided, ref: confirmation)
        )

      wait_until(
        fn -> has_element?(view, ~s([data-test="question-choices"])) end,
        2_000,
        "the choices back"
      )

      assert has_element?(view, ~s([role="alert"]), "The confirmation was withdrawn.")
      assert layer_assigns(view).held == %{}
      assert Q.row(setup.ctx, ref).state == "open"
      refute_received {:answered, ^ref}
      end_views()
    end

    test "a run that ends while the confirmation waits clears both screens and leaves nothing standing",
         setup do
      asking = screen!(setup)
      other = screen!(setup)
      {run, ref} = Q.open!(setup.ctx, setup.component)
      shows!(asking, Prompt.question_id(ref))
      choose(asking, "allow_always")
      confirmation = waited_ref(asking)
      shows!(other, Prompt.confirmation_id(confirmation), "the confirmation in front")

      Q.end!(setup.ctx, run, :withdrawn)

      wait_until(
        fn -> is_nil(open_prompt(asking)) and is_nil(open_prompt(other)) end,
        2_000,
        "both screens clear"
      )

      assert Q.standing(setup.ctx) == []

      assert {:ok, %{state: "cancelled"}} =
               Arca.PendingConfirmations.get(Context.actor(setup.ctx), confirmation)

      end_views()
    end

    test "is confirmed on a second screen, where it goes in front of the card; the asking card repeats once",
         setup do
      authenticator = Sanctum.TestContext.passkey!(setup.user.user_id)
      asking = screen!(setup)
      other = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(asking, id)
      shows!(other, id)

      choose(asking, "allow_always")
      confirmation = waited_ref(asking)
      shows!(other, Prompt.confirmation_id(confirmation), "the confirmation in front")
      assert [%{id: ^id}] = layer_assigns(other).queue

      prove_here!(other, confirmation, authenticator)

      assert_receive {:answered, ^ref}, 2_000
      wait_until(fn -> open_prompt(asking) == nil end, 2_000, "the asking card gone")
      wait_until(fn -> open_prompt(other) == nil end, 2_000, "the other screen's card gone")
      assert [%{effect: "allow", caller: "any", until: nil}] = Q.standing(setup.ctx)
      refute_receive {:answered, ^ref}, 300
      end_views()
    end

    test "closing the confirmation on the second screen answers nothing, and the card comes back",
         setup do
      asking = screen!(setup)
      other = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(asking, id)
      shows!(other, id)

      choose(asking, "allow_always")
      confirmation = waited_ref(asking)
      shows!(other, Prompt.confirmation_id(confirmation), "the confirmation in front")

      other
      |> with_target("#system-layer")
      |> render_click("dismiss", %{"id" => Prompt.confirmation_id(confirmation)})

      assert open_prompt(other) == id
      assert has_element?(other, ~s([data-test="question-choices"]))
      refute_received {:answered, ^ref}
      assert Q.row(setup.ctx, ref).state == "open"

      # The asking screen still waits on the confirmation, untouched.
      assert has_element?(asking, ~s([data-test="confirmation"][data-ref="#{confirmation}"]))

      assert {:ok, %{state: "pending"}} =
               Arca.PendingConfirmations.get(Context.actor(setup.ctx), confirmation)

      end_views()
    end

    test "cancelled, the confirmation leaves the card and its choices come back unanswered, on both screens",
         setup do
      asking = screen!(setup)
      other = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      id = Prompt.question_id(ref)
      shows!(asking, id)
      shows!(other, id)

      choose(asking, "allow_always")
      confirmation = waited_ref(asking)
      shows!(other, Prompt.confirmation_id(confirmation), "the confirmation in front")

      asking |> element(~s([data-test="confirm-cancel"])) |> render_click()

      wait_until(
        fn -> has_element?(asking, ~s([data-test="question-choices"])) end,
        2_000,
        "the asking card's choices back"
      )

      refute has_element?(asking, ~s([data-test="confirmation"]))
      assert has_element?(asking, ~s([role="alert"]), "still unanswered")
      shows!(other, id, "the other screen's card back")
      assert Q.row(setup.ctx, ref).state == "open"
      refute_received {:answered, ^ref}

      # Asked again, it asks for a new confirmation and repeats only that.
      choose(asking, "allow_always")
      refute waited_ref(asking) == confirmation
      end_views()
    end

    test "expired, the confirmation leaves the card and its choices come back unanswered",
         setup do
      view = screen!(setup)
      {_run, ref} = Q.open!(setup.ctx, setup.component)
      shows!(view, Prompt.question_id(ref))
      choose(view, "allow_always")
      confirmation = waited_ref(view)

      ctx = view_context(view)
      actor = Context.actor(ctx)

      :ok =
        Cyfr.Bus.broadcast(
          actor,
          Cyfr.Bus.prompts(actor, ctx.user_id),
          Cyfr.Bus.Prompt.new(actor, :confirmation, :expired, ref: confirmation)
        )

      wait_until(
        fn -> has_element?(view, ~s([data-test="question-choices"])) end,
        2_000,
        "the choices back"
      )

      assert layer_assigns(view).held == %{}
      assert Q.row(setup.ctx, ref).state == "open"
      refute_received {:answered, ^ref}
      end_views()
    end
  end
end
