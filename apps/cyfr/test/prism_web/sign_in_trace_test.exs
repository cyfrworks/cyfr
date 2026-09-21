# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SignInTraceTest do
  @moduledoc """
  Sign-in on the product path, end to end, once per way in. A browser opens
  the sign-in page; the identity provider answers; the door admits; the
  person's estate is minted at once and the real shipped bundle fills it in
  the background with no registry reachable; the session is a cookie; and
  the console mounts on the estate that fill left, its context established
  from that cookie.

    * Device flow: `/login` starts GitHub's device flow against a stand-in
      IdP, the page's own poll mints a ticket bound to this browser, and
      `/auth/device/complete/:ticket` sets the cookie.
    * OIDC: `/auth/oidcc` goes to a stand-in issuer
      (`Cyfr.Test.OidcStrategy`), which returns through
      `/auth/oidcc/callback` with Ueberauth's state check in between.

  Fills run in the background here (`provisioning_inline: false`), and no
  estate is stubbed: the page can mount only because the fill happened.
  """
  use PrismWeb.ConnCase, async: false

  import Cyfr.Test.Wait

  @moduletag timeout: 240_000

  alias Cyfr.Test.SeedBundle
  alias Sanctum.Tenancy.{Athanors, Users}

  @repo_root Path.expand("../../../..", __DIR__)

  setup do
    test_dir = Path.join(System.tmp_dir!(), "cyfr_trace_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    File.mkdir_p!(seed_dir)
    File.cp_r!(Path.join(@repo_root, "seed/components"), Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    env = [
      base_path: test_dir,
      seed_path: seed_dir,
      # Both endpoints, because they are separate settings and a pull dials
      # the OCI one.
      registry_url: "none",
      oci_registry_url: "none",
      provisioning_inline: false
    ]

    # The provider selection and the issuer are the identity domain's keys
    # (`:sanctum`), the rest the host's: restoring the wrong application
    # leaves a provider set for every test that runs after this one.
    restore =
      restore_env(:cyfr, Keyword.keys(env) ++ [:github_client_id, :device_flow_endpoints])

    restore_sanctum = restore_env(:sanctum, [:auth_provider, :oidc_issuer])

    prev_ueberauth = Application.get_env(:ueberauth, Ueberauth)
    for {key, value} <- env, do: Application.put_env(:cyfr, key, value)

    on_exit(fn ->
      restore.()
      restore_sanctum.()
      Application.put_env(:ueberauth, Ueberauth, prev_ueberauth)
      File.rm_rf!(test_dir)
    end)

    # The sign-in budgets are node-wide counters another test may have spent.
    Cyfr.RateLimiter.reset()

    # A fill still running when the paths are restored would provision
    # against the repository's own seed and data trees.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "ops")
    :ok
  end

  test "device flow: the sign-in page, the IdP, the ticket, the cookie, the filled estate",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    polls = stand_in_idp(n)

    # The browser's first visit gives it the session the ticket is bound to.
    page = get(conn, "/login")
    {:ok, login, _html} = live(page)
    login |> element("button[phx-value-provider=github]") |> render_click()

    # The page polls on its own: pending once, then the IdP authorizes.
    {ticket_path, _flash} = assert_redirect(login, 15_000)
    assert ticket_path =~ "/auth/device/complete/"
    assert Agent.get(polls, & &1) == 2

    signed_in = page |> recycle() |> get(ticket_path)
    assert redirected_to(signed_in) == "/"
    assert get_session(signed_in, :sanctum_session_token)

    assert_console_on_filled_estate(signed_in, "github|https://github.com|#{n}")
  end

  test "OIDC: the issuer round trip through /auth/oidcc/callback, the cookie, the filled estate",
       %{conn: conn} do
    n = System.unique_integer([:positive])
    Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OIDC)
    Application.put_env(:sanctum, :oidc_issuer, "https://idp.test")
    Application.put_env(:ueberauth, Ueberauth, providers: [oidcc: {Cyfr.Test.OidcStrategy, []}])

    to_issuer =
      get(conn, "/auth/oidcc", %{"sub" => "trace-#{n}", "email" => "trace#{n}@example.com"})

    callback = redirected_to(to_issuer)
    assert callback =~ "/auth/oidcc/callback"

    signed_in = to_issuer |> recycle() |> get(callback)
    assert redirected_to(signed_in) == "/"
    assert get_session(signed_in, :sanctum_session_token)

    assert_console_on_filled_estate(signed_in, "oidcc|https://idp.test|trace-#{n}")
  end

  # The person the sign-in minted, the fill their estate received with
  # nothing here performing it, and the console mounted from the cookie.
  defp assert_console_on_filled_estate(signed_in, identity) do
    {:ok, user} = Users.get_by_identity(identity)
    athanor_id = user.personal_athanor_id
    assert {:ok, %{kind: "person"}} = Athanors.get(athanor_id)

    wait_until(
      fn ->
        case Athanors.get(athanor_id) do
          {:ok, %{provisioned_at: %DateTime{}}} ->
            true

          {:ok, row} ->
            case Athanors.provisioning_failure(row) do
              nil -> false
              failure -> flunk("the fill recorded a failure: #{inspect(failure)}")
            end

          other ->
            flunk("the athanor vanished: #{inspect(other)}")
        end
      end,
      45_000
    )

    # What the fill laid down: the shipped bundle, from the seed alone.
    reader = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)

    for unit <- SeedBundle.model_chat_units() do
      assert {:ok, %{publisher: "local"}} =
               Compendium.Registry.get_latest(reader, unit.name, "local", "catalyst"),
             "#{unit.ref} is not registered after the fill"
    end

    assert {:ok, [_profile]} =
             Arca.ConsentStorage.profiles(Sanctum.Context.actor(reader), "agent:local.aqua")

    # `/` lands the person in their own estate — the redirect naming it is
    # itself the claim — and the page there is not the preparing state.
    Process.put(:prism_test_athanor_id, athanor_id)
    console = recycle(signed_in)

    assert {:error, {:live_redirect, %{to: landing}}} = live(console, "/")
    assert landing =~ "/chat"
    assert {:ok, _view, html} = live(console, landing)
    refute html =~ "Preparing"
  end

  # GitHub's device flow as its endpoints answer: a code, one pending poll, a
  # token, the profile and the verified primary email. Answers the counter
  # of token polls.
  defp stand_in_idp(n) do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    {:ok, polls} = Agent.start_link(fn -> 0 end)

    Application.put_env(:cyfr, :github_client_id, "trace-client")

    Application.put_env(:cyfr, :device_flow_endpoints, %{
      github: %{
        device: base <> "/login/device/code",
        token: base <> "/login/oauth/access_token",
        userinfo: base <> "/user",
        emails: base <> "/user/emails"
      }
    })

    Bypass.expect_once(bypass, "POST", "/login/device/code", fn conn ->
      json(conn, %{
        "device_code" => "dc-#{n}",
        "user_code" => "TRACE-#{n}",
        "verification_uri" => "https://github.com/login/device",
        "expires_in" => 900,
        "interval" => 0
      })
    end)

    Bypass.expect(bypass, "POST", "/login/oauth/access_token", fn conn ->
      case Agent.get_and_update(polls, &{&1, &1 + 1}) do
        0 -> json(conn, %{"error" => "authorization_pending"})
        _ -> json(conn, %{"access_token" => "gho_trace_#{n}", "token_type" => "bearer"})
      end
    end)

    Bypass.expect(bypass, "GET", "/user", fn conn ->
      json(conn, %{"id" => n, "login" => "trace#{n}", "name" => "Trace #{n}"})
    end)

    Bypass.expect(bypass, "GET", "/user/emails", fn conn ->
      json(conn, [%{"email" => "trace#{n}@example.com", "primary" => true, "verified" => true}])
    end)

    polls
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp restore_env(app, keys) do
    prev = Map.new(keys, &{&1, Application.get_env(app, &1)})

    fn ->
      for {key, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end
  end
end
