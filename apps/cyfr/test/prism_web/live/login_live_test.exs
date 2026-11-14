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

  import Ecto.Query, only: [from: 2]
  import PrismWeb.Vocabulary, only: [refute_vocabulary: 1]

  alias Sanctum.Test.DirectoryServer

  @token String.duplicate("5e", 32)

  # How long a test waits for the registry's answer to reach the page,
  # which comes after the event has answered.
  @answered_ms 5_000

  # The browser gives up on a pushed event it waits on for 30 seconds and
  # reloads (the shipped script's push timeout); a test stands that wait
  # in with this one.
  @push_timeout_ms 1_000

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
    {:ok, %{user: user, session_token: token}} = Sanctum.SignIn.answer(answer, binding)
    %{account: account, user: user, session_token: token}
  end

  # A browser holding `token`'s session, as its cookie carries it.
  defp with_session(conn, token),
    do:
      Plug.Test.init_test_session(conn, %{
        to_string(CyfrWeb.SignInResponse.session_key()) => token
      })

  # The answer `account`'s passkey gives `request`, as the account pages
  # hand it to the page.
  defp answer_of(request, account),
    do:
      request
      |> DirectoryServer.passkey_answer(account, hd(account.passkeys))
      |> Prima.SignIn.fragment()

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
    {path, _flash} = assert_redirect(view, @answered_ms)
    assert "/auth/passkey/complete/" <> _ticket = path
  end

  # The account's directory, read for an account this CYFR has not read
  # yet, holds the read here until the test releases it, past the
  # browser's 30 s wait on the event (stood in for by `@push_timeout_ms`).
  test "an answer whose account's directory is slow answers at once, says it is checking, checks once, and shows its outcome",
       %{conn: conn, dir: dir, tls: tls} do
    first!(dir)
    test = self()
    inner = DirectoryServer.handler(dir.dir)

    slow =
      DirectoryServer.Server.start(
        tls[:server_config],
        fn request ->
          send(test, {:held, self()})

          receive do
            :release -> :ok
          end

          inner.(request)
        end,
        self()
      )

    on_exit(fn -> DirectoryServer.Server.stop(slow) end)
    url = "https://dir-a.test:#{slow.port}"
    Prima.Test.Env.put_app_env(:sanctum, :directory_url, url)
    newcomer = dir.dir |> DirectoryServer.account!(url) |> passkey!(dir)

    {:ok, view, _html} = live(conn, ~p"/login")
    view |> element(~s([data-test="sign-in"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: hop})
    [_page, fragment] = String.split(hop, "#", parts: 2)
    {:ok, map} = Prima.SignIn.parse_fragment(fragment)
    {:ok, request} = Prima.SignIn.decode(map)

    answer =
      request
      |> DirectoryServer.passkey_answer(newcomer, hd(newcomer.passkeys))
      |> Prima.SignIn.fragment()

    html = handed(view, answer)
    assert_receive {:held, held}, @answered_ms

    try do
      assert is_binary(html), "the page did not answer while the directory held the read"
      assert html =~ "Checking what you signed."
      refute_vocabulary(html)

      # The same answer again starts no second check.
      assert is_binary(handed(view, answer))
      Process.sleep(2 * @push_timeout_ms)
      assert render(view) =~ "Checking what you signed."
    after
      send(held, :release)
    end

    # The door does not admit this account: the page says so, as it does
    # for any answer the door refuses.
    html = render_async(view, @answered_ms)
    assert html =~ Sanctum.Door.refusal_message()
    refute html =~ "Checking what you signed."
    refute_receive {:held, _second}, 500
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

    # A sync signed for a person whose account's head is stale, so the check
    # reads the directory, which holds the read until the test releases it:
    # answers the request asked, the page and the held read.
    defp checking!(conn, dir, tls) do
      observer = self()
      armed = :atomics.new(1, [])
      inner = DirectoryServer.handler(dir.dir)

      slow =
        DirectoryServer.Server.start(
          tls[:server_config],
          fn request ->
            if :atomics.get(armed, 1) == 1 do
              send(observer, {:checking_held, self()})

              receive do
                :release_check -> :ok
              end

              :atomics.put(armed, 1, 0)
            end

            inner.(request)
          end,
          self()
        )

      on_exit(fn -> DirectoryServer.Server.stop(slow) end)
      url = "https://dir-a.test:#{slow.port}"
      Prima.Test.Env.put_app_env(:sanctum, :directory_url, url)
      asked = asked!(conn, %{dir | url: url}, %{"action" => "sync"})
      identifier = asked.account.identifier

      Arca.Repo.update_all(
        from(h in Arca.Schemas.DirectoryHead, where: h.identifier == ^identifier),
        set: [verified_at: DateTime.add(DateTime.utc_now(), -31_536_000, :second)]
      )

      registry(asked.account, fn %{path: "/v1/tokens/mint"} ->
        send(observer, :minted)

        {200,
         Sanctum.Test.RegistryStub.answer(%{
           "personal_namespace" => %{"slug" => "left-person", "token" => "cyfr_pt_left-person"},
           "memberships" => []
         })}
      end)

      :atomics.put(armed, 1, 1)
      {:ok, view, _html} = live(asked.conn, ~p"/login")
      assert is_binary(handed(view, signed_at_pages(asked)))
      assert_receive {:checking_held, held}, @answered_ms
      {asked, view, held}
    end

    # The request is spent when the check begins; what it asked for is done
    # by the call that outlives the page, never by a page that left.
    test "a sync whose answer is still being checked when the person leaves is completed and stored",
         %{conn: conn, dir: dir, tls: tls} do
      {asked, view, held} = checking!(conn, dir, tls)
      {_ref, _topic, proxy} = view.proxy
      Process.unlink(proxy)
      page = Process.monitor(view.pid)
      GenServer.stop(view.pid, {:shutdown, :closed})
      assert_receive {:DOWN, ^page, :process, _pid, {:shutdown, :closed}}, @answered_ms

      send(held, :release_check)
      assert_receive :minted, @answered_ms

      Prima.Test.Wait.wait_until(
        fn ->
          match?(
            {:ok, %{token: "cyfr_pt_left-person"}},
            Compendium.Registry.CredentialStore.get(
              asked.ctx,
              Compendium.RegistryHost.canonical_host(),
              "left-person"
            )
          )
        end,
        @answered_ms,
        "the push token the registry minted to be stored"
      )
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

      assert {"/", %{"info" => "Your push tokens are synced."}} =
               assert_redirect(view, @answered_ms)

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

        assert {"/", %{"info" => "Your push tokens are synced."}} =
                 assert_redirect(view, @answered_ms)

        assert_received {:registry_request, %{method: "POST", path: "/v1/tokens/mint"}}
      after
        Arca.Repo.query("ALTER TABLE sessions_unavailable RENAME TO sessions")
      end
    end

    # A registry that holds the mint until the test releases it, then
    # answers it: the test is told `{:held, stub}` while it holds, and
    # `:answered` once it answers.
    defp held_mint(account, slug) do
      test = self()

      registry(account, fn %{path: "/v1/tokens/mint"} ->
        send(test, {:held, self()})

        receive do
          :release -> :ok
        end

        send(test, :answered)

        {200,
         Sanctum.Test.RegistryStub.answer(%{
           "personal_namespace" => %{"slug" => slug, "token" => "cyfr_pt_" <> slug},
           "memberships" => []
         })}
      end)
    end

    # The account pages' answer handed to the page as the browser hands it:
    # a push waited on no longer than the browser waits (`@push_timeout_ms`).
    defp handed(view, answer) do
      task = Task.async(fn -> render_hook(view, "account_answer", %{"answer" => answer}) end)

      case Task.yield(task, @push_timeout_ms) do
        {:ok, html} -> html
        nil -> :unanswered
      end
    end

    test "the page answers at once, says it is checking, and shows the registry's answer whenever it comes",
         %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "sync"})
      held_mint(asked.account, "slow-person")
      answer = signed_at_pages(asked)

      {:ok, view, _html} = live(asked.conn, ~p"/login")
      html = handed(view, answer)
      assert_receive {:held, stub}, @answered_ms

      try do
        assert is_binary(html), "the page did not answer while the registry held the request"
        html = render(view)
        assert html =~ "Checking what you signed."
        refute_vocabulary(html)

        # The same answer again starts no second call: its request was taken.
        assert is_binary(handed(view, answer))

        # Held past the browser's wait, and past it twice, the page still
        # waits for the registry.
        Process.sleep(2 * @push_timeout_ms)
        assert render(view) =~ "Checking what you signed."
      after
        send(stub, :release)
      end

      assert {"/", %{"info" => "Your push tokens are synced."}} =
               assert_redirect(view, @answered_ms)

      assert_received {:registry_request, %{path: "/v1/tokens/mint"}}
      refute_received {:registry_request, _second}
    end

    test "a mint the registry makes after the person left is stored", %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "sync"})
      held_mint(asked.account, "gone-person")

      {:ok, view, _html} = live(asked.conn, ~p"/login")
      assert is_binary(handed(view, signed_at_pages(asked)))
      assert_receive {:held, stub}, @answered_ms

      # The browser's connection gone: the page stops as a closed socket
      # stops it.
      {_ref, _topic, proxy} = view.proxy
      Process.unlink(proxy)
      page = Process.monitor(view.pid)
      GenServer.stop(view.pid, {:shutdown, :closed})
      assert_receive {:DOWN, ^page, :process, _pid, {:shutdown, :closed}}, @answered_ms

      send(stub, :release)
      assert_receive :answered, @answered_ms

      Prima.Test.Wait.wait_until(
        fn ->
          match?(
            {:ok, %{token: "cyfr_pt_gone-person"}},
            Compendium.Registry.CredentialStore.get(
              asked.ctx,
              Compendium.RegistryHost.canonical_host(),
              "gone-person"
            )
          )
        end,
        @answered_ms,
        "the minted token to be stored"
      )

      assert {:ok, %{namespace: "gone-person"}} = Sanctum.Tenancy.Users.get(asked.ctx.user_id)
    end

    test "a session revoked while the registry answers stores no namespace or token", %{
      conn: conn,
      dir: dir
    } do
      asked = asked!(conn, dir, %{"action" => "sync"})
      held_mint(asked.account, "revoked-person")
      {:ok, before} = Sanctum.Tenancy.Users.get(asked.ctx.user_id)
      {:ok, view, _html} = live(asked.conn, ~p"/login")
      assert is_binary(handed(view, signed_at_pages(asked)))
      assert_receive {:held, stub}, @answered_ms
      assert {:ok, count} = Sanctum.Session.revoke_all_for_user(asked.ctx.user_id)
      assert count > 0
      send(stub, :release)
      assert {"/", %{"error" => message}} = assert_redirect(view, @answered_ms)
      assert message =~ "That did not go through"

      assert {:error, :not_found} =
               Compendium.Registry.CredentialStore.get(
                 asked.ctx,
                 Compendium.RegistryHost.canonical_host(),
                 "revoked-person"
               )

      assert {:ok, after_user} = Sanctum.Tenancy.Users.get(asked.ctx.user_id)
      assert after_user.namespace == before.namespace
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

      assert {"/", %{"error" => message}} = assert_redirect(view, @answered_ms)
      assert message =~ "This account is not registered."
      refute_vocabulary(message)
    end

    test "returned in a browser without the session that asked, it is sent nowhere",
         %{conn: conn, dir: dir} do
      asked = asked!(conn, dir, %{"action" => "legal_accept", "policy_version" => "2026-09"})
      registry(asked.account, fn _request -> flunk("nothing is sent") end)

      {:ok, view, _html} = live(conn, ~p"/login")
      render_hook(view, "account_answer", %{"answer" => signed_at_pages(asked)})
      html = render_async(view, @answered_ms)

      assert html =~ "nobody was signed in"
      refute_received {:registry_request, _}
    end
  end

  test "an answer the page cannot take signs no one in and says so", %{conn: conn, dir: dir} do
    first!(dir)
    {:ok, view, _html} = live(conn, ~p"/login")

    render_hook(view, "account_answer", %{"answer" => "not-an-answer"})
    html = render_async(view, @answered_ms)
    assert html =~ "nobody was signed in"
    refute_vocabulary(html)
  end

  test "Create your account sends the browser to the new-account page with a request bound to it",
       %{conn: conn, dir: dir} do
    first!(dir)
    {:ok, view, html} = live(conn, ~p"/login")
    assert html =~ "Create your account"

    view |> element(~s([data-test="create-account"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: url})
    assert String.starts_with?(url, dir.url <> "/account/new#name=&request=")
    [_page, fragment] = String.split(url, "&request=", parts: 2)

    assert {:ok, %{"purpose" => "sign_in", "return" => return}} =
             Prima.SignIn.parse_fragment(fragment)

    assert String.ends_with?(return, "/login")
  end

  test "signing out lands on the sign-in page saying so", %{conn: conn, dir: dir} do
    first!(dir)
    {:ok, view, html} = live(conn, ~p"/login?error=signed_out")
    assert view |> element(~s([data-test="sign-in-notice"])) |> render() =~ "You signed out."
    refute has_element?(view, ~s([data-test="sign-in-error"]))
    refute_vocabulary(html)
  end

  test "a person this CYFR has not let in reads who can, in one sentence whatever the reason",
       %{conn: conn, dir: dir} do
    first!(dir)
    stranger = dir.dir |> DirectoryServer.account!(dir.url) |> passkey!(dir)
    {:ok, view, _html} = live(conn, ~p"/login")

    view |> element(~s([data-test="sign-in"])) |> render_click()
    assert_push_event(view, "account:hop", %{url: url})
    [_page, fragment] = String.split(url, "#", parts: 2)
    {:ok, request} = fragment |> Prima.SignIn.parse_fragment() |> elem(1) |> Prima.SignIn.decode()

    render_hook(view, "account_answer", %{"answer" => answer_of(request, stranger)})
    html = render_async(view, @answered_ms)
    sentence = "This CYFR has not let you in. Whoever runs it can let you in."
    assert view |> element(~s([data-test="sign-in-error"])) |> render() =~ sentence
    assert Prima.Refusal.message({:door, :denied}) == sentence
    assert Prima.Refusal.message({:door, :not_allowed}) == sentence
    refute_vocabulary(html)
  end

  test "a sign-in from a tab whose sign-in another tab replaced says this browser is signed in",
       %{conn: conn, dir: dir} do
    %{account: account, session_token: token} = first!(dir)
    {:ok, %{request: request}} = Sanctum.SignIn.request(:sign_in, {:browser, "an-earlier-tab"})
    {:ok, view, _html} = conn |> with_session(token) |> live(~p"/login")

    render_hook(view, "account_answer", %{"answer" => answer_of(request, account)})
    render_async(view, @answered_ms)
    error = view |> element(~s([data-test="sign-in-error"])) |> render()
    assert error =~ "This browser is signed in already, from another tab."
    assert error =~ ~s(href="/")
    refute error =~ "nobody was signed in"
  end

  test "a confirmation that names no page to return to says it is done and closes its tab",
       %{conn: conn, dir: dir} do
    %{account: account, user: user, session_token: token} = first!(dir)
    {:ok, %{id: athanor_id}} = Sanctum.Tenancy.Athanors.get_by_owner(user.id)
    hash = Sanctum.Session.token_hash(token)

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        athanor_id: athanor_id,
        provider: "passkey",
        auth_method: :oidc,
        authenticated: true,
        session_token_hash: hash,
        permissions: Sanctum.Context.person_permissions()
      )

    {:ok, record} =
      Prima.Confirmation.new(
        id: Prima.Confirmation.ref("cnf_" <> Base.url_encode64(:crypto.strong_rand_bytes(32))),
        home: Sanctum.origin(),
        rp_id: URI.parse(Sanctum.origin()).host,
        athanor: athanor_id,
        person: user.id,
        operation: "vault.create",
        args_digest: Prima.Digest.sha256("args"),
        action: "credential_entry",
        preview: %{home: Sanctum.origin(), athanor: "Home", operation: "vault.create"},
        challenge: :crypto.strong_rand_bytes(32),
        expires_at: System.system_time(:millisecond) + 300_000
      )

    {:ok, row} =
      Arca.PendingConfirmations.open(Sanctum.Context.actor(ctx), %{
        record: record,
        opener: "session:test",
        asker: %{"kind" => "session"}
      })

    {:ok, %{request: request}} =
      Sanctum.SignIn.request(:confirm, {:session, hash}, ctx: ctx, ref: row.ref)

    {:ok, view, _html} = conn |> with_session(token) |> live(~p"/login")

    render_hook(view, "account_answer", %{"answer" => answer_of(request, account)})
    html = render_async(view, @answered_ms)
    assert_push_event(view, "account:close", %{})

    assert view |> element(~s([data-test="confirmed"])) |> render() =~
             "This tab closes by itself."

    refute has_element?(view, ~s([data-test="sign-in"]))
    refute_vocabulary(html)

    assert {:ok, %{state: "confirmed"}} =
             Arca.PendingConfirmations.get(Sanctum.Context.actor(ctx), row.ref)
  end
end
