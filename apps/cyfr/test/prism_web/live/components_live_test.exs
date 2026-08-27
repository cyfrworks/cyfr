# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ComponentsLiveTest do
  @moduledoc """
  Provenance in the Components page: a bundled component wears its badge
  and offers no Remove (it isn't the athanor's to delete — and costs
  nothing); an edited copy reads "modified" and offers Reset; Reset
  reverts to shipped.
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

    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    user = test_user()
    conn = log_in_user(conn, user)

    # The scan mints the bundled row through the overlay union — no bytes
    # move — inside the athanor the view will mount.
    home = Sanctum.Tenancy.Athanors.home!()

    ctx =
      Sanctum.internal_context(user_id: "_test", athanor_id: home.id, scope: :athanor)

    # The suite's storage root is shared across tests while the DB rows
    # roll back — an edit one test materializes must not leak into the
    # next test's provenance. Registered before the seed restore, so it
    # runs first (LIFO).
    on_exit(fn ->
      Arca.delete_tree(ctx, ["components", "reagents", "local", "shelf-tool"])
    end)

    %{errors: 0} = Compendium.AutoIndexer.scan(ctx: ctx)

    {:ok, conn: conn, ctx: ctx}
  end

  defp expanded_html(conn) do
    {view, _html} = mount_athanor(conn, "/components")
    render_click(view, "toggle_expand", %{"ref" => "reagent:local.shelf-tool"})
    {view, render(view)}
  end

  test "a bundled component wears its badge and offers no Remove", %{conn: conn} do
    {_view, html} = expanded_html(conn)

    assert html =~ "shelf-tool"
    assert html =~ ~r/>\s*bundled\s*</
    refute html =~ ~r/>\s*modified\s*</
    refute html =~ "Reset"
    refute html =~ "Remove reagent:local.shelf-tool:1.0.0?"
  end

  test "an edited copy reads modified and offers Reset", %{conn: conn, ctx: ctx} do
    :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")

    {_view, html} = expanded_html(conn)

    assert html =~ ~r/>\s*modified\s*</
    assert html =~ "Reset reagent:local.shelf-tool:1.0.0 to the shipped version?"
  end

  test "Reset reverts the copy to shipped", %{conn: conn, ctx: ctx} do
    :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")

    {view, html} = expanded_html(conn)
    assert html =~ ~r/>\s*modified\s*</

    render_click(view, "reset", %{"ref" => "reagent:local.shelf-tool:1.0.0"})

    # The copy is gone; the seed shows through, and a fresh mount agrees.
    refute Arca.exists?(ctx, @version_dir ++ ["notes.txt"])
    assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :seed}

    {_view, html} = expanded_html(conn)
    assert html =~ ~r/>\s*bundled\s*</
    refute html =~ ~r/>\s*modified\s*</
  end
end
