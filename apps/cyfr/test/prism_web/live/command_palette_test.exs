# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.CommandPaletteTest do
  # The palette's rows come from the same tool results the pages read, so
  # a row must carry the reference those results actually name.
  use PrismWeb.ConnCase, async: false

  setup do
    test_path = Path.join(System.tmp_dir!(), "palette_#{:rand.uniform(1_000_000)}")
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

  test "an installed component is offered by its reference, not as a blank row",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:catalyst), %{
        name: "palette-probe",
        version: "0.1.0",
        type: "catalyst",
        description: "Test catalyst"
      })

    {view, _html} = mount_athanor(conn, "/settings")

    html =
      view
      |> with_target("#command-palette")
      |> render_click("toggle", %{})

    assert html =~ "catalyst:local.palette-probe:0.1.0"
    assert has_element?(view, ~s(#command-palette [phx-value-to*="palette-probe"]))
  end
end
