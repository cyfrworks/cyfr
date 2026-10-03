# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuthGrant do
  @moduledoc """
  The initial OAuth authorization for a vault entry — entry-keyed,
  never component-keyed. `authorize_url/2` starts a browser grant for a
  new or existing `kind: "oauth"` vault entry; `complete/3` (driven by
  the callback route) exchanges the code and seals the token bundle into
  the entry's material.

  Authorization endpoints live on the entry (they are binding fields,
  covered by the derived binding digest) and are fixed when it is
  created: a new entry takes its provider's preset
  (`Sanctum.Vault.OAuth.preset/1`) or, for a provider with none, the
  endpoints the request names; a re-auth uses the entry's stored
  endpoints exactly and takes no new ones, and a grant whose target's
  endpoints are no longer the entry's writes nothing
  (`:endpoints_immutable`). So what re-auth talks to is exactly what
  consent bound. Provider client credentials come from
  `Sanctum.ProviderCredentials` by tenant; a component manifest is never
  consulted.

  The two completion classes mirror `Sanctum.Vault`'s rotate/rebind
  split:

    * same binding (ordinary re-auth) — material replaced under the
      `payload_rev` CAS; no consent is disturbed; `needs_reauth` clears.
    * changed scopes — the scopes move with the bundle granted for them,
      the only way an entry's scopes change; the derived binding digest
      moves and every profile whose head consent references the entry
      flips to `needs_consent`.

  `complete/3` runs with no browser Context:
  proof-of-initiation is the single-use 256-bit `state`
  (delete-on-read, 2-minute TTL) plus the server-held PKCE verifier, and
  the interactive-class check happened at `authorize_url/2` when the
  pending record was minted. The pending record carries the Context that
  check passed for and the `Prima.Actor` it projects, so the callback acts
  with authority derived from the session that started the grant and
  never from a tenant named in a row it reads — and that standing is read
  again before the credential is written: a session-backed context is
  revalidated (`Sanctum.Caller.revalidate_session/1`), anything else is
  held to the channel rule (`Sanctum.Tenancy.channel_active?/2`). A grant
  a paired device started is written in a transaction that holds the
  device's client and certificate (`Sanctum.Issuance.device_hold/1`), so a
  revocation that commits after that revalidation writes nothing either.
  """

  require Logger
  require Sanctum.Issuance

  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Vault.OAuth, as: VaultOAuth
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  @pending_ttl_ms 120_000

  @doc """
  Start a browser authorization for a vault entry.

  Two shapes:

    * `%{entry_id: id, scopes: [...]?}` — re-authorize an existing oauth
      entry. Endpoints and provider come from the entry's own binding
      fields, and naming `endpoints` beside `entry_id` is refused
      `:endpoints_immutable`. Scopes are the entry's unless the request
      names others: re-authorization is the one way an entry's scopes
      change, and its callback rebinds them with the bundle granted for
      them. Naming an empty list is refused `:scopes_required`.
    * `%{name: n, provider: p, scopes: [...], endpoints: %{...}?}` — a new
      entry. A provider with a preset (`Sanctum.Vault.OAuth.preset/1`)
      takes the preset's endpoints, and naming any beside it is refused
      `:endpoints_preset_conflict`; any other provider must name them
      (`:endpoints_required`): `authorize_url` + `token_url` (https),
      optional `auth_style` / `extra_params`
      (`Sanctum.Vault.OAuth.validate_endpoints/1`).

  Starting one is a sensitive change (`credential_entry`): the grant it
  completes seals a credential into the vault.

  Returns `{:ok, %{url, state, redirect_uri}}`.
  """
  @spec authorize_url(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def authorize_url(%Context{} = ctx, params) when is_map(params) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, target} <- resolve_target(ctx, params),
         :ok <-
           Authz.confirm(ctx, :credential_entry, %{
             operation: "vault.authorize",
             arguments: params,
             resource: target.name
           }),
         {:ok, endpoints} <- VaultOAuth.validate_endpoints(target.endpoints),
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
        context: ctx,
        actor: Context.actor(ctx)
      }

      Arca.Cache.put({:vault_oauth_pending, state}, pending, @pending_ttl_ms)

      # Provider-specific knobs go UNDER the parameters this server minted:
      # `extra_params` is caller data (an entry's stored endpoints), and
      # merging it over the top would let it hand back its own `state`,
      # `redirect_uri` or a `code_challenge_method` of "plain" — downgrading
      # PKCE and substituting the very values the callback checks. Reserved
      # keys are refused outright at validation, so this ordering is the
      # belt behind that brace.
      query =
        (endpoints["extra_params"] || %{})
        |> Map.merge(%{
          "client_id" => creds["client_id"],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(target.scopes, " "),
          "state" => state,
          "code_challenge" => code_challenge,
          "code_challenge_method" => "S256"
        })

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
  answers 400, since an expired or foreign `state` proves nothing. The
  grant's actor must still stand where it started the grant, read before
  the exchange and again before anything is written: `{:error,
  :unauthenticated}` when it does not — the presented `state` opens
  nothing — and `{:error, :unavailable}` when the store cannot say, or
  when a remote person's identity cannot be confirmed fresh.
  """
  @spec complete(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def complete(state, code, redirect_uri) do
    # Standing is read before the code is spent at the provider and again
    # after, since the exchange is an outbound round trip a revocation can
    # land inside.
    with {:ok, pending} <- fetch_pending(state),
         :ok <- validate_redirect_uri(pending, redirect_uri),
         {:ok, _before} <- still_standing(pending),
         {:ok, creds} <- provider_creds(pending.actor.athanor_id, pending.target.provider),
         {:ok, response} <- exchange(pending, creds, code, redirect_uri),
         {:ok, standing} <- still_standing(pending),
         {:ok, hold} <- write_hold(standing) do
      bundle = %{
        "access_token" => response["access_token"],
        "refresh_token" => response["refresh_token"],
        "expires_at" => VaultOAuth.compute_expires_at(response["expires_in"]),
        "token_type" => response["token_type"] || "bearer",
        "scopes" => pending.target.scopes
      }

      pending |> apply_grant(bundle, hold) |> unheld()
    end
  end

  # The grant's actor, re-established: a session that started the grant must
  # still be a live session of a standing person focused on the same athanor;
  # any other holder is held to the rule an athanor-owned channel stands by.
  # A remote person whose identity could not be confirmed fresh is paused,
  # not signed out: the callback says to try again, as when the store
  # cannot answer.
  #
  # Answers the revalidated context, or nil for a grant no context
  # started, which its write is then held by (`write_hold/1`).
  defp still_standing(%{context: %Context{} = ctx, actor: actor}) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, %Context{} = fresh} -> with :ok <- same_athanor(fresh, actor), do: {:ok, fresh}
      {:error, reason} when reason in [:unavailable, :identity_stale] -> {:error, :unavailable}
      {:error, _refused} -> {:error, :unauthenticated}
    end
  end

  defp still_standing(%{actor: actor}), do: with(:ok <- channel(actor), do: {:ok, nil})

  # The write holds what the revalidated context stands on: a paired
  # device's client and certificate, locked in the write's own transaction
  # (`Sanctum.Issuance.device_hold/1`), so a revocation that commits after
  # the revalidation and before the write refuses it; nothing for a
  # session or a channel, as before. A device context with no binding of
  # its own opens nothing.
  defp write_hold(%Context{} = ctx) do
    case Sanctum.Issuance.device_hold(ctx) do
      {:ok, hold} -> {:ok, hold}
      {:error, _no_binding} -> {:error, :unauthenticated}
    end
  end

  defp write_hold(nil), do: {:ok, []}

  # A write its device no longer stands for, any of the standing refusals
  # (`Sanctum.Issuance`), is refused as the recheck refuses one: the
  # presented `state` opens nothing.
  defp unheld({:error, reason}) when Sanctum.Issuance.standing_refusal?(reason),
    do: {:error, :unauthenticated}

  defp unheld(result), do: result

  defp same_athanor(%Context{session_token_hash: hash, athanor_id: athanor_id}, actor)
       when is_binary(hash) do
    if athanor_id == actor.athanor_id, do: :ok, else: {:error, :unauthenticated}
  end

  defp same_athanor(%Context{}, actor), do: channel(actor)

  defp channel(%Prima.Actor{athanor_id: athanor_id, user_id: user_id}) do
    if Sanctum.Tenancy.channel_active?(athanor_id, user_id),
      do: :ok,
      else: {:error, :unauthenticated}
  end

  # ---------------------------------------------------------------------------
  # Target resolution
  # ---------------------------------------------------------------------------

  # An existing entry is re-authorized against exactly the endpoints it
  # was created with: no preset is merged over them, and a request naming
  # endpoints of its own is refused rather than silently ignored. It asks
  # for the scopes the request names, or the entry's own; a grant for other
  # scopes rebinds them at the callback (`rebind_step/2`). A request naming
  # no scopes at all is refused, never a rebind of the entry to none.
  defp resolve_target(ctx, %{entry_id: id} = params) when is_binary(id) do
    with :ok <- no_new_endpoints(params),
         :ok <- scopes_named(params),
         {:ok, entry} <- Arca.VaultStorage.get(Context.actor(ctx), id) do
      cond do
        entry.status == "tombstoned" ->
          {:error, :not_found}

        entry.kind != "oauth" ->
          {:error, {:not_an_oauth_entry, entry.kind}}

        entry.provider_hint == "" ->
          {:error, :provider_unknown}

        true ->
          {:ok,
           %{
             kind: :existing,
             entry_id: entry.id,
             name: entry.name,
             provider: entry.provider_hint,
             endpoints: decode_map(entry.oauth_endpoints),
             scopes: Map.get(params, :scopes) || decode_list(entry.oauth_scopes)
           }}
      end
    end
  end

  # A new entry's endpoints are its provider's preset, or, for a provider
  # with none, the ones the request names; never both and never neither.
  defp resolve_target(_ctx, %{name: name, provider: provider} = params)
       when is_binary(name) and name != "" and is_binary(provider) and provider != "" do
    with {:ok, endpoints} <- new_endpoints(provider, Map.get(params, :endpoints)) do
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
  end

  defp resolve_target(_ctx, _params),
    do: {:error, :target_required}

  defp no_new_endpoints(params) do
    if is_nil(Map.get(params, :endpoints)), do: :ok, else: {:error, :endpoints_immutable}
  end

  # A re-authorization keeps the entry's scopes when it names none and
  # otherwise names at least one, each a non-empty string.
  defp scopes_named(params) do
    case Map.fetch(params, :scopes) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, [_ | _] = scopes} -> if Enum.all?(scopes, &named_scope?/1), do: :ok, else: refused()
      {:ok, _other} -> refused()
    end
  end

  defp named_scope?(scope), do: is_binary(scope) and String.trim(scope) != ""
  defp refused, do: {:error, :scopes_required}

  defp new_endpoints(provider, given) do
    named? = not (is_nil(given) or given == %{})

    case VaultOAuth.preset(provider) do
      %{endpoints: _} when named? -> {:error, :endpoints_preset_conflict}
      %{endpoints: endpoints} -> {:ok, endpoints}
      nil when named? -> VaultOAuth.validate_endpoints(given)
      nil -> {:error, :endpoints_required}
    end
  end

  # `fetch_for_oauth` speaks operator-facing string errors, including the
  # not-configured message that names oauth.set_client.
  defp provider_creds(athanor_id, provider) do
    Sanctum.ProviderCredentials.fetch_for_oauth(athanor_id, provider)
  end

  # ---------------------------------------------------------------------------
  # Exchange
  # ---------------------------------------------------------------------------

  defp fetch_pending(state) do
    # Consume state atomically so replayed or concurrent callbacks fail.
    case Arca.Cache.take({:vault_oauth_pending, state}) do
      {:ok, pending} -> {:ok, pending}
      :miss -> {:error, :unknown_state}
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

    case VaultOAuth.http_post(
           endpoints["token_url"],
           headers,
           URI.encode_query(body_params),
           :auth_code
         ) do
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

  # A cipher fault (a missing or rotated keyring — `Cipher.encrypt/2`
  # RAISES on those; its success type is `{:ok, binary}` only) at this
  # point is unrecoverable either way: the single-use authorization code
  # is already spent. But a typed refusal reaches the operator with the
  # cause; an unrescued raise was a 500 with the grant half-applied.
  defp seal(json, aad) do
    Sanctum.Cipher.encrypt(json, aad)
  rescue
    e ->
      Logger.error("[Vault.OAuthGrant] credential seal failed: #{Exception.message(e)}")
      {:error, "credential seal failed — check the crypto keyring"}
  end

  defp apply_grant(%{target: %{kind: :new} = target, actor: actor} = pending, bundle, hold) do
    id = Prima.UUID7.generate_id("vlt")
    aad = CipherAAD.vault_entry(actor.athanor_id, id, target.provider)

    with {:ok, json} <- Payload.encode_material(%{}, bundle),
         {:ok, sealed} <- seal(json, aad) do
      # The binding columns are known before the insert, so the digest
      # derived from them is too: the row lands complete rather than
      # existing for a moment with no cached digest. The tenant is the
      # pending grant's actor and is stamped on by the facade.
      binding = %{
        provider_hint: target.provider,
        field_names: "[]",
        oauth_endpoints: Jason.encode!(target.endpoints),
        oauth_scopes: Jason.encode!(target.scopes)
      }

      with {:ok, digest} <- VaultReader.binding_digest(binding),
           attrs =
             Map.merge(binding, %{
               id: id,
               name: target.name,
               kind: "oauth",
               provenance: "user",
               status: "active",
               sealed_payload: sealed,
               binding_digest: digest
             }),
           {:ok, _entry} <- Arca.VaultStorage.put(actor, attrs, hold) do
        broadcast(pending, id, target.name, :create)
        {:ok, %{entry_id: id, name: target.name, provider: target.provider, rebound: false}}
      end
    end
  end

  defp apply_grant(%{target: %{kind: :existing} = target, actor: actor} = pending, bundle, hold) do
    with {:ok, entry} <- Arca.VaultStorage.get(actor, target.entry_id),
         :ok <- still_living(entry),
         :ok <- same_endpoints(entry, target) do
      fields = current_fields(actor, entry)
      aad = CipherAAD.vault_entry(actor.athanor_id, entry.id, entry.provider_hint)

      with {:ok, json} <- Payload.encode_material(fields, bundle),
           {:ok, sealed} <- seal(json, aad) do
        case commit_grant(actor, entry, target, sealed, hold) do
          {:ok, rebound} ->
            granted(pending, entry, target, rebound)

          {:error, :payload_conflict} ->
            # A concurrent material write landed between authorize and
            # callback. The grant is the fresher credential; one re-read
            # retry, then give up loudly.
            retry_grant(pending, bundle, hold)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp retry_grant(%{target: target, actor: actor} = pending, bundle, hold) do
    case Arca.VaultStorage.get(actor, target.entry_id) do
      {:ok, entry} ->
        # The retry re-runs the first attempt's checks, not just its
        # write: the conflicting writer may have been `vault.revoke` —
        # skipping `still_living/1` here CAS'd fresh live tokens into an
        # entry the owner had just revoked, re-arming it.
        with :ok <- still_living(entry),
             :ok <- same_endpoints(entry, target) do
          aad = CipherAAD.vault_entry(actor.athanor_id, entry.id, entry.provider_hint)

          with {:ok, json} <- Payload.encode_material(current_fields(actor, entry), bundle),
               {:ok, sealed} <- seal(json, aad),
               {:ok, rebound} <- commit_grant(actor, entry, target, sealed, hold) do
            granted(pending, entry, target, rebound)
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every decision the commit carries out is made HERE, before the
  # transaction opens: whether this grant moves the binding, the digest it
  # moves to, the status a successful re-auth restores, and the word a
  # blocked profile takes. What crosses into Arca is that plan plus the two
  # preconditions the rows must still satisfy — the digest the binding was
  # read at and the revision the payload was read at — and Arca writes the
  # lot in one transaction or none of it. Tokens granted for a new binding
  # are therefore never readable under a consent to the old one, and a
  # binding that cannot move leaves the old material exactly where it was.
  # `{:error, :payload_conflict}` when another material write landed since
  # `entry` was read.
  defp commit_grant(actor, entry, target, sealed, hold) do
    with {:ok, rebind} <- rebind_step(entry, target) do
      plan = %{
        expected_rev: entry.payload_rev,
        sealed_payload: sealed,
        # A successful re-auth clears `needs_reauth`, with the material.
        status: if(entry.status == "needs_reauth", do: "active"),
        rebind: rebind
      }

      case Arca.VaultStorage.commit_payload(actor, entry.id, plan, hold) do
        {:ok, _written} ->
          {:ok, rebind != nil}

        {:error, :binding_moved} = error ->
          Logger.error("[Vault.OAuthGrant] rebind failed: #{inspect(error)}")
          {:error, :rebind_bookkeeping_failed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp granted(pending, entry, target, rebound) do
    broadcast(pending, entry.id, entry.name, if(rebound, do: :rebind, else: :rotate))
    {:ok, %{entry_id: entry.id, name: entry.name, provider: target.provider, rebound: rebound}}
  end

  defp still_living(%{status: "tombstoned"}), do: {:error, :not_found}
  defp still_living(%{status: "revoked"}), do: {:error, :revoked}
  defp still_living(_), do: :ok

  # The endpoints the grant was started against must still be the entry's:
  # a grant never moves them, so one whose target names others writes
  # nothing.
  defp same_endpoints(entry, target) do
    if decode_map(entry.oauth_endpoints) == target.endpoints,
      do: :ok,
      else: {:error, :endpoints_immutable}
  end

  # Preserve material fields across a re-auth; an unreadable payload
  # converts to empty-fields material.
  defp current_fields(actor, entry) do
    aad = CipherAAD.vault_entry(actor.athanor_id, entry.id, entry.provider_hint)

    with sealed when is_binary(sealed) <- entry.sealed_payload,
         {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad),
         {:ok, %{"v" => 3, "fields" => fields}} <- Payload.decode(plaintext) do
      fields
    else
      _ -> %{}
    end
  end

  # A grant whose scopes differ from the entry's stored ones is a binding
  # change: the binding moves and every profile referencing the entry is
  # blocked with it, inside the commit's own transaction. Its endpoints
  # are the entry's (`same_endpoints/2`) and never move. The common re-auth
  # (same binding) is `nil` — nothing to move, no profile disturbed.
  defp rebind_step(entry, target) do
    stored_scopes = decode_list(entry.oauth_scopes)

    if Enum.sort(stored_scopes) == Enum.sort(target.scopes) do
      {:ok, nil}
    else
      changes = %{oauth_scopes: Jason.encode!(target.scopes)}

      with {:ok, digest} <- VaultReader.binding_digest(Map.merge(entry, changes)) do
        {:ok,
         %{
           from_digest: entry.binding_digest,
           changes: Map.put(changes, :binding_digest, digest),
           blocked_status: Sanctum.Vault.blocked_profile_status()
         }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Plumbing
  # ---------------------------------------------------------------------------

  defp broadcast(%{actor: actor}, entry_id, name, verb),
    do: Sanctum.Telemetry.vault_entry_changed(actor.athanor_id, entry_id, verb, %{name: name})

  @doc """
  The OAuth callback route, spelled once: the router mounts it, the
  callback controller rebuilds the redirect_uri from it, and the grant
  sends it to the provider — three copies of one wire contract collapse
  to this accessor (a moved route silently broke the flow before).
  """
  @spec callback_path() :: String.t()
  def callback_path, do: "/auth/oauth/callback"

  @doc """
  The `redirect_uri` this deployment registers with a provider.

  Uses `Sanctum.origin/0`: `CYFR_PUBLIC_URL` when the operator declared
  one, otherwise this deployment's own origin. Absolute either way — a
  provider cannot redirect to a path.
  """
  @spec redirect_uri() :: String.t()
  def redirect_uri do
    Sanctum.origin() <> callback_path()
  end

  defp build_redirect_uri, do: redirect_uri()

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
