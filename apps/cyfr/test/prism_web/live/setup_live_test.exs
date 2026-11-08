# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SetupLiveTest do
  @moduledoc """
  `/setup`: the setup link's token, handed over from the fragment, opens
  the page while no person is here: "Sign in with your account" and
  "Create your account" each send the browser to the account pages with
  a sign-in request holding the token. A token that is not this CYFR's,
  or a CYFR set up already, goes to `/`. The page says none of the words
  the vocabulary rule keeps from a person.
  """
  use PrismWeb.ConnCase, async: false

  import PrismWeb.Vocabulary, only: [refute_vocabulary: 1]

  alias Sanctum.Test.DirectoryServer

  @token String.duplicate("5e", 32)

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, "https://dir.example")
    Arca.Repo.delete_all(Arca.Schemas.User)
    :ok
  end

  test "the token opens both ways to the account pages, each holding it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")
    html = render_hook(view, "account_token", %{"token" => @token})

    assert html =~ "Sign in with your account"
    assert html =~ "Create your account"
    refute_vocabulary(html)

    view |> element(~s([data-test="setup-sign-in"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: sign})
    assert String.starts_with?(sign, "https://dir.example/account/sign#")

    view |> element(~s([data-test="setup-create"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: new})
    assert String.starts_with?(new, "https://dir.example/account/new#name=&request=")
  end

  test "Create your account offers no name, so the first person's answer asks the registry for the account's name by its identifier and records none while it holds none",
       %{conn: conn} do
    tls = DirectoryServer.tls()
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Sanctum.Test.RegistryStub.handles!(%{}, dir.url)

    # One browser across the setup page and the sign-in page: the forgery
    # token its session holds binds the request to it.
    conn =
      Plug.Test.init_test_session(conn, %{
        "_csrf_token" => Base.url_encode64(:crypto.strong_rand_bytes(18))
      })

    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "account_token", %{"token" => @token})
    view |> element(~s([data-test="setup-create"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: url})
    assert [_page, fragment] = String.split(url, "#name=&request=", parts: 2)

    account = DirectoryServer.add_passkey!(dir.dir, DirectoryServer.account!(dir.dir, dir.url))
    {:ok, map} = Prima.SignIn.parse_fragment(fragment)
    {:ok, request} = Prima.SignIn.decode(map)

    answer =
      request
      |> DirectoryServer.passkey_answer(account, hd(account.passkeys))
      |> Prima.SignIn.fragment()

    {:ok, login, _html} = live(conn, ~p"/login")
    render_hook(login, "account_answer", %{"answer" => answer})
    assert {"/auth/passkey/complete/" <> _ticket, _flash} = assert_redirect(login)

    assert {:ok, %{namespace: nil}} = Sanctum.Tenancy.Users.get_by_identifier(account.identifier)
    assert_received {:registry_request, %{path: "/v1/identities/" <> rest}}
    assert rest == account.identifier <> "/handle"
    refute_received {:registry_request, %{path: "/v1/handles/" <> _}}
  end

  test "a token that is not this CYFR's goes to /", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "account_token", %{"token" => String.duplicate("00", 32)})
    assert_redirect(view, ~p"/")
  end

  test "a CYFR set up already goes to /", %{conn: conn} do
    {_person, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    {:ok, view, _html} = live(conn, ~p"/setup")
    render_hook(view, "account_token", %{"token" => @token})
    assert_redirect(view, ~p"/")
  end
end
