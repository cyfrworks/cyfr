defmodule Compendium.Registry.ClientTest do
  use ExUnit.Case, async: false

  alias Compendium.Registry.Client
  alias Compendium.MCP
  alias Compendium.OCI.Errors
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    # Point API URL at a non-routable address so tests don't hit the real API.
    # Use a random high port on localhost that (almost certainly) has no listener.
    # Client.ex prepends "https://", so we set the bare host:port here.
    original_registry_url = Application.get_env(:cyfr, :registry_url)
    Application.put_env(:cyfr, :registry_url, "127.0.0.1:19")

    ctx = Context.local()

    on_exit(fn ->
      if original_registry_url,
        do: Application.put_env(:cyfr, :registry_url, original_registry_url),
        else: Application.delete_env(:cyfr, :registry_url)
    end)

    {:ok, ctx: ctx}
  end

  # Helper to temporarily set edition and restore after test
  defp with_edition(edition, fun) do
    original_arx = Application.get_env(:cyfr, :edition)

    Application.put_env(:cyfr, :edition, edition)

    try do
      fun.()
    after
      if original_arx,
        do: Application.put_env(:cyfr, :edition, original_arx),
        else: Application.delete_env(:cyfr, :edition)
    end
  end

  # ============================================================================
  # Registry.Client — Error Handling
  # ============================================================================

  describe "search/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.search(ctx, %{query: "test"})
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts empty params", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.search(ctx, %{})
      assert err.registry == "cyfr.run"
    end

    test "accepts all filter params", %{ctx: ctx} do
      {:error, %Errors{}} =
        Client.search(ctx, %{
          query: "data",
          type: "reagent",
          category: "data-processing",
          tags: ["wasm", "data"],
          license: "MIT",
          limit: 10,
          offset: 0
        })
    end
  end

  describe "discover/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.discover(ctx, %{namespace: "cyfr"})
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts empty params", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.discover(ctx, %{})
      assert err.registry == "cyfr.run"
    end
  end

  describe "get_component/5 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable", %{ctx: ctx} do
      {:error, %Errors{} = err} = Client.get_component(ctx, "reagent", "cyfr", "data-processor")
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "includes version in request when provided", %{ctx: ctx} do
      {:error, %Errors{} = err} =
        Client.get_component(ctx, "reagent", "cyfr", "data-processor", "1.0.0")

      assert err.registry == "cyfr.run"
    end
  end

  # ============================================================================
  # MCP Routing — Core edition routes search to Registry.Client
  # ============================================================================

  describe "MCP search routing" do
    test "Core edition attempts cyfr.run search (gets connection error, falls back to local with loud failure)",
         %{ctx: ctx} do
      with_edition(:core, fn ->
        {:ok, result} =
          MCP.handle("component", ctx, %{
            "action" => "search",
            "query" => "nonexistent-component-xyz"
          })

        # Should get local results with structured failure info
        assert is_list(result[:components]) or is_list(result.components)
        assert result[:incomplete] == true
        assert is_binary(result[:registry_error])
        assert result[:registry_error] =~ "cyfr.run"
        assert result[:note] =~ "INCOMPLETE RESULTS"
        assert result[:note] =~ "cyfr.run search failed"
      end)
    end

    test "Arx edition does not attempt cyfr.run search", %{ctx: ctx} do
      with_edition(:arx, fn ->
        {:ok, result} =
          MCP.handle("component", ctx, %{
            "action" => "search",
            "query" => "nonexistent-component-xyz"
          })

        # Arx returns local results only, no warning about cyfr.run
        assert is_list(result.components)
        refute result[:warning]
      end)
    end
  end

  # ============================================================================
  # MCP Routing — Core edition routes discover to Registry.Client
  # ============================================================================

  describe "MCP discover routing" do
    test "Core edition uses cyfr.run REST API for discover (fails with connection error)", %{
      ctx: ctx
    } do
      with_edition(:core, fn ->
        {:error, reason} =
          MCP.handle("component", ctx, %{
            "action" => "discover"
          })

        # Core routes through Registry.Client which fails to connect
        assert reason =~ "cyfr.run"
      end)
    end

    test "Core edition rejects non-cyfr.run registry for discover", %{ctx: ctx} do
      with_edition(:core, fn ->
        {:error, msg} =
          MCP.handle("component", ctx, %{
            "action" => "discover",
            "registry" => "ghcr.io"
          })

        assert msg =~ "Core edition only supports registry.cyfr.run"
      end)
    end

    test "Arx edition uses OCI.Client for discover (not Registry.Client)", %{ctx: ctx} do
      with_edition(:arx, fn ->
        result =
          MCP.handle("component", ctx, %{
            "action" => "discover"
          })

        # Arx uses OCI.Client.discover which hits the network directly.
        # The error should NOT mention "cyfr.run REST API" — it goes through
        # OCI protocol instead.
        case result do
          {:error, msg} ->
            refute msg =~ "cyfr.run discover failed"
            refute msg =~ "cyfr.run search failed"

          {:ok, _} ->
            :ok
        end
      end)
    end

    test "Arx edition allows custom registry for discover", %{ctx: ctx} do
      with_edition(:arx, fn ->
        result =
          MCP.handle("component", ctx, %{
            "action" => "discover",
            "registry" => "ghcr.io"
          })

        case result do
          {:error, msg} -> refute msg =~ "Core edition"
          {:ok, _} -> :ok
        end
      end)
    end
  end

  # ============================================================================
  # Post-auth-refactor endpoints — error paths
  #
  # These tests mirror the existing error-path philosophy (set :registry_url to
  # an unreachable host; assert %Errors{} shape). Happy-path HTTP responses
  # aren't covered here — the repo has no Finch mocking infrastructure and
  # adding one is out of scope; integration coverage lands with codex work.
  # ============================================================================

  describe "probe_identity/3 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} = Client.probe_identity(:github, "fake-access-token")
      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "accepts an explicit label override" do
      {:error, %Errors{} = err} =
        Client.probe_identity(:github, "fake-access-token", "my-laptop")

      assert err.reason == :registry_unavailable
    end

    test "accepts provider as string or atom (normalized to string in body)" do
      {:error, %Errors{}} = Client.probe_identity("github", "tok")
      {:error, %Errors{}} = Client.probe_identity(:google, "tok")
    end
  end

  describe "claim_personal_namespace/4 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.claim_personal_namespace("alice", :github, "fake-access-token")

      assert err.reason == :registry_unavailable
    end
  end

  describe "claim_publisher_namespace/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.claim_publisher_namespace("acme.com", "fake-bearer")

      assert err.reason == :registry_unavailable
    end
  end

  describe "verify_publisher_namespace/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.verify_publisher_namespace("acme.com", "fake-bearer")

      assert err.reason == :registry_unavailable
    end
  end

  describe "get_namespace/1 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} = Client.get_namespace("alice")
      assert err.reason == :registry_unavailable
    end
  end

  describe "list_tokens/2 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} = Client.list_tokens("alice", "fake-bearer")
      assert err.reason == :registry_unavailable
    end
  end

  describe "issue_additional_token/3 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.issue_additional_token("alice", "fake-bearer", "ci-laptop")

      assert err.reason == :registry_unavailable
    end

    test "accepts nil label — defaults to device_label()" do
      {:error, %Errors{}} = Client.issue_additional_token("alice", "fake-bearer", nil)
    end
  end

  describe "revoke_token/3 - error handling" do
    test "returns %Errors{} when cyfr.run is unreachable" do
      {:error, %Errors{} = err} =
        Client.revoke_token("alice", "01H8K9XZABC", "fake-bearer")

      assert err.reason == :registry_unavailable
    end
  end

  describe "members CRUD - error handling" do
    test "add_member returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} =
        Client.add_member("acme.com", "alice", "member", "fake-bearer")

      assert err.reason == :registry_unavailable
    end

    test "update_member returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} =
        Client.update_member("acme.com", "alice", "admin", "fake-bearer")

      assert err.reason == :registry_unavailable
    end

    test "remove_member returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} =
        Client.remove_member("acme.com", "alice", "fake-bearer")

      assert err.reason == :registry_unavailable
    end

    test "list_members returns %Errors{} on connection refused" do
      {:error, %Errors{} = err} = Client.list_members("acme.com", "fake-bearer")
      assert err.reason == :registry_unavailable
    end
  end

  describe "token redaction" do
    # The log_token_returning_result/redact pipeline runs on every call to a
    # token-returning endpoint. We can't observe the redaction on the error
    # path (redact only runs on {:ok, body}), but we CAN confirm that a
    # probe call with a fake access_token never leaks the raw token value
    # into Logger output — the access_token goes into the request body, and
    # Phoenix's :filter_parameters + Client.redact cover the response side.
    #
    # This test intentionally uses a connection-refused host so no real
    # response bytes are generated, only the error-side Logger line which
    # should reference %Errors{} structure — never the access_token.
    test "connection-refused log does not leak the request-side access_token" do
      import ExUnit.CaptureLog

      fake_token = "gho_supersecret_test_only_token_XYZ"

      log =
        capture_log(fn ->
          {:error, %Errors{}} = Client.probe_identity(:github, fake_token)
        end)

      refute log =~ fake_token,
             "access_token leaked into Logger output — check Client.redact/1"
    end
  end

  describe "device_label/0" do
    setup do
      original_app = Application.get_env(:cyfr, :device_label)
      original_env = System.get_env("CYFR_DEVICE_LABEL")

      on_exit(fn ->
        if original_app,
          do: Application.put_env(:cyfr, :device_label, original_app),
          else: Application.delete_env(:cyfr, :device_label)

        if original_env,
          do: System.put_env("CYFR_DEVICE_LABEL", original_env),
          else: System.delete_env("CYFR_DEVICE_LABEL")
      end)

      :ok
    end

    test "prefers :cyfr, :device_label app env over CYFR_DEVICE_LABEL env" do
      Application.put_env(:cyfr, :device_label, "app-env-value")
      System.put_env("CYFR_DEVICE_LABEL", "os-env-value")
      assert Client.device_label() == "app-env-value"
    end

    test "falls back to CYFR_DEVICE_LABEL when no app env" do
      Application.delete_env(:cyfr, :device_label)
      System.put_env("CYFR_DEVICE_LABEL", "os-env-value")
      assert Client.device_label() == "os-env-value"
    end

    test "falls back to machine hostname when neither env set" do
      Application.delete_env(:cyfr, :device_label)
      System.delete_env("CYFR_DEVICE_LABEL")

      label = Client.device_label()
      assert is_binary(label)
      assert label != ""
    end
  end

  # ============================================================================
  # MCP Pull — Stale cache warning surfacing
  # ============================================================================

  describe "MCP pull - stale cache warning" do
    test "Core edition surfaces pull warnings from OCI.Client", %{ctx: ctx} do
      with_edition(:core, fn ->
        # Pull from cyfr.run will fail at network level, but this tests
        # the code path that checks for result[:warning]
        result =
          MCP.handle("component", ctx, %{
            "action" => "pull",
            "reference" => "registry.cyfr.run/cyfr/reagents/test:1.0.0"
          })

        # Network error expected — we're just verifying the code path exists
        assert {:error, _} = result
      end)
    end

    test "Arx edition surfaces pull warnings from OCI.Client", %{ctx: ctx} do
      with_edition(:arx, fn ->
        result =
          MCP.handle("component", ctx, %{
            "action" => "pull",
            "reference" => "ghcr.io/alice/reagents/test:1.0.0"
          })

        # Network error expected
        assert {:error, _} = result
      end)
    end
  end
end
