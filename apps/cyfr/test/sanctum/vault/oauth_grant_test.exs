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

  import Ecto.Query, only: [from: 2]

  @provider "google"
  @scopes ["https://www.googleapis.com/auth/gmail.readonly"]

  # Where the cases' entries may go. Their tokens are dispensed to the
  # cases, so the entries are disclosed.
  @destination %{"hosts" => ["gmail.googleapis.com"]}
  @destination_text ~s({"hosts":["gmail.googleapis.com"],"scheme":"https"})
  # A narrower destination, which the session alone moves.
  @narrower Map.put(@destination, "paths", ["/gmail/"])

  # A provider no shipped preset is (`:sanctum, :scripted_oauth_provider`),
  # standing in for its token endpoint, which a code exchange and a refresh
  # both reach. It answers what the test scripts, in order, telling the
  # test each request; an answer scripted as `{before, answer}` runs
  # `before` first, so a write can land while a refresh is at the provider.
  defmodule RaceIdp do
    @moduledoc false

    @hint "race-idp"
    @endpoints %{
      "authorize_url" => "https://idp.race.test/authorize",
      "token_url" => "https://idp.race.test/token"
    }

    def hint, do: @hint
    def endpoints, do: @endpoints

    def preset(@hint), do: %{endpoints: @endpoints}
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

    # The scripted provider's token endpoint answers the grants' exchanges
    # and the dispenses' refreshes (`RaceIdp`); restored by on_exit,
    # registered before the change.
    prior = Application.fetch_env(:sanctum, :scripted_oauth_provider)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:sanctum, :scripted_oauth_provider, value)
        :error -> Application.delete_env(:sanctum, :scripted_oauth_provider)
      end
    end)

    Application.put_env(:sanctum, :scripted_oauth_provider, RaceIdp)

    ctx = Sanctum.TestContext.local()

    for provider <- [@provider, RaceIdp.hint()] do
      :ok =
        Sanctum.TestContext.put_provider_credentials(
          ctx,
          provider,
          "client-id-1",
          "client-secret-1"
        )
    end

    {:ok, ctx: ctx}
  end

  # An oauth entry as the store holds one, of `hint`'s provider at
  # `endpoints`, holding `fields` and the bundle `oauth`.
  defp stored_entry!(
         ctx,
         name,
         hint,
         endpoints,
         fields \\ %{},
         oauth \\ %{"access_token" => "at-0"}
       ) do
    id = Prima.UUID7.generate_id("vlt")
    aad = CipherAAD.vault_entry(ctx.athanor_id, id, hint)
    {:ok, json} = Payload.encode_material(fields, oauth)
    {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

    binding = %{
      provider_hint: hint,
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

  # An entry of the scripted provider, at its endpoints.
  defp idp_entry!(ctx, name, fields \\ %{}, oauth \\ %{"access_token" => "at-0"}),
    do: stored_entry!(ctx, name, RaceIdp.hint(), RaceIdp.endpoints(), fields, oauth)

  # The pending record a passed authorize_url/2 would have minted. The
  # pending is server-minted state, so fabricating it here exercises the
  # full fetch → validate → exchange → apply path.
  defp mint_pending!(ctx, target) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    # The pending record carries the context the interactive check passed
    # for and the actor it projects; the callback has no context of its own
    # and acts with that authority and no other.
    pending = %{
      target: target,
      redirect_uri: CyfrWeb.Endpoint.url() <> "/auth/oauth/callback",
      code_verifier: "verifier-1",
      context: ctx,
      actor: Sanctum.Context.actor(ctx)
    }

    Arca.Cache.put({:vault_oauth_pending, state}, pending, 120_000)
    {state, pending}
  end

  defp new_target(name) do
    %{
      kind: :new,
      entry_id: nil,
      name: name,
      provider: RaceIdp.hint(),
      endpoints: RaceIdp.endpoints(),
      scopes: @scopes,
      destination: @destination_text,
      attach_only: false
    }
  end

  defp existing_target(entry, scopes) do
    %{
      kind: :existing,
      entry_id: entry.id,
      name: entry.name,
      provider: entry.provider_hint,
      endpoints: Jason.decode!(entry.oauth_endpoints),
      scopes: scopes
    }
  end

  # The scripted token endpoint's answers, in order, replacing any a case
  # scripted before.
  defp script!(answers) do
    test = self()
    _ = stop_supervised(RaceIdp)

    start_supervised!(%{
      id: RaceIdp,
      start: {Agent, :start_link, [fn -> {test, answers} end, [name: RaceIdp]]}
    })

    :ok
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

      entry = stored_entry!(ctx, "G-stored", @provider, stored)

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
      script!([
        {:ok,
         %{
           "access_token" => "at-1",
           "refresh_token" => "rt-1",
           "expires_in" => 3600,
           "token_type" => "Bearer"
         }}
      ])

      {state, pending} = mint_pending!(ctx, new_target("My Google"))

      assert {:ok, result} = OAuthGrant.complete(state, "code-1", pending.redirect_uri)
      assert result.provider == RaceIdp.hint()
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
      assert entry.provider_hint == RaceIdp.hint()
      assert entry.binding_digest != nil
      assert payload["v"] == 3

      # The bundle is the token, its refresh token and its expiry; the
      # scopes it was granted for are the entry's binding column.
      assert %{"access_token" => "at-1", "refresh_token" => "rt-1", "expires_at" => expires_at} =
               payload["oauth"]

      assert map_size(payload["oauth"]) == 3
      assert is_binary(expires_at)
      assert Jason.decode!(entry.oauth_scopes) == @scopes

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

    test "an unknown state is its own refusal" do
      assert {:error, :unknown_state} = OAuthGrant.complete("no-such-state", "c", "r")
    end

    test "the state is single-use", %{ctx: ctx} do
      script!([{:ok, %{"access_token" => "at"}}])
      {state, pending} = mint_pending!(ctx, new_target("Once"))

      assert {:ok, _} = OAuthGrant.complete(state, "code", pending.redirect_uri)
      assert {:error, :unknown_state} = OAuthGrant.complete(state, "code", pending.redirect_uri)
    end

    test "a redirect_uri mismatch is refused before any provider contact", %{ctx: ctx} do
      script!([])
      {state, _pending} = mint_pending!(ctx, new_target("Strict"))

      assert {:error, "redirect_uri mismatch"} =
               OAuthGrant.complete(state, "code", "https://evil.example/callback")

      refute_received {:token_request, _}
    end

    test "a token endpoint over plain http is never sent the code", %{ctx: ctx} do
      script!([{:ok, %{"access_token" => "at-plain"}}])

      plain = %{
        new_target("Plain")
        | endpoints: %{RaceIdp.endpoints() | "token_url" => "http://idp.race.test/token"}
      }

      {state, pending} = mint_pending!(ctx, plain)

      assert {:error, "token_url must use https://"} =
               OAuthGrant.complete(state, "code", pending.redirect_uri)

      refute_received {:token_request, _}
      assert entries_named(ctx, "Plain") == []
    end
  end

  describe "complete/3 — re-auth of an existing entry" do
    test "same binding replaces material under CAS and clears needs_reauth", %{ctx: ctx} do
      view = idp_entry!(ctx, "G", %{"note" => "kept"})

      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), view.id, "needs_reauth")
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)
      digest_before = entry.binding_digest

      script!([{:ok, %{"access_token" => "at-2", "refresh_token" => "rt-2"}}])
      {state, pending} = mint_pending!(ctx, existing_target(entry, @scopes))

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

    test "an entry whose stored payload does not open is refused, never rewritten as empty fields",
         %{ctx: ctx} do
      view = idp_entry!(ctx, "G-damaged", %{"note" => "kept"})
      actor = Sanctum.Context.actor(ctx)

      # The payload sealed under another entry's AAD: stored bytes this
      # entry cannot open.
      {:ok, other_json} = Payload.encode_material(%{}, %{"access_token" => "other"})
      other_aad = CipherAAD.vault_entry(ctx.athanor_id, "vlt_other", RaceIdp.hint())
      {:ok, foreign} = Sanctum.Cipher.encrypt(other_json, other_aad)

      {1, _} =
        Arca.Repo.update_all(
          from(v in Arca.Schemas.VaultEntry, where: v.id == ^view.id),
          set: [sealed_payload: foreign]
        )

      {:ok, entry} = Arca.VaultStorage.get(actor, view.id)

      script!([{:ok, %{"access_token" => "at-2", "refresh_token" => "rt-2"}}])
      {state, pending} = mint_pending!(ctx, existing_target(entry, @scopes))

      assert {:error, :unseal_failed} =
               OAuthGrant.complete(state, "code-damaged", pending.redirect_uri)

      {:ok, after_entry} = Arca.VaultStorage.get(actor, view.id)
      assert after_entry.sealed_payload == foreign
      assert after_entry.payload_rev == entry.payload_rev
    end

    test "changed scopes are a rebind: digest moves, bound profile flips", %{ctx: ctx} do
      # Bind a profile to the entry through the real consent walk.
      wasm = Cyfr.Test.Guests.wasm(:reagent)

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, wasm, %{
          name: "grant-bound",
          version: "1.0.0",
          type: "reagent"
        })

      view = idp_entry!(ctx, "G2")

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

      script!([{:ok, %{"access_token" => "at-3"}}])

      wider = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      {state, pending} = mint_pending!(ctx, existing_target(entry, wider))

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

    test "a grant for other scopes rebinds them with its own bundle", %{ctx: ctx} do
      held = %{"access_token" => "at-0", "refresh_token" => "rt-0"}
      view = idp_entry!(ctx, "G-regrant", %{}, held)
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)

      script!([{:ok, %{"access_token" => "at-regrant", "refresh_token" => "rt-regrant"}}])

      wider = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      {state, pending} = mint_pending!(ctx, existing_target(entry, wider))

      assert {:ok, %{rebound: true}} = OAuthGrant.complete(state, "code-5", pending.redirect_uri)

      {after_entry, payload} = unseal!(view.id, ctx.athanor_id)
      assert Jason.decode!(after_entry.oauth_scopes) == wider
      assert after_entry.binding_digest != entry.binding_digest

      assert %{"access_token" => "at-regrant", "refresh_token" => "rt-regrant"} =
               payload["oauth"]
    end

    test "a target whose endpoints are no longer the entry's is refused and writes nothing",
         %{ctx: ctx} do
      view = idp_entry!(ctx, "G3", %{"note" => "kept"})
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)

      # The grant was started against endpoints the entry does not hold:
      # the code is exchanged at the token endpoint the grant was started
      # with, and then nothing is written.
      script!([{:ok, %{"access_token" => "at-moved", "refresh_token" => "rt-moved"}}])

      moved = %{
        existing_target(entry, @scopes)
        | endpoints:
            Map.put(RaceIdp.endpoints(), "authorize_url", "https://idp.elsewhere.example/auth")
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

  describe "complete/3 — the scopes the provider answered" do
    @send "https://www.googleapis.com/auth/gmail.send"

    # A new entry's grant for `requested`, answered `answer`, and the entry
    # it stored with its unsealed payload, or the refusal.
    defp grant_new(ctx, name, requested, answer) do
      script!([
        {:ok,
         Map.merge(%{"access_token" => "at-#{name}", "refresh_token" => "rt-#{name}"}, answer)}
      ])

      {state, pending} = mint_pending!(ctx, %{new_target(name) | scopes: requested})

      case OAuthGrant.complete(state, "code-#{name}", pending.redirect_uri) do
        {:ok, %{entry_id: id}} -> {:ok, unseal!(id, ctx.athanor_id), {state, pending}}
        {:error, _} = refused -> {refused, {state, pending}}
      end
    end

    # The scopes an entry binds: its binding column, the bundle holding none.
    defp stored_scopes({entry, payload}) do
      refute Map.has_key?(payload["oauth"], "scopes")
      Jason.decode!(entry.oauth_scopes)
    end

    defp entries_named(ctx, name) do
      {:ok, entries} = Arca.VaultStorage.list(Sanctum.Context.actor(ctx))
      Enum.filter(entries, &(&1.name == name))
    end

    test "a narrower answer is what the entry binds, and a dispense for the request reads it",
         %{ctx: ctx} do
      requested = @scopes ++ [@send]

      assert {:ok, {entry, _payload} = stored, _} =
               grant_new(ctx, "G-narrow", requested, %{"scope" => "#{@send} #{@send}"})

      assert stored_scopes(stored) == [@send]
      assert {:ok, entry.binding_digest} == VaultReader.binding_digest(entry)

      missing = @scopes

      assert {:error, {:scope_projection_unsatisfiable, ^missing}} =
               VaultReader.oauth_token(ctx, edge(entry, requested), RaceIdp.hint(), @dispense)

      assert {:ok, "at-G-narrow"} =
               VaultReader.oauth_token(ctx, edge(entry, [@send]), RaceIdp.hint(), @dispense)
    end

    test "a narrower answer to a re-authorization rebinds the entry to it", %{ctx: ctx} do
      requested = @scopes ++ [@send]
      view = idp_entry!(ctx, "G-renarrow")
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)

      script!([{:ok, %{"access_token" => "at-renarrow", "scope" => @send}}])
      {state, pending} = mint_pending!(ctx, existing_target(entry, requested))

      assert {:ok, %{rebound: true}} = OAuthGrant.complete(state, "code", pending.redirect_uri)

      {after_entry, _payload} = stored = unseal!(view.id, ctx.athanor_id)
      assert stored_scopes(stored) == [@send]
      assert after_entry.binding_digest != entry.binding_digest
    end

    test "a wider answer is refused and stores no token, for a new entry and a re-authorization",
         %{ctx: ctx} do
      assert {{:error, :scopes_not_requested}, {state, pending}} =
               grant_new(ctx, "G-wide", @scopes, %{"scope" => Enum.join(@scopes ++ [@send], " ")})

      assert entries_named(ctx, "G-wide") == []

      # The pending grant was spent as every refused exchange spends it.
      assert {:error, :unknown_state} = OAuthGrant.complete(state, "code", pending.redirect_uri)

      view = idp_entry!(ctx, "G-rewide", %{"note" => "kept"})
      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), view.id, "needs_reauth")
      {:ok, entry} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), view.id)

      script!([{:ok, %{"access_token" => "at-rewide", "scope" => "#{@send}"}}])
      {state, pending} = mint_pending!(ctx, existing_target(entry, @scopes))

      assert {:error, :scopes_not_requested} =
               OAuthGrant.complete(state, "code", pending.redirect_uri)

      {after_entry, payload} = unseal!(view.id, ctx.athanor_id)
      assert after_entry.payload_rev == entry.payload_rev
      assert after_entry.sealed_payload == entry.sealed_payload
      assert after_entry.binding_digest == entry.binding_digest
      assert after_entry.oauth_scopes == entry.oauth_scopes
      assert after_entry.status == "needs_reauth"
      assert payload["oauth"]["access_token"] == "at-0"
    end

    test "a scope that is not a string is a malformed answer and stores no token", %{ctx: ctx} do
      for {answer, n} <- Enum.with_index([@scopes, 7, %{"granted" => @scopes}]) do
        name = "G-malformed-#{n}"

        assert {{:error, "token endpoint returned no access_token or a malformed scope"}, _} =
                 grant_new(ctx, name, @scopes, %{"scope" => answer})

        assert entries_named(ctx, name) == []
      end
    end
  end

  # Controls: the answers the requested set already stood for before the
  # provider's answer was read.
  describe "complete/3 — answers that name the request or no scope" do
    test "an answer naming exactly the request stores it", %{ctx: ctx} do
      requested = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      answer = requested |> Enum.reverse() |> Enum.join(" ")

      assert {:ok, stored, _} = grant_new(ctx, "G-exact", requested, %{"scope" => answer})
      assert stored_scopes(stored) == requested
    end

    test "an answer naming no scope, absent or blank, stores the request", %{ctx: ctx} do
      for {answer, n} <-
            Enum.with_index([%{}, %{"scope" => nil}, %{"scope" => ""}, %{"scope" => "  "}]) do
        assert {:ok, {_entry, payload} = stored, _} =
                 grant_new(ctx, "G-omitted-#{n}", @scopes, answer)

        assert stored_scopes(stored) == @scopes
        assert payload["oauth"]["access_token"] == "at-G-omitted-#{n}"
        assert payload["oauth"]["refresh_token"] == "rt-G-omitted-#{n}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A dispense fenced on the binding it was validated at
  # ---------------------------------------------------------------------------

  describe "a dispense is fenced on the binding it was validated at" do
    @a "race.a"
    @b "race.b"
    @c "race.c"
    @expired "2020-01-01T00:00:00Z"

    test "a waiting dispense is never handed the token of a widening re-authorization",
         %{ctx: ctx} do
      # A dispense validated at the old binding waits on the entry's refresh
      # lock while a re-authorization for wider scopes commits; the token it
      # brings is the new binding's alone.
      narrow = @scopes
      wide = @scopes ++ ["https://www.googleapis.com/auth/gmail.send"]
      entry = race_entry!(ctx, narrow, expired_bundle("at-narrow", "rt-1"))

      lock = hold_refresh_lock!(ctx, entry)

      dispense =
        Task.async(fn ->
          VaultReader.oauth_token(ctx, edge(entry, narrow), RaceIdp.hint(), @dispense)
        end)

      await_waiting!(lock)

      script!([
        {:ok, %{"access_token" => "at-wide", "refresh_token" => "rt-2", "expires_in" => 3600}}
      ])

      {state, pending} = mint_pending!(ctx, existing_target(entry, wide))
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

    test "a refresh whose provider call is in flight when the entry is deleted writes nothing back",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      # While the refresh is at the provider, the owner deletes the entry:
      # its material is erased, and the refresh's write-back must not seal
      # the provider's answer into it again.
      script!([
        {fn -> {:ok, _} = Arca.VaultStorage.tombstone(Sanctum.Context.actor(ctx), entry.id) end,
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
      # The field schema is rebound and the bundle kept while the refresh is
      # at the provider, which rotates the refresh token. Nothing is answered
      # under the moved binding, but the entry is not left on the token the
      # provider retired.
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
    end

    test "a refresh answered for other scopes than the entry's is refused and keeps only the rotated token",
         %{ctx: ctx} do
      for {held, answered} <- [{[@a, @b], @a}, {[@a], "#{@a} #{@c}"}] do
        entry = race_entry!(ctx, held, expired_bundle("at-old", "rt-1"))

        script!([
          {:ok,
           %{
             "access_token" => "at-refreshed",
             "refresh_token" => "rt-2",
             "scope" => answered,
             "expires_in" => 3600
           }}
        ])

        assert {:error, {:authorization_required, sentence}} =
                 VaultReader.oauth_token(ctx, edge(entry, held), RaceIdp.hint(), @dispense)

        assert sentence ==
                 "the provider refreshed this connection for other scopes than it holds; " <>
                   "re-authorize it"

        assert_received {:token_request, %{"refresh_token" => "rt-1"}}
        row = row!(ctx, entry)
        assert Jason.decode!(row.oauth_scopes) == held
        assert row.binding_digest == entry.binding_digest
        kept = bundle!(ctx, entry)
        assert kept["refresh_token"] == "rt-2"
        assert kept["access_token"] == "at-old"
        stop_supervised!(RaceIdp)
      end
    end

    # The scope the code exchange refuses as malformed, read by the one
    # parser both paths share.
    for {shape, scope} <- [
          number: 7,
          object: %{"granted" => [@a, @b]},
          string_array: [@a, @b],
          mixed_array: [@a, 7]
        ] do
      test "a refresh answered with a #{shape} scope is refused and keeps only the rotated token",
           %{ctx: ctx} do
        held = [@a, @b]
        entry = race_entry!(ctx, held, expired_bundle("at-old", "rt-1"))

        script!([
          {:ok,
           %{
             "access_token" => "at-invalid",
             "refresh_token" => "rt-2",
             "scope" => unquote(Macro.escape(scope)),
             "expires_in" => 3600
           }}
        ])

        assert {:error,
                {:authorization_required, "the token endpoint answered a malformed scope"}} =
                 VaultReader.oauth_token(ctx, edge(entry, held), RaceIdp.hint(), @dispense)

        kept = bundle!(ctx, entry)
        assert kept["access_token"] == "at-old"
        assert kept["refresh_token"] == "rt-2"
        assert Jason.decode!(row!(ctx, entry).oauth_scopes) == held
      end
    end

    # Control: an answer naming the entry's own scopes, or none, refreshes.
    test "a refresh answered for the entry's own scopes, or none, is held", %{ctx: ctx} do
      for answer <- [%{"scope" => "#{@b} #{@a}"}, %{}, %{"scope" => " "}] do
        entry = race_entry!(ctx, [@a, @b], expired_bundle("at-old", "rt-1"))

        script!([
          {:ok,
           Map.merge(
             %{"access_token" => "at-refreshed", "refresh_token" => "rt-2", "expires_in" => 3600},
             answer
           )}
        ])

        assert {:ok, "at-refreshed"} =
                 VaultReader.oauth_token(ctx, edge(entry, [@a, @b]), RaceIdp.hint(), @dispense)

        assert Jason.decode!(row!(ctx, entry).oauth_scopes) == [@a, @b]
        assert bundle!(ctx, entry)["refresh_token"] == "rt-2"
        stop_supervised!(RaceIdp)
      end
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
      {:ok, _} = Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry.id, "revoked")

      release!(lock)
      assert {:error, {:entry_unavailable, "revoked"}} = Task.await(dispense, 30_000)
      refute_received {:token_request, _}
    end

    test "a refresh whose binding moves without a payload write answers nothing",
         %{ctx: ctx} do
      # A rebind of the destination writes no payload, so the refresh's own
      # write wins its compare-and-set; the row after the write is checked
      # against the binding the dispense was validated at.
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))
      test = self()

      script!([
        {fn ->
           send(
             test,
             {:rebind, Sanctum.Vault.rebind(ctx, %{id: entry.id, destination: @narrower})}
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

    test "a refresh whose entry is revoked while it is at the provider answers nothing",
         %{ctx: ctx} do
      entry = race_entry!(ctx, [@a], expired_bundle("at-old", "rt-1"))

      script!([
        {fn ->
           {:ok, _} =
             Arca.VaultStorage.set_status(Sanctum.Context.actor(ctx), entry.id, "revoked")
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
      projection: %{fields: %{}, scopes: scopes}
    }

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
