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

  test "a code that admits no one is one sentence", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invite")
    render_hook(view, "account_token", %{"token" => "unknown"})

    assert has_element?(view, ~s([data-test="invite-refused"]))
    assert render(view) =~ Prima.Refusal.message(:invitation_invalid)
  end
end
