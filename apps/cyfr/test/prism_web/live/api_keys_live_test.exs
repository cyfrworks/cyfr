# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ApiKeysLiveTest do
  @moduledoc """
  The API Keys page in lite mode: one kind of key, its permissions ticked
  from a preset and named by what each lets a key do, optionally narrowed
  to named tools, each shown on its row.
  """
  use PrismWeb.ConnCase, async: false

  import Prima.Test.Wait

  defp checked(view) do
    for {scope, _what} <- Sanctum.ApiKey.permissions(),
        has_element?(view, ~s(input[type="checkbox"][phx-value-scope="#{scope}"][checked])),
        do: scope
  end

  test "the lite page offers the presets, and a key made from one keeps its tools on its row",
       %{conn: conn} do
    user = test_user()
    {:ok, row} = Sanctum.Tenancy.Users.get(user.user_id)
    {:ok, _} = Sanctum.Tenancy.Users.put_prefs(row, %{"mode" => "lite"})
    {view, _html} = conn |> log_in_user(user) |> mount_athanor("/api-keys")
    ctx = %{Sanctum.TestContext.local() | athanor_id: seated_athanor().id, user_id: user.user_id}
    html = render_click(view, "toggle_create")

    for {preset, _scopes} <- Sanctum.ApiKey.presets() do
      assert has_element?(
               view,
               ~s(button[phx-click="preset"][phx-value-preset="#{preset}"]),
               preset
             )
    end

    for {_scope, what} <- Sanctum.ApiKey.permissions(), do: assert(html =~ what)
    refute html =~ "Grant all"
    refute has_element?(view, ~s(select[name="type"]))

    assert checked(view) == ["execute", "component_read", "storage_read"]

    view |> element(~s(button[phx-value-preset="Build components"])) |> render_click()

    assert checked(view) ==
             ["execute", "component_read", "storage_read", "component_manage", "storage_write"]

    view |> element(~s(button[phx-value-preset="Manage keys and webhooks"])) |> render_click()
    assert checked(view) == ["admin"]

    view |> element(~s(input[phx-value-scope="execute"])) |> render_click()
    assert checked(view) == ["execute", "admin"]

    render_submit(view, "create", %{"name" => "narrow", "tools" => "c:local.ship, r:local.fetch"})

    assert [%{ref: ref, operation: "key.create"}] =
             Arca.PendingConfirmations.list_open(Sanctum.Context.actor(ctx), ctx.user_id)
             |> elem(1)

    Sanctum.TestContext.prove!(ctx, ref)

    wait_until(
      fn -> is_map(:sys.get_state(view.pid).socket.assigns.new_key) end,
      2_000,
      "the key"
    )

    assert {:ok,
            %{scope: ["execute", "admin"], tools: ["catalyst:local.ship", "reagent:local.fetch"]}} =
             Sanctum.ApiKey.get(ctx, "narrow")

    wait_until(
      fn -> render(view) =~ "catalyst:local.ship, reagent:local.fetch" end,
      2_000,
      "the key's row"
    )

    assert render(view) =~ "Run tools, Manage keys, webhooks and programs"
    Cyfr.Test.Sandbox.end_views()
  end
end
