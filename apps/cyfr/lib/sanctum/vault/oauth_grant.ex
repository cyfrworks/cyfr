# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthGrant do
  @moduledoc """
  The initial OAuth authorization for a Connection — connection-keyed,
  never component-keyed. `authorize_url/2` starts a browser grant for a
  new or existing `kind: "oauth"` vault entry; `complete/3` (driven by
  the callback route) exchanges the code and seals the token bundle into
  the entry's material.

  Authorization endpoints live on the entry (they are binding fields,
  covered by the derived binding digest), so what re-auth talks to is
  exactly what consent bound. Provider client credentials come from
  `Sanctum.ProviderCredentials` by tenant; a component manifest is never
  consulted.

  The two completion classes mirror `Sanctum.Vault`'s rotate/rebind
  split:

    * same binding (ordinary re-auth) — material replaced under the
      `payload_rev` CAS; no consent is disturbed; `needs_reauth` clears.
    * changed binding (scopes or endpoints that differ) — the derived
      binding digest moves and every profile whose head consent references
      the entry flips to `needs_consent`.

  `complete/3` runs with no browser Context:
  proof-of-initiation is the single-use 256-bit `state`
  (delete-on-read, 2-minute TTL) plus the server-held PKCE verifier, and
  the interactive-class check happened at `authorize_url/2` when the
  pending record was minted.
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Vault.OAuth, as: VaultOAuth
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  @pending_ttl_ms 120_000

  # Endpoint presets for providers this instance has shipped an arc for.
  # An unknown provider is not an error — the caller supplies endpoints
  # explicitly and they become the entry's binding fields like any other.
  @presets %{
    "google" => %{
      "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
      "token_url" => "https://oauth2.googleapis.com/token",
      "auth_style" => "params",
      "extra_params" => %{"access_type" => "offline", "prompt" => "consent"}
    }
  }

  @doc """
  Start a browser authorization for a Connection.

  Two shapes:

    * `%{entry_id: id}` — re-authorize an existing oauth entry. Endpoints,
      scopes and provider come from the entry's own binding fields.
    * `%{name: n, provider: p, scopes: [...], endpoints: %{...}?}` — a new
      Connection. `endpoints` may be omitted for a preset provider
      (#{inspect(Map.keys(@presets))}); otherwise it must carry
      `authorize_url` + `token_url` (https), optional `auth_style` /
      `extra_params`.

  Returns `{:ok, %{url, state, redirect_uri}}`.
  """
  @spec authorize_url(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def authorize_url(%Context{} = ctx, params) when is_map(params) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, target} <- resolve_target(ctx, params),
         {:ok, endpoints} <- validate_endpoints(target.endpoints),
         {:ok, creds} <- provider_creds(ctx.athanor_id, target.provider) do
      state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      code_verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      code_challenge =
        :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

      redirect_uri = build_redirect_uri()

      pending = %{
        target: target,
        redirect_uri: redirect_uri,
        code_verifier: code_verifier,
        athanor_id: ctx.athanor_id,
        user_id: ctx.user_id
      }

      Arca.Cache.put({:vault_oauth_pending, state}, pending, @pending_ttl_ms)

      query =
        %{
          "client_id" => creds["client_id"],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(target.scopes, " "),
          "state" => state,
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256"
        }
        |> Map.merge(endpoints["extra_params"] || %{})

      url = endpoints["authorize_url"] <> "?" <> URI.encode_query(query)
      {:ok, %{url: url, state: state, redirect_uri: redirect_uri}}
    end
  end

  @doc """
  Complete a pending grant: exchange the code, seal the bundle into the
  entry (minting it for a `:new` target), apply rotate-vs-rebind
  semantics, and clear `needs_reauth`.

  Returns `{:ok, %{entry_id, name, provider, rebound: bool}}`;
  `{:error, :unknown_state}` when no pending grant matches — the callback
  answers 400, since an expired or foreign `state` proves nothing.
  """
  @spec complete(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def complete(state, code, redirect_uri) do
    with {:ok, pending} <- fetch_pending(state),
         :ok <- validate_redirect_uri(pending, redirect_uri),
         {:ok, creds} <- provider_creds(pending.athanor_id, pending.target.provider),
         {:ok, response} <- exchange(pending, creds, code, redirect_uri) do
      bundle = %{
        "access_token" => response["access_token"],
        "refresh_token" => response["refresh_token"],
        "expires_at" => VaultOAuth.compute_expires_at(response["expires_in"]),
        "token_type" => response["token_type"] || "bearer",
        "scopes" => pending.target.scopes
      }

      apply_grant(pending, bundle)
    end
  end

  # ---------------------------------------------------------------------------
  # Target resolution
  # ---------------------------------------------------------------------------

  defp resolve_target(ctx, %{entry_id: id}) when is_binary(id) do
    with {:ok, entry} <- Arca.VaultStorage.get(ctx.athanor_id, id) do
      cond do
        entry.status == "tombstoned" ->
          {:error, :not_found}

        entry.kind != "oauth" ->
          {:error, {:not_an_oauth_entry, entry.kind}}

        true ->
          endpoints = decode_map(entry.oauth_endpoints)

          provider =
            case entry.provider_hint do
              hint when is_binary(hint) and hint != "" -> hint
              _ -> endpoints["provider"] || ""
            end

          if provider == "" do
            {:error, :provider_unknown}
          else
            {:ok,
             %{
               kind: :existing,
               entry_id: entry.id,
               name: entry.name,
               provider: provider,
               endpoints: with_preset(provider, endpoints),
               scopes: decode_list(entry.oauth_scopes)
             }}
          end
      end
    end
  end

  defp resolve_target(_ctx, %{name: name, provider: provider} = params)
       when is_binary(name) and name != "" and is_binary(provider) and provider != "" do
    endpoints = with_preset(provider, Map.get(params, :endpoints) || %{})

    {:ok,
     %{
       kind: :new,
       entry_id: nil,
       name: name,
       provider: provider,
       endpoints: endpoints,
       scopes: Map.get(params, :scopes, [])
     }}
  end

  defp resolve_target(_ctx, _params),
    do: {:error, :target_required}

  defp with_preset(provider, endpoints) do
    Map.merge(Map.get(@presets, provider, %{}), endpoints || %{})
  end

  defp validate_endpoints(%{"authorize_url" => auth, "token_url" => token} = endpoints)
       when is_binary(auth) and is_binary(token) do
    if String.starts_with?(auth, "https://") and String.starts_with?(token, "https://") do
      {:ok, endpoints}
    else
      {:error, :endpoints_must_use_https}
    end
  end

  defp validate_endpoints(_), do: {:error, :endpoints_required}

  # `fetch_for_oauth` speaks operator-facing string errors, including the
  # not-configured message that names oauth.set_client.
  defp provider_creds(athanor_id, provider) do
    Sanctum.ProviderCredentials.fetch_for_oauth(athanor_id, provider)
  end

  # ---------------------------------------------------------------------------
  # Exchange
  # ---------------------------------------------------------------------------

  defp fetch_pending(state) do
    # Single-use: consumed on read — a replayed callback with the same
    # state finds nothing.
    case Arca.Cache.get({:vault_oauth_pending, state}) do
      {:ok, pending} ->
        Arca.Cache.invalidate({:vault_oauth_pending, state})
        {:ok, pending}

      :miss ->
        {:error, :unknown_state}
    end
  end

  defp validate_redirect_uri(pending, redirect_uri) do
    if Plug.Crypto.secure_compare(to_string(pending.redirect_uri), to_string(redirect_uri || "")) do
      :ok
    else
      {:error, "redirect_uri mismatch"}
    end
  end

  defp exchange(pending, creds, code, redirect_uri) do
    endpoints = pending.target.endpoints

    body_params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri,
      "code_verifier" => pending.code_verifier
    }

    auth_style = endpoints["auth_style"] || "params"
    {headers, body_params} = VaultOAuth.apply_auth_style(auth_style, creds, body_params)
    headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]

    case VaultOAuth.http_post(endpoints["token_url"], headers, URI.encode_query(body_params)) do
      {:ok, %{"access_token" => token} = response} when is_binary(token) ->
        {:ok, response}

      {:ok, _} ->
        {:error, "token endpoint returned no access_token"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Applying the grant
  # ---------------------------------------------------------------------------

  defp apply_grant(%{target: %{kind: :new} = target} = pending, bundle) do
    with {:ok, json} <- Payload.encode_material(%{}, bundle) do
      id = Emissary.UUID7.generate_id("vlt")
      aad = CipherAAD.vault_entry(pending.athanor_id, id, target.provider)
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

      attrs = %{
        id: id,
        athanor_id: pending.athanor_id,
        name: target.name,
        kind: "oauth",
        provider_hint: target.provider,
        provenance: "user",
        field_names: "[]",
        oauth_endpoints: Jason.encode!(target.endpoints),
        oauth_scopes: Jason.encode!(target.scopes),
        status: "active",
        sealed_payload: sealed
      }

      with {:ok, entry} <- Arca.VaultStorage.put(attrs),
           {:ok, digest} <- VaultReader.binding_digest(entry),
           :ok <-
             Arca.VaultStorage.update_binding(pending.athanor_id, id, %{
               binding_digest: digest
             }) do
        broadcast(pending, id, :create)
        {:ok, %{entry_id: id, name: target.name, provider: target.provider, rebound: false}}
      end
    end
  end

  defp apply_grant(%{target: %{kind: :existing} = target} = pending, bundle) do
    with {:ok, entry} <- Arca.VaultStorage.get(pending.athanor_id, target.entry_id),
         :ok <- still_living(entry) do
      fields = current_fields(entry)

      with {:ok, json} <- Payload.encode_material(fields, bundle) do
        aad =
          CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

        {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

        case Arca.VaultStorage.rotate_payload(
               entry.athanor_id,
               entry.id,
               entry.payload_rev,
               sealed
             ) do
          :ok ->
            rebound = maybe_rebind(entry, target)

            if entry.status == "needs_reauth" do
              Arca.VaultStorage.set_status(entry.athanor_id, entry.id, "active")
            end

            broadcast(pending, entry.id, if(rebound, do: :rebind, else: :rotate))

            {:ok,
             %{entry_id: entry.id, name: entry.name, provider: target.provider, rebound: rebound}}

          {:error, :payload_conflict} ->
            # A concurrent material write landed between authorize and
            # callback. The grant is the fresher credential; one re-read
            # retry, then give up loudly.
            retry_grant(pending, bundle)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp retry_grant(%{target: target} = pending, bundle) do
    case Arca.VaultStorage.get(pending.athanor_id, target.entry_id) do
      {:ok, entry} ->
        with {:ok, json} <- Payload.encode_material(current_fields(entry), bundle) do
          aad =
            CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

          {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

          case Arca.VaultStorage.rotate_payload(
                 entry.athanor_id,
                 entry.id,
                 entry.payload_rev,
                 sealed
               ) do
            :ok ->
              rebound = maybe_rebind(entry, target)
              broadcast(pending, entry.id, if(rebound, do: :rebind, else: :rotate))

              {:ok,
               %{
                 entry_id: entry.id,
                 name: entry.name,
                 provider: target.provider,
                 rebound: rebound
               }}

            {:error, reason} ->
              {:error, reason}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp still_living(%{status: "tombstoned"}), do: {:error, :not_found}
  defp still_living(%{status: "revoked"}), do: {:error, :revoked}
  defp still_living(_), do: :ok

  # Preserve v2 material fields across a re-auth; a v1 pointer (or an
  # unreadable payload) converts to empty-fields material — the pointer's
  # legacy rows are not this entry's material and never migrate silently.
  defp current_fields(entry) do
    aad = CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

    with sealed when is_binary(sealed) <- entry.sealed_payload,
         {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad),
         {:ok, %{"v" => 2, "fields" => fields}} <- Payload.decode(plaintext) do
      fields
    else
      _ -> %{}
    end
  end

  # A grant whose endpoints or scopes differ from the entry's stored
  # binding fields is a binding change: update them, recompute the derived
  # digest, and flip referencing profiles to needs_consent. The common
  # re-auth (same binding) touches nothing.
  defp maybe_rebind(entry, target) do
    stored_endpoints = decode_map(entry.oauth_endpoints)
    stored_scopes = decode_list(entry.oauth_scopes)

    if stored_endpoints == target.endpoints and
         Enum.sort(stored_scopes) ==
           Enum.sort(target.scopes) do
      false
    else
      changes = %{
        oauth_endpoints: Jason.encode!(target.endpoints),
        oauth_scopes: Jason.encode!(target.scopes)
      }

      rebound = Map.merge(Map.from_struct(entry), changes)

      with {:ok, digest} <- VaultReader.binding_digest(rebound),
           :ok <-
             Arca.VaultStorage.update_binding(
               entry.athanor_id,
               entry.id,
               Map.put(changes, :binding_digest, digest)
             ),
           {:ok, affected} <-
             Arca.ConsentStorage.head_profiles_referencing(entry.athanor_id, entry.id) do
        Enum.each(affected, fn profile_id ->
          Arca.ProfileStorage.set_status(entry.athanor_id, profile_id, "needs_consent")
        end)

        true
      else
        error ->
          Logger.error("[Vault.OAuthGrant] rebind bookkeeping failed: #{inspect(error)}")
          true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  defp broadcast(pending, entry_id, verb) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      Prism.Topics.vault_changed(pending.athanor_id),
      {:vault_entry_changed, entry_id, verb}
    )

    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      Prism.Topics.vault_changed_global(),
      {:vault_entry_changed_global, pending.athanor_id, entry_id, verb}
    )
  end

  defp build_redirect_uri do
    EmissaryWeb.Endpoint.url() <> "/auth/oauth/callback"
  end

  defp decode_map(nil), do: %{}

  defp decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_list(nil), do: []

  defp decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
