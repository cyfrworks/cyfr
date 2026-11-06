# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLiveTest do
  @moduledoc """
  The sign-in page and the return. "Sign in with your account" mints a
  request bound to this browser and sends the browser to the account
  pages' sign page with it; the account pages' answer, handed over from
  the fragment, signs the person in through a one-time ticket bound to
  this browser. An answer the page cannot take signs no one in and says
  so; a CYFR with no person offers only the way to set up. The page says
  none of the words the vocabulary rule keeps from a person.
  """
  use PrismWeb.ConnCase, async: false

  import PrismWeb.Vocabulary, only: [refute_vocabulary: 1]

  alias Sanctum.Test.DirectoryServer

  @token String.duplicate("5e", 32)

  setup_all do
    %{tls: DirectoryServer.tls()}
  end

  setup %{tls: tls} do
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    DirectoryServer.listen!()
    DirectoryServer.seam!(tls)
    dir = DirectoryServer.start!(tls)
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, dir.url)
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)
    Arca.Repo.delete_all(Arca.Schemas.User)
    %{dir: dir}
  end

  # An account at the scripted directory with a passkey, and the CYFR's
  # first person by it, admitted under the setup token.
  defp first!(dir) do
    account = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)
    binding = {:browser, "first-browser"}

    {:ok, %{request: request}} =
      Sanctum.SignIn.request(:sign_in, binding, admission: {:setup, @token})

    answer = DirectoryServer.passkey_answer(request, account, hd(account.passkeys))
    {:ok, %{user: user}} = Sanctum.SignIn.answer(answer, binding)
    %{account: account, user: user}
  end

  defp passkey!(account, dir), do: DirectoryServer.add_passkey!(dir.dir, account)

  test "a CYFR with no person offers only the way to set up", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/login")

    assert has_element?(view, ~s([data-test="not-set-up"]))
    refute has_element?(view, ~s([data-test="sign-in"]))
    refute_vocabulary(html)
  end

  test "the one button sends the browser to the account pages with a request bound to it", %{
    conn: conn,
    dir: dir
  } do
    first!(dir)
    {:ok, view, html} = live(conn, ~p"/login")
    assert html =~ "Sign in with your account"
    refute_vocabulary(html)

    view |> element(~s([data-test="sign-in"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: url})

    assert String.starts_with?(url, dir.url <> "/account/sign#")
    [_page, fragment] = String.split(url, "#", parts: 2)

    assert {:ok, %{"purpose" => "sign_in", "return" => return}} =
             Prima.SignIn.parse_fragment(fragment)

    assert String.ends_with?(return, "/login")
  end

  test "the account pages' answer signs the person in through a ticket bound to this browser",
       %{conn: conn, dir: dir} do
    %{account: account} = first!(dir)
    {:ok, view, _html} = live(conn, ~p"/login")

    view |> element(~s([data-test="sign-in"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: url})
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, map} = Prima.SignIn.parse_fragment(fragment)
    {:ok, request} = Prima.SignIn.decode(map)

    answer =
      request
      |> DirectoryServer.passkey_answer(account, hd(account.passkeys))
      |> Prima.SignIn.fragment()

    render_hook(view, "account_answer", %{"answer" => answer})
    {path, _flash} = assert_redirect(view)
    assert "/auth/passkey/complete/" <> _ticket = path
  end

  test "an answer the page cannot take signs no one in and says so", %{conn: conn, dir: dir} do
    first!(dir)
    {:ok, view, _html} = live(conn, ~p"/login")

    html = render_hook(view, "account_answer", %{"answer" => "not-an-answer"})
    assert html =~ "nobody was signed in"
    refute_vocabulary(html)
  end
end
