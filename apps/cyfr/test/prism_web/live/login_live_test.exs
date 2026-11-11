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

  describe "a registry signature's return" do
    # The first person signed in in this browser, and the registry request
    # their session asked for through the registry tool, as the registry
    # page asks: the browser's conn, the request, and the account.
    defp asked!(conn, dir, args) do
      %{account: account, user: user} = first!(dir)
      {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(user.id)

      {:ok, session} =
        Sanctum.TestContext.create_session(
          Sanctum.Context.build(
            user_id: user.id,
            athanor_id: athanor_id,
            provider: "passkey",
            permissions: Sanctum.Context.person_permissions(),
            auth_method: :oidc,
            authenticated: true
          )
        )

      {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor_id, refresh: false)

      {:ok, %{request: map, url: url}} = Compendium.Providers.Registry.handle(ctx, args)
      assert String.starts_with?(url, dir.url <> "/account/sign#")
      {:ok, request} = Prima.SignIn.decode(map)

      %{
        conn: Plug.Test.init_test_session(conn, %{session_key() => session.token}),
        ctx: ctx,
        request: request,
        account: account
      }
    end

    defp signed_at_pages(%{request: request, account: account}) do
      request
      |> DirectoryServer.passkey_answer(account, hd(account.passkeys))
      |> Prima.SignIn.fragment()
    end

    # The registry, checking each request as the registry does under the
    # account's log, and answering `answer.(request)`.
    defp registry(account, answer) do
      {:ok, state} = Prima.Identity.verify_chain(account.log)

      Sanctum.Test.RegistryStub.start!(fn %{body: body} = request ->
        case Prima.RegistryRequest.verify(
               body,
               state,
               %{host: Sanctum.Test.RegistryStub.host(), directory: account.url},
               System.system_time(:millisecond)
             ) do
          {:ok, signed} -> answer.(Map.put(request, :signed, signed))
          {:error, reason} -> flunk("the registry refused the request: #{inspect(reason)}")
        end
      end)
    end

    test "completes the sync the passkey signed, under the session that asked, and says so",
         %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "sync"})

      registry(asked.account, fn %{path: "/v1/tokens/mint"} ->
        {200,
         Sanctum.Test.RegistryStub.answer(%{
           "personal_namespace" => %{"slug" => "page-person", "token" => "cyfr_pt_page"},
           "memberships" => []
         })}
      end)

      {:ok, view, _html} = live(asked.conn, ~p"/login")
      render_hook(view, "account_answer", %{"answer" => signed_at_pages(asked)})

      assert {"/", %{"info" => "Your push tokens are synced."}} = assert_redirect(view)
      assert_received {:registry_request, %{method: "POST", path: "/v1/tokens/mint"}}

      assert {:ok, %{token: "cyfr_pt_page"}} =
               Compendium.Registry.CredentialStore.get(
                 asked.ctx,
                 Compendium.RegistryHost.canonical_host(),
                 "page-person"
               )

      assert {:ok, %{namespace: "page-person"}} = Sanctum.Tenancy.Users.get(asked.ctx.user_id)
    end

    test "a sync signed while the session store could not answer the page's opening completes once it answers",
         %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "sync"})

      registry(asked.account, fn %{path: "/v1/tokens/mint"} ->
        {200,
         Sanctum.Test.RegistryStub.answer(%{
           "personal_namespace" => %{"slug" => "page-person", "token" => "cyfr_pt_page"},
           "memberships" => []
         })}
      end)

      try do
        Arca.Repo.query!("ALTER TABLE sessions RENAME TO sessions_unavailable")
        {:ok, view, _html} = live(asked.conn, ~p"/login")
        Arca.Repo.query!("ALTER TABLE sessions_unavailable RENAME TO sessions")

        render_hook(view, "account_answer", %{"answer" => signed_at_pages(asked)})
        assert {"/", %{"info" => "Your push tokens are synced."}} = assert_redirect(view)
        assert_received {:registry_request, %{method: "POST", path: "/v1/tokens/mint"}}
      after
        Arca.Repo.query("ALTER TABLE sessions_unavailable RENAME TO sessions")
      end
    end

    test "the page never keeps the session's token", %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "sync"})
      token = Plug.Conn.get_session(asked.conn, session_key())
      assert is_binary(token)

      {:ok, view, _html} = live(asked.conn, ~p"/login")
      assigns = :sys.get_state(view.pid).socket.assigns

      refute inspect(assigns, limit: :infinity, printable_limit: :infinity) =~ token
    end

    test "a registry's refusal is the flash the browser returns with, in a person's words",
         %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "legal_accept", "policy_version" => "2026-09"})

      registry(asked.account, fn _request ->
        Sanctum.Test.RegistryStub.refusal(:unknown_identity)
      end)

      {:ok, view, _html} = live(asked.conn, ~p"/login")

      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(view, "account_answer", %{"answer" => signed_at_pages(asked)})
      end)

      assert {"/", %{"error" => message}} = assert_redirect(view)
      assert message =~ "This account is not registered."
      refute_vocabulary(message)
    end

    test "returned in a browser without the session that asked, it is sent nowhere",
         %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "legal_accept", "policy_version" => "2026-09"})
      registry(asked.account, fn _request -> flunk("nothing is sent") end)

      {:ok, view, _html} = live(conn, ~p"/login")
      html = render_hook(view, "account_answer", %{"answer" => signed_at_pages(asked)})

      assert html =~ "nobody was signed in"
      refute_received {:registry_request, _}
    end
  end

  test "an answer the page cannot take signs no one in and says so", %{conn: conn, dir: dir} do
    first!(dir)
    {:ok, view, _html} = live(conn, ~p"/login")

    html = render_hook(view, "account_answer", %{"answer" => "not-an-answer"})
    assert html =~ "nobody was signed in"
    refute_vocabulary(html)
  end
end
