# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SetupLiveTest do
  @moduledoc """
  `/setup`: the setup link's token, handed over from the fragment, opens
  the first person's passkey; the registration makes that person, their
  athanor, the passkey and the platform grant, and signs them in back on
  this page, where the handle is offered and skipping goes into CYFR. A
  token that is not this CYFR's, and a CYFR set up already, are one
  answer, and no ceremony starts.
  """

  # The setup token is process-wide configuration.
  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Schemas.{Membership, Passkey, User}
  alias Sanctum.TestContext.Authenticator

  @token String.duplicate("5e", 32)

  setup do
    previous = Application.fetch_env(:sanctum, :setup_token)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sanctum, :setup_token, value)
        :error -> Application.delete_env(:sanctum, :setup_token)
      end
    end)

    Application.put_env(:sanctum, :setup_token, @token)

    # The installation holds no person inside this test's transaction,
    # whatever the suite committed: the first person is the question.
    Arca.Repo.delete_all(User)
    :ok
  end

  defp people, do: Arca.Repo.aggregate(User, :count)
  defp passkeys, do: Arca.Repo.aggregate(Passkey, :count)

  defp grants,
    do: Arca.Repo.aggregate(from(m in Membership, where: m.scope == "platform"), :count)

  # The page with the link's token handed over, as its script does.
  defp opened(conn, token) do
    browser = get(conn, ~p"/setup")
    {:ok, view, _html} = live(browser, ~p"/setup")
    render_hook(view, "setup_token", %{"token" => token})
    {browser, view}
  end

  # The browser's ceremony under the options the page answered.
  defp ceremony(view) do
    render_hook(view, "setup_start", %{})
    assert_reply(view, %{public_key: public_key, registration: registration})

    Authenticator.registration(
      Authenticator.new("setup|#{System.unique_integer([:positive])}"),
      %{public_key: public_key, registration: registration}
    )
  end

  test "the link's passkey makes the first person, their administrator grant, and signs them in back here",
       %{conn: conn} do
    {browser, view} = opened(conn, @token)
    assert has_element?(view, ~s([data-test="setup-create"]))

    render_hook(view, "setup_passkey", %{"credential" => ceremony(view)})
    {path, _flash} = assert_redirect(view)
    assert String.starts_with?(path, "/auth/passkey/complete/")

    assert {people(), passkeys(), grants()} == {1, 1, 1}
    [%{id: user_id, admission: "setup"}] = Arca.Repo.all(User)

    landed = get(browser, path)
    assert redirected_to(landed, 303) == "/setup"
    token = get_session(landed, :sanctum_session_token)
    assert {:ok, %{user_id: ^user_id}} = Sanctum.Session.load(token)

    # Signed in, the page offers a handle and the way into CYFR.
    {:ok, signed_in, _html} = live(recycle(landed), ~p"/setup")
    assert has_element?(signed_in, ~s([data-test="setup-done"]))
    assert has_element?(signed_in, ~s([data-test="identity"][data-state="choose"]))
    assert has_element?(signed_in, ~s([data-test="identity-handle"]))
    assert has_element?(signed_in, ~s([data-test="setup-continue"][href="/"]))
    refute has_element?(signed_in, ~s([data-test="setup-create"]))
  end

  test "a wrong token, a missing one and a CYFR with no setup token are one answer, and start no ceremony",
       %{conn: conn} do
    for token <- [String.duplicate("0f", 32), "", "not-hex"] do
      {_browser, view} = opened(conn, token)
      assert has_element?(view, ~s([data-test="setup-closed"]), "not valid, or setup is complete")
      refute has_element?(view, ~s([data-test="setup-create"]))

      render_hook(view, "setup_start", %{})
      assert_reply(view, %{error: true})
    end

    Application.delete_env(:sanctum, :setup_token)
    {_browser, view} = opened(conn, @token)
    assert has_element?(view, ~s([data-test="setup-closed"]))
    assert people() == 0
  end

  test "a second tab after setup is sent to sign in, and its ceremony writes nothing", %{
    conn: conn
  } do
    {_browser, first} = opened(conn, @token)
    {_browser, second} = opened(conn, @token)
    second_credential = ceremony(second)

    render_hook(first, "setup_passkey", %{"credential" => ceremony(first)})
    assert {people(), passkeys()} == {1, 1}

    # The open tab's registration is refused at the admission, which
    # holds the person's passkey now.
    render_hook(second, "setup_passkey", %{"credential" => second_credential})
    assert has_element?(second, ~s([data-test="setup-closed"]))
    assert has_element?(second, ~s(a[href="/login"]))
    assert {people(), passkeys()} == {1, 1}

    # A tab opened now is told so before any ceremony.
    {_browser, third} = opened(conn, @token)
    assert has_element?(third, ~s([data-test="setup-closed"]))
  end

  test "a cancelled ceremony writes nothing and the passkey can be created again", %{conn: conn} do
    {_browser, view} = opened(conn, @token)
    render_hook(view, "setup_start", %{})
    render_hook(view, "setup_error", %{})

    assert has_element?(view, ~s([data-test="setup-error"]), "nothing was saved")
    assert has_element?(view, ~s([data-test="setup-create"]))
    assert {people(), passkeys(), grants()} == {0, 0, 0}

    render_hook(view, "setup_passkey", %{"credential" => ceremony(view)})
    {"/auth/passkey/complete/" <> _ticket, _flash} = assert_redirect(view)
    assert people() == 1
  end

  test "a registration that does not verify writes nothing", %{conn: conn} do
    {_browser, view} = opened(conn, @token)
    credential = ceremony(view) |> put_in(["response", "clientDataJSON"], "e30")

    render_hook(view, "setup_passkey", %{"credential" => credential})
    assert has_element?(view, ~s([data-test="setup-error"]), "could not be registered")
    assert {people(), passkeys(), grants()} == {0, 0, 0}
  end

  test "a person set up from the command line registers their passkey here, the same person again",
       %{conn: conn} do
    {:ok, %{person: person}} =
      Sanctum.Newcomer.admit({:setup, @token}, {:command_line, "laptop"})

    {_browser, view} = opened(conn, @token)
    render_hook(view, "setup_passkey", %{"credential" => ceremony(view)})
    {"/auth/passkey/complete/" <> _ticket, _flash} = assert_redirect(view)

    assert [%{id: user_id}] = Arca.Repo.all(User)
    assert user_id == person.id
    assert [%{user_id: ^user_id}] = Arca.Repo.all(Passkey)

    # The passkey closes setup.
    {_browser, again} = opened(conn, @token)
    assert has_element?(again, ~s([data-test="setup-closed"]))
  end
end
