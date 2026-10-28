# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MembersLiveTest do
  @moduledoc """
  The members page of a group: any member adds by person identifier (a
  seat that waits when the person has never signed in) or by the person's
  id here, removes, withdraws an invitation, and creates a group — all
  through the same verbs Codex uses.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.Test.RegistryStub

  test "adding a person by their id seats them; removing an active member takes them out", %{
    conn: conn
  } do
    alice = test_user()
    bob = test_user()
    carol = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Team #{alice.namespace}")
    {:ok, :added} = Members.add(group, [user_id: bob.user_id], alice.user_id)
    bound = session!(bob.user_id, group.id)

    {view, html} = mount_athanor(conn, "/members", group)
    assert html =~ bob.email

    view
    |> form("form[phx-submit=add]", %{"person" => "  #{carol.user_id} "})
    |> render_submit()

    assert render(view) =~ carol.email
    assert Members.member?(carol.user_id, group.id)

    view
    |> element("button[phx-click=remove][phx-value-user-id='#{bob.user_id}']")
    |> render_click()

    refute Members.member?(bob.user_id, group.id)
    refute render(view) =~ bob.email

    # Remove is the leave: the session bound to the group went with the seat.
    assert {:error, _} = Arca.SessionStorage.get_session(bound)
  end

  test "Withdraw on an invitation claimed since the page read it leaves the member seated",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Claimed #{alice.namespace}")
    n = System.unique_integer([:positive])
    identifier = "per_" <> Prima.Digest.sha256_hex("members-live-claimed-#{n}")
    {:ok, :invited} = Members.add(group, [identifier: identifier], alice.user_id)

    {view, _html} = mount_athanor(conn, "/members", group)

    assert has_element?(
             view,
             "button[phx-click=remove_invite][phx-value-identifier='#{identifier}']"
           )

    # The invitee arrives while the page still shows their invitation.
    {:ok, by_identifier} =
      Sanctum.Test.People.remote(
        %{
          id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", identifier),
          provider: "cyfr"
        },
        %{identifier: identifier, directory_url: "https://dir.example"}
      )

    {:ok, 1} = Members.activate_invited(by_identifier)

    # The click the stale page sends withdraws only an invitation, and an
    # invitation that is a seat now is not found.
    html = render_click(view, "remove_invite", %{"identifier" => identifier})
    assert html =~ "already accepted"

    assert Members.member?(by_identifier.id, group.id)
    refute has_element?(view, "button[phx-click=remove_invite]")
  end

  test "an identifier invites from the same form, shows on the roster, and is withdrawn by it",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Ids #{alice.namespace}")
    identifier = "per_" <> Prima.Digest.sha256_hex("members-live-#{alice.namespace}")

    {view, _html} = mount_athanor(conn, "/members", group)

    view
    |> form("form[phx-submit=add]", %{"person" => "  #{identifier} "})
    |> render_submit()

    assert render(view) =~ identifier

    assert [%{status: "invited", user_id: nil}] =
             Enum.filter(
               rows!(Members.list_by_athanor(group.id)),
               &(&1.person_identifier == identifier)
             )

    # A malformed one is refused in its own sentence, and nothing is held.
    view
    |> form("form[phx-submit=add]", %{"person" => "per_nope"})
    |> render_submit()

    assert render(view) =~ "not a person identifier"

    view
    |> element("button[phx-click=remove_invite][phx-value-identifier='#{identifier}']")
    |> render_click()

    refute render(view) =~ identifier

    refute Enum.any?(
             rows!(Members.list_by_athanor(group.id)),
             &(&1.person_identifier == identifier)
           )
  end

  test "a handle adds from the same form: a person here is seated, someone not here is invited, and a refusal says why",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Handles #{alice.namespace}")
    n = System.unique_integer([:positive])
    known = "per_" <> Prima.Digest.sha256_hex("members-live-handle-known-#{n}")
    stranger = "per_" <> Prima.Digest.sha256_hex("members-live-handle-stranger-#{n}")

    {:ok, here} =
      Sanctum.Test.People.remote(
        %{id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", known), provider: "cyfr"},
        %{identifier: known, directory_url: "https://dir.example"}
      )

    RegistryStub.handles!(%{"known" => known, "stranger" => stranger, "down" => :close})

    {view, html} = mount_athanor(conn, "/members", group)
    assert html =~ "@handle"
    assert has_element?(view, ~s([data-test="member-add-help"]), "handle (@name)")

    view |> form("form[phx-submit=add]", %{"person" => " @known "}) |> render_submit()
    assert Members.member?(here.id, group.id)

    view |> form("form[phx-submit=add]", %{"person" => "@stranger"}) |> render_submit()
    assert render(view) =~ stranger

    assert [%{status: "invited", user_id: nil}] =
             Enum.filter(
               rows!(Members.list_by_athanor(group.id)),
               &(&1.person_identifier == stranger)
             )

    seats = rows!(Members.list_by_athanor(group.id))

    view |> form("form[phx-submit=add]", %{"person" => "@nobody"}) |> render_submit()
    assert render(view) =~ "No one holds that handle at the registry."

    ExUnit.CaptureLog.capture_log(fn ->
      view |> form("form[phx-submit=add]", %{"person" => "@down"}) |> render_submit()
      assert render(view) =~ "The registry could not be reached just now"
    end)

    view |> form("form[phx-submit=add]", %{"person" => "@Not-A-Handle"}) |> render_submit()
    assert render(view) =~ "not a handle"

    assert rows!(Members.list_by_athanor(group.id)) == seats
  end

  test "an email address names no one here: it is refused, and nothing is held",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Per #{alice.namespace}")
    address = "newcomer-#{System.unique_integer([:positive])}@example.com"

    {view, _html} = mount_athanor(conn, "/members", group)

    view
    |> form("form[phx-submit=add]", %{"person" => address})
    |> render_submit()

    assert render(view) =~ "Could not add"
    assert [%{user_id: user_id}] = rows!(Members.list_by_athanor(group.id))
    assert user_id == alice.user_id
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

  test "a DM is named by the other person, and your own seat reads as You", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    conn = log_in_user(conn, alice)
    record_namespace!(bob)
    {:ok, pair} = Athanors.create_pair(alice.user_id, bob.user_id)

    {view, html} = mount_athanor(conn, "/members", pair)

    # The heading is who you are talking to, not the stored "A & B".
    assert has_element?(view, "h3", bob.email)
    refute html =~ pair.name
    assert has_element?(view, "td", "You")
    assert has_element?(view, "td", bob.email)
  end

  defp rows!({:ok, rows}), do: rows

  # A session of the person bound to the athanor; answers its row key.
  defp session!(user_id, athanor_id) do
    {:ok, session} =
      Sanctum.TestContext.create_session(
        Sanctum.Context.build(
          user_id: user_id,
          athanor_id: athanor_id,
          provider: "github",
          permissions: [:*],
          scope: :athanor,
          auth_method: :oidc,
          authenticated: true
        )
      )

    Sanctum.Session.token_hash(session.token)
  end
end
