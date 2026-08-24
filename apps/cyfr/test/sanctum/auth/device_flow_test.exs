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

  describe "init_device_flow/1" do
    test "returns error when github client_id not configured" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github")
    end

    test "normalizes string provider to atom" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      # Both string and atom should work the same way
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow(:github)
    end
  end

  describe "poll_for_session/2" do
    test "returns error when client_id not configured" do
      Application.delete_env(:cyfr, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.poll_for_session("github", "fake_device_code")
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
               DeviceFlow.init_device_flow("github")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow(:github)
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

    test "needs_legal" do
      assert DeviceFlow.wire(%{
               status: "complete",
               user: @user,
               session_token: "tok",
               access_token: "at",
               outcome: {:needs_legal, "v2"}
             }) == %{
               status: "complete",
               user: @user,
               session_token: "tok",
               needs_policy_acceptance: true,
               required_policy_version: "v2",
               needs_personal_namespace: false,
               access_token: "at"
             }
    end

    test "needs_claim" do
      assert DeviceFlow.wire(%{
               status: "complete",
               user: @user,
               session_token: "tok",
               access_token: "at",
               outcome: {:needs_claim, "alice"}
             }) == %{
               status: "complete",
               user: @user,
               session_token: "tok",
               needs_personal_namespace: true,
               suggested_username: "alice",
               access_token: "at"
             }
    end

    test "reauthenticate carries no session token" do
      assert DeviceFlow.wire(%{
               status: "complete",
               user: @user,
               outcome: {:reauthenticate, :idp_expired}
             }) == %{
               status: "complete",
               user: @user,
               reauthenticate: true,
               probe_error: "invalid_access_token",
               needs_personal_namespace: true
             }
    end

    test "unavailable becomes the registry_unavailable status" do
      wired =
        DeviceFlow.wire(%{
          status: "complete",
          user: @user,
          outcome: {:unavailable, :registry_unreachable}
        })

      assert wired.status == "registry_unavailable"
      assert is_binary(wired.message)
      refute Map.has_key?(wired, :user)
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
end
