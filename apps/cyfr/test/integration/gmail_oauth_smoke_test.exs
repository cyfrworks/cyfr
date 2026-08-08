# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.GmailOAuthSmokeTest do
  @moduledoc """
  The operator arc for the one OAuth exemplar, end to end against a stub
  provider: mint a connection holding a token bundle, grant a profile
  binding it, dispense through the vault, refresh when it expires, and
  watch revocation bite.

  gmail is the OAuth exemplar: a needs manifest declaring an
  `oauth:google` role plus the egress it is allowed. The component itself
  arrives by registry pull in production; here the same manifest shape is
  published directly, since what is under test is the credential path,
  not ingestion.
  """

  use ExUnit.Case, async: false

  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Source
  alias Sanctum.Vault
  alias Sanctum.VaultReader

  @wasm File.read!(Path.join(__DIR__, "../support/test_wasm/math.wasm"))
  @provider "google"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "gmail_smoke_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)
    Application.put_env(:cyfr, :components_path, Path.join(test_path, "components"))

    original_source = Application.get_env(:cyfr, :consent_source)
    Application.put_env(:cyfr, :consent_source, Source.DB)

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

    # The gmail manifest's security-relevant shape: an oauth need plus
    # the egress it is allowed — the re-released bundle's vocabulary.
    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: "gmail",
        version: "0.2.0",
        type: "catalyst",
        manifest:
          Jason.encode!(%{
            "name" => "gmail",
            "version" => "0.2.0",
            "type" => "catalyst",
            "needs" => %{
              @provider => %{
                "type" => "oauth:google",
                "reason" => "to read your Gmail inbox",
                "required" => true,
                "scopes" => ["https://www.googleapis.com/auth/gmail.readonly"]
              }
            },
            "caps" => %{
              "egress" => %{
                "domains" => ["gmail.googleapis.com"],
                "methods" => ["GET"]
              }
            }
          })
      })

    {:ok, ctx: ctx}
  end

  defp mint_connection!(ctx, oauth, endpoints) do
    {:ok, view} =
      Vault.create(ctx, %{
        name: "my-gmail",
        kind: "oauth",
        provider_hint: @provider,
        fields: %{},
        oauth: oauth,
        oauth_endpoints: endpoints,
        oauth_scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
      })

    view
  end

  defp grant!(ctx, entry_id, scopes \\ []) do
    ref = "catalyst:local.gmail"
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})

    binding =
      %{need: @provider, entry_id: entry_id}
      |> then(fn b -> if scopes == [], do: b, else: Map.put(b, :scopes, scopes) end)

    decisions = %{ref: ref, bindings: [binding]}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    committed
  end

  defp edge_resource!(ctx, profile_id) do
    {:ok, consent} = Source.DB.head_consent(ctx, profile_id)
    {:ok, blob} = Sanctum.Authority.Blob.parse(consent.resolved_policy)
    {:ok, edge} = Sanctum.Authority.Blob.ingress(blob, "catalyst:local.gmail")
    edge.vault
  end

  test "the whole arc: connect, grant, dispense, revoke", %{ctx: ctx} do
    # A live token dispenses without touching the provider at all — the
    # refresh arm is the next test.
    entry =
      mint_connection!(
        ctx,
        %{"access_token" => "ya29.live", "refresh_token" => "1//rt", "token_type" => "Bearer"},
        %{"token_url" => "https://oauth2.googleapis.com/token", "auth_style" => "params"}
      )

    committed = grant!(ctx, entry.id)
    assert committed.revision == 1

    resource = edge_resource!(ctx, committed.profile_id)
    assert resource.entry_id == entry.id

    # Dispensing goes through the vault, not the legacy grant plane.
    assert {:ok, "ya29.live"} = VaultReader.oauth_token(ctx, resource, @provider)

    # A provider the consent does not name never leaves the reader.
    assert {:error, {:provider_mismatch, "github"}} =
             VaultReader.oauth_token(ctx, resource, "github")

    # Revocation bites at the next retrieval.
    {:ok, %{affected: affected}} = Vault.revoke(ctx, entry.id)
    assert committed.profile_id in affected

    assert {:error, {:entry_unavailable, "revoked"}} =
             VaultReader.oauth_token(ctx, resource, @provider)
  end

  test "the connection can arrive through the real grant flow", %{ctx: ctx} do
    # The operator arc end to end: provider client credentials stored,
    # a browser grant completed against the token endpoint, the minted
    # entry bound through the consent walk, and the token dispensed from
    # the vault path. The pending is fabricated exactly as vault.authorize
    # mints it (endpoint https validation happens there, on operator
    # input), with the token URL pointed at Bypass.
    :ok = Sanctum.ProviderCredentials.put(ctx, @provider, "smoke-cid", "smoke-cs")

    bypass = Bypass.open()

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "authorization_code"
      assert params["code_verifier"] == "smoke-verifier"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "access_token" => "ya29.granted",
          "refresh_token" => "1//rt2",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    redirect_uri = EmissaryWeb.Endpoint.url() <> "/auth/oauth/callback"

    pending = %{
      target: %{
        kind: :new,
        entry_id: nil,
        name: "my-gmail-granted",
        provider: @provider,
        endpoints: %{
          "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
          "token_url" => "http://localhost:#{bypass.port}/token",
          "auth_style" => "params"
        },
        scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
      },
      redirect_uri: redirect_uri,
      code_verifier: "smoke-verifier",
      org_id: ctx.org_id,
      project_id: ctx.project_id,
      user_id: ctx.user_id
    }

    Arca.Cache.put({:vault_oauth_pending, state}, pending, 120_000)

    {:ok, result} = Sanctum.Vault.OAuthGrant.complete(state, "smoke-code", redirect_uri)

    committed = grant!(ctx, result.entry_id)
    resource = edge_resource!(ctx, committed.profile_id)
    assert resource.entry_id == result.entry_id

    assert {:ok, "ya29.granted"} = VaultReader.oauth_token(ctx, resource, @provider)
  end

  test "a plaintext token endpoint is refused before any provider contact", %{ctx: ctx} do
    bypass = Bypass.open()
    parent = self()

    # Stubbed, not expected: the point is that it is never called.
    Bypass.stub(bypass, "POST", "/token", fn conn ->
      send(parent, :provider_called)
      Plug.Conn.resp(conn, 200, "{}")
    end)

    :ok = Sanctum.ProviderCredentials.put(ctx, @provider, "client-id", "client-secret")

    entry =
      mint_connection!(
        ctx,
        %{
          "access_token" => "ya29.stale",
          "refresh_token" => "1//rt",
          "expires_at" => "2020-01-01T00:00:00Z"
        },
        %{"token_url" => "http://127.0.0.1:#{bypass.port}/token"}
      )

    committed = grant!(ctx, entry.id)
    resource = edge_resource!(ctx, committed.profile_id)

    # The endpoint must be https, and the refusal comes before the socket
    # is ever opened — a refresh token is never sent in the clear.
    assert {:error, "token_url must use https://"} =
             VaultReader.oauth_token(ctx, resource, @provider)

    refute_receive :provider_called, 200
  end

  test "a scope projection narrower than the grant is refused, not over-served",
       %{ctx: ctx} do
    entry =
      mint_connection!(
        ctx,
        %{"access_token" => "ya29.live"},
        %{"token_url" => "https://oauth2.googleapis.com/token"}
      )

    committed = grant!(ctx, entry.id, ["https://www.googleapis.com/auth/gmail.send"])
    resource = edge_resource!(ctx, committed.profile_id)

    assert {:error, {:scope_projection_unsatisfiable, missing}} =
             VaultReader.oauth_token(ctx, resource, @provider)

    assert "https://www.googleapis.com/auth/gmail.send" in missing
  end

  test "material never appears in what the operator surfaces return", %{ctx: ctx} do
    entry =
      mint_connection!(
        ctx,
        %{"access_token" => "ya29.super-secret"},
        %{"token_url" => "https://oauth2.googleapis.com/token"}
      )

    {:ok, listed} = Vault.list(ctx)
    rendered = inspect(listed)

    refute rendered =~ "ya29.super-secret"
    refute rendered =~ "sealed_payload"

    # And the sealed column really is sealed.
    {:ok, row} = Arca.VaultStorage.get(ctx.org_id, entry.id)
    refute row.sealed_payload =~ "ya29.super-secret"

    aad = CipherAAD.vault_entry(ctx.org_id, ctx.project_id, entry.id, @provider)
    assert {:ok, plaintext} = Sanctum.Cipher.decrypt(row.sealed_payload, aad)
    assert plaintext =~ "ya29.super-secret"
  end
end
