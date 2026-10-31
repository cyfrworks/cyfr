# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MembersLiveTest do
  @moduledoc """
  Members add people by name, offer a named invitation when no one holds
  the name, and remove people through the same operations Codex uses.
  Invitation links are shown once, listed for their group and revocable.
  """
  use PrismWeb.ConnCase, async: false

  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.Test.RegistryStub

  import PrismWeb.AdmissionScreens, only: [refute_vocabulary: 1]

  test "adding a person by name seats them; removing an active member takes them out", %{
    conn: conn
  } do
    alice = test_user()
    bob = test_user()
    carol = test_user()
    %{identifier: identifier} = RegistryStub.enroll!(carol.user_id)
    record_namespace!(carol)
    RegistryStub.handles!(%{carol.namespace => identifier})
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Team #{alice.namespace}")
    {:ok, :added} = Members.add(group, [user_id: bob.user_id], alice.user_id)
    bound = session!(bob.user_id, group.id)

    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    assert html =~ bob.email

    add_person(view, "  @#{carol.namespace} ")

    assert has_element?(view, "td", "@#{carol.namespace}")
    assert Members.member?(carol.user_id, group.id)

    view
    |> element("button[phx-click=remove][phx-value-user-id='#{bob.user_id}']")
    |> render_click()
    |> refute_vocabulary()

    refute Members.member?(bob.user_id, group.id)
    refute checked_render(view) =~ bob.email

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

    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)

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
    refute_vocabulary(html)
    assert html =~ "already accepted"

    assert Members.member?(by_identifier.id, group.id)
    refute has_element?(view, "button[phx-click=remove_invite]")
  end

  test "names with or without @ add a person here or a seat waiting for their first sign-in",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    n = System.unique_integer([:positive])
    known = "per_" <> Prima.Digest.sha256_hex("members-live-name-known-#{n}")
    stranger = "per_" <> Prima.Digest.sha256_hex("members-live-name-stranger-#{n}")

    {:ok, here} =
      Sanctum.Test.People.remote(
        %{id: Sanctum.Auth.Identity.cyfr_key("https://dir.example", known), provider: "cyfr"},
        %{identifier: known, directory_url: "https://dir.example"}
      )

    record_namespace!(%{user_id: here.id, namespace: "known"})
    RegistryStub.handles!(%{"known" => known, "stranger" => stranger})

    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    assert has_element?(view, ~s(input[name="person"][placeholder="@name"]))

    assert has_element?(
             view,
             ~s([data-test="member-add-help"]),
             "Add someone by their name. A name no one holds yet offers an invitation link with that name filled in."
           )

    add_person(view, " known ")
    assert_receive {:registry_request, %{path: "/v1/handles/known"}}
    assert Members.member?(here.id, group.id)
    assert has_element?(view, "th", "Name")
    assert has_element?(view, "td", "@known")
    refute has_element?(view, "th", "Identifier")

    add_person(view, " @stranger ")
    assert_receive {:registry_request, %{path: "/v1/handles/stranger"}}

    assert [%{status: "invited", user_id: nil}] =
             Enum.filter(
               rows!(Members.list_by_athanor(group.id)),
               &(&1.person_identifier == stranger)
             )

    refute link_text(checked_render(view)) =~ stranger
    refute link_text(checked_render(view)) =~ known
    assert Arca.Repo.all(Arca.Schemas.Invitation) == []
  end

  test "an unknown bare name offers a named link and creates only that group's invitation",
       %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    RegistryStub.handles!(%{})
    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    observe_writes!(view)
    seats = rows!(Members.list_by_athanor(group.id))
    groups = Athanors.list_for_user(alice.user_id)

    html = add_person(view, " newcomer ")
    assert html =~ "No one has @newcomer yet."
    refute html =~ "Storage is unavailable"
    assert_receive {:registry_request, %{path: "/v1/handles/newcomer"}}
    assert_receive {:page_write, "member", "add"}
    assert rows!(Members.list_by_athanor(group.id)) == seats
    assert Arca.Repo.all(Arca.Schemas.Invitation) == []

    view
    |> element(~s(button[phx-click="invite_name"]), "Create an invitation link for @newcomer")
    |> render_click(%{"name" => "someone-else", "athanor_id" => "other"})
    |> refute_vocabulary()

    assert_receive {:page_write, "invitation", "create"}
    refute_receive {:page_write, _, _}, 0
    refute_receive {:registry_request, _}, 0
    assert rows!(Members.list_by_athanor(group.id)) == seats
    assert Athanors.list_for_user(alice.user_id) == groups

    [%{name: "newcomer", athanor_id: id, issued_by: issuer}] =
      Arca.Repo.all(Arca.Schemas.Invitation)

    assert id == group.id
    assert issuer == alice.user_id

    code = view |> element(~s([data-test="invitation-link"])) |> checked_render() |> link_text()
    code = code |> String.split("#") |> List.last()
    assert {:ok, %{name: "newcomer", athanor: group_name}} = Sanctum.Invitations.lookup(code)
    assert group_name == group.name
    refute has_element?(view, ~s([data-test="member-unknown-name"]))

    render_click(view, "invite_name", %{"name" => "someone-else", "athanor_id" => "other"})
    |> refute_vocabulary()

    refute_receive {:page_write, _, _}, 0
    assert length(Arca.Repo.all(Arca.Schemas.Invitation)) == 1
  end

  test "editing an unknown name clears its offer and a stale click sends nothing", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    RegistryStub.handles!(%{})
    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    assert add_person(view, "@newcomer") =~ "No one has @newcomer yet."
    observe_writes!(view)

    view
    |> form("#member-add-form", %{"person" => "different"})
    |> render_change()
    |> refute_vocabulary()

    refute has_element?(view, ~s(button[phx-click="invite_name"]))

    render_click(view, "invite_name", %{"name" => "newcomer"})
    |> refute_vocabulary()

    refute_receive {:page_write, _, _}, 0
    assert Arca.Repo.all(Arca.Schemas.Invitation) == []
    checked_render(view)
  end

  test "person identifiers and local ids send no request from either add form", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    {:ok, pair} = Athanors.create_pair(alice.user_id, bob.user_id)
    RegistryStub.handles!(%{})

    for {athanor, event} <- [{group, "add"}, {pair, "add_third"}] do
      {view, html} = mount_athanor(conn, "/members", athanor)
      refute_vocabulary(html)
      observe_writes!(view)
      seats = rows!(Members.list_by_athanor(athanor.id))
      groups = Athanors.list_for_user(alice.user_id)

      for person <- ["per_" <> String.duplicate("a", 64), "per_nope", bob.user_id, "usr_missing"] do
        html = add_person(view, "  #{person}  ", event)

        assert html =~
                 "Add people by name here. To add someone by identifier, use cyfr member add on the command line."

        refute_receive {:page_write, _, _}, 0
        refute_receive {:registry_request, _}, 0
        assert rows!(Members.list_by_athanor(athanor.id)) == seats
        assert Athanors.list_for_user(alice.user_id) == groups
        assert Arca.Repo.all(Arca.Schemas.Invitation) == []
      end
    end
  end

  test "a misspelled name or email sends nothing and says how to spell a name", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    RegistryStub.handles!(%{})
    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    observe_writes!(view)
    seats = rows!(Members.list_by_athanor(group.id))

    for person <- [
          "",
          "@Not-A-Name",
          "@",
          "@@name",
          "a--b",
          "newcomer@example.com",
          String.duplicate("a", 40)
        ] do
      html = add_person(view, person)

      assert html =~
               "A name is lowercase letters and digits joined by single hyphens, at most 39 characters."

      refute_receive {:page_write, _, _}, 0
      refute_receive {:registry_request, _}, 0
      assert rows!(Members.list_by_athanor(group.id)) == seats
      assert Arca.Repo.all(Arca.Schemas.Invitation) == []
    end
  end

  test "a CYFR with no name lookup says nobody can be found by name", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    RegistryStub.handles!(%{})
    for app <- [:sanctum, :cyfr], do: Prima.Test.Env.put_app_env(app, :registry_url, "none")
    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    seats = rows!(Members.list_by_athanor(group.id))

    assert add_person(view, "newcomer") =~
             "This CYFR does not reach cyfr.run, so nobody can be found by name."

    refute_receive {:registry_request, _}, 0
    assert rows!(Members.list_by_athanor(group.id)) == seats
    assert Arca.Repo.all(Arca.Schemas.Invitation) == []
    refute has_element?(view, ~s(button[phx-click="invite_name"]))
  end

  test "a silent cyfr.run offers a retry and writes nothing", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {:ok, group} = Athanors.create_group(alice.user_id, "Names #{alice.namespace}")
    RegistryStub.handles!(%{"silent" => :close})
    {view, html} = mount_athanor(conn, "/members", group)
    refute_vocabulary(html)
    seats = rows!(Members.list_by_athanor(group.id))

    ExUnit.CaptureLog.capture_log(fn ->
      assert add_person(view, "silent") =~ "cyfr.run did not answer. Try again."
    end)

    assert_receive {:registry_request, %{path: "/v1/handles/silent"}}
    assert rows!(Members.list_by_athanor(group.id)) == seats
    assert Arca.Repo.all(Arca.Schemas.Invitation) == []
    refute has_element?(view, ~s(button[phx-click="invite_name"]))
  end

  test "an unanswered or unknown third name leaves the direct thread and groups alone",
       %{conn: conn} do
    alice = test_user()
    bob = test_user()
    conn = log_in_user(conn, alice)
    {:ok, pair} = Athanors.create_pair(alice.user_id, bob.user_id)
    RegistryStub.handles!(%{"silent" => :close})
    {view, html} = mount_athanor(conn, "/members", pair)
    refute_vocabulary(html)
    groups = Athanors.list_for_user(alice.user_id)
    observe_writes!(view)

    ExUnit.CaptureLog.capture_log(fn ->
      assert add_person(view, "silent", "add_third") =~ "cyfr.run did not answer. Try again."
    end)

    assert add_person(view, "newcomer", "add_third") =~ "No one has @newcomer yet."
    assert Athanors.list_for_user(alice.user_id) == groups
    assert Members.count_by_athanor(pair.id) == {:ok, 2}
    refute_receive {:page_write, _, _}, 0
    assert Arca.Repo.all(Arca.Schemas.Invitation) == []
  end

  test "a third person is added by name to a new group, leaving the direct thread alone",
       %{conn: conn} do
    alice = test_user()
    bob = test_user()
    carol = test_user()
    %{identifier: identifier} = RegistryStub.enroll!(carol.user_id)
    RegistryStub.handles!(%{"carol" => identifier})
    conn = log_in_user(conn, alice)
    {:ok, pair} = Athanors.create_pair(alice.user_id, bob.user_id)
    {view, html} = mount_athanor(conn, "/members", pair)
    refute_vocabulary(html)

    result = view |> form("#member-add-third-form", %{"person" => "carol"}) |> render_submit()
    assert_receive {:registry_request, %{path: "/v1/handles/carol"}}
    refute_receive {:registry_request, _}, 0

    {path, _flash} = assert_redirect(view)

    [group] =
      Enum.filter(
        Athanors.list_for_user(alice.user_id),
        &(&1.kind == "group" and &1.roster == "open")
      )

    assert path == PrismWeb.Focus.path(group, "/members")
    {:ok, added, html} = follow_redirect(result, conn, path)
    refute_vocabulary(html)
    checked_render(added)
    assert Members.member?(alice.user_id, group.id)
    assert Members.member?(bob.user_id, group.id)
    assert Members.member?(carol.user_id, group.id)
    assert Members.count_by_athanor(pair.id) == {:ok, 2}
    refute Members.member?(carol.user_id, pair.id)
  end

  test "a group is created from the page and its creator is its only member", %{conn: conn} do
    alice = test_user()
    conn = log_in_user(conn, alice)
    {view, html} = mount_athanor(conn, "/members")
    refute_vocabulary(html)

    view
    |> form("form[phx-submit=create_group]", %{"name" => "Garden #{alice.namespace}"})
    |> render_submit()
    |> refute_vocabulary()

    assert checked_render(view) =~ "Garden #{alice.namespace}"
    [group] = Enum.filter(Athanors.list_for_user(alice.user_id), &(&1.name =~ "Garden"))
    assert Members.count_by_athanor(group.id) == {:ok, 1}
    assert Members.member?(alice.user_id, group.id)
  end

  test "a DM is named by the other person, and its roster shows names", %{conn: conn} do
    alice = test_user()
    bob = test_user()
    conn = log_in_user(conn, alice)
    record_namespace!(bob)
    {:ok, pair} = Athanors.create_pair(alice.user_id, bob.user_id)

    {view, html} = mount_athanor(conn, "/members", pair)
    refute_vocabulary(html)

    # The heading is who you are talking to, not the stored "A & B".
    assert has_element?(view, "h3", bob.email)
    refute html =~ pair.name
    assert has_element?(view, "td", "@#{alice.namespace}")
    assert has_element?(view, "td", "@#{bob.namespace}")
  end

  describe "invitation links" do
    test "a member creates a link shown once with a copy control, sees it pending, and revokes it",
         %{conn: conn} do
      alice = test_user()
      conn = log_in_user(conn, alice)
      {:ok, group} = Athanors.create_group(alice.user_id, "Links #{alice.namespace}")
      {view, html} = mount_athanor(conn, "/members", group)
      refute_vocabulary(html)

      checked_render(view)

      assert has_element?(
               view,
               "p",
               "A link makes someone new to this CYFR a person here and seats them in this group. Someone who already has a CYFR name signs in with it from the same link. It works once and expires after seven days."
             )

      refute has_element?(view, ~s([data-test="invitation-new"]))

      view
      |> element(~s([data-test="invitation-create"]))
      |> render_click()
      |> refute_vocabulary()

      link = view |> element(~s([data-test="invitation-link"])) |> checked_render() |> link_text()
      assert String.starts_with?(link, Sanctum.Person.home() <> "/invite#")
      code = link |> String.split("#") |> List.last()
      assert {:ok, %{athanor: name}} = Sanctum.Invitations.lookup(code)
      assert name == group.name
      checked_render(view)
      assert has_element?(view, ~s([data-test="invitation-copy"]))

      [%{id: id}] = Arca.Repo.all(Arca.Schemas.Invitation)
      assert has_element?(view, "#invitations button[phx-value-id='#{id}']", "Revoke")

      # Shown once: the page read again lists the link and no longer shows it.
      {again, html} = mount_athanor(conn, "/members", group)
      refute_vocabulary(html)
      refute has_element?(again, ~s([data-test="invitation-new"]))
      refute html =~ code
      assert has_element?(again, "#invitations", "pending")

      again
      |> element("#invitations button[phx-value-id='#{id}']")
      |> render_click()
      |> refute_vocabulary()

      checked_render(again)
      assert has_element?(again, "#invitations", "revoked")
      refute has_element?(again, "#invitations button[phx-value-id='#{id}']")
      assert %DateTime{} = Arca.Repo.get!(Arca.Schemas.Invitation, id).revoked_at
      assert {:error, :invitation_invalid} = Sanctum.Invitations.lookup(code)
    end

    test "lists only this group's links", %{conn: conn} do
      alice = test_user()
      conn = log_in_user(conn, alice)
      {:ok, here} = Athanors.create_group(alice.user_id, "Here #{alice.namespace}")
      {:ok, there} = Athanors.create_group(alice.user_id, "There #{alice.namespace}")
      ctx = Sanctum.TestContext.session!(alice.user_id)
      {:ok, %{invitation: mine}} = Sanctum.Invitations.create(ctx, here.id)
      {:ok, %{invitation: elsewhere}} = Sanctum.Invitations.create(ctx, there.id)

      {view, html} = mount_athanor(conn, "/members", here)
      refute_vocabulary(html)
      assert has_element?(view, "#invitations button[phx-value-id='#{mine.id}']")
      refute has_element?(view, "#invitations button[phx-value-id='#{elsewhere.id}']")
    end

    test "a person's own athanor and a direct thread offer no links", %{conn: conn} do
      alice = test_user()
      bob = test_user()
      conn = log_in_user(conn, alice)
      {:ok, pair} = Athanors.create_pair(alice.user_id, bob.user_id)

      {own, html} = mount_athanor(conn, "/members")
      refute_vocabulary(html)
      refute has_element?(own, ~s([data-test="invitation-create"]))

      {thread, html} = mount_athanor(conn, "/members", pair)
      refute_vocabulary(html)
      refute has_element?(thread, ~s([data-test="invitation-create"]))
    end
  end

  defp add_person(view, person, event \\ "add") do
    view
    |> form("form[phx-submit=#{event}]", %{"person" => person})
    |> render_submit()
    |> refute_vocabulary()

    checked_render(view)
  end

  defp checked_render(view_or_element),
    do: view_or_element |> render() |> tap(&refute_vocabulary/1)

  defp observe_writes!(view) do
    observer = self()
    handler = "members-page-#{System.unique_integer([:positive])}"
    on_exit(fn -> :telemetry.detach(handler) end)

    :ok =
      :telemetry.attach_many(
        handler,
        [[:cyfr, :sanctum, :decision, :admitted], [:cyfr, :sanctum, :decision, :refused]],
        fn _event, _measurements, %{tool: tool, action: action}, _config ->
          if self() == view.pid and action in ~w(add create remove leave use revoke),
            do: send(observer, {:page_write, tool, action})
        end,
        nil
      )
  end

  defp link_text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()

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
