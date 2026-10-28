# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.InviteLiveTest do
  @moduledoc """
  `/invite`: the link's code, handed over from the fragment, names who
  invited and to which athanor, and its passkey makes the person, seated
  in the group, and signs them in. An expired, a redeemed and a revoked
  code read `invitation_invalid`'s sentence, start no ceremony and create
  nothing, and so does a code revoked after the page read it.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Invitation, Membership, Passkey, User}
  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.TestContext.Authenticator

  setup do
    issuer = test_user(%{name: "Ada Issuer"})
    {:ok, group} = Athanors.create_group(issuer.user_id, "Garden #{issuer.namespace}")
    %{issuer: issuer, group: group}
  end

  defp invite!(%{issuer: issuer, group: group}) do
    ctx = Sanctum.TestContext.session!(issuer.user_id)
    {:ok, %{invitation: invitation, code: code}} = Sanctum.Invitations.create(ctx, group.id)
    {invitation.id, code}
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp passkeys, do: Arca.Repo.aggregate(Passkey, :count)

  defp seats(group),
    do: Arca.Repo.aggregate(from(m in Membership, where: m.athanor_id == ^group.id), :count)

  # The page with the link's code handed over, as its script does.
  defp opened(conn, code) do
    browser = get(conn, ~p"/invite")
    {:ok, view, _html} = live(browser, ~p"/invite")
    render_hook(view, "invite_token", %{"token" => code})
    {browser, view}
  end

  # The browser's ceremony under the options the page answered.
  defp ceremony(view) do
    render_hook(view, "invite_start", %{})
    assert_reply(view, %{public_key: public_key, registration: registration})

    Authenticator.registration(
      Authenticator.new("invite|#{System.unique_integer([:positive])}"),
      %{public_key: public_key, registration: registration}
    )
  end

  test "names who invited and to which athanor; the passkey makes the person in the group and signs them in",
       %{conn: conn, group: group} = ctx do
    {id, code} = invite!(ctx)
    {browser, view} = opened(conn, code)

    assert has_element?(view, ~s([data-test="invite-from"]), "Ada Issuer")
    assert has_element?(view, ~s([data-test="invite-athanor"]), group.name)
    assert has_element?(view, ~s([data-test="invite-expires"]))
    assert has_element?(view, ~s([data-test="invite-create"]), "Create your identity here")

    render_hook(view, "invite_passkey", %{"credential" => ceremony(view)})
    {path, _flash} = assert_redirect(view)
    assert String.starts_with?(path, "/auth/passkey/complete/")

    %{redeemed_by: user_id} = Arca.Repo.get!(Invitation, id)
    assert %User{admission: "invitation"} = Arca.Repo.get!(User, user_id)
    assert Members.member?(user_id, group.id)

    landed = get(browser, path)
    assert redirected_to(landed) == "/"
    token = get_session(landed, :sanctum_session_token)
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(token)
  end

  test "an expired, a redeemed and a revoked code say so, start no ceremony and create nothing",
       %{conn: conn, issuer: issuer, group: group} = ctx do
    {expired, expired_code} = invite!(ctx)

    {1, _} =
      Arca.Repo.update_all(from(i in Invitation, where: i.id == ^expired),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

    {_redeemed, redeemed_code} = invite!(ctx)
    {:ok, options} = Sanctum.Passkeys.newcomer_options()

    {:ok, _} =
      Sanctum.Newcomer.admit(
        {:invitation, redeemed_code},
        {:passkey, Authenticator.registration(Authenticator.new("first"), options)}
      )

    {revoked, revoked_code} = invite!(ctx)

    {:ok, _} =
      Sanctum.Invitations.revoke(Sanctum.TestContext.session!(issuer.user_id), revoked)

    before = {people(), passkeys(), seats(group)}
    sentence = Prima.Refusal.message(:invitation_invalid)

    for code <- [expired_code, redeemed_code, revoked_code] do
      {_browser, view} = opened(conn, code)
      assert has_element?(view, ~s([data-test="invite-refused"]), sentence)
      refute has_element?(view, ~s([data-test="invite-create"]))
      refute has_element?(view, ~s([data-test="invite-from"]))

      render_hook(view, "invite_start", %{})
      assert_reply(view, %{error: true})
    end

    assert {people(), passkeys(), seats(group)} == before
  end

  test "a code revoked after the page read it creates nothing when its passkey arrives",
       %{conn: conn, issuer: issuer, group: group} = ctx do
    {id, code} = invite!(ctx)
    {_browser, view} = opened(conn, code)
    credential = ceremony(view)
    before = {people(), passkeys(), seats(group)}

    {:ok, _} = Sanctum.Invitations.revoke(Sanctum.TestContext.session!(issuer.user_id), id)

    render_hook(view, "invite_passkey", %{"credential" => credential})
    assert has_element?(view, ~s([data-test="invite-refused"]))
    assert {people(), passkeys(), seats(group)} == before
  end

  test "a cancelled ceremony writes nothing and the passkey can be created again",
       %{conn: conn, group: group} = ctx do
    {_id, code} = invite!(ctx)
    {_browser, view} = opened(conn, code)
    before = people()

    render_hook(view, "invite_start", %{})
    render_hook(view, "invite_error", %{})
    assert has_element?(view, ~s([data-test="invite-error"]), "nothing was saved")
    assert has_element?(view, ~s([data-test="invite-create"]))
    assert people() == before

    render_hook(view, "invite_passkey", %{"credential" => ceremony(view)})
    {"/auth/passkey/complete/" <> _ticket, _flash} = assert_redirect(view)
    assert people() == before + 1
    assert seats(group) == 2
  end
end
