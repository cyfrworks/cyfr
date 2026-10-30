# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.InviteLiveTest do
  @moduledoc """
  `/invite`: the link's code, handed over from the fragment, names who
  invited and to which athanor, and opens the two screens, the name field
  filled with the name the invitation carries. The passkey makes the
  person, seated in the group, and their enrollment; screen 2 registers
  them at cyfr.run, pushes their recovery code once, and "I saved it"
  signs them in. Each answer of cyfr.run leaves screen 2 in its state. An
  expired, a redeemed and a revoked code read `invitation_invalid`'s
  sentence, start no ceremony and create nothing, and so does a code
  revoked after the page read it.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import PrismWeb.AdmissionScreens

  alias Arca.Schemas.{IdentityAttempt, Invitation, Membership, Passkey, User}
  alias Sanctum.Tenancy.{Athanors, Members}
  alias Sanctum.TestContext.Authenticator

  setup do
    issuer = test_user(%{name: "Ada Issuer"})
    {:ok, group} = Athanors.create_group(issuer.user_id, "Garden #{issuer.namespace}")
    %{issuer: issuer, group: group}
  end

  defp invite!(%{issuer: issuer, group: group}, name \\ nil) do
    ctx = Sanctum.TestContext.session!(issuer.user_id)

    {:ok, %{invitation: invitation, code: code}} =
      Sanctum.Invitations.create(ctx, group.id, name)

    {invitation.id, code}
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp passkeys, do: Arca.Repo.aggregate(Passkey, :count)

  defp seats(group),
    do: Arca.Repo.aggregate(from(m in Membership, where: m.athanor_id == ^group.id), :count)

  defp attempt(user_id),
    do: Arca.Repo.get_by!(IdentityAttempt, user_id: user_id, kind: "enrollment")

  # The page with the link's code handed over, as its script does.
  defp opened(conn, code) do
    browser = get(conn, ~p"/invite")
    {:ok, view, _html} = live(browser, ~p"/invite")
    render_hook(view, "invite_token", %{"token" => code})
    render(view)
    {browser, view}
  end

  test "names who invited and to which athanor; the two screens make the person in the group and sign them in",
       %{conn: conn, group: group} = ctx do
    directory!()
    registry!()
    {id, code} = invite!(ctx)
    {browser, view} = opened(conn, code)

    assert has_element?(view, "h1", "You are invited to CYFR")
    assert has_element?(view, ~s([data-test="invite-from"]), "Ada Issuer")
    assert has_element?(view, ~s([data-test="invite-athanor"]), group.name)

    assert render(view) =~
             ~r/invited you to\s+<span[^>]*>\s*#{Regex.escape(group.name)}\s*<\/span>\s+on this CYFR\.\s+This CYFR keeps your identity\./

    assert has_element?(view, ~s([data-test="invite-expires"]), "The invitation can be used once")

    assert has_element?(
             view,
             "p",
             "People find you by this name on every CYFR. It is yours for life and cannot be changed."
           )

    assert has_element?(view, "p", "This creates your name at cyfr.run under its terms.")
    assert has_element?(view, ~s([data-test="admission-name-input"][value=""]))
    assert has_element?(view, ~s([data-test="admission-create"][disabled]), "Create a passkey")
    refute_vocabulary(render(view))

    name!(view, "mira")
    assert has_element?(view, ~s([data-check="free"]))
    identity = admit!(view, "invite")

    %{redeemed_by: user_id} = Arca.Repo.get!(Invitation, id)

    assert %User{admission: "invitation", namespace: "mira"} =
             Arca.Repo.get!(User, user_id)

    assert Members.member?(user_id, group.id)

    assert screen_2?(view, :code)
    attempt = attempt(user_id)
    code = code!(view)
    assert code == Prima.RecoveryCode.encode(attempt.identifier, identity.recovery_secret)
    refute render(view) =~ code
    refute_vocabulary(render(view))
    assert get_session(browser, :sanctum_session_token) == nil

    view |> element(~s([data-test="admission-saved"])) |> render_click()
    {path, _flash} = assert_redirect(view)
    assert "/auth/passkey/complete/" <> _ticket = path

    landed = get(browser, path)
    assert redirected_to(landed) == "/"

    assert Phoenix.Flash.get(landed.assigns.flash, :info) ==
             "Saved. You can add another recovery code in Settings, and keep it apart from this one."

    token = get_session(landed, :sanctum_session_token)
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(token)
    assert %{phase: "completed"} = attempt(user_id)
  end

  test "an invitation's name fills the field, checked at once; with no athanor it names this CYFR",
       %{conn: conn, issuer: issuer} do
    directory!()
    registry!(%{"held" => :taken})
    # An invitation to no athanor is the platform administrator's.
    {:ok, _} = Sanctum.TestContext.ensure_platform(issuer.user_id)
    ctx = Sanctum.TestContext.session!(issuer.user_id)
    {:ok, %{code: code}} = Sanctum.Invitations.create(ctx, nil, "nova")
    {_browser, view} = opened(conn, code)

    refute has_element?(view, ~s([data-test="invite-athanor"]))

    assert render(view) =~
             ~r/invited you to\s+this CYFR\.\s+This CYFR keeps your identity\./

    assert has_element?(view, ~s([data-test="admission-name-input"][value="nova"]))
    assert has_element?(view, ~s([data-test="admission-name-check"][data-check="free"]))
    refute has_element?(view, ~s([data-test="admission-create"][disabled]))
    refute_vocabulary(render(view))

    # The field is the person's to change.
    name!(view, "held")
    assert has_element?(view, ~s([data-check="taken"]))
    assert has_element?(view, ~s([data-test="admission-create"][disabled]))

    name!(view, "nova")
    admit!(view, "invite")
    assert screen_2?(view, :code)

    assert [%{namespace: "nova"}] =
             Arca.Repo.all(from(u in User, where: u.admission == "invitation"))
  end

  @tag :capture_log
  test "each answer of cyfr.run leaves screen 2 in its state", %{conn: conn} = ctx do
    directory = directory!()
    registry = registry!()

    for {script, state} <- [
          {fn -> next_genesis(directory, :drop) end, :silent},
          {fn -> next_genesis(directory, :refuse) end, :refused},
          {fn -> script(registry, version: :close) end, :silent},
          {fn -> script(registry, claims: [:taken]) end, :taken},
          {fn -> script(registry, claims: [:reserved]) end, :reserved}
        ] do
      script(registry, version: :answer, claims: [])
      {_id, code} = invite!(ctx)
      {_browser, view} = opened(conn, code)
      name!(view, "n#{System.unique_integer([:positive])}")
      script.()
      admit!(view, "invite")

      assert screen_2?(view, state), "#{state}: #{render(view)}"
      refute has_element?(view, ~s([data-test="admission-saved"]))
      refute_push_event(view, "admission_code", %{})
      refute_vocabulary(render(view))
    end

    script(registry, version: :answer, claims: [])
    for app <- [:sanctum, :cyfr], do: Prima.Test.Env.put_app_env(app, :registry_url, "none")
    {_id, code} = invite!(ctx)
    {_browser, view} = opened(conn, code)
    name!(view, "last")
    admit!(view, "invite")
    assert screen_2?(view, :no_registry)
    refute_vocabulary(render(view))
  end

  test "an expired, a redeemed and a revoked code say so, start no ceremony and create nothing",
       %{conn: conn, issuer: issuer, group: group} = ctx do
    directory!()
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
        {:passkey, Authenticator.registration(Authenticator.new("first"), options),
         Sanctum.Test.Newcomers.identity()}
      )

    {revoked, revoked_code} = invite!(ctx)

    {:ok, _} =
      Sanctum.Invitations.revoke(Sanctum.TestContext.session!(issuer.user_id), revoked)

    before = {people(), passkeys(), seats(group)}
    sentence = Prima.Refusal.message(:invitation_invalid)

    for code <- [expired_code, redeemed_code, revoked_code] do
      {_browser, view} = opened(conn, code)
      assert has_element?(view, ~s([data-test="invite-refused"]), sentence)
      refute has_element?(view, ~s([data-test="admission-create"]))
      refute has_element?(view, ~s([data-test="invite-from"]))
      refute_vocabulary(render(view))

      render_hook(view, "invite_start", %{})
      assert_reply(view, %{error: true})
    end

    assert {people(), passkeys(), seats(group)} == before
  end

  test "a code revoked after the page read it creates nothing when its passkey arrives",
       %{conn: conn, issuer: issuer, group: group} = ctx do
    directory!()
    registry!()
    {id, code} = invite!(ctx)
    {_browser, view} = opened(conn, code)
    name!(view, "mira")
    credential = ceremony(view, "invite")
    before = {people(), passkeys(), seats(group)}

    {:ok, _} = Sanctum.Invitations.revoke(Sanctum.TestContext.session!(issuer.user_id), id)

    admit!(view, "invite", credential)
    assert has_element?(view, ~s([data-test="invite-refused"]))
    assert {people(), passkeys(), seats(group)} == before
  end

  test "a cancelled ceremony writes nothing and the passkey can be created again",
       %{conn: conn, group: group} = ctx do
    directory!()
    registry!()
    {_id, code} = invite!(ctx)
    {_browser, view} = opened(conn, code)
    name!(view, "mira")
    before = people()

    render_hook(view, "invite_start", %{})
    render_hook(view, "invite_error", %{})

    assert has_element?(
             view,
             ~s([data-test="admission-error"]),
             "The passkey was not created, so nothing was saved. Try again."
           )

    assert has_element?(view, ~s([data-test="admission-create"]))
    assert people() == before

    admit!(view, "invite")
    assert screen_2?(view, :code)
    assert people() == before + 1
    assert seats(group) == 2
  end
end
