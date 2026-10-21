# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Auth.DeviceFlowTest do
  use ExUnit.Case, async: false

  alias Sanctum.Auth.DeviceFlow

  setup do
    # Use a temp directory for tests
    test_dir = Path.join(System.tmp_dir!(), "cyfr_device_flow_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)

    # Set the base path for tests
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)

      Application.delete_env(:sanctum, :github_client_id)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "init_device_flow/2" do
    test "returns error when github client_id not configured" do
      Application.delete_env(:sanctum, :github_client_id)

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github", nil)
    end

    test "normalizes string provider to atom" do
      Application.delete_env(:sanctum, :github_client_id)

      # Both string and atom should work the same way
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github", nil)

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow(:github, nil)
    end
  end

  describe "poll_for_session/3" do
    test "returns error when client_id not configured" do
      Application.delete_env(:sanctum, :github_client_id)

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.poll_for_session("github", "fake_device_code", nil)
    end

    test "polls beyond the per-code budget answer slow_down without provider contact" do
      Application.delete_env(:sanctum, :github_client_id)
      Prima.Test.RateLimiter.reset!()
      on_exit(fn -> Prima.Test.RateLimiter.reset!() end)

      code = "budget_test_code"

      # Inside the budget every poll proceeds (and here dies on the missing
      # client id — no provider is ever contacted in this suite).
      for _ <- 1..30 do
        assert {:error, {:client_id_not_configured, :github}} =
                 DeviceFlow.poll_for_session("github", code, nil)
      end

      # The 31st answers the protocol's own back-pressure shape, before
      # any config or provider is consulted.
      assert {:ok, %{status: "pending", slow_down: true}} =
               DeviceFlow.poll_for_session("github", code, nil)

      # A different device code has its own budget.
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.poll_for_session("github", "another_code", nil)

      # The appeal-path poll shares the same budget vocabulary.
      assert {:ok, %{status: "pending", slow_down: true}} =
               DeviceFlow.poll_for_access_token("github", code, nil)
    end
  end

  # Check per-address device-flow limits and the independent global
  # sign-in budget on MCP and LiveView surfaces.
  describe "anonymous sign-in budgets are per-address, and the global sits above them" do
    setup do
      Application.delete_env(:sanctum, :github_client_id)
      Prima.Test.RateLimiter.reset!()
      on_exit(fn -> Prima.Test.RateLimiter.reset!() end)
      :ok
    end

    # A budget-denied init is refused BEFORE the client id is consulted, so
    # the two outcomes are distinguishable without contacting a provider.
    defp init_from(ip), do: DeviceFlow.init_device_flow("github", ip)

    defp admitted?({:error, {:client_id_not_configured, :github}}), do: true
    defp admitted?({:error, {:rate_limited, retry_after_s}}) when retry_after_s > 0, do: false

    test "one address exhausts only its own init budget" do
      noisy = "198.51.100.9"

      # Hammer well past any plausible per-address ceiling. Whatever the
      # number is, it must run out.
      outcomes = for _ <- 1..200, do: admitted?(init_from(noisy))
      assert false in outcomes, "one address must not be able to init without bound"
    end

    test "a second address still signs in after the first is exhausted" do
      noisy = "198.51.100.9"
      innocent = "203.0.113.4"

      for _ <- 1..200, do: init_from(noisy)

      # One client must not exhaust the sign-in budget available to other clients.
      assert admitted?(init_from(innocent)),
             "a second address must still be able to start a sign-in"
    end

    test "the poll budget is per-address too, above and beyond the per-code one" do
      noisy = "198.51.100.9"
      innocent = "203.0.113.4"

      # Each code has its own 30/min, so a swarm of fabricated codes from
      # one address is only bounded by the per-address bucket.
      for n <- 1..200 do
        DeviceFlow.poll_for_session("github", "code_#{n}", noisy)
      end

      assert {:ok, %{status: "pending", slow_down: true}} =
               DeviceFlow.poll_for_session("github", "code_fresh", noisy)

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.poll_for_session("github", "code_other", innocent)
    end

    test "a surface with no address of its own still passes the global ceiling" do
      # `nil` is the MCP route, metered per IP by its own plug. It must not
      # crash and must not be exempt from the server-wide breaker.
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github", nil)
    end
  end

  describe "wire/1 — the CLI poll contract" do
    # `cyfr login` (apps/codex/cmd/login.go) reads these exact keys; every
    # change here is a cross-language wire change and must be deliberate.
    @user %{id: "u1", email: "u@example.com", name: "U"}

    test "a signed-in result is its status, user and session token" do
      assert DeviceFlow.wire(%{
               status: "complete",
               user: @user,
               session_token: "tok",
               outcome: {:proceed, %{unsynced: [], probe: :skipped}}
             }) == %{status: "complete", user: @user, session_token: "tok"}
    end

    test "outcome-less statuses pass through untouched" do
      for passthrough <- [
            %{status: "pending"},
            %{status: "pending", slow_down: true},
            %{status: "denied"},
            %{status: "expired"},
            %{status: "error", message: "m"}
          ] do
        assert DeviceFlow.wire(passthrough) == passthrough
      end
    end
  end

  defmodule IpRecordingDeviceFlow do
    # Records the address it was handed, the way `PrismWeb.LoginLiveTest`'s
    # fake does for the console surface.
    def init_device_flow(_provider, client_ip) do
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
  end

  describe "the MCP surface charges an address too" do
    # Device initialization needs its own per-address budget on every surface.
    test "session.device_init charges the context's client_ip" do
      ctx = %{Sanctum.TestContext.local() | client_ip: "203.0.113.9", authenticated: false}

      prev_flow = Application.get_env(:sanctum, :device_flow)
      prev_provider = Application.get_env(:sanctum, :auth_provider)
      Application.put_env(:sanctum, :device_flow, IpRecordingDeviceFlow)
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)
      Application.delete_env(:sanctum, :device_flow_last_ip)

      on_exit(fn ->
        if prev_flow,
          do: Application.put_env(:sanctum, :device_flow, prev_flow),
          else: Application.delete_env(:sanctum, :device_flow)

        if prev_provider,
          do: Application.put_env(:sanctum, :auth_provider, prev_provider),
          else: Application.delete_env(:sanctum, :auth_provider)

        Application.delete_env(:sanctum, :device_flow_last_ip)
      end)

      Sanctum.Providers.Session.handle(ctx, %{"action" => "device_init", "provider" => "github"})

      assert Application.get_env(:sanctum, :device_flow_last_ip) == "203.0.113.9",
             "the MCP device flow was charged no address"
    end
  end

  describe "a device sign-in over its init budget" do
    test "is told to wait, as a typed rate limit, on the MCP surface too" do
      ip = "198.51.100.77"
      ctx = %{Sanctum.TestContext.local() | client_ip: ip, authenticated: false}
      prev_flow = Application.get_env(:sanctum, :device_flow)
      prev_provider = Application.get_env(:sanctum, :auth_provider)
      prev_client = Application.fetch_env(:sanctum, :github_client_id)

      on_exit(fn ->
        Prima.Test.RateLimiter.reset!()

        case prev_client do
          {:ok, id} -> Application.put_env(:sanctum, :github_client_id, id)
          :error -> Application.delete_env(:sanctum, :github_client_id)
        end

        if prev_flow,
          do: Application.put_env(:sanctum, :device_flow, prev_flow),
          else: Application.delete_env(:sanctum, :device_flow)

        if prev_provider,
          do: Application.put_env(:sanctum, :auth_provider, prev_provider),
          else: Application.delete_env(:sanctum, :auth_provider)
      end)

      Prima.Test.RateLimiter.reset!()
      Application.delete_env(:sanctum, :device_flow)
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)
      # No client id, so an admitted init stops at the configuration and
      # never reaches a provider.
      Application.delete_env(:sanctum, :github_client_id)

      # Spend this address's init budget, whatever its number is.
      outcomes = for _ <- 1..200, do: DeviceFlow.init_device_flow("github", ip)
      assert {:error, {:rate_limited, retry_after_s}} = List.last(outcomes)
      assert retry_after_s > 0

      # The wait is read again, so it may have ticked down a second.
      assert {:error, {:rate_limited, wait_s} = limited} =
               Sanctum.Providers.Session.handle(ctx, %{
                 "action" => "device_init",
                 "provider" => "github"
               })

      assert wait_s > 0 and wait_s <= retry_after_s
      assert %Prima.Refusal{class: :rate_limited} = Prima.Refusal.classify(limited)
    end
  end

  defmodule FullServerDeviceFlow do
    # A server at capacity: the door refuses the mint, so `admitted/2`
    # refuses the sign-in and the poll carries that reason out — the
    # athanors it holds, or how fast it admits strangers.
    def poll_for_session(_provider, "dc_slow", _client_ip, _opts),
      do: {:error, {:limit_reached, :mint_per_hour, 10}}

    def poll_for_session(_provider, _device_code, _client_ip, _opts),
      do: {:error, {:limit_reached, :max_athanors, 1}}
  end

  defmodule IdP do
    @moduledoc false
    # A plain HTTP/1.1 stand-in for GitHub's device-flow endpoints on
    # loopback: one request per connection, answered from `routes`, a map
    # of `{method, path}` to the JSON body.

    def start(routes) do
      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listen)
      pid = spawn(fn -> accept(listen, routes) end)
      %{port: port, pid: pid, listen: listen}
    end

    def stop(%{pid: pid, listen: listen}) do
      Process.exit(pid, :kill)
      :gen_tcp.close(listen)
    end

    defp accept(listen, routes) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          serve(socket, routes)
          accept(listen, routes)

        {:error, _closed} ->
          :ok
      end
    end

    defp serve(socket, routes) do
      with {:ok, head, _rest} <- read_head(socket, "") do
        [line | _headers] = String.split(head, "\r\n")
        [method, target, _version] = String.split(line, " ", parts: 3)
        body = routes |> Map.fetch!({method, URI.parse(target).path}) |> Jason.encode!()

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
            "#{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
        )
      end

      :gen_tcp.close(socket)
    end

    defp read_head(socket, acc) do
      case :binary.split(acc, "\r\n\r\n") do
        [head, rest] ->
          {:ok, head, rest}

        [_partial] ->
          with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000), do: read_head(socket, acc <> data)
      end
    end
  end

  describe "poll_for_link/4 — a device flow that links a door instead of signing in" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      Arca.Cache.init()
      Prima.Test.RateLimiter.reset!()
      endpoints = Application.get_env(:sanctum, :device_flow_endpoints)
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      on_exit(fn ->
        if endpoints,
          do: Application.put_env(:sanctum, :device_flow_endpoints, endpoints),
          else: Application.delete_env(:sanctum, :device_flow_endpoints)

        Arca.Cache.delete_match({:established, :_, :_, :_})
        Prima.Test.RateLimiter.reset!()
      end)

      Application.put_env(:sanctum, :github_client_id, "link-client")
      :ok
    end

    # GitHub's endpoints, answering a token or a pending poll.
    defp idp!(token_answer) do
      n = System.unique_integer([:positive])

      idp =
        IdP.start(%{
          {"POST", "/login/oauth/access_token"} => token_answer,
          {"GET", "/user"} => %{"id" => n, "login" => "linked#{n}", "name" => "Linked #{n}"},
          {"GET", "/user/emails"} => [
            %{"email" => "linked#{n}@example.com", "primary" => true, "verified" => true}
          ]
        })

      on_exit(fn -> IdP.stop(idp) end)
      base = "http://127.0.0.1:#{idp.port}"

      Application.put_env(:sanctum, :device_flow_endpoints, %{
        github: %{
          token: base <> "/login/oauth/access_token",
          userinfo: base <> "/user",
          emails: base <> "/user/emails"
        }
      })

      n
    end

    defp signed_in! do
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: "oidcc|https://idp.test|device-link-#{n}",
          provider: "oidcc",
          email: "device-link-#{n}@idp.test",
          verified: true
        })

      {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user.id, "Device link #{n}")

      built =
        Sanctum.Context.build(
          user_id: user.id,
          provider: "oidcc",
          athanor_id: athanor.id,
          permissions: [:*],
          auth_method: :oidc,
          authenticated: true
        )

      {:ok, session} = Sanctum.TestContext.create_session(built)

      {:ok, ctx} =
        Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

      %{user: user, ctx: ctx}
    end

    test "the identity the provider authorizes is a ticket for the person who polled, " <>
           "and no one is signed in" do
      person = signed_in!()
      n = idp!(%{"access_token" => "gho_link", "token_type" => "bearer"})
      sessions = Arca.Repo.aggregate(Arca.Schemas.Session, :count)
      people = Arca.Repo.aggregate(Arca.Schemas.User, :count)

      assert {:ok, %{status: "complete", provider: "github", ticket: ticket}} =
               DeviceFlow.poll_for_link("github", "dc-link-#{n}", nil, person.ctx)

      assert Arca.Repo.aggregate(Arca.Schemas.Session, :count) == sessions
      assert Arca.Repo.aggregate(Arca.Schemas.User, :count) == people

      key = "github|https://github.com|#{n}"

      assert {:ok, %{linked: true, door: %{key: ^key}}} =
               Sanctum.TestContext.confirming(
                 person.ctx,
                 &Sanctum.SignIn.link_door(&1, "github", ticket)
               )

      assert {:ok, %{id: user_id}} = Sanctum.Tenancy.Users.get_by_identity(key)
      assert user_id == person.user.id
    end

    test "a Google door is linked the same way, by the subject Google names" do
      person = signed_in!()
      n = System.unique_integer([:positive])

      idp =
        IdP.start(%{
          {"POST", "/token"} => %{"access_token" => "ya29_link", "token_type" => "Bearer"},
          {"GET", "/userinfo"} => %{
            "sub" => "g-#{n}",
            "email" => "g#{n}@example.com",
            "email_verified" => true,
            "name" => "G #{n}"
          }
        })

      on_exit(fn ->
        IdP.stop(idp)
        Application.delete_env(:sanctum, :google_client_id)
        Application.delete_env(:sanctum, :google_client_secret)
      end)

      base = "http://127.0.0.1:#{idp.port}"
      Application.put_env(:sanctum, :google_client_id, "link-google")
      Application.put_env(:sanctum, :google_client_secret, "link-google-secret")

      Application.put_env(:sanctum, :device_flow_endpoints, %{
        google: %{token: base <> "/token", userinfo: base <> "/userinfo"}
      })

      assert {:ok, %{status: "complete", provider: "google", ticket: ticket}} =
               DeviceFlow.poll_for_link("google", "dc-google-#{n}", nil, person.ctx)

      key = "google|https://accounts.google.com|g-#{n}"

      assert {:ok, %{linked: true, door: %{key: ^key}}} =
               Sanctum.TestContext.confirming(
                 person.ctx,
                 &Sanctum.SignIn.link_door(&1, "google", ticket)
               )
    end

    test "a pending authorization answers pending, and a closed door mints no ticket" do
      person = signed_in!()
      n = idp!(%{"error" => "authorization_pending"})

      assert {:ok, %{status: "pending"}} =
               DeviceFlow.poll_for_link("github", "dc-pending-#{n}", nil, person.ctx)

      [entry] = Sanctum.Door.Store.list()
      :ok = Sanctum.Door.Store.remove(entry.id)
      _ = idp!(%{"access_token" => "gho_link", "token_type" => "bearer"})

      assert {:error, {:door, :not_allowed}} =
               DeviceFlow.poll_for_link("github", "dc-closed-#{n}", nil, person.ctx)

      assert {:error, :unauthenticated} =
               DeviceFlow.poll_for_link(
                 "github",
                 "dc-nosession-#{n}",
                 nil,
                 %{person.ctx | session_token_hash: nil}
               )
    end
  end

  describe "poll_for_session/3 — a door a recovery retires while the sign-in runs" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      Arca.Cache.init()
      Prima.Test.RateLimiter.reset!()
      endpoints = Application.get_env(:sanctum, :device_flow_endpoints)
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      on_exit(fn ->
        if endpoints,
          do: Application.put_env(:sanctum, :device_flow_endpoints, endpoints),
          else: Application.delete_env(:sanctum, :device_flow_endpoints)

        Arca.Cache.delete_match({:established, :_, :_, :_})
        Arca.Cache.delete_match(Arca.Cache.Keys.match_identity_unreachable())
        Prima.Test.RateLimiter.reset!()
      end)

      Application.put_env(:sanctum, :github_client_id, "recovered-client")
      :ok
    end

    test "the poller is told to sign in again, and no fault is logged" do
      alias Sanctum.Test.DirectoryServer

      tls = DirectoryServer.tls()
      DirectoryServer.listen!()
      DirectoryServer.seam!(tls)
      directory = DirectoryServer.start!(tls)
      identity = DirectoryServer.identity!(directory.dir, directory.url)

      # A person whose keys are at another home, signing in here through
      # their GitHub door, the identity the provider authorizes.
      n = idp!(%{"access_token" => "gho_recovered", "token_type" => "bearer"})
      key = Sanctum.Auth.Identity.builtin_key(:github, to_string(n))

      {:ok, user} =
        Sanctum.Tenancy.Users.upsert_from_provider(%{
          id: key,
          provider: "github",
          verified: :unknown
        })

      :ok = DirectoryServer.remote_person!(user.id, identity)

      assert {:ok, %{status: "complete", session_token: token}} =
               DeviceFlow.poll_for_session(:github, "dc_before_#{n}", "203.0.113.20")

      assert is_binary(token)

      # They recover with new keys at their directory. The next sign-in's
      # fresh read finds the recovery and retires the door it came through
      # before its session is issued.
      DirectoryServer.recover!(directory.dir, identity)

      {answer, log} =
        ExUnit.CaptureLog.with_log(fn ->
          DeviceFlow.poll_for_session(:github, "dc_after_#{n}", "203.0.113.21")
        end)

      assert {:ok, %{status: "error", message: message} = refused} = answer
      assert message =~ "cyfr login"
      refute Map.has_key?(refused, :session_token)
      refute log =~ "session create failed"
      refute log =~ "[error]"
      assert {:error, :not_found} = Sanctum.Tenancy.Users.get_by_identity(key)
    end
  end

  describe "poll_for_session/4 — a command line names its machine" do
    setup tags do
      Arca.Test.Sandbox.setup!(tags)
      Arca.Cache.init()
      Prima.Test.RateLimiter.reset!()
      endpoints = Application.get_env(:sanctum, :device_flow_endpoints)
      {:ok, _} = Sanctum.Door.Store.allow("wildcard", "*", "test")

      on_exit(fn ->
        if endpoints,
          do: Application.put_env(:sanctum, :device_flow_endpoints, endpoints),
          else: Application.delete_env(:sanctum, :device_flow_endpoints)

        Arca.Cache.delete_match({:established, :_, :_, :_})
        Prima.Test.RateLimiter.reset!()
      end)

      Application.put_env(:sanctum, :github_client_id, "command-line-client")
      :ok
    end

    test "the session a command line signs in is listed by its machine, and the browser's names none" do
      n = idp!(%{"access_token" => "gho_command_line", "token_type" => "bearer"})

      assert {:ok, %{status: "complete", session_token: token}} =
               DeviceFlow.poll_for_session(:github, "dc_cli_#{n}", "203.0.113.30",
                 command_line: "laptop"
               )

      {:ok, row} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(token))
      assert row.cli_machine == "laptop"

      assert {:ok, [%{cli_machine: "laptop"}]} =
               Arca.SessionStorage.list_command_lines(row.user_id)

      assert {:ok, %{status: "complete", session_token: browser}} =
               DeviceFlow.poll_for_session(:github, "dc_browser_#{n}", "203.0.113.31")

      {:ok, browser_row} = Arca.SessionStorage.get_session(Sanctum.Session.token_hash(browser))
      assert browser_row.cli_machine == nil
      assert {:ok, [_command_line_alone]} = Arca.SessionStorage.list_command_lines(row.user_id)
    end
  end

  describe "a full server, seen from the CLI" do
    setup do
      prev_flow = Application.get_env(:sanctum, :device_flow)
      prev_provider = Application.get_env(:sanctum, :auth_provider)
      Application.put_env(:sanctum, :device_flow, FullServerDeviceFlow)
      Application.put_env(:sanctum, :auth_provider, Sanctum.Auth.OAuth)

      on_exit(fn ->
        if prev_flow,
          do: Application.put_env(:sanctum, :device_flow, prev_flow),
          else: Application.delete_env(:sanctum, :device_flow)

        if prev_provider,
          do: Application.put_env(:sanctum, :auth_provider, prev_provider),
          else: Application.delete_env(:sanctum, :auth_provider)
      end)

      :ok
    end

    test "the poller is told the server is at capacity, as a rate limit and never an internal failure" do
      ctx = %{Sanctum.TestContext.local() | authenticated: false}

      for {code, sentence} <- [
            {"dc_full", "This server holds as many athanors as it may — ask its operator"},
            {"dc_slow",
             "This server is admitting new people slowly right now — try again shortly"}
          ] do
        assert {:error, reason} =
                 Sanctum.Providers.Session.handle(ctx, %{
                   "action" => "device_poll",
                   "provider" => "github",
                   "device_code" => code
                 })

        assert %Prima.Refusal{class: :rate_limited, message: ^sentence} =
                 Sanctum.Refusals.classify(reason)
      end
    end
  end
end
