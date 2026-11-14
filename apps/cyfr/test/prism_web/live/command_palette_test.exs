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

    # The developer's lookups, components among them, are offered in dev.
    {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "dev"})
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

  test "a tincture is offered in the Canvas mode, focused, and nothing names /tinctures",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}

    manifest = %{
      "name" => "palette-app",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html"}
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", "palette-app", "1.0.0",
      manifest: manifest,
      files: [{"index.html", "<!doctype html><title>palette-app</title>"}]
    )

    Prism.TinctureRegistry.reload_athanor(athanor.id)

    {view, _html} = mount_athanor(conn, "/settings")
    view |> with_target("#command-palette") |> render_click("toggle", %{})

    assert has_element?(
             view,
             ~s(#command-palette [phx-value-to="/?publisher=local&tincture_name=palette-app"])
           )

    refute has_element?(view, ~s(#command-palette [phx-value-to*="/tinctures"]))
  end

  # A component row as the registry writes one, `inserted_at` naming how new
  # it is.
  defp component_row!(ctx, name, inserted_at) do
    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}",
        name: name,
        version: "0.1.0",
        component_type: "catalyst",
        description: name,
        tags: "[]",
        digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower),
        release_digest: "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower),
        size: 100,
        exports: "[]",
        manifest: "{}",
        publisher: "local",
        publisher_id: "local|local|#{ctx.namespace}",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: inserted_at,
        updated_at: inserted_at
      })
  end

  test "an installed component is found by its name past every listing's bound",
       %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "dev"})
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}

    # `http` first, and the 1,000 a list answers at most newer than it.
    start = DateTime.utc_now() |> DateTime.add(-3_600) |> DateTime.truncate(:microsecond)
    component_row!(ctx, "http", start)
    for n <- 1..1_000, do: component_row!(ctx, "newer-#{n}", DateTime.add(start, n))

    actor = Sanctum.Context.actor(ctx)
    {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, "components")

    {:ok, :acknowledged} =
      Arca.StorageProjectionChanges.replace(actor, "components", token, fn -> :acknowledged end)

    {view, _html} = mount_athanor(conn, "/settings")
    view |> with_target("#command-palette") |> render_click("toggle", %{})

    # By its plain name, by a kind and publisher before the start of its
    # name, and by the whole label it is shown by.
    for typed <- ["http", "catalyst:local.ht", "catalyst:local.http:0.1.0"] do
      view |> element("#command-palette input") |> render_keyup(%{"value" => typed})

      assert has_element?(
               view,
               ~s(#command-palette [phx-value-to="/components/catalyst:local.http:0.1.0"])
             ),
             typed

      refute has_element?(view, ~s(#command-palette [phx-value-to*="newer-"])), typed
    end

    # A reference of another kind finds nothing of this one.
    view |> element("#command-palette input") |> render_keyup(%{"value" => "reagent:local.http"})
    refute has_element?(view, ~s(#command-palette [phx-value-to*="catalyst:local.http"]))
  end

  test "a desktop is offered as the chooser of desktops, by the shell's key", %{conn: conn} do
    user = test_user()
    conn = log_in_user(conn, user)
    athanor = seated_athanor()
    ctx = %{Sanctum.TestContext.local() | user_id: user.user_id, athanor_id: athanor.id}

    manifest = %{
      "name" => "palette-desk",
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{"entry" => "index.html", "desktop" => %{}}
    }

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", "palette-desk", "1.0.0",
      manifest: manifest,
      files: [{"index.html", "<!doctype html><title>palette-desk</title>"}]
    )

    Prism.TinctureRegistry.reload_athanor(athanor.id)

    {view, _html} = mount_athanor(conn, "/settings")
    view |> with_target("#command-palette") |> render_click("toggle", %{})

    route = Sanctum.Tenancy.Athanors.route_slug(athanor)

    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> element(~s(#command-palette button[phx-value-to="/?shell=desktops"]), "desktop")
             |> render_click()

    assert to == "/a/#{route}/?shell=desktops"
  end
end
