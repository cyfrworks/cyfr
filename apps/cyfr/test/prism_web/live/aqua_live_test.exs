# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A store that cannot give the AQUA crew listing; every other read is the
# local adapter's.
defmodule PrismWeb.AquaLiveTest.UnreadableCrew do
  @moduledoc false
  use Arca.Storage.TestDouble

  @crew Compendium.AquaPath.crew_root()

  def list_typed(_actor, @crew), do: {:error, :eacces}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

defmodule PrismWeb.AquaLiveTest do
  # The AQUA page shows the tree of the person's own athanor, and every
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

      assert %{"install" => "catalyst:local.harness", "need" => "claude"} =
               URI.decode_query(URI.parse(href).query)
    end

    # A brain that mounts a program's own sign-in: bound, it waits on that
    # sign-in, and only a sign-in whose command exited 0 connects it.
    test "a crew member whose brain mounts a login reads Program not signed in until its " <>
           "program signs in, then Model connected",
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
      :ok = Arca.put(actor, Compendium.AquaPath.soul_file(), "---\ntitle: AQUA\n---\n\nsoul\n")

      :ok =
        Arca.put(
          actor,
          Compendium.AquaPath.crew_file("harness"),
          "---\ncatalyst_ref: #{ref}\nmodel: harness-model\n---\n\nYou run the harness.\n"
        )

      {:ok, _} = Compendium.AgentIndex.sync(ctx)

      {:ok, entry} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "claude-login",
          kind: "login",
          program: "claude"
        })

      grant!(ctx, ref, %{bindings: [%{need: "claude", entry_id: entry.id}]})

      grant!(ctx, Prima.AgentRef.ref("harness"), %{
        selections: [%{dep: ref, need: "claude", entry_id: entry.id}]
      })

      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-harness", "Program not signed in")
      refute has_element?(view, "#aqua-card-harness", "Model connected")

      # The sign-in whose command exited 0.
      :ok = Sanctum.Mount.signed_in(ctx, entry.id)
      send_update_agents(view, load: true)

      assert has_element?(view, "#aqua-card-harness", "Model connected")
      refute has_element?(view, "#aqua-card-harness", "Program not signed in")
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

    test "a new crew member is a name: it runs under the soul's policy and holds none of its own",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"tool_policy" => soul_policy}} = get_agent(ctx, "aqua")

      {view, _html} = mount_athanor(conn, "/aqua")

      html =
        view
        |> form("form[phx-submit=editor_create_member]", %{"name" => "scout"})
        |> render_submit()

      assert html =~ "Added &#39;scout&#39; to the crew"
      assert {:ok, %{"type" => "crew", "tool_policy" => ^soul_policy}} = get_agent(ctx, "scout")
      assert {:ok, %{"tool_policy" => ^soul_policy}} = get_agent(ctx, "aqua")

      {:ok, bytes} =
        Arca.get(Sanctum.Context.actor(ctx), Compendium.AquaPath.crew_file("scout"))

      refute bytes =~ "tool_policy"

      # Its card says what it is good at and what to avoid, and edits no
      # capabilities: those are the soul's.
      settled(fn -> has_element?(view, "#aqua-card-scout") end, "the scout card")
      assert has_element?(view, "#aqua-card-scout-description")
      assert has_element?(view, "#aqua-card-scout-avoid")
      assert has_element?(view, "#aqua-card-scout", "Runs under the soul's capabilities")
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
      assert html =~ "Loading AQUA…"

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
               "The agents cannot be read right now — try again."
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

    test "a catalyst the athanor does not hold is offered an Install, which refuses without a registry",
         %{conn: conn, ctx: ctx} do
      # The soul names a model catalyst nothing here holds: the page says so
      # and offers to fetch it, rather than leaving a dead end.
      :ok = soul_names_missing_catalyst!(ctx)

      previous = Application.get_env(:cyfr, :registry_url)
      Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())

      on_exit(fn ->
        if previous,
          do: Application.put_env(:cyfr, :registry_url, previous),
          else: Application.delete_env(:cyfr, :registry_url)
      end)

      # The soul's card: a crew member whose brain is not here says so on
      # its own card.
      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-aqua", "not installed here yet")
      assert has_element?(view, "#aqua-card-aqua button[phx-click=install_catalyst]")

      # With no registry the refusal is the outcome, and it never became a
      # request: `Compendium.Pull` asks before it resolves a tag.
      assert {:error, %Compendium.OCI.Errors{reason: :registry_unconfigured}} =
               Compendium.Pull.oci_reference_for("catalyst:moonmoon69.claude")

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

      # The fetch has answered; it is gone before the registry setting it
      # read is restored and before the sandbox it queried is released.
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

      # And the way on is live: the grant opens on the release that landed,
      # in the page's system layer and nowhere on the page.
      view
      |> element("#aqua-card-aqua button[phx-click=open_consent]", "Connect a model")
      |> render_click()

      html = render(view)
      assert html =~ "#{ref}:0.1.0"
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
      refute has_element?(view, "button[phx-click=open_consent]", "Connect a model")

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

      refute has_element?(view, "button[phx-click=open_consent]", "Connect a model")

      Cyfr.Test.Sandbox.end_views()
    end

    test "connecting a model binds the key in the system layer, and the page says it is connected",
         %{conn: conn, ctx: ctx} do
      ref = "catalyst:local.keyed"
      :ok = soul_names_catalyst!(ctx, ref)

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
          name: "keyed",
          version: "0.1.0",
          type: "catalyst",
          description: "A model catalyst",
          manifest:
            Jason.encode!(%{
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

      {view, _html} = mount_athanor(conn, "/aqua")

      view
      |> element("button[phx-click=open_consent]", "Connect a model")
      |> render_click()

      # No sheet on the page itself: the grant is the layer's.
      refute has_element?(view, "#consent-sheet-dialog")
      assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))

      view
      |> element(
        ~s(#system-layer-dialog [data-test="grant-pick"][phx-value-entry_id="#{entry.id}"])
      )
      |> render_click()

      render(view)
      view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

      # The layer asks its sheet for the walk, then commits.
      Prima.Test.Wait.wait_until(fn -> render(view) =~ "Model connected." end, 5_000, "the grant")
      refute has_element?(view, ~s(#system-layer-dialog [data-kind="grant"]))

      {:ok, [%{id: profile_id} | _]} = Sanctum.Consent.profiles(ctx, ref)
      {:ok, head} = Sanctum.Consent.head_consent(ctx, profile_id)
      assert Enum.any?(head.vault_refs, &(&1.vault_entry_id == entry.id))
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
      Prima.Test.Wait.wait_until(fn -> render(view) =~ "Model connected." end, 5_000, "the grant")

      # The kept entry is gone: a load from here finds no hit to hand back,
      # whatever a fresh run answers.
      PrismWeb.ModelCatalog.load(ctx)
      refute_received {:list_models_result, _tag, {:ok, %{"models" => %{"kept" => _}}}}
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

    test "the page writes the soul's policy, never a destructive auto; a crew member holds none",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")
      agents = with_target(view, "#aqua-agents")
      {:ok, %{"tool_policy" => before}} = get_agent(ctx, "aqua")
      refute Map.has_key?(before, "storage.write")

      # A write-kind hand starts at ask, and moves between ask and auto.
      render_click(agents, "editor_toggle_capability", %{
        "name" => "aqua",
        "key" => "storage.write"
      })

      assert {:ok, %{"tool_policy" => %{"storage.write" => "ask"}}} = get_agent(ctx, "aqua")

      for mode <- ["auto", "ask"] do
        render_click(agents, "editor_set_capability_mode", %{
          "name" => "aqua",
          "key" => "storage.write",
          "mode" => mode
        })

        assert {:ok, %{"tool_policy" => %{"storage.write" => ^mode}}} = get_agent(ctx, "aqua")
      end

      # A destructive hand is never auto.
      html =
        render_click(agents, "editor_set_capability_mode", %{
          "name" => "aqua",
          "key" => "files.delete",
          "mode" => "auto"
        })

      assert html =~ "always asks"
      assert {:ok, %{"tool_policy" => %{"files.delete" => "ask"}}} = get_agent(ctx, "aqua")

      # A crew member runs under the soul's policy: the soul's edit is its
      # too, and a write of its own is refused.
      assert {:ok, %{"tool_policy" => %{"storage.write" => "ask"}}} = get_agent(ctx, "explorer")

      html =
        render_click(agents, "editor_toggle_capability", %{
          "name" => "explorer",
          "key" => "storage.list"
        })

      assert html =~ "runs under the soul&#39;s tool policy"
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

    test "the capability matrix is the soul's alone: the ask/auto pill and the destructive row",
         %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(
               view,
               ~s(#aqua-card-aqua button[phx-click=editor_set_capability_mode][phx-value-key="files.write"])
             )

      assert has_element?(view, ~s(#aqua-card-aqua input[phx-value-key="files.delete"]))
      refute has_element?(view, ~s(#aqua-card-explorer input[phx-value-key="files.delete"]))
    end

    test "an allowlist edit lands on the policy as it is now, not on the copy the page loaded",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")

      # Another member's edit, after this page read the soul.
      {:ok, %{"tool_policy" => theirs}} = get_agent(ctx, "aqua")
      theirs = Map.put(theirs, "vault.list", "ask")

      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tool_policy" => theirs
        })

      # A toggle on the soul's card keeps it…
      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{"name" => "aqua", "key" => "storage.write"})

      assert {:ok,
              %{"tool_policy" => %{"storage.write" => "ask", "vault.list" => "ask"} = policy}} =
               get_agent(ctx, "aqua")

      # …and another, after yet another edit, keeps both.
      {:ok, _} =
        Cyfr.Test.AquaTool.call(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tool_policy" => Map.put(policy, "vault.get", "ask")
        })

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{"name" => "aqua", "key" => "storage.write"})

      {:ok, %{"tool_policy" => after_toggle}} = get_agent(ctx, "aqua")
      refute Map.has_key?(after_toggle, "storage.write")
      assert after_toggle["vault.list"] == "ask"
      assert after_toggle["vault.get"] == "ask"
    end
  end

  # A section re-reads itself on a message the write sends after it
  # answers, so a card's new state is awaited rather than read at once.
  defp settled(fun, label), do: Prima.Test.Wait.wait_until(fun, 2_000, label)

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
