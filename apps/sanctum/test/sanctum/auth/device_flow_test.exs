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
      Application.delete_env(:sanctum, :google_client_id)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "init_device_flow/1" do
    test "returns error when github client_id not configured" do
      Application.delete_env(:sanctum, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github")
    end

    test "returns error when google client_id not configured" do
      Application.delete_env(:sanctum, :google_client_id)
      System.delete_env("CYFR_GOOGLE_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :google}} =
               DeviceFlow.init_device_flow("google")
    end

    test "normalizes string provider to atom" do
      Application.delete_env(:sanctum, :github_client_id)
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
      Application.delete_env(:sanctum, :github_client_id)
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
      Application.delete_env(:sanctum, :github_client_id)
      System.delete_env("CYFR_GITHUB_CLIENT_ID")

      # Both should fail with same error
      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow("github")

      assert {:error, {:client_id_not_configured, :github}} =
               DeviceFlow.init_device_flow(:github)
    end

    test "handles both string and atom providers for google" do
      Application.delete_env(:sanctum, :google_client_id)
      System.delete_env("CYFR_GOOGLE_CLIENT_ID")

      assert {:error, {:client_id_not_configured, :google}} =
               DeviceFlow.init_device_flow("google")

      assert {:error, {:client_id_not_configured, :google}} =
               DeviceFlow.init_device_flow(:google)
    end
  end
end
