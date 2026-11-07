# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.InviteLiveTest do
  @moduledoc """
  `/invite`: the link's code, handed over from the fragment, names who
  invited and until when, and "Sign in with your account" and "Create
  your account" each send the browser to the account pages with a sign-in
  request holding the code's hash, never the code; the new page is
  offered the name the invitation carries. A code that admits no one is
  one sentence. The page says none of the words the vocabulary rule keeps
  from a person.
  """
  use PrismWeb.ConnCase, async: false

  import PrismWeb.Vocabulary, only: [refute_vocabulary: 1]

  alias Sanctum.Test.DirectoryServer

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, "https://dir.example")

    {admin, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    {:ok, _row} = Sanctum.TestContext.ensure_platform(user.id)

    {:ok, %{code: code}} =
      Sanctum.Invitations.create(%{admin | platform_admin: true}, nil, "mira")

    %{code: code}
  end

  test "names the invitation, and sends the browser to the account pages with its hash", %{
    conn: conn,
    code: code
  } do
    {:ok, view, _html} = live(conn, ~p"/invite")
    html = render_hook(view, "account_token", %{"token" => code})

    assert has_element?(view, ~s([data-test="invite-from"]))
    assert has_element?(view, ~s([data-test="invite-expires"]))
    refute_vocabulary(html)

    view |> element(~s([data-test="invite-create"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: url})
    assert String.starts_with?(url, "https://dir.example/account/new#name=mira&request=")
    refute url =~ code

    view |> element(~s([data-test="invite-sign-in"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: sign})
    assert String.starts_with?(sign, "https://dir.example/account/sign#")
  end

  describe "Create your account" do
    # The account the newcomer makes at a scripted directory with a
    # passkey, and the answer the new page returns for the request in
    # `url`, as the account pages hand it to the sign-in page.
    defp made!(url) do
      dir = served!()
      account = DirectoryServer.add_passkey!(dir.dir, DirectoryServer.account!(dir.dir, dir.url))
      [_page, request] = String.split(url, "request=", parts: 2)
      {:ok, map} = Prima.SignIn.parse_fragment(request)
      {:ok, request} = Prima.SignIn.decode(map)
      answer = DirectoryServer.passkey_answer(request, account, hd(account.passkeys))
      %{account: account, dir: dir, answer: Prima.SignIn.fragment(answer)}
    end

    defp served! do
      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      dir = DirectoryServer.start!(tls)
      Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
      dir
    end

    # One browser across the invitation page and the sign-in page: the
    # forgery token its session holds binds the request to it.
    defp browser(conn) do
      csrf = Base.url_encode64(:crypto.strong_rand_bytes(18))
      Plug.Test.init_test_session(conn, %{"_csrf_token" => csrf})
    end

    defp created(conn, code) do
      {:ok, view, _html} = live(conn, ~p"/invite")
      render_hook(view, "account_token", %{"token" => code})
      view |> element(~s([data-test="invite-create"])) |> render_click()
      assert_push_event(view, "account:hop", %{url: url})
      url
    end

    defp signed_in(conn, answer) do
      {:ok, login, _html} = live(conn, ~p"/login")
      render_hook(login, "account_answer", %{"answer" => answer})
      assert {"/auth/passkey/complete/" <> _ticket, _flash} = assert_redirect(login)
    end

    test "records the offered name once the registry says the new account holds it", %{
      conn: conn,
      code: code
    } do
      conn = browser(conn)
      %{account: account, dir: dir, answer: answer} = made!(created(conn, code))
      Sanctum.Test.RegistryStub.handles!(%{"mira" => account.identifier}, dir.url)

      signed_in(conn, answer)

      assert {:ok, %{namespace: "mira"}} =
               Sanctum.Tenancy.Users.get_by_identifier(account.identifier)
    end

    test "records nothing when the registry names another account by the offered name", %{
      conn: conn,
      code: code
    } do
      conn = browser(conn)
      %{account: account, dir: dir, answer: answer} = made!(created(conn, code))
      stranger = DirectoryServer.account!(dir.dir, dir.url)
      Sanctum.Test.RegistryStub.handles!(%{"mira" => stranger.identifier}, dir.url)

      signed_in(conn, answer)

      assert {:ok, %{namespace: nil}} =
               Sanctum.Tenancy.Users.get_by_identifier(account.identifier)
    end
  end

  test "a code that admits no one is one sentence", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invite")
    render_hook(view, "account_token", %{"token" => "unknown"})

    assert has_element?(view, ~s([data-test="invite-refused"]))
    assert render(view) =~ Prima.Refusal.message(:invitation_invalid)
  end
end
