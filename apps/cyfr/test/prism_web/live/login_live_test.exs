# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.LoginLiveTest do
  @moduledoc """
  Prism sign-in for GitHub and Google is device flow on this page; they
  have no browser callback. A deployment on its own issuer links to
  `/auth/oidcc`. A person whose keys another home holds signs in with
  their CYFR: the page sends them to their own home, checks the carry they
  bring back, carries this home's challenge through the browser's session
  and posts their home's assertion to the callback.
  """
  use PrismWeb.ConnCase, async: false

  defmodule FakeDeviceFlow do
    # Records the address it was handed. The `/live` socket passes no
    # rate-limit plug, so the LiveView supplying a real client IP is the
    # only per-address bound this surface has — a `nil` here would compile,
    # run, and silently leave sign-in exhaustible by one caller again.
    def init_device_flow(provider, client_ip) when provider in [:github, :google] do
      Application.put_env(:sanctum, :device_flow_last_ip, client_ip)

      {:ok,
       %{
         device_code: "dev-code",
         user_code: "WXYZ-1234",
         verification_uri: "https://github.com/login/device",
         expires_in: 900,
         interval: 60
       }}
    end

    def poll_for_session(_provider, _code, client_ip) do
      Application.put_env(:sanctum, :device_flow_last_ip, client_ip)
      Application.get_env(:sanctum, :device_flow_poll_result, {:ok, %{status: "pending"}})
    end
  end

  setup do
    originals = %{
      github_id: Application.get_env(:sanctum, :github_client_id),
      google_id: Application.get_env(:sanctum, :google_client_id),
      google_secret: Application.get_env(:sanctum, :google_client_secret),
      auth_provider: Application.get_env(:sanctum, :auth_provider),
      device_flow: Application.get_env(:sanctum, :device_flow),
      poll_result: Application.get_env(:sanctum, :device_flow_poll_result)
    }

    on_exit(fn ->
      restore(:github_client_id, originals.github_id)
      restore(:google_client_id, originals.google_id)
      restore(:google_client_secret, originals.google_secret)
      restore(:auth_provider, originals.auth_provider)
      restore(:device_flow, originals.device_flow)
      restore(:device_flow_poll_result, originals.poll_result)
    end)

    :ok
  end

  defp restore(key, value), do: restore(:sanctum, key, value)

  # Every key this case swaps is the identity domain's, the fake flow's own
  # two among them. Restoring the wrong application leaves a fake provider
  # installed for every test that runs after this one.
  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  describe "provider buttons" do
    test "GitHub and Google start device flow on this page, not /auth/:provider",
         %{conn: conn} do
      Application.put_env(:sanctum, :github_client_id, "github-device-id")
      Application.put_env(:sanctum, :google_client_id, "google-device-id")
      Application.put_env(:sanctum, :google_client_secret, "google-device-secret")
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)

      {:ok, view, html} = live(conn, ~p"/login")

      refute html =~ ~r{href="[^"]*/auth/github"}
      refute html =~ ~r{href="[^"]*/auth/google"}
      assert has_element?(view, "button[phx-click=start][phx-value-provider=github]")
      assert has_element?(view, "button[phx-click=start][phx-value-provider=google]")
      assert html =~ "Sign in with GitHub"
      assert html =~ "Sign in with Google"
    end

    test "an OIDC deployment still kicks off through /auth/oidcc", %{conn: conn} do
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OIDC)

      {:ok, _view, html} = live(conn, ~p"/login")

      assert html =~ ~r{href="[^"]*/auth/oidcc"}
      refute html =~ "Sign in with GitHub"
    end
  end

  describe "device flow" do
    setup do
      Application.put_env(:sanctum, :github_client_id, "github-device-id")
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)
      Application.put_env(:sanctum, :device_flow, FakeDeviceFlow)
      :ok
    end

    test "start shows the user code and verification URL", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      html = render(view)
      assert html =~ "WXYZ-1234"
      assert html =~ "https://github.com/login/device"
      assert html =~ "Waiting for authorization"
    end

    test "the flow is budgeted against a resolved client address", %{conn: conn} do
      Application.delete_env(:sanctum, :device_flow_last_ip)
      on_exit(fn -> Application.delete_env(:sanctum, :device_flow_last_ip) end)

      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      # `/live` is handled by the endpoint before the router, so no plug
      # meters this socket: if the LiveView hands the flow a `nil` address,
      # one caller can exhaust the server-wide sign-in budget again.
      #
      # This covers the LiveView half only. `Phoenix.LiveViewTest` builds
      # `connect_info` from the test conn rather than from the endpoint's
      # socket declaration, so removing `:peer_data` from the endpoint
      # would NOT fail here — that half is pinned in
      # `CyfrWeb.EndpointSocketTest`.
      ip = Application.get_env(:sanctum, :device_flow_last_ip)

      assert is_binary(ip), "the LiveView must budget the device flow by client address"

      assert {:ok, _} = :inet.parse_address(String.to_charlist(ip)),
             "expected a real address, got #{inspect(ip)}"

      refute ip == "0.0.0.0",
             "a connected socket must resolve a peer, not the fail-closed placeholder"
    end

    test "a completed poll redirects through the device-complete handshake", %{conn: conn} do
      ctx =
        Sanctum.Context.build(
          user_id: "github|https://github.com|login_live_#{System.unique_integer([:positive])}",
          email: "login@example.com",
          provider: "github",
          permissions: [:*],
          namespace: "testns",
          authenticated: true
        )

      {:ok, session} = Sanctum.Session.create(Sanctum.TestContext.issuer!(ctx))

      Application.put_env(
        :sanctum,
        :device_flow_poll_result,
        {:ok,
         %{
           status: "complete",
           session_token: session.token,
           outcome: {:proceed, %{unsynced: [], probe: :ok}}
         }}
      )

      # One browser start to finish. The ticket is bound to the session that
      # began the flow, so the visit that follows the redirect has to be the
      # same browser — here, the same conn carrying the same cookie.
      browser = get(conn, ~p"/login")

      {:ok, view, _} = live(browser, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      send(view.pid, :login_poll)
      {path, _flash} = assert_redirect(view)

      assert String.starts_with?(path, "/auth/device/complete/")

      landed = get(browser, path)
      assert redirected_to(landed) == "/"
      assert get_session(landed, :sanctum_session_token) == session.token
    end

    test "a boot that lost the control plane stops a waiting sign-in at its next poll, asking no provider",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      view
      |> element("button[phx-click=start][phx-value-provider=github]")
      |> render_click()

      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      Application.delete_env(:sanctum, :device_flow_last_ip)
      on_exit(fn -> Application.delete_env(:sanctum, :device_flow_last_ip) end)

      send(view.pid, :login_poll)
      html = render(view)

      assert html =~ "not accepting sign-ins"
      refute html =~ "Waiting for authorization"
      assert Application.get_env(:sanctum, :device_flow_last_ip) == nil

      # Stopped: a later tick asks nothing either, owner again or not.
      Arca.ControlPlane.record(:unclaimed)
      send(view.pid, :login_poll)
      _ = render(view)
      assert Application.get_env(:sanctum, :device_flow_last_ip) == nil
    end

    test "a page open on a boot that lost the control plane starts no sign-in", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      Arca.ControlPlane.record(:lost)
      on_exit(fn -> Arca.ControlPlane.record(:unclaimed) end)
      Application.delete_env(:sanctum, :device_flow_last_ip)
      on_exit(fn -> Application.delete_env(:sanctum, :device_flow_last_ip) end)

      html =
        view
        |> element("button[phx-click=start][phx-value-provider=github]")
        |> render_click()

      assert html =~ "not accepting sign-ins"
      refute html =~ "WXYZ-1234"
      assert Application.get_env(:sanctum, :device_flow_last_ip) == nil
    end

    test "a missing device-complete ticket returns to login", %{conn: conn} do
      conn = get(conn, "/auth/device/complete/not-a-real-ticket")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "sign in with your CYFR" do
    alias Sanctum.Test.DirectoryServer

    setup do
      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      Prima.RateLimiter.reset()

      on_exit(fn ->
        Prima.RateLimiter.reset()
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
      end)

      directory = DirectoryServer.start!(tls)
      %{identity: DirectoryServer.identity!(directory.dir, directory.url)}
    end

    test "the entry has the script keep the expectation, then sends the person to their own home's /carry, naming this home in the fragment",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/login")
      assert html =~ "Sign in with your CYFR"
      assert html =~ ~s(data-carry="login")
      assert html =~ ~s(data-lifetime-ms="#{Arca.CarryActions.lifetime_ms()}")

      view |> element("#cyfr-sign-in") |> render_submit(%{"home" => "a.example"})

      assert_push_event(view, "cyfr:expect", %{home: "https://a.example", to: to})

      assert to ==
               "https://a.example/carry#" <>
                 URI.encode_query(%{"destination" => Sanctum.Person.home()})
    end

    test "naming the home whose challenge this browser holds resumes that exchange: the same challenge goes back, and no expectation is kept",
         %{conn: conn, identity: identity} do
      %{fragment: carry} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      {:ok, held} = Sanctum.Auth.CyfrDoor.challenge(carry)

      browser =
        conn |> Plug.Test.init_test_session(%{"cyfr_challenge" => held}) |> get(~p"/login")

      {:ok, view, _} = live(browser, ~p"/login")
      view |> element("#cyfr-sign-in") |> render_submit(%{"home" => "https://a.example"})

      # What comes back on a resumed exchange is its assertion, never a
      # carry: the script is told to go, and keeps no expectation that a
      # carry could use.
      assert_push_event(view, "cyfr:go", %{to: path})
      refute_push_event(view, "cyfr:expect", %{})
      assert String.starts_with?(path, "/auth/cyfr?ticket=")

      hop = get(browser, path)
      assert hop.status == 303
      assert get_resp_header(hop, "location") == [Sanctum.Auth.CyfrDoor.redirect_url(held)]
      assert get_session(hop, "cyfr_challenge") == held

      # Another home's name begins a new exchange there instead.
      {:ok, view, _} = live(browser, ~p"/login")
      view |> element("#cyfr-sign-in") |> render_submit(%{"home" => "b.example"})

      assert_push_event(view, "cyfr:expect", %{
        home: "https://b.example",
        to: "https://b.example/carry#" <> _
      })
    end

    test "a held challenge past its expiry resumes nothing: naming its home begins a new exchange there",
         %{conn: conn, identity: identity} do
      %{fragment: carry} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      {:ok, held} = Sanctum.Auth.CyfrDoor.challenge(carry)
      expired = Map.put(held, "expires_at", System.os_time(:millisecond) - 1)

      browser =
        conn |> Plug.Test.init_test_session(%{"cyfr_challenge" => expired}) |> get(~p"/login")

      {:ok, view, _} = live(browser, ~p"/login")
      view |> element("#cyfr-sign-in") |> render_submit(%{"home" => "https://a.example"})

      assert_push_event(view, "cyfr:expect", %{home: "https://a.example", to: to})
      assert String.starts_with?(to, "https://a.example/carry#")
      refute_push_event(view, "cyfr:go", %{})
    end

    test "the browser secret a held challenge binds is never in what the page's assigns print",
         %{conn: conn, identity: identity} do
      %{fragment: carry} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      {:ok, held} = Sanctum.Auth.CyfrDoor.challenge(carry)

      browser =
        conn |> Plug.Test.init_test_session(%{"cyfr_challenge" => held}) |> get(~p"/login")

      {:ok, view, _} = live(browser, ~p"/login")

      # A second exchange's challenge, waiting for the person's Continue.
      %{fragment: another} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())

      render_hook(view, "cyfr_carry", %{
        "fragment" => another,
        "expected_source" => "https://a.example"
      })

      assigns = :sys.get_state(view.pid).socket.assigns
      assert %PrismWeb.LoginLive.Held{held: %{"browser_secret" => secret}} = assigns.cyfr_held

      assert %PrismWeb.LoginLive.Held{held: %{"browser_secret" => pending}} =
               assigns.cyfr_pending.held

      # A crash report prints the page's state, its assigns included.
      printed = inspect(:sys.get_state(view.pid), limit: :infinity, printable_limit: :infinity)
      refute printed =~ secret
      refute printed =~ pending
      assert printed =~ held["challenge_id"]
    end

    test "an address that is no home's, or this home's, is told so", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/login")

      html = view |> element("#cyfr-sign-in") |> render_submit(%{"home" => "not a home"})
      assert html =~ "not a home&#39;s address"

      html =
        view |> element("#cyfr-sign-in") |> render_submit(%{"home" => Sanctum.Person.home()})

      assert html =~ "this home&#39;s address"
    end

    test "a carry brought back is checked, its challenge carried through this browser's session, and the assertion posted signs the person in",
         %{conn: conn, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      %{fragment: carry} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())

      # One browser start to finish: the ticket is bound to it.
      browser = get(conn, ~p"/login")
      {:ok, view, _} = live(browser, ~p"/login")

      html =
        render_hook(view, "cyfr_carry", %{
          "fragment" => carry,
          "expected_source" => "https://a.example"
        })

      # The code of the challenge this home issued, which the person's
      # home names too; nothing moves until the person continues.
      [_, code] = Regex.run(~r/data-test="code"[^>]*>\s*([0-9A-Z]{4}-[0-9A-Z]{4})/, html)
      assert html =~ "https://a.example"

      assert {:error, {:redirect, %{to: path}}} =
               view |> element("[data-test=cyfr-continue]") |> render_click()

      assert String.starts_with?(path, "/auth/cyfr?ticket=")

      hop = get(browser, path)
      assert hop.status == 303
      held = get_session(hop, "cyfr_challenge")
      assert [location] = get_resp_header(hop, "location")
      assert String.starts_with?(location, "https://a.example/carry#")

      {:ok, challenge} = Prima.Identity.Encoding.unb64(held["challenge"], 32)
      assert code == Prima.PersonAssertion.comparison_code(challenge)

      # The person's home answers with the assertion, back to this page.
      assertion = DirectoryServer.assertion_fragment(identity, held, Sanctum.Person.home())
      back = recycle(hop)
      {:ok, view, _} = live(back, ~p"/login")
      render_hook(view, "cyfr_assertion", %{"fragment" => assertion})

      # Signed in, the browser goes back to the person's home to say so,
      # at the return URL the carry's envelope signed.
      signed_in = follow_trigger_action(element(view, "#cyfr-callback"), back)
      {:ok, admitted} = Prima.Carry.Return.new(held["action_id"], :admitted)

      assert redirected_to(signed_in, 303) ==
               "https://a.example/carry#" <> Prima.Carry.Return.fragment(admitted)

      assert get_session(signed_in, :sanctum_session_token) ==
               Sanctum.Auth.CyfrDoor.session_token(held)
    end

    test "a carry from another home than the one the person named is refused before any directory is read, and nobody is signed in",
         %{conn: conn, identity: identity} do
      {:ok, _} = Sanctum.Door.Store.allow("identifier", identity.identifier, "test")
      %{fragment: carry} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      browser = get(conn, ~p"/login")
      {:ok, view, _} = live(browser, ~p"/login")
      _ = DirectoryServer.requests()

      html =
        render_hook(view, "cyfr_carry", %{
          "fragment" => carry,
          "expected_source" => "https://other.example"
        })

      assert html =~ "another home than the one you named"
      refute has_element?(view, "#cyfr-code")
      assert DirectoryServer.requests() == []

      # Without the named home at all, the carry is one this page did not
      # ask for.
      html = render_hook(view, "cyfr_carry", %{"fragment" => carry})
      assert html =~ "did not ask for"
      refute has_element?(view, "#cyfr-code")

      html = render_hook(view, "cyfr_unsolicited", %{})
      assert html =~ "did not ask for"

      # No session was made: the browser is still signed out.
      assert redirected_to(get(recycle(browser), ~p"/chat")) =~ "/login"
    end

    test "cancelling at the code leaves nothing pending; a code past its challenge's expiry goes nowhere",
         %{conn: conn, identity: identity} do
      %{fragment: carry} = DirectoryServer.carry_fragment(identity, Sanctum.Person.home())
      {:ok, view, _} = live(conn, ~p"/login")

      render_hook(view, "cyfr_carry", %{
        "fragment" => carry,
        "expected_source" => "https://a.example"
      })

      assert has_element?(view, "#cyfr-code")

      view |> element("#cyfr-code button", "Cancel") |> render_click()
      refute has_element?(view, "#cyfr-code")
      assert render_click(view, "cyfr_continue", %{}) =~ "Sign in with your CYFR"

      render_hook(view, "cyfr_carry", %{
        "fragment" => carry,
        "expected_source" => "https://a.example"
      })

      :sys.replace_state(view.pid, fn state ->
        update_in(state.socket.assigns.cyfr_pending.held.held, &Map.put(&1, "expires_at", 0))
      end)

      html = view |> element("[data-test=cyfr-continue]") |> render_click()
      assert html =~ "That sign-in expired"
    end

    test "a carry that does not verify leaves the person here, told to begin again; nothing is posted",
         %{conn: conn, identity: identity} do
      {:ok, view, _} = live(conn, ~p"/login")

      html =
        render_hook(view, "cyfr_carry", %{
          "fragment" => "not a carry",
          "expected_source" => "https://a.example"
        })

      assert html =~ "Begin it again from your home"

      %{fragment: elsewhere} =
        DirectoryServer.carry_fragment(identity, "https://elsewhere.example")

      html =
        render_hook(view, "cyfr_carry", %{
          "fragment" => elsewhere,
          "expected_source" => "https://a.example"
        })

      assert html =~ "begun for another home"

      html = render_hook(view, "cyfr_oversized", %{})
      assert html =~ "larger than this home accepts"

      html =
        render_hook(view, "cyfr_assertion", %{
          "fragment" => String.duplicate("A", Prima.Carry.max_fragment_bytes() + 1)
        })

      assert html =~ "larger than this home accepts"
      refute has_element?(view, "#cyfr-callback")
    end
  end
end
