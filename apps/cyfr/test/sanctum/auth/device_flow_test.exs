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

  describe "probe_after_session/3 — probe → CredentialStore integration" do
    # The IdP-side (GitHub / Google token exchange + userinfo) lives at
    # compile-time-fixed hostnames in @provider_urls and isn't stubbable
    # without a refactor. probe_after_session/3 is the post-Session.create
    # segment that IS stubbable — it calls Registry.Client.probe_identity
    # (HTTP, configurable via :registry_url + :registry_scheme) and then
    # CredentialStore.put. This block exercises that segment end-to-end.
    alias Compendium.Registry.CredentialStore

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)
      original_oci = Application.get_env(:cyfr, :oci_registry_url)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")
      # Pin the CredentialStore key-space so assertions target a known host.
      Application.put_env(:cyfr, :oci_registry_url, "registry.test")

      on_exit(fn ->
        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_scheme,
          do: Application.put_env(:cyfr, :registry_scheme, original_scheme),
          else: Application.delete_env(:cyfr, :registry_scheme)

        if original_oci,
          do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
          else: Application.delete_env(:cyfr, :oci_registry_url)
      end)

      {:ok, bypass: bypass}
    end

    # SQL-sandbox rollback between tests races with Bypass/Finch worker
    # processes, so each test uses a unique user_id to avoid cross-test
    # CredentialStore collisions.
    defp fresh_session(label) do
      uid = "#{label}_#{System.unique_integer([:positive])}"

      %{
        user_id: "github|https://github.com|#{uid}",
        token: "sess_#{uid}",
        email: "alice@example.com"
      }
    end

    defp json_resp(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    test "happy path: personal + membership tokens are stored; no warnings",
         %{bypass: bypass} do
      session = fresh_session("df_happy")

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        json_resp(conn, 200, %{
          "personal_namespace" => %{"slug" => "alice", "token" => "cyfr_pt_personal"},
          "memberships" => [
            %{"slug" => "stripe.com", "token" => "cyfr_pt_stripe", "role" => "admin"}
          ]
        })
      end)

      assert {%{needs_personal_namespace: false} = extra, nil} =
               DeviceFlow.probe_after_session("github", "gho_access", session)

      refute Map.has_key?(extra, :credential_store_warnings)

      assert {:ok, %{token: "cyfr_pt_personal", role: "personal"}} =
               CredentialStore.get(session.user_id, "registry.test", "alice")

      assert {:ok, %{token: "cyfr_pt_stripe", role: "admin"}} =
               CredentialStore.get(session.user_id, "registry.test", "stripe.com")
    end

    test "no personal: returns needs_personal_namespace + suggested_username",
         %{bypass: bypass} do
      session = fresh_session("df_unclaimed")

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        json_resp(conn, 200, %{
          "personal_namespace" => nil,
          "memberships" => []
        })
      end)

      assert {%{needs_personal_namespace: true, suggested_username: suggested}, nil} =
               DeviceFlow.probe_after_session("github", "gho_access", session)

      assert is_binary(suggested)

      assert :not_found = CredentialStore.get(session.user_id, "registry.test", "alice")
    end

    test "probe 401: returns reauthenticate flag + :invalid_access_token error",
         %{bypass: bypass} do
      session = fresh_session("df_401")

      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        json_resp(conn, 401, %{"error" => "invalid_access_token"})
      end)

      assert {%{needs_personal_namespace: true, reauthenticate: true}, :invalid_access_token} =
               DeviceFlow.probe_after_session("github", "expired_token", session)

      assert :not_found = CredentialStore.get(session.user_id, "registry.test", "alice")
    end

    test "probe 500: session survives; error is surfaced non-blockingly",
         %{bypass: bypass} do
      session = fresh_session("df_5xx")

      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn conn ->
        json_resp(conn, 500, %{"error" => "internal"})
      end)

      assert {%{needs_personal_namespace: true} = extra, err} =
               DeviceFlow.probe_after_session("github", "gho_access", session)

      refute Map.get(extra, :reauthenticate)
      assert err != nil

      assert :not_found = CredentialStore.get(session.user_id, "registry.test", "alice")
    end
  end
end
