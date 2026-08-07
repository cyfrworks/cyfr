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
  `{:vault_oauth_refresh, org, entry_id}` — the entry is the only route
  to a material bundle, so entry grain is exactly one lock per stored
  refresh token. Legacy pointer entries never reach this module; they
  delegate to `Sanctum.OAuth` and serialize on its component-ref key
  with every legacy caller of the same bundle.

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
      lock_key =
        {:vault_oauth_refresh, Arca.QueryHelpers.normalize_org_id(entry.org_id), entry.id}

      RefreshLock.run(
        lock_key,
        fn -> refresh_as_leader(entry.org_id, entry.id, provider) end,
        fn -> recheck(entry.org_id, entry.id) end
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
      |> put_present("scopes", oauth["scopes"])

    Map.put(payload, "oauth", new_oauth)
  end

  # ---------------------------------------------------------------------------
  # Leader / follower
  # ---------------------------------------------------------------------------

  # The leader re-reads the row inside the lock: a refresh that completed
  # between the caller's unseal and lock acquisition must be returned, not
  # repeated (the provider may have rotated the refresh token).
  defp refresh_as_leader(org_id, entry_id, provider) do
    with {:ok, entry, payload} <- load_fresh(org_id, entry_id) do
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
  defp recheck(org_id, entry_id) do
    case load_fresh(org_id, entry_id) do
      {:ok, _entry, %{"oauth" => oauth}} when is_map(oauth) ->
        if token_valid?(oauth), do: {:ok, oauth["access_token"]}, else: :stale

      _ ->
        :stale
    end
  end

  defp perform_refresh(entry, payload, oauth, provider) do
    endpoints = decode_endpoints(entry.oauth_endpoints)

    with {:ok, token_url} <- fetch_token_url(endpoints),
         {:ok, creds} <- fetch_provider_creds(entry, provider) do
      body_params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => oauth["refresh_token"]
      }

      auth_style = endpoints["auth_style"] || "params"
      {headers, body_params} = apply_auth_style(auth_style, creds, body_params)
      headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]

      emit_telemetry(entry, provider, :attempt)

      case http_post(token_url, headers, URI.encode_query(body_params)) do
        {:ok, response} ->
          write_back(entry, apply_refresh_response(payload, oauth, response))

        {:error, reason} ->
          emit_telemetry(entry, provider, :error)

          {:error,
           "authorization_required: refresh failed for vault entry " <>
             "#{entry.id}: #{reason}"}
      end
    end
  end

  # CAS at the revision read inside the lock. A conflict means a concurrent
  # vault.rotate landed mid-refresh; the material writer wins and this
  # refresh re-reads rather than clobbering.
  defp write_back(entry, new_payload) do
    aad = CipherAAD.vault_entry(entry.org_id, entry.project_id, entry.id, entry.provider_hint)

    with {:ok, json} <- encode_payload(new_payload),
         {:ok, sealed} <- Sanctum.Cipher.encrypt(json, aad) do
      case Arca.VaultStorage.rotate_payload(entry.org_id, entry.id, entry.payload_rev, sealed) do
        :ok ->
          emit_telemetry(entry, entry.provider_hint, :ok)
          {:ok, get_in(new_payload, ["oauth", "access_token"])}

        {:error, :payload_conflict} ->
          case recheck(entry.org_id, entry.id) do
            {:ok, token} -> {:ok, token}
            :stale -> {:error, :payload_conflict}
          end

        {:error, reason} ->
          {:error, reason}
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

  defp load_fresh(org_id, entry_id) do
    with {:ok, entry} <- Arca.VaultStorage.get(org_id, entry_id),
         {:ok, sealed} <- fetch_sealed(entry) do
      aad = CipherAAD.vault_entry(entry.org_id, entry.project_id, entry.id, entry.provider_hint)

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

  defp fetch_token_url(%{"token_url" => url}) when is_binary(url) do
    if String.starts_with?(url, "https://") do
      {:ok, url}
    else
      {:error, "token_url must use https://"}
    end
  end

  defp fetch_token_url(_), do: {:error, :no_token_url}

  defp fetch_provider_creds(entry, provider) do
    Sanctum.ProviderCredentials.fetch_for_oauth(entry.org_id, entry.project_id, provider)
  end

  defp apply_auth_style("header", creds, body_params) do
    encoded = Base.encode64("#{creds["client_id"]}:#{creds["client_secret"] || ""}")
    {[{"authorization", "Basic #{encoded}"}], body_params}
  end

  defp apply_auth_style(_params, creds, body_params) do
    params = %{"client_id" => creds["client_id"]}

    params =
      if creds["client_secret"],
        do: Map.put(params, "client_secret", creds["client_secret"]),
        else: params

    {[], Map.merge(body_params, params)}
  end

  defp http_post(url, headers, body) do
    req = Finch.build(:post, url, headers, body)

    case Finch.request(req, Compendium.Finch, receive_timeout: 15_000, request_timeout: 20_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, "invalid JSON response from token endpoint"}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, "token refresh failed (status #{status})"}

      {:error, reason} ->
        Logger.warning("[Sanctum.Vault.OAuth] HTTP request failed: #{inspect(reason)}")
        {:error, "token endpoint unreachable"}
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

  defp compute_expires_at(nil), do: nil

  defp compute_expires_at(expires_in)
       when is_integer(expires_in) and expires_in > 0 and expires_in <= @max_expires_in do
    DateTime.utc_now()
    |> DateTime.add(expires_in, :second)
    |> DateTime.to_iso8601()
  end

  defp compute_expires_at(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp emit_telemetry(entry, provider, status) do
    :telemetry.execute(
      [:cyfr, :vault, :oauth_refresh],
      %{system_time: System.system_time()},
      %{entry_id: entry.id, provider: provider, status: status}
    )
  end
end
