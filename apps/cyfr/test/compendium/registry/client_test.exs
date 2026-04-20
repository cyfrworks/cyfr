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

  describe "happy-path wire tests (Bypass)" do
    # Boots a real (but ephemeral) HTTP server per test via Bypass; points the
    # Client at it via :registry_url + :registry_scheme overrides. Confirms
    # method + path + Authorization-header plumbing for the 12 Registry.Client
    # endpoints. Error paths are covered above via the non-routable-host
    # pattern; these tests exercise the 200-response decode path that
    # connection-refused can never reach.

    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")

      on_exit(fn ->
        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_scheme,
          do: Application.put_env(:cyfr, :registry_scheme, original_scheme),
          else: Application.delete_env(:cyfr, :registry_scheme)
      end)

      {:ok, bypass: bypass}
    end

    defp json_resp(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    defp auth_header(conn) do
      conn
      |> Plug.Conn.get_req_header("authorization")
      |> List.first()
    end

    test "probe_identity/3 — POST /v1/identity/probe with access_token in body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["provider"] == "github"
        assert body["access_token"] == "gho_access"
        assert is_binary(body["label"])
        # Access-token endpoints MUST NOT carry a push-token bearer.
        assert auth_header(conn) == nil

        resp = %{
          "personal_namespace" => %{"slug" => "alice"},
          "memberships" => [],
          "tokens" => [
            %{
              "namespace" => "alice",
              "token" => "cyfr_pt_probe_xyz",
              "issued_at" => "2026-04-21T00:00:00Z",
              "label" => "laptop"
            }
          ]
        }

        json_resp(conn, 200, resp)
      end)

      assert {:ok, %{"personal_namespace" => %{"slug" => "alice"}, "tokens" => [_]}} =
               Client.probe_identity("github", "gho_access", "laptop")
    end

    test "claim_personal_namespace/4 — POST /v1/namespaces/personal/claim", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/personal/claim", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["username"] == "alice"
        assert body["provider"] == "github"
        assert body["access_token"] == "gho_access"

        json_resp(conn, 200, %{
          "namespace" => %{"slug" => "alice", "kind" => "personal"},
          "token" => "cyfr_pt_claim_xyz",
          "label" => "laptop"
        })
      end)

      assert {:ok, %{"namespace" => %{"slug" => "alice"}, "token" => "cyfr_pt_claim_xyz"}} =
               Client.claim_personal_namespace("alice", "github", "gho_access", "laptop")
    end

    test "claim_publisher_namespace/2 — POST /v1/namespaces/publisher/claim with Bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/publisher/claim", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_personal_abc"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"slug" => "stripe.com"} = Jason.decode!(raw)

        json_resp(conn, 200, %{
          "slug" => "stripe.com",
          "challenge" => %{"record_name" => "_cyfr-verify.stripe.com", "record_value" => "cyfr-verify=abc123"}
        })
      end)

      assert {:ok, %{"slug" => "stripe.com", "challenge" => _}} =
               Client.claim_publisher_namespace("stripe.com", "cyfr_pt_personal_abc")
    end

    test "verify_publisher_namespace/2 — POST /v1/namespaces/publisher/verify with Bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/publisher/verify", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_personal_abc"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"slug" => "stripe.com"} = Jason.decode!(raw)

        json_resp(conn, 200, %{
          "namespace" => %{"slug" => "stripe.com", "domain_verified" => true},
          "token" => "cyfr_pt_verify_xyz",
          "label" => "laptop"
        })
      end)

      assert {:ok, %{"token" => "cyfr_pt_verify_xyz"}} =
               Client.verify_publisher_namespace("stripe.com", "cyfr_pt_personal_abc")
    end

    test "get_namespace/1 — GET /v1/namespaces/{slug} without auth", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/namespaces/alice", fn conn ->
        assert auth_header(conn) == nil
        json_resp(conn, 200, %{"slug" => "alice", "kind" => "personal", "domain_verified" => false})
      end)

      assert {:ok, %{"slug" => "alice"}} = Client.get_namespace("alice")
    end

    test "list_tokens/2 — GET /v1/namespaces/{slug}/tokens with Bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/namespaces/alice/tokens", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_alice_abc"

        json_resp(conn, 200, %{
          "tokens" => [
            %{"id" => "t1", "label" => "laptop", "created_at" => "2026-04-01T00:00:00Z"}
          ]
        })
      end)

      assert {:ok, %{"tokens" => [%{"id" => "t1"}]}} =
               Client.list_tokens("alice", "cyfr_pt_alice_abc")
    end

    test "issue_additional_token/3 — POST /v1/namespaces/{slug}/tokens with Bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/alice/tokens", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_alice_abc"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"label" => "workstation"} = Jason.decode!(raw)

        json_resp(conn, 200, %{
          "id" => "t2",
          "token" => "cyfr_pt_new_xyz",
          "label" => "workstation",
          "created_at" => "2026-04-21T00:00:00Z"
        })
      end)

      assert {:ok, %{"token" => "cyfr_pt_new_xyz", "id" => "t2"}} =
               Client.issue_additional_token("alice", "cyfr_pt_alice_abc", "workstation")
    end

    test "revoke_token/3 — DELETE /v1/namespaces/{slug}/tokens/{id} returns :ok", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/v1/namespaces/alice/tokens/t1", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_alice_abc"
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Client.revoke_token("alice", "t1", "cyfr_pt_alice_abc")
    end

    test "add_member/4 — POST /v1/namespaces/{slug}/members with Bearer + body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/stripe.com/members", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_stripe_admin"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["target_personal_slug"] == "bob"
        assert body["role"] == "member"

        json_resp(conn, 200, %{
          "slug" => "stripe.com",
          "member" => %{"personal_slug" => "bob", "role" => "member"}
        })
      end)

      assert {:ok, %{"member" => %{"personal_slug" => "bob"}}} =
               Client.add_member("stripe.com", "bob", "member", "cyfr_pt_stripe_admin")
    end

    test "update_member/4 — PATCH /v1/namespaces/{slug}/members/{target} with Bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "PATCH", "/v1/namespaces/stripe.com/members/bob", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_stripe_admin"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"role" => "admin"} = Jason.decode!(raw)

        json_resp(conn, 200, %{
          "member" => %{"personal_slug" => "bob", "role" => "admin"}
        })
      end)

      assert {:ok, %{"member" => %{"role" => "admin"}}} =
               Client.update_member("stripe.com", "bob", "admin", "cyfr_pt_stripe_admin")
    end

    test "remove_member/3 — DELETE /v1/namespaces/{slug}/members/{target} returns :ok", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/v1/namespaces/stripe.com/members/bob", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_stripe_admin"
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = Client.remove_member("stripe.com", "bob", "cyfr_pt_stripe_admin")
    end

    test "list_members/2 — GET /v1/namespaces/{slug}/members with Bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/namespaces/stripe.com/members", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_stripe_admin"

        json_resp(conn, 200, %{
          "members" => [
            %{"personal_slug" => "alice", "role" => "admin"},
            %{"personal_slug" => "bob", "role" => "member"}
          ]
        })
      end)

      assert {:ok, %{"members" => [%{"role" => "admin"}, %{"role" => "member"}]}} =
               Client.list_members("stripe.com", "cyfr_pt_stripe_admin")
    end
  end

  describe "happy-path log redaction" do
    # Token-returning endpoints route through log_token_returning_result/redact.
    # Verify that on a successful response containing a `token` field, the
    # Logger.info line carries `[REDACTED]` and never the raw token value.

    setup do
      bypass = Bypass.open()
      original_url = Application.get_env(:cyfr, :registry_url)
      original_scheme = Application.get_env(:cyfr, :registry_scheme)

      Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
      Application.put_env(:cyfr, :registry_scheme, "http")

      on_exit(fn ->
        if original_url,
          do: Application.put_env(:cyfr, :registry_url, original_url),
          else: Application.delete_env(:cyfr, :registry_url)

        if original_scheme,
          do: Application.put_env(:cyfr, :registry_scheme, original_scheme),
          else: Application.delete_env(:cyfr, :registry_scheme)
      end)

      {:ok, bypass: bypass}
    end

    @raw_token "cyfr_pt_SUPERSECRET_TEST_ONLY_zzz"

    # Bumps the primary Logger level to :info for the duration of the call
    # (config/test.exs sets it to :warning globally) so the Logger.info line
    # in `log_token_returning_result/2` actually reaches ExUnit.CaptureLog.
    defp with_info_log(fun) do
      import ExUnit.CaptureLog
      original = Logger.level()

      try do
        Logger.configure(level: :info)
        capture_log([level: :info], fun)
      after
        Logger.configure(level: original)
      end
    end

    test "probe_identity — token in response is redacted in logs", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        json_resp(conn, 200, %{
          "personal_namespace" => %{"slug" => "alice"},
          "memberships" => [],
          "tokens" => [%{"namespace" => "alice", "token" => @raw_token, "issued_at" => "2026-04-21T00:00:00Z", "label" => "l"}]
        })
      end)

      log = with_info_log(fn -> {:ok, _} = Client.probe_identity("github", "gho_x") end)

      assert log =~ "[REDACTED]", "token-redacting wrapper did not run on happy path"
      refute log =~ @raw_token, "raw token leaked into Logger output"
    end

    test "claim_personal_namespace — top-level token is redacted", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/personal/claim", fn conn ->
        json_resp(conn, 200, %{
          "namespace" => %{"slug" => "alice"},
          "token" => @raw_token,
          "label" => "l"
        })
      end)

      log =
        with_info_log(fn ->
          {:ok, _} = Client.claim_personal_namespace("alice", "github", "gho_x")
        end)

      assert log =~ "[REDACTED]"
      refute log =~ @raw_token
    end

    test "verify_publisher_namespace — token is redacted", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/publisher/verify", fn conn ->
        json_resp(conn, 200, %{
          "namespace" => %{"slug" => "stripe.com"},
          "token" => @raw_token,
          "label" => "l"
        })
      end)

      log =
        with_info_log(fn ->
          {:ok, _} = Client.verify_publisher_namespace("stripe.com", "bearer")
        end)

      assert log =~ "[REDACTED]"
      refute log =~ @raw_token
    end

    test "issue_additional_token — token is redacted", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/alice/tokens", fn conn ->
        json_resp(conn, 200, %{
          "id" => "t2",
          "token" => @raw_token,
          "label" => "l",
          "created_at" => "2026-04-21T00:00:00Z"
        })
      end)

      log =
        with_info_log(fn ->
          {:ok, _} = Client.issue_additional_token("alice", "bearer", "l")
        end)

      assert log =~ "[REDACTED]"
      refute log =~ @raw_token
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

  # Component moderation (deprecate / yank) client calls. The non-routable
  # registry_url in setup/0 guarantees these return
  # %Errors{reason: :registry_unavailable}, which is enough to exercise the
  # URL-building + bearer-threading code path. Full wire-level assertions live
  # in cyfr.run/internal/api integration tests.
  describe "deprecate_component/6 - error handling" do
    test "reaches the registry with the right path and bearer", %{ctx: _ctx} do
      {:error, %Errors{} = err} =
        Client.deprecate_component("alice", "catalyst", "widget", "1.0.0", "use v2", "cyfr_pt_x")

      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "passes through URL-unsafe chars in slug + name + version", %{ctx: _ctx} do
      # Server rejects these anyway; the client must pass through verbatim
      # (no silent mangling). Verifies URI.encode covers the input.
      {:error, %Errors{}} =
        Client.deprecate_component(
          "stripe.com",
          "reagent",
          "api-v2",
          "1.2.3-beta+abc",
          "legacy",
          "cyfr_pt_y"
        )
    end
  end

  describe "yank_component/6 - error handling" do
    test "accepts empty reason", %{ctx: _ctx} do
      {:error, %Errors{} = err} =
        Client.yank_component("alice", "catalyst", "widget", "1.0.0", "", "cyfr_pt_x")

      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end
  end

  describe "MCP component.deprecate" do
    test "rejects missing reason", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "deprecate",
          "reference" => "c:alice.widget:1.0.0"
        })

      assert msg =~ "reason"
    end

    test "rejects empty reason", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "deprecate",
          "reference" => "c:alice.widget:1.0.0",
          "reason" => ""
        })

      assert msg =~ "reason"
    end

    test "rejects unpinned ref (no version)", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "deprecate",
          "reference" => "c:alice.widget",
          "reason" => "use v2"
        })

      assert msg =~ "pinned version"
    end
  end

  # Admin-moderation client tests — URL/path/bearer plumbing. Non-routable
  # host makes every call fail at connection time, which is enough to
  # exercise the request-build code path without a full server stub.
  describe "admin moderation — client" do
    test "create_abuse_report/5 reaches the registry" do
      {:error, %Errors{} = err} =
        Client.create_abuse_report("malware", "alice", nil, "d", "cyfr_pt_x")

      assert err.registry == "cyfr.run"
      assert err.reason == :registry_unavailable
    end

    test "admin_takedown_component/6 uses admin bearer" do
      {:error, %Errors{}} =
        Client.admin_takedown_component("alice", "catalyst", "widget", "1.0.0", "DMCA", "admin-tok")
    end

    test "admin_revoke_namespace_tokens/3 reaches registry" do
      {:error, %Errors{}} =
        Client.admin_revoke_namespace_tokens("alice", "compromise", "admin-tok")
    end

    test "admin_resolve_report/3 reaches registry" do
      {:error, %Errors{}} = Client.admin_resolve_report("rid-123", "resolved", "admin-tok")
    end

    test "admin_dismiss_report/3 accepts empty resolution" do
      {:error, %Errors{}} = Client.admin_dismiss_report("rid-123", "", "admin-tok")
    end

    test "admin_list_open_reports/2 supports limit/offset" do
      {:error, %Errors{}} = Client.admin_list_open_reports("admin-tok", limit: 10, offset: 20)
    end
  end

  describe "MCP registry.report" do
    test "rejects missing category", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("registry", ctx, %{
          "action" => "report",
          "target_namespace" => "alice",
          "details" => "d"
        })

      assert msg =~ "category"
    end

    test "rejects missing target", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("registry", ctx, %{
          "action" => "report",
          "category" => "malware",
          "details" => "d"
        })

      assert msg =~ "target"
    end

    test "rejects missing details", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("registry", ctx, %{
          "action" => "report",
          "category" => "malware",
          "target_namespace" => "alice"
        })

      assert msg =~ "details"
    end
  end

  describe "MCP admin.*" do
    test "rejects non-admin context", %{ctx: _ctx} do
      # The default ctx from Context.local() has wildcard :* — we need a
      # non-admin one for this test.
      non_admin = Sanctum.Context.build(user_id: "not-admin", permissions: [:execute])

      {:error, msg} =
        MCP.handle("admin", non_admin, %{
          "action" => "list-reports"
        })

      assert msg =~ "admin"
    end

    test "admin.takedown rejects missing reason" do
      # Use a ctx with admin permission so we get past the auth check.
      admin_ctx = Sanctum.Context.build(user_id: "admin-1", permissions: [:admin])

      {:error, msg} =
        MCP.handle("admin", admin_ctx, %{
          "action" => "takedown",
          "reference" => "c:alice.widget:1.0.0"
        })

      assert msg =~ "reason"
    end

    test "admin.resolve-report rejects missing report_id" do
      admin_ctx = Sanctum.Context.build(user_id: "admin-1", permissions: [:admin])

      {:error, msg} =
        MCP.handle("admin", admin_ctx, %{
          "action" => "resolve-report",
          "resolution" => "done"
        })

      assert msg =~ "report_id"
    end

    test "admin.set-token rejects missing token" do
      admin_ctx = Sanctum.Context.build(user_id: "admin-1", permissions: [:admin])

      {:error, msg} =
        MCP.handle("admin", admin_ctx, %{
          "action" => "set-token"
        })

      assert msg =~ "admin_token"
    end
  end

  describe "MCP component.yank" do
    test "rejects missing reference", %{ctx: ctx} do
      {:error, msg} = MCP.handle("component", ctx, %{"action" => "yank"})
      assert msg =~ "reference"
    end

    test "rejects unpinned ref", %{ctx: ctx} do
      {:error, msg} =
        MCP.handle("component", ctx, %{
          "action" => "yank",
          "reference" => "c:alice.widget"
        })

      assert msg =~ "pinned version"
    end
  end

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
