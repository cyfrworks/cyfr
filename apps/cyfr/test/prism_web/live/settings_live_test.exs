# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SettingsLiveTest do
  @moduledoc """
  Settings: the door is the operator's section and nobody else's; the
  lite/dev preference is every person's own.
  """
  use PrismWeb.ConnCase, async: false

  test "the door section is shown to a platform admin and to nobody else", %{conn: conn} do
    person = test_user()
    {view, html} = conn |> log_in_user(person) |> mount_athanor("/settings")
    refute html =~ "Server allowlist"
    refute has_element?(view, "button[phx-click=door_allow]")

    ops = test_user()
    {:ok, _} = Sanctum.Tenancy.Members.ensure_platform(ops.user_id)
    {admin_view, admin_html} = build_conn() |> log_in_user(ops) |> mount_athanor("/settings")
    assert admin_html =~ "Server allowlist"

    email = "letin-#{System.unique_integer([:positive])}@example.com"

    admin_view
    |> element("button[phx-click=door_allow]")
    |> render_click(%{"value" => email})

    assert render(admin_view) =~ email
    assert {:ok, :allowed} = Sanctum.Door.admit("github|https://github.com|x", email, true)
  end

  test "the mode preference is written to the person's row", %{conn: conn} do
    person = test_user()

    {:ok, _} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: person.user_id,
        provider: "github",
        email: person.email,
        verified: true
      })

    {view, _} = conn |> log_in_user(person) |> mount_athanor("/settings")

    view |> element("button[phx-click=set_mode][phx-value-mode=lite]") |> render_click()
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user_id)
    assert Sanctum.Tenancy.Users.prefs(user)["mode"] == "lite"

    view |> element("button[phx-click=set_mode][phx-value-mode=dev]") |> render_click()
    {:ok, user} = Sanctum.Tenancy.Users.get(person.user_id)
    assert Sanctum.Tenancy.Users.prefs(user)["mode"] == "dev"
  end
end
