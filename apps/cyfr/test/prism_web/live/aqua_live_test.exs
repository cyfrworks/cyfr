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

    # The group's header says what a turn would have: Aqua's browser is not
    # added, and where to add it.
    browser = "#aqua-group-family-browser"
    assert has_element?(view, browser <> " summary", "not added yet")

    assert has_element?(
             view,
             browser <> ~s( a[href*="programs?add=browser&"]),
             "Add it"
           )

    # Off, the group has none of its entries on; on again, all of them.
    view |> element(switch) |> render_click()
    assert {:ok, false} = Aqua.BrowserSetting.allowed?(ctx)
    assert has_element?(view, switch <> ~s([aria-checked="false"]), "Off")

    settled(
      fn -> Enum.all?(entries(view, browser), fn {_key, on} -> not on end) end,
      "none of the browser's entries on"
    )

    view |> element(switch) |> render_click()
    assert {:ok, true} = Aqua.BrowserSetting.allowed?(ctx)
    assert has_element?(view, switch <> ~s([aria-checked="true"]))
    settled(fn -> Enum.all?(entries(view, browser), &elem(&1, 1)) end, "all of them on")
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
  @setup_needs "Tick what you have: a key from a model provider, or Claude Code, " <>
                 "OpenAI Codex, Antigravity, OpenCode or Cursor on your own plan."

  # The setup read again, as the page reads it after a write of its own,
  # which asks no program.
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
    # turn is refused with (`Prima.Refusal`).
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
      Cyfr.Test.Sandbox.end_views()
    end

    # Sign in is the person's press, offered while the program is known
    # signed out, as its driver's account answer alone says: it opens the
    # member's editor and starts the program in its row's folder, at a
    # size the frame corrects when it attaches, its terminal shown on this
    # page. When that terminal ends the program is asked again, and an
    # answer that it is signed in ungreys the member.
    test "Sign in opens the editor and the terminal here, and asks again when the terminal ends",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "claude-code")
      row = brain_row!(ctx, "claude-code")
      home = row.id
      fake = backends!()
      card = "#aqua-card-claude-code"
      sign_in = card <> ~s( [data-test="sign-in"])
      failed = card <> ~s( [data-test="listing-failed"])

      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "claude-code")
      lists!(fake, row, fn -> has_element?(view, sign_in) end, {:signed_out, @signed_out})
      assert has_element?(view, failed, @signed_out)
      view |> element(card <> "-done") |> render_click()
      refute has_element?(view, card <> "-model")
      refute_received {:session, "open", %{"mode" => "terminal"}, _fields}

      view |> element(sign_in) |> render_click()

      assert_receive {:session, "open",
                      %{"home_id" => ^home, "argv" => [], "rows" => 24, "cols" => 80}, _fields},
                     5_000

      # Both stand on this page: the editor and the terminal, which is
      # first. Nothing is asked beside it.
      assert has_element?(view, card <> "-model")
      session = sign_in_terminal!(view, card)
      refute_received {:session, "open", %{"mode" => "run"}, _fields}
      assert has_element?(view, card <> ~s( [data-test="listing-held"]))
      refute has_element?(view, failed)

      assert view
             |> element("#terminal-#{session}-screen")
             |> render_hook("terminal_ready", %{"session" => session, "rows" => 30, "cols" => 100})

      assert has_element?(view, card <> ".opacity-60")
      Cyfr.Test.ScriptedBackends.end_sessions(fake, home)
      lists!(fake, row, fn -> has_element?(view, card, "Model connected") end)

      assert has_element?(view, card <> ~s( [data-test="terminal-ended"]))
      refute has_element?(view, card <> ".opacity-60")
      refute has_element?(view, sign_in)
      assert has_element?(view, card <> ~s(-model option[value="haiku"]))

      view |> element(card <> ~s( [data-test="terminal-dismiss"])) |> render_click()
      refute has_element?(view, card <> ~s( [data-test="terminal"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # The frame's Close ends the program, and that is the terminal's end
    # too: the program is asked again.
    test "closing the terminal Sign in showed asks the program again", %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      brain = "#aqua-setup-brain-claude-code"
      step = "#aqua-setup-step-program-claude-code"
      frame = ~s(#aqua-setup-step-brains [data-test="terminal"])

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      view |> element(brain <> " input") |> render_click()
      view |> element(step <> ~s( [data-test="sign-in"])) |> render_click()
      settled(fn -> has_element?(view, frame) end, "the setup's terminal")

      view |> element(frame <> ~s( [data-test="terminal-close"])) |> render_click()
      lists!(fake, row, fn -> has_element?(view, brain <> ~s([data-state="signed_in"])) end)

      assert has_element?(
               view,
               frame <> ~s( [data-test="terminal-ended"]),
               "The program was closed."
             )

      Cyfr.Test.Sandbox.end_views()
    end

    # Sign in shows the person's running terminal of the row when one runs,
    # whichever open started it (the install's is the same open of the
    # same person's), so the kept folder never runs a second of the program
    # from here; once that terminal has ended, Sign in opens one of its own.
    test "Sign in shows the program's running terminal, and opens one only when none runs",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "claude-code")
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      home = row.id
      card = "#aqua-card-claude-code"
      sign_in = card <> ~s( [data-test="sign-in"])
      failed = card <> ~s( [data-test="listing-failed"])
      signed_out = {:signed_out, @signed_out}

      held = card <> ~s( [data-test="listing-held"])

      # The terminal comes, and nothing is asked beside it.
      signed_in_again = fn view ->
        view |> element(sign_in) |> render_click()
        settled(fn -> has_element?(view, held) end, "the ask held")
        settled(fn -> has_element?(view, card <> ~s( [id$="-screen"])) end, "the terminal")
      end

      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "claude-code")
      lists!(fake, row, fn -> has_element?(view, sign_in) end, signed_out)
      signed_in_again.(view)
      first = sign_in_terminal!(view, card)

      # A terminal opens under its lifetime's key, which its id is a handle of.
      key_of = fn id ->
        [{pid, _person}] = Registry.lookup(Opus.Programs.Registry, {:terminal, id})
        :sys.get_state(pid).lifetime.key
      end

      assert opened(home) == [key_of.(first)]
      Cyfr.Test.Sandbox.end_views()

      # Sign in on a page opened again shows the same terminal and opens none.
      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, sign_in) end, "known signed out")
      signed_in_again.(view)
      assert sign_in_terminal!(view, card) == first
      assert opened(home) -- [first] == []

      Cyfr.Test.ScriptedBackends.end_sessions(fake, home)
      lists!(fake, row, fn -> has_element?(view, failed) and ended?(view, card) end, signed_out)

      Prima.Test.Wait.wait_until(
        fn -> Registry.lookup(Opus.Programs.Registry, {:terminal, first}) == [] end,
        5_000,
        "the first terminal to end"
      )

      signed_in_again.(view)

      settled(fn -> not ended?(view, card) end, "a terminal of its own")
      second = sign_in_terminal!(view, card)
      refute second == first
      assert key_of.(second) in opened(home)
      Cyfr.Test.Sandbox.end_views()
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
    # once the row stands as a brain's and an editor's ask read it signed
    # out, its sign-in; once an answer says it is signed in, it is
    # connected. Either way its models and efforts are the ones its program
    # lists, read from the row's driver when asked; before the row is there
    # the member's own model stands alone.
    test "a crew member on a program brain offers its install, then its sign-in, " <>
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

      assert has_element?(view, card, "It runs on a program you have not installed")

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

      refute has_element?(view, card <> ~s( [data-test="sign-in"]))
      refute has_element?(view, card <> ~s( [data-test="connect"]))
      refute has_element?(view, card <> " button[phx-click=open_consent]")
      assert texts(view, card <> "-runs dd") == ["Claude Code", "opus"]
      refute has_element?(view, "#aqua-card-coder-options")
      refute_received {:session, "open", _open, _fields}

      row = brain_row!(ctx, "claude-code")
      send_update_agents(view, load: true)
      reread_setup(view)
      refute has_element?(view, card <> ~s( a[data-test="install-program"]))

      # The row's driver refuses the listing, reading the account signed
      # out: the card offers its sign-in, the editor in the refusal's
      # words, and is not connected.
      edit!(view, "coder")

      lists!(
        fake,
        row,
        fn -> has_element?(view, card <> ~s( [data-test="sign-in"])) end,
        {:signed_out, @signed_out}
      )

      assert has_element?(view, card <> ~s( [data-test="sign-in"]), "Sign in")
      assert has_element?(view, card <> ~s( [data-test="listing-failed"]), @signed_out)
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

      view |> element(card <> ~s( [data-test="list-again"])) |> render_click()
      lists!(fake, row, fn -> model_choices(view, "coder") == listed end)
      assert has_element?(view, card, "Model connected")
      refute has_element?(view, card <> ~s( [data-test="sign-in"]))

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
        refute has_element?(view, card <> ~s( [data-test="sign-in"]))
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

    test "a crew member made here is offered the soul's tools and holds none of its own",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"tools" => soul_tools}} = get_agent(ctx, "aqua")
      assert soul_tools != []
      :ok = open_brain!(ctx)

      {view, _html} = mount_athanor(conn, "/aqua")
      assert make!(view, "#aqua-new-member", "scout", "catalyst:open", "open-1") =~ "Made scout."

      assert {:ok, %{"type" => "crew", "tools" => ^soul_tools}} = get_agent(ctx, "scout")

      assert {:ok, %{"tools" => ^soul_tools}} = get_agent(ctx, "aqua")

      {:ok, bytes} =
        Arca.get(Sanctum.Context.actor(ctx), Compendium.AquaPath.crew_file("scout"))

      refute bytes =~ "tools:"
      # Nor a prompt: its file is its frontmatter alone, its title and what
      # it runs on.
      assert bytes ==
               "---\ntitle: scout\ncatalyst_ref: catalyst:local.open\nmodel: open-1\n---\n"

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
               "Offered Aqua's tools on every job."
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

    # A scroll replaced through Files past the bound stays the athanor's,
    # and the page says on it why Aqua does not use it.
    test "a scroll replaced through Files past the bound says why on the page",
         %{conn: conn, ctx: ctx} do
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "skill_create",
          "name" => "too-big",
          "description" => "d",
          "content" => "short"
        })

      {:ok, _written} =
        Arca.Files.write(
          Sanctum.Context.actor(ctx),
          Enum.join(Compendium.AquaPath.skill_manifest("too-big"), "/"),
          ~s(---\nname: "too-big"\ndescription: "d"\n---\n\n) <> String.duplicate("a", 131_072)
        )

      {view, _html} = mount_athanor(conn, "/aqua")

      assert view |> element("#aqua-scroll-too-large-too-big") |> render() =~
               "Aqua does not use this scroll"
    end

    # A scroll whose name holds what CYFR marks its frames with is handed to
    # no harness, since handing would rename it, and the page says why on it.
    test "a scroll named with a frame's mark says why on the page, and no index lists it",
         %{conn: conn, ctx: ctx} do
      name = "s" <> Aqua.Reader.mark("thr_any")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "skill_create",
          "name" => name,
          "description" => "d",
          "content" => "short"
        })

      {view, _html} = mount_athanor(conn, "/aqua")

      assert view |> element("#aqua-scroll-misnamed-" <> name) |> render() =~
               "its name holds what CYFR marks its own frames with"

      refute has_element?(view, "#aqua-scroll-too-large-" <> name)
      {:ok, %{entries: entries}} = Compendium.skills_index(ctx, Compendium.skills_index_limit())
      refute Enum.any?(entries, &(&1.name == name))
      refute Compendium.AquaPath.handed_name?(Aqua.Reader.token())
      assert Compendium.AquaPath.handed_name?("research")
    end

    test "the Scrolls group opens while a scroll is written, and one is written, edited and " <>
           "deleted here",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"skills" => [shipped | _]}} =
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "skill_list"})

      # The server ships a scroll, listed in the Scrolls group, which opens
      # on the person's press like every group of what Aqua may use.
      {view, html} = mount_athanor(conn, "/aqua")
      refute has_element?(view, "#aqua-scrolls[open]")
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
      assert has_element?(view, "#aqua-scrolls[open]")

      view
      |> form("#aqua-scroll-editor", %{
        "name" => "pdf-forms",
        "description" => "Fill PDF forms",
        "content" => "# PDF forms\nUse pdftk."
      })
      |> render_submit()

      # The list is read again on the page's own message after the write.
      settled(
        fn -> has_element?(view, "#aqua-scrolls-section button[phx-value-name=pdf-forms]") end,
        "the new scroll listed"
      )

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
            "own file is missing",
            "Nothing pinned yet.",
            "Nothing kept yet.",
            "No scrolls here.",
            "Shipped files",
            "New crew member",
            "to make a crew member"
          ] do
        refute html =~ line, "the dead render says #{inspect(line)}"
      end

      # Loaded, the sections are there, and where a member is made with
      # them: with no harness or key connected, the line that says to
      # connect one, in place of a form that could make nothing.
      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "Shipped files"
      assert has_element?(view, "#aqua-about")
      assert has_element?(view, "#aqua-notes")
      assert has_element?(view, "#aqua-scrolls")
      refute has_element?(view, "#aqua-new-member")

      assert has_element?(
               view,
               ~s([data-test="new-member-waits"]),
               "Connect a program or a key in the setup above to make a crew member."
             )
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

      refute render(view) =~ "own file is missing"
      refute has_element?(view, ~s(#aqua-new-member, [data-test="new-member-waits"]))
      refute has_element?(view, "button[phx-click=install_catalyst]")
      refute has_element?(view, "button[phx-click=open_consent]")
    end

    test "a store that answers with no agents still says Aqua's own file is missing", %{
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

      assert render(view) =~ "own file is missing"
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

    test "the card of a crew member with no harness or key offers the choice in its field",
         %{conn: conn, ctx: ctx} do
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "proofreader",
          "title" => "proofreader"
        })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      settled(fn -> has_element?(view, "#aqua-card-proofreader") end, "the new card")
      assert texts(view, "#aqua-card-proofreader-runs dd") == ["none chosen yet"]
      edit!(view, "proofreader")

      assert choices(view, "#aqua-card-proofreader-harness option[selected]") == [
               {"", "Choose a program or key"}
             ]

      refute has_element?(view, ~s(#aqua-card-proofreader a[data-test="connect"]))
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

      # A connected brain is a member's: the crew's step waits on none, and
      # Aqua's waits for a member to run on. (The form offers a key once
      # its provider lists models, which this one's does not.)
      refute has_element?(view, ~s([data-test="setup-crew-waits"]))
      assert has_element?(view, ~s([data-test="setup-aqua-waits"]), "Make a crew member first.")
      refute has_element?(view, "#aqua-setup-member")

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

      assert has_element?(
               view,
               ~s(#aqua-setup-step-brains[data-done="false"]),
               "1. Programs and keys"
             )

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
               "Connect a program or key first."
             )

      refute has_element?(view, "#aqua-setup-new-member")
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
    # member can be made on it; once the listing answers it is signed in,
    # and the crew's step offers it among the harnesses, with the models
    # its program lists once it is chosen. Make with a name and a model
    # writes that member on the program and asks nothing; with either
    # missing it writes nothing. Chosen for
    # Aqua, the member asks nothing and Aqua's grant stays as it was, and
    # Aqua answers on the program. Without Aqua's grant (the person revoked
    # it), choosing grants nothing either: the step for Aqua is not done
    # and offers the grant, which opens Aqua's own confirmation; granted
    # there, the step is done and Aqua answers.
    for grant <- [:standing, :revoked] do
      @tag grant: grant
      test "a program brain signs in on the setup, Make writes the member the person names, " <>
             "and Aqua answers on it, Aqua's grant #{grant}",
           %{conn: conn, ctx: ctx, grant: grant} do
        on_exit(fn ->
          Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
        end)

        # Aqua's grant, as the fill mints it over a seed whose hands Aqua's
        # tools need are installed; the seed's own member stands on a brain
        # not installed here.
        Cyfr.Test.SeedBundle.lay!(~w(files http))
        :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)

        :ok =
          Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())

        {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
        {:ok, _} = Compendium.AgentIndex.sync(ctx)
        {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

        if grant == :revoked do
          {:ok, %{revoked: [_ | _]}} =
            Sanctum.Consent.revoke_source(ctx, Prima.AgentRef.soul_ref())
        end

        fake = backends!()
        %{name: name, title: title} = Opus.Programs.Definition.brain("claude-code")
        row = brain_row!(ctx, name)
        brain = "#aqua-setup-brain-" <> name
        step = "#aqua-setup-step-program-" <> name
        new = "#aqua-setup-new-member"
        harness = "program:" <> name
        member = "Opus"

        {view, _html} = mount_athanor(conn, "/aqua?setup=1")
        view |> element(brain <> " input") |> render_click()

        # Nothing known, it is installed and offered, and ticked still
        # offers its sign-in. No model is offered before it is chosen.
        assert has_element?(view, brain <> ~s([data-state="installed"]), "installed")
        assert has_element?(view, step, "#{title}: sign it in on its terminal.")
        assert has_element?(view, step <> ~s( button[data-test="sign-in"]), "Sign in")
        offered = ~s( select[name="brain"] optgroup[label="Programs"] option)
        new_member!(view, new)
        assert choices(view, new <> offered) == [{harness, title}]
        refute has_element?(view, new <> ~s( select[name="model"]))

        # Chosen, it is asked, and its driver reads it signed out.
        view |> form(new, %{"name" => member, "brain" => harness}) |> render_change()

        lists!(
          fake,
          row,
          fn -> has_element?(view, brain <> ~s([data-state="signed_out"])) end,
          {:signed_out, @signed_out}
        )

        assert has_element?(view, brain <> ~s( [data-test="setup-signed-out"]), "signed out")
        assert has_element?(view, new <> ~s( [data-test="listing-failed"]), @signed_out)
        refute has_element?(view, new <> offered)
        refute has_element?(view, new <> ~s( select[name="model"]))

        assert has_element?(
                 view,
                 ~s([data-test="setup-crew-waits"]),
                 "Connect a program or key first."
               )

        # Signed in, as the account member says: the form offers it, by its
        # title; the form below the setup is the same one.
        view |> element(new <> ~s( [data-test="list-again"])) |> render_click()
        lists!(fake, row, fn -> has_element?(view, new <> offered) end)
        assert choices(view, new <> offered) == [{harness, title}]
        assert choices(view, "#aqua-new-member" <> offered) == [{harness, title}]
        assert has_element?(view, brain <> ~s([data-state="signed_in"]), "signed in")
        assert has_element?(view, ~s(#aqua-setup-step-brains[data-done="true"]))
        refute has_element?(view, step)
        refute has_element?(view, ~s([data-test="setup-crew-waits"]))

        assert choices(view, new <> ~s( select[name="model"] option)) == [
                 {"", "Choose a model"},
                 {"default", "Default (recommended)"},
                 {"opus", "Opus"},
                 {"haiku", "Haiku"}
               ]

        assert has_element?(view, new <> ~s( button[type="submit"]), "Make crew member")
        # What the form holds, the form below the setup holds too.
        assert has_element?(view, ~s(#aqua-new-member input[name="name"][value="#{member}"]))

        # No name, no harness or no model, no member.
        for {sent, said} <- [
              {%{"name" => " ", "model" => "opus"}, "Give the crew member a name first."},
              {%{"brain" => "", "model" => "opus"}, "Choose a program or key first."},
              {%{"model" => ""}, "Choose a model first."}
            ] do
          assert view
                 |> with_target("#aqua-agents")
                 |> render_submit(
                   "make_member",
                   Map.merge(%{"name" => member, "brain" => harness}, sent)
                 ) =~ said
        end

        assert {:error, _} = get_agent(ctx, member)

        # A member is its harness, its model, its effort and its access: the
        # form offers the efforts of the model picked and the access choices its
        # driver lists, in the driver's words, closed while it offers one and
        # carried as a hidden value; what it is good at and should avoid are
        # the person's to write, or to leave empty.
        view
        |> form(new, %{"name" => member, "brain" => harness, "model" => "opus"})
        |> render_change()

        assert texts(view, new <> ~s( select[name="options[effort]"] option)) ==
                 ["default", "low", "high", "max"]

        assert choices(view, new <> ~s( select[name="options[access]"][disabled] option)) == [
                 {"default", "Default mode"}
               ]

        assert has_element?(
                 view,
                 new <> ~s( input[type="hidden"][name="options[access]"][value="default"])
               )

        # An access the driver does not list writes nothing, and the form
        # shows the driver's own choices again.
        assert view
               |> form(new)
               |> render_submit(%{"model" => "opus", "options" => %{"access" => "plan"}}) =~
                 "That program or key does not offer what was chosen — choose again."

        assert {:error, _} = get_agent(ctx, member)

        assert has_element?(
                 view,
                 new <> ~s| input[name="description"][placeholder="Good at (optional)"]|
               )

        assert has_element?(
                 view,
                 new <> ~s| input[name="avoid"][placeholder="Avoid (optional)"]|
               )

        view
        |> form(new, %{
          "model" => "opus",
          "options" => %{"effort" => "high"},
          "description" => " Builds things "
        })
        |> render_submit()

        # The member is the person's name for it, never the harness's.
        assert {:ok,
                %{
                  "title" => ^member,
                  "program" => ^name,
                  "catalyst_ref" => nil,
                  "model" => "opus",
                  "description" => "Builds things",
                  "avoid" => "",
                  "options" => %{"effort" => "high", "access" => "default"}
                }} = get_agent(ctx, member)

        assert {:error, _} = get_agent(ctx, name)
        assert render(view) =~ "Made #{member}."
        settled(fn -> has_element?(view, "#aqua-setup-made-" <> member, "ready.") end, "ready")

        # Made, the form holds nothing, and its card names its harness.
        refute has_element?(view, new <> ~s( input[name="name"][value]))

        assert texts(view, "#aqua-card-#{member}-runs dd") ==
                 [title, "Opus", "Default mode", "high"]

        # Aqua's Runs on names the member with its harness and its model,
        # the model by the name the listing gives it ("Opus" for the id
        # "opus"), here and on Aqua's card.
        for runs_on <- ["#aqua-setup-member", "#aqua-card-aqua-member"] do
          assert {member, "#{member} — #{title}, Opus"} in choices(view, runs_on <> " option")
        end

        refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

        # Chosen for Aqua: nothing is asked, and Aqua's grant is what it was.
        actor = Sanctum.Context.actor(ctx)
        granted = aqua_grant!(actor)
        # Revoked, Aqua holds no grant at all; standing, the one the fill made.
        assert granted == [] == (grant == :revoked)
        view |> form("#aqua-setup-member", %{"member" => member}) |> render_change()

        if grant == :revoked do
          line = ~s([data-test="setup-aqua-grant"])
          settled(fn -> has_element?(view, line) end, "Aqua's grant asked")
          assert has_element?(view, ~s(#aqua-setup-step-aqua[data-done="false"]))
          refute has_element?(view, ~s([data-test="setup-aqua-done"]))

          assert has_element?(
                   view,
                   line,
                   "You have not granted yet what Aqua and its crew members may use."
                 )

          refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
          assert aqua_grant!(actor) == granted
          view |> element(line <> " button", "Grant") |> render_click()
          assert has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
          view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()
        end

        settled(
          fn ->
            has_element?(view, ~s([data-test="setup-aqua-done"]), "Aqua runs on #{member}.")
          end,
          "Aqua seated"
        )

        assert has_element?(view, ~s(#aqua-setup-step-aqua[data-done="true"]))
        refute has_element?(view, ~s([data-test="setup-aqua-grant"]))
        refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))
        if grant == :standing, do: assert(aqua_grant!(actor) == granted)

        # Aqua answers, its turn on the program the member names.
        person = %{ctx | origin: :interactive}
        {:ok, thread} = Arca.Test.Days.thread(actor)

        assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
                 Aqua.Runner.send_message(person, thread.id, "@aqua hello")

        answers!(fake, row, "Hello from Claude Code.", fn ->
          match?({:ok, %{status: "completed"}}, Aqua.Tape.turn(ctx, turn_id))
        end)

        assert ["Hello from Claude Code."] =
                 for(
                   %{turn_id: ^turn_id, author: "aqua", kind: "text", content: said} <-
                     Arca.ThreadStorage.messages(actor, thread.id),
                   do: said
                 )

        Cyfr.Test.Sandbox.end_views()
      end
    end

    # As many members run on one harness or key as the person makes, each
    # under the name they gave it; CYFR names none after what it runs on.
    test "two members made on one key run on it under the names the person gave them",
         %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      for {form, name} <- [{"#aqua-setup-new-member", "Opus"}, {"#aqua-new-member", "Sonnet"}] do
        assert make!(view, form, name, "catalyst:open", "open-1") =~ "Made #{name}."

        assert {:ok, %{"title" => ^name, "catalyst_ref" => "catalyst:local.open"}} =
                 get_agent(ctx, name)
      end

      assert {:error, _} = get_agent(ctx, "open")

      # The form is still there for a third, and a name a member holds is
      # refused as a member that exists.
      assert make!(view, "#aqua-new-member", "Opus", "catalyst:open", "open-1") =~
               "Make failed: Crew member &#39;Opus&#39; already exists"

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      assert has_element?(view, "#aqua-setup-made-Opus")
      assert has_element?(view, "#aqua-setup-made-Sonnet")
      assert has_element?(view, "#aqua-card-Opus") and has_element?(view, "#aqua-card-Sonnet")
      Cyfr.Test.Sandbox.end_views()
    end

    # A key's options are what its `describe` declares for the model
    # picked in the form, read as a card reads a brain's options: none
    # before a model is picked, none for a model that declares none, every
    # one it declares for one that does, and Make writes each one chosen,
    # cast to its kind, as it does for a program.
    test "the form offers every option a key declares for the model picked, and Make writes " <>
           "the ones chosen",
         %{conn: conn, ctx: ctx} do
      described_open!(ctx, %{
        "open-1" => [
          %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]},
          %{"name" => "budget", "kind" => "integer", "default" => 4}
        ],
        "open-2" => []
      })

      new = "#aqua-setup-new-member"
      effort = new <> ~s( select[name="options[effort]"])
      budget = new <> ~s( input[name="options[budget]"][type="number"])
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      choose!(view, new, "Opus", "catalyst:open")
      refute has_element?(view, effort)
      # A key has no access to choose.
      refute has_element?(view, new <> ~s( [name="options[access]"]))

      pick = %{"name" => "Opus", "brain" => "catalyst:open"}
      view |> form(new, Map.put(pick, "model", "open-1")) |> render_change()
      settled(fn -> has_element?(view, effort) end, "the model's options")
      assert texts(view, effort <> " option") == ["default", "low", "high"]
      assert has_element?(view, budget <> ~s|[placeholder="default (4)"]|)
      assert has_element?(view, new <> ~s( option[value="open-1"][selected]))

      view |> form(new, Map.put(pick, "model", "open-2")) |> render_change()
      settled(fn -> not has_element?(view, effort) end, "no options for open-2")
      refute has_element?(view, budget)

      view |> form(new, Map.put(pick, "model", "open-1")) |> render_change()
      settled(fn -> has_element?(view, effort) end, "open-1's options again")

      view
      |> form(new, Map.merge(pick, %{"options" => %{"effort" => "high", "budget" => "9"}}))
      |> render_submit()

      assert {:ok,
              %{
                "catalyst_ref" => "catalyst:local.open",
                "model" => "open-1",
                "options" => %{"effort" => "high", "budget" => 9}
              }} = get_agent(ctx, "Opus")

      Cyfr.Test.Sandbox.end_views()
    end

    # As a browser drives the form: each field's change is sent with the
    # form as it stands, and Make sends the form with nothing added. What
    # the form holds survives each render (a field the page did not show
    # again would be sent empty), so the member made is what was chosen.
    test "the form driven as a browser does, a change for each field and then Make, makes the " <>
           "member chosen",
         %{conn: conn, ctx: ctx} do
      described_open!(ctx, %{
        "open-1" => [],
        "open-2" => [
          %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]},
          %{"name" => "budget", "kind" => "integer"}
        ]
      })

      new = "#aqua-setup-new-member"
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      new_member!(view, new)

      settled(
        fn -> has_element?(view, new <> ~s( option[value="catalyst:open"])) end,
        "the key offered"
      )

      change = fn field -> view |> form(new, field) |> render_change() end
      change.(%{"name" => "Sonnet"})
      change.(%{"description" => "Quick edits"})
      change.(%{"brain" => "catalyst:open"})
      change.(%{"model" => "open-2"})
      settled(fn -> has_element?(view, new <> ~s( [name="options[effort]"])) end, "the options")
      change.(%{"options" => %{"effort" => "low"}})
      change.(%{"options" => %{"budget" => "7"}})
      change.(%{"avoid" => "Long jobs"})

      # Both showings of the form hold what was entered.
      for form <- [new, "#aqua-new-member"] do
        assert has_element?(view, form <> ~s( input[name="name"][value="Sonnet"]))
        assert has_element?(view, form <> ~s( option[value="catalyst:open"][selected]))
        assert has_element?(view, form <> ~s( option[value="open-2"][selected]))

        assert has_element?(
                 view,
                 form <> ~s( [name="options[effort]"] option[value="low"][selected])
               )

        assert has_element?(view, form <> ~s( input[name="options[budget]"][value="7"]))
        assert has_element?(view, form <> ~s( input[name="description"][value="Quick edits"]))
      end

      assert view |> form(new) |> render_submit() =~ "Made Sonnet."

      assert {:ok,
              %{
                "title" => "Sonnet",
                "catalyst_ref" => "catalyst:local.open",
                "model" => "open-2",
                "description" => "Quick edits",
                "avoid" => "Long jobs",
                "options" => %{"effort" => "low", "budget" => 7}
              }} = get_agent(ctx, "Sonnet")

      # Another harness or key lists other models and options: choosing one
      # drops the model and the options chosen on the last.
      change.(%{"name" => "Haiku"})
      change.(%{"brain" => "catalyst:open"})
      change.(%{"model" => "open-2"})
      settled(fn -> has_element?(view, new <> ~s( [name="options[effort]"])) end, "the options")
      change.(%{"options" => %{"effort" => "high"}})
      change.(%{"brain" => ""})
      refute has_element?(view, new <> ~s( select[name="model"]))
      change.(%{"brain" => "catalyst:open"})
      refute has_element?(view, new <> ~s( option[value="open-2"][selected]))
      refute has_element?(view, new <> ~s( [name="options[effort]"]))
      assert has_element?(view, new <> ~s( input[name="name"][value="Haiku"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # Make writes an option only if the model it names offers it: one left
    # from the model picked before, sent with another that offers none
    # (or whose options have not answered yet), writes nothing, says to
    # choose again, and the form then shows that model's own choices.
    test "Make refuses an effort the model it names does not offer, and writes the member " <>
           "once chosen again",
         %{conn: conn, ctx: ctx} do
      described_open!(ctx, %{
        "open-1" => [%{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]}],
        "open-2" => []
      })

      new = "#aqua-setup-new-member"
      effort = new <> ~s( select[name="options[effort]"])
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      choose!(view, new, "Opus", "catalyst:open")
      pick = %{"name" => "Opus", "brain" => "catalyst:open"}

      view |> form(new, Map.put(pick, "model", "open-1")) |> render_change()
      settled(fn -> has_element?(view, effort) end, "open-1's efforts")

      # Switched to open-2 as Make is pressed, open-1's effort still chosen.
      html =
        view
        |> with_target("#aqua-agents")
        |> render_submit(
          "make_member",
          Map.merge(pick, %{"model" => "open-2", "options" => %{"effort" => "high"}})
        )

      assert html =~ "That program or key does not offer what was chosen — choose again."
      refute html =~ "Made "
      assert {:error, _} = get_agent(ctx, "Opus")
      assert has_element?(view, new <> ~s( option[value="open-2"][selected]))
      assert has_element?(view, new <> ~s( input[name="name"][value="Opus"]))
      settled(fn -> not has_element?(view, effort) end, "open-2's own choices")

      view |> form(new, Map.put(pick, "model", "open-2")) |> render_submit()

      assert {:ok,
              %{
                "catalyst_ref" => "catalyst:local.open",
                "model" => "open-2",
                "options" => options
              }} =
               get_agent(ctx, "Opus")

      assert options == %{}
      Cyfr.Test.Sandbox.end_views()
    end

    # A member's editor names the program or key it runs on as a field of
    # its own. Another chosen there is asked for its list and writes
    # nothing; the model picked of it moves the member in one write, and
    # an option that model does not list is taken off in the same write.
    test "a card names the member's harness or key and moves it to another, whose models and " <>
           "options it then offers",
         %{conn: conn, ctx: ctx, athanor: athanor} do
      Cyfr.Test.SeedBundle.lay!(~w(files http))
      :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
      {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

      described_open!(ctx, %{
        "open-1" => [
          %{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]},
          %{"name" => "budget", "kind" => "integer"}
        ],
        "open-2" => []
      })

      fake = backends!()
      %{name: program, title: title} = Opus.Programs.Definition.brain("claude-code")
      row = brain_row!(ctx, program)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "Opus",
          "title" => "Opus",
          "catalyst_ref" => "catalyst:local.open",
          "model" => "open-1",
          "options" => %{"effort" => "high", "budget" => 9}
        })

      field = "#aqua-card-Opus-harness"
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      edit!(view, "Opus")

      settled(
        fn -> has_element?(view, field <> ~s( option[value="program:#{program}"])) end,
        "the program offered"
      )

      assert has_element?(view, field, "Program or key")

      assert choices(view, field <> " option") == [
               {"program:" <> program, title},
               {"catalyst:open", "open"}
             ]

      assert choices(view, field <> " option[selected]") == [{"catalyst:open", "open"}]

      assert model_choices(view, "Opus") == [
               {"open::open-1", "open-1"},
               {"open::open-2", "open-2"}
             ]

      # The program chosen is asked, and nothing is written.
      unmoved = get_agent(ctx, "Opus")
      view |> form(field, %{"harness" => "program:" <> program}) |> render_change()
      assert get_agent(ctx, "Opus") == unmoved

      lists!(fake, row, fn ->
        has_element?(view, ~s(#aqua-card-Opus-model option[value="opus"]))
      end)

      assert model_choices(view, "Opus") == [
               {"-", "Choose a model"},
               {"", "The program's default"},
               {"default", "Default (recommended)"},
               {"opus", "Opus"},
               {"haiku", "Haiku"}
             ]

      assert has_element?(view, field <> ~s( option[value="program:#{program}"][selected]))

      # Its model picked: moved, the effort that model takes too is kept,
      # and the option it does not list is taken off.
      model!(view, "Opus", "opus")

      assert {:ok,
              %{
                "program" => ^program,
                "catalyst_ref" => nil,
                "model" => "opus",
                "options" => %{"effort" => "high"} = options
              }} = get_agent(ctx, "Opus")

      assert options == %{"effort" => "high"}

      settled(
        fn -> has_element?(view, ~s(#aqua-card-Opus-access [data-test="access"])) end,
        "the card on the program"
      )

      assert model_choices(view, "Opus") == [
               {"", "The program's default"},
               {"default", "Default (recommended)"},
               {"opus", "Opus"},
               {"haiku", "Haiku"}
             ]

      assert texts(view, "#aqua-card-Opus-option-effort option") ==
               ["default", "low", "high", "max"]

      # Back to the key: nothing is written until its model is picked.
      moved = get_agent(ctx, "Opus")
      view |> form(field, %{"harness" => "catalyst:open"}) |> render_change()
      assert get_agent(ctx, "Opus") == moved
      assert has_element?(view, field <> ~s( option[value="catalyst:open"][selected]))

      assert model_choices(view, "Opus") == [
               {"-", "Choose a model"},
               {"open::open-1", "open-1"},
               {"open::open-2", "open-2"}
             ]

      refute has_element?(view, "#aqua-card-Opus-access")
      model!(view, "Opus", "open::open-1")

      assert {:ok,
              %{
                "program" => nil,
                "catalyst_ref" => "catalyst:local.open",
                "model" => "open-1",
                "options" => options
              }} = get_agent(ctx, "Opus")

      assert options == %{"effort" => "high"}

      # A member whose file holds no model.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "Opus", "model" => nil})

      send(view.pid, {:refresh, :agents})

      settled(
        fn -> has_element?(view, ~s(#aqua-card-Opus [data-test="needs-model"])) end,
        "no model"
      )

      # A key has no default model: with none chosen the member is not
      # ready, its card says a model is to be chosen, the setup's list
      # says it is not ready, and Aqua's Runs on names it so.
      unchosen = Prima.Refusal.message({:crew_unready, "Opus", :no_model})
      assert unchosen == "Opus has no model chosen yet — choose one on its card on the Aqua page"
      assert has_element?(view, ~s(#aqua-card-Opus [data-test="needs-model"]), unchosen)
      refute has_element?(view, "#aqua-card-Opus", "Model connected")
      assert has_element?(view, "#aqua-setup-made-Opus", "not ready yet")

      assert {"Opus", "Opus — open, no model chosen yet"} in choices(
               view,
               "#aqua-card-aqua-member option"
             )

      # Aqua on that member has no model to answer with, and its thread
      # says so, with the way to the Aqua page.
      on_exit(fn ->
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
      end)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => "Opus"})

      {:ok, pane, _html} =
        live_isolated(conn, PrismWeb.ThreadPaneLive, session: %{"athanor_id" => athanor.id})

      settled(
        fn ->
          has_element?(pane, ~s(a[data-test="model-connect"]), "Connect one on your Aqua page.")
        end,
        "the pane's line"
      )

      # A model chosen, it is ready.
      view
      |> element("#aqua-card-Opus-model")
      |> render_change(%{"name" => "Opus", "value" => "open::open-2"})

      # open-2 takes no effort.
      assert {:ok, %{"model" => "open-2", "options" => left}} = get_agent(ctx, "Opus")
      assert left == %{}

      settled(fn -> has_element?(view, "#aqua-setup-made-Opus", "ready.") end, "ready again")
      refute has_element?(view, ~s(#aqua-card-Opus [data-test="needs-model"]))
      assert has_element?(view, "#aqua-card-Opus", "Model connected")

      assert {"Opus", "Opus — open, open-2"} in choices(view, "#aqua-card-aqua-member option")

      # One not connected here writes nothing.
      before = get_agent(ctx, "Opus")

      assert view
             |> with_target("#aqua-agents")
             |> render_change("editor_set_harness", %{
               "name" => "Opus",
               "harness" => "program:openai-codex"
             }) =~ "That program or key is not connected here."

      assert get_agent(ctx, "Opus") == before
      Cyfr.Test.Sandbox.end_views()
    end

    # The model catalogue is kept a minute, so a key it still lists may
    # no longer be connected: the form offers only a key the setup reads
    # as connected, and Make reads that again, so a page that still shows
    # the key makes nothing and says why.
    test "Make on a key no longer connected makes nothing", %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      form = "#aqua-setup-new-member"
      on_exit(fn -> Cyfr.Test.AquaTool.call(ctx, %{"action" => "delete", "name" => "Late"}) end)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      choose!(view, form, "Late", "catalyst:open")
      {:ok, %{revoked: [_ | _]}} = Sanctum.Consent.revoke_source(ctx, "catalyst:local.open")

      assert view
             |> form(form, %{"name" => "Late", "brain" => "catalyst:open", "model" => "open-1"})
             |> render_submit() =~ "That program or key is not connected here."

      assert {:error, _} = get_agent(ctx, "Late")

      # The refusal reads the setup again, and the key is offered no more.
      settled(
        fn -> not has_element?(view, ~s(option[value="catalyst:open"])) end,
        "the key withdrawn"
      )

      # A page opened now, the catalogue still listing the key's models,
      # does not offer it.
      {fresh, _html} = mount_athanor(conn, "/aqua?setup=1")
      settled(fn -> has_element?(fresh, "#aqua-setup-brain-open") end, "the setup read")
      assert {%{"open" => ["open-1"]}, _refs} = picker(fresh)
      refute has_element?(fresh, ~s(option[value="catalyst:open"]))
      refute has_element?(fresh, form)
      Cyfr.Test.Sandbox.end_views()
    end

    test "a card moves no member to a key no longer connected", %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      field = "#aqua-card-Mover-harness"

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "Mover",
          "title" => "Mover",
          "catalyst_ref" => "catalyst:moonmoon69.claude"
        })

      on_exit(fn -> Cyfr.Test.AquaTool.call(ctx, %{"action" => "delete", "name" => "Mover"}) end)
      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "Mover")

      settled(
        fn -> has_element?(view, field <> ~s( option[value="catalyst:open"])) end,
        "the card offers the key"
      )

      {:ok, %{revoked: [_ | _]}} = Sanctum.Consent.revoke_source(ctx, "catalyst:local.open")
      before = get_agent(ctx, "Mover")

      assert view |> form(field, %{"harness" => "catalyst:open"}) |> render_change() =~
               "That program or key is not connected here."

      assert get_agent(ctx, "Mover") == before

      settled(
        fn -> not has_element?(view, field <> ~s( option[value="catalyst:open"])) end,
        "the key withdrawn"
      )

      {fresh, _html} = mount_athanor(conn, "/aqua")
      edit!(fresh, "Mover")
      settled(fn -> has_element?(fresh, field) end, "the card read")
      assert {%{"open" => ["open-1"]}, _refs} = picker(fresh)
      refute has_element?(fresh, ~s(option[value="catalyst:open"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # A person reads Aqua, crew member, harness, key and scroll: nothing
    # the Aqua page shows them, in its text or in a hint, a placeholder or
    # a confirmation, says "soul".
    test "nothing a person reads on the Aqua page says soul", %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      :ok = member!(ctx, "explorer")
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      settled(
        fn ->
          has_element?(view, "#aqua-card-explorer") and has_element?(view, "#aqua-restore")
        end,
        "the page read"
      )

      page = view |> render() |> LazyHTML.from_fragment()

      hints =
        for attribute <- ~w(title placeholder aria-label data-confirm alt),
            said <- LazyHTML.attribute(LazyHTML.query(page, "[#{attribute}]"), attribute),
            do: said

      read = [LazyHTML.text(page) | hints]

      assert read |> Enum.join("\n") |> String.contains?("Aqua")
      assert Enum.filter(read, &(&1 =~ ~r/soul/i)) == []
      Cyfr.Test.Sandbox.end_views()
    end

    # What the setup makes, the person made: the member is the athanor's
    # own, and a restore of the shipped files keeps it as it is.
    test "a member made from the setup is the athanor's own, and a restore keeps its file",
         %{conn: conn, ctx: ctx} do
      :ok = open_brain!(ctx)
      actor = Sanctum.Context.actor(ctx)
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      make!(view, "#aqua-setup-new-member", "Opus", "catalyst:open", "open-1")
      settled(fn -> has_element?(view, "#aqua-card-Opus", "yours") end, "the made member's card")
      refute has_element?(view, "#aqua-card-Opus", "shipped")
      {:ok, bytes} = Arca.get(actor, Compendium.AquaPath.crew_file("Opus"))

      view |> element("#aqua-restore button[phx-click=restore_shipped]") |> render_click()
      assert has_element?(view, "#aqua-restore-result", "Kept (1)")
      assert render(view) =~ "aqua/crew/Opus.md"
      assert {:ok, ^bytes} = Arca.get(actor, Compendium.AquaPath.crew_file("Opus"))
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
    # member's card offers it as a harness and then the models its
    # program lists. Choosing it makes that crew member name the program
    # and no catalyst, and asks nothing, since a member holds no consent
    # of its own. Its access saved, a move to a key takes the program
    # away again, and the access with it in the same write, so the member
    # answers on the key's brain once a model of the key's is chosen.
    for %{name: name, title: title, command: command} <- Opus.Programs.Definition.brains() do
      @tag brain: {name, title, command}
      test "the setup offers #{name} as a program brain, installs it, signs it in and makes it " <>
             "a crew member's harness; a move to a key takes it back",
           %{conn: conn, ctx: ctx, brain: {name, title, command}} do
        fake = backends!()
        publish_brain!(ctx, "open", %{})
        grant!(ctx, "catalyst:local.open", %{bindings: []})
        remember_catalogue!(%{"open" => ["open-1"]}, %{"open" => "catalyst:local.open:0.1.0"})
        {:ok, _} = Cyfr.Test.AquaTool.call(ctx, %{"action" => "create", "name" => "mine"})
        {:ok, before} = get_agent(ctx, "mine")
        assert before["program"] == nil

        {view, _html} = mount_athanor(conn, "/aqua?setup=1")
        brain = "#aqua-setup-brain-" <> name
        offered = ~s(#aqua-card-mine-harness optgroup option[value="program:#{name}"])
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

        # Its row stands: installed, and offered. Chosen on a card it is
        # asked, and has no sign-in yet.
        row = program_row!(ctx, name, command)
        reread_setup(view)
        settled(fn -> has_element?(view, brain <> ~s([data-state="installed"])) end, "installed")
        assert has_element?(view, step, "#{title}: sign it in on its terminal.")
        refute has_element?(view, step <> ~s( a[data-test="install-program"]))
        harness!(view, "mine", "program:#{name}")

        lists!(
          fake,
          row,
          fn -> has_element?(view, brain <> ~s([data-state="signed_out"])) end,
          {:signed_out, @signed_out}
        )

        assert has_element?(view, brain <> ~s( [data-test="setup-signed-out"]), "signed out")
        assert has_element?(view, step, "#{title}: sign it in on its terminal.")
        assert has_element?(view, step <> ~s( [data-test="sign-in"]), "Sign in")
        refute has_element?(view, offered)
        assert get_agent(ctx, "mine") == {:ok, before}

        # Signed in, as its account member says.
        listing = [
          %{"id" => "the-model", "name" => "The model", "efforts" => []},
          %{"id" => "other", "name" => "Other", "efforts" => []}
        ]

        view |> element(~s(#aqua-card-mine [data-test="list-again"])) |> render_click()
        lists!(fake, row, fn -> has_element?(view, offered) end, listing)
        assert has_element?(view, brain <> ~s([data-state="signed_in"]), "signed in")
        refute has_element?(view, step)
        assert choices(view, offered) == [{"program:#{name}", title}]
        assert get_agent(ctx, "mine") == {:ok, before}

        settled(
          fn ->
            model_choices(view, "mine") == [
              {"-", "Choose a model"},
              {"", "The program's default"},
              {"the-model", "The model"},
              {"other", "Other"}
            ]
          end,
          "the program's models on the card"
        )

        model!(view, "mine", "the-model")

        assert get_agent(ctx, "mine") ==
                 {:ok,
                  %{
                    before
                    | "program" => name,
                      "model" => "the-model",
                      "catalyst_ref" => nil
                  }}

        # A member holds no consent of its own: picking its brain asks nothing.
        _ = render(view)
        refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

        # Its card shows the access its program's driver lists, in the
        # driver's words, closed while the driver offers one choice.
        access = "#aqua-card-mine-access select[disabled]"
        settled(fn -> has_element?(view, access) end, "the card's access")
        [choice] = driver_access(command)
        assert choices(view, access <> " option") == [{choice["id"], choice["name"]}]

        # Saved on the card, the access is the member's own.
        view |> form("#aqua-card-mine-access") |> render_change()
        saved = %{"access" => choice["id"]}

        assert get_agent(ctx, "mine") ==
                 {:ok,
                  %{
                    before
                    | "program" => name,
                      "model" => "the-model",
                      "catalyst_ref" => nil,
                      "options" => saved
                  }}

        # A key is a catalyst: once its model is picked the program goes,
        # and so does the access, in the same write: an API brain has none
        # to choose.
        described!(ctx, "catalyst:local.open:0.1.0", %{"open-1" => []})
        on_program = get_agent(ctx, "mine")
        harness!(view, "mine", "catalyst:open")
        assert get_agent(ctx, "mine") == on_program
        model!(view, "mine", "open::open-1")

        assert get_agent(ctx, "mine") ==
                 {:ok, %{before | "catalyst_ref" => "catalyst:local.open", "model" => "open-1"}}

        settled(fn -> not has_element?(view, "#aqua-card-mine-access") end, "no access")

        # And the member answers a post on its new brain.
        Cyfr.Test.Sandbox.end_views()
        answered_on_open!(ctx, "mine")
      end
    end

    # A move takes off only what the new harness does not list, applied to
    # the member's options as they stand when it lands: an option set
    # elsewhere since the page read them is kept.
    test "a move keeps an option set elsewhere since the page read it", %{conn: conn, ctx: ctx} do
      fake = backends!()
      claude = brain_row!(ctx, "claude-code")
      codex = brain_row!(ctx, "openai-codex")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "mine",
          "title" => "Mine",
          "program" => "claude-code",
          "model" => "opus",
          "options" => %{"effort" => "high", "access" => "default"}
        })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      edit!(view, "mine")

      lists_each!(fake, [claude, codex], fn ->
        has_element?(view, ~s(#aqua-card-mine-harness option[value="program:openai-codex"])) and
          has_element?(view, "#aqua-card-mine-access select[disabled]")
      end)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "mine",
          "options_patch" => %{"effort" => "low"}
        })

      harness!(view, "mine", "program:openai-codex")

      lists_each!(fake, [claude, codex], fn ->
        has_element?(view, ~s(#aqua-card-mine-model option[value="opus"]))
      end)

      model!(view, "mine", "opus")

      assert {:ok, %{"program" => "openai-codex", "model" => "opus", "options" => options}} =
               get_agent(ctx, "mine")

      assert options == %{"effort" => "low"}
      Cyfr.Test.Sandbox.end_views()
    end

    # What a model chosen takes off is held to the member's options as they stand
    # when it lands: a value saved elsewhere since the page read them, one
    # the new model does not list, goes, and the member answers on it.
    test "a model chosen takes off a value saved elsewhere since the page read it that the new " <>
           "model does not list",
         %{conn: conn, ctx: ctx} do
      publish_brain!(ctx, "open", %{})
      grant!(ctx, "catalyst:local.open", %{bindings: []})

      remember_catalogue!(%{"open" => ["open-1", "open-2"]}, %{
        "open" => "catalyst:local.open:0.1.0"
      })

      described!(ctx, "catalyst:local.open:0.1.0", %{
        "open-1" => [%{"name" => "effort", "kind" => "enum", "values" => ["low", "high"]}],
        "open-2" => [%{"name" => "effort", "kind" => "enum", "values" => ["low"]}]
      })

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "mine",
          "title" => "Mine",
          "catalyst_ref" => "catalyst:local.open",
          "model" => "open-1",
          "options" => %{"effort" => "low"}
        })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      pick = ~s(#aqua-card-mine-model option[value="open::open-2"])
      edit!(view, "mine")
      settled(fn -> has_element?(view, pick) end, "the card's models")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "mine",
          "options_patch" => %{"effort" => "high"}
        })

      view |> form("#aqua-card-mine-model", %{"value" => "open::open-2"}) |> render_change()

      assert {:ok,
              %{
                "catalyst_ref" => "catalyst:local.open",
                "model" => "open-2",
                "options" => options
              }} =
               get_agent(ctx, "mine")

      assert options == %{}
      Cyfr.Test.Sandbox.end_views()
      answered_on_open!(ctx, "mine")
    end

    # A model picked on a card names the card's whole brain: a card left
    # open on Claude Code while the member was moved to Codex elsewhere
    # puts the member back on Claude Code with the model picked, holding
    # only what Claude Code lists, and its next turn runs there.
    test "a model picked on a card left open on another program puts the member on the card's " <>
           "program",
         %{conn: conn, ctx: ctx} do
      Cyfr.Test.SeedBundle.lay!(~w(files http))
      :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
      {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

      fake = backends!()
      claude = brain_row!(ctx, "claude-code")
      codex = brain_row!(ctx, "openai-codex")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "mine",
          "title" => "Mine",
          "program" => "claude-code",
          "model" => "opus",
          "options" => %{"effort" => "high"}
        })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      edit!(view, "mine")

      lists_each!(fake, [claude, codex], fn ->
        has_element?(view, ~s(#aqua-card-mine-model option[value="haiku"]))
      end)

      # Elsewhere: moved to Codex, with an effort and Codex's access saved.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "mine",
          "program" => "openai-codex",
          "model" => "gpt-6.1-sol",
          "options_patch" => %{"effort" => "low", "access" => "full-access"}
        })

      view |> form("#aqua-card-mine-model", %{"value" => "haiku"}) |> render_change()

      assert {:ok,
              %{
                "program" => "claude-code",
                "catalyst_ref" => nil,
                "model" => "haiku",
                "options" => options
              }} = get_agent(ctx, "mine")

      assert options == %{"effort" => "low"}
      Cyfr.Test.Sandbox.end_views()

      actor = Sanctum.Context.actor(ctx)
      {:ok, room} = Arca.Test.Days.thread(actor)
      {:ok, thread} = Aqua.Tape.crew_thread(ctx, room.id, "mine")

      assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
               Aqua.Runner.send_message(%{ctx | origin: :interactive}, thread.id, "hello")

      answers!(fake, claude, "Hello from Claude Code.", fn ->
        match?({:ok, %{status: "completed"}}, Aqua.Tape.turn(ctx, turn_id))
      end)

      assert_received {:driver_start, %{"config" => config}}
      assert config == %{"model" => "haiku", "effort" => "low"}
    end

    # The program a card's pick names is the one its form showed, not the
    # page's copy of the member: a pick that lands after the card has
    # moved to an API brain still puts the member on that program, and
    # never leaves it with no brain.
    test "a model picked on a program's card lands after the card moved to an API brain " <>
           "and names the program its form showed",
         %{conn: conn, ctx: ctx} do
      Cyfr.Test.SeedBundle.lay!(~w(files http))
      :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
      {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
      open_brain!(ctx)

      fake = backends!()
      claude = brain_row!(ctx, "claude-code")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "mine",
          "title" => "Mine",
          "program" => "claude-code",
          "model" => "opus"
        })

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      shown = ~s(#aqua-card-mine-model input[name="program"][value="claude-code"])

      edit!(view, "mine")

      lists_each!(fake, [claude], fn ->
        has_element?(view, ~s(#aqua-card-mine-model option[value="haiku"]))
      end)

      assert has_element?(view, shown)

      # The card moves to an API brain before the pick lands.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "mine",
          "program" => nil,
          "catalyst_ref" => "catalyst:local.open",
          "model" => "open-1"
        })

      send(view.pid, {:refresh, :agents})
      settled(fn -> not has_element?(view, shown) end, "the card on the API brain")

      # The pick the program's form sent, as it showed the card.
      view
      |> with_target("#aqua-agents")
      |> render_change("editor_set_model", %{
        "name" => "mine",
        "brain" => "program",
        "program" => "claude-code",
        "value" => "haiku"
      })

      assert {:ok, %{"program" => "claude-code", "catalyst_ref" => nil, "model" => "haiku"}} =
               get_agent(ctx, "mine")
    end

    # A program's pick that names no program, or names one that is no
    # text, changes nothing and leaves the page open.
    test "a program's model pick that names no program changes nothing", %{conn: conn, ctx: ctx} do
      open_brain!(ctx)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "create",
          "name" => "mine",
          "title" => "Mine",
          "catalyst_ref" => "catalyst:local.open",
          "model" => "open-1"
        })

      {:ok, before} = get_agent(ctx, "mine")
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      edit!(view, "mine")
      settled(fn -> has_element?(view, "#aqua-card-mine-model") end, "the card")

      for {program, value} <- [{"", ""}, {%{"a" => "b"}, "haiku"}] do
        view
        |> with_target("#aqua-agents")
        |> render_change("editor_set_model", %{
          "name" => "mine",
          "brain" => "program",
          "program" => program,
          "value" => value
        })

        assert has_element?(view, "#aqua-card-mine-model")
        assert get_agent(ctx, "mine") == {:ok, before}
      end
    end

    # A member moved from one program brain to the other keeps each option
    # whose value the new program lists, and drops any other: the access
    # the first driver listed is none of the second's, so it goes, and the
    # member's turn on the second program starts with no access named,
    # taking that driver's first choice, and answers.
    for {from, to} <- [{"claude-code", "openai-codex"}, {"openai-codex", "claude-code"}] do
      @tag move: {from, to}
      test "a member moved from #{from} to #{to} drops the access #{to} does not list, and " <>
             "answers on #{to}",
           %{conn: conn, ctx: ctx, move: {from, to}} do
        # The crew's grant, as the fill mints it over a seed whose hands
        # Aqua's tools need are installed.
        Cyfr.Test.SeedBundle.lay!(~w(files http))
        :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)

        :ok =
          Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())

        {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
        {:ok, _} = Compendium.AgentIndex.sync(ctx)
        {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)

        fake = backends!()
        from_row = brain_row!(ctx, from)
        to_row = brain_row!(ctx, to)
        [from_access] = driver_access(Arca.McpServerStorage.driver(from_row))
        [to_access] = driver_access(Arca.McpServerStorage.driver(to_row))

        {:ok, _} =
          Cyfr.Test.AquaTool.call(ctx, %{
            "action" => "create",
            "name" => "mine",
            "title" => "Mine",
            "program" => from,
            "model" => "opus",
            "options" => %{"effort" => "high", "access" => from_access["id"]}
          })

        {view, _html} = mount_athanor(conn, "/aqua?setup=1")
        access = "#aqua-card-mine-access select[disabled]"
        edit!(view, "mine")

        lists_each!(fake, [from_row, to_row], fn ->
          has_element?(view, ~s(#aqua-card-mine-harness option[value="program:#{to}"])) and
            has_element?(view, access)
        end)

        assert choices(view, access <> " option") == [{from_access["id"], from_access["name"]}]

        unmoved = get_agent(ctx, "mine")
        harness!(view, "mine", "program:#{to}")
        assert get_agent(ctx, "mine") == unmoved

        lists_each!(fake, [from_row, to_row], fn ->
          has_element?(view, ~s(#aqua-card-mine-model option[value="opus"]))
        end)

        # Its model chosen from the new program's listing, the effort stays.
        model!(view, "mine", "opus")

        assert {:ok,
                %{
                  "program" => ^to,
                  "model" => "opus",
                  "catalyst_ref" => nil,
                  "options" => options
                }} = get_agent(ctx, "mine")

        assert options == %{"effort" => "high"}

        settled(
          fn -> choices(view, access <> " option") == [{to_access["id"], to_access["name"]}] end,
          "the new program's access"
        )

        Cyfr.Test.Sandbox.end_views()

        # A post to the member runs on the new program, which starts with
        # the effort kept and no access named.
        actor = Sanctum.Context.actor(ctx)
        {:ok, room} = Arca.Test.Days.thread(actor)
        {:ok, thread} = Aqua.Tape.crew_thread(ctx, room.id, "mine")

        assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
                 Aqua.Runner.send_message(%{ctx | origin: :interactive}, thread.id, "hello")

        answers!(fake, to_row, "Hello from #{to}.", fn ->
          match?({:ok, %{status: "completed"}}, Aqua.Tape.turn(ctx, turn_id))
        end)

        assert_received {:driver_start, %{"config" => config}}
        assert config == %{"model" => "opus", "effort" => "high"}

        assert ["Hello from #{to}."] ==
                 for(
                   %{turn_id: ^turn_id, sent_by: "mine", kind: "text", content: said} <-
                     Arca.ThreadStorage.messages(actor, thread.id),
                   do: said
                 )
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

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")

      harness!(view, "mine", "catalyst:program")
      model!(view, "mine", "program::vendor::model")

      assert get_agent(ctx, "mine") ==
               {:ok,
                %{before | "catalyst_ref" => "catalyst:local.program", "model" => "vendor::model"}}

      Cyfr.Test.Sandbox.end_views()
    end

    # Aqua answers with the brain, model and options of the crew member it
    # runs on: the crew's grant does not follow that member, so choosing
    # one asks nothing and grants nothing.
    test "choosing the crew member Aqua runs on asks nothing",
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
      # Each member is named with the harness or key and the model Aqua
      # would run on.
      assert {"mine", "Mine — open, open-1"} in choices(view, "#aqua-setup-member option")
      assert {"mine", "Mine — open, open-1"} in choices(view, "#aqua-card-aqua-member option")

      view |> form("#aqua-setup-member", %{"member" => "mine"}) |> render_change()

      assert {:ok,
              %{"member" => "mine", "catalyst_ref" => "catalyst:local.open", "model" => "open-1"}} =
               get_agent(ctx, "aqua")

      _ = render(view)
      refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

      # The card names who Aqua runs on, and has no model of its own.
      assert has_element?(view, ~s(#aqua-card-aqua-member option[value="mine"][selected]))
      refute has_element?(view, "#aqua-card-aqua-model")

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
        PrismWeb.ModelCatalog.remember(athanor.id, %{
          "models" => %{"kept" => ["kept-model-1"]},
          "refs" => %{"kept" => "catalyst:local.kept"}
        })

      on_exit(fn -> PrismWeb.ModelCatalog.forget(athanor.id) end)

      # The page reads the kept catalogue. A key only the catalogue lists
      # is not a connected one, so no form offers it.
      :ok = member!(ctx, "explorer")
      {view, _html} = mount_athanor(conn, "/aqua")

      settled(
        fn -> elem(picker(view), 0) == %{"kept" => ["kept-model-1"]} end,
        "the kept catalogue read"
      )

      refute has_element?(view, ~s(option[value="catalyst:kept"]))

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
    # it; cleared, it takes it off. The provider's own search is the
    # Search group's switch on the same list.
    test "a checkbox offers the soul a tool and takes it off again; a crew member holds none",
         %{conn: conn, ctx: ctx} do
      :ok = member!(ctx, "explorer")
      {view, _html} = mount_athanor(conn, "/aqua")
      {:ok, before} = get_agent(ctx, "aqua")
      refute "storage.write" in before["tools"]
      assert "native_search" in before["tools"]

      for {key, during, box, on} <- [
            {"storage.write", Enum.sort(["storage.write" | before["tools"]]),
             ~s(#aqua-card-aqua input[phx-click=editor_toggle_capability][phx-value-key="storage.write"]),
             "[checked]"},
            {"native_search", before["tools"] -- ["native_search"],
             "#aqua-card-aqua #aqua-group-search-switch", ~s([aria-checked="true"])}
          ] do
        ticked? = key in before["tools"]
        assert has_element?(view, box <> on) == ticked?

        view |> element(box) |> render_click()
        assert {:ok, %{before | "tools" => during}} == get_agent(ctx, "aqua")
        assert {:ok, %{"tools" => ^during}} = get_agent(ctx, "explorer")

        settled(
          fn -> has_element?(view, box <> on) == not ticked? end,
          "#{key}'s switch after the first click"
        )

        view |> element(box) |> render_click()
        assert {:ok, before} == get_agent(ctx, "aqua")

        settled(
          fn -> has_element?(view, box <> on) == ticked? end,
          "#{key}'s switch after the second click"
        )
      end

      # A crew member's own write is refused.
      html =
        view
        |> with_target("#aqua-agents")
        |> render_click("editor_toggle_capability", %{
          "name" => "explorer",
          "key" => "storage.list",
          "on" => "true"
        })

      assert html =~ "A crew member is offered the soul&#39;s tools and has none of its own"
      assert {:ok, before} == get_agent(ctx, "aqua")
    end

    # A soul whose file lists its tools under the retired `tool_policy`:
    # the section says what to change in place of every card, and the
    # rest of the page renders.
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
      refute has_element?(view, ~s(#aqua-new-member, [data-test="new-member-waits"]))
      refute render(view) =~ "own file is missing"
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

    # Opening the page reads what the member's file holds and what is
    # known, and asks nothing: no program starts for a page read. Its card
    # shows the stored values closed, the model by its id while no name is
    # known. A press opens the editor, which asks for that program's list.
    test "opening the page opens no session, and opening an editor opens one",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      home = row.id
      :ok = member!(ctx, "claude-code")
      card = "#aqua-card-claude-code"

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      settled(fn -> has_element?(view, card <> "-runs") end, "the card")
      reread_setup(view)
      send_update_agents(view, load: true)
      _ = render(view)
      refute_receive {:session, "open", _open, _fields}, 500

      assert texts(view, card <> "-runs dd") == ["Claude Code", "opus"]
      refute has_element?(view, card <> "-model")
      assert has_element?(view, card, "Installed")
      refute has_element?(view, card, "Model connected")
      refute has_element?(view, card <> ".opacity-60")
      refute has_element?(view, ~s(#aqua-card-aqua-member option[value="claude-code"][disabled]))

      assert has_element?(
               view,
               ~s(#aqua-setup-brain-claude-code[data-state="installed"]),
               "installed"
             )

      assert has_element?(view, ~s(#aqua-setup-step-brains[data-done="true"]))

      edit!(view, "claude-code")
      assert_receive {:session, "open", %{"mode" => "run", "home_id" => ^home}, _fields}, 5_000
      lists!(fake, row, fn -> has_element?(view, card <> ~s(-model option[value="haiku"])) end)

      # What was listed is known: a page opened later names the model by it,
      # and still asks nothing.
      flush_sessions()
      {later, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> texts(later, card <> "-runs dd") == ["Claude Code", "Opus"] end, "the name")
      refute_receive {:session, "open", _open, _fields}, 500
      Cyfr.Test.Sandbox.end_views()
    end

    # A CYFR with no room is not a program signed out: the member stays as
    # it was, the form to make one stays, and the editor says there is no
    # room, with Try again, which asks again.
    test "a full CYFR keeps the member and the form, and reads nothing signed out",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      {:ok, before} = get_agent(ctx, "claude-code")
      card = "#aqua-card-claude-code"

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      Cyfr.Test.ScriptedBackends.refuse_once(fake, "open", "capacity")
      edit!(view, "claude-code")

      settled(
        fn ->
          has_element?(
            view,
            card <> ~s( [data-test="listing-failed"]),
            "This CYFR has no room for another running program right now."
          )
        end,
        "no room said"
      )

      refute has_element?(view, card <> ".opacity-60")
      refute has_element?(view, card <> ~s( [data-test="sign-in"]))
      refute render(view) =~ "signed out"
      refute render(view) =~ "cannot be read right now"
      assert has_element?(view, ~s(#aqua-setup-brain-claude-code[data-state="installed"]))
      assert has_element?(view, "#aqua-setup-new-member-open", "New crew member")
      assert has_element?(view, "#aqua-new-member-open", "New crew member")
      assert get_agent(ctx, "claude-code") == {:ok, before}

      view |> element(card <> ~s( [data-test="list-again"])) |> render_click()
      lists!(fake, row, fn -> has_element?(view, card <> ~s(-model option[value="haiku"])) end)
      refute has_element?(view, card <> ~s( [data-test="listing-failed"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # Effort follows the model: each model takes efforts of its own, a
    # change of model clears one the new model does not list, and a model
    # with none disables Effort.
    test "a model change clears an effort the new model does not list", %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      effort = "#aqua-card-claude-code-option-effort"

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "claude-code",
          "options_patch" => %{"effort" => "max", "access" => "default"}
        })

      listing = [
        %{"id" => "opus", "name" => "Opus", "efforts" => ["low", "high", "max"]},
        %{"id" => "sonnet", "name" => "Sonnet", "efforts" => ["low", "max"]},
        %{"id" => "haiku", "name" => "Haiku", "efforts" => []}
      ]

      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "claude-code")

      lists!(
        fake,
        row,
        fn -> has_element?(view, effort <> ~s( option[value="high"])) end,
        listing
      )

      assert texts(view, effort <> " option") == ["default", "low", "high", "max"]

      model!(view, "claude-code", "sonnet")

      assert {:ok,
              %{"model" => "sonnet", "options" => %{"effort" => "max", "access" => "default"}}} =
               get_agent(ctx, "claude-code")

      settled(fn -> texts(view, effort <> " option") == ["default", "low", "max"] end, "Sonnet's")

      model!(view, "claude-code", "haiku")
      assert {:ok, %{"model" => "haiku", "options" => options}} = get_agent(ctx, "claude-code")
      assert options == %{"access" => "default"}
      settled(fn -> has_element?(view, effort <> " select[disabled]") end, "Effort disabled")
      Cyfr.Test.Sandbox.end_views()
    end

    # A failed ask wipes nothing: the stored values stand, and an edit that
    # needs the list is refused with Try again.
    test "a failed ask keeps every stored value, and an edit that needs the list is refused",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      card = "#aqua-card-claude-code"

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "claude-code",
          "options_patch" => %{"effort" => "max", "access" => "default"}
        })

      {:ok, before} = get_agent(ctx, "claude-code")
      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "claude-code")
      why = "Claude Code did not list its models: it did not answer in time."

      lists!(
        fake,
        row,
        fn -> has_element?(view, card <> ~s( [data-test="listing-failed"]), why) end,
        {:refused, why}
      )

      refute has_element?(view, card <> ".opacity-60")

      for {event, sent} <- [
            {"editor_set_model",
             %{"brain" => "program", "program" => "claude-code", "value" => "haiku"}},
            {"editor_set_option", %{"option" => "effort", "value" => "low"}}
          ] do
        assert view
               |> with_target("#aqua-agents")
               |> render_change(event, Map.put(sent, "name", "claude-code")) =~ "Try again"

        assert get_agent(ctx, "claude-code") == {:ok, before}
      end

      Cyfr.Test.Sandbox.end_views()
    end

    # Make takes a model its program lists and that model's effort alone.
    test "Make refuses a model the program does not list and an effort its model does not take",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      new = "#aqua-new-member"

      listing = [
        %{"id" => "opus", "name" => "Opus", "efforts" => ["high"]},
        %{"id" => "haiku", "name" => "Haiku", "efforts" => []}
      ]

      {view, _html} = mount_athanor(conn, "/aqua")
      choose!(view, new, "Maker", "program:claude-code")
      lists!(fake, row, fn -> has_element?(view, new <> ~s( option[value="haiku"])) end, listing)

      pick = %{"name" => "Maker", "brain" => "program:claude-code"}

      for sent <- [
            %{"model" => "invented"},
            %{"model" => "haiku", "options" => %{"effort" => "high"}}
          ] do
        assert view
               |> with_target("#aqua-agents")
               |> render_submit("make_member", Map.merge(pick, sent)) =~
                 "does not offer what was chosen"

        assert {:error, _} = get_agent(ctx, "Maker")
      end

      view |> form(new, Map.put(pick, "model", "opus")) |> render_change()
      view |> form(new, %{"options" => %{"effort" => "high"}}) |> render_change()
      view |> form(new, %{"model" => "haiku"}) |> render_change()
      assert has_element?(view, new <> ~s( select[name="options[effort]"][disabled]))
      refute has_element?(view, new <> ~s( option[value="high"]))
      Cyfr.Test.Sandbox.end_views()
    end

    # A write is decided on the member as it is stored when it lands: the
    # model and the effort are checked together and written together, so an
    # editor left open puts no effort of the last model on the next.
    test "an edit left open cannot put the previous model's effort on its successor",
         %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      effort = "#aqua-card-claude-code-option-effort"
      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "claude-code")

      listing = [
        %{"id" => "opus", "name" => "Opus", "efforts" => ["low", "max"]},
        %{"id" => "haiku", "name" => "Haiku", "efforts" => []}
      ]

      lists!(fake, row, fn -> has_element?(view, effort <> " option[value=max]") end, listing)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "claude-code",
          "model" => "haiku"
        })

      view |> form(effort, %{"value" => "max"}) |> render_change()
      {:ok, saved} = get_agent(ctx, "claude-code")
      assert {saved["model"], saved["options"]["effort"]} == {"haiku", nil}
      Cyfr.Test.Sandbox.end_views()
    end

    # A write needs the list this opening of the editor asked for and got.
    # An earlier opening's, a pending ask and a failed one authorize
    # nothing, however the pick reaches the page.
    test "only the list this opening asked for authorizes a write", %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      card = "#aqua-card-claude-code"
      {view, _html} = mount_athanor(conn, "/aqua")
      edit!(view, "claude-code")
      lists!(fake, row, fn -> has_element?(view, card <> "-model option[value=haiku]") end)
      view |> element(card <> "-done") |> render_click()
      {:ok, before} = get_agent(ctx, "claude-code")

      edit!(view, "claude-code")

      picks = [
        {"editor_set_model",
         %{"brain" => "program", "program" => "claude-code", "value" => "haiku"}},
        {"editor_set_option", %{"option" => "effort", "value" => "low"}}
      ]

      pick = fn {event, sent} ->
        html =
          view
          |> with_target("#aqua-agents")
          |> render_change(event, Map.put(sent, "name", "claude-code"))

        assert get_agent(ctx, "claude-code") == {:ok, before}
        assert html =~ "Try again"
      end

      # Pending, then refused.
      Enum.each(picks, pick)

      lists!(
        fake,
        row,
        fn -> has_element?(view, card <> " [data-test=listing-failed]") end,
        {:refused, "Could not list models"}
      )

      Enum.each(picks, pick)
      Cyfr.Test.Sandbox.end_views()
    end

    # The page keeps no copy of what is known: it reads it as it renders,
    # its own event or a card's alike.
    for press <- ["#aqua-setup summary", "#aqua-card-claude-code-edit"] do
      @tag press: press
      test "an open page stops greying the member once the evidence expires, seen at #{press}",
           %{conn: conn, ctx: ctx, press: press} do
        fake = backends!()
        row = brain_row!(ctx, "claude-code")
        :ok = member!(ctx, "claude-code")

        key =
          Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), row.id, row.epoch, :account)

        :ok = Arca.Cache.put(key, :signed_out, 600_000)
        {view, _html} = mount_athanor(conn, "/aqua")
        settled(fn -> has_element?(view, "#aqua-card-claude-code.opacity-60") end, "signed out")
        :ok = Arca.Cache.put(key, :signed_out, 0)
        assert :miss == Arca.Cache.get(key)
        view |> element(press) |> render_click()
        refute has_element?(view, "#aqua-card-claude-code.opacity-60")

        if press =~ "-edit" do
          option = ~s(#aqua-card-claude-code-model option[value="haiku"])
          lists!(fake, row, fn -> has_element?(view, option) end)
        end

        Cyfr.Test.Sandbox.end_views()
      end
    end

    # Sign in shows the terminal where the person pressed, one that
    # another panel of the page already shows among them.
    test "an existing terminal is shown in the editor that requested it", %{conn: conn, ctx: ctx} do
      backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      card = "#aqua-card-claude-code"
      key = Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), row.id, row.epoch, :account)
      :ok = Arca.Cache.put(key, :signed_out, 600_000)
      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      settled(fn -> has_element?(view, card <> " [data-test=sign-in]") end, "signed out")
      view |> element("#aqua-setup-brain-claude-code input") |> render_click()

      view
      |> element("#aqua-setup-step-program-claude-code [data-test=sign-in]")
      |> render_click()

      session = sign_in_terminal!(view, "#aqua-setup")
      [was] = screen_ids(view)

      view |> element(card <> " [data-test=sign-in]") |> render_click()
      assert sign_in_terminal!(view, card) == session
      refute has_element?(view, ~s(#aqua-setup [data-test="terminal"]))

      # A frame of its own, so its hook stands again and attaches.
      assert [screen] = screen_ids(view)
      refute screen == was

      assert view
             |> element("#" <> screen)
             |> render_hook("terminal_ready", %{"session" => session, "rows" => 30, "cols" => 90})

      Cyfr.Test.Sandbox.end_views()
    end

    # The page asks nothing while that terminal runs, so it stays where
    # the person can end it when its card is gone.
    test "a terminal whose card is gone stays on the page", %{conn: conn, ctx: ctx} do
      backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      card = "#aqua-card-claude-code"
      key = Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), row.id, row.epoch, :account)
      :ok = Arca.Cache.put(key, :signed_out, 600_000)
      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, card <> " [data-test=sign-in]") end, "signed out")
      view |> element(card <> " [data-test=sign-in]") |> render_click()
      session = sign_in_terminal!(view, card)

      view |> element(card <> " button[phx-click=editor_delete]") |> render_click()
      settled(fn -> not has_element?(view, card) end, "the card gone")
      assert sign_in_terminal!(view, "#aqua-agents") == session
      Cyfr.Test.Sandbox.end_views()
    end

    # Sign in is one thing at a time: an ask already out is let end, then
    # the terminal opens before any other, and nothing is asked until it
    # ends, whatever is pressed meanwhile.
    test "Sign in asks nothing beside its terminal", %{conn: conn, ctx: ctx} do
      fake = backends!()
      claude = brain_row!(ctx, "claude-code")
      codex = brain_row!(ctx, "openai-codex")
      :ok = member!(ctx, "claude-code")
      :ok = member!(ctx, "openai-codex")
      card = "#aqua-card-claude-code"
      home = claude.id
      key = Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), home, claude.epoch, :account)
      :ok = Arca.Cache.put(key, :signed_out, 600_000)

      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, card <> " [data-test=sign-in]") end, "signed out")
      edit!(view, "claude-code")
      assert_receive {:session, "open", %{"mode" => "run", "home_id" => ^home}, _fields}, 5_000

      view |> element(card <> " [data-test=sign-in]") |> render_click()
      refute_receive {:session, "open", %{"mode" => "terminal"}, _fields}, 500

      screen = card <> ~s( [id$="-screen"][data-session])
      lists!(fake, claude, fn -> has_element?(view, screen) end, {:signed_out, @signed_out})

      edit!(view, "openai-codex")
      refute_receive {:session, "open", %{"mode" => "run"}, _fields}, 500

      for held <- [card, "#aqua-card-openai-codex"] do
        assert has_element?(
                 view,
                 held <> ~s( [data-test="listing-held"]),
                 "It is asked for its list when the sign-in's terminal ends."
               )
      end

      Cyfr.Test.ScriptedBackends.end_sessions(fake, home)

      lists_each!(fake, [claude, codex], fn ->
        has_element?(view, card <> ~s(-model option[value="haiku"])) and
          has_element?(view, ~s(#aqua-card-openai-codex-model option[value="haiku"]))
      end)

      Cyfr.Test.Sandbox.end_views()
    end

    # A listing whose task is lost ends as failed, with Try again, and the
    # next press is asked.
    test "a lost listing task fails its listing and leaves Try again", %{conn: conn, ctx: ctx} do
      fake = backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")
      card = "#aqua-card-claude-code"
      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, card <> "-edit") end, "the card")
      before = Process.list()
      edit!(view, "claude-code")
      home = row.id
      assert_receive {:session, "open", %{"mode" => "run", "home_id" => ^home}, _fields}, 5_000

      assert [task] =
               for(
                 pid <- Process.list() -- before,
                 {:dictionary, held} <- [Process.info(pid, :dictionary)],
                 match?([page | _] when page == view.pid, held[:"$callers"]),
                 do: pid
               )

      # Lost alone, as a task lost after it let the page go is.
      :sys.replace_state(view.pid, fn state ->
        Process.unlink(task)
        state
      end)

      Process.exit(task, :kill)

      settled(
        fn -> has_element?(view, card <> ~s( [data-test="listing-failed"]), "did not answer") end,
        "the lost listing said"
      )

      # The lost caller's holder ends with it and closes its session, which
      # no driver answered: the retry's is then the row's one session.
      assert_receive {:session, "close", %{"home_id" => ^home}, _fields}, 5_000

      over = fn ->
        not Enum.any?(Cyfr.Test.ScriptedBackends.sessions(fake, home), fn {_id, session} ->
          session.running
        end)
      end

      settled(over, "the lost caller's session ended")
      view |> element(card <> ~s( [data-test="list-again"])) |> render_click()
      lists!(fake, row, fn -> has_element?(view, card <> ~s(-model option[value="haiku"])) end)
      Cyfr.Test.Sandbox.end_views()
    end

    # A real sign-out greys the member's card and its "Runs on" entry, and
    # Aqua's card when it runs on that member, each with Sign in and
    # Change. A page that only reads says it, and asks nothing.
    test "a known sign-out greys the member and Aqua on it, and offers Sign in and Change",
         %{conn: conn, ctx: ctx} do
      on_exit(fn ->
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
      end)

      backends!()
      row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "member" => "claude-code"
        })

      key =
        Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), row.id, row.epoch, :account)

      :ok = Arca.Cache.put(key, :signed_out, 600_000)

      {view, _html} = mount_athanor(conn, "/aqua?setup=1")
      settled(fn -> has_element?(view, "#aqua-card-claude-code.opacity-60") end, "greyed")

      for card <- ["#aqua-card-claude-code", "#aqua-card-aqua"] do
        assert has_element?(view, card <> ".opacity-60")

        assert has_element?(
                 view,
                 card <> ~s( [data-test="program-signed-out"]),
                 "Claude Code's program is signed out. Sign it in, or choose another."
               )

        assert has_element?(view, card <> ~s( [data-test="sign-in"]), "Sign in")
        assert has_element?(view, card <> ~s( [data-test="change"]), "Change")
        refute has_element?(view, card, "Model connected")
      end

      for runs_on <- ["#aqua-setup-member", "#aqua-card-aqua-member"] do
        assert has_element?(
                 view,
                 runs_on <> ~s( option[value="claude-code"][disabled]),
                 "signed out"
               )
      end

      assert has_element?(view, ~s(#aqua-setup-step-aqua[data-done="false"]))
      assert has_element?(view, "#aqua-setup-made-claude-code", "not ready yet")
      assert has_element?(view, "#aqua-setup summary", "Set up Aqua")
      refute_receive {:session, "open", _open, _fields}, 500
      Cyfr.Test.Sandbox.end_views()
    end

    # Once Aqua is ready its setup is no task left to do.
    test "the setup's summary reads Aqua's setup once Aqua is ready", %{conn: conn, ctx: ctx} do
      on_exit(fn ->
        Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => nil})
      end)

      Cyfr.Test.SeedBundle.lay!(~w(files http))
      :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
      :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
      {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
      backends!()
      _row = brain_row!(ctx, "claude-code")
      :ok = member!(ctx, "claude-code")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "member" => "claude-code"
        })

      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, "#aqua-setup summary", "Aqua's setup") end, "Aqua ready")
      Cyfr.Test.Sandbox.end_views()
    end

    # A person reads what an action does, never the operation's id.
    test "a permission shows its action's declared title", %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/aqua")

      row =
        "#aqua-card-aqua label:has([phx-value-key='aqua.skill_create']) [data-test=aqua-entry-name]"

      labels =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(row)
        |> LazyHTML.text()
        |> String.trim()

      assert labels == Aqua.action_title("aqua", "skill_create")
      refute texts(view, "#aqua-card-aqua label") |> Enum.any?(&(&1 == "aqua.skill_create"))
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
      edit!(view, "explorer")
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
          edit!(view, "explorer")
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
      |> render_click("editor_toggle_capability", %{
        "name" => "aqua",
        "key" => "storage.write",
        "on" => "true"
      })

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
      |> render_click("editor_toggle_capability", %{
        "name" => "aqua",
        "key" => "storage.write",
        "on" => "false"
      })

      want = Enum.sort(["vault.get", "vault.list" | shipped])
      assert {:ok, %{"tools" => ^want}} = get_agent(ctx, "aqua")
    end
  end

  describe "what Aqua may use" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
      {:ok, conn: conn, ctx: ctx}
    end

    # Each MCP server of the athanor is a group of its own: its tools, then
    # its resources and its prompts, off until the person switches them on
    # there, one entry or the whole group in one update; an entry that
    # cannot be handed says why, and a server that does not answer says so
    # once, its entries already on the list still there to switch off.
    test "each MCP server is a group of its own, its offerings off until switched on there",
         %{conn: conn, ctx: ctx} do
      # Aqua as setup leaves it: shipped, its grant given for the list it
      # ships with, which every switch here moves past.
      shipped_and_granted!(ctx)
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(
               view,
               ~s(#aqua-may-use [data-test="aqua-no-servers"] a[href$="/programs"]),
               "Programs"
             )

      Cyfr.Test.Sandbox.end_views()

      offering_server!(ctx, "docs", ~w(search fetch two__parts))
      offering_server!(ctx, "quiet", [], silent: true)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tools_add" => ["quiet:ask"]
        })

      {:ok, %{"tools" => before}} = get_agent(ctx, "aqua")
      docs = "#aqua-group-server-docs"
      quiet = "#aqua-group-server-quiet"

      # Each server's name stands before it answers.
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, docs, "docs")
      assert has_element?(view, quiet, "quiet")
      render_async(view, 5_000)

      assert entries(view, docs) == [
               {"docs:fetch", false},
               {"docs:search", false},
               {"docs:two__parts", false},
               {"docs:@resources", false},
               {"docs:@prompts", false}
             ]

      assert has_element?(view, docs <> ~s( [data-key="docs:@resources"]), "Resources")
      assert has_element?(view, docs <> ~s( [data-key="docs:@prompts"]), "Prompts")
      assert has_element?(view, docs <> ~s(-switch[aria-checked="false"]))

      assert has_element?(view, quiet <> ~s([data-state="silent"]), "quiet did not answer")
      assert has_element?(view, quiet <> " button[phx-click=offerings_again]", "Ask again")
      assert entries(view, quiet) == [{"quiet:ask", true}]

      # One entry switched on writes the one list, and one whose name no
      # model can be given says why once the page has asked again.
      view |> element(entry_box(docs, "docs:two__parts")) |> render_click()
      assert {:ok, %{"tools" => with_one}} = get_agent(ctx, "aqua")
      assert with_one == Enum.sort(["docs:two__parts" | before])

      settled(
        fn ->
          render_async(view, 5_000)

          has_element?(
            view,
            docs <>
              ~s( [data-key="docs:two__parts"] [data-test="aqua-not-handed"][data-reason="name"])
          )
        end,
        "the reason a turn would give"
      )

      assert has_element?(view, docs <> ~s(-switch[aria-checked="mixed"]))

      # The group's switch adds the rest in one update, then takes them all
      # off in one more.
      everything = ~w(docs:@prompts docs:@resources docs:fetch docs:search docs:two__parts)
      updates = aqua_updates(ctx)
      view |> element(docs <> "-switch") |> render_click()
      assert {:ok, %{"tools" => all_on}} = get_agent(ctx, "aqua")
      assert all_on == Enum.sort(everything ++ before)
      settled(fn -> aqua_updates(ctx) == updates + 1 end, "one update")

      settled(
        fn -> has_element?(view, docs <> ~s(-switch[aria-checked="true"])) end,
        "the group on"
      )

      view |> element(docs <> "-switch") |> render_click()
      assert {:ok, %{"tools" => ^before}} = get_agent(ctx, "aqua")
      settled(fn -> aqua_updates(ctx) == updates + 2 end, "one more update")

      # The silent server's entry is still switched off from its group.
      view |> element(entry_box(quiet, "quiet:ask")) |> render_click()
      assert {:ok, %{"tools" => without}} = get_agent(ctx, "aqua")
      assert without == before -- ["quiet:ask"]
      Cyfr.Test.Sandbox.end_views()
    end

    # Aqua on a ready brain, its grant given: a switch moves what Aqua may
    # use past it, so the block says once that it is to give again, as
    # the next turn's start refuses until it is.
    test "a switch puts what Aqua may use past its grant, said once at the top of the block",
         %{conn: conn, ctx: ctx} do
      soul_on_open!(ctx)

      {view, _html} = mount_athanor(conn, "/aqua")
      refute has_element?(view, ~s(#aqua-card-aqua [data-test="aqua-grant"]))

      view |> element("#aqua-group-search-switch") |> render_click()

      settled(
        fn ->
          has_element?(
            view,
            ~s(#aqua-may-use [data-test="aqua-grant"][data-state="consent_stale"]),
            "What Aqua and its crew members may use changed since you granted it."
          )
        end,
        "the grant asked again"
      )

      assert has_element?(view, "#aqua-may-use button[phx-click=open_consent]", "Grant again")
      assert length(texts(view, ~s(#aqua-card-aqua [data-test="aqua-grant"]))) == 1

      # What holds until then, beside it, held in view as the block scrolls.
      assert has_element?(
               view,
               ~s(#aqua-may-use [data-test="aqua-grant-held"] [data-test="aqua-grant-meanwhile"]),
               "Aqua and its crew members take no turn"
             )

      assert {:ok, :stale} =
               ctx
               |> Opus.authority_for(:default, Prima.AgentRef.soul_ref())
               |> elem(1)
               |> Aqua.ConsentStatus.classify_refusal()

      Cyfr.Test.Sandbox.end_views()
    end

    # A switch writes only a key this page lists for the athanor, and
    # means what the person chose: a press in a tab that still shows the
    # old state is the same choice, not its undoing.
    test "a switch writes only what the page lists, set to what the person chose",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"tools" => before}} = get_agent(ctx, "aqua")
      {view, _html} = mount_athanor(conn, "/aqua")
      {other, _html} = mount_athanor(conn, "/aqua")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{
        "name" => "aqua",
        "key" => "absent:read",
        "on" => "true"
      })

      assert {:ok, %{"tools" => ^before}} = get_agent(ctx, "aqua")

      search = "#aqua-group-search-switch"
      on? = "native_search" in before
      view |> element(search) |> render_click()
      other |> element(search) |> render_click()
      assert {:ok, %{"tools" => after_both}} = get_agent(ctx, "aqua")
      assert "native_search" in after_both == not on?
      Cyfr.Test.Sandbox.end_views()
    end

    # A grant given while a server did not expose a listed tool still
    # loads once the server exposes it, and the next turn's start refuses
    # for it: the block says so, from the start's own comparison.
    test "a server exposing more than its grant covers asks for the grant again on the page",
         %{conn: conn, ctx: ctx} do
      soul_on_open!(ctx)
      offering_server!(ctx, "gh", ["search"], config: %{"tool_patterns" => ["other"]})

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tools_add" => ["gh:search"]
        })

      {:ok, _} = Compendium.AgentIndex.sync(ctx)
      grant!(ctx, Prima.AgentRef.soul_ref(), %{selections: []})
      line = ~s(#aqua-may-use [data-test="aqua-grant"][data-state="consent_stale"])

      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, "#aqua-group-server-gh[data-state=answered]") end, "gh")
      render_async(view, 5_000)
      refute has_element?(view, line)
      Cyfr.Test.Sandbox.end_views()

      {:ok, _} =
        Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "gh", %{
          config_json: Jason.encode!(%{"tool_patterns" => ["other", "search"]})
        })

      {view, _html} = mount_athanor(conn, "/aqua")

      settled(
        fn ->
          render_async(view, 5_000)
          has_element?(view, line, "changed since you granted it")
        end,
        "the grant asked again"
      )

      Cyfr.Test.Sandbox.end_views()
    end

    # Each server's group fills in as its own answer comes: one held server
    # keeps no answered one waiting, and a write meanwhile asks it no
    # second time.
    test "an answered server's group fills in while another is still asked",
         %{conn: conn, ctx: ctx} do
      {:ok, hold} = Agent.start_link(fn -> true end)
      offering_server!(ctx, "docs", ["search"])
      offering_server!(ctx, "held", ["read"], hold: hold)
      docs = "#aqua-group-server-docs"
      held = "#aqua-group-server-held"

      {view, _html} = mount_athanor(conn, "/aqua")
      assert_receive {:holding, "held", stub}, 5_000

      settled(
        fn ->
          has_element?(view, docs <> ~s([data-state="answered"] [data-key="docs:search"]))
        end,
        "docs answered while held is asked"
      )

      assert has_element?(view, held <> ~s([data-state="asking"]))

      view |> element(entry_box(docs, "docs:search")) |> render_click()
      settled(fn -> has_element?(view, entry_box(docs, "docs:search") <> "[checked]") end, "on")
      assert has_element?(view, held <> ~s([data-state="asking"]))
      refute_received {:holding, "held", _second}

      :ok = Agent.update(hold, fn _ -> false end)
      send(stub, :go)

      settled(
        fn -> has_element?(view, held <> ~s([data-state="answered"] [data-key="held:read"])) end,
        "held answered"
      )

      Cyfr.Test.Sandbox.end_views()
    end

    # A switch pressed takes no other press while its write is under way,
    # and the answer to the press already shows the write: a second press
    # means what the person sees then, never the state before the first.
    test "a pressed switch shows its write in the answer to the press, and takes no press meanwhile",
         %{conn: conn, ctx: ctx} do
      offering_server!(ctx, "docs", ["search", "fetch"])
      switch = "#aqua-group-server-docs-switch"
      {view, _html} = mount_athanor(conn, "/aqua")

      settled(
        fn -> has_element?(view, "#aqua-group-server-docs[data-state=answered]") end,
        "docs"
      )

      assert has_element?(view, switch <> "[phx-disable-with]")

      assert has_element?(
               view,
               entry_box("#aqua-group-server-docs", "docs:search") <> "[phx-disable-with]"
             )

      answered =
        view
        |> element(switch)
        |> render_click()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(switch <> ~s([aria-checked="true"][phx-value-on="false"]))

      assert Enum.count(answered) == 1
      Cyfr.Test.Sandbox.end_views()
    end

    # A server turned off is asked nothing and offers nothing to switch on:
    # what the list names of it stays, to be switched off, while another
    # server is still being asked.
    test "a server turned off after it answered offers only what is on, to switch off",
         %{conn: conn, ctx: ctx} do
      {:ok, hold} = Agent.start_link(fn -> true end)
      offering_server!(ctx, "docs", ["search", "fetch"])
      offering_server!(ctx, "held", ["read"], hold: hold)

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tools_add" => ["docs:search"]
        })

      docs = "#aqua-group-server-docs"
      {view, _html} = mount_athanor(conn, "/aqua")
      settled(fn -> has_element?(view, docs <> ~s([data-state="answered"])) end, "answered")

      {:ok, _} =
        Arca.McpServerStorage.update(Sanctum.Context.actor(ctx), "docs", %{enabled: false})

      send(view.pid, {:refresh, :agents})
      settled(fn -> has_element?(view, docs <> ~s([data-state="off"])) end, "turned off")
      assert entries(view, docs) == [{"docs:search", true}]

      assert has_element?(
               view,
               docs <> " summary",
               "turned off, 1 entry kept on for when it is back"
             )

      :ok = Agent.update(hold, fn _ -> false end)
      for {:holding, "held", stub} <- drain_holding(), do: send(stub, :go)
      Cyfr.Test.Sandbox.end_views()
    end

    # A group's switch sets what the list can hold; an entry the list
    # cannot name says why on its own line, and a name that holds what
    # reads as a thread's mark is each turn's to decide. Each server entry
    # carries its kind.
    test "a group's switch sets what the list can hold, and each entry that cannot says why",
         %{conn: conn, ctx: ctx} do
      marked = "cyfr-AAAAAAAAAAAAAAAA"
      offering_server!(ctx, "ns", ["read", "ns:read", marked])

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tools_add" => ["ns:" <> marked]
        })

      {:ok, %{"tools" => before}} = get_agent(ctx, "aqua")
      group = "#aqua-group-server-ns"
      {view, _html} = mount_athanor(conn, "/aqua")

      settled(
        fn ->
          render_async(view, 5_000)
          has_element?(view, group <> ~s( [data-key="ns:#{marked}"] [data-reason="per_thread"]))
        end,
        "each turn decides"
      )

      unlistable = group <> ~s( [data-key="ns:ns:read"])
      assert has_element?(view, unlistable <> " input[disabled]")
      assert has_element?(view, unlistable <> ~s( [data-reason="unlistable"]))
      assert has_element?(view, group <> ~s( [data-key="ns:read"]), "Tool")
      assert has_element?(view, group <> ~s( [data-key="ns:@resources"]), "Resources")

      view |> element(group <> "-switch") |> render_click()
      assert {:ok, %{"tools" => after_switch}} = get_agent(ctx, "aqua")
      assert after_switch == Enum.sort(before ++ ~w(ns:@prompts ns:@resources ns:read))
      Cyfr.Test.Sandbox.end_views()
    end
  end

  # `name`, an MCP server of the athanor's over HTTP that declares tools,
  # resources and prompts and lists `tools` by name, its configuration
  # `:config`. Silent, it answers nothing, and its client gives up on it
  # after half a second. Held, while the Agent `:hold` holds true, each
  # request tells the test `{:holding, name, pid}` and waits for `:go`.
  defp offering_server!(ctx, name, tools, opts \\ []) do
    stub = Cyfr.Test.HTTPStub.open()
    silent? = Keyword.get(opts, :silent, false)
    hold = Keyword.get(opts, :hold)
    test = self()

    Cyfr.Test.HTTPStub.stub(stub, "POST", "/" <> name, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      if hold && Agent.get(hold, & &1) do
        send(test, {:holding, name, self()})
        receive do: (:go -> :ok)
      end

      if silent? do
        # Past the client's half second, so it never reads this.
        receive do: (:never -> :ok), after: (2_000 -> :ok)
        Plug.Conn.resp(conn, 503, "")
      else
        result =
          case body["method"] do
            "server/discover" ->
              %{"capabilities" => %{"tools" => %{}, "resources" => %{}, "prompts" => %{}}}

            "tools/list" ->
              %{
                "tools" =>
                  for(
                    tool <- tools,
                    do: %{
                      "name" => tool,
                      "description" => "The #{tool} of #{name}.",
                      "inputSchema" => %{"type" => "object"}
                    }
                  )
              }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => body["id"], "result" => result})
        )
      end
    end)

    {:ok, _} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        url: "http://127.0.0.1:#{stub.port}/#{name}",
        config_json:
          Jason.encode!(
            Map.merge(
              if(silent?, do: %{"timeout_ms" => 500}, else: %{}),
              Keyword.get(opts, :config, %{})
            )
          )
      })

    on_exit(fn -> Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id) end)
  end

  # The held requests a scripted server has told the test of so far.
  defp drain_holding(held \\ []) do
    receive do
      {:holding, _name, _stub} = holding -> drain_holding([holding | held])
    after
      0 -> held
    end
  end

  # Each entry of a group, by its key, in the page's order, with whether
  # its switch is on.
  defp entries(view, group) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(group <> " [data-key]")
    |> Enum.map(fn entry ->
      [key] = LazyHTML.attribute(entry, "data-key")
      on = entry |> LazyHTML.query("input[type=checkbox][checked]") |> Enum.count()
      {key, on == 1}
    end)
  end

  defp entry_box(group, key),
    do: group <> ~s( [data-key="#{key}"] input[phx-click=editor_toggle_capability])

  # The person's writes of an agent file through the `aqua` tool so far.
  defp aqua_updates(ctx) do
    {:ok, decisions} = Arca.DecisionLog.list(Sanctum.Context.actor(ctx), limit: 500)
    Enum.count(decisions, &(&1.tool == "aqua" and &1.action == "update"))
  end

  # Aqua as it ships, its grant and every shipped source's given, as a
  # person's setup leaves them.
  defp shipped_and_granted!(ctx) do
    Cyfr.Test.SeedBundle.lay!(~w(files http))
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
  end

  # Aqua as it ships, seated on a crew member of its own on the brain
  # `open`, with its one model, which needs nothing of the person, and the
  # crew's grant given.
  defp soul_on_open!(ctx) do
    shipped_and_granted!(ctx)
    open_brain!(ctx)

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "create",
        "name" => "brain",
        "title" => "Brain",
        "catalyst_ref" => "catalyst:local.open",
        "model" => "open-1"
      })

    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{"action" => "update", "name" => "aqua", "member" => "brain"})

    grant!(ctx, Prima.AgentRef.soul_ref(), %{})
  end

  # A section re-reads itself on a message the write sends after it
  # answers, so a card's new state is awaited rather than read at once.
  defp settled(fun, label), do: Prima.Test.Wait.wait_until(fun, 2_000, label)

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

  # The terminal Sign in showed in the card `card`, on this page.
  defp sign_in_terminal!(view, card) do
    screen = card <> ~s( [id$="-screen"][data-session])
    settled(fn -> has_element?(view, screen) end, "the terminal on this page")

    [session] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(screen)
      |> LazyHTML.attribute("data-session")

    assert "trm_" <> _ = session
    session
  end

  # The id of each terminal screen the page shows.
  defp screen_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id$="-screen"][data-session]))
    |> LazyHTML.attribute("id")
  end

  defp ended?(view, card), do: has_element?(view, card <> ~s( [data-test="terminal-ended"]))

  # The program or key `value` chosen in the editor of `member`, once
  # its field offers that one.
  defp harness!(view, member, value) do
    field = "#aqua-card-#{member}-harness"
    unless has_element?(view, field), do: edit!(view, member)

    settled(
      fn -> has_element?(view, field <> ~s( option[value="#{value}"])) end,
      "#{value} offered on the card"
    )

    view |> form(field, %{"harness" => value}) |> render_change()
  end

  # The model `value` chosen on the card of `member`, once its card lists it.
  defp model!(view, member, value) do
    field = "#aqua-card-#{member}-model"

    settled(
      fn -> has_element?(view, field <> ~s( option[value="#{value}"])) end,
      "#{value} listed on the card"
    )

    view |> form(field, %{"value" => value}) |> render_change()
  end

  # The editor of `member`, opened by its press.
  defp edit!(view, member) do
    edit = ~s(#aqua-card-#{member}-edit)
    settled(fn -> has_element?(view, edit) end, "#{member}'s Edit")
    view |> element(edit) |> render_click()
  end

  # The form that makes a crew member, opened by its press.
  defp new_member!(view, form) do
    settled(
      fn -> has_element?(view, form) or has_element?(view, form <> "-open") end,
      "New crew member"
    )

    unless has_element?(view, form), do: view |> element(form <> "-open") |> render_click()
  end

  # What the service was asked so far, dropped.
  defp flush_sessions do
    receive do
      {:session, _op, _message, _fields} -> flush_sessions()
    after
      0 -> :ok
    end
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

  # The form `form` with a name and a harness or key chosen, once the form
  # offers that one.
  defp choose!(view, form, name, brain) do
    new_member!(view, form)

    settled(
      fn -> has_element?(view, form <> ~s( select[name="brain"] option[value="#{brain}"])) end,
      "#{brain} offered"
    )

    view |> form(form, %{"name" => name, "brain" => brain}) |> render_change()
  end

  # A crew member made in `form`: its name, its harness or key and a model
  # that one lists; what the page then says.
  defp make!(view, form, name, brain, model) do
    choose!(view, form, name, brain)

    view
    |> form(form, %{"name" => name, "brain" => brain, "model" => model})
    |> render_submit()
  end

  # The brain `open` installed and granted, as the card's read of a
  # brain's options lists it, with two models and the options its
  # `describe` declares for each.
  defp described_open!(ctx, options_by_model) do
    Arca.Test.UnitFixtures.tenant_component!(ctx, "catalyst", "local", "open", "0.1.0",
      manifest: %{
        "name" => "open",
        "type" => "catalyst",
        "version" => "0.1.0",
        "publisher" => "local",
        "contracts" => [Prima.Model.chat_contract()]
      },
      wasm: Cyfr.Test.Guests.wasm(:catalyst)
    )

    grant!(ctx, "catalyst:local.open", %{bindings: []})

    remember_catalogue!(%{"open" => ["open-1", "open-2"]}, %{
      "open" => "catalyst:local.open:0.1.0"
    })

    described!(ctx, "catalyst:local.open:0.1.0", options_by_model)
  end

  # The brain `open`, which needs nothing of the person, granted, with the
  # one model the kept catalogue lists for it.
  defp open_brain!(ctx) do
    publish_brain!(ctx, "open", %{})
    grant!(ctx, "catalyst:local.open", %{bindings: []})
    remember_catalogue!(%{"open" => ["open-1"]}, %{"open" => "catalyst:local.open:0.1.0"})
  end

  # The person's post to `member`, in its own thread off a room, answered
  # on the brain `open`, a worker playing the brain's answer, under the
  # crew's grant as the fill mints it.
  defp answered_on_open!(ctx, member) do
    ref = "catalyst:local.open"
    Cyfr.Test.SeedBundle.lay!(~w(files http))
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    :ok = Arca.Overlay.pull_shipped(Sanctum.Context.actor(ctx), Compendium.AquaPath.soul_file())
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, _} = Sanctum.Consent.Bootstrap.run(ctx)
    grant!(ctx, Prima.AgentRef.soul_ref(), %{})
    Cyfr.Test.ScriptedWorker.fresh_limits!(ctx, [ref])

    start_supervised!(
      {Cyfr.Test.ScriptedWorker,
       ref: [ref],
       script: [
         %{
           "content" => [%{"type" => "text", "text" => "Hello from open."}],
           "stop_reason" => "end_turn",
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }
       ]}
    )

    actor = Sanctum.Context.actor(ctx)
    {:ok, room} = Arca.Test.Days.thread(actor)
    {:ok, thread} = Aqua.Tape.crew_thread(ctx, room.id, member)

    assert {:ok, %{accepted: true, admitted: :turn, turn_id: turn_id}} =
             Aqua.Runner.send_message(%{ctx | origin: :interactive}, thread.id, "hello")

    Prima.Test.Wait.wait_until(
      fn ->
        {:ok, %{status: status}} = Aqua.Tape.turn(ctx, turn_id)
        status in Prima.TurnState.terminal_statuses()
      end,
      30_000,
      "the member's turn to end"
    )

    assert {:ok, %{status: "completed", error: nil}} = Aqua.Tape.turn(ctx, turn_id)

    assert ["Hello from open."] =
             for(
               %{turn_id: ^turn_id, sent_by: ^member, kind: "text", content: said} <-
                 Arca.ThreadStorage.messages(actor, thread.id),
               do: said
             )
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
    %{"id" => "default", "name" => "Default (recommended)", "efforts" => ["low", "high", "max"]},
    %{"id" => "opus", "name" => "Opus", "efforts" => ["low", "high", "max"]},
    %{"id" => "haiku", "name" => "Haiku", "efforts" => ["low", "high", "max"]}
  ]

  # Plays the driver of `row` for every listing a page asks of it, a new
  # driver process each, until `shown` holds: its hello, as the row's
  # driver, once the session stands, then the models `listing` names and
  # each one's efforts, signed in by the account member; or, for
  # `{:signed_out, sentence}`, the refusal a program with no sign-in
  # answers, that member signed out; or, for `{:refused, sentence}`, a
  # refusal that says nothing of the account.
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

          {:session, "recv", %{"after" => 0, "session" => session}, _fields} ->
            # A hello lands in every running session of the row's, so a read
            # of one that has ended since gets none.
            if match?(
                 %{^session => %{running: true}},
                 Cyfr.Test.ScriptedBackends.sessions(fake, home)
               ) do
              say(fake, row, %{
                "t" => "hello",
                "v" => Opus.Brain.Wire.version(),
                "driver" => Arca.McpServerStorage.driver(row),
                "boot" => "b#{System.unique_integer([:positive])}"
              })
            end

          {:session, "send", %{"lines" => [line]}, _fields} ->
            case Jason.decode!(line) do
              %{"t" => "models", "id" => id} ->
                say(fake, row, listed(id, listing, row))

              _another ->
                :ok
            end
        after
          100 -> :ok
        end

        lists!(fake, row, shown, listing, deadline)
    end
  end

  # Plays the driver of each of `rows` for every listing a page asks of
  # it, each answering for its own row, until `shown` holds.
  defp lists_each!(fake, rows, shown),
    do: lists_each!(fake, rows, shown, System.monotonic_time(:millisecond) + 10_000)

  defp lists_each!(fake, rows, shown, deadline) do
    by_id = Map.new(rows, &{&1.id, &1})

    cond do
      shown.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the page did not show what its programs' listings said")

      true ->
        receive do
          {:session, "recv", %{"after" => 0}, %{server: server}} when is_map_key(by_id, server) ->
            row = by_id[server]

            say(fake, row, %{
              "t" => "hello",
              "v" => Opus.Brain.Wire.version(),
              "driver" => Arca.McpServerStorage.driver(row),
              "boot" => "b#{System.unique_integer([:positive])}"
            })

          {:session, "send", %{"lines" => [line]}, %{server: server}}
          when is_map_key(by_id, server) ->
            case Jason.decode!(line) do
              %{"t" => "models", "id" => id} ->
                say(fake, by_id[server], listed(id, @listing, by_id[server]))

              _another ->
                :ok
            end
        after
          100 -> :ok
        end

        lists_each!(fake, rows, shown, deadline)
    end
  end

  # Plays the driver of `row` for Aqua's turn on it until `done` holds: its
  # hello, the harness started, the turn's work and its post taken, `said`
  # said and the post answered; a listing asked meanwhile is answered.
  defp answers!(fake, row, said, done),
    do: answers!(fake, row, said, done, System.monotonic_time(:millisecond) + 30_000)

  defp answers!(fake, row, said, done, deadline) do
    cond do
      done.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Aqua's turn on the program did not complete")

      true ->
        receive do
          {:session, "recv", %{"after" => 0}, _fields} ->
            say(fake, row, %{
              "t" => "hello",
              "v" => Opus.Brain.Wire.version(),
              "driver" => Arca.McpServerStorage.driver(row),
              "boot" => "b#{System.unique_integer([:positive])}"
            })

          {:session, "send", %{"lines" => [line]}, _fields} ->
            answer!(fake, row, said, Jason.decode!(line))
        after
          100 -> :ok
        end

        answers!(fake, row, said, done, deadline)
    end
  end

  # The driver's answer to one line the holder wrote it.
  defp answer!(fake, row, said, %{"t" => t} = line) do
    cond do
      t == "models" ->
        say(fake, row, listed(line["id"], @listing, row))

      # A start's scrolls, each kept to the model's harness's way.
      t == "scroll" ->
        say(fake, row, %{"t" => "yielded", "id" => line["id"]})

      t == "start" ->
        send(self(), {:driver_start, line})

        say(fake, row, %{
          "t" => "started",
          "session" => "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
          "fresh" => true,
          "held" => []
        })

      t == "work" ->
        say(fake, row, %{"t" => "accepted", "id" => line["id"]})

      t == "post" ->
        %{"id" => id, "work" => work} = line
        say(fake, row, %{"t" => "accepted", "id" => id})

        say(fake, row, %{
          "t" => "said",
          "gen" => 0,
          "work" => work,
          "message" => "msg_1",
          "text" => said
        })

        say(fake, row, %{
          "t" => "idle",
          "gen" => 0,
          "work" => work,
          "answered" => [id],
          "stop" => "end_turn"
        })

      true ->
        :ok
    end
  end

  # What the catalyst `resolved` declares in its `describe` of each model,
  # by the options of each, as the capabilities it was read for keep it
  # (`Aqua.Models.capabilities/5`), forgotten when the test ends.
  defp described!(ctx, resolved, options_by_model) do
    on_exit(fn -> Arca.Cache.delete_match({:model_caps, ctx.athanor_id, :_, :_, :_}) end)

    for {model, options} <- options_by_model,
        do:
          Arca.Cache.put(
            {:model_caps, ctx.athanor_id, resolved, model, nil},
            %{options: options},
            600_000
          )

    :ok
  end

  # Aqua's grant as it is stored: each of its profiles with the head
  # consent it holds, whole.
  defp aqua_grant!(actor) do
    {:ok, profiles} = Arca.ConsentStorage.profiles(actor, Prima.AgentRef.soul_ref())

    for profile <- profiles do
      {:ok, head, refs} = Arca.ConsentStorage.get_head(actor, profile.id)
      {profile, head, refs}
    end
  end

  defp listed(id, {:refused, sentence}, _row),
    do: %{"t" => "refused", "id" => id, "reason" => sentence}

  defp listed(id, {:signed_out, sentence}, _row),
    do: %{"t" => "refused", "id" => id, "reason" => sentence, "account" => "signed_out"}

  defp listed(id, models, row),
    do: %{
      "t" => "models",
      "id" => id,
      "models" => models,
      "access" => driver_access(Arca.McpServerStorage.driver(row)),
      "account" => "signed_in"
    }

  # The one access choice each shipped driver lists, in its own words, as
  # the driver answers a listing (apps/locus/keeper/cmd).
  defp driver_access("cyfr-claude-code" <> _rest),
    do: [%{"id" => "default", "name" => "Default mode"}]

  defp driver_access("cyfr-codex" <> _rest),
    do: [%{"id" => "full-access", "name" => "Full access, no approvals"}]

  defp driver_access("cyfr-antigravity" <> _rest),
    do: [%{"id" => "full-access", "name" => "Full access, no approvals"}]

  defp driver_access("cyfr-opencode" <> _rest),
    do: [%{"id" => "full-access", "name" => "Full access, no approvals"}]

  defp driver_access("cyfr-cursor" <> _rest),
    do: [%{"id" => "full-access", "name" => "Full access, no approvals"}]

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
