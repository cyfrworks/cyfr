# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Registry.ClientSyncTest do
  # Tests that point the client at a Bypass server or at a seeded cache
  # (`:registry_url`, `:registry_scheme`, `:oci_registry_url` and the
  # storage root are global configuration) or capture its log (the capture
  # and the log level are global), so they run alone. The rest of the
  # client's tests run async in `Compendium.Registry.ClientTest`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Compendium.Registry.{Client, CredentialStore}
  alias Compendium.Provider
  alias Compendium.OCI.{Blob, Cache, Errors, Reference, Transport}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  # Boots a real (but ephemeral) HTTP server per test via Bypass and points
  # the client at it through the :registry_url and :registry_scheme
  # overrides. Bypass fails the test on any request it holds no expectation
  # for, so a test that sets none proves that no request left.
  defp point_at_bypass(_context) do
    bypass = Bypass.open()
    original_url = Application.get_env(:cyfr, :registry_url)
    original_scheme = Application.get_env(:cyfr, :registry_scheme)

    Application.put_env(:cyfr, :registry_url, "127.0.0.1:#{bypass.port}")
    Application.put_env(:cyfr, :registry_scheme, "http")

    on_exit(fn ->
      restore_env(:cyfr, :registry_url, original_url)
      restore_env(:cyfr, :registry_scheme, original_scheme)
    end)

    {:ok, bypass: bypass}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

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

  defp read_json(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  # Every query pair in order: a repeated key would collapse in a map.
  defp query_pairs(conn), do: conn.query_string |> URI.query_decoder() |> Enum.to_list()

  # ============================================================================
  # Request shapes — what each call puts on the wire
  # ============================================================================

  describe "request shapes" do
    setup :point_at_bypass

    test "search/2 sends every filter param", %{ctx: ctx, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/components", fn conn ->
        assert query_pairs(conn) == [
                 {"q", "data"},
                 {"type", "reagent"},
                 {"category", "data-processing"},
                 {"license", "MIT"},
                 {"limit", "10"},
                 {"offset", "0"},
                 {"tags", "wasm"},
                 {"tags", "data"}
               ]

        json_resp(conn, 200, %{"components" => [], "total" => 0})
      end)

      assert {:ok, %{components: [], total: 0}} =
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

    test "get_component/5 puts the version in the path when given one", %{
      ctx: ctx,
      bypass: bypass
    } do
      Bypass.expect_once(
        bypass,
        "GET",
        "/v1/components/reagent/cyfr/data-processor/1.0.0",
        fn conn ->
          json_resp(conn, 200, %{"name" => "data-processor", "version" => "1.0.0"})
        end
      )

      assert {:ok, %{"name" => "data-processor", "version" => "1.0.0"}} =
               Client.get_component(ctx, "reagent", "cyfr", "data-processor", "1.0.0")
    end

    test "probe_identity/3 sends the provider as a string, given a string or an atom", %{
      bypass: bypass
    } do
      parent = self()

      Bypass.expect(bypass, "POST", "/v1/identity/probe", fn conn ->
        {body, conn} = read_json(conn)
        send(parent, {:provider, body["provider"]})
        json_resp(conn, 200, %{"personal_namespace" => nil, "memberships" => [], "tokens" => []})
      end)

      assert {:ok, _} = Client.probe_identity("github", "tok")
      assert {:ok, _} = Client.probe_identity(:google, "tok")

      assert_received {:provider, "github"}
      assert_received {:provider, "google"}
    end

    test "probe_identity/3 sends an explicit label override", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/identity/probe", fn conn ->
        {body, conn} = read_json(conn)

        assert body == %{
                 "provider" => "github",
                 "access_token" => "fake-access-token",
                 "label" => "my-laptop"
               }

        json_resp(conn, 200, %{"personal_namespace" => nil, "memberships" => [], "tokens" => []})
      end)

      assert {:ok, _} = Client.probe_identity(:github, "fake-access-token", "my-laptop")
    end

    test "issue_additional_token/3 with a nil label sends device_label()", %{bypass: bypass} do
      label = CredentialStore.device_label()

      Bypass.expect_once(bypass, "POST", "/v1/namespaces/alice/tokens", fn conn ->
        assert auth_header(conn) == "Bearer fake-bearer"
        {body, conn} = read_json(conn)
        assert body == %{"label" => label}

        json_resp(conn, 200, %{"id" => "t3", "token" => "cyfr_pt_t3", "label" => label})
      end)

      assert {:ok, %{"id" => "t3"}} = Client.issue_additional_token("alice", "fake-bearer", nil)
    end

    test "deprecate_component/6 reaches the registry with the right path, bearer and reason", %{
      bypass: bypass
    } do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v1/components/alice/catalyst/widget/1.0.0/deprecate",
        fn conn ->
          assert auth_header(conn) == "Bearer cyfr_pt_x"
          {body, conn} = read_json(conn)
          assert body == %{"reason" => "use v2"}

          json_resp(conn, 200, %{"status" => "deprecated"})
        end
      )

      assert {:ok, %{"status" => "deprecated"}} =
               Client.deprecate_component(
                 "alice",
                 "catalyst",
                 "widget",
                 "1.0.0",
                 "use v2",
                 "cyfr_pt_x"
               )
    end

    test "deprecate_component/6 leaves a legitimate slug, name and version untouched", %{
      bypass: bypass
    } do
      parent = self()

      Bypass.expect_once(bypass, fn conn ->
        send(parent, {:request, conn.method, conn.request_path})
        json_resp(conn, 200, %{"status" => "deprecated"})
      end)

      assert {:ok, _} =
               Client.deprecate_component(
                 "stripe.com",
                 "reagent",
                 "api-v2",
                 "1.2.3-beta+abc",
                 "legacy",
                 "cyfr_pt_y"
               )

      # `+` in a semver build tag is reserved, so it escapes; everything a
      # real slug/name/version uses is unreserved and survives verbatim.
      assert_received {:request, "POST",
                       "/v1/components/stripe.com/reagent/api-v2/1.2.3-beta%2Babc/deprecate"}
    end

    test "yank_component/6 sends an empty reason", %{bypass: bypass} do
      Bypass.expect_once(
        bypass,
        "POST",
        "/v1/components/alice/catalyst/widget/1.0.0/yank",
        fn conn ->
          assert auth_header(conn) == "Bearer cyfr_pt_x"
          {body, conn} = read_json(conn)
          assert body == %{"reason" => ""}

          json_resp(conn, 200, %{"status" => "yanked"})
        end
      )

      assert {:ok, %{"status" => "yanked"}} =
               Client.yank_component("alice", "catalyst", "widget", "1.0.0", "", "cyfr_pt_x")
    end

    test "create_abuse_report/5 reaches the registry with its bearer and report", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/abuse-reports", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_x"
        {body, conn} = read_json(conn)

        assert body == %{
                 "category" => "malware",
                 "target_namespace" => "alice",
                 "target_component_id" => nil,
                 "details" => "d"
               }

        json_resp(conn, 201, %{"id" => "rep_1"})
      end)

      assert {:ok, %{"id" => "rep_1"}} =
               Client.create_abuse_report("malware", "alice", nil, "d", "cyfr_pt_x")
    end
  end

  # ============================================================================
  # MCP Routing — a search asks cyfr.run beside the local index, as `source` says
  # ============================================================================

  describe "MCP search routing" do
    setup :point_at_bypass

    test "a search asks cyfr.run and answers the local rows, marked incomplete, when it refuses",
         %{ctx: ctx, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/components", fn conn ->
        assert {"q", "nonexistent-component-xyz"} in query_pairs(conn)
        json_resp(conn, 403, %{"error" => "denied"})
      end)

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "search",
          "query" => "nonexistent-component-xyz"
        })

      assert is_list(result.components)
      assert result.incomplete == true
      assert result.registry_error =~ "Access denied for cyfr.run"
      assert result.note =~ "INCOMPLETE RESULTS — cyfr.run search failed"
      assert result.note =~ "Only local components are shown."
    end

    test "a local-only search sends cyfr.run nothing", %{ctx: ctx, bypass: bypass} do
      # No expectation is set: Bypass fails the test on any request that
      # reaches it.
      _ = bypass

      {:ok, result} =
        Provider.handle("component", ctx, %{
          "action" => "search",
          "source" => "local",
          "query" => "nonexistent-component-xyz"
        })

      assert is_list(result.components)
      refute Map.has_key?(result, :incomplete)
      refute Map.has_key?(result, :registry_error)
    end
  end

  # ============================================================================
  # MCP Routing — discover asks cyfr.run's REST API for the configured host only
  # ============================================================================

  describe "MCP discover routing" do
    setup :point_at_bypass

    test "discover asks cyfr.run's REST API", %{ctx: ctx, bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/components", fn conn ->
        assert query_pairs(conn) == []
        json_resp(conn, 200, %{"components" => [%{"name" => "data-processor"}], "total" => 1})
      end)

      assert {:ok, result} = Provider.handle("component", ctx, %{"action" => "discover"})

      assert result == %{
               registry: Compendium.RegistryHost.canonical_host(),
               components: [%{name: "data-processor"}],
               total: 1
             }
    end

    test "discover refuses a registry other than the canonical one before any request", %{
      ctx: ctx,
      bypass: bypass
    } do
      # No expectation is set: Bypass fails the test on any request that
      # reaches it.
      _ = bypass

      {:error, refusal} =
        Provider.handle("component", ctx, %{
          "action" => "discover",
          "registry" => "ghcr.io"
        })

      assert %Prima.Refusal{class: :unavailable, reason: {:registry, :registry_host_mismatch}} =
               refusal

      assert err_msg(refusal) =~ "only supports #{Compendium.RegistryHost.canonical_host()}"
      assert err_msg(refusal) =~ "ghcr.io"
    end

    test "discover naming the canonical registry sends its namespace and type to cyfr.run", %{
      ctx: ctx,
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/v1/components", fn conn ->
        assert query_pairs(conn) == [{"publisher", "cyfr"}, {"type", "reagent"}]
        json_resp(conn, 200, %{"components" => [], "total" => 0})
      end)

      assert {:ok, %{components: [], total: 0}} =
               Provider.handle("component", ctx, %{
                 "action" => "discover",
                 "registry" => Compendium.RegistryHost.canonical_host(),
                 "namespace" => "cyfr",
                 "type" => "reagent"
               })
    end

    test "discover is refused as unconfigured when no registry is configured", %{
      ctx: ctx,
      bypass: bypass
    } do
      # `CYFR_REGISTRY_URL=none`; `point_at_bypass/1` restores the URL.
      _ = bypass
      Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())

      {:error, refusal} = Provider.handle("component", ctx, %{"action" => "discover"})

      assert %Prima.Refusal{reason: {:registry, :registry_unconfigured}} = refusal
      assert err_msg(refusal) =~ "No registry is configured on this server"
    end
  end

  # ============================================================================
  # MCP Pull — a stale cache's warning reaches the caller
  # ============================================================================

  # The canonical OCI host is the closed loopback port of `config/test.exs`,
  # so a tag's digest check never answers. The cache holds the manifest under
  # its own digest and the blobs it names, in a storage root of the test's
  # own; the caller's entitlement memo is what lets the pull serve them.
  describe "MCP pull - stale cache warning" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "cyfr_registry_stale_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      original_base = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, root)

      on_exit(fn ->
        restore_env(:arca, :base_path, original_base)
        File.rm_rf!(root)
      end)

      Cyfr.Test.Sandbox.stop_work_on_exit()

      registry = Compendium.RegistryHost.canonical_host()
      name = "stale#{System.unique_integer([:positive])}"
      repository = "alice/reagents/#{name}"

      # The smallest valid module: a pull that gets as far as storing it
      # stores it.
      wasm = <<0, ?a, ?s, ?m, 1, 0, 0, 0>>
      config = Jason.encode!(%{"name" => name, "version" => "1.0.0", "type" => "reagent"})
      manifest = manifest_json(config, wasm)

      :ok = Cache.put_blob(Blob.compute_digest(config), config)
      :ok = Cache.put_blob(Blob.compute_digest(wasm), wasm)

      {:ok,
       registry: registry,
       repository: repository,
       manifest: manifest,
       digest: Blob.compute_digest(manifest),
       reference: "#{registry}/#{repository}:1.0.0",
       ref: %Reference{registry: registry, repository: repository, tag: "1.0.0"}}
    end

    @stale_warning "Registry was unreachable during digest check — cached manifest may be stale"

    test "an anonymous pull served from a stale cache answers its warning", c do
      # A cached body that does not hash to its recorded digest is never
      # served: the pull refetches, and the registry does not answer.
      :ok = Cache.put_manifest(c.registry, c.repository, "1.0.0", c.manifest <> " ", c.digest)
      entitle!(credential_key(c.ctx, c.ref), c)

      assert {:error, refused} =
               Provider.handle("component", c.ctx, %{
                 "action" => "pull",
                 "reference" => c.reference
               })

      assert refused =~ "Failed to connect to #{c.registry}"

      :ok = Cache.put_manifest(c.registry, c.repository, "1.0.0", c.manifest, c.digest)

      assert {:ok, result} =
               Provider.handle("component", c.ctx, %{
                 "action" => "pull",
                 "reference" => c.reference
               })

      assert result.status == "pulled"
      assert result[:warning] == @stale_warning
      assert result.auth_note =~ "You are pulling anonymously"
    end

    test "a signed-in pull is served from a stale cache only under its own entitlement", c do
      signed_in = Sanctum.TestContext.local()
      :ok = CredentialStore.put_push_token(signed_in, c.registry, "alice", "tok_a", "personal")
      :ok = Cache.put_manifest(c.registry, c.repository, "1.0.0", c.manifest, c.digest)

      # The anonymous memo is not this caller's: the registry is asked
      # under its credential, does not answer, and nothing is served.
      entitle!("anonymous", c)
      key = credential_key(signed_in, c.ref)
      refute key == "anonymous"

      assert {:error, refused} =
               Provider.handle("component", signed_in, %{
                 "action" => "pull",
                 "reference" => c.reference
               })

      assert refused =~ "Failed to connect to #{c.registry}"

      entitle!(key, c)

      assert {:ok, result} =
               Provider.handle("component", signed_in, %{
                 "action" => "pull",
                 "reference" => c.reference
               })

      assert result.status == "pulled"
      assert result[:warning] == @stale_warning
      refute Map.has_key?(result, :auth_note)
    end
  end

  # The memo outlives the test unless it is forgotten.
  defp entitle!(key, c) do
    :ok = Cache.entitle(key, c.registry, c.repository)
    on_exit(fn -> Cache.forget_entitlement(key, c.registry, c.repository) end)
  end

  defp credential_key(ctx, ref) do
    {:ok, key} = Transport.credential_key(ctx, ref)
    key
  end

  # A minimal OCI image manifest wrapping `wasm` as a reagent layer under
  # `config`.
  defp manifest_json(config, wasm) do
    Jason.encode!(%{
      "schemaVersion" => 2,
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "artifactType" => "application/vnd.cyfr.component.v1",
      "config" => %{
        "mediaType" => "application/vnd.cyfr.manifest.v1+json",
        "size" => byte_size(config),
        "digest" => Blob.compute_digest(config)
      },
      "layers" => [
        %{
          "mediaType" => "application/vnd.cyfr.reagent.v1+wasm",
          "size" => byte_size(wasm),
          "digest" => Blob.compute_digest(wasm)
        }
      ],
      "annotations" => %{}
    })
  end

  describe "token redaction" do
    # The log_token_returning_result pipeline runs on every call to a
    # token-returning endpoint. We can't observe the redaction on the error
    # path (Prima.Sanitizer.sanitize/1 only runs on {:ok, body}), but we
    # CAN confirm that a probe call with a fake access_token never leaks the
    # raw token value into Logger output — the access_token goes into the
    # request body, and :filter_parameters + the sanitizer cover the
    # response side.
    #
    # This test intentionally uses a connection-refused host so no real
    # response bytes are generated, only the error-side Logger line which
    # should reference %Errors{} structure — never the access_token.
    test "connection-refused log does not leak the request-side access_token" do
      fake_token = "gho_supersecret_test_only_token_XYZ"

      log =
        capture_log(fn ->
          {:error, %Errors{}} = Client.probe_identity(:github, fake_token)
        end)

      # The failure line is written, and it does not carry the token.
      assert log =~ "probe_identity failed"

      refute log =~ fake_token,
             "access_token leaked into Logger output — check Client.redact/1"
    end
  end

  describe "happy-path wire tests (Bypass)" do
    # Confirms method + path + Authorization-header plumbing for every
    # Registry.Client endpoint, and the 200-response decode path that a
    # refused connection can never reach.
    setup :point_at_bypass

    test "a damaged stored push token refuses before any request leaves", %{
      ctx: ctx,
      bypass: bypass
    } do
      registry = Compendium.RegistryHost.canonical_host()

      # One usable token, and one row that does not open: the damaged row
      # fails the choice, rather than handing over the other token or
      # sending the request anonymously.
      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          ctx,
          registry,
          "zeta.example",
          "cyfr_pt_usable",
          "personal"
        )

      aad = Sanctum.CipherAAD.registry_token(ctx.user_id, registry, "alice")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt("not json", aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: ctx.user_id,
          registry: registry,
          namespace_slug: "alice",
          credential_ciphertext: ciphertext
        })

      # No expectation is set: Bypass fails the test on any request that
      # reaches it.
      _ = bypass

      assert {:error, {:corrupt, :registry_credential}} = Client.search(ctx, %{query: "x"})
      assert {:error, {:corrupt, :registry_credential}} = Client.discover(ctx, %{})

      assert {:error, {:corrupt, :registry_credential}} =
               Client.get_component(ctx, "reagent", "alice", "thing", "1.0.0")

      assert %Prima.Refusal{class: :corrupt} =
               Prima.Refusal.classify({:corrupt, :registry_credential})
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

    test "claim_publisher_namespace/2 — POST /v1/namespaces/publisher/claim with Bearer", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/namespaces/publisher/claim", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_personal_abc"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"slug" => "stripe.com"} = Jason.decode!(raw)

        json_resp(conn, 200, %{
          "slug" => "stripe.com",
          "challenge" => %{
            "record_name" => "_cyfr-verify.stripe.com",
            "record_value" => "cyfr-verify=abc123"
          }
        })
      end)

      assert {:ok, %{"slug" => "stripe.com", "challenge" => _}} =
               Client.claim_publisher_namespace("stripe.com", "cyfr_pt_personal_abc")
    end

    test "verify_publisher_namespace/2 — POST /v1/namespaces/publisher/verify with Bearer", %{
      bypass: bypass
    } do
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

        json_resp(conn, 200, %{
          "slug" => "alice",
          "kind" => "personal",
          "domain_verified" => false
        })
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

    test "issue_additional_token/3 — POST /v1/namespaces/{slug}/tokens with Bearer", %{
      bypass: bypass
    } do
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

    test "revoke_token/3 — DELETE /v1/namespaces/{slug}/tokens/{id} returns :ok", %{
      bypass: bypass
    } do
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

    test "update_member/4 — PATCH /v1/namespaces/{slug}/members/{target} with Bearer", %{
      bypass: bypass
    } do
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

    test "remove_member/3 — DELETE /v1/namespaces/{slug}/members/{target} returns :ok", %{
      bypass: bypass
    } do
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

    test "list_my_reports/2 — GET /v1/abuse-reports/mine with paging and Bearer", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/v1/abuse-reports/mine", fn conn ->
        assert auth_header(conn) == "Bearer cyfr_pt_alice"
        params = Plug.Conn.fetch_query_params(conn).query_params
        assert params["limit"] == "10"
        assert params["offset"] == "20"

        json_resp(conn, 200, %{"reports" => [%{"id" => "rep_1"}], "total" => 1})
      end)

      assert {:ok, %{"reports" => [%{"id" => "rep_1"}], "total" => 1}} =
               Client.list_my_reports("cyfr_pt_alice", limit: 10, offset: 20)
    end

    test "get_legal_page/1 — GET /v1/legal/{name}, no bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/legal/terms", fn conn ->
        assert auth_header(conn) == nil

        json_resp(conn, 200, %{
          "name" => "terms",
          "title" => "Terms of Service",
          "content_markdown" => "# Terms"
        })
      end)

      assert {:ok, %{"name" => "terms", "content_markdown" => "# Terms"}} =
               Client.get_legal_page("terms")
    end

    test "get_legal_version/0 — GET /v1/legal/version, no bearer", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/v1/legal/version", fn conn ->
        assert auth_header(conn) == nil

        json_resp(conn, 200, %{
          "policy_version" => "2026-08-01",
          "policies" => [%{"name" => "terms", "title" => "Terms", "sha256" => "abc"}]
        })
      end)

      assert {:ok, %{"policy_version" => "2026-08-01"}} = Client.get_legal_version()
    end

    test "accept_policies/4 — POST /v1/legal/accept with access_token in body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/legal/accept", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["provider"] == "github"
        assert body["access_token"] == "gho_access"
        assert body["policy_version"] == "2026-08-01"
        # An access-token endpoint never carries a push-token bearer.
        assert auth_header(conn) == nil

        json_resp(conn, 201, %{"id" => "acc_1", "policy_version" => "2026-08-01"})
      end)

      assert {:ok, %{"id" => "acc_1"}} =
               Client.accept_policies("github", "gho_access", nil, "2026-08-01")
    end

    test "create_appeal/6 — POST /v1/appeals with access_token in body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/appeals", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["provider"] == "github"
        assert body["access_token"] == "gho_access"
        assert body["action_type"] == "yank"
        assert body["action_ref"] == "c:alice.foo:1.0.0"
        assert body["argument"] == "this was a mistake"
        assert auth_header(conn) == nil

        json_resp(conn, 201, %{"id" => "app_1", "status" => "open"})
      end)

      assert {:ok, %{"id" => "app_1", "status" => "open"}} =
               Client.create_appeal(
                 "github",
                 "gho_access",
                 nil,
                 "yank",
                 "c:alice.foo:1.0.0",
                 "this was a mistake"
               )
    end

    test "a slug carrying path separators stays one segment", %{bypass: bypass} do
      parent = self()

      Bypass.expect(bypass, fn conn ->
        send(parent, {:segments, conn.path_info})
        json_resp(conn, 404, %{"error" => "not found"})
      end)

      {:error, %Errors{}} = Client.get_namespace("../v1/legal/version")

      # Three segments, the slug escaped into the third — not six segments
      # addressing a different endpoint.
      assert_received {:segments, ["v1", "namespaces", "..%2Fv1%2Flegal%2Fversion"]}
    end
  end

  describe "happy-path log redaction" do
    # Token-returning endpoints route through log_token_returning_result/redact.
    # Verify that on a successful response containing a `token` field, the
    # Logger.info line carries `[REDACTED]` and never the raw token value.
    setup :point_at_bypass

    @raw_token "cyfr_pt_SUPERSECRET_TEST_ONLY_zzz"

    # Bumps the primary Logger level to :info for the duration of the call
    # (config/test.exs sets it to :warning globally) so the Logger.info line
    # in `log_token_returning_result/2` actually reaches ExUnit.CaptureLog.
    defp with_info_log(fun) do
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
          "tokens" => [
            %{
              "namespace" => "alice",
              "token" => @raw_token,
              "issued_at" => "2026-04-21T00:00:00Z",
              "label" => "l"
            }
          ]
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

  # Providers answer typed reasons where the class is clear; the shared
  # renderer is the one spelling of every sentence, so assert through it.
  # Plain strings pass through unchanged.
  defp err_msg(reason) do
    Sanctum.Refusals.render(reason) ||
      flunk("unrenderable refusal: #{inspect(reason)}")
  end
end
