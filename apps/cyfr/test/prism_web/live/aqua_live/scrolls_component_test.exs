# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.ScrollsComponentTest do
  # The Scrolls group of the Aqua page as a view of `aqua/scrolls/`: its
  # buttons make the writes Files makes there, bringing a pack in shows the
  # one sheet first and keeps exactly what it showed, and every card reads
  # in one column at narrow width with its actions in one menu.
  use PrismWeb.ConnCase, async: false

  alias Compendium.PackArchive

  setup %{conn: conn} do
    test_path = Path.join(System.tmp_dir!(), "scrolls_page_#{:rand.uniform(1_000_000)}")
    Prima.Test.Env.put_app_env(:arca, :base_path, test_path)
    on_exit(fn -> File.rm_rf(test_path) end)

    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}
    {:ok, conn: conn, ctx: ctx, athanor: athanor, actor: Sanctum.Context.actor(ctx)}
  end

  defp section(view), do: with_target(view, "#aqua-scrolls-section")

  defp settled(fun, label), do: Prima.Test.Wait.wait_until(fun, 2_000, label)

  defp upload!(view, filename, bytes) do
    input = file_input(view, "#aqua-bring-form", :pack, [%{name: filename, content: bytes}])
    render_upload(input, filename)
    view |> form("#aqua-bring-form") |> render_submit()
  end

  defp servers_pack do
    PackArchive.tar_gz([
      {"srv/.claude-plugin/plugin.json",
       ~s({"name": "srv", "mcpServers": {"inline-one": {"command": "a"}}}), false},
      {"srv/.codex-plugin/plugin.json", ~s({"name": "srv", "mcpServers": "./servers.json"}),
       false},
      {"srv/servers.json", ~s({"mcpServers": {"from-file": {"command": "b"}}}), false},
      {"srv/.mcp.json", ~s({"mcpServers": {"dot-mcp": {"command": "c"}}}), false},
      {"srv/skills/look/SKILL.md", "---\nname: look\ndescription: d\n---\n\nLook.\n", false},
      {"srv/skills/how/SKILL.md",
       "---\nname: how\ndescription: d\ndisable-model-invocation: true\n---\n\nAsk.\n", false},
      {"srv/skills/look/run.sh", "#!/bin/sh\n", true}
    ])
  end

  test "bringing a pack in shows the sheet's sentence and each server of all three ways, and Bring in keeps the digest agreed to",
       %{conn: conn, ctx: ctx, actor: actor} do
    {view, _html} = mount_athanor(conn, "/aqua")
    upload!(view, "srv.tar.gz", servers_pack())

    sheet = view |> element("#aqua-pack-sheet") |> render()

    trust =
      PrismWeb.AquaLive.ScrollsComponent.trust_sentence()
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    assert sheet =~ trust

    servers = view |> element("#aqua-sheet-servers") |> render()
    for name <- ["inline-one", "from-file", "dot-mcp"], do: assert(servers =~ name)

    {:ok, shown} = Compendium.Packs.sheet(ctx, servers_pack(), "srv.tar.gz")
    view |> element("#aqua-sheet-confirm") |> render_click()

    settled(fn -> has_element?(view, "#aqua-pack-srv") end, "the brought pack's card")
    {:ok, raw} = Arca.get(actor, ~w(aqua scrolls srv .cyfr-pack.json))
    assert {:ok, %{origin: "brought", agreed: agreed}} = Compendium.Packs.decode_record(raw)
    assert agreed == shown.agreed

    # A scroll its author kept from the model is marked so on the card,
    # which a bring-in leaves open.
    assert view |> element("#aqua-scroll-kept-srv-how") |> render() =~ "used when named"
    refute has_element?(view, "#aqua-scroll-kept-srv-look")

    # Opening a scroll shows its files, the one that runs marked so, and a
    # brought pack's scroll offers Copy to my pack, never Edit.
    view |> section() |> render_click("scroll_open", %{"pack" => "srv", "folder" => "look"})
    assert view |> element("#aqua-scroll-open") |> render() =~ "run.sh"
    assert view |> element("#aqua-scroll-open") |> render() =~ "runs"
    refute has_element?(view, "#aqua-scroll-open button[phx-click=scroll_edit]")

    view |> element("#aqua-scroll-open button[phx-click=scroll_copy]") |> render_click()
    assert {:ok, %{name: "mine:look"}} = Compendium.skill(ctx, "mine:look")
  end

  test "New pack is one act, refused under cyfr or a name already here; New scroll, Edit, Delete and Remove are the Files writes",
       %{conn: conn, ctx: ctx, actor: actor} do
    {view, _html} = mount_athanor(conn, "/aqua")

    # One act: a pack's name and its first scroll's name.
    view |> section() |> render_click("pack_new", %{})

    view
    |> form("#aqua-scroll-editor", %{
      "pack" => "garden",
      "scroll" => "roses",
      "description" => "How the roses are kept",
      "content" => "Prune in March."
    })
    |> render_submit()

    settled(fn -> has_element?(view, "#aqua-pack-garden") end, "the new pack's card")
    {:ok, raw} = Arca.get(actor, ~w(aqua scrolls garden .cyfr-pack.json))
    assert {:ok, %{origin: "own", on: true}} = Compendium.Packs.decode_record(raw)
    assert {:ok, %{body: "Prune in March."}} = Compendium.skill(ctx, "garden:roses")

    for {name, says} <- [
          {"garden", "already here"},
          {"cyfr", "already here"},
          {"-x", "letters, digits"}
        ] do
      view |> section() |> render_click("pack_new", %{})

      html =
        view
        |> form("#aqua-scroll-editor", %{
          "pack" => name,
          "scroll" => "more",
          "description" => "d",
          "content" => "c"
        })
        |> render_submit()

      assert html =~ says
      view |> section() |> render_click("editor_cancel", %{})
    end

    assert {:error, :not_found} = Compendium.skill(ctx, "garden:more")

    # New scroll and Edit in a pack of the person's own.
    view |> section() |> render_click("scroll_new", %{"pack" => "garden"})

    view
    |> form("#aqua-scroll-editor", %{
      "scroll" => "ivy",
      "description" => "d",
      "content" => "Climb."
    })
    |> render_submit()

    assert {:ok, %{body: "Climb."}} = Compendium.skill(ctx, "garden:ivy")

    view |> section() |> render_click("scroll_open", %{"pack" => "garden", "folder" => "ivy"})
    view |> section() |> render_click("scroll_edit", %{})

    view
    |> form("#aqua-scroll-editor", %{"description" => "d", "content" => "Climb higher."})
    |> render_submit()

    assert {:ok, %{body: "Climb higher."}} = Compendium.skill(ctx, "garden:ivy")

    # Delete: the scroll's folder goes, as Files deletes it.
    view |> section() |> render_click("scroll_open", %{"pack" => "garden", "folder" => "ivy"})
    view |> element("#aqua-scroll-open button[phx-click=scroll_delete]") |> render_click()
    assert {:ok, []} = Arca.list_typed(actor, ~w(aqua scrolls garden skills ivy))
    assert {:error, :not_found} = Compendium.skill(ctx, "garden:ivy")

    # Remove: the pack's folder goes; CYFR's own refuses.
    view |> section() |> render_click("pack_remove", %{"pack" => "garden"})
    assert {:ok, []} = Arca.list_typed(actor, ~w(aqua scrolls garden))

    assert view |> section() |> render_click("pack_remove", %{"pack" => "cyfr"}) =~
             "cannot be deleted"

    assert {:ok, %{name: "cyfr:research"}} = Compendium.skill(ctx, "cyfr:research")
  end

  test "a switch takes a pack out of the index, and a scroll past the bound says why",
       %{conn: conn, ctx: ctx, actor: actor} do
    {:ok, _} =
      Arca.Files.write(
        actor,
        "aqua/scrolls/mine/skills/too-big/SKILL.md",
        ~s(---\nname: "too-big"\ndescription: "d"\n---\n\n) <> String.duplicate("a", 131_072)
      )

    {view, _html} = mount_athanor(conn, "/aqua")
    view |> section() |> render_click("pack_open", %{"pack" => "mine"})

    assert view |> element("#aqua-scroll-too-large-mine-too-big") |> render() =~
             "Aqua does not use this scroll"

    view |> section() |> render_click("pack_switch", %{"pack" => "cyfr", "on" => "false"})
    assert {:error, :not_found} = Compendium.skill(ctx, "cyfr:research")
    assert has_element?(view, "#aqua-pack-cyfr [role=switch][aria-checked=false]")

    view |> section() |> render_click("pack_switch", %{"pack" => "cyfr", "on" => "true"})
    assert {:ok, _} = Compendium.skill(ctx, "cyfr:research")
  end

  test "at narrow width the cards are one column, each card's actions in one menu, and Download is offered on every card",
       %{conn: conn, athanor: athanor, actor: actor} do
    {:ok, _} =
      Arca.Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

    {view, _html} = mount_athanor(conn, "/aqua")

    # One column below the medium breakpoint, two from it.
    assert has_element?(view, "#aqua-scrolls-section div.grid.grid-cols-1.md\\:grid-cols-2")

    for pack <- ["cyfr", "mine"] do
      assert has_element?(view, "#aqua-pack-#{pack} details#aqua-pack-menu-#{pack} summary")

      assert view |> element("#aqua-pack-menu-#{pack} a[download]") |> render() =~
               "/a/#{Sanctum.Tenancy.Athanors.route_slug(athanor)}/scrolls/download/#{pack}"
    end
  end

  test "Download gives a pack as the archive it would be brought in by, and another athanor's is not found",
       %{conn: conn, actor: actor} do
    {:ok, _} =
      Arca.Files.write(actor, "aqua/scrolls/mine/skills/a/SKILL.md", "---\nname: a\n---\n\nb\n")

    response = get(conn, athanor_path("/scrolls/download/mine"))
    assert response.status == 200
    assert ["application/gzip" <> _] = get_resp_header(response, "content-type")
    {:ok, entries} = PackArchive.read(response.resp_body)
    assert Enum.map(entries, & &1.path) == ["mine/skills/a/SKILL.md"]

    assert get(conn, athanor_path("/scrolls/download/absent")).status == 404
  end
end
