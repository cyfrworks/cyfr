# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuth do
  @moduledoc """
  Token lifecycle for v2 (material) vault entries.

  Dispense returns the sealed bundle's access token while it is valid;
  an expired bundle is refreshed against the entry's own
  `oauth_endpoints` — which the loader has already verified against the
  consent's binding digest, so a rebound endpoint can never be POSTed a
  refresh token under an old consent. Provider client credentials come
  from `Sanctum.ProviderCredentials` by tenant, never from the caller's
  permission set.

  Refresh is single-flighted per **vault entry** on
  `{:vault_oauth_refresh, athanor_id, entry_id}` — the entry is the only route
  to a material bundle, so entry grain is exactly one lock per stored
  refresh token.

  INVARIANT: no database transaction is held across the provider HTTP
  call — the POST and the CAS write-back are sequential; serialization
  is the lock's job, never the database's.
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.OAuth.RefreshLock
  alias Sanctum.Vault.Payload

  @expiry_buffer_seconds 60
  @max_expires_in 86_400 * 365

  @doc """
  Dispense an access token from a v2 payload's oauth bundle, refreshing
  through the entry-keyed single-flight lock when expired.
  """
  @spec dispense(Arca.Schemas.VaultEntry.t(), map(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def dispense(entry, oauth, provider) do
    if token_valid?(oauth) do
      {:ok, oauth["access_token"]}
    else
      lock_key = {:vault_oauth_refresh, entry.athanor_id, entry.id}

      RefreshLock.run(
        lock_key,
        fn -> refresh_as_leader(entry.athanor_id, entry.id, provider) end,
        fn -> recheck(entry.athanor_id, entry.id) end
      )
    end
  end

  @doc false
  # The pure half of a refresh: fold the provider's response into the
  # current payload, preserving fields and scopes. Public for tests — the
  # HTTP and CAS halves are exercised separately.
  def apply_refresh_response(payload, oauth, response) do
    new_oauth =
      %{
        "access_token" => response["access_token"],
        "refresh_token" => response["refresh_token"] || oauth["refresh_token"],
        "expires_at" => compute_expires_at(response["expires_in"]),
        "token_type" => response["token_type"] || oauth["token_type"] || "bearer"
      }
      |> Cyfr.MapUtil.put_present("scopes", oauth["scopes"])

    Map.put(payload, "oauth", new_oauth)
  end

  # ---------------------------------------------------------------------------
  # Leader / follower
  # ---------------------------------------------------------------------------

  # The leader re-reads the row inside the lock: a refresh that completed
  # between the caller's unseal and lock acquisition must be returned, not
  # repeated (the provider may have rotated the refresh token).
  defp refresh_as_leader(athanor_id, entry_id, provider) do
    with {:ok, entry, payload} <- load_fresh(athanor_id, entry_id) do
      oauth = payload["oauth"]

      cond do
        not is_map(oauth) ->
          {:error, :no_oauth_material}

        token_valid?(oauth) ->
          {:ok, oauth["access_token"]}

        not is_binary(oauth["refresh_token"]) ->
          {:error,
           "authorization_required: token expired and no refresh_token " <>
             "for vault entry #{entry_id}"}

        true ->
          perform_refresh(entry, payload, oauth, provider)
      end
    end
  end

  # A follower re-reads after the leader finished; :stale hands leadership
  # to the next caller (bounded by RefreshLock's retry count).
  defp recheck(athanor_id, entry_id) do
    case load_fresh(athanor_id, entry_id) do
      {:ok, _entry, %{"oauth" => oauth}} when is_map(oauth) ->
        if token_valid?(oauth), do: {:ok, oauth["access_token"]}, else: :stale

      _ ->
        :stale
    end
  end

  defp perform_refresh(entry, payload, oauth, provider) do
    endpoints = decode_endpoints(entry.oauth_endpoints)

    with {:ok, token_url} <- fetch_token_url(endpoints),
         # The scheme refusal lands before credentials are read or any
         # telemetry fires — a refresh token is never sent in the clear,
         # and the same rule runs again inside http_post for every caller.
         :ok <- require_https(token_url, :refresh_token),
         {:ok, creds} <- fetch_provider_creds(entry, provider) do
      body_params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => oauth["refresh_token"]
      }

      auth_style = endpoints["auth_style"] || "params"
      {headers, body_params} = apply_auth_style(auth_style, creds, body_params)
      headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]

      # One provider spelling on every event of a refresh: the entry's own
      # provider_hint — :attempt tagged with the caller's provider argument
      # while :ok read the hint made one refresh look like two providers.
      emit_telemetry(entry, entry.provider_hint, :attempt)

      case http_post(token_url, headers, URI.encode_query(body_params)) do
        {:ok, response} ->
          write_back(entry, apply_refresh_response(payload, oauth, response), oauth)

        {:error, reason} ->
          emit_telemetry(entry, entry.provider_hint, :error)

          {:error,
           "authorization_required: refresh failed for vault entry " <>
             "#{entry.id}: #{reason}"}
      end
    end
  end

  @doc false
  # CAS at the revision read inside the lock. A conflict means a concurrent
  # vault.rotate landed mid-refresh — and by then the provider has already
  # rotated the refresh token this refresh consumed, so simply dropping the
  # response would strand the entry on a dead token family (permanent
  # re-consent). The conflict is resolved by what the rotate actually
  # wrote — see merge_after_conflict/3. Public for tests, like
  # apply_refresh_response/3: the HTTP half is exercised separately.
  def write_back(entry, new_payload, consumed_oauth) do
    case seal_and_cas(entry, new_payload) do
      :ok ->
        emit_telemetry(entry, entry.provider_hint, :ok)
        {:ok, get_in(new_payload, ["oauth", "access_token"])}

      {:error, :payload_conflict} ->
        merge_after_conflict(entry, new_payload, consumed_oauth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seal_and_cas(entry, new_payload) do
    aad = CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

    with {:ok, json} <- encode_payload(new_payload),
         {:ok, sealed} <- Sanctum.Cipher.encrypt(json, aad) do
      Arca.VaultStorage.rotate_payload(entry.athanor_id, entry.id, entry.payload_rev, sealed)
    end
  end

  # The concurrent writer was a vault.rotate. Two cases, told apart by the
  # refresh token the fresh row carries:
  #
  #   * a DIFFERENT refresh token — the rotate brought its own bundle (a
  #     fresh grant). Its material wins outright: the bundle this refresh
  #     minted descends from a token family the re-auth abandoned.
  #   * the SAME refresh token — the rotate touched only the fields. The
  #     provider has already invalidated that stored token by answering
  #     this refresh, so the refreshed bundle is folded into the fresh
  #     payload (the rotate's fields win) and written once more. A second
  #     conflict gives up rather than looping.
  defp merge_after_conflict(entry, refreshed_payload, consumed_oauth) do
    with {:ok, fresh_entry, fresh_payload} <- load_fresh(entry.athanor_id, entry.id) do
      fresh_oauth = fresh_payload["oauth"]

      cond do
        is_map(fresh_oauth) and
            fresh_oauth["refresh_token"] != consumed_oauth["refresh_token"] ->
          if token_valid?(fresh_oauth) do
            {:ok, fresh_oauth["access_token"]}
          else
            {:error, :payload_conflict}
          end

        true ->
          merged = Map.put(fresh_payload, "oauth", refreshed_payload["oauth"])

          case seal_and_cas(fresh_entry, merged) do
            :ok ->
              emit_telemetry(fresh_entry, fresh_entry.provider_hint, :ok)
              {:ok, get_in(merged, ["oauth", "access_token"])}

            {:error, _} ->
              {:error, :payload_conflict}
          end
      end
    end
  end

  defp encode_payload(%{"fields" => fields} = payload) do
    Payload.encode_material(fields, payload["oauth"])
  end

  defp encode_payload(payload), do: {:error, {:invalid_payload, payload}}

  # ---------------------------------------------------------------------------
  # Pieces
  # ---------------------------------------------------------------------------

  defp load_fresh(athanor_id, entry_id) do
    with {:ok, entry} <- Arca.VaultStorage.get(athanor_id, entry_id),
         {:ok, sealed} <- fetch_sealed(entry) do
      aad = CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

      with {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad),
           {:ok, payload} <- Payload.decode(plaintext) do
        {:ok, entry, payload}
      else
        _ -> {:error, :unseal_failed}
      end
    end
  end

  defp fetch_sealed(%{sealed_payload: sealed}) when is_binary(sealed), do: {:ok, sealed}
  defp fetch_sealed(_), do: {:error, :unseal_failed}

  defp decode_endpoints(nil), do: %{}

  defp decode_endpoints(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  # Scheme policy lives in `require_https/2` inside http_post — one rule
  # for both token-endpoint dialects, not a second spelling here.
  defp fetch_token_url(%{"token_url" => url}) when is_binary(url), do: {:ok, url}
  defp fetch_token_url(_), do: {:error, :no_token_url}

  defp fetch_provider_creds(entry, provider) do
    Sanctum.ProviderCredentials.fetch_for_oauth(entry.athanor_id, provider)
  end

  @doc false
  # Shared with Sanctum.Vault.OAuthGrant — the grant exchange speaks the
  # same auth styles and token endpoint dialect as refresh.
  def apply_auth_style("header", creds, body_params) do
    encoded = Base.encode64("#{creds["client_id"]}:#{creds["client_secret"] || ""}")
    {[{"authorization", "Basic #{encoded}"}], body_params}
  end

  def apply_auth_style(_params, creds, body_params) do
    params = %{"client_id" => creds["client_id"]}

    params =
      if creds["client_secret"],
        do: Map.put(params, "client_secret", creds["client_secret"]),
        else: params

    {[], Map.merge(body_params, params)}
  end

  @doc false
  # The token URL is caller-supplied (vault.create / vault.rebind
  # oauth_endpoints), so this POST rides the pinned SSRF path like every
  # other outbound request: resolve-validate once, connect to the validated
  # IP, never follow redirects. A private token endpoint (an internal IdP)
  # is reachable only when the operator named it in the private-egress
  # allowlist. The scheme rule is `require_https/2` — the ONE spelling for
  # both token-endpoint dialects, keyed on what the POST carries.
  def http_post(url, headers, body, credential \\ :refresh_token) do
    with :ok <- require_https(url, credential) do
      case Cyfr.Network.pinned_request(:post, url, headers, body,
             allow_private: :policy,
             receive_timeout: 15_000,
             # A token response is a small JSON object; the endpoint is
             # caller-supplied, so the ceiling streams rather than trusting it.
             max_response_bytes: 1024 * 1024
           ) do
        {:ok, status, _resp_headers, resp_body} when status in 200..299 ->
          case Jason.decode(resp_body) do
            {:ok, data} -> {:ok, data}
            {:error, _} -> {:error, "invalid JSON response from token endpoint"}
          end

        {:ok, status, _resp_headers, _resp_body} ->
          {:error, "token exchange failed (status #{status})"}

        {:error, reason} ->
          Logger.warning("[Sanctum.Vault.OAuth] HTTP request failed: #{inspect(reason)}")
          {:error, "token endpoint unreachable"}
      end
    end
  end

  # One scheme rule, keyed on what the POST carries. A refresh token is a
  # long-lived credential: it never travels in the clear, door or no door,
  # and the refusal lands before a socket is ever opened. An authorization
  # code is single-use and short-lived: a doorless dev server may exchange
  # it against a local http IdP; a configured door makes https mandatory
  # for it too. This used to be two independent spellings 60 lines apart.
  defp require_https(url, :refresh_token), do: https_or_refuse(url)

  defp require_https(url, :auth_code) do
    if Sanctum.auth_configured?(), do: https_or_refuse(url), else: :ok
  end

  defp https_or_refuse(url) do
    if String.starts_with?(url, "https://") do
      :ok
    else
      {:error, "token_url must use https://"}
    end
  end

  defp token_valid?(%{"expires_at" => nil, "access_token" => token}) when is_binary(token),
    do: true

  defp token_valid?(%{"expires_at" => expires_at}) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _} -> DateTime.diff(dt, DateTime.utc_now()) > @expiry_buffer_seconds
      _ -> false
    end
  end

  defp token_valid?(%{"access_token" => token}) when is_binary(token), do: true
  defp token_valid?(_), do: false

  @doc false
  # Shared with Sanctum.Vault.OAuthGrant. An ABSENT `expires_in` is a
  # non-expiring token (nil, never refreshed — correct). A PRESENT but
  # unusable one must not be read the same way: `token_valid?/1` answers
  # true for a nil expiry forever, so the entry would work until the
  # provider expires it and then 401 with no refresh ever attempted.
  # Present-but-unparseable records the token as already expired instead,
  # forcing one refresh attempt on the next dispense.
  def compute_expires_at(nil), do: nil

  def compute_expires_at(expires_in)
      when is_integer(expires_in) and expires_in > 0 and expires_in <= @max_expires_in do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.to_iso8601()
  end

  # An expiry past the one-year ceiling is clamped, not treated as absent —
  # the token still expires, just later than we track.
  def compute_expires_at(expires_in) when is_integer(expires_in) and expires_in > @max_expires_in,
    do: compute_expires_at(@max_expires_in)

  # RFC 6749 says `expires_in` is a number; plenty of providers send a
  # JSON string, and a few send a float.
  def compute_expires_at(expires_in) when is_binary(expires_in) do
    case Integer.parse(String.trim(expires_in)) do
      {seconds, ""} -> compute_expires_at(seconds)
      _ -> expired_now(expires_in)
    end
  end

  def compute_expires_at(expires_in) when is_float(expires_in) and expires_in > 0,
    do: compute_expires_at(trunc(expires_in))

  def compute_expires_at(other), do: expired_now(other)

  defp expired_now(value) do
    Logger.warning(
      "[Sanctum.Vault.OAuth] unusable expires_in #{inspect(value)} — recording the token " <>
        "as already expired so a refresh is attempted rather than never"
    )

    DateTime.to_iso8601(DateTime.utc_now())
  end

  defp emit_telemetry(entry, provider, status) do
    :telemetry.execute(
      [:cyfr, :sanctum, :vault, :oauth_refresh],
      %{system_time: System.system_time()},
      %{entry_id: entry.id, provider: provider, status: status}
    )
  end
end
