# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLiveTest do
  # The AQUA page shows the tree of the estate in focus — a person's own
  # on their page, the group's on the group's — and every write lands
  # there through the `aqua` and `notes` tools. These drive the LiveView
  # itself: the AgentConfig-level test cannot catch a handler that reads
  # the wrong context or a card that offers a verb the tool refuses.
  use PrismWeb.ConnCase, async: false

  alias Aqua.AgentConfig

  setup do
    test_path = Path.join(System.tmp_dir!(), "aqua_live_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    :ok
  end

  defp get_agent(ctx, name), do: AgentConfig.call_aqua(ctx, %{"action" => "get", "name" => name})

  test "a group's page shows the group's tree alone, and a person's page edits their own",
       %{conn: conn} do
    user = test_user()
    n = System.unique_integer([:positive])

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me-al#{n}",
        owner_user_id: user.user_id,
        created_by: user.user_id
      })

    {:ok, group} = Sanctum.Tenancy.Athanors.create_group(user.user_id, "Acme #{n}")
    conn = log_in_user(conn, user, athanor_id: group.id)

    {:ok, u} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)

    {:ok, _} =
      Sanctum.Tenancy.Members.ensure(user.user_id, scope: "athanor", athanor_id: mine.id)

    mine_ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: mine.id}
    group_ctx = %{mine_ctx | athanor_id: group.id}

    {:ok, _} =
      AgentConfig.call_aqua(mine_ctx, %{
        "action" => "create",
        "name" => "tom",
        "title" => "Tom",
        "content" => "# Tom"
      })

    refute Arca.exists?(group_ctx, Compendium.AquaPath.agent_file("tom"))

    # The group's page: no closet picker, no personal role.
    {_view, html} = mount_athanor(conn, "/aqua", group)
    refute html =~ "in your athanor"
    refute html =~ "aqua-card-tom"
    refute html =~ ~s(name="owner")

    # The person's own page: their tree, and a write lands in it alone.
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
    refute Arca.exists?(group_ctx, Compendium.AquaPath.agent_file("tom"))
  end

  # Point the soul at `ref`, and put it back afterwards: the agent files live
  # in the suite's shared tree, so a write left behind is the next test's
  # starting state.
  defp soul_names_catalyst!(ctx, ref) do
    {:ok, soul} = Aqua.AgentConfig.agent(ctx, "aqua")
    was = soul["catalyst_ref"] || ""

    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ref
      })

    on_exit(fn ->
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => was
      })
    end)

    :ok
  end

  defp soul_names_missing_catalyst!(ctx),
    do: soul_names_catalyst!(ctx, "catalyst:moonmoon69.claude")

  # Minimal valid WASM with a `run` export — enough to publish a row, which
  # is what a pull that lands leaves behind.
  @wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
          <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
          <<0x03, 0x02, 0x01, 0x00>> <>
          <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
          <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

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

  describe "the estate's page" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      estate = seated_athanor()
      ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: estate.id}
      {:ok, conn: conn, ctx: ctx, estate: estate}
    end

    test "the soul offers no Delete; a shipped role is disabled and enabled from its card",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")

      refute has_element?(view, "#aqua-card-aqua button[phx-click=editor_delete]")
      refute has_element?(view, "#aqua-card-aqua button[phx-click=editor_set_disabled]")

      # Shipped and unedited: no Delete, a Disable.
      assert has_element?(view, "#aqua-card-planner", "shipped")
      refute has_element?(view, "#aqua-card-planner button[phx-click=editor_delete]")

      view
      |> element("#aqua-card-planner button[phx-click=editor_set_disabled]", "Disable")
      |> render_click()

      assert {:ok, %{"disabled" => true}} = get_agent(ctx, "planner")

      # Still on the page — `list` drops it, the page does not — as
      # disabled, edited, and with the way back.
      assert has_element?(view, "#aqua-card-planner", "disabled")
      assert has_element?(view, "#aqua-card-planner", "edited")

      assert has_element?(
               view,
               "#aqua-card-planner button[phx-click=editor_revert]",
               "Revert to shipped"
             )

      view
      |> element("#aqua-card-planner button[phx-click=editor_set_disabled]", "Enable")
      |> render_click()

      assert {:ok, %{"disabled" => false}} = get_agent(ctx, "planner")
    end

    test "restoring the shipped files reverts an edited soul and keeps what the estate made",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"title" => shipped_title}} = get_agent(ctx, "aqua")

      {:ok, _} =
        AgentConfig.call_aqua(ctx, %{"action" => "update", "name" => "aqua", "title" => "Mine"})

      {:ok, _} =
        AgentConfig.call_aqua(ctx, %{"action" => "create", "name" => "scout", "content" => "# S"})

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "Restore shipped files"

      view |> element("#aqua-restore button[phx-click=restore_shipped]") |> render_click()

      assert {:ok, %{"title" => ^shipped_title}} = get_agent(ctx, "aqua")
      assert {:ok, %{"name" => "scout"}} = get_agent(ctx, "scout")

      html = render(view)
      assert html =~ "aqua/aqua.md"
      assert html =~ "aqua/roles/scout.md"
      assert has_element?(view, "#aqua-restore-result", "Kept (1)")
    end

    test "removing everything the estate made deletes a member-made role too",
         %{conn: conn, ctx: ctx} do
      {:ok, _} =
        AgentConfig.call_aqua(ctx, %{"action" => "create", "name" => "scout", "content" => "# S"})

      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-scout", "yours")

      view |> element("#aqua-restore button[phx-click=restore_all]") |> render_click()

      assert {:error, _} = get_agent(ctx, "scout")
      refute has_element?(view, "#aqua-card-scout")
      assert has_element?(view, "#aqua-restore-result", "aqua/roles/scout.md")
    end

    test "a new role starts with a role's hands, and the soul is given leave to clone into it",
         %{conn: conn, ctx: ctx} do
      {:ok, %{"tool_policy" => planner_policy}} = get_agent(ctx, "planner")
      assert map_size(planner_policy) > 0

      {view, html} = mount_athanor(conn, "/aqua")

      # The most restrictive role is the default start.
      assert html =~ ~s(<option value="planner" selected)

      view
      |> form("form[phx-submit=editor_create_role]", %{
        "name" => "scout",
        "start_from" => "planner"
      })
      |> render_submit()

      assert {:ok, %{"tool_policy" => ^planner_policy}} = get_agent(ctx, "scout")
      assert {:ok, %{"tool_policy" => %{"scout.*" => "auto"}}} = get_agent(ctx, "aqua")
      assert render(view) =~ "the soul may now clone into it"

      # The soul card shows the leave, and the toggle takes it back.
      assert has_element?(view, "#aqua-clone-strip input[phx-value-role=scout][checked]")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_clone", %{"role" => "scout"})

      {:ok, %{"tool_policy" => soul_policy}} = get_agent(ctx, "aqua")
      refute Map.has_key?(soul_policy, "scout.*")
      refute has_element?(view, "#aqua-clone-strip input[phx-value-role=scout][checked]")

      # A role the roster does not hold cannot be named.
      assert view
             |> with_target("#aqua-agents")
             |> render_click("editor_toggle_clone", %{
               "role" => "nobody"
             }) =~
               "Unknown role: nobody"
    end

    test "the pinned page is written from the page and is what the soul reads",
         %{conn: conn, ctx: ctx} do
      # The estate here is the person's own, so its one pinned page is
      # `about-you`; a shared estate's is `about-us`.
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
        AgentConfig.call_aqua(ctx, %{"action" => "skill_list"})

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
               AgentConfig.call_aqua(ctx, %{"action" => "skill_get", "name" => shipped["name"]})

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
               AgentConfig.call_aqua(ctx, %{"action" => "skill_get", "name" => "pdf-forms"})

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
               AgentConfig.call_aqua(ctx, %{"action" => "skill_get", "name" => "pdf-forms"})

      # The estate's own scroll is deleted, with the verb spelled as such.
      assert has_element?(view, "#aqua-scroll-open button[phx-click=skill_delete]", "Delete")

      view
      |> with_target("#aqua-scrolls-section")
      |> render_click("skill_delete", %{"name" => "pdf-forms"})

      assert {:error, _} =
               AgentConfig.call_aqua(ctx, %{"action" => "skill_get", "name" => "pdf-forms"})

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
            "start with no hands",
            "+ New role"
          ] do
        refute html =~ line, "the dead render says #{inspect(line)}"
      end

      # Loaded, the sections are there, and the form with them.
      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "Shipped files"
      assert has_element?(view, "#aqua-about")
      assert has_element?(view, "#aqua-notes")
      assert has_element?(view, "#aqua-scrolls")
      assert has_element?(view, "form[phx-submit=editor_create_role]")
    end

    test "a catalyst the estate does not hold is offered an Install, which refuses without a registry",
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

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "not installed here yet"
      assert has_element?(view, "button[phx-click=install_catalyst]")

      # With no registry the refusal is the outcome, and it never became a
      # request: `Compendium.Pull` asks before it resolves a tag.
      assert {:error, %Compendium.OCI.Errors{reason: :registry_unconfigured}} =
               Compendium.Pull.oci_reference_for("catalyst:moonmoon69.claude")

      view
      |> element("button[phx-click=install_catalyst]")
      |> render_click()

      html = render(view)
      assert html =~ "Could not install"

      # The button comes back: a refused fetch must not leave the page
      # showing "Installing…" with nothing to click.
      refute html =~ "Installing…"
      assert has_element?(view, "button[phx-click=install_catalyst]:not([disabled])")
    end

    test "an install that lands leaves the model asking for a key, not asking to be installed",
         %{conn: conn, ctx: ctx} do
      ref = "catalyst:local.newmodel"
      :ok = soul_names_catalyst!(ctx, ref)

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "not installed here yet"

      # What a pull that succeeds leaves behind: the row, with a required
      # need and no consent bound to it yet.
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
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
                  "required" => true
                }
              }
            })
        })

      send(view.pid, {:catalyst_installed, ref, {:ok, %{}}})

      html = settled_render(view)
      assert html =~ "Installed #{ref}."
      refute html =~ "not installed here yet"
      assert html =~ "the model has no key yet"
      refute has_element?(view, "button[phx-click=install_catalyst]")

      # And the way on is live: the sheet opens on the release that landed.
      view
      |> element("button[phx-click=open_consent]", "Connect a model")
      |> render_click()

      html = render(view)
      assert html =~ "#{ref}:0.1.0"
      assert html =~ "to call the model with your key"
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
      estate = seated_athanor()

      :ok =
        PrismWeb.ModelCatalog.remember(estate.id, %{"models" => %{"kept" => ["kept-model-1"]}})

      on_exit(fn -> PrismWeb.ModelCatalog.forget(estate.id) end)

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "kept-model-1"

      send(view.pid, {:consent_granted, "catalyst:local.http:1.1.0", %{}})
      assert render(view) =~ "Model connected."

      # The kept entry is gone: a load from here finds no hit to hand back.
      PrismWeb.ModelCatalog.load(ctx)
      refute_received {:list_models_result, {:ok, _}}
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

    test "the page writes what an agent can hold: auto on a role, ask on the soul, never a destructive auto",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")

      # A write-kind hand: a role holds it at auto (it has no card to
      # raise), the soul at ask.
      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{
        "name" => "web",
        "key" => "files.write"
      })

      assert {:ok, %{"tool_policy" => %{"files.write" => "auto"}}} = get_agent(ctx, "web")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{
        "name" => "aqua",
        "key" => "files.write"
      })

      assert {:ok, %{"tool_policy" => %{"files.write" => "ask"}}} = get_agent(ctx, "aqua")

      # A destructive hand is never a role's, and never auto on the soul.
      html =
        view
        |> with_target("#aqua-agents")
        |> render_click("editor_toggle_capability", %{
          "name" => "web",
          "key" => "files.delete"
        })

      assert html =~ "no card to raise"
      assert {:ok, %{"tool_policy" => policy}} = get_agent(ctx, "web")
      refute Map.has_key?(policy, "files.delete")

      html =
        view
        |> with_target("#aqua-agents")
        |> render_click("editor_set_capability_mode", %{
          "name" => "aqua",
          "key" => "files.delete",
          "mode" => "auto"
        })

      assert html =~ "always asks"
      assert {:ok, %{"tool_policy" => %{"files.delete" => "ask"}}} = get_agent(ctx, "aqua")

      # And a role is never demoted to ask.
      html =
        view
        |> with_target("#aqua-agents")
        |> render_click("editor_set_capability_mode", %{
          "name" => "web",
          "key" => "files.write",
          "mode" => "ask"
        })

      assert html =~ "no card to raise"
      assert {:ok, %{"tool_policy" => %{"files.write" => "auto"}}} = get_agent(ctx, "web")
    end

    test "a shipped role's policy round-trips through untick and tick unchanged", %{
      conn: conn,
      ctx: ctx
    } do
      {view, _html} = mount_athanor(conn, "/aqua")
      {:ok, %{"tool_policy" => shipped}} = get_agent(ctx, "builder")
      assert shipped["files.write"] == "auto"

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{
        "name" => "builder",
        "key" => "files.write"
      })

      assert {:ok, %{"tool_policy" => without}} = get_agent(ctx, "builder")
      refute Map.has_key?(without, "files.write")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_capability", %{
        "name" => "builder",
        "key" => "files.write"
      })

      assert {:ok, %{"tool_policy" => ^shipped}} = get_agent(ctx, "builder")
    end

    test "the matrix tells the truth: a role's hands run in the role, and it is offered no destructive row",
         %{conn: conn} do
      {view, _html} = mount_athanor(conn, "/aqua")
      html = render(view)

      # The builder's card says its hands run in the role; the soul's card
      # keeps the ask/auto pill and says destructive always asks.
      assert html =~ "runs in this role"
      assert html =~ "always asks"
    end

    test "an allowlist edit lands on the policy as it is now, not on the copy the page loaded",
         %{conn: conn, ctx: ctx} do
      {view, _html} = mount_athanor(conn, "/aqua")

      # Another member's edit, after this page read the soul.
      {:ok, %{"tool_policy" => theirs}} = get_agent(ctx, "aqua")
      theirs = Map.put(theirs, "vault.list", "ask")

      {:ok, _} =
        AgentConfig.call_aqua(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tool_policy" => theirs
        })

      # Creating a role gives the soul leave to clone into it…
      view
      |> form("form[phx-submit=editor_create_role]", %{"name" => "scout", "start_from" => ""})
      |> render_submit()

      assert {:ok, %{"tool_policy" => %{"scout.*" => "auto", "vault.list" => "ask"} = policy}} =
               get_agent(ctx, "aqua")

      # …and a toggle on the soul's card, after yet another edit, keeps both.
      {:ok, _} =
        AgentConfig.call_aqua(ctx, %{
          "action" => "update",
          "name" => "aqua",
          "tool_policy" => Map.put(policy, "vault.get", "ask")
        })

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_clone", %{"role" => "scout"})

      {:ok, %{"tool_policy" => after_toggle}} = get_agent(ctx, "aqua")
      refute Map.has_key?(after_toggle, "scout.*")
      assert after_toggle["vault.list"] == "ask"
      assert after_toggle["vault.get"] == "ask"
    end
  end
end
