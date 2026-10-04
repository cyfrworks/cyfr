# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLiveTest do
  @moduledoc """
  Provenance in the Components page: a bundled copy wears its badge,
  offers Reset and no Remove (it isn't the athanor's to delete); Reset
  restores the shipped bytes over an edit; a newer shipped version is
  offered as Update and pulled in beside the copy.
  """

  use PrismWeb.ConnCase, async: false

  @valid_wasm <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00>> <>
                <<0x01, 0x04, 0x01, 0x60, 0x00, 0x00>> <>
                <<0x03, 0x02, 0x01, 0x00>> <>
                <<0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00>> <>
                <<0x0A, 0x04, 0x01, 0x02, 0x00, 0x0B>>

  @version_dir ["components", "reagents", "local", "shelf-tool", "1.0.0"]

  setup %{conn: conn} do
    # A private seed tree shipping one component; the suite's shared seed
    # stays untouched.
    base = Path.join(System.tmp_dir!(), "components_live_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")
    shipped = Path.join([seed, "components", "reagents", "local", "shelf-tool", "1.0.0"])
    File.mkdir_p!(shipped)

    File.write!(
      Path.join(shipped, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.0.0", "description" => "shipped"})
    )

    File.write!(Path.join(shipped, "reagent.wasm"), @valid_wasm)

    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    user = test_user()
    conn = log_in_user(conn, user)

    # Signing in copied the shipped version into the athanor the view
    # will mount; the scan mints its row.
    ctx =
      Sanctum.internal_context(
        user_id: "_test",
        athanor_id: seated_athanor().id,
        scope: :athanor
      )

    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)

    {:ok, conn: conn, ctx: ctx, seed: seed}
  end

  defp expanded_html(conn) do
    {view, _html} = mount_athanor(conn, "/components")
    render_click(view, "toggle_expand", %{"ref" => "reagent:local.shelf-tool"})
    {view, render(view)}
  end

  test "a bundled copy wears its badge, offers Reset and no Remove", %{conn: conn} do
    {_view, html} = expanded_html(conn)

    assert html =~ "shelf-tool"
    assert html =~ ~r/>\s*bundled\s*</
    assert html =~ "Reset reagent:local.shelf-tool:1.0.0 to the shipped version?"
    refute html =~ "Remove reagent:local.shelf-tool:1.0.0?"
  end

  test "Reset restores the shipped bytes over an edit", %{conn: conn, ctx: ctx} do
    :ok = Arca.put(Sanctum.Context.actor(ctx), @version_dir ++ ["notes.txt"], "edited")
    assert {:ok, true} = Arca.Overlay.edited?(Sanctum.Context.actor(ctx), @version_dir)

    {view, _html} = expanded_html(conn)
    render_click(view, "reset", %{"ref" => "reagent:local.shelf-tool:1.0.0"})

    # The edit is gone; the copy matches the shipped version again, and a
    # fresh mount agrees.
    refute Arca.exists?(Sanctum.Context.actor(ctx), @version_dir ++ ["notes.txt"])
    assert {:ok, false} = Arca.Overlay.edited?(Sanctum.Context.actor(ctx), @version_dir)

    {_view, html} = expanded_html(conn)
    assert html =~ ~r/>\s*bundled\s*</
  end

  test "a grant is asked in the page's system layer, not drawn on the page, and the plan is read again once granted",
       %{conn: conn, ctx: ctx} do
    {view, _html} = expanded_html(conn)

    view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()
    html = render(view)

    assert html =~ ~s(data-kind="grant")
    assert html =~ "Grant reagent:local.shelf-tool:1.0.0"
    assert has_element?(view, ~s(#system-layer-dialog [data-test="grant-sheet"]))
    refute has_element?(view, "#consent-sheet-dialog")

    view |> element(~s(#system-layer-dialog button[phx-click="confirm"])) |> render_click()

    # The layer asks its sheet for the walk, commits, and reports.
    Prima.Test.Wait.wait_until(
      fn -> :sys.get_state(view.pid).socket.assigns.grant_prompt == nil end,
      5_000,
      "the grant"
    )

    html = render(view)
    refute html =~ ~s(data-kind="grant")
    assert :sys.get_state(view.pid).socket.assigns.grant_prompt == nil
    assert {:ok, [_profile | _]} = Sanctum.Consent.profiles(ctx, "reagent:local.shelf-tool")
  end

  test "a grant asked here opens on the plan's suggestion, and a need the component reads " <>
         "itself links to the update this page offers",
       %{conn: conn, ctx: ctx} do
    manifest = fn version ->
      %{
        "name" => "shelf-model",
        "type" => "catalyst",
        "version" => version,
        "publisher" => "local",
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:shelf.example",
            "reason" => "to call the shelf's model",
            "fields" => ["SHELF_KEY"]
          }
        }
      }
    end

    # A shipped catalyst that reads its key itself, and a newer version
    # shipped since.
    {:ok, _} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "shelf-model", "1.0.0",
        manifest: manifest.("1.0.0"),
        wasm: @valid_wasm
      )

    Arca.Test.UnitFixtures.seed_component!("catalyst", "local", "shelf-model", "1.1.0",
      manifest: manifest.("1.1.0"),
      wasm: @valid_wasm
    )

    grant = fn ->
      {view, _html} = mount_athanor(conn, "/components")
      render_click(view, "toggle_expand", %{"ref" => "catalyst:local.shelf-model"})
      render(view)
      view |> element("button[phx-click=open_consent]", "Grant access") |> render_click()
      render(view)
      view
    end

    # No entry it may read: the sheet names the newer version, linking to
    # this page's entry for the component, where Update is.
    view = grant.()

    assert has_element?(
             view,
             ~s(#system-layer-dialog a[data-test="grant-update"]),
             "Update catalyst:local.shelf-model to 1.1.0"
           )

    [href] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(a[data-test="grant-update"]))
      |> LazyHTML.attribute("href")

    assert href =~ "/components?"

    assert URI.decode_query(URI.parse(href).query) == %{
             "ref" => "catalyst:local.shelf-model",
             "setup" => "true"
           }

    # An entry it may read: the grant opens with it bound.
    person = %{Sanctum.TestContext.local() | athanor_id: ctx.athanor_id}

    {:ok, entry} =
      Sanctum.TestContext.create_vault(person, %{
        name: "shelf key",
        kind: "api_key",
        provider_hint: "shelf.example",
        fields: %{"SHELF_KEY" => "sk-shelf"},
        destination: %{"hosts" => ["api.shelf.example"]},
        disclose: true
      })

    view = grant.()

    assert has_element?(
             view,
             ~s(#system-layer-dialog [data-test="grant-pick"][aria-pressed="true"]),
             entry.name
           )
  end

  test "a newer shipped version is offered as Update and pulled in beside the copy", %{
    conn: conn,
    ctx: ctx,
    seed: seed
  } do
    newer = Path.join([seed, "components", "reagents", "local", "shelf-tool", "1.1.0"])
    File.mkdir_p!(newer)

    File.write!(
      Path.join(newer, "cyfr-manifest.json"),
      Jason.encode!(%{"type" => "reagent", "version" => "1.1.0", "description" => "shipped"})
    )

    File.write!(Path.join(newer, "reagent.wasm"), @valid_wasm)

    {view, html} = expanded_html(conn)
    assert html =~ "Update to 1.1.0"
    refute html =~ "1.1.0</span>"

    render_click(view, "pull", %{"ref" => "reagent:local.shelf-tool:1.1.0"})

    # The copy lands, registered, and the page shows it as the latest
    # version with nothing left to update to.
    Prima.Test.Wait.wait_until(fn ->
      render(view) =~ "Pulled reagent:local.shelf-tool:1.1.0"
    end)

    html = render(view)
    refute html =~ "Update to"
    assert html =~ "1.1.0"

    newer_dir = ["components", "reagents", "local", "shelf-tool", "1.1.0"]
    assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), newer_dir) == {:ok, :shipped}
    assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), @version_dir) == {:ok, :shipped}

    assert {:ok, %{version: "1.1.0"}} =
             Compendium.Registry.get_latest(ctx, "shelf-tool", "local", "reagent")
  end
end
