# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MembersLiveTest do
  @moduledoc """
  The members page of a group: any member adds by email (a seat that waits
  when the person has never signed in), removes, and creates a group — all
  through the same verbs Codex uses.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.{Athanors, Members}

  test "adding an email seats an invited row; removing an active member takes them out", %{
    conn: conn
  } do
    alice = test_user()
    bob = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Team #{alice.namespace}")

    {:ok, _} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{
        id: bob.user_id,
        provider: "github",
        email: bob.email,
        verified: true
      })

    {:ok, :added} = Members.add(group, [user_id: bob.user_id], alice.user_id)

    {view, html} = mount_athanor(conn, "/members", group)
    assert html =~ bob.email

    stranger = "newcomer-#{System.unique_integer([:positive])}@example.com"

    view
    |> form("form[phx-submit=add]", %{"email" => stranger})
    |> render_submit()

    assert render(view) =~ stranger

    assert Enum.any?(
             rows!(Members.list_by_athanor(group.id)),
             &(&1.email == stranger and &1.status == "invited")
           )

    view
    |> element("button[phx-click=remove][phx-value-user-id='#{bob.user_id}']")
    |> render_click()

    refute Members.member?(bob.user_id, group.id)
    refute render(view) =~ bob.email
  end

  test "a group is created from the page and its creator is its only member", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {view, _html} = mount_athanor(conn, "/members")

    view
    |> form("form[phx-submit=create_group]", %{"name" => "Garden #{alice.namespace}"})
    |> render_submit()

    assert render(view) =~ "Garden #{alice.namespace}"
    [group] = Enum.filter(Athanors.list_for_user(alice.user_id), &(&1.name =~ "Garden"))
    assert Members.count_by_athanor(group.id) == {:ok, 1}
    assert Members.member?(alice.user_id, group.id)
  end
  defp rows!({:ok, rows}), do: rows
end
