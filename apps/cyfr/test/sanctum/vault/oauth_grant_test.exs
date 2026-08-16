# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthGrantTest do
  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.Vault
  alias Sanctum.Vault.OAuthGrant
  alias Sanctum.Vault.Payload

  @provider "google"
  @scopes ["https://www.googleapis.com/auth/gmail.readonly"]

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "oauth_grant_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.DB)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_source,
        do: Application.put_env(:cyfr, :consent_source, original_source),
        else: Application.delete_env(:cyfr, :consent_source)
    end)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.ProviderCredentials.put(ctx, @provider, "client-id-1", "client-secret-1")

    {:ok, ctx: ctx}
  end

  # Binding endpoints whose token URL points at Bypass. Entries created with
  # these have Bypass as their *stored* binding, so a re-auth against the
  # same endpoints exercises the same-binding (CAS) path for real. Endpoint
  # https validation happens at authorize time on operator input; storage
  # accepts what the operator bound.
  defp bypass_endpoints(bypass) do
    %{
      "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
      "token_url" => "http://localhost:#{bypass.port}/token",
      "auth_style" => "params"
    }
  end

  # The pending record a passed authorize_url/2 would have minted. The
  # pending is server-minted state, so fabricating it here exercises the
  # full fetch → validate → exchange → apply path without weakening the
  # https validation that guards operator input.
  defp mint_pending!(ctx, target) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    pending = %{
      target: target,
      redirect_uri: EmissaryWeb.Endpoint.url() <> "/auth/oauth/callback",
      code_verifier: "verifier-1",
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id
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
      scopes: @scopes
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
    {:ok, entry} = Arca.VaultStorage.get(athanor_id, entry_id)
    aad = CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)
    {:ok, plaintext} = Sanctum.Cipher.decrypt(entry.sealed_payload, aad)
    {:ok, payload} = Payload.decode(plaintext)
    {entry, payload}
  end

  describe "authorize_url/2" do
    test "builds a preset-provider URL with PKCE and stores the pending", %{ctx: ctx} do
      assert {:ok, %{url: url, state: state}} =
               OAuthGrant.authorize_url(ctx, %{
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
      :ok = Sanctum.ProviderCredentials.put(ctx, "acme", "cid", "cs")

      assert {:error, :endpoints_required} =
               OAuthGrant.authorize_url(ctx, %{name: "Acme", provider: "acme", scopes: []})
    end

    test "plaintext endpoints are refused", %{ctx: ctx} do
      :ok = Sanctum.ProviderCredentials.put(ctx, "acme", "cid", "cs")

      assert {:error, :endpoints_must_use_https} =
               OAuthGrant.authorize_url(ctx, %{
                 name: "Acme",
                 provider: "acme",
                 scopes: [],
                 endpoints: %{
                   "authorize_url" => "http://acme.example/auth",
                   "token_url" => "http://acme.example/token"
                 }
               })
    end

    test "an unconfigured provider names oauth.set_client", %{ctx: ctx} do
      assert {:error, message} =
               OAuthGrant.authorize_url(ctx, %{
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
        Vault.create(ctx, %{
          name: "G",
          kind: "oauth",
          provider_hint: @provider,
          oauth_endpoints: %{
            "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
            "token_url" => "https://oauth2.googleapis.com/token"
          },
          oauth_scopes: @scopes
        })

      assert {:ok, %{url: url}} = OAuthGrant.authorize_url(ctx, %{entry_id: view.id})
      query = URI.decode_query(URI.parse(url).query)
      assert query["scope"] == Enum.join(@scopes, " ")
    end

    test "a non-oauth entry cannot be authorized", %{ctx: ctx} do
      {:ok, view} = Vault.create(ctx, %{name: "K", kind: "api_key", fields: %{"key" => "v"}})

      assert {:error, {:not_an_oauth_entry, "api_key"}} =
               OAuthGrant.authorize_url(ctx, %{entry_id: view.id})
    end
  end

  describe "complete/3 — new connection" do
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
      assert payload["v"] == 2
      assert payload["oauth"]["access_token"] == "at-1"
      assert payload["oauth"]["refresh_token"] == "rt-1"
      assert payload["oauth"]["scopes"] == @scopes
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

      {:ok, view} =
        Vault.create(ctx, %{
          name: "G",
          kind: "oauth",
          provider_hint: @provider,
          fields: %{"note" => "kept"},
          oauth_endpoints: bypass_endpoints(bypass),
          oauth_scopes: @scopes
        })

      :ok = Arca.VaultStorage.set_status(ctx.athanor_id, view.id, "needs_reauth")
      {:ok, entry} = Arca.VaultStorage.get(ctx.athanor_id, view.id)
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

      {:ok, view} =
        Vault.create(ctx, %{
          name: "G2",
          kind: "oauth",
          provider_hint: @provider,
          oauth_endpoints: bypass_endpoints(bypass),
          oauth_scopes: @scopes
        })

      {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: "reagent:local.grant-bound"})

      decisions = %{
        ref: "reagent:local.grant-bound",
        bindings: [%{need: "@ingress", entry_id: view.id, fields: []}]
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

      {:ok, entry} = Arca.VaultStorage.get(ctx.athanor_id, view.id)
      digest_before = entry.binding_digest

      stub_token_endpoint(bypass, %{"access_token" => "at-3"})

      wider = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      {state, pending} = mint_pending!(ctx, existing_target(entry, bypass, wider))

      assert {:ok, %{rebound: true}} =
               OAuthGrant.complete(state, "code-3", pending.redirect_uri)

      {:ok, after_entry} = Arca.VaultStorage.get(ctx.athanor_id, view.id)
      assert after_entry.binding_digest != digest_before
      assert Jason.decode!(after_entry.oauth_scopes) |> Enum.sort() == Enum.sort(wider)

      {:ok, [profile]} = Sanctum.Consent.Source.DB.profiles(ctx, "reagent:local.grant-bound")
      assert profile.status == :needs_consent
    end
  end
end
