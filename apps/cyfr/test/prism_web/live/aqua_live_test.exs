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

  # The crew members these tests make, as the person makes one on the Aqua
  # page: the seed ships none.
  @members %{
    "claude-code" => %{"title" => "Claude Code", "program" => "claude-code", "model" => "opus"},
    "openai-codex" => %{
      "title" => "OpenAI Codex",
      "program" => "openai-codex",
      "model" => "gpt-6.1-sol"
    },
    "explorer" => %{
      "title" => "Explorer",
      "catalyst_ref" => "catalyst:local.gemini",
      "model" => "gemini-pro-latest"
    }
  }

  defp member!(ctx, name) do
    args = Map.merge(%{"action" => "create", "name" => name}, Map.fetch!(@members, name))
    {:ok, %{"created" => ^name}} = Cyfr.Test.AquaTool.call(ctx, args)
    :ok
  end

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
        "title" => "Tom"
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

  # Seat the soul on a crew member of its own that names `ref`, and put it
  # back afterwards: Aqua runs on the brain of the member it names, and the
  # agent files live in the suite's shared tree, so a write left behind is
  # the next test's starting state.
  defp soul_names_catalyst!(ctx, ref) do
    {:ok, soul} = Cyfr.Test.AquaTool.call(ctx, %{"action" => "get", "name" => "aqua"})
    was = soul["member"]

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => "brain",
        "title" => "Brain",
        "catalyst_ref" => ref
      })

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => "brain"})

    on_exit(fn ->
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => was})
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "delete", "name" => "brain"})
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

  # The setup's rows of the program brains CYFR ships, after the API ones.
  defp program_rows,
    do: Enum.map(Opus.Programs.Definition.brains(), &("aqua-setup-brain-" <> &1.name))

  # What a program with no sign-in answers its listing with.
  @signed_out "Claude Code is not signed in: sign it in on its terminal."

  # What the setup says while nothing is connected and nothing ticked.
  @setup_needs "Tick the brains you have: a key from a model provider, or Claude Code or " <>
                 "OpenAI Codex on your own plan."

  # The setup read again, as the page reads it after a write of its own:
  # each standing program brain's listing is asked once more.
  defp reread_setup(view), do: send(view.pid, {:refresh, :setup})

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

    # Aqua on a member whose program is not installed: Aqua's card says so
    # in the sentence Aqua's turn is refused with, naming the member, whose
    # own card offers the install once and says nothing of it twice.
    test "Aqua's card says its chosen member's program is missing", %{conn: conn, ctx: ctx} do
      on_exit(fn ->
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
      end)

      :ok = member!(ctx, "claude-code")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "member" => "claude-code"
        })

      {:ok, roster} = Aqua.AgentConfig.roster(ctx)
      assert Aqua.Models.model_status(ctx, roster)["aqua"] == {:program_missing, "claude-code"}
      {view, _html} = mount_athanor(conn, "/aqua")
      sentence = Prima.Refusal.message({:crew_unready, "Claude Code", :program_missing})

      assert has_element?(view, ~s(#aqua-card-aqua [data-test="program-refused"]), sentence)
      refute has_element?(view, ~s(#aqua-card-aqua [data-test="install-program"]))

      assert has_element?(
               view,
               ~s(#aqua-card-claude-code [data-test="install-program"]),
               "install claude-code"
             )

      refute has_element?(view, ~s(#aqua-card-claude-code [data-test="program-refused"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # A new athanor's Aqua runs on no one; the card names who it runs on and,
    # while that member does not stand, says why in the sentence Aqua's
    # turn is refused with (`Prima.Refusal`). A member in read-only whose
    # brain CYFR cannot keep read-only leaves Aqua unable to run, in the
    # member's own sentence.
    test "Aqua's card names the member it runs on and says why it cannot run, as its turn does",
         %{conn: conn, ctx: ctx} do
      said = fn view ->
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s(#aqua-card-aqua [data-test="aqua-runs-on-refused"]))
        |> LazyHTML.text()
        |> String.trim()
      end

      :ok = member!(ctx, "explorer")
      :ok = member!(ctx, "openai-codex")
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, ~s(#aqua-card-aqua-member option[value=""][selected]))
      assert said.(view) == Prima.Refusal.message({:aqua_runs_on, :none, nil})
      refute has_element?(view, "#aqua-card-aqua-model")

      on_exit(fn ->
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
      end)

      for {edit, reason} <- [
            {%{"member" => "ghost"}, {:aqua_runs_on, :missing, "ghost"}},
            {%{"member" => "explorer"}, nil}
          ] do
        {:ok, _} =
          Cyfr.Test.AquaTool.call(ctx, Map.merge(%{"action" => "update", "name" => "aqua"}, edit))

        send_update_agents(view, load: true)

        if reason,
          do: assert(said.(view) == Prima.Refusal.message(reason)),
          else: refute(has_element?(view, ~s(#aqua-card-aqua [data-test="aqua-runs-on-refused"])))
      end

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "explorer",
          "disabled" => true
        })

      send_update_agents(view, load: true)
      assert said.(view) == Prima.Refusal.message({:aqua_runs_on, :disabled, "explorer"})

      # On a read-only member whose program CYFR cannot hold read-only.
      _row = program_row!(ctx, "openai-codex", "cyfr-codex npx -y @openai/codex@0.169.0")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "openai-codex",
          "mode" => "read-only"
        })

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "member" => "openai-codex"
        })

      send_update_agents(view, load: true)

      assert has_element?(
               view,
               ~s(#aqua-card-aqua [data-test="read-only-unheld"]),
               Aqua.Models.unheld_sentence("OpenAI Codex", "openai-codex")
             )

      Cyfr.Test.Sandbox.end_views()
    end

    # Set up is the person's press, offered while the program's listing is
    # refused, as a program with no sign-in refuses it: it starts the
    # program in its row's folder, at a size the frame corrects when it
    # attaches, and shows its terminal with the way back here.
    test "Set up on the card starts the program and shows its terminal, which comes back here",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "claude-code")
      row = brain_row!(ctx, "claude-code")
      home = row.id
      fake = backends!()
      set_up = ~s(#aqua-card-claude-code [data-test="set-up-program"])

      {view, _html} = mount_athanor(conn, "/aqua")
      lists!(fake, row, fn -> has_element?(view, set_up) end, {:refused, @signed_out})

      assert has_element?(
               view,
               ~s(#aqua-card-claude-code [data-test="program-signed-out"]),
               @signed_out
             )

      refute_received {:session, "open", %{"mode" => "terminal"}, _fields}

      view |> element(set_up) |> render_click()

      assert_receive {:session, "open",
                      %{"home_id" => ^home, "argv" => [], "rows" => 24, "cols" => 80}, _fields},
                     5_000

      {path, _flash} = assert_redirect(view, 5_000)
      assert URI.parse(path).path =~ ~r{/programs$}

      assert %{"terminal" => "trm_" <> _, "from" => "aqua"} =
               URI.decode_query(URI.parse(path).query)
    end

    # Set up shows the person's running terminal of the row when one runs,
    # whichever open started it (the install's is the same open of the
    # same person's), so the kept folder never runs a second of the program
    # from here; once that terminal has ended, Set up opens one of its own.
    test "Set up shows the program's running terminal, and opens one only when none runs",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "claude-code")
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      home = row.id
      set_up = ~s(#aqua-card-claude-code [data-test="set-up-program"])
      signed_out = {:refused, @signed_out}

      {view, _html} = mount_athanor(conn, "/aqua")
      lists!(fake, row, fn -> has_element?(view, set_up) end, signed_out)
      view |> element(set_up) |> render_click()
      first = set_up_terminal!(view)
      assert opened(home) == [first]

      # Set up again shows the same terminal and opens none.
      {view, _html} = mount_athanor(conn, "/aqua")
      lists!(fake, row, fn -> has_element?(view, set_up) end, signed_out)
      view |> element(set_up) |> render_click()
      assert set_up_terminal!(view) == first
      assert opened(home) -- [first] == []

      Cyfr.Test.ScriptedBackends.end_sessions(fake, home)

      Prima.Test.Wait.wait_until(
        fn -> Registry.lookup(Opus.Programs.Registry, {:terminal, first}) == [] end,
        5_000,
        "the first terminal to end"
      )

      {view, _html} = mount_athanor(conn, "/aqua")
      lists!(fake, row, fn -> has_element?(view, set_up) end, signed_out)
      view |> element(set_up) |> render_click()
      second = set_up_terminal!(view)
      refute second == first
      assert second in opened(home)
    end

    # A crew member whose brain needs nothing of the person, never granted,
    # waits on the person's grant alone: its card says so, never Model
    # connected, and its Connect opens the setup.
    test "a crew member whose brain needs only the grant says so on its card, with Connect",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "open", %{})

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "opener",
          "title" => "Opener",
          "catalyst_ref" => "catalyst:local.open"
        })

      {view, _html} = mount_athanor(conn, "/aqua")
      card = "#aqua-card-opener"
      assert has_element?(view, card, "Not connected — it needs only your grant")
      refute has_element?(view, card, "Model connected")
      assert has_element?(view, card <> ~s( a[data-test="connect"]), "Connect")
    end

    # A crew member whose brain is a program names the row by its name.
    # While the athanor has no row of that name, its card offers to install
    # it, through the Programs page's form for a program of that name;
    # once the row stands as a brain's and its program's listing is
    # refused, as a program with no sign-in refuses it, to set it up, where
    # the person signs it in; once the listing answers, it is connected.
    # Either way it offers no other brain, and its models and efforts are
    # the ones its program lists, read from the row's driver; before the
    # row is there the member's own model stands alone.
    test "a crew member on a program brain offers its install, then its set up, " <>
           "with the models and efforts its program lists",
         %{conn: conn, ctx: ctx} do
      fake = backends!()

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "coder",
          "title" => "Coder",
          "program" => "claude-code",
          "model" => "opus"
        })

      card = "#aqua-card-coder"
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(
               view,
               card <> ~s( a[data-test="install-program"]),
               "install claude-code"
             )

      assert has_element?(view, card, "Its brain runs a program you have not installed")

      [href] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(card <> ~s( a[data-test="install-program"]))
        |> LazyHTML.attribute("href")

      assert URI.parse(href).path == athanor_path("/programs")

      assert URI.decode_query(URI.parse(href).query) == %{
               "add" => "claude-code",
               "from" => "aqua"
             }

      refute has_element?(view, card <> ~s( [data-test="set-up-program"]))
      refute has_element?(view, card <> ~s( [data-test="connect"]))
      refute has_element?(view, card <> " button[phx-click=open_consent]")
      assert model_choices(view, "coder") == [{"", "The program's default"}, {"opus", "opus"}]
      refute has_element?(view, "#aqua-card-coder-options")
      refute_received {:session, "open", _open, _fields}

      row = brain_row!(ctx, "claude-code")
      send_update_agents(view, load: true)
      reread_setup(view)
      refute has_element?(view, card <> ~s( a[data-test="install-program"]))

      # The row's driver refuses the listing while the program is not signed
      # in: the card offers its set up, in the refusal's words, and is not
      # connected.
      lists!(
        fake,
        row,
        fn -> has_element?(view, card <> ~s( [data-test="set-up-program"])) end,
        {:refused, @signed_out}
      )

      assert has_element?(view, card <> ~s( [data-test="set-up-program"]), "Set up claude-code")
      assert has_element?(view, card <> ~s( [data-test="program-signed-out"]), @signed_out)
      refute has_element?(view, card, "Model connected")
      refute has_element?(view, card <> " button[phx-click=open_consent]")

      # The row's driver lists its program's models, for the person here:
      # each listing the page asks for is answered, until the card shows it.
      listed = [
        {"", "The program's default"},
        {"default", "Default (recommended)"},
        {"opus", "Opus"},
        {"haiku", "Haiku"}
      ]

      reread_setup(view)
      lists!(fake, row, fn -> model_choices(view, "coder") == listed end)
      assert has_element?(view, card, "Model connected")
      refute has_element?(view, card <> ~s( [data-test="set-up-program"]))

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

      assert {:ok, %{"program" => "claude-code", "catalyst_ref" => nil, "model" => "haiku"}} =
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
            "program" => program
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

    test "the shipped soul offers no Delete; a crew member is disabled and enabled from its card",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "explorer")
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(view, "#aqua-card-aqua", "shipped")
      refute has_element?(view, "#aqua-card-aqua button[phx-click=editor_delete]")
      refute has_element?(view, "#aqua-card-aqua button[phx-click=editor_set_disabled]")

      # The athanor's own: a Delete and a Disable.
      assert has_element?(view, "#aqua-card-explorer", "yours")
      assert has_element?(view, "#aqua-card-explorer button[phx-click=editor_delete]")

      view
      |> element("#aqua-card-explorer button[phx-click=editor_set_disabled]", "Disable")
      |> render_click()

      assert {:ok, %{"disabled" => true}} = get_agent(ctx, "explorer")

      # Still on the page — `list` drops it, the page does not — as
      # disabled, with the way back. The write answers before the section
      # re-reads, so the card is awaited.
      settled(
        fn -> has_element?(view, "#aqua-card-explorer", "disabled") end,
        "the disabled card"
      )

      assert has_element?(view, "#aqua-card-explorer", "disabled")

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
          "name" => "scout"
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
          "name" => "scout"
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
      # Nor a prompt: its file is its frontmatter alone.
      assert bytes == "---\ntitle: scout\nmode: auto\n---\n"

      # Its card says what it is good at and what to avoid, and edits no
      # capabilities, which are the soul's, and no prompt, which only the
      # soul has.
      settled(fn -> has_element?(view, "#aqua-card-scout") end, "the scout card")
      assert has_element?(view, "#aqua-card-scout-description")
      assert has_element?(view, "#aqua-card-scout-avoid")
      refute has_element?(view, "#aqua-card-scout [phx-click=editor_edit_prompt]")
      assert has_element?(view, "#aqua-card-aqua [phx-click=editor_edit_prompt]", "Edit prompt")

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

      publish_brain!(ctx, "open", %{})

      :ok = soul_names_catalyst!(ctx, "catalyst:local.keyed")

      # The soul's brain is not connected, so the setup is the page's
      # first step, open without being asked for.
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-setup[open]")

      assert setup_rows(view) ==
               ["aqua-setup-brain-keyed", "aqua-setup-brain-open" | program_rows()]

      assert has_element?(
               view,
               "#aqua-setup-brain-keyed label",
               "a key: to call Keyed with your key (keyed.test/keys)"
             )

      assert has_element?(view, "#aqua-setup-brain-open label", "needs only your grant")

      # With nothing ticked, the setup says what Aqua needs.
      assert has_element?(view, ~s([data-test="setup-needs"]), @setup_needs)

      refute has_element?(view, "#aqua-setup-steps")

      view |> element("#aqua-setup-brain-keyed input") |> render_click()
      view |> element("#aqua-setup-brain-open input") |> render_click()
      refute has_element?(view, ~s([data-test="setup-needs"]))

      assert has_element?(
               view,
               "#aqua-setup-step-keyed button[phx-click=open_consent]",
               "Enter the key"
             )

      assert has_element?(view, "#aqua-setup-step-open button[phx-click=open_consent]", "Grant")

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
               "aqua-setup-brain-open" | program_rows()
             ]
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
          "title" => "Tidy"
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

      assert has_element?(view, ~s([data-test="setup-needs"]), @setup_needs)

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

      # A connected brain is a member's: the crew's step suggests one on it,
      # and Aqua's waits for a member to run on.
      assert has_element?(view, "#aqua-setup-suggest-open")
      refute has_element?(view, ~s([data-test="setup-crew-waits"]))
      assert has_element?(view, ~s([data-test="setup-aqua-waits"]), "Make a crew member first.")
      refute has_element?(view, "#aqua-setup-member")
      refute has_element?(view, "#aqua-setup-pick")

      # The brain's models call runs beside the page; it ends before the test does.
      Cyfr.Test.Sandbox.end_views()
    end

    # A new athanor: the seed ships no crew and its Aqua runs on no one, so
    # the setup is open on its first step, the crew's step waits on a
    # brain and Aqua's on a member, and the daily thread says what is left
    # to do, with the way here.
    test "a new athanor's setup waits on a brain, then a member, and its daily thread says so",
         %{conn: conn, athanor: athanor} do
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-setup[open]")

      assert has_element?(view, ~s(#aqua-setup-step-brains[data-done="false"]), "1. Brains")

      assert has_element?(
               view,
               ~s(#aqua-setup-step-brains [data-test="setup-needs"]),
               @setup_needs
             )

      for %{name: name} <- Opus.Programs.Definition.brains(),
          do:
            assert(
              has_element?(view, ~s(#aqua-setup-brain-#{name}[data-state="program_missing"]))
            )

      assert has_element?(view, ~s(#aqua-setup-step-crew[data-done="false"]), "2. Crew")

      assert has_element?(
               view,
               ~s(#aqua-setup-step-crew [data-test="setup-crew-waits"]),
               "Connect a brain first."
             )

      refute has_element?(view, ~s(form[id^="aqua-setup-suggest-"]))
      refute has_element?(view, "#aqua-setup-members")
      assert has_element?(view, ~s(#aqua-setup-step-aqua[data-done="false"]), "3. Aqua")

      assert has_element?(
               view,
               ~s(#aqua-setup-step-aqua [data-test="setup-aqua-waits"]),
               "Make a crew member first."
             )

      refute has_element?(view, "#aqua-setup-member")

      # The daily thread's pane says it in Aqua's own sentence, with the way
      # to this page.
      {:ok, pane, _html} =
        live_isolated(conn, PrismWeb.ThreadPaneLive, session: %{"athanor_id" => athanor.id})

      sentence = Prima.Refusal.message({:aqua_runs_on, :none, nil})

      settled(
        fn -> has_element?(pane, ~s([data-test="model-unseated"]), sentence) end,
        "the pane's sentence"
      )

      assert has_element?(
               pane,
               ~s(a[data-test="model-connect"][href="#{athanor_path("/aqua?setup=1", athanor)}"]),
               "Open your Aqua page."
             )

      Cyfr.Test.Sandbox.end_views()
    end

    # A program brain whose row stands: while its program's listing is
    # refused, as a program with no sign-in refuses it, the setup says so
    # in the refusal's words, its step signs it in on its terminal, and no
    # member is suggested on it; once the listing answers it is signed in,
    # and the crew's step suggests the member CYFR suggests for it, with the
    # models its program lists. Make with a model writes that member on the
    # program and asks its consent at once; with none it writes nothing.
    test "a program brain signs in on the setup, and Make writes the member it suggests",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      %{name: name, title: title} = Opus.Programs.Definition.brain("claude-code")
      row = brain_row!(ctx, name)
      brain = "#aqua-setup-brain-" <> name
      step = "#aqua-setup-step-program-" <> name
      suggest = "#aqua-setup-suggest-" <> name

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      view |> element(brain <> " input") |> render_click()

      lists!(
        fake,
        row,
        fn -> has_element?(view, brain <> ~s([data-state="signed_out"])) end,
        {:refused, @signed_out}
      )

      assert has_element?(view, brain <> ~s( [data-test="setup-signed-out"]), @signed_out)
      assert has_element?(view, step, "#{title}: sign it in on its terminal.")
      assert has_element?(view, step <> ~s( button[data-test="set-up-program"]), "Set up #{name}")
      refute has_element?(view, suggest)
      assert has_element?(view, ~s([data-test="setup-crew-waits"]), "Connect a brain first.")

      # Signed in: its listing answers.
      reread_setup(view)
      lists!(fake, row, fn -> has_element?(view, suggest) end)
      assert has_element?(view, brain <> ~s([data-state="signed_in"]), "signed in")
      assert has_element?(view, ~s(#aqua-setup-step-brains[data-done="true"]))
      refute has_element?(view, step)
      refute has_element?(view, ~s([data-test="setup-crew-waits"]))

      assert choices(view, suggest <> ~s( select[name="model"] option)) == [
               {"", "Choose a model"},
               {"default", "Default (recommended)"},
               {"opus", "Opus"},
               {"haiku", "Haiku"}
             ]

      assert has_element?(view, suggest <> ~s( button[type="submit"]), "Make #{title}")

      # No model, no member.
      assert view |> form(suggest, %{"model" => ""}) |> render_submit() =~ "Choose a model first."
      assert {:error, _} = get_agent(ctx, name)

      # A member is its brain, its model and its effort: the row offers the
      # efforts the program lists, and what it is good at and should avoid
      # are the person's to write, or to leave empty.
      assert texts(view, suggest <> ~s( select[name="effort"] option)) ==
               ["The program's default effort", "low", "high", "max"]

      assert has_element?(
               view,
               suggest <> ~s| input[name="description"][placeholder="Good at (optional)"]|
             )

      assert has_element?(
               view,
               suggest <> ~s| input[name="avoid"][placeholder="Avoid (optional)"]|
             )

      view
      |> form(suggest, %{
        "model" => "opus",
        "effort" => "high",
        "description" => " Builds things "
      })
      |> render_submit()

      assert {:ok,
              %{
                "title" => ^title,
                "program" => ^name,
                "catalyst_ref" => nil,
                "model" => "opus",
                "mode" => "auto",
                "description" => "Builds things",
                "avoid" => "",
                "options" => %{"effort" => "high"}
              }} = get_agent(ctx, name)

      assert render(view) =~ "Made #{title}."

      settled(
        fn ->
          has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]), "agent:local.#{name}")
        end,
        "the member's consent"
      )

      Cyfr.Test.Sandbox.end_views()
    end

    # Several members may run on one brain: once the member suggested for
    # it is made, the suggestion is gone, and + New crew member makes
    # another, whose card's pick puts it on the same brain.
    test "after the member suggested on a brain is made, another made by hand runs on the same " <>
           "brain, and none is suggested again",
         %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      suggest = "#aqua-setup-suggest-open"
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      assert choices(view, suggest <> ~s( select[name="model"] option)) == [
               {"", "Choose a model"},
               {"open-1", "open-1"}
             ]

      view |> form(suggest, %{"model" => "open-1"}) |> render_submit()

      assert {:ok, %{"catalyst_ref" => "catalyst:local.open", "model" => "open-1"}} =
               get_agent(ctx, "open")

      settled(fn -> not has_element?(view, suggest) end, "the suggestion made")

      view
      |> form("form[phx-submit=editor_create_member]", %{"name" => "second"})
      |> render_submit()

      settled(fn -> has_element?(view, "#aqua-card-second-model") end, "the second card")

      view
      |> element("#aqua-card-second-model")
      |> render_change(%{"name" => "second", "value" => "open::open-1"})

      for name <- ~w(open second) do
        assert {:ok, %{"catalyst_ref" => "catalyst:local.open", "model" => "open-1"}} =
                 get_agent(ctx, name)
      end

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, "#aqua-setup-made-open")
      assert has_element?(view, "#aqua-setup-made-second")
      assert has_element?(view, "#aqua-card-open") and has_element?(view, "#aqua-card-second")
      refute has_element?(view, ~s(form[id^="aqua-setup-suggest-"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # What the setup makes, the person made: the member is the athanor's
    # own, and a restore of the shipped files keeps it as it is.
    test "a member made from the setup is the athanor's own, and a restore keeps its file",
         %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      actor = Sanctum.Context.actor(ctx)
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      view |> form("#aqua-setup-suggest-open", %{"model" => "open-1"}) |> render_submit()
      settled(fn -> has_element?(view, "#aqua-card-open", "yours") end, "the made member's card")
      refute has_element?(view, "#aqua-card-open", "shipped")
      {:ok, bytes} = Arca.get(actor, Compendium.AquaPath.crew_file("open"))

      view |> element("#aqua-restore button[phx-click=restore_shipped]") |> render_click()
      assert has_element?(view, "#aqua-restore-result", "Kept (1)")
      assert render(view) =~ "aqua/crew/open.md"
      assert {:ok, ^bytes} = Arca.get(actor, Compendium.AquaPath.crew_file("open"))
      Cyfr.Test.Sandbox.end_views()
    end

    # The shipped API brains are catalysts, and each program brain CYFR
    # ships is one row of its own after them, which no catalyst's row
    # reads the same name beside.
    test "with the shipped brains installed, the setup offers each API brain, then each " <>
           "program brain CYFR ships, once each",
         %{conn: conn, ctx: ctx} do
      shipped = Enum.map(Cyfr.Test.SeedBundle.model_chat_units(), & &1.name)
      Cyfr.Test.SeedBundle.lay!(shipped)
      :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
      {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      brains = for "aqua-setup-brain-" <> name <- setup_rows(view), do: name
      programs = Enum.map(Opus.Programs.Definition.brains(), & &1.name)

      assert Enum.sort(brains -- programs) == Enum.sort(shipped)
      assert brains -- shipped == programs
      assert Enum.uniq(brains) == brains, "a program brain's name is no catalyst's beside it"
      Cyfr.Test.Sandbox.end_views()
    end

    # Each program brain CYFR ships is a row of the setup, named by its
    # title. Ticked, its install is the Programs page's form for it; once
    # its row stands and its program's listing is refused, as a program
    # with no sign-in refuses it, its step is to sign it in on its
    # terminal; once the listing answers it is signed in, and a crew
    # member's picker offers, under the brain's title, the models its
    # program lists. Picking one makes that crew member name the program,
    # with that model and no catalyst, and asks its consent at once; a
    # key's model takes the program away again.
    for %{name: name, title: title, command: command} <- Opus.Programs.Definition.brains() do
      @tag brain: {name, title, command}
      test "the setup offers #{name} as a program brain, installs it, signs it in and makes it " <>
             "a crew member's brain; a key's model takes it back",
           %{conn: conn, ctx: ctx, brain: {name, title, command}} do
        fake = backends!()
        publish_brain!(ctx, "open", %{})
        grant!(ctx, "catalyst:local.open", %{bindings: []})
        remember_catalogue!(%{"open" => ["open-1"]}, %{"open" => "catalyst:local.open:0.1.0"})
        {:ok, _} = Cyfr.Test.AquaTool.call(ctx, %{"action" => "create", "name" => "mine"})
        {:ok, before} = get_agent(ctx, "mine")
        assert before["program"] == nil

        {view, _html} = mount_athanor(conn, "/aqua?setup=1&agent=mine")
        brain = "#aqua-setup-brain-" <> name
        assert has_element?(view, brain <> ~s([data-state="program_missing"]))

        assert texts(view, brain <> " label span") == [
                 title,
                 "a plan: to run #{title} in its own folder, signed in to your own plan"
               ]

        view |> element(brain <> " input") |> render_click()
        step = "#aqua-setup-step-program-" <> name
        assert has_element?(view, step, "#{title}: install its program, then sign it in.")

        assert has_element?(
                 view,
                 step <> ~s( a[data-test="install-program"]),
                 "install #{name}"
               )

        [href] =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query(step <> ~s( a[data-test="install-program"]))
          |> LazyHTML.attribute("href")

        assert URI.parse(href).path == athanor_path("/programs")
        assert URI.decode_query(URI.parse(href).query) == %{"add" => name, "from" => "aqua"}

        # Its row stands, and its program has no sign-in yet.
        row = program_row!(ctx, name, command)
        reread_setup(view)

        lists!(
          fake,
          row,
          fn -> has_element?(view, brain <> ~s([data-state="signed_out"])) end,
          {:refused, @signed_out}
        )

        assert has_element?(view, brain <> ~s( [data-test="setup-signed-out"]), @signed_out)
        assert has_element?(view, step, "#{title}: sign it in on its terminal.")
        assert has_element?(view, step <> ~s( [data-test="set-up-program"]), "Set up #{name}")
        refute has_element?(view, step <> ~s( a[data-test="install-program"]))
        assert program_choices(view, title) == []

        # Signed in: its listing answers.
        listing = [
          %{"id" => "the-model", "name" => "The model"},
          %{"id" => "other", "name" => "Other"}
        ]

        reread_setup(view)
        lists!(fake, row, fn -> program_choices(view, title) != [] end, listing)
        assert has_element?(view, brain <> ~s([data-state="signed_in"]), "signed in")
        refute has_element?(view, step)

        assert program_choices(view, title) == [
                 {"::program::#{name}::the-model", "The model"},
                 {"::program::#{name}::other", "Other"}
               ]

        view
        |> form("#aqua-setup-pick", %{"value" => "::program::#{name}::the-model"})
        |> render_change()

        assert get_agent(ctx, "mine") ==
                 {:ok,
                  %{
                    before
                    | "program" => name,
                      "model" => "the-model",
                      "catalyst_ref" => nil
                  }}

        settled(
          fn ->
            has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]), "agent:local.mine")
          end,
          "the member's consent asked again"
        )

        # A key's model is a catalyst's: the program goes.
        view |> form("#aqua-setup-pick", %{"value" => "open::open-1"}) |> render_change()

        assert get_agent(ctx, "mine") ==
                 {:ok, %{before | "catalyst_ref" => "catalyst:local.open", "model" => "open-1"}}

        Cyfr.Test.Sandbox.end_views()
      end
    end

    test "a catalyst called program keeps its model containing the picker separator",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "program", %{})
      grant!(ctx, "catalyst:local.program", %{bindings: []})

      remember_catalogue!(
        %{"program" => ["vendor::model"]},
        %{"program" => "catalyst:local.program:0.1.0"}
      )

      {:ok, _} = Cyfr.Test.AquaTool.call(ctx, %{"action" => "create", "name" => "mine"})
      {:ok, before} = get_agent(ctx, "mine")

      {view, _html} = mount_athanor(conn, "/aqua?setup=1&agent=mine")

      assert has_element?(
               view,
               ~s(#aqua-setup-pick option[value="program::vendor::model"])
             )

      view
      |> form("#aqua-setup-pick", %{"value" => "program::vendor::model"})
      |> render_change()

      assert get_agent(ctx, "mine") ==
               {:ok,
                %{before | "catalyst_ref" => "catalyst:local.program", "model" => "vendor::model"}}

      Cyfr.Test.Sandbox.end_views()
    end

    # Aqua answers with the brain, model and mode of the crew member it
    # runs on: choosing one asks Aqua's consent again at once, and grants
    # nothing by itself.
    test "choosing the crew member Aqua runs on asks for Aqua's consent again at once",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "open", %{})
      grant!(ctx, "catalyst:local.open", %{bindings: []})

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "mine",
          "title" => "Mine",
          "catalyst_ref" => "catalyst:local.open",
          "model" => "open-1"
        })

      on_exit(fn ->
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
      end)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, ~s(#aqua-setup-brain-open[data-state="ready"]))
      assert has_element?(view, "#aqua-setup-member", "Which crew member does Aqua run on?")
      assert has_element?(view, ~s(#aqua-setup-member option[value="mine"]), "Mine")

      view |> form("#aqua-setup-member", %{"member" => "mine"}) |> render_change()

      assert {:ok,
              %{"member" => "mine", "catalyst_ref" => "catalyst:local.open", "model" => "open-1"}} =
               get_agent(ctx, "aqua")

      settled(
        fn ->
          has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]), "agent:local.aqua")
        end,
        "the soul's consent asked again"
      )

      # The card names who Aqua runs on, and has no model of its own.
      assert has_element?(view, ~s(#aqua-card-aqua-member option[value="mine"][selected]))
      refute has_element?(view, "#aqua-card-aqua-model")
      refute has_element?(view, "#aqua-card-aqua-mode")

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

      # A member on a key's model, whose card's picker reads the catalogue.
      :ok = member!(ctx, "explorer")
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

    test "the prompt editor saves the soul's prompt it opened, and refuses to save over another " <>
           "member's edit made since",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")
      agents = with_target(view, "#aqua-agents")

      render_click(agents, "editor_edit_prompt", %{"name" => "aqua"})
      html = view |> form("#prompt-editor form", %{"content" => "# Mine"}) |> render_submit()

      refute html =~ "Save failed"
      assert {:ok, %{"content" => "# Mine"}} = get_agent(ctx, "aqua")
      refute has_element?(view, "#prompt-editor")

      render_click(agents, "editor_edit_prompt", %{"name" => "aqua"})
      assert has_element?(view, "#prompt-editor textarea[name=content]", "# Mine")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "content" => "# Theirs"
        })

      html = view |> form("#prompt-editor form", %{"content" => "# Again"}) |> render_submit()

      assert html =~ "The prompt changed since you opened it"
      assert {:ok, %{"content" => "# Theirs"}} = get_agent(ctx, "aqua")
      assert has_element?(view, "#prompt-editor textarea[name=content]")
    end

    # Nothing runs a prompt CYFR no longer shows: a crew file that still
    # holds one stands on the page as the sentence that says what to do.
    test "a crew member whose file still holds a prompt is shown as what to change, in place of its card",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "claude-code")

      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.agent_file("explorer"),
          "---\ntitle: Explorer\n---\n\nYou are the explorer.\n"
        )

      {view, _html} = mount_athanor(conn, "/aqua")

      settled(fn -> has_element?(view, "#aqua-refused-explorer") end, "the explorer's sentence")

      assert has_element?(
               view,
               "#aqua-refused-explorer[data-test=crew-refused]",
               Compendium.AquaAgent.prompt_refused("explorer")
             )

      refute has_element?(view, "#aqua-card-explorer")
      assert has_element?(view, "#aqua-card-claude-code")
      Cyfr.Test.Sandbox.end_views()
    end

    # A box ticked offers the soul the tool, and every crew member with
    # it; cleared, it takes it off. The provider's own search is a box of
    # its own on the same list.
    test "a checkbox offers the soul a tool and takes it off again; a crew member holds none",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "explorer")
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

    # Each crew member's mode is its own: its switch shows it, and a choice
    # writes it into the member's file. Aqua runs in the mode of the crew
    # member it runs on, and its card has no switch of its own.
    test "each member's switch shows its mode, and a choice writes it to the member's file",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "explorer")
      actor = Sanctum.Context.actor(ctx)
      {view, _html} = mount_athanor(conn, "/aqua")
      refute has_element?(view, "#aqua-card-aqua-mode")

      for name <- ["explorer"] do
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

      for name <- ["explorer"] do
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
    # says why beneath it: a program row whose driver cannot start its
    # harness read-only, an OpenAI Codex member's own row among
    # them. A file set to read-only by hand on such a brain shows it
    # chosen, with the same sentence, since its turns are refused. A brain
    # on a key, or a row CYFR keeps read-only, leaves the choice open.
    test "a member whose brain cannot be kept read-only has its read-only choice closed, " <>
           "with why beneath it",
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

      codex = program_row!(ctx, "openai-codex", "cyfr-codex npx -y @openai/codex@0.169.0")
      claude = program_row!(ctx, "claude", "cyfr-claude-code")
      :ok = member!(ctx, "openai-codex")

      members = [
        {"by-hand", "By Hand", %{"program" => codex.name}},
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
                "title" => title
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
            {"by-hand", "By Hand", "openai-codex", ["read-only"]},
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
      :ok = member!(ctx, "explorer")
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
      :ok = member!(ctx, "explorer")

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
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "explorer")
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(view, ~s(#aqua-card-aqua input[phx-value-key="files.delete"]))
      assert has_element?(view, "#aqua-card-explorer")
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

  # The terminal sessions opened in `home`'s folder so far, by their key,
  # each once.
  defp opened(home, keys \\ []) do
    receive do
      {:session, "open", %{"home_id" => ^home, "mode" => "terminal", "key" => key}, _fields} ->
        opened(home, keys ++ [key])
    after
      500 -> Enum.uniq(keys)
    end
  end

  # The terminal Set up showed: the Programs page it went to, which names
  # the session, with the way back here.
  defp set_up_terminal!(view) do
    {path, _flash} = assert_redirect(view, 5_000)
    assert URI.parse(path).path =~ ~r{/programs$}

    assert %{"terminal" => "trm_" <> _ = terminal, "from" => "aqua"} =
             URI.decode_query(URI.parse(path).query)

    terminal
  end

  # Each model the setup's picker offers under a program brain's title, as
  # its value and the words it shows.
  defp program_choices(view, title) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#aqua-setup-pick optgroup[label="#{title}"] option))
    |> Enum.map(fn option ->
      {option |> LazyHTML.attribute("value") |> List.first(),
       option |> LazyHTML.text() |> String.trim()}
    end)
  end

  # Each option `selector` finds, as its value and the words it shows.
  defp choices(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(fn option ->
      {option |> LazyHTML.attribute("value") |> List.first(),
       option |> LazyHTML.text() |> String.trim()}
    end)
  end

  # The brain `open`, which needs nothing of the person, granted, with the
  # one model the kept catalogue lists for it.
  defp open_brain!(ctx) do
    publish_brain!(ctx, "open", %{})
    grant!(ctx, "catalyst:local.open", %{bindings: []})
    remember_catalogue!(%{"open" => ["open-1"]}, %{"open" => "catalyst:local.open:0.1.0"})
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

  # The models a program lists unless a test names its own.
  @listing [
    %{"id" => "default", "name" => "Default (recommended)"},
    %{"id" => "opus", "name" => "Opus"},
    %{"id" => "haiku", "name" => "Haiku"}
  ]

  # Plays the driver of `row` for every listing a page asks of it, a new
  # driver process each, until `shown` holds: its hello, as the row's
  # driver, once the session stands, then the models `listing` names and
  # the efforts its program lists, or, for `{:refused, sentence}`, the
  # refusal a program with no sign-in answers.
  defp lists!(fake, row, shown, listing \\ @listing),
    do: lists!(fake, row, shown, listing, System.monotonic_time(:millisecond) + 10_000)

  defp lists!(fake, row, shown, listing, deadline) do
    home = row.id

    cond do
      shown.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the page did not show what its program's listing said")

      true ->
        receive do
          {:session, "open", %{"mode" => "run", "home_id" => ^home}, _fields} ->
            :ok

          {:session, "recv", %{"after" => 0}, _fields} ->
            say(fake, row, %{
              "t" => "hello",
              "v" => Opus.Brain.Wire.version(),
              "driver" => Arca.McpServerStorage.driver(row),
              "boot" => "b#{System.unique_integer([:positive])}"
            })

          {:session, "send", %{"lines" => [line]}, _fields} ->
            case Jason.decode!(line) do
              %{"t" => "models", "id" => id} ->
                say(fake, row, listed(id, listing))

              _another ->
                :ok
            end
        after
          100 -> :ok
        end

        lists!(fake, row, shown, listing, deadline)
    end
  end

  defp listed(id, {:refused, sentence}),
    do: %{"t" => "refused", "id" => id, "reason" => sentence}

  defp listed(id, models),
    do: %{"t" => "models", "id" => id, "models" => models, "efforts" => ["low", "high", "max"]}

  # The text of each element `selector` finds, trimmed.
  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
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

  # The kept driven row of the program brain `name`, its command as the
  # brain's definition holds it (`Opus.Programs.Definition.brains/0`).
  defp brain_row!(ctx, name),
    do: program_row!(ctx, name, Opus.Programs.Definition.brain(name).command)

  # The athanor's kept driven program row `name`, as an install confirmed
  # on the Programs page leaves it.
  defp program_row!(ctx, name, command) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        config_json: Jason.encode!(%{"command" => command, "env" => %{}})
      })

    row
  end

  # A person's grant of `ref`, walked as their own page walks it.
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
