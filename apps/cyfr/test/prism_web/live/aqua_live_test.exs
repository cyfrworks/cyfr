# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A store that cannot give the Aqua crew listing; every other read is the
# local adapter's.
defmodule PrismWeb.AquaLiveTest.UnreadableCrew do
  @moduledoc false
  use Arca.Storage.TestDouble

  @crew Compendium.AquaPath.crew_root()

  def list_typed(_actor, @crew), do: {:error, :eacces}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

defmodule PrismWeb.AquaLiveTest do
  # The Aqua page shows the tree of the person's own athanor, and every
  # write lands there through the `aqua` and `notes` tools. These drive the LiveView
  # itself: a test of the tool alone cannot catch a handler that reads
  # the wrong context or a card that offers a verb the tool refuses.
  use PrismWeb.ConnCase, async: false

  setup do
    test_path = Path.join(System.tmp_dir!(), "aqua_live_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      # A turn the test left finishing may still write under the path; the
      # runners are stopped after this callback, so the removal tolerates it.
      File.rm_rf(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    :ok
  end

  defp get_agent(ctx, name),
    do: Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => name})

  # The storage adapter for the rest of the test.
  defp storage!(adapter) do
    original = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, adapter)

    on_exit(fn ->
      if original,
        do: Application.put_env(:arca, :storage_adapter, original),
        else: Application.delete_env(:arca, :storage_adapter)
    end)
  end

  test "a person's page edits their own tree, and a write lands in it alone",
       %{conn: conn} do
    user = test_user()
    mine = Sanctum.Test.People.athanor!(user.user_id)
    theirs = Sanctum.Test.People.athanor!(test_user().user_id)
    conn = log_in_user(conn, user)

    mine_ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}
    their_ctx = %{mine_ctx | athanor_id: theirs.id}

    {:ok, _} =
      Cyfr.Test.AquaTool.call(mine_ctx, %{
        "action" => "create",
        "name" => "tom",
        "title" => "Tom",
        "content" => "# Tom"
      })

    refute Arca.exists?(Sanctum.Context.actor(their_ctx), Compendium.AquaPath.agent_file("tom"))

    {view, html} = mount_athanor(conn, "/aqua", mine)
    assert html =~ "aqua-card-tom"

    view
    |> with_target("#aqua-agents")
    |> render_click("editor_update_field", %{
      "name" => "tom",
      "field" => "title",
      "value" => "My Tom"
    })

    assert {:ok, %{"title" => "My Tom"}} = get_agent(mine_ctx, "tom")
    refute Arca.exists?(Sanctum.Context.actor(their_ctx), Compendium.AquaPath.agent_file("tom"))
  end

  test "the person's browser setting stands beside the soul's capabilities, which leave the browser's actions to it",
       %{conn: conn} do
    user = test_user()
    mine = Sanctum.Test.People.athanor!(user.user_id)
    conn = log_in_user(conn, user)
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}

    {view, _html} = mount_athanor(conn, "/aqua", mine)
    switch = ~s([data-test="aqua-browser-switch"])

    assert has_element?(view, switch <> ~s([aria-checked="true"]), "On")

    assert has_element?(
             view,
             ~s([data-test="aqua-browser-add"] a[href*="programs?add=browser&"]),
             "Add Aqua's browser"
           )

    # The second, for work kept apart, is offered beside it.
    assert has_element?(
             view,
             ~s([data-test="aqua-browser-add-apart"] a[href*="programs?add=browser-apart"]),
             "Add the second browser"
           )

    # The setting decides the browser's own actions, so no checkbox offers
    # them; turning it on is the person's switch alone, so none offers
    # that either, and turning it off stays a tool the soul is offered.
    refute has_element?(view, ~s([phx-value-key="browser.open"]))
    refute has_element?(view, ~s([phx-value-key="browser.read"]))
    refute has_element?(view, ~s([phx-value-key="browser.turn_on"]))
    assert has_element?(view, ~s([phx-value-key="browser.turn_off"]))

    view |> element(switch) |> render_click()
    assert {:ok, false} = Aqua.BrowserSetting.allowed?(ctx)
    assert has_element?(view, switch <> ~s([aria-checked="false"]), "Off")

    view |> element(switch) |> render_click()
    assert {:ok, true} = Aqua.BrowserSetting.allowed?(ctx)
    assert has_element?(view, switch <> ~s([aria-checked="true"]))
  end

  # Point the soul at `ref`, and put it back afterwards: the agent files live
  # in the suite's shared tree, so a write left behind is the next test's
  # starting state.
  defp soul_names_catalyst!(ctx, ref) do
    {:ok, soul} = Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => "aqua"})
    was = soul["catalyst_ref"] || ""

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ref
      })

    on_exit(fn ->
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => was
      })
    end)

    :ok
  end

  # A brain: a catalyst speaking `model/chat@1` at 0.1.0 with `needs`.
  defp publish_brain!(ctx, name, needs) do
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: name,
        version: "0.1.0",
        type: "catalyst",
        description: "A model catalyst",
        manifest:
          Jason.encode!(%{
            "contracts" => [Prima.Model.chat_contract()],
            "needs" => needs,
            "caps" => %{
              "egress" => %{"domains" => Enum.flat_map(Map.values(needs), &(&1["hosts"] || []))}
            }
          })
      })

    :ok
  end

  # The catalogue this athanor's pages read, as a load left it, forgotten
  # when the test ends.
  defp remember_catalogue!(models, refs) do
    athanor = seated_athanor()
    :ok = PrismWeb.ModelCatalog.remember(athanor.id, %{"models" => models, "refs" => refs})
    on_exit(fn -> PrismWeb.ModelCatalog.forget(athanor.id) end)
  end

  # What the page's picker offers, and the reference each provider names.
  defp picker(view) do
    assigns = :sys.get_state(view.pid).socket.assigns
    {assigns.models_by_provider, assigns.catalyst_refs}
  end

  # The reference of every `models` call traced, in the order made.
  defp models_asked(asked \\ []) do
    receive do
      {:trace, _pid, :call, {Aqua.Models, :ask_models, [_ctx, ref]}} ->
        models_asked([ref | asked])
    after
      0 -> Enum.reverse(asked)
    end
  end

  # The id of each brain the setup lists, in its order.
  defp setup_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#aqua-setup-brains > li")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
  end

  defp soul_names_missing_catalyst!(ctx),
    do: soul_names_catalyst!(ctx, "catalyst:moonmoon69.claude")

  # The page talks to its sections with `send_update`; a test that is about
  # a section's own state says so the same way.
  defp send_update_agents(view, assigns) do
    :sys.replace_state(view.pid, & &1)

    Phoenix.LiveView.send_update(
      view.pid,
      PrismWeb.AquaLive.AgentsComponent,
      Keyword.put(Enum.to_list(assigns), :id, "aqua-agents")
    )

    render(view)
  end

  test "Aqua's setup offers an administrator this CYFR's setup next until Settings has " <>
         "opened it, and offers it to nobody else",
       %{conn: conn} do
    admin = test_user()
    {:ok, _} = Sanctum.TestContext.ensure_platform(admin.user_id)
    next = ~s([data-test="setup-admin-next"] a[href$="/settings?setup=1"])

    {view, _html} = mount_athanor(log_in_user(conn, admin), "/aqua?setup=1")
    assert has_element?(view, next, "Next: set up this CYFR for the people you let in")

    # Settings opens the administrator's setup and writes that it was seen.
    {settings, _html} = mount_athanor(log_in_user(build_conn(), admin), "/settings?setup=1")
    assert has_element?(settings, ~s([data-test="setup"]))

    {view, _html} = mount_athanor(log_in_user(build_conn(), admin), "/aqua?setup=1")
    refute has_element?(view, ~s([data-test="setup-admin-next"]))

    person = test_user()
    {view, _html} = mount_athanor(log_in_user(build_conn(), person), "/aqua?setup=1")
    refute has_element?(view, ~s([data-test="setup-admin-next"]))
    Cyfr.Test.Sandbox.end_views()
  end

  describe "the athanor's page" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
      {:ok, conn: conn, ctx: ctx, athanor: athanor}
    end

    test "a brain whose catalyst runs a program not installed offers its install on the card",
         %{conn: conn, ctx: ctx} do
      soul_runs_claude!(ctx)

      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(
               view,
               ~s(#aqua-card-aqua a[data-test="install-program"]),
               "install claude"
             )

      [href] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#aqua-card-aqua a[data-test="install-program"]))
        |> LazyHTML.attribute("href")

      assert %{"install" => "catalyst:local.harness", "need" => "claude", "from" => "aqua"} ==
               URI.decode_query(URI.parse(href).query)

      # Once the row is there, the card offers to set it up in its own
      # terminal instead.
      program_row!(ctx, "claude")
      {view, _html} = mount_athanor(conn, "/aqua")
      refute has_element?(view, ~s(#aqua-card-aqua a[data-test="install-program"]))
      assert has_element?(view, ~s(#aqua-card-aqua [data-test="set-up-program"]), "Set up claude")
    end

    # Set up is the person's press: it starts the program in its row's
    # folder, at a size the frame corrects when it attaches, and shows its
    # terminal with the way back here.
    test "Set up on the card starts the program and shows its terminal, which comes back here",
         %{conn: conn, ctx: ctx} do
      soul_runs_claude!(ctx)
      home = program_row!(ctx, "claude").id
      backends!()

      {view, _html} = mount_athanor(conn, "/aqua")
      refute_received {:session, "open", _message, _fields}

      view |> element(~s(#aqua-card-aqua [data-test="set-up-program"])) |> render_click()

      assert_receive {:session, "open",
                      %{"home_id" => ^home, "argv" => [], "rows" => 24, "cols" => 80}, _fields},
                     5_000

      {path, _flash} = assert_redirect(view, 5_000)
      assert URI.parse(path).path =~ ~r{/programs$}

      assert %{"terminal" => "trm_" <> _, "from" => "aqua"} =
               URI.decode_query(URI.parse(path).query)
    end

    test "a refused Set up says why on the card and stays there", %{conn: conn, ctx: ctx} do
      soul_runs_claude!(ctx)

      {:ok, _row} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          cap: 0,
          name: "claude",
          transport: "http",
          url: "https://tools.example.com/mcp",
          config_json: Jason.encode!(%{})
        })

      {view, _html} = mount_athanor(conn, "/aqua")
      view |> element(~s(#aqua-card-aqua [data-test="set-up-program"])) |> render_click()
      render_async(view, 5_000)

      assert has_element?(
               view,
               ~s(#aqua-card-aqua [data-test="set-up-refused"]),
               "'claude' is a tool server elsewhere; only a program opens here"
             )

      assert has_element?(view, ~s(#aqua-card-aqua [data-test="set-up-program"]), "Set up claude")
    end

    # A brain that runs a program on its own sign-in: with no row, its
    # program is to set up and grant; with its row set up and not bound,
    # its grant is all it needs, the brain's and then the member's own;
    # bound to the program row, it is connected, the program signed in
    # when it says so.
    test "a crew member whose brain runs a program reads its program to set up, then its " <>
           "grant, until the row is bound, then Model connected",
         %{conn: conn, ctx: ctx} do
      ctx = %{ctx | origin: :interactive}
      actor = Sanctum.Context.actor(ctx)
      ref = "catalyst:local.harness"

      unit =
        Arca.Test.UnitFixtures.tenant_component!(ctx, "catalyst", "local", "harness", "1.0.0",
          manifest: %{
            "name" => "harness",
            "type" => "catalyst",
            "version" => "1.0.0",
            "publisher" => "local",
            "needs" => %{
              "claude" => %{
                "type" => "login",
                "program" => "claude",
                "reason" => "to run Claude Code on your own plan",
                "required" => true
              }
            }
          },
          wasm: Cyfr.Test.Guests.wasm(:catalyst)
        )

      {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)

      # A soul with no tools, so the member's closure is its brain alone.
      :ok = Arca.put(actor, Compendium.AquaPath.soul_file(), "---\ntitle: Aqua\n---\n\nsoul\n")

      :ok =
        Arca.put(
          actor,
          Compendium.AquaPath.crew_file("harness"),
          "---\ncatalyst_ref: #{ref}\nmodel: harness-model\n---\n\nYou run the harness.\n"
        )

      {:ok, _} = Compendium.AgentIndex.sync(ctx)

      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-harness", "set up its program on the Programs page")
      refute has_element?(view, "#aqua-card-harness", "Model connected")

      row = program_row!(ctx, "claude")
      send_update_agents(view, load: true)
      card_needs_grant!(view, "harness")

      grant!(ctx, ref, %{bindings: [%{need: "claude", entry_id: row.id}]})
      send_update_agents(view, load: true)
      card_needs_grant!(view, "harness")

      grant!(ctx, Prima.AgentRef.ref("harness"), %{
        selections: [%{dep: ref, need: "claude", entry_id: row.id}]
      })

      send_update_agents(view, load: true)

      assert has_element?(view, "#aqua-card-harness", "Model connected")
      refute has_element?(view, "#aqua-card-harness", "set up its program")

      # Its binding is the one row named as its program: no key, and no
      # other binding, to change to.
      refute has_element?(view, "#aqua-card-harness button[phx-click=open_consent]")
    end

    # A crew member whose brain is a program names the row by its name.
    # While the athanor has no row of that name, its card offers to install
    # it, through the Programs page's form prefilled from the member's file;
    # once the row stands as a brain's, to set it up, where the person signs
    # it in. Either way it offers no other brain, and its models and
    # efforts are the ones its program lists, read from the row's driver;
    # before the row is there the member's own model stands alone.
    test "a crew member on a program brain offers its install, then its set up, " <>
           "with the models and efforts its program lists",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      install = "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323"

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "coder",
          "title" => "Coder",
          "program" => "claude",
          "install" => install,
          "model" => "opus",
          "content" => "# Coder"
        })

      card = "#aqua-card-coder"
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, card <> ~s( a[data-test="install-program"]), "install claude")
      assert has_element?(view, card, "Its brain runs a program you have not installed")

      [href] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(card <> ~s( a[data-test="install-program"]))
        |> LazyHTML.attribute("href")

      assert URI.parse(href).path == athanor_path("/programs")

      assert URI.decode_query(URI.parse(href).query) == %{
               "install_for" => "coder",
               "from" => "aqua"
             }

      refute has_element?(view, card <> ~s( [data-test="set-up-program"]))
      refute has_element?(view, card <> ~s( [data-test="connect"]))
      refute has_element?(view, card <> " button[phx-click=open_consent]")
      assert model_choices(view, "coder") == [{"", "The program's default"}, {"opus", "opus"}]
      refute has_element?(view, "#aqua-card-coder-options")
      refute_received {:session, "open", _open, _fields}

      row = program_row!(ctx, "claude", install)
      send_update_agents(view, load: true)
      refute has_element?(view, card <> ~s( a[data-test="install-program"]))
      assert has_element?(view, card <> ~s( [data-test="set-up-program"]), "Set up claude")
      refute has_element?(view, card <> " button[phx-click=open_consent]")

      # The row's driver lists its program's models, for the person here:
      # each listing the page asks for is answered, until the card shows it.
      listed = [
        {"", "The program's default"},
        {"default", "Default (recommended)"},
        {"opus", "Opus"},
        {"haiku", "Haiku"}
      ]

      lists!(fake, row, fn -> model_choices(view, "coder") == listed end)

      assert texts(view, "#aqua-card-coder-option-effort option") == [
               "default",
               "low",
               "high",
               "max"
             ]

      # A model it lists is the member's model, and only its model.
      view
      |> element("#aqua-card-coder-model")
      |> render_change(%{"name" => "coder", "brain" => "program", "value" => "haiku"})

      assert {:ok,
              %{
                "program" => "claude",
                "catalyst_ref" => nil,
                "model" => "haiku",
                "install" => ^install
              }} =
               Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => "coder"})
    end

    # A row of the member's program's name that stands but is no brain's,
    # disabled or not one a brain runs in (a bare harness among them), is
    # never read as not installed: no install is offered over it, and the
    # card says what to change on the Programs page.
    test "a program member whose row of that name stands disabled or unfit says so and offers no install",
         %{conn: conn, ctx: ctx} do
      {:ok, _idle} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          cap: 0,
          name: "idle-claude",
          transport: "program",
          mark: "driven",
          url: nil,
          home: "kept",
          enabled: false,
          config_json: Jason.encode!(%{"command" => "cyfr-claude-code claude", "env" => %{}})
        })

      _bare = program_row!(ctx, "bare-claude", "npx -y @anthropic-ai/claude-code")

      for {name, program} <- [{"idle", "idle-claude"}, {"bare", "bare-claude"}] do
        {:ok, _} =
          Cyfr.Test.AquaTool.call(ctx, %{
            "action" => "create",
            "name" => name,
            "program" => program,
            "install" => "cyfr-claude-code claude",
            "content" => "# #{name}"
          })
      end

      {view, _html} = mount_athanor(conn, "/aqua")

      for {name, program, state} <- [
            {"idle", "idle-claude", :program_disabled},
            {"bare", "bare-claude", :program_unfit}
          ] do
        card = "#aqua-card-" <> name
        assert has_element?(view, card, Prima.Refusal.message({:crew_unready, name, state}))
        refute has_element?(view, card <> ~s( a[data-test="install-program"]))
        refute has_element?(view, card <> ~s( [data-test="set-up-program"]))
        refute has_element?(view, card, "not installed")

        [href] =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(card <> ~s( a[data-test="open-program"]))
          |> LazyHTML.attribute("href")

        assert URI.decode_query(URI.parse(href).query) == %{"name" => program}
      end
    end

    test "the soul offers no Delete; a shipped crew member is disabled and enabled from its card",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")

      refute has_element?(view, "#aqua-card-aqua button[phx-click=editor_delete]")
      refute has_element?(view, "#aqua-card-aqua button[phx-click=editor_set_disabled]")

      # Shipped and unedited: no Delete, a Disable.
      assert has_element?(view, "#aqua-card-explorer", "shipped")
      refute has_element?(view, "#aqua-card-explorer button[phx-click=editor_delete]")

      view
      |> element("#aqua-card-explorer button[phx-click=editor_set_disabled]", "Disable")
      |> render_click()

      assert {:ok, %{"disabled" => true}} = get_agent(ctx, "explorer")

      # Still on the page — `list` drops it, the page does not — as
      # disabled, edited, and with the way back. The write answers before
      # the section re-reads, so the card is awaited.
      settled(
        fn -> has_element?(view, "#aqua-card-explorer", "disabled") end,
        "the disabled card"
      )

      assert has_element?(view, "#aqua-card-explorer", "disabled")
      assert has_element?(view, "#aqua-card-explorer", "edited")

      assert has_element?(
               view,
               "#aqua-card-explorer button[phx-click=editor_revert]",
               "Revert to shipped"
             )

      view
      |> element("#aqua-card-explorer button[phx-click=editor_set_disabled]", "Enable")
      |> render_click()

      assert {:ok, %{"disabled" => false}} = get_agent(ctx, "explorer")
    end

    test "restoring the shipped files reverts an edited soul and keeps what the athanor made",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"title" => shipped_title}} = get_agent(ctx, "aqua")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "title" => "Mine"})

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "scout",
          "content" => "# S"
        })

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "Restore shipped files"

      view |> element("#aqua-restore button[phx-click=restore_shipped]") |> render_click()

      assert {:ok, %{"title" => ^shipped_title}} = get_agent(ctx, "aqua")
      assert {:ok, %{"name" => "scout"}} = get_agent(ctx, "scout")

      html = render(view)
      assert html =~ "aqua/aqua.md"
      assert html =~ "aqua/crew/scout.md"
      assert has_element?(view, "#aqua-restore-result", "Kept (1)")
    end

    test "removing everything the athanor made deletes a crew member it made too",
         %{conn: conn, ctx: ctx} do
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "scout",
          "content" => "# S"
        })

      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-scout", "yours")

      view |> element("#aqua-restore button[phx-click=restore_all]") |> render_click()

      assert {:error, _} = get_agent(ctx, "scout")
      settled(fn -> not has_element?(view, "#aqua-card-scout") end, "the scout card to go")
      refute has_element?(view, "#aqua-card-scout")
      assert has_element?(view, "#aqua-restore-result", "aqua/crew/scout.md")
    end

    test "a new crew member is a name: it is offered the soul's tools and holds none of its own",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"tools" => soul_tools}} = get_agent(ctx, "aqua")
      assert soul_tools != []

      {view, _html} = mount_athanor(conn, "/aqua")

      html =
        view
        |> form("form[phx-submit=editor_create_member]", %{"name" => "scout"})
        |> render_submit()

      assert html =~ "Added &#39;scout&#39; to the crew"

      assert {:ok, %{"type" => "crew", "tools" => ^soul_tools, "mode" => "auto"}} =
               get_agent(ctx, "scout")

      assert {:ok, %{"tools" => ^soul_tools}} = get_agent(ctx, "aqua")

      {:ok, bytes} =
        Arca.get(Sanctum.Context.actor(ctx), Compendium.AquaPath.crew_file("scout"))

      refute bytes =~ "tools:"

      # Its card says what it is good at and what to avoid, and edits no
      # capabilities: those are the soul's.
      settled(fn -> has_element?(view, "#aqua-card-scout") end, "the scout card")
      assert has_element?(view, "#aqua-card-scout-description")
      assert has_element?(view, "#aqua-card-scout-avoid")

      assert has_element?(
               view,
               "#aqua-card-scout",
               "Offered the soul's tools; a hand-off may narrow them for one job."
             )

      refute has_element?(view, "#aqua-card-scout input[phx-click=editor_toggle_capability]")
      assert has_element?(view, "#aqua-card-aqua input[phx-click=editor_toggle_capability]")
    end

    test "the pinned page is written from the page and is what the soul reads",
         %{conn: conn, ctx: ctx} do
      # The athanor's one pinned page is `about-you`.
      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "About you"
      assert html =~ "Nothing pinned yet."

      view |> with_target("#aqua-notes-section") |> render_click("about_edit", %{})

      view
      |> form("#aqua-about form", %{"content" => "We ship on Fridays."})
      |> render_submit()

      assert render(view) =~ "We ship on Fridays."
      assert {:ok, %{name: "about-you", content: "We ship on Fridays."}} = Aqua.Notes.pinned(ctx)

      # The pinned page is not a note in the drawer.
      refute has_element?(view, "#aqua-notes button[phx-value-name=about-you]")
    end

    test "a page Aqua wrote says so; learned in a deleted thread it is marked with Remove, " <>
           "which removes it as read and no newer page",
         %{conn: conn, ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      {:ok, learned} = Arca.Test.Days.thread(actor)

      by_aqua = [kept_by: Prima.Author.agent(), thread: learned.id]

      {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Flies to Lisbon.", by_aqua)

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "Flies to Lisbon."
      assert has_element?(view, "#aqua-about-by", "Written by Aqua. Edit it to make it yours.")
      refute has_element?(view, "#aqua-about-deleted")

      {:ok, _} = Arca.ThreadStorage.delete(actor, learned.id)
      {view, html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-about-deleted", "a thread that has since been deleted")
      assert html =~ "Flies to Lisbon."

      # A page written after the section read it is not what Remove removes.
      {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Flies to Lisbon on the 3rd.", by_aqua)
      html = view |> with_target("#aqua-notes-section") |> render_click("about_remove", %{})
      assert html =~ "Could not remove it"
      assert {:ok, %{content: "Flies to Lisbon on the 3rd."}} = Aqua.Notes.pinned(ctx)

      # Read again, Remove removes it.
      assert has_element?(view, "#aqua-about-deleted")
      view |> with_target("#aqua-notes-section") |> render_click("about_remove", %{})
      assert :none = Aqua.Notes.pinned(ctx)
      assert render(view) =~ "Nothing pinned yet."
    end

    test "a save over a page Aqua wrote since the editor opened is refused and keeps Aqua's",
         %{conn: conn, ctx: ctx} do
      {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Prefers mornings.")
      {view, _html} = mount_athanor(conn, "/aqua")
      view |> with_target("#aqua-notes-section") |> render_click("about_edit", %{})

      {:ok, _} =
        Aqua.Notes.pin(ctx, "about-you", "Prefers mornings and tea.",
          kept_by: Prima.Author.agent()
        )

      html =
        view |> form("#aqua-about form", %{"content" => "Prefers evenings."}) |> render_submit()

      assert html =~ "Could not pin that"
      assert {:ok, %{content: "Prefers mornings and tea."}} = Aqua.Notes.pinned(ctx)
    end

    test "the pinned editor counts bytes, and the tool's refusal over the cap is the flash",
         %{conn: conn, ctx: ctx} do
      cap = Aqua.Notes.pin_max_bytes()
      # Two bytes a character: well under the cap in characters, over it in bytes.
      too_long = String.duplicate("é", div(cap, 2) + 10)
      assert String.length(too_long) < cap
      assert byte_size(too_long) > cap

      {view, _html} = mount_athanor(conn, "/aqua")
      view |> with_target("#aqua-notes-section") |> render_click("about_edit", %{})

      html =
        view
        |> with_target("#aqua-notes-section")
        |> render_click("about_change", %{"content" => too_long})

      assert html =~ "#{byte_size(too_long)} / #{cap} bytes"
      assert html =~ "text-red-400"

      html = view |> form("#aqua-about form", %{"content" => too_long}) |> render_submit()
      assert html =~ "Could not pin that"
      assert html =~ "at most #{cap} bytes"
      assert :none = Aqua.Notes.pinned(ctx)
    end

    test "the notes drawer lists what was kept here, opens one, and forgets on request",
         %{conn: conn, ctx: ctx} do
      {:ok, _} = Aqua.Notes.keep(ctx, "plan", "Ship Friday.\nThen rest.")

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "plan"
      refute html =~ "Ship Friday."

      assert view
             |> with_target("#aqua-notes-section")
             |> render_click("note_open", %{"name" => "plan"}) =~
               "Ship Friday."

      view
      |> with_target("#aqua-notes-section")
      |> render_click("note_forget", %{"name" => "plan"})

      refute render(view) =~ "Ship Friday."
      assert {:ok, %{notes: notes}} = Aqua.Notes.list(ctx)
      refute Enum.any?(notes, &(&1.name == "plan"))
    end

    test "a note write refreshes the drawer", %{conn: conn, ctx: ctx} do
      {:ok, _} = Aqua.Notes.keep(ctx, "plan", "Ship Friday.")

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "plan"

      # Kept out of band after the page loaded: the drawer is stale until
      # a write from the page refreshes it.
      {:ok, _} = Aqua.Notes.keep(ctx, "retro", "Rest Monday.")
      refute render(view) =~ "retro"

      # The write answers, then the drawer reloads on its own message.
      assert view
             |> with_target("#aqua-notes-section")
             |> render_click("note_forget", %{"name" => "plan"}) =~
               "Forgot the note: plan"

      assert has_element?(view, "#aqua-notes button[phx-value-name=retro]")
      refute has_element?(view, "#aqua-notes button[phx-value-name=plan]")
    end

    test "the scrolls disclosure opens when a scroll exists, and one is written, edited and deleted here",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"skills" => [shipped | _]}} =
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "skill_list"})

      # The server ships a scroll, so the disclosure is open from the start.
      {view, html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-scrolls[open]")
      assert html =~ shipped["name"]

      # A shipped, unedited scroll offers no removal verb; edited, it
      # offers the way back — and takes it.
      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_open", %{
        "name" => shipped["name"]
      })

      assert has_element?(view, "#aqua-scroll-open", "shipped")
      refute has_element?(view, "#aqua-scroll-open button[phx-click=skill_delete]")
      refute has_element?(view, "#aqua-scroll-open button[phx-click=skill_revert]")

      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_edit", %{
        "name" => shipped["name"]
      })

      view
      |> form("#aqua-scroll-editor", %{"description" => "Edited here", "content" => "# Mine"})
      |> render_submit()

      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_open", %{
        "name" => shipped["name"]
      })

      assert has_element?(view, "#aqua-scroll-open", "edited")

      assert has_element?(
               view,
               "#aqua-scroll-open button[phx-click=skill_revert]",
               "Revert to shipped"
             )

      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_revert", %{
        "name" => shipped["name"]
      })

      shipped_description = shipped["description"]

      assert {:ok, %{"description" => ^shipped_description}} =
               Cyfr.Test.AquaTool.call(ctx, %{"action" => "skill_get", "name" => shipped["name"]})

      view |> with_target("#aqua-scrolls-section") |> render_click("skill_new", %{})

      view
      |> form("#aqua-scroll-editor", %{
        "name" => "pdf-forms",
        "description" => "Fill PDF forms",
        "content" => "# PDF forms\nUse pdftk."
      })
      |> render_submit()

      assert has_element?(view, "#aqua-scrolls[open]")
      html = render(view)
      assert html =~ "pdf-forms"
      assert html =~ "Fill PDF forms"
      refute html =~ "Use pdftk."

      assert {:ok, %{"content" => "# PDF forms\nUse pdftk."}} =
               Cyfr.Test.AquaTool.call(ctx, %{"action" => "skill_get", "name" => "pdf-forms"})

      # Open it, edit it: the open scroll shows the new body.
      assert view
             |> with_target("#aqua-scrolls-section")
             |> render_click("skill_open", %{
               "name" => "pdf-forms"
             }) =~ "Use pdftk."

      assert has_element?(view, "#aqua-scroll-open", "yours")

      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_edit", %{"name" => "pdf-forms"})

      view
      |> form("#aqua-scroll-editor", %{
        "description" => "Fill PDF forms",
        "content" => "# PDF forms\nUse qpdf."
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Use qpdf."
      refute html =~ "Use pdftk."

      assert {:ok, %{"content" => "# PDF forms\nUse qpdf."}} =
               Cyfr.Test.AquaTool.call(ctx, %{"action" => "skill_get", "name" => "pdf-forms"})

      # The athanor's own scroll is deleted, with the verb spelled as such.
      assert has_element?(view, "#aqua-scroll-open button[phx-click=skill_delete]", "Delete")

      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_delete", %{"name" => "pdf-forms"})

      assert {:error, _} =
               Cyfr.Test.AquaTool.call(ctx, %{"action" => "skill_get", "name" => "pdf-forms"})

      refute has_element?(view, "#aqua-scroll-open")
      refute has_element?(view, "#aqua-scrolls button[phx-value-name=pdf-forms]")
    end

    test "the first paint is the frame and its spinner — no empty state the load has not earned",
         %{conn: conn} do
      html = conn |> get(athanor_path("/aqua")) |> html_response(200)
      assert html =~ "Loading Aqua…"

      for line <- [
            "No soul here",
            "Nothing pinned yet.",
            "Nothing kept yet.",
            "No scrolls here.",
            "Shipped files",
            "+ New crew member"
          ] do
        refute html =~ line, "the dead render says #{inspect(line)}"
      end

      # Loaded, the sections are there, and the form with them.
      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "Shipped files"
      assert has_element?(view, "#aqua-about")
      assert has_element?(view, "#aqua-notes")
      assert has_element?(view, "#aqua-scrolls")
      assert has_element?(view, "form[phx-submit=editor_create_member]")
    end

    # A store that cannot give the agents: the page says so in place of the
    # cards, the new-member form and the missing soul's note, and offers no
    # model to install or connect. One that answers with no agents is an
    # athanor with no soul, as before.
    @tag :capture_log
    test "an agents list that cannot be read says so, and offers nothing to create or connect",
         %{conn: conn} do
      storage!(PrismWeb.AquaLiveTest.UnreadableCrew)
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(
               view,
               ~s([data-test="agents-unavailable"]),
               "Aqua and its crew members cannot be read right now — try again."
             )

      refute render(view) =~ "No soul here"
      refute has_element?(view, "form[phx-submit=editor_create_member]")
      refute has_element?(view, "button[phx-click=install_catalyst]")
      refute has_element?(view, "button[phx-click=open_consent]")
    end

    test "a store that answers with no agents still says no soul is here", %{
      conn: conn,
      ctx: ctx
    } do
      # Every agent the fill shipped goes, unit by unit, as a reset of the
      # whole root would take them.
      assert :ok =
               Arca.Overlay.with_internal_writes(fn ->
                 Arca.delete_tree(Sanctum.Context.actor(ctx), ["aqua"])
               end)

      {view, _html} = mount_athanor(conn, "/aqua")

      assert render(view) =~ "No soul here"
      refute has_element?(view, ~s([data-test="agents-unavailable"]))
    end

    test "a catalyst the athanor does not hold is offered an Install, which refuses while the registry cannot be reached",
         %{conn: conn, ctx: ctx} do
      # The soul names a model catalyst nothing here holds: the page says so
      # and offers to fetch it, rather than leaving a dead end.
      :ok = soul_names_missing_catalyst!(ctx)

      # The soul's card: a crew member whose brain is not here says so on
      # its own card.
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-aqua", "not installed here yet")
      assert has_element?(view, "#aqua-card-aqua button[phx-click=install_catalyst]")

      before = Task.Supervisor.children(Prism.TaskSupervisor)

      view
      |> element("#aqua-card-aqua button[phx-click=install_catalyst]")
      |> render_click()

      fetch = page_tasks(view, before)

      # The click only starts the fetch; its refusal reaches the page when
      # the task answers. The page tells the section which install ended
      # while it serves that answer, so a render asked for once the refusal
      # shows is served after the section has heard.
      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "Could not install" end,
        5_000,
        "the install's refusal"
      )

      html = render(view)
      assert html =~ "Could not install"

      # The button comes back: a refused fetch must not leave the page
      # showing "Installing…" with nothing to click.
      refute html =~ "Installing…"

      assert has_element?(
               view,
               "#aqua-card-aqua button[phx-click=install_catalyst]:not([disabled])"
             )

      # The fetch has answered; it is gone before the sandbox it queried is
      # released.
      Prima.Test.Wait.wait_until(
        fn -> not Enum.any?(Task.Supervisor.children(Prism.TaskSupervisor), &(&1 in fetch)) end,
        5_000,
        "the install's fetch to end"
      )
    end

    test "an install that lands leaves the model asking for a key, not asking to be installed",
         %{conn: conn, ctx: ctx} do
      ref = "catalyst:local.newmodel"
      :ok = soul_names_catalyst!(ctx, ref)

      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-aqua", "not installed here yet")

      # What a pull that succeeds leaves behind: the row, with a required
      # need and no consent bound to it yet.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "newmodel",
          version: "0.1.0",
          type: "catalyst",
          description: "A model catalyst",
          manifest:
            Jason.encode!(%{
              "contracts" => [Prima.Model.chat_contract()],
              "needs" => %{
                "api_key" => %{
                  "type" => "api_key:newmodel.test",
                  "reason" => "to call the model with your key",
                  "fields" => ["NEWMODEL_API_KEY"],
                  "required" => true,
                  "hosts" => ["api.newmodel.example"]
                }
              },
              "caps" => %{"egress" => %{"domains" => ["api.newmodel.example"]}}
            })
        })

      # The install task answers under the focus it started with.
      tag = CyfrWeb.ContextGuard.capture(:sys.get_state(view.pid).socket)
      send(view.pid, {:catalyst_installed, tag, ref, {:ok, %{}}})

      html = settled_render(view)
      assert html =~ "Installed #{ref}."
      refute has_element?(view, "#aqua-card-aqua", "not installed here yet")
      assert has_element?(view, "#aqua-card-aqua", "the model has no key yet")
      refute has_element?(view, "#aqua-card-aqua button[phx-click=install_catalyst]")

      # And the way on is live: Connect leads to Aqua's setup, which lists
      # the release that landed, and its step opens the grant in the page's
      # system layer and nowhere on the page.
      view |> element(~s(#aqua-card-aqua a[data-test="connect"])) |> render_click()
      assert has_element?(view, "#aqua-setup[open]")
      view |> element("#aqua-setup-brain-newmodel input") |> render_click()
      view |> element("#aqua-setup-step-newmodel button", "Enter the key") |> render_click()

      html = render(view)
      assert html =~ ref
      assert html =~ "to call the model with your key"
      assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-needs"]))
    end

    # The model's consent exists but is damaged, or the store cannot answer
    # it: connecting a key cannot repair it, so none is offered, and the
    # page says which.
    @tag :capture_log
    test "a model whose consent is damaged or unreadable says so, and offers no Connect",
         %{conn: conn, ctx: ctx} do
      ref = "catalyst:local.brokenmodel"
      profile = "prof_brokenmodel"
      :ok = soul_names_catalyst!(ctx, ref)

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "brokenmodel",
          version: "0.1.0",
          type: "catalyst",
          description: "A model catalyst",
          manifest:
            Jason.encode!(%{
              "needs" => %{
                "api_key" => %{
                  "type" => "api_key:brokenmodel.test",
                  "reason" => "to call the model with your key",
                  "fields" => ["BROKENMODEL_API_KEY"],
                  "required" => true,
                  "hosts" => ["api.brokenmodel.example"]
                }
              },
              "caps" => %{"egress" => %{"domains" => ["api.brokenmodel.example"]}}
            })
        })

      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          ctx,
          %{id: profile, source_ref: ref, kind: :owner, label: "default", status: :active},
          %{
            id: "cons_brokenmodel",
            revision: 1,
            scope: :versionless,
            shape_digest: "sha256:shape",
            commit_digest: "sha256:commit",
            resolved_policy: "{}",
            activation: %{ref => "sha256:act"},
            vault_refs: []
          }
        )

      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile, scope: "sideways")

      {view, _html} = mount_athanor(conn, "/aqua")
      settled_render(view)

      assert has_element?(
               view,
               "span",
               "A consent this model runs under is damaged and cannot be used — " <>
                 "revoke the damaged profile and grant it again."
             )

      refute render(view) =~ "the model has no key yet"
      refute has_element?(view, ~s(#aqua-card-aqua a[data-test="connect"]))
      refute has_element?(view, "#aqua-card-aqua button[phx-click=open_consent]")

      # The store stops answering: the panel reads the model again.
      :ok = Sanctum.Test.ConsentFixtures.hand_edit_head!(ctx, profile, scope: "versionless")
      Arca.Repo.query!("ALTER TABLE consents RENAME TO consents_unavailable")

      Phoenix.LiveView.send_update(view.pid, PrismWeb.AquaLive.AgentsComponent,
        id: "aqua-agents",
        load: true
      )

      assert has_element?(
               view,
               "span",
               "A consent this model runs under cannot be read right now — try again."
             )

      refute has_element?(view, ~s(#aqua-card-aqua a[data-test="connect"]))
      refute has_element?(view, "#aqua-card-aqua button[phx-click=open_consent]")

      Cyfr.Test.Sandbox.end_views()
    end

    test "connecting a brain in the setup binds the key in the system layer, shows what the " <>
           "provider answered, and a refused key takes that brain's models off the picker",
         %{conn: conn, ctx: ctx} do
      ref = "catalyst:local.keyed"
      :ok = soul_names_catalyst!(ctx, ref)

      # The picker as the catalogue left it: models the brain answered
      # under its previous key, beside another brain's.
      picker = %{"keyed" => ["keyed-old-1"], "other" => ["other-1"]}
      refs = %{"keyed" => ref, "other" => "catalyst:local.other"}
      remember_catalogue!(picker, refs)

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "keyed",
          version: "0.1.0",
          type: "catalyst",
          description: "A model catalyst",
          manifest:
            Jason.encode!(%{
              "contracts" => [Prima.Model.chat_contract()],
              "needs" => %{
                "api_key" => %{
                  "type" => "api_key:keyed.test",
                  "reason" => "to call the model with your key",
                  "fields" => ["KEYED_API_KEY"],
                  "required" => true,
                  "hosts" => ["api.keyed.example"]
                }
              },
              "caps" => %{"egress" => %{"domains" => ["api.keyed.example"]}}
            })
        })

      # The provider the need names; the model reads its key itself, so
      # the entry is disclosed.
      params = %{
        name: "keyed key",
        kind: "api_key",
        provider_hint: "keyed.test",
        fields: %{"KEYED_API_KEY" => "sk-keyed"},
        destination: %{"hosts" => ["api.keyed.example"]},
        disclose: true
      }

      entering =
        Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
          operation: "vault.create",
          arguments: params,
          resource: params.name
        })

      {:ok, entry} = Sanctum.Vault.create(entering, params)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      view |> element("#aqua-setup-brain-keyed input") |> render_click()
      view |> element("#aqua-setup-step-keyed button", "Enter the key") |> render_click()

      # No sheet on the page itself: the grant is the layer's.
      refute has_element?(view, "#consent-sheet-dialog")
      assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))

      view
      |> element(
        ~s(#system-layer-dialog [data-test="grant-pick"][phx-value-entry_id="#{entry.id}"])
      )
      |> render_click()

      render(view)

      # Every `models` call the page makes from here on, counted where each
      # one is made (`Aqua.Models`), for whichever path asks.
      :erlang.trace(:all, true, [:call, {:tracer, self()}])
      :erlang.trace_pattern({Aqua.Models, :ask_models, 2}, true, [:local])

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      # The layer asks its sheet for the walk, then commits; the page then
      # asks the brain for its models once and shows what it answered.
      Prima.Test.Wait.wait_until(
        fn ->
          has_element?(view, ~s(#aqua-setup-brain-keyed [data-test="setup-answer"]), "answered")
        end,
        5_000,
        "the brain's answer"
      )

      refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

      # What the brain answered its one `models` call, in its words: the
      # test catalyst answers every input `{"ran":true}`, no model list.
      assert view
             |> element(~s(#aqua-setup-brain-keyed [data-test="setup-answer"]))
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() ==
               ~s(keyed answered: the catalyst answered something that is not the envelope: %{"ran" => true})

      # Connecting asked the brain once, and nothing asked it again: the
      # page's mailbox is served before the count is read.
      _ = :sys.get_state(view.pid)
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Aqua.Models, :ask_models, 2}, false, [:local])
      assert models_asked() == [ref]

      # The refused key offers none of the old models; nothing else moved.
      assert picker(view) == {%{"other" => ["other-1"]}, refs}

      {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(ctx, ref)
      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
      assert Enum.any?(head.vault_refs, &(&1.vault_entry_id == entry.id))

      # The brain's models call runs beside the page; it ends before the test does.
      Cyfr.Test.Sandbox.end_views()
    end

    test "reconnecting a third-party brain by its versioned reference fills its own picker " <>
           "entry, never a local brain's of the same name",
         %{conn: conn, ctx: ctx} do
      # acme's brain, as a pull installs it, answers its models with the
      # chat fixture's one model.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, File.read!(Cyfr.Test.ChatFixture.wasm_path()), %{
          name: "brain",
          version: "1.0.0",
          type: "catalyst",
          publisher: "acme",
          description: "acme's model catalyst",
          manifest: Jason.encode!(%{"contracts" => [Prima.Model.chat_contract()]})
        })

      publish_brain!(ctx, "brain", %{})

      refs = %{"acme.brain" => "catalyst:acme.brain", "brain" => "catalyst:local.brain"}
      remember_catalogue!(%{"acme.brain" => ["old-model"], "brain" => ["local-model"]}, refs)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      # A ready card's "Change the key" names the resolved, versioned
      # release.
      render_click(view, "open_consent", %{"ref" => "catalyst:acme.brain:1.0.0"})
      assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

      :erlang.trace(:all, true, [:call, {:tracer, self()}])
      :erlang.trace_pattern({Aqua.Models, :ask_models, 2}, true, [:local])
      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      Prima.Test.Wait.wait_until(
        fn -> render(view) =~ "brain answered with one model." end,
        10_000,
        "acme's brain's answer"
      )

      _ = :sys.get_state(view.pid)
      :erlang.trace(:all, false, [:call])
      :erlang.trace_pattern({Aqua.Models, :ask_models, 2}, false, [:local])
      assert models_asked() == ["catalyst:acme.brain:1.0.0"]

      # acme's entry is replaced whole; the local brain's is untouched.
      assert picker(view) ==
               {%{"acme.brain" => ["chat-fixture"], "brain" => ["local-model"]}, refs}

      # The brain's models call runs beside the page; it ends before the test does.
      Cyfr.Test.Sandbox.end_views()
    end

    test "Aqua's setup lists every installed brain with what it needs, offers one step per " <>
           "brain ticked, and a brain installed later joins it",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "keyed", %{
        "api_key" => %{
          "type" => "api_key:keyed.test",
          "reason" => "to call Keyed with your key (keyed.test/keys)",
          "fields" => ["KEYED_API_KEY"],
          "required" => true,
          "hosts" => ["api.keyed.example"]
        }
      })

      publish_brain!(ctx, "planned", %{
        "plan" => %{
          "type" => "login",
          "program" => "planner",
          "reason" => "to run Planner on your own plan"
        }
      })

      :ok = soul_names_catalyst!(ctx, "catalyst:local.keyed")

      # The soul's brain is not connected, so the setup is the page's
      # first step, open without being asked for.
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-setup[open]")

      assert setup_rows(view) == ["aqua-setup-brain-keyed", "aqua-setup-brain-planned"]

      assert has_element?(
               view,
               "#aqua-setup-brain-keyed label",
               "a key: to call Keyed with your key (keyed.test/keys)"
             )

      assert has_element?(
               view,
               "#aqua-setup-brain-planned label",
               "a plan: to run Planner on your own plan"
             )

      # With nothing ticked, the setup says what Aqua needs.
      assert has_element?(
               view,
               ~s([data-test="setup-needs"]),
               "Aqua needs a key or a plan to answer: tick one you have."
             )

      refute has_element?(view, "#aqua-setup-steps")

      view |> element("#aqua-setup-brain-keyed input") |> render_click()
      view |> element("#aqua-setup-brain-planned input") |> render_click()
      refute has_element?(view, ~s([data-test="setup-needs"]))

      assert has_element?(
               view,
               "#aqua-setup-step-keyed button[phx-click=open_consent]",
               "Enter the key"
             )

      [href] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#aqua-setup-step-planned a")
        |> LazyHTML.attribute("href")

      assert URI.parse(href).path == athanor_path("/programs")

      assert URI.decode_query(URI.parse(href).query) ==
               %{"install" => "catalyst:local.planned", "need" => "plan"}

      # A brain installed afterwards is offered with no change to the setup.
      publish_brain!(ctx, "later", %{
        "api_key" => %{
          "type" => "api_key:later.test",
          "reason" => "to call Later with your key",
          "fields" => ["LATER_API_KEY"],
          "required" => true,
          "hosts" => ["api.later.example"]
        }
      })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      assert setup_rows(view) == [
               "aqua-setup-brain-keyed",
               "aqua-setup-brain-later",
               "aqua-setup-brain-planned"
             ]
    end

    # Its program installed (the Programs page's one confirmation), a brain
    # that runs it asks only for its grant, which binds the program row.
    test "a brain whose program is set up asks only for the grant, which binds the program's row",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "planned", %{
        "plan" => %{
          "type" => "login",
          "program" => "planner",
          "reason" => "to run Planner on your own plan"
        }
      })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, ~s(#aqua-setup-brain-planned[data-state="needs_program"]))
      view |> element("#aqua-setup-brain-planned input") |> render_click()

      assert has_element?(
               view,
               "#aqua-setup-step-planned",
               "planned: set up planner on the Programs page, then grant it here."
             )

      row = program_row!(ctx, "planner")
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, ~s(#aqua-setup-brain-planned[data-state="needs_grant"]))
      assert has_element?(view, "#aqua-setup-brain-planned label", "needs only your grant")

      view |> element("#aqua-setup-brain-planned input") |> render_click()

      view
      |> element("#aqua-setup-step-planned button[phx-click=open_consent]", "Grant")
      |> render_click()

      settled(
        fn -> has_element?(view, ~s(#system-layer-dialog [data-kind="grant"])) end,
        "the grant asked"
      )

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      Prima.Test.Wait.wait_until(
        fn -> has_element?(view, ~s(#aqua-setup-brain-planned[data-state="ready"])) end,
        5_000,
        "the brain connected"
      )

      {:ok, [%{id: profile_id}]} = Sanctum.Consent.profiles(ctx, "catalyst:local.planned")
      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
      assert [%{mcp_server_id: bound}] = head.vault_refs
      assert bound == row.id
    end

    # The step follows the brain's state: one that needs a key beside its
    # program's sign-in reads as needing a key, whatever need comes first.
    test "a brain that needs a key beside its program's sign-in steps to its key",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "mixed", %{
        "a_plan" => %{
          "type" => "login",
          "program" => "mixer",
          "reason" => "to run Mixer on your own plan",
          "required" => true
        },
        "b_key" => %{
          "type" => "api_key:mixed.test",
          "reason" => "to call Mixed with your key",
          "fields" => ["MIXED_API_KEY"],
          "required" => true,
          "hosts" => ["api.mixed.example"]
        }
      })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, ~s(#aqua-setup-brain-mixed[data-state="needs_key"]))
      view |> element("#aqua-setup-brain-mixed input") |> render_click()

      assert has_element?(
               view,
               "#aqua-setup-step-mixed button[phx-click=open_consent]",
               "Enter the key"
             )

      refute has_element?(view, "#aqua-setup-step-mixed", "Programs page")
    end

    test "a new crew member's card offers Connect, which opens the setup for that member",
         %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/aqua")

      view
      |> form("form[phx-submit=editor_create_member]", %{"name" => "proofreader"})
      |> render_submit()

      settled(fn -> has_element?(view, "#aqua-card-proofreader") end, "the new card")
      assert has_element?(view, "#aqua-card-proofreader", "No brain yet")

      view |> element(~s(#aqua-card-proofreader a[data-test="connect"])) |> render_click()

      assert_patch(view, athanor_path("/aqua?agent=proofreader&setup=1"))
      assert has_element?(view, "#aqua-setup[open]")
      assert has_element?(view, ~s([data-test="setup-unconnected"]), "proofreader")
    end

    test "Enter in a crew member's Good at saves it, as leaving the field does",
         %{conn: conn, ctx: ctx} do
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "tidy",
          "title" => "Tidy",
          "content" => "# Tidy"
        })

      {view, _html} = mount_athanor(conn, "/aqua")

      view
      |> form("#aqua-card-tidy-description", %{"value" => "proofreading"})
      |> render_submit()

      assert {:ok, %{"description" => "proofreading"}} = get_agent(ctx, "tidy")
    end

    test "a brain that needs nothing asks only for the grant, and is connected once granted",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "open", %{})
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      assert has_element?(view, ~s(#aqua-setup-brain-open[data-state="needs_grant"]))
      assert has_element?(view, "#aqua-setup-brain-open label", "needs only your grant")
      refute has_element?(view, "#aqua-setup-brain-open", "connected")

      assert has_element?(
               view,
               ~s([data-test="setup-needs"]),
               "Aqua needs a key or a plan to answer: tick one you have."
             )

      view |> element("#aqua-setup-brain-open input") |> render_click()
      assert has_element?(view, "#aqua-setup-step-open", "open: grant it to connect.")
      refute has_element?(view, "#aqua-setup-step-open", "key")

      view
      |> element("#aqua-setup-step-open button[phx-click=open_consent]", "Grant")
      |> render_click()

      assert has_element?(
               view,
               ~s(#system-layer-dialog [data-kind="grant"]),
               "This app asks for no credentials."
             )

      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      Prima.Test.Wait.wait_until(
        fn -> has_element?(view, ~s(#aqua-setup-brain-open[data-state="ready"]), "connected") end,
        5_000,
        "the brain connected"
      )

      assert has_element?(view, "#aqua-setup-pick", "Which connected brain is Aqua's own?")

      # The brain's models call runs beside the page; it ends before the test does.
      Cyfr.Test.Sandbox.end_views()
    end

    test "picking a connected brain for Aqua asks for its consent again at once",
         %{conn: conn, ctx: ctx} do
      athanor = seated_athanor()
      publish_brain!(ctx, "open", %{})
      grant!(ctx, "catalyst:local.open", %{bindings: []})

      :ok =
        PrismWeb.ModelCatalog.remember(athanor.id, %{
          "models" => %{"open" => ["open-1"]},
          "refs" => %{"open" => "catalyst:local.open:0.1.0"}
        })

      on_exit(fn -> PrismWeb.ModelCatalog.forget(athanor.id) end)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, ~s(#aqua-setup-brain-open[data-state="ready"]))
      assert has_element?(view, "#aqua-setup-pick", "Which connected brain is Aqua's own?")

      view |> form("#aqua-setup-pick", %{"value" => "open::open-1"}) |> render_change()

      assert {:ok, %{"catalyst_ref" => "catalyst:local.open", "model" => "open-1"}} =
               get_agent(ctx, "aqua")

      settled(
        fn ->
          has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]), "agent:local.aqua")
        end,
        "the soul's consent asked again"
      )

      Cyfr.Test.Sandbox.end_views()
    end

    test "an unrelated reload does not re-enable Install while its fetch is running",
         %{conn: conn, ctx: ctx} do
      :ok = soul_names_missing_catalyst!(ctx)

      {view, _html} = mount_athanor(conn, "/aqua")

      # The section is told an install started, then reloaded for an
      # unrelated reason. A button re-enabled here invites a second
      # download of the same component.
      send_update_agents(view, installing: "catalyst:moonmoon69.claude")
      send_update_agents(view, load: true)

      assert has_element?(view, "button[phx-click=install_catalyst][disabled]")

      # The install that ends is the one named, and only then.
      send_update_agents(view, installed: "catalyst:someone.else")
      assert has_element?(view, "button[phx-click=install_catalyst][disabled]")

      send_update_agents(view, installed: "catalyst:moonmoon69.claude")
      assert has_element?(view, "button[phx-click=install_catalyst]:not([disabled])")
    end

    test "a key bound from the page drops the kept catalogue, so the picker is read again",
         %{conn: conn, ctx: ctx} do
      athanor = seated_athanor()

      :ok =
        PrismWeb.ModelCatalog.remember(athanor.id, %{"models" => %{"kept" => ["kept-model-1"]}})

      on_exit(fn -> PrismWeb.ModelCatalog.forget(athanor.id) end)

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "kept-model-1"

      # The grant is asked in the page's system layer; confirmed there, the
      # page hears it.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "kept-key",
          version: "0.1.0",
          type: "catalyst",
          description: "A model catalyst",
          manifest: Jason.encode!(%{})
        })

      render_click(view, "open_consent", %{"ref" => "catalyst:local.kept-key:0.1.0"})
      assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
      Prima.Test.Wait.wait_until(fn -> render(view) =~ "Asking kept-key" end, 5_000, "the grant")

      # The kept entry is gone: a load from here finds no hit to hand back,
      # whatever a fresh run answers.
      PrismWeb.ModelCatalog.load(ctx)
      refute_received {:list_models_result, _tag, {:ok, %{"models" => %{"kept" => _}}}}

      # The page's models call and this load's run both run beside the test;
      # each ends before it does.
      Cyfr.Test.Sandbox.end_views()
    end

    test "the prompt editor is a dialog with a sibling backdrop and an Escape of its own",
         %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/aqua")
      refute has_element?(view, "#prompt-editor")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_edit_prompt", %{"name" => "aqua"})

      assert has_element?(view, "#prompt-editor textarea[name=content]")

      # A click into the textarea must not cancel: no cancel binding sits on
      # an ancestor of the content — the backdrop is a sibling, and Escape
      # is bound to the dialog's own root.
      refute has_element?(view, "#prompt-editor[phx-click]")
      refute has_element?(view, "#prompt-editor [phx-click-away]")
      assert has_element?(view, ~s(#prompt-editor[phx-keydown][phx-key="Escape"]))

      view |> element("#prompt-editor") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#prompt-editor")
    end

    test "the prompt editor saves the prompt it opened, and refuses to save over another " <>
           "member's edit made since",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")
      agents = with_target(view, "#aqua-agents")

      render_click(agents, "editor_edit_prompt", %{"name" => "explorer"})
      html = view |> form("#prompt-editor form", %{"content" => "# Mine"}) |> render_submit()

      refute html =~ "Save failed"
      assert {:ok, %{"content" => "# Mine"}} = get_agent(ctx, "explorer")
      refute has_element?(view, "#prompt-editor")

      render_click(agents, "editor_edit_prompt", %{"name" => "explorer"})
      assert has_element?(view, "#prompt-editor textarea[name=content]", "# Mine")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "explorer",
          "content" => "# Theirs"
        })

      html = view |> form("#prompt-editor form", %{"content" => "# Again"}) |> render_submit()

      assert html =~ "The prompt changed since you opened it"
      assert {:ok, %{"content" => "# Theirs"}} = get_agent(ctx, "explorer")
      assert has_element?(view, "#prompt-editor textarea[name=content]")
    end

    # A box ticked offers the soul the tool, and every crew member with
    # it; cleared, it takes it off. The provider's own search is a box of
    # its own on the same list.
    test "a checkbox offers the soul a tool and takes it off again; a crew member holds none",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")
      {:ok, before} = get_agent(ctx, "aqua")
      refute "storage.write" in before["tools"]
      assert "native_search" in before["tools"]

      for {key, during} <- [
            {"storage.write", Enum.sort(["storage.write" | before["tools"]])},
            {"native_search", before["tools"] -- ["native_search"]}
          ] do
        box =
          ~s(#aqua-card-aqua input[phx-click=editor_toggle_capability][phx-value-key="#{key}"])

        ticked? = key in before["tools"]
        assert has_element?(view, box <> "[checked]") == ticked?

        view |> element(box) |> render_click()
        assert {:ok, %{before | "tools" => during}} == get_agent(ctx, "aqua")
        assert {:ok, %{"tools" => ^during}} = get_agent(ctx, "explorer")

        settled(
          fn -> has_element?(view, box <> "[checked]") == not ticked? end,
          "#{key}'s box after the first click"
        )

        view |> element(box) |> render_click()
        assert {:ok, before} == get_agent(ctx, "aqua")

        settled(
          fn -> has_element?(view, box <> "[checked]") == ticked? end,
          "#{key}'s box after the second click"
        )
      end

      # A crew member's own write is refused.
      html =
        view
        |> with_target("#aqua-agents")
        |> render_click("editor_toggle_capability", %{
          "name" => "explorer",
          "key" => "storage.list"
        })

      assert html =~ "A crew member is offered the soul&#39;s tools and has none of its own"
      assert {:ok, before} == get_agent(ctx, "aqua")
    end

    # Each member's mode is its own, the soul's and a crew member's alike:
    # its switch shows it, and a choice writes it into the member's file.
    test "each member's switch shows its mode, and a choice writes it to the member's file",
         %{conn: conn, ctx: ctx} do
      actor = Sanctum.Context.actor(ctx)
      {view, _html} = mount_athanor(conn, "/aqua")

      for name <- ["aqua", "explorer"] do
        assert mode_shown(view, name) == ["auto"]

        assert has_element?(
                 view,
                 mode_choice(name, "read-only"),
                 "Read-only: runs only reads, then answers; every other call is refused"
               )

        assert has_element?(
                 view,
                 mode_choice(name, "auto"),
                 "Auto: runs every tool it is offered, deleting included"
               )

        refute has_element?(view, mode_choice(name, "read-only") <> "[disabled]")
        refute has_element?(view, "#aqua-card-#{name} [data-test=read-only-unheld]")
      end

      for name <- ["explorer", "aqua"] do
        {:ok, before} = get_agent(ctx, name)
        assert before["mode"] == "auto"

        view |> element(mode_choice(name, "read-only")) |> render_click()
        assert {:ok, %{before | "mode" => "read-only"}} == get_agent(ctx, name)
        {:ok, bytes} = Arca.get(actor, Compendium.AquaPath.agent_file(name))
        assert bytes =~ "\nmode: read-only\n"

        settled(
          fn -> mode_shown(view, name) == ["read-only"] end,
          "#{name}'s switch on read-only"
        )

        view |> element(mode_choice(name, "auto")) |> render_click()
        assert {:ok, before} == get_agent(ctx, name)
        settled(fn -> mode_shown(view, name) == ["auto"] end, "#{name}'s switch back on auto")
      end

      # Only the two modes are written.
      {:ok, before} = get_agent(ctx, "explorer")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_set_mode", %{"name" => "explorer", "mode" => "ask"})

      assert {:ok, before} == get_agent(ctx, "explorer")
    end

    # A brain CYFR cannot keep read-only closes the read-only choice and
    # says why beneath it: a catalyst whose manifest declares a login need,
    # or a program row whose driver cannot start its harness read-only, the
    # shipped OpenAI Codex member's own row among them. A
    # file set to read-only by hand on such a brain shows it chosen, with
    # the same sentence, since its turns are refused. A brain on a key, or
    # a row CYFR keeps read-only, leaves the choice open.
    test "a member whose brain cannot be kept read-only has its read-only choice closed, " <>
           "with why beneath it",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "planned", %{
        "plan" => %{
          "type" => "login",
          "program" => "planner",
          "reason" => "to run Planner on your own plan"
        }
      })

      publish_brain!(ctx, "keyed", %{
        "api_key" => %{
          "type" => "api_key:keyed.test",
          "reason" => "to call Keyed with your key (keyed.test/keys)",
          "fields" => ["KEYED_API_KEY"],
          "required" => true,
          "hosts" => ["api.keyed.example"]
        }
      })

      codex = program_row!(ctx, "openai-codex", "cyfr-codex npx -y @openai/codex@0.169.0")
      claude = program_row!(ctx, "claude", "cyfr-claude-code")

      members = [
        {"planner", "Planner", %{"catalyst_ref" => "catalyst:local.planned"}},
        {"by-hand", "By Hand", %{"catalyst_ref" => "catalyst:local.planned"}},
        {"keyed", "Keyed", %{"catalyst_ref" => "catalyst:local.keyed"}},
        {"coder", "Coder", %{"program" => codex.name}},
        {"held", "Held", %{"program" => claude.name}}
      ]

      for {name, title, brain} <- members do
        {:ok, _} =
          Cyfr.Test.AquaTool.call(
            ctx,
            Map.merge(
              %{
                "action" => "create",
                "name" => name,
                "title" => title,
                "content" => "# #{title}"
              },
              brain
            )
          )
      end

      # Set to read-only by hand, as an edit made off this page would.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "by-hand",
          "mode" => "read-only"
        })

      {view, _html} = mount_athanor(conn, "/aqua")

      for {name, title, brain, shown} <- [
            {"planner", "Planner", "planned", ["auto"]},
            {"by-hand", "By Hand", "planned", ["read-only"]},
            {"coder", "Coder", "openai-codex", ["auto"]},
            {"openai-codex", "OpenAI Codex", "openai-codex", ["auto"]}
          ] do
        assert has_element?(view, mode_choice(name, "read-only") <> "[disabled]")
        refute has_element?(view, mode_choice(name, "auto") <> "[disabled]")
        assert mode_shown(view, name) == shown

        assert texts(view, "#aqua-card-#{name} [data-test=read-only-unheld]") ==
                 [Aqua.Models.unheld_sentence(title, brain)]
      end

      for name <- ["keyed", "held"] do
        assert mode_shown(view, name) == ["auto"]
        refute has_element?(view, mode_choice(name, "read-only") <> "[disabled]")
        refute has_element?(view, "#aqua-card-#{name} [data-test=read-only-unheld]")
      end

      # The auto choice stays open: the member set to read-only by hand
      # is switched to auto from its card.
      {:ok, before} = get_agent(ctx, "by-hand")
      view |> element(mode_choice("by-hand", "auto")) |> render_click()
      assert {:ok, %{before | "mode" => "auto"}} == get_agent(ctx, "by-hand")
    end

    # Every athanor made before modes holds a soul whose file lists its
    # tools under the retired `tool_policy`: the section says what to
    # change in place of every card, and the rest of the page renders.
    test "a soul that still holds tool_policy says what to change in place of every card",
         %{conn: conn, ctx: ctx} do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.soul_file(),
          "---\ntitle: Aqua\ntool_policy:\n  files.read: auto\n---\n\nsoul\n"
        )

      {view, _html} = mount_athanor(conn, "/aqua")

      assert texts(view, ~s([data-test="agents-unavailable"])) == [
               Prima.AgentRef.tool_policy_retired()
             ]

      refute has_element?(view, "[id^=aqua-card-]")
      refute has_element?(view, "form[phx-submit=editor_create_member]")
      refute render(view) =~ "No soul here"
      assert has_element?(view, "#aqua-notes")
    end

    # The soul's list names one action an entry, so what the page shows is
    # what a turn is offered: a file that names a tool's actions as `tool.*`
    # is refused, and the section names the entry and says what to write.
    test "a soul whose tools list holds a wildcard names the entry in place of every card",
         %{conn: conn, ctx: ctx} do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.soul_file(),
          "---\ntitle: Aqua\ntools:\n  - storage.*\n  - files.read\n---\n\nsoul\n"
        )

      {view, _html} = mount_athanor(conn, "/aqua")

      assert texts(view, ~s([data-test="agents-unavailable"])) == [
               Prima.AgentRef.tools_entry_invalid("storage.*")
             ]

      assert Prima.AgentRef.tools_entry_invalid("storage.*") =~ "`storage.*`"
      assert Prima.AgentRef.tools_entry_invalid("storage.*") =~ "list each action by name"
      refute has_element?(view, "[id^=aqua-card-]")
    end

    # A brain's options are what its `describe` declares: the card offers
    # each by its kind and writes the value cast to that kind, and an empty
    # one takes the option off.
    test "a brain's declared options are edited on the card, each as its kind",
         %{conn: conn, ctx: ctx} do
      # No brain here is ready, so the page reads no options of its own;
      # the explorer's are given as a ready brain's `describe` declares
      # them, again after each write's re-read of the section.
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-explorer")
      refute has_element?(view, "[id$=-options]")

      declared = [
        %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]},
        %{"name" => "budget", "kind" => "integer", "default" => 4}
      ]

      change = fn option, value ->
        send_update_agents(view, brain_options: %{"explorer" => declared})

        view
        |> element("#aqua-card-explorer-option-#{option}")
        |> render_change(%{"name" => "explorer", "option" => option, "value" => value})
      end

      send_update_agents(view, brain_options: %{"explorer" => declared})
      assert has_element?(view, "#aqua-card-explorer-options select[aria-label=effort]")

      assert has_element?(
               view,
               ~s{#aqua-card-explorer-options input[aria-label=budget][placeholder="default (4)"]}
             )

      for {option, value, want} <- [{"effort", "high", "high"}, {"budget", "8", 8}] do
        change.(option, value)
        assert {:ok, %{"options" => %{^option => ^want}}} = get_agent(ctx, "explorer")
      end

      change.("effort", "")
      assert {:ok, %{"options" => %{"budget" => 8} = options}} = get_agent(ctx, "explorer")
      refute Map.has_key?(options, "effort")

      # A value outside what the brain declares is refused on the page.
      assert change.("budget", "many") =~ "That option takes a whole number"
      assert {:ok, %{"options" => %{"budget" => 8}}} = get_agent(ctx, "explorer")
    end

    # Each page sends the one option it changed; neither writes back the
    # options it read, so two people editing different options of one
    # brain at once keep both.
    test "two pages editing different brain options at once keep both",
         %{conn: conn, ctx: ctx} do
      declared = [
        %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]},
        %{"name" => "budget", "kind" => "integer"}
      ]

      edits = [{"effort", "high"}, {"budget", "8"}]

      views =
        for _edit <- edits do
          {view, _html} = mount_athanor(conn, "/aqua")
          assert has_element?(view, "#aqua-card-explorer")
          send_update_agents(view, brain_options: %{"explorer" => declared})
          view
        end

      views
      |> Enum.zip(edits)
      |> Enum.map(fn {view, {option, value}} ->
        Task.async(fn ->
          view
          |> element("#aqua-card-explorer-option-#{option}")
          |> render_change(%{"name" => "explorer", "option" => option, "value" => value})
        end)
      end)
      |> Task.await_many(30_000)

      assert {:ok, %{"options" => %{"effort" => "high", "budget" => 8}}} =
               get_agent(ctx, "explorer")
    end

    test "the capability matrix is the soul's alone, its destructive rows among it",
         %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(view, ~s(#aqua-card-aqua input[phx-value-key="files.delete"]))
      refute has_element?(view, ~s(#aqua-card-explorer input[phx-value-key="files.delete"]))
    end

    test "a tools edit lands on the list as it is now, not on the copy the page loaded",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")
      {:ok, %{"tools" => shipped}} = get_agent(ctx, "aqua")

      # Another member's edit, after this page read the soul.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tools_add" => ["vault.list"]
        })

      # A toggle on the soul's card keeps it…
      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{"name" => "aqua", "key" => "storage.write"})

      want = Enum.sort(["storage.write", "vault.list" | shipped])
      assert {:ok, %{"tools" => ^want}} = get_agent(ctx, "aqua")

      # …and another, after yet another edit, keeps both.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tools_add" => ["vault.get"]
        })

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{"name" => "aqua", "key" => "storage.write"})

      want = Enum.sort(["vault.get", "vault.list" | shipped])
      assert {:ok, %{"tools" => ^want}} = get_agent(ctx, "aqua")
    end
  end

  # A section re-reads itself on a message the write sends after it
  # answers, so a card's new state is awaited rather than read at once.
  defp settled(fun, label), do: Prima.Test.Wait.wait_until(fun, 2_000, label)

  # One choice of a member's mode switch.
  defp mode_choice(name, mode),
    do: ~s(#aqua-card-#{name}-mode button[role=radio][phx-value-mode="#{mode}"])

  # The modes a member's switch shows chosen.
  defp mode_shown(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#aqua-card-#{name}-mode [role=radio][aria-checked="true"]))
    |> Enum.flat_map(&LazyHTML.attribute(&1, "phx-value-mode"))
  end

  # Each choice of a member's Model, as its value and the words it shows.
  defp model_choices(view, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#aqua-card-#{name}-model select option))
    |> Enum.map(fn option ->
      {option |> LazyHTML.attribute("value") |> List.first(),
       option |> LazyHTML.text() |> String.trim()}
    end)
  end

  defp say(fake, row, event),
    do: Cyfr.Test.ScriptedBackends.write(fake, row.id, Jason.encode!(event))

  # Plays the driver of `row` for every listing a page asks of it, a new
  # driver process each, until `shown` holds: its hello once the session
  # stands, then the models and efforts its program lists.
  defp lists!(fake, row, shown, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    home = row.id

    cond do
      shown.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the card did not show its program's listing")

      true ->
        receive do
          {:session, "open", %{"mode" => "run", "home_id" => ^home}, _fields} ->
            :ok

          {:session, "recv", %{"after" => 0}, _fields} ->
            say(fake, row, %{
              "t" => "hello",
              "v" => Opus.Brain.Wire.version(),
              "driver" => "cyfr-claude-code",
              "boot" => "b#{System.unique_integer([:positive])}"
            })

          {:session, "send", %{"lines" => [line]}, _fields} ->
            case Jason.decode!(line) do
              %{"t" => "models", "id" => id} ->
                say(fake, row, %{
                  "t" => "models",
                  "id" => id,
                  "models" => [
                    %{"id" => "default", "name" => "Default (recommended)"},
                    %{"id" => "opus", "name" => "Opus"},
                    %{"id" => "haiku", "name" => "Haiku"}
                  ],
                  "efforts" => ["low", "high", "max"]
                })

              _another ->
                :ok
            end
        after
          100 -> :ok
        end

        lists!(fake, row, shown, deadline)
    end
  end

  # The text of each element `selector` finds, trimmed.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # A card whose brain waits on the person's grant alone: it says so, and
  # its Connect opens the setup, whose step for the brain is the grant,
  # never the Programs page.
  defp card_needs_grant!(view, name) do
    card = "#aqua-card-" <> name
    assert has_element?(view, card, "Not connected — it needs only your grant")
    refute has_element?(view, card, "set up its program")
    refute has_element?(view, card, "Model connected")
    assert has_element?(view, card <> ~s( a[data-test="connect"]), "Connect")
  end

  # A person's grant of `ref`, walked as their own page walks it.
  # The athanor's kept driven program row `name`, as an install confirmed
  # on the Programs page leaves it.
  # The soul's brain is a catalyst whose login needs the `claude` program.
  defp soul_runs_claude!(ctx) do
    manifest = %{
      "name" => "harness",
      "type" => "catalyst",
      "version" => "1.0.0",
      "publisher" => "local",
      "needs" => %{
        "claude" => %{
          "type" => "login",
          "program" => "claude",
          "reason" => "to run Claude Code on your own plan",
          "install" => %{"command" => "npx -y @anthropic-ai/claude-code"}
        }
      }
    }

    unit =
      Arca.Test.UnitFixtures.tenant_component!(ctx, "catalyst", "local", "harness", "1.0.0",
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm(:catalyst)
      )

    {:ok, _} = Compendium.Registry.register_from_arca(ctx, unit)
    soul_names_catalyst!(ctx, "catalyst:local.harness")
  end

  @backends_root :crypto.strong_rand_bytes(32)

  # The programs controller on a scripted backends service, put back
  # however the test ends; what the service is asked arrives here.
  defp backends! do
    on_exit(fn ->
      :persistent_term.erase({Arca.ControlPlane, :generation})
      Arca.ControlPlane.record(:unclaimed)
    end)

    fake = Cyfr.Test.ScriptedBackends.start(self(), @backends_root)

    Cyfr.Test.ScriptedBackends.supervise_controller(
      url: fake.url,
      root: @backends_root,
      tick_ms: 3_600_000
    )

    assert_receive {:control, "reconcile", _reconcile, _fields}, 2_000
    fake
  end

  defp program_row!(ctx, name, command \\ nil) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => command || "npx -y #{name}", "env" => %{}})
      })

    row
  end

  defp grant!(ctx, ref, over) do
    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, over)
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  # The tasks the page itself started on the console's supervisor since `before`
  # was read: a task names the process that started it first in its
  # `$callers`, which leaves out the tasks those tasks start in turn.
  defp page_tasks(%{pid: page}, before) do
    for pid <- Task.Supervisor.children(Prism.TaskSupervisor) -- before,
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        match?([^page | _], dictionary[:"$callers"]),
        do: pid
  end
end
