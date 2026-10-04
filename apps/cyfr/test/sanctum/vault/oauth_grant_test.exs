# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthGrantTest do
  use ExUnit.Case, async: false

  # What a dispense is made for, as an attempt names it. These resources
  # carry no binding key, so no binding lifetime is read for them.
  @dispense %{root_execution_id: "exec_reader_test", profile_id: nil, consent_id: nil}

  alias Sanctum.CipherAAD
  alias Sanctum.Vault.OAuthGrant
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  @provider "google"
  @scopes ["https://www.googleapis.com/auth/gmail.readonly"]

  # Where the cases' entries may go. Their tokens are dispensed to the
  # cases, so the entries are disclosed.
  @destination %{"hosts" => ["gmail.googleapis.com"]}
  @destination_text ~s({"hosts":["gmail.googleapis.com"],"scheme":"https"})

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "oauth_grant_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.local()

    :ok =
      Sanctum.TestContext.put_provider_credentials(
        ctx,
        @provider,
        "client-id-1",
        "client-secret-1"
      )

    {:ok, ctx: ctx}
  end

  # Binding endpoints whose token URL points at Bypass. Entries stored with
  # these have Bypass as their *stored* binding, so a re-auth against the
  # same endpoints exercises the same-binding (CAS) path for real. Endpoint
  # https validation happens when an entry is created and at authorize
  # time, on operator input; storage holds what was bound.
  defp bypass_endpoints(bypass) do
    %{
      "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
      "token_url" => "http://localhost:#{bypass.port}/token",
      "auth_style" => "params"
    }
  end

  # An oauth entry as the store holds one, its endpoints whatever the test
  # binds: a create would refuse Bypass's plain-http token URL.
  defp stored_entry!(ctx, name, endpoints, fields \\ %{}, oauth \\ %{"access_token" => "at-0"}) do
    id = Prima.UUID7.generate_id("vlt")
    aad = CipherAAD.vault_entry(ctx.athanor_id, id, @provider)
    {:ok, json} = Payload.encode_material(fields, oauth)
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    binding = %{
      provider_hint: @provider,
      field_names: Jason.encode!(Enum.sort(Map.keys(fields))),
      oauth_endpoints: Jason.encode!(endpoints),
      oauth_scopes: Jason.encode!(@scopes),
      destination: @destination_text,
      attach_only: false
    }

    {:ok, digest} = Sanctum.VaultReader.binding_digest(binding)

    {:ok, entry} =
      Arca.VaultStorage.put(
        Sanctum.Context.actor(ctx),
        Map.merge(binding, %{
          id: id,
          name: name,
          kind: "oauth",
          status: "active",
          sealed_payload: sealed,
          binding_digest: digest
        })
      )

    entry
  end

  # The pending record a passed authorize_url/2 would have minted. The
  # pending is server-minted state, so fabricating it here exercises the
  # full fetch → validate → exchange → apply path without weakening the
  # https validation that guards operator input.
  defp mint_pending!(ctx, target) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    # The pending record carries the actor the interactive check passed
    # for; the callback has no context of its own and acts with that
    # authority and no other.
    pending = %{
      target: target,
      redirect_uri: CyfrWeb.Endpoint.url() <> "/auth/oauth/callback",
      code_verifier: "verifier-1",
      actor: Sanctum.Context.actor(ctx)
    }

    Arca.Cache.put({:vault_oauth_pending, state}, pending, 120_000)
    {state, pending}
  end

  defp new_target(name, bypass) do
    %{
      kind: :new,
      entry_id: nil,
      name: name,
      provider: @provider,
      endpoints: bypass_endpoints(bypass),
      scopes: @scopes,
      destination: @destination_text,
      attach_only: false
    }
  end

  defp existing_target(entry, bypass, scopes) do
    %{
      kind: :existing,
      entry_id: entry.id,
      name: entry.name,
      provider: @provider,
      endpoints: bypass_endpoints(bypass),
      scopes: scopes
    }
  end

  defp stub_token_endpoint(bypass, response) do
    test = self()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:token_request, URI.decode_query(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(response))
    end)
  end

  defp unseal!(entry_id, athanor_id) do
    {:ok, entry} = Arca.VaultStorage.get(%Prima.Actor{athanor_id: athanor_id}, entry_id)
    aad = CipherAAD.vault_entry(athanor_id, entry.id, entry.provider_hint)
    {:ok, plaintext} = Sanctum.Cipher.decrypt(entry.sealed_payload, aad)
    {:ok, payload} = Payload.decode(plaintext)
    {entry, payload}
  end

  describe "authorize_url/2" do
    test "builds a preset-provider URL with PKCE and stores the pending", %{ctx: ctx} do
      assert {:ok, %{url: url, state: state}} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 destination: @destination,
                 name: "My Google",
                 provider: @provider,
                 scopes: @scopes
               })

      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")
      query = URI.decode_query(URI.parse(url).query)
      assert query["client_id"] == "client-id-1"
      assert query["code_challenge_method"] == "S256"
      assert query["scope"] == Enum.join(@scopes, " ")
      assert query["access_type"] == "offline"
      assert query["state"] == state

      assert {:ok, pending} = Arca.Cache.get({:vault_oauth_pending, state})
      assert pending.target.kind == :new
      assert pending.target.name == "My Google"
      # The new entry will hold the preset's endpoints, and only those.
      assert pending.target.endpoints == Sanctum.Vault.OAuth.preset(@provider).endpoints
    end

    test "a preset provider naming endpoints of its own is refused", %{ctx: ctx} do
      assert {:error, :endpoints_preset_conflict} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 destination: @destination,
                 name: "Not Google",
                 provider: @provider,
                 scopes: @scopes,
                 endpoints: %{
                   "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
                   "token_url" => "https://attacker.example/token"
                 }
               })
    end

    test "a re-auth naming endpoints beside the entry is refused", %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G-fixed",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      for endpoints <- [
            %{
              "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
              "token_url" => "https://attacker.example/token"
            },
            %{}
          ] do
        assert {:error, :endpoints_immutable} =
                 Sanctum.TestContext.authorize_vault(ctx, %{
                   entry_id: view.id,
                   endpoints: endpoints
                 })
      end
    end

    test "a wire re-authorization naming endpoints is refused, not stripped of them",
         %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G-wire",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      for endpoints <- [
            %{
              "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
              "token_url" => "https://attacker.example/token"
            },
            %{}
          ] do
        call = %{"action" => "authorize", "id" => view.id, "oauth_endpoints" => endpoints}

        # Confirmed or not, the request's own shape refuses it: no grant is
        # started against the entry with the endpoints silently dropped.
        assert {:error, "endpoints_immutable: " <> _} =
                 Sanctum.TestContext.confirming(ctx, &Sanctum.Providers.Vault.handle(&1, call))
      end
    end

    test "a re-authorization asks for the scopes it names, so scopes change only by a grant",
         %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G-scopes",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      wider = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]

      assert {:ok, %{url: url, state: state}} =
               Sanctum.TestContext.authorize_vault(ctx, %{entry_id: view.id, scopes: wider})

      assert URI.decode_query(URI.parse(url).query)["scope"] == Enum.join(wider, " ")
      assert {:ok, pending} = Arca.Cache.get({:vault_oauth_pending, state})
      assert pending.target.scopes == wider
      assert pending.target.endpoints == Sanctum.Vault.OAuth.preset(@provider).endpoints

      # The wire's re-authorization carries them the same way.
      call = %{"action" => "authorize", "id" => view.id, "oauth_scopes" => wider}

      assert {:ok, %{url: wire_url}} =
               Sanctum.TestContext.confirming(ctx, &Sanctum.Providers.Vault.handle(&1, call))

      assert URI.decode_query(URI.parse(wire_url).query)["scope"] == Enum.join(wider, " ")

      # Until the grant completes, the entry is bound as it was.
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      assert Jason.decode!(entry.oauth_scopes) == @scopes
    end

    test "a re-authorization naming no scopes is refused, on the grant and on the wire",
         %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G-noscopes",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      assert {:error, :scopes_required} =
               Sanctum.TestContext.authorize_vault(ctx, %{entry_id: view.id, scopes: []})

      call = %{"action" => "authorize", "id" => view.id, "oauth_scopes" => []}

      assert {:error, "scopes_required: " <> _} =
               Sanctum.TestContext.confirming(ctx, &Sanctum.Providers.Vault.handle(&1, call))

      # No grant is pending that would rebind the entry to no scopes.
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      assert Jason.decode!(entry.oauth_scopes) == @scopes
    end

    test "a re-authorization naming an empty scope is refused, on the grant and on the wire",
         %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G-blankscope",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      for scopes <- [[""], ["  "], @scopes ++ [""]] do
        assert {:error, :scopes_required} =
                 Sanctum.TestContext.authorize_vault(ctx, %{entry_id: view.id, scopes: scopes})

        call = %{"action" => "authorize", "id" => view.id, "oauth_scopes" => scopes}

        assert {:error, "scopes_required: " <> _} =
                 Sanctum.TestContext.confirming(ctx, &Sanctum.Providers.Vault.handle(&1, call))
      end

      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      assert Jason.decode!(entry.oauth_scopes) == @scopes
    end

    test "a re-auth uses the entry's stored endpoints exactly, with no preset merged", %{ctx: ctx} do
      # A google entry whose stored endpoints carry none of the preset's
      # extra parameters: the authorization asks with what is stored.
      stored = %{
        "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url" => "https://oauth2.googleapis.com/token"
      }

      entry = stored_entry!(ctx, "G-stored", stored)

      assert {:ok, %{url: url, state: state}} =
               Sanctum.TestContext.authorize_vault(ctx, %{entry_id: entry.id})

      query = URI.decode_query(URI.parse(url).query)
      refute Map.has_key?(query, "access_type")
      refute Map.has_key?(query, "prompt")

      assert {:ok, pending} = Arca.Cache.get({:vault_oauth_pending, state})
      assert pending.target.endpoints == stored
    end

    test "requires the interactive class", %{ctx: ctx} do
      key_ctx = %{ctx | auth_method: :api_key}

      assert {:error, _} =
               OAuthGrant.authorize_url(key_ctx, %{
                 name: "Nope",
                 provider: @provider,
                 scopes: @scopes
               })
    end

    test "an unknown provider without endpoints is refused", %{ctx: ctx} do
      :ok = Sanctum.TestContext.put_provider_credentials(ctx, "acme", "cid", "cs")

      assert {:error, :endpoints_required} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 destination: @destination,
                 name: "Acme",
                 provider: "acme",
                 scopes: []
               })
    end

    test "plaintext endpoints are refused", %{ctx: ctx} do
      :ok = Sanctum.TestContext.put_provider_credentials(ctx, "acme", "cid", "cs")

      assert {:error, :endpoints_must_use_https} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 destination: @destination,
                 name: "Acme",
                 provider: "acme",
                 scopes: [],
                 endpoints: %{
                   "authorize_url" => "http://acme.example/auth",
                   "token_url" => "http://acme.example/token"
                 }
               })
    end

    test "extra_params may not steer the flow's security parameters", %{ctx: ctx} do
      :ok = Sanctum.TestContext.put_provider_credentials(ctx, "acme", "cid", "cs")

      # Each of these, if honoured, breaks the callback's own checks:
      # "plain" downgrades PKCE, and a caller-chosen state or redirect_uri
      # substitutes the values `complete/3` compares against.
      for reserved <- ~w(code_challenge_method state redirect_uri client_id scope) do
        assert {:error, {:reserved_extra_param, ^reserved}} =
                 Sanctum.TestContext.authorize_vault(ctx, %{
                   destination: @destination,
                   name: "Acme",
                   provider: "acme",
                   scopes: ["read"],
                   endpoints: %{
                     "authorize_url" => "https://acme.example/auth",
                     "token_url" => "https://acme.example/token",
                     "extra_params" => %{reserved => "attacker-chosen"}
                   }
                 })
      end
    end

    test "a legitimate extra_param still rides along", %{ctx: ctx} do
      :ok = Sanctum.TestContext.put_provider_credentials(ctx, "acme", "cid", "cs")

      assert {:ok, %{url: url, state: state}} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 destination: @destination,
                 name: "Acme",
                 provider: "acme",
                 scopes: ["read"],
                 endpoints: %{
                   "authorize_url" => "https://acme.example/auth",
                   "token_url" => "https://acme.example/token",
                   "extra_params" => %{"prompt" => "consent", "audience" => "acme-api"}
                 }
               })

      query = URI.decode_query(URI.parse(url).query)
      assert query["prompt"] == "consent"
      assert query["audience"] == "acme-api"
      # The server's own parameters are untouched by the merge.
      assert query["state"] == state
      assert query["code_challenge_method"] == "S256"
      assert query["client_id"] == "cid"
    end

    test "an unconfigured provider names oauth.set_client", %{ctx: ctx} do
      assert {:error, message} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 destination: @destination,
                 name: "Slack",
                 provider: "slack",
                 scopes: [],
                 endpoints: %{
                   "authorize_url" => "https://slack.example/auth",
                   "token_url" => "https://slack.example/token"
                 }
               })

      assert message =~ "oauth.set_client"
    end

    test "re-auth target comes from the entry's own binding fields", %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      assert {:ok, %{url: url}} = Sanctum.TestContext.authorize_vault(ctx, %{entry_id: view.id})
      assert String.starts_with?(url, "https://accounts.google.com/o/oauth2/v2/auth?")
      query = URI.decode_query(URI.parse(url).query)
      assert query["scope"] == Enum.join(@scopes, " ")
      assert query["access_type"] == "offline"
    end

    test "a non-oauth entry cannot be authorized", %{ctx: ctx} do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "K",
          kind: "api_key",
          fields: %{"key" => "v"}
        })

      assert {:error, {:not_an_oauth_entry, "api_key"}} =
               Sanctum.TestContext.authorize_vault(ctx, %{entry_id: view.id})
    end
  end

  describe "complete/3 — new entry" do
    test "mints an active oauth entry holding the bundle", %{ctx: ctx} do
      bypass = Bypass.open()

      stub_token_endpoint(bypass, %{
        "access_token" => "at-1",
        "refresh_token" => "rt-1",
        "expires_in" => 3600,
        "token_type" => "Bearer"
      })

      {state, pending} = mint_pending!(ctx, new_target("My Google", bypass))

      assert {:ok, result} = OAuthGrant.complete(state, "code-1", pending.redirect_uri)
      assert result.provider == @provider
      refute result.rebound

      # The exchange carried PKCE + the authorization code.
      assert_receive {:token_request, params}
      assert params["grant_type"] == "authorization_code"
      assert params["code"] == "code-1"
      assert params["code_verifier"] == "verifier-1"
      assert params["client_id"] == "client-id-1"

      {entry, payload} = unseal!(result.entry_id, ctx.athanor_id)
      assert entry.status == "active"
      assert entry.kind == "oauth"
      assert entry.provider_hint == @provider
      assert entry.binding_digest != nil
      assert payload["v"] == 3
      assert payload["oauth"]["access_token"] == "at-1"
      assert payload["oauth"]["refresh_token"] == "rt-1"
      assert payload["oauth"]["scopes"] == @scopes

      # The destination and the disclosure the grant was started with are
      # the new entry's, and its binding digest covers them.
      assert entry.destination == @destination_text
      assert entry.attach_only == false
      assert {:ok, entry.binding_digest} == VaultReader.binding_digest(entry)
    end

    test "authorize carries the destination into the new entry, attach-only unless it discloses",
         %{ctx: ctx} do
      assert {:ok, %{state: state}} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 name: "Attached Google",
                 provider: @provider,
                 scopes: @scopes,
                 destination: %{"hosts" => ["GMAIL.googleapis.com"], "paths" => ["/gmail/v1/"]}
               })

      assert {:ok, %{target: target}} = Arca.Cache.get({:vault_oauth_pending, state})

      assert target.destination ==
               ~s({"hosts":["gmail.googleapis.com"],"paths":["/gmail/v1/"],"scheme":"https"})

      assert target.attach_only == true

      assert {:ok, %{state: disclosed}} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 name: "Disclosed Google",
                 provider: @provider,
                 scopes: @scopes,
                 destination: @destination,
                 disclose: true
               })

      assert {:ok, %{target: %{attach_only: false}}} =
               Arca.Cache.get({:vault_oauth_pending, disclosed})
    end

    test "a new entry's grant without a destination, or with one off the grammar, is refused",
         %{ctx: ctx} do
      assert {:error, :destination_required} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 name: "Nowhere",
                 provider: @provider,
                 scopes: @scopes
               })

      assert {:error, {:invalid_destination, _}} =
               Sanctum.TestContext.authorize_vault(ctx, %{
                 name: "Nowhere",
                 provider: @provider,
                 scopes: @scopes,
                 destination: %{"hosts" => ["*"]}
               })

      # A re-authorization moves no destination: the wire refuses one beside an id.
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          destination: @destination,
          disclose: true,
          name: "G-reauth",
          kind: "oauth",
          provider_hint: @provider,
          oauth_scopes: @scopes
        })

      assert {:error, {:invalid_argument, message}} =
               Sanctum.Providers.Vault.handle(ctx, %{
                 "action" => "authorize",
                 "id" => view.id,
                 "destination" => %{"hosts" => ["elsewhere.example"]}
               })

      assert message =~ "rebind"
    end

    test "an unknown state is distinguishable for legacy fall-through" do
      assert {:error, :unknown_state} = OAuthGrant.complete("no-such-state", "c", "r")
    end

    test "the state is single-use", %{ctx: ctx} do
      bypass = Bypass.open()
      stub_token_endpoint(bypass, %{"access_token" => "at", "token_type" => "bearer"})
      {state, pending} = mint_pending!(ctx, new_target("Once", bypass))

      assert {:ok, _} = OAuthGrant.complete(state, "code", pending.redirect_uri)
      assert {:error, :unknown_state} = OAuthGrant.complete(state, "code", pending.redirect_uri)
    end

    test "a redirect_uri mismatch is refused before any provider contact", %{ctx: ctx} do
      bypass = Bypass.open()
      {state, _pending} = mint_pending!(ctx, new_target("Strict", bypass))

      assert {:error, "redirect_uri mismatch"} =
               OAuthGrant.complete(state, "code", "https://evil.example/callback")
    end
  end

  describe "complete/3 — re-auth of an existing entry" do
    test "same binding replaces material under CAS and clears needs_reauth", %{ctx: ctx} do
      bypass = Bypass.open()
      view = stored_entry!(ctx, "G", bypass_endpoints(bypass), %{"note" => "kept"})

      :ok = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), view.id, "needs_reauth")
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      digest_before = entry.binding_digest

      stub_token_endpoint(bypass, %{"access_token" => "at-2", "refresh_token" => "rt-2"})
      {state, pending} = mint_pending!(ctx, existing_target(entry, bypass, @scopes))

      assert {:ok, result} = OAuthGrant.complete(state, "code-2", pending.redirect_uri)
      assert result.entry_id == view.id
      refute result.rebound

      {after_entry, payload} = unseal!(view.id, ctx.athanor_id)
      assert after_entry.status == "active"
      assert after_entry.payload_rev == entry.payload_rev + 1
      assert payload["fields"] == %{"note" => "kept"}
      assert payload["oauth"]["access_token"] == "at-2"
      assert after_entry.binding_digest == digest_before
    end

    test "changed scopes are a rebind: digest moves, bound profile flips", %{ctx: ctx} do
      bypass = Bypass.open()

      # Bind a profile to the entry through the real consent walk.
      wasm = File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: "grant-bound",
          version: "1.0.0",
          type: "reagent"
        })

      view = stored_entry!(ctx, "G2", bypass_endpoints(bypass))

      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "reagent:local.grant-bound"})

      decisions = %{
        ref: "reagent:local.grant-bound",
        bindings: [%{need: "@ingress", entry_id: view.id, scopes: @scopes}]
      }

      {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

      {:ok, _} =
        Sanctum.Consent.Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      digest_before = entry.binding_digest

      stub_token_endpoint(bypass, %{"access_token" => "at-3"})

      wider = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      {state, pending} = mint_pending!(ctx, existing_target(entry, bypass, wider))

      assert {:ok, %{rebound: true}} =
               OAuthGrant.complete(state, "code-3", pending.redirect_uri)

      {:ok, after_entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      assert after_entry.binding_digest != digest_before
      assert Jason.decode!(after_entry.oauth_scopes) |> Enum.sort() == Enum.sort(wider)

      {:ok, [profile]} =
        Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), "reagent:local.grant-bound")

      assert profile.status == :needs_consent
      # The scopes moved; the endpoints did not.
      assert after_entry.oauth_endpoints == entry.oauth_endpoints
    end

    test "a grant for other scopes rebinds them with its own bundle, which holds no narrower tokens",
         %{ctx: ctx} do
      bypass = Bypass.open()

      held = %{
        "access_token" => "at-0",
        "refresh_token" => "rt-0",
        "scopes" => @scopes,
        "tokens" => %{"x.narrow" => %{"access_token" => "at-narrow", "expires_at" => nil}}
      }

      view = stored_entry!(ctx, "G-regrant", bypass_endpoints(bypass), %{}, held)
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)

      stub_token_endpoint(bypass, %{
        "access_token" => "at-regrant",
        "refresh_token" => "rt-regrant"
      })

      wider = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      {state, pending} = mint_pending!(ctx, existing_target(entry, bypass, wider))

      assert {:ok, %{rebound: true}} = OAuthGrant.complete(state, "code-5", pending.redirect_uri)

      {after_entry, payload} = unseal!(view.id, ctx.athanor_id)
      assert Jason.decode!(after_entry.oauth_scopes) == wider
      assert after_entry.binding_digest != entry.binding_digest
      assert payload["oauth"]["access_token"] == "at-regrant"
      assert payload["oauth"]["scopes"] == wider
      refute Map.has_key?(payload["oauth"], "tokens")
    end

    test "a target whose endpoints are no longer the entry's is refused and writes nothing",
         %{ctx: ctx} do
      bypass = Bypass.open()
      view = stored_entry!(ctx, "G3", bypass_endpoints(bypass), %{"note" => "kept"})
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)

      # The grant was started against endpoints the entry does not hold:
      # the code is exchanged at the token endpoint the grant was started
      # with, and then nothing is written.
      stub_token_endpoint(bypass, %{"access_token" => "at-moved", "refresh_token" => "rt-moved"})

      moved = %{
        existing_target(entry, bypass, @scopes)
        | endpoints:
            Map.put(
              bypass_endpoints(bypass),
              "authorize_url",
              "https://idp.elsewhere.example/auth"
            )
      }

      {state, pending} = mint_pending!(ctx, moved)

      assert {:error, :endpoints_immutable} =
               OAuthGrant.complete(state, "code-4", pending.redirect_uri)

      {after_entry, payload} = unseal!(view.id, ctx.athanor_id)
      assert after_entry.payload_rev == entry.payload_rev
      assert after_entry.sealed_payload == entry.sealed_payload
      assert after_entry.binding_digest == entry.binding_digest
      assert after_entry.oauth_endpoints == entry.oauth_endpoints
      assert payload["oauth"]["access_token"] == "at-0"
    end
  end

  # ---------------------------------------------------------------------------
  # A dispense fenced on the binding it was validated at
  # ---------------------------------------------------------------------------

  # A provider no shipped preset is (`:sanctum, :scripted_oauth_provider`),
  # shown to attenuate a refresh. Its token endpoint answers what the test
  # scripts, in order, telling the test each request; an answer scripted as
  # `{before, answer}` runs `before` first, so a write can land while a
  # refresh is at the provider.
  defmodule RaceIdp do
    @moduledoc false

    @hint "race-idp"
    @endpoints %{
      "authorize_url" => "https://idp.race.test/authorize",
      "token_url" => "https://idp.race.test/token"
    }

    def hint, do: @hint
    def endpoints, do: @endpoints

    def preset(@hint), do: %{endpoints: @endpoints, attenuates_scope: true}
    def preset(_hint), do: nil

    def post(_url, _headers, body) do
      {test, next} =
        Agent.get_and_update(__MODULE__, fn
          {test, [next | rest]} -> {{test, next}, {test, rest}}
          {test, []} -> {{test, :unscripted}, {test, []}}
        end)

      send(test, {:token_request, URI.decode_query(body)})

      case next do
        :unscripted ->
          {:error, "unscripted request"}

        {before, answer} when is_function(before, 0) ->
          before.()
          answer

        answer ->
          answer
      end
    end
  end

  describe "a dispense is fenced on the binding it was validated at" do
    @a "race.a"
    @b "race.b"
    @c "race.c"
    @expired "2020-01-01T00:00:00Z"

    setup %{ctx: ctx} do
      prior = Application.fetch_env(:sanctum, :scripted_oauth_provider)
      Application.put_env(:sanctum, :scripted_oauth_provider, RaceIdp)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:sanctum, :scripted_oauth_provider, value)
          :error -> Application.delete_env(:sanctum, :scripted_oauth_provider)
        end
      end)

      :ok =
        Sanctum.TestContext.put_provider_credentials(ctx, RaceIdp.hint(), "race-cid", "race-cs")

      :ok
    end

    test "a waiting dispense is never handed the token of a widening re-authorization",
         %{ctx: ctx} do
      # The reviewer's race: a dispense validated at the old binding waits on
      # the entry's refresh lock while a re-authorization for wider scopes
      # commits; the token it brings is the new binding's alone.
      bypass = Bypass.open()
      narrow = @scopes
      wide = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]

      entry =
        put_entry!(ctx, @provider, bypass_endpoints(bypass), narrow, %{
          "access_token" => "at-narrow",
          "refresh_token" => "rt-1",
          "expires_at" => @expired,
          "scopes" => narrow
        })

      lock = hold_refresh_lock!(ctx, entry)

      dispense =
        Task.async(fn ->
          VaultReader.oauth_token(ctx, edge(entry, narrow), @provider, @dispense)
        end)

      await_waiting!(lock)

      stub_token_endpoint(bypass, %{
        "access_token" => "at-wide",
        "refresh_token" => "rt-2",
        "expires_in" => 3600
      })

      {state, pending} = mint_pending!(ctx, existing_target(entry, bypass, wide))
      assert {:ok, %{rebound: true}} = OAuthGrant.complete(state, "code", pending.redirect_uri)
      assert row!(ctx, entry).binding_digest != entry.binding_digest

      release!(lock)
      assert {:error, :binding_mismatch} = Task.await(dispense, 30_000)
    end

    test "a dispense that leads the refresh after the binding moved refreshes nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))
      script!([{:ok, %{"access_token" => "at-refreshed", "expires_in" => 3600}}])

      lock = hold_refresh_lock!(ctx, entry)

      dispense =
        Task.async(fn ->
          VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)
        end)

      await_waiting!(lock)

      # The re-authorization's token has expired too, so no recheck finds a
      # fresh one: the dispense leads the next refresh, at the new binding.
      regrant!(ctx, entry, [@a, @b], expired_bundle("at-wide", "rt-2"))

      release!(lock)
      assert {:error, :binding_mismatch} = Task.await(dispense, 30_000)
      refute_received {:token_request, _}
    end

    test "a narrower dispense waiting on the lock is never handed the new binding's held token",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a, @b], live_bundle("at-wide", "rt-1"))
      script!([])

      lock = hold_refresh_lock!(ctx, entry)

      dispense =
        Task.async(fn ->
          VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)
        end)

      await_waiting!(lock)

      regrant!(
        ctx,
        entry,
        [@a, @b, @c],
        Map.put(live_bundle("at-wider", "rt-2"), "tokens", %{
          @a => %{"access_token" => "at-a-new", "expires_at" => nil}
        })
      )

      release!(lock)
      assert {:error, :binding_mismatch} = Task.await(dispense, 30_000)
      refute_received {:token_request, _}
    end

    test "a narrower dispense that leads the refresh after the binding moved refreshes nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a, @b], live_bundle("at-wide", "rt-1"))
      script!([{:ok, %{"access_token" => "at-a-refreshed", "scope" => @a, "expires_in" => 3600}}])

      lock = hold_refresh_lock!(ctx, entry)

      dispense =
        Task.async(fn ->
          VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)
        end)

      await_waiting!(lock)

      regrant!(ctx, entry, [@a, @b, @c], live_bundle("at-wider", "rt-2"))

      release!(lock)
      assert {:error, :binding_mismatch} = Task.await(dispense, 30_000)
      refute_received {:token_request, _}
    end

    test "a refresh whose write loses to a re-authorization answers nothing of the new bundle",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      # While the refresh is at the provider, the person re-authorizes for
      # wider scopes: the refresh's write loses its compare-and-set to a
      # bundle of another token family, under another binding.
      script!([
        {fn -> regrant!(ctx, entry, [@a, @b], live_bundle("at-wide", "rt-2")) end,
         {:ok, %{"access_token" => "at-refreshed", "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert_received {:token_request, %{"refresh_token" => "rt-1"}}
      assert %{"access_token" => "at-wide", "refresh_token" => "rt-2"} = bundle!(ctx, entry)
    end

    test "a refresh whose write loses to a rebind of the same token family answers nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      # The concurrent write keeps the refresh token this refresh presented
      # and moves the binding: what the refresh obtained is not folded in
      # under the binding that now stands, nor answered to the old one.
      script!([
        {fn -> rebind_fields!(ctx, entry, ["note"]) end,
         {:ok, %{"access_token" => "at-refreshed", "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert %{"access_token" => "at-old", "refresh_token" => "rt-1"} = bundle!(ctx, entry)
    end

    test "a narrower refresh whose write loses to a re-authorization answers nothing of it",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a, @b], live_bundle("at-wide", "rt-1"))

      script!([
        {fn ->
           regrant!(
             ctx,
             entry,
             [@a, @b, @c],
             Map.put(live_bundle("at-wider", "rt-2"), "tokens", %{
               @a => %{"access_token" => "at-a-new", "expires_at" => nil}
             })
           )
         end, {:ok, %{"access_token" => "at-a-refreshed", "scope" => @a, "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert_received {:token_request, %{"scope" => @a}}
    end

    test "a refresh whose provider call is in flight when the entry is deleted writes nothing back",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      # While the refresh is at the provider, the owner deletes the entry:
      # its material is erased, and the refresh's write-back must not seal
      # the provider's answer into it again.
      script!([
        {fn -> :ok = Arca.VaultStorage.tombstone(Sanctum.Context.actor(ctx), entry.id) end,
         {:ok,
          %{"access_token" => "at-refreshed", "refresh_token" => "rt-2", "expires_in" => 3600}}}
      ])

      result = VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert_received {:token_request, %{"refresh_token" => "rt-1"}}
      refute match?({:ok, _}, result)
      assert {:error, {:entry_unavailable, "tombstoned"}} = result

      row = row!(ctx, entry)
      assert row.status == "tombstoned"
      assert row.sealed_payload == nil
    end

    test "a refresh refused for a moved binding keeps the refresh token the provider rotated",
         %{ctx: ctx} do
      # The third review's case: the field schema is rebound and the
      # bundle kept while the refresh is at the provider, which rotates the
      # refresh token. Nothing is answered under the moved binding, but the
      # entry is not left on the token the provider retired.
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      script!([
        {fn -> rebind_fields!(ctx, entry, ["note"]) end,
         {:ok,
          %{"access_token" => "at-refreshed", "refresh_token" => "rt-2", "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert_received {:token_request, %{"refresh_token" => "rt-1"}}
      assert Jason.decode!(row!(ctx, entry).oauth_scopes) == [@a]
      kept = bundle!(ctx, entry)
      assert kept["refresh_token"] == "rt-2"
      # Only the refresh token: the refused refresh's access token is not.
      assert kept["access_token"] == "at-old"
      refute Map.has_key?(kept, "tokens")
    end

    test "a narrower refresh refused for a moved binding keeps the rotated token and holds nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a, @b], live_bundle("at-wide", "rt-1"))

      script!([
        {fn -> rebind_fields!(ctx, entry, ["note"]) end,
         {:ok,
          %{
            "access_token" => "at-a-refreshed",
            "scope" => @a,
            "refresh_token" => "rt-2",
            "expires_in" => 3600
          }}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      kept = bundle!(ctx, entry)
      assert kept["refresh_token"] == "rt-2"
      assert kept["access_token"] == "at-wide"
      refute Map.has_key?(kept, "tokens")
    end

    test "a re-authorization's own refresh token is never replaced by a refused refresh's rotation",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      script!([
        {fn -> regrant!(ctx, entry, [@a, @b], live_bundle("at-wide", "rt-2")) end,
         {:ok,
          %{"access_token" => "at-refreshed", "refresh_token" => "rt-1b", "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert %{"access_token" => "at-wide", "refresh_token" => "rt-2"} = bundle!(ctx, entry)
    end

    test "a dispense waiting on the lock while the entry is revoked refreshes and answers nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))
      script!([{:ok, %{"access_token" => "at-refreshed", "expires_in" => 3600}}])

      lock = hold_refresh_lock!(ctx, entry)

      dispense =
        Task.async(fn ->
          VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)
        end)

      await_waiting!(lock)
      :ok = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry.id, "revoked")

      release!(lock)
      assert {:error, {:entry_unavailable, "revoked"}} = Task.await(dispense, 30_000)
      refute_received {:token_request, _}
    end

    test "a refresh whose binding moves without a payload write answers nothing",
         %{ctx: ctx} do
      # A rebind of the field schema writes no payload, so the refresh's own
      # write wins its compare-and-set; the row after the write is checked
      # against the binding the dispense was validated at.
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))
      test = self()

      script!([
        {fn ->
           send(
             test,
             {:rebind, Sanctum.Vault.rebind(ctx, %{id: entry.id, field_names: ["note"]})}
           )
         end, {:ok, %{"access_token" => "at-refreshed", "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert_received {:rebind, {:ok, _}}
      moved = row!(ctx, entry)
      assert moved.binding_digest != entry.binding_digest
      # The refreshed bundle is stored, the same token family, for the
      # binding that now stands to answer under its own consent.
      assert bundle!(ctx, entry)["access_token"] == "at-refreshed"
    end

    test "a narrower refresh whose binding moves without a payload write answers nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a, @b], live_bundle("at-wide", "rt-1"))
      test = self()

      script!([
        {fn ->
           send(
             test,
             {:rebind, Sanctum.Vault.rebind(ctx, %{id: entry.id, field_names: ["note"]})}
           )
         end, {:ok, %{"access_token" => "at-a-refreshed", "scope" => @a, "expires_in" => 3600}}}
      ])

      assert {:error, :binding_mismatch} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)

      assert_received {:rebind, {:ok, _}}
    end

    test "a refresh whose entry is revoked while it is at the provider answers nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      script!([
        {fn ->
           :ok = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry.id, "revoked")
         end, {:ok, %{"access_token" => "at-refreshed", "expires_in" => 3600}}}
      ])

      assert {:error, {:entry_unavailable, "revoked"}} =
               VaultReader.oauth_token(ctx, edge(entry, [@a]), RaceIdp.hint(), @dispense)
    end
  end

  # An entry as the store holds one, at the digest its binding derives.
  defp put_entry!(ctx, hint, endpoints, scopes, bundle) do
    id = Prima.UUID7.generate_id("vlt")
    aad = CipherAAD.vault_entry(ctx.athanor_id, id, hint)
    {:ok, json} = Payload.encode_material(%{}, bundle)
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    binding = %{
      provider_hint: hint,
      field_names: "[]",
      oauth_endpoints: Jason.encode!(endpoints),
      oauth_scopes: Jason.encode!(scopes),
      destination: @destination_text,
      attach_only: false
    }

    {:ok, digest} = Sanctum.VaultReader.binding_digest(binding)

    {:ok, entry} =
      Arca.VaultStorage.put(
        Sanctum.Context.actor(ctx),
        Map.merge(binding, %{
          id: id,
          name: "race-#{System.unique_integer([:positive])}",
          kind: "oauth",
          status: "active",
          sealed_payload: sealed,
          binding_digest: digest
        })
      )

    entry
  end

  defp race_entry!(ctx, scopes, bundle),
    do: put_entry!(ctx, RaceIdp.hint(), RaceIdp.endpoints(), scopes, bundle)

  defp live_bundle(token, refresh),
    do: %{"access_token" => token, "refresh_token" => refresh, "expires_at" => nil}

  defp expired_bundle(token, refresh),
    do: %{"access_token" => token, "refresh_token" => refresh, "expires_at" => @expired}

  # The consent edge as it stands: the projection, at the entry's digest.
  defp edge(entry, scopes),
    do: %{
      entry_id: entry.id,
      binding_digest: entry.binding_digest,
      projection: %{fields: [], scopes: scopes}
    }

  defp script!(answers) do
    test = self()

    start_supervised!(%{
      id: RaceIdp,
      start: {Agent, :start_link, [fn -> {test, answers} end, [name: RaceIdp]]}
    })

    :ok
  end

  # A refresh of the entry in flight: something leads its lock until
  # released.
  defp hold_refresh_lock!(ctx, entry) do
    key = {:vault_oauth_refresh, ctx.athanor_id, entry.id}
    test = self()

    leader =
      spawn(fn ->
        {:ok, _} = Registry.register(Sanctum.OAuth.RefreshRegistry, key, :leader)
        send(test, {:leading, self()})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:leading, ^leader}
    leader
  end

  defp release!(leader), do: send(leader, :release)

  # The dispense passed its binding check and waits on the lock's holder.
  defp await_waiting!(leader, tries \\ 500) do
    cond do
      match?({:monitored_by, [_ | _]}, Process.info(leader, :monitored_by)) -> :ok
      tries == 0 -> flunk("no dispense came to wait on the lock")
      true -> Process.sleep(10) && await_waiting!(leader, tries - 1)
    end
  end

  # What a re-authorization commits: a newly granted bundle and the scopes
  # it was granted for, moving the binding, in one write.
  defp regrant!(ctx, entry, scopes, bundle),
    do: commit!(ctx, entry, bundle, %{oauth_scopes: Jason.encode!(scopes)})

  # A rebind of the field schema beside a rotate that keeps the bundle.
  defp rebind_fields!(ctx, entry, fields) do
    row = row!(ctx, entry)
    commit!(ctx, entry, bundle!(ctx, entry), %{field_names: Jason.encode!(fields)}, row)
  end

  defp commit!(ctx, entry, bundle, changes, row \\ nil) do
    row = row || row!(ctx, entry)
    aad = CipherAAD.vault_entry(ctx.athanor_id, entry.id, row.provider_hint)
    {:ok, json} = Payload.encode_material(%{}, bundle)
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)
    {:ok, digest} = Sanctum.VaultReader.binding_digest(Map.merge(row, changes))

    {:ok, _} =
      Arca.VaultStorage.commit_payload(Sanctum.Context.actor(ctx), entry.id, %{
        expected_rev: row.payload_rev,
        sealed_payload: sealed,
        status: nil,
        rebind: %{
          from_digest: row.binding_digest,
          changes: Map.put(changes, :binding_digest, digest),
          blocked_status: Sanctum.Vault.blocked_profile_status()
        }
      })

    :ok
  end

  defp row!(ctx, entry) do
    {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry.id)
    row
  end

  defp bundle!(ctx, entry) do
    {_row, payload} = unseal!(entry.id, ctx.athanor_id)
    payload["oauth"]
  end
end
