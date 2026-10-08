# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# A store that cannot give the AQUA roles listing; every other read is the
# local adapter's.
defmodule PrismWeb.AquaLiveTest.UnreadableRoles do
  @moduledoc false
  use Arca.Storage.TestDouble

  @roles Compendium.AquaPath.roles_root()

  def list_typed(_actor, @roles), do: {:error, :eacces}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)
end

# A store that answers, and holds no soul and no role.
defmodule PrismWeb.AquaLiveTest.EmptyAqua do
  @moduledoc false
  use Arca.Storage.TestDouble

  @roles Compendium.AquaPath.roles_root()
  @soul Compendium.AquaPath.soul_file()

  def list_typed(_actor, @roles), do: {:ok, []}
  def list_typed(actor, path), do: Arca.Adapters.Local.list_typed(actor, path)

  def get(_actor, @soul), do: {:error, :not_found}
  def get(actor, path), do: Arca.Adapters.Local.get(actor, path)
end

defmodule PrismWeb.AquaLiveTest do
  # The AQUA page shows the tree of the athanor in focus — a person's own
  # on their page, the group's on the group's — and every write lands
  # there through the `aqua` and `notes` tools. These drive the LiveView
  # itself: the AgentConfig-level test cannot catch a handler that reads
  # the wrong context or a card that offers a verb the tool refuses.
  use PrismWeb.ConnCase, async: false

  alias Aqua.AgentConfig

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

  defp get_agent(ctx, name), do: AgentConfig.call_aqua(ctx, %{"action" => "get", "name" => name})

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

    refute Arca.exists?(Sanctum.Context.actor(group_ctx), Compendium.AquaPath.agent_file("tom"))

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
    refute Arca.exists?(Sanctum.Context.actor(group_ctx), Compendium.AquaPath.agent_file("tom"))
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

  describe "the athanor's page" do
    setup %{conn: conn} do
      user = test_user()
      conn = log_in_user(conn, user)
      athanor = seated_athanor()
      ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
      {:ok, conn: conn, ctx: ctx, athanor: athanor}
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
      # disabled, edited, and with the way back. The write answers before
      # the section re-reads, so the card is awaited.
      settled(fn -> has_element?(view, "#aqua-card-planner", "disabled") end, "the disabled card")
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

    test "restoring the shipped files reverts an edited soul and keeps what the athanor made",
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

    test "removing everything the athanor made deletes a member-made role too",
         %{conn: conn, ctx: ctx} do
      {:ok, _} =
        AgentConfig.call_aqua(ctx, %{"action" => "create", "name" => "scout", "content" => "# S"})

      {view, _html} = mount_athanor(conn, "/aqua")
      assert has_element?(view, "#aqua-card-scout", "yours")

      view |> element("#aqua-restore button[phx-click=restore_all]") |> render_click()

      assert {:error, _} = get_agent(ctx, "scout")
      settled(fn -> not has_element?(view, "#aqua-card-scout") end, "the scout card to go")
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
      settled(
        fn -> has_element?(view, "#aqua-clone-strip input[phx-value-role=scout][checked]") end,
        "the clone strip to show scout"
      )

      assert has_element?(view, "#aqua-clone-strip input[phx-value-role=scout][checked]")

      view
      |> with_target("#aqua-agents")
      |> render_click("editor_toggle_clone", %{"role" => "scout"})

      {:ok, %{"tool_policy" => soul_policy}} = get_agent(ctx, "aqua")
      refute Map.has_key?(soul_policy, "scout.*")

      settled(
        fn ->
          not has_element?(view, "#aqua-clone-strip input[phx-value-role=scout][checked]")
        end,
        "the clone strip to drop scout"
      )

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
      # The athanor here is the person's own, so its one pinned page is
      # `about-you`; a shared athanor's is `about-us`.
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

      # The athanor's own scroll is deleted, with the verb spelled as such.
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

    # A store that cannot give the agents: the page says so in place of the
    # cards, the new-role form and the missing soul's note, and offers no
    # model to install or connect. One that answers with no agents is an
    # athanor with no soul, as before.
    @tag :capture_log
    test "an agents list that cannot be read says so, and offers nothing to create or connect",
         %{conn: conn} do
      storage!(PrismWeb.AquaLiveTest.UnreadableRoles)
      {view, _html} = mount_athanor(conn, "/aqua")

      assert has_element?(
               view,
               ~s([data-test="agents-unavailable"]),
               "The agents cannot be read right now — try again."
             )

      refute render(view) =~ "No soul here"
      refute has_element?(view, "form[phx-submit=editor_create_role]")
      refute has_element?(view, "button[phx-click=install_catalyst]")
      refute has_element?(view, "button[phx-click=open_consent]")
    end

    test "a store that answers with no agents still says no soul is here", %{conn: conn} do
      storage!(PrismWeb.AquaLiveTest.EmptyAqua)
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

      {view, html} = mount_athanor(conn, "/aqua")
      assert html =~ "not installed here yet"
      assert has_element?(view, "button[phx-click=install_catalyst]")

      # With no registry the refusal is the outcome, and it never became a
      # request: `Compendium.Pull` asks before it resolves a tag.
      assert {:error, %Compendium.OCI.Errors{reason: :registry_unconfigured}} =
               Compendium.Pull.oci_reference_for("catalyst:moonmoon69.claude")

      before = Task.Supervisor.children(Prism.TaskSupervisor)

      view
      |> element("button[phx-click=install_catalyst]")
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
      assert has_element?(view, "button[phx-click=install_catalyst]:not([disabled])")

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

      # The install task answers under the focus it started with.
      tag = CyfrWeb.ContextGuard.capture(:sys.get_state(view.pid).socket)
      send(view.pid, {:catalyst_installed, tag, ref, {:ok, %{}}})

      html = settled_render(view)
      assert html =~ "Installed #{ref}."
      refute html =~ "not installed here yet"
      assert html =~ "the model has no key yet"
      refute has_element?(view, "button[phx-click=install_catalyst]")

      # And the way on is live: the grant opens on the release that landed,
      # in the page's system layer and nowhere on the page.
      view
      |> element("button[phx-click=open_consent]", "Connect a model")
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
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
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
                  "required" => true
                }
              }
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
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
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
                  "required" => true
                }
              }
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
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
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

  # A section re-reads itself on a message the write sends after it
  # answers, so a card's new state is awaited rather than read at once.
  defp settled(fun, label), do: Prima.Test.Wait.wait_until(fun, 2_000, label)

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
