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
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      Application.delete_env(:cyfr, :github_client_id)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "init_device_flow/2" do
    test "returns error when github client_id not configured" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github", nil)
    end

    test "normalizes string provider to atom" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      # Both string and atom should work the same way
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github", nil)

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow(:github, nil)
    end
  end

  describe "poll_for_session/3" do
    test "returns error when client_id not configured" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.poll_for_session("github", "fake_device_code", nil)
    end

    test "polls beyond the per-code budget answer slow_down without provider contact" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")
      Cyfr.RateLimiter.reset()
      on_exit(fn -> Cyfr.RateLimiter.reset() end)

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
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")
      Cyfr.RateLimiter.reset()
      on_exit(fn -> Cyfr.RateLimiter.reset() end)
      :ok
    end

    # A budget-denied init is refused BEFORE the client id is consulted, so
    # the two outcomes are distinguishable without contacting a provider.
    defp init_from(ip), do: DeviceFlow.init_device_flow("github", ip)

    defp admitted?({:error, {:client_id_not_configured, :github}}), do: true
    defp admitted?({:error, "Too many sign-in attempts" <> _}), do: false

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

  # Note: Full integration tests for device flow require mocking HTTP calls
  # or actual OAuth provider setup. The tests above verify the configuration
  # checking and error handling paths.

  describe "provider normalization" do
    test "handles both string and atom providers for github" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      # Both should fail with same error
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github", nil)

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow(:github, nil)
    end
  end

  # The post-door decision — what cyfr.run says about the person and what
  # follows — is one function for the CLI and the browser:
  # `Sanctum.SignIn.complete/3`, exercised in sign_in_complete_test.exs.

  describe "wire/1 — the CLI poll contract" do
    # `cyfr login` (apps/codex/cmd/login.go) reads these exact keys; every
    # change here is a cross-language wire change and must be deliberate.
    @user %{id: "u1", email: "u@example.com", name: "U"}

    test "proceed" do
      assert DeviceFlow.wire(%{
               status: "complete",
               user: @user,
               session_token: "tok",
               outcome: {:proceed, %{unsynced: [], probe: :ok}}
             }) == %{
               status: "complete",
               user: @user,
               session_token: "tok",
               needs_personal_namespace: false
             }
    end

    test "proceed carries the report's warnings and probe error" do
      wired =
        DeviceFlow.wire(%{
          status: "complete",
          user: @user,
          session_token: "tok",
          outcome: {:proceed, %{unsynced: ["ns1"], probe: :failed}}
        })

      assert wired.credential_store_warnings == ["ns1"]
      assert wired.probe_error == "probe_failed"
    end

    test "a policy owed or a namespace conflict is a probe error on a signed-in result" do
      owed =
        DeviceFlow.wire(%{
          status: "complete",
          user: @user,
          session_token: "tok",
          outcome: {:proceed, %{unsynced: [], probe: :legal_required}}
        })

      assert owed.session_token == "tok"
      assert owed.needs_personal_namespace == false
      assert owed.probe_error == "policy_acceptance_required"

      conflict =
        DeviceFlow.wire(%{
          status: "complete",
          user: @user,
          session_token: "tok",
          outcome: {:proceed, %{unsynced: [], probe: :namespace_conflict}}
        })

      assert conflict.probe_error == "namespace_conflict"
      refute Map.has_key?(conflict, :access_token)
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
      Application.put_env(:cyfr, :device_flow_last_ip, client_ip)

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

      prev_flow = Application.get_env(:cyfr, :device_flow)
      prev_provider = Application.get_env(:cyfr, :auth_provider)
      Application.put_env(:cyfr, :device_flow, IpRecordingDeviceFlow)
      Application.put_env(:cyfr, :auth_provider, Sanctum.Auth.OAuth)
      Application.delete_env(:cyfr, :device_flow_last_ip)

      on_exit(fn ->
        if prev_flow,
          do: Application.put_env(:cyfr, :device_flow, prev_flow),
          else: Application.delete_env(:cyfr, :device_flow)

        if prev_provider,
          do: Application.put_env(:cyfr, :auth_provider, prev_provider),
          else: Application.delete_env(:cyfr, :auth_provider)

        Application.delete_env(:cyfr, :device_flow_last_ip)
      end)

      Sanctum.MCP.SessionTool.handle(ctx, %{"action" => "device_init", "provider" => "github"})

      assert Application.get_env(:cyfr, :device_flow_last_ip) == "203.0.113.9",
             "the MCP device flow was charged no address"
    end
  end
end
