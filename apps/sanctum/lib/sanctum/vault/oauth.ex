# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault.OAuth do
  @moduledoc """
  OAuth for vault entries: the provider presets, the endpoint rule and the
  token lifecycle.

  **Presets.** One table (`preset/1`) names the endpoints of each provider
  this instance ships an arc for and whether that provider attenuates a
  refresh (`attenuates_scope?/1`). An entry's endpoints are fixed when it
  is created, from its provider's preset or, for a provider with none,
  given explicitly and held to `validate_endpoints/1`; they never change
  afterwards. Attenuation is never stored on an entry: it is the
  provider's, read from the table each time.

  **Dispense.** `dispense/5` answers a token for the projection's scopes.
  A projection naming exactly the entry's scopes is answered the sealed
  bundle's token while it is valid, and an expired bundle is refreshed
  against the entry's own `oauth_endpoints`, which the loader has already
  verified against the consent's binding digest. A projection naming fewer
  is answered only where the provider attenuates a refresh: by a token
  held for that scope set (`oauth.tokens`, `Sanctum.Vault.Payload`), or one
  a refresh sending `scope` obtains, whose answer must name a scope set
  within the request. Otherwise it is refused `:scope_not_attenuable`
  before any lock or request, and the entry's broader token is never
  served for it. Provider client credentials come from
  `Sanctum.ProviderCredentials` by tenant, never from the caller's
  permission set.

  Refresh is single-flighted per **vault entry** on
  `{:vault_oauth_refresh, athanor_id, entry_id}`, whatever scope set it
  asks for: the entry holds one refresh token, so one lock per entry is one
  lock per refresh token, and a provider that rotates it on use is never
  raced. Each leader and follower checks the token of its own scope set.
  `Sanctum.OAuth.RefreshLock` serializes the cell on that key, not just
  this member. The athanor in the key, in every read and write below and
  in the AEAD AAD is the CALLER's, carried on the actor; a row never names
  the tenant that may act on it.

  The lock serializes the provider call. What decides the *write* is the
  compare-and-set on `payload_rev`: a write that advanced that revision
  since this refresh read it (a rotate, a re-authorization) makes the
  write-back lose, and it is reconciled against what stands, so an old
  refresh never replaces a newer bundle even when both members refreshed
  at once. A change that advances no revision (a `field_names` rebind, a
  status change) cannot make that write lose. The binding is therefore
  checked apart from it, against the binding the dispense was validated at
  and with the entry still active: at every re-read whose token may be
  answered after the lock (`load_fresh/3`), and again after a refresh's own
  write (`still_fenced/2`), before its token is answered. A change landing
  after that last check, before the caller uses the token, is not seen; the
  token answered is still the validated binding's. A refresh refused at a
  conflict's re-read for a moved binding keeps a refresh token the provider
  rotated for it, where the row, still active, holds the token this refresh
  consumed (`refuse_moved/4`); one refused after its write has already
  stored it.

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

  @typedoc """
  A provider's preset: the endpoints an entry of its hint is created with,
  and whether the provider is shown to attenuate a refresh to the scopes
  it sends.
  """
  @type preset :: %{endpoints: %{String.t() => term()}, attenuates_scope: boolean()}

  # The providers this instance has shipped an arc for. Every preset's
  # `attenuates_scope` is false. A preset is switched on only by a change
  # that records the provider's documentation that a refresh's `scope`
  # parameter yields a token limited to it, and a live test against the
  # provider showing it; until then a narrower projection of its entries
  # is refused rather than served the entry's broader token.
  @presets %{
    "google" => %{
      endpoints: %{
        "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url" => "https://oauth2.googleapis.com/token",
        "auth_style" => "params",
        "extra_params" => %{"access_type" => "offline", "prompt" => "consent"}
      },
      attenuates_scope: false
    }
  }

  # What an entry's stored `oauth_endpoints` holds, and nothing else.
  @endpoint_keys ~w(authorize_url token_url auth_style extra_params)

  # The authorization parameters this server owns. `extra_params` exists for
  # provider knobs (`access_type`, `prompt`, `audience`); naming one of these
  # is either a misunderstanding or an attempt to steer the flow, and both
  # deserve an answer rather than a silent drop.
  @reserved_params ~w(client_id redirect_uri response_type scope state
                      code_challenge code_challenge_method)

  # ---------------------------------------------------------------------------
  # Presets and endpoints
  # ---------------------------------------------------------------------------

  @doc """
  The preset of `provider_hint`, or nil for a provider this instance ships
  none for, whose entries are created with explicit endpoints.
  """
  @spec preset(String.t() | nil) :: preset() | nil
  def preset(provider_hint) when is_binary(provider_hint) do
    case Map.fetch(@presets, provider_hint) do
      {:ok, preset} -> preset
      :error -> scripted_preset(provider_hint)
    end
  end

  def preset(_provider_hint), do: nil

  @doc """
  Whether `provider_hint`'s provider is shown to attenuate a refresh:
  false for a provider without a preset, and false for every preset this
  instance ships.
  """
  @spec attenuates_scope?(String.t() | nil) :: boolean()
  def attenuates_scope?(provider_hint),
    do: match?(%{attenuates_scope: true}, preset(provider_hint))

  @doc """
  Hold explicit endpoints to the endpoint rule: an `authorize_url` and a
  `token_url`, both https, and no `extra_params` naming a parameter this
  server owns. Answers the endpoints as an entry stores them, its endpoint
  keys alone (`authorize_url`, `token_url`, `auth_style`, `extra_params`).
  """
  @spec validate_endpoints(term()) ::
          {:ok, %{String.t() => term()}}
          | {:error,
             :endpoints_required
             | :endpoints_must_use_https
             | {:reserved_extra_param, String.t()}}
  def validate_endpoints(%{"authorize_url" => auth, "token_url" => token} = endpoints)
      when is_binary(auth) and is_binary(token) do
    cond do
      not (String.starts_with?(auth, "https://") and String.starts_with?(token, "https://")) ->
        {:error, :endpoints_must_use_https}

      reserved = reserved_extra_param(endpoints) ->
        {:error, {:reserved_extra_param, reserved}}

      true ->
        {:ok, Map.take(endpoints, @endpoint_keys)}
    end
  end

  def validate_endpoints(_endpoints), do: {:error, :endpoints_required}

  defp reserved_extra_param(endpoints) do
    case endpoints["extra_params"] do
      %{} = extra -> Enum.find(@reserved_params, &Map.has_key?(extra, &1))
      _ -> nil
    end
  end

  # A provider the suites script, standing in for a preset no shipped one
  # reaches: `:sanctum, :scripted_oauth_provider`, a test seam no
  # configuration file or variable sets (as `:sanctum, :oidc_reauth_client`
  # is), names a module whose `preset/1` answers a preset for a hint the
  # shipped table does not hold and whose `post/3` answers that preset's
  # token endpoint in the network's place. It never replaces a shipped
  # preset, and a release never sets it.
  defp scripted_preset(provider_hint) do
    case scripted() do
      nil ->
        nil

      module ->
        case module.preset(provider_hint) do
          nil ->
            nil

          %{endpoints: %{} = endpoints, attenuates_scope: attenuates}
          when is_boolean(attenuates) ->
            %{endpoints: endpoints, attenuates_scope: attenuates}

          other ->
            raise ArgumentError,
                  "a scripted OAuth preset is malformed: #{Prima.LoggerContext.shape(other)}, " <>
                    "expected a map of endpoints and a boolean attenuates_scope"
        end
    end
  end

  defp scripted do
    case Application.get_env(:sanctum, :scripted_oauth_provider) do
      nil ->
        nil

      module when is_atom(module) ->
        module

      other ->
        raise ArgumentError,
              ":scripted_oauth_provider is a module, got #{Prima.LoggerContext.shape(other)}"
    end
  end

  defp scripted_provider(provider_hint) when is_binary(provider_hint) do
    if Map.has_key?(@presets, provider_hint) or scripted_preset(provider_hint) == nil,
      do: nil,
      else: scripted()
  end

  # ---------------------------------------------------------------------------
  # Dispense
  # ---------------------------------------------------------------------------

  @doc """
  Dispense an access token for `scopes`, the projection's, from the
  entry's oauth bundle.

  Scopes equal as a set to the entry's are answered the bundle's token,
  refreshed through the entry-keyed single-flight lock when expired.
  Narrower scopes are answered only where the entry's provider attenuates a
  refresh, and refused `:scope_not_attenuable` with no lock taken and no
  request made where it does not. Scopes the entry lacks are refused
  `{:scope_projection_unsatisfiable, missing}`.

  `entry` is the row the caller validated the consent's binding against,
  and `oauth` its bundle. Every read of the row after waiting on or taking
  the refresh lock whose token may be answered, and the row after a
  refresh's own write, is checked against that binding and for the entry
  being active: a binding that
  moved meanwhile (a re-authorization for other scopes, a rebind) refuses
  `:binding_mismatch`, an entry no longer active `{:entry_unavailable,
  status}`, and nothing is dispensed, so a token granted under a new
  binding is never answered to a consent to the old one.
  """
  @spec dispense(Prima.Actor.t(), Arca.VaultStorage.entry(), map(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def dispense(%Prima.Actor{athanor_id: athanor_id} = actor, entry, oauth, provider, scopes)
      when is_binary(athanor_id) and is_list(scopes) do
    requested = scopes |> Enum.uniq() |> Enum.sort()

    with {:ok, fence} <- fence(entry) do
      case projection_class(entry, requested) do
        :whole -> dispense_whole(actor, entry, oauth, provider, fence)
        :narrower -> dispense_narrower(actor, entry, oauth, provider, requested, fence)
        {:error, _} = refused -> refused
      end
    end
  end

  # The binding a dispense was validated at: the digest derived from the
  # row's binding fields, as the reader derives it. A row read later answers
  # for the same consent only while it derives the same one.
  defp fence(entry) do
    case Sanctum.VaultReader.binding_digest(entry) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, :binding_mismatch}
    end
  end

  defp projection_class(entry, requested) do
    held = entry_scopes(entry)

    case requested -- held do
      [] when requested == held ->
        :whole

      [] ->
        if attenuates_scope?(entry.provider_hint),
          do: :narrower,
          else: {:error, :scope_not_attenuable}

      missing ->
        {:error, {:scope_projection_unsatisfiable, missing}}
    end
  end

  defp dispense_whole(actor, entry, oauth, provider, fence) do
    if token_valid?(oauth) do
      {:ok, oauth["access_token"]}
    else
      RefreshLock.run(
        lock_key(actor, entry.id),
        fn -> refresh_as_leader(actor, entry.id, provider, fence) end,
        fn -> recheck(actor, entry.id, fence) end
      )
    end
  end

  defp dispense_narrower(actor, entry, oauth, provider, requested, fence) do
    key = Payload.scope_key(requested)

    case held_token(oauth, key) do
      {:ok, _token} = held ->
        held

      :none ->
        RefreshLock.run(
          lock_key(actor, entry.id),
          fn -> narrower_as_leader(actor, entry.id, provider, requested, fence) end,
          fn -> recheck_narrower(actor, entry.id, key, fence) end
        )
    end
  end

  # One lock per entry, so one per stored refresh token, whatever scope
  # set a refresh asks for.
  defp lock_key(%Prima.Actor{athanor_id: athanor_id}, entry_id),
    do: {:vault_oauth_refresh, athanor_id, entry_id}

  @doc false
  # The pure half of a full-scope refresh: fold the provider's response
  # into the current payload, preserving fields, scopes and the tokens held
  # for narrower scope sets. Public for tests — the HTTP and CAS halves are
  # exercised separately.
  def apply_refresh_response(payload, oauth, response) do
    new_oauth =
      %{
        "access_token" => response["access_token"],
        "refresh_token" => response["refresh_token"] || oauth["refresh_token"],
        "expires_at" => compute_expires_at(response["expires_in"]),
        "token_type" => response["token_type"] || oauth["token_type"] || "bearer"
      }
      |> Prima.MapUtil.put_present("scopes", oauth["scopes"])
      |> Prima.MapUtil.put_present("tokens", oauth["tokens"])

    Map.put(payload, "oauth", new_oauth)
  end

  # ---------------------------------------------------------------------------
  # Leader / follower: the entry's own scopes
  # ---------------------------------------------------------------------------

  # The leader re-reads the row inside the lock: a refresh that completed
  # between the caller's unseal and lock acquisition must be returned, not
  # repeated (the provider may have rotated the refresh token). The re-read
  # is fenced on the binding the caller validated (`load_fresh/3`).
  defp refresh_as_leader(actor, entry_id, provider, fence) do
    with {:ok, entry, payload} <- load_fresh(actor, entry_id, fence) do
      oauth = payload["oauth"]

      cond do
        not is_map(oauth) ->
          {:error, :no_oauth_material}

        token_valid?(oauth) ->
          {:ok, oauth["access_token"]}

        not is_binary(oauth["refresh_token"]) ->
          {:error,
           {:authorization_required,
            "the token expired and this connection carries no refresh token " <>
              "(entry #{entry_id})"}}

        true ->
          perform_refresh(actor, entry, payload, oauth, provider)
      end
    end
  end

  # A follower re-reads after the leader finished; :stale hands leadership
  # to the next caller (bounded by RefreshLock's retry count). A binding
  # that moved answers :stale too, never the new binding's token: the
  # retry leads, and its fenced re-read refuses.
  defp recheck(actor, entry_id, fence) do
    case load_fresh(actor, entry_id, fence) do
      {:ok, _entry, %{"oauth" => oauth}} when is_map(oauth) ->
        if token_valid?(oauth), do: {:ok, oauth["access_token"]}, else: :stale

      _ ->
        :stale
    end
  end

  defp perform_refresh(actor, entry, payload, oauth, provider) do
    endpoints = decode_endpoints(entry.oauth_endpoints)

    with {:ok, token_url} <- fetch_token_url(endpoints),
         # The scheme refusal lands before credentials are read or any
         # telemetry fires — a refresh token is never sent in the clear,
         # and the same rule runs again inside http_post for every caller.
         :ok <- require_https(token_url, :refresh_token),
         {:ok, creds} <- fetch_provider_creds(actor, provider) do
      body_params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => oauth["refresh_token"]
      }

      # Use the entry’s provider_hint for every refresh telemetry event.
      emit_telemetry(entry, entry.provider_hint, :attempt)

      case token_post(entry, endpoints, creds, token_url, body_params) do
        {:ok, response} ->
          write_back(actor, entry, apply_refresh_response(payload, oauth, response), oauth)

        {:error, reason} ->
          emit_telemetry(entry, entry.provider_hint, :error)

          {:error,
           {:authorization_required, "the refresh failed for entry #{entry.id}: #{reason}"}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Leader / follower: a narrower scope set
  # ---------------------------------------------------------------------------

  defp narrower_as_leader(actor, entry_id, provider, requested, fence) do
    key = Payload.scope_key(requested)

    with {:ok, entry, payload} <- load_fresh(actor, entry_id, fence) do
      oauth = payload["oauth"]

      cond do
        not is_map(oauth) ->
          {:error, :no_oauth_material}

        match?({:ok, _}, held_token(oauth, key)) ->
          held_token(oauth, key)

        not is_binary(oauth["refresh_token"]) ->
          {:error,
           {:authorization_required,
            "this connection carries no refresh token, so no token for fewer scopes " <>
              "can be obtained (entry #{entry_id})"}}

        true ->
          perform_narrower_refresh(actor, entry, payload, oauth, provider, requested)
      end
    end
  end

  defp recheck_narrower(actor, entry_id, key, fence) do
    case load_fresh(actor, entry_id, fence) do
      {:ok, _entry, %{"oauth" => oauth}} when is_map(oauth) ->
        case held_token(oauth, key) do
          {:ok, _token} = held -> held
          :none -> :stale
        end

      _ ->
        :stale
    end
  end

  defp perform_narrower_refresh(actor, entry, payload, oauth, provider, requested) do
    endpoints = decode_endpoints(entry.oauth_endpoints)

    with {:ok, token_url} <- fetch_token_url(endpoints),
         :ok <- require_https(token_url, :refresh_token),
         {:ok, creds} <- fetch_provider_creds(actor, provider) do
      body_params = %{
        "grant_type" => "refresh_token",
        "refresh_token" => oauth["refresh_token"],
        "scope" => Enum.join(requested, " ")
      }

      emit_telemetry(entry, entry.provider_hint, :attempt)

      case token_post(entry, endpoints, creds, token_url, body_params) do
        {:ok, response} ->
          narrower_answer(actor, entry, payload, oauth, requested, response)

        {:error, reason} ->
          emit_telemetry(entry, entry.provider_hint, :error)

          {:error,
           {:authorization_required, "the refresh failed for entry #{entry.id}: #{reason}"}}
      end
    end
  end

  # An answer is held for its scope set only when it names a scope set
  # within the request: an answer naming none says nothing of what the
  # token reaches, and one naming more is the broader token the projection
  # must never be served. A refused answer's access token is neither held
  # nor dispensed, but a refresh token it rotated is kept, since the
  # provider may already have retired the one this refresh presented.
  defp narrower_answer(actor, entry, payload, oauth, requested, response) do
    key = Payload.scope_key(requested)

    case attenuated_token(response, requested) do
      {:ok, token} ->
        held = %{
          "access_token" => token,
          "expires_at" => compute_expires_at(response["expires_in"])
        }

        update = fn bundle ->
          bundle
          |> Map.put("tokens", Map.put(bundle["tokens"] || %{}, key, held))
          |> put_rotated(response)
        end

        case commit_update(actor, entry, payload, oauth, update) do
          :ok ->
            emit_telemetry(entry, entry.provider_hint, :ok)
            answer_fenced(actor, entry, token)

          # A rotate brought its own bundle mid-refresh: the token this
          # refresh obtained descends from a family the re-auth abandoned,
          # so only what the rotate holds for this scope set is answered.
          {:superseded, fresh_oauth} ->
            case held_token(fresh_oauth, key) do
              {:ok, _token} = held -> held
              :none -> {:error, :payload_conflict}
            end

          {:error, _} = refused ->
            refused
        end

      {:error, _} = refused ->
        emit_telemetry(entry, entry.provider_hint, :error)
        keep_rotated(actor, entry, payload, oauth, response)
        refused
    end
  end

  defp attenuated_token(response, requested) do
    sent = Enum.flat_map(requested, &String.split/1)

    case answered_scopes(response["scope"]) do
      [] ->
        {:error, :scope_not_attenuable}

      answered ->
        cond do
          answered -- sent != [] ->
            {:error, :scope_not_attenuable}

          not is_binary(response["access_token"]) ->
            {:error,
             {:authorization_required,
              "the token endpoint answered no access token for fewer scopes"}}

          true ->
            {:ok, response["access_token"]}
        end
    end
  end

  # RFC 6749 spells an answer's scope as one space-delimited string; a JSON
  # array of strings says the same. Anything else names no scope.
  defp answered_scopes(scope) when is_binary(scope), do: scope |> String.split() |> Enum.uniq()

  defp answered_scopes(scope) when is_list(scope) do
    if Enum.all?(scope, &is_binary/1),
      do: scope |> Enum.flat_map(&String.split/1) |> Enum.uniq(),
      else: []
  end

  defp answered_scopes(_scope), do: []

  defp put_rotated(bundle, %{"refresh_token" => rotated})
       when is_binary(rotated) and rotated != "",
       do: Map.put(bundle, "refresh_token", rotated)

  defp put_rotated(bundle, _response), do: bundle

  defp keep_rotated(actor, entry, payload, oauth, %{"refresh_token" => rotated} = response)
       when is_binary(rotated) and rotated != "" do
    if rotated != oauth["refresh_token"] do
      case commit_update(actor, entry, payload, oauth, &put_rotated(&1, response)) do
        :ok ->
          :ok

        # A rotate brought its own bundle, whose refresh token stands.
        {:superseded, _fresh_oauth} ->
          :ok

        # The binding moved: `refuse_moved/4` kept the rotated token in the
        # row as it stands, where that row still held the one consumed.
        {:error, :binding_mismatch} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.Vault.OAuth] a refused refresh's rotated refresh token was not stored " <>
              "for entry #{entry.id}: #{inspect(Prima.Sanitizer.sanitize(reason))}"
          )
      end
    end

    :ok
  end

  defp keep_rotated(_actor, _entry, _payload, _oauth, _response), do: :ok

  # The token held for a scope set, while it is valid.
  defp held_token(oauth, key) when is_map(oauth) do
    case oauth["tokens"] do
      %{^key => held} -> if token_valid?(held), do: {:ok, held["access_token"]}, else: :none
      _ -> :none
    end
  end

  defp held_token(_oauth, _key), do: :none

  # Apply `update` to the bundle read inside the lock and write it at the
  # revision read. A conflict is reconciled as `merge_after_conflict/4`
  # reconciles a full-scope refresh: the re-read is fenced on the binding
  # `entry` was read at, a rotate that brought its own bundle wins outright
  # (`{:superseded, its_bundle}`), and one that kept the bundle has the
  # update folded into what it wrote, once.
  defp commit_update(actor, entry, payload, consumed_oauth, update) do
    updated = Map.put(payload, "oauth", update.(payload["oauth"]))

    case seal_and_cas(actor, entry, updated) do
      :ok ->
        :ok

      {:error, :payload_conflict} ->
        rotated = updated["oauth"]["refresh_token"]

        with {:ok, fence} <- fence(entry),
             {:ok, fresh_entry, fresh_payload} <-
               fenced_reread(actor, entry.id, fence, consumed_oauth, rotated) do
          fresh_oauth = fresh_payload["oauth"]

          cond do
            not is_map(fresh_oauth) ->
              {:error, :payload_conflict}

            fresh_oauth["refresh_token"] != consumed_oauth["refresh_token"] ->
              {:superseded, fresh_oauth}

            true ->
              merged = Map.put(fresh_payload, "oauth", update.(fresh_oauth))

              case seal_and_cas(actor, fresh_entry, merged) do
                :ok -> :ok
                {:error, _} -> {:error, :payload_conflict}
              end
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # CAS at the revision read inside the lock. A conflict means a write that
  # advanced the revision landed mid-refresh (a rotate or a
  # re-authorization) — and by then the provider has already rotated the
  # refresh token this refresh consumed, so simply dropping the response
  # would strand the entry on a dead token family (permanent re-consent).
  # The conflict is resolved by what that write actually stored — see
  # merge_after_conflict/4. Public for tests, like apply_refresh_response/3:
  # the HTTP half is exercised separately.
  def write_back(%Prima.Actor{} = actor, entry, new_payload, consumed_oauth) do
    case seal_and_cas(actor, entry, new_payload) do
      :ok ->
        emit_telemetry(entry, entry.provider_hint, :ok)
        answer_fenced(actor, entry, get_in(new_payload, ["oauth", "access_token"]))

      {:error, :payload_conflict} ->
        merge_after_conflict(actor, entry, new_payload, consumed_oauth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seal_and_cas(%Prima.Actor{athanor_id: athanor_id} = actor, entry, new_payload) do
    aad = CipherAAD.vault_entry(athanor_id, entry.id, entry.provider_hint)

    with {:ok, json} <- encode_payload(new_payload),
         {:ok, sealed} <- Sanctum.Cipher.encrypt(json, aad) do
      Arca.VaultStorage.rotate_payload(actor, entry.id, entry.payload_rev, sealed)
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
  #
  # Either way the re-read is fenced first on the binding `entry` was read
  # at: a write that moved the binding (a re-authorization for other scopes,
  # a rebind) is the binding's own, so nothing of it, or of this refresh, is
  # answered (`:binding_mismatch`), and only a refresh token the provider
  # rotated is kept (`refuse_moved/4`).
  defp merge_after_conflict(actor, entry, refreshed_payload, consumed_oauth) do
    rotated = get_in(refreshed_payload, ["oauth", "refresh_token"])

    with {:ok, fence} <- fence(entry),
         {:ok, fresh_entry, fresh_payload} <-
           fenced_reread(actor, entry.id, fence, consumed_oauth, rotated) do
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

          case seal_and_cas(actor, fresh_entry, merged) do
            :ok ->
              emit_telemetry(fresh_entry, fresh_entry.provider_hint, :ok)
              answer_fenced(actor, entry, get_in(merged, ["oauth", "access_token"]))

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

  # The row as it stands, read for a dispense validated at `fence`: one no
  # longer active (revoked, tombstoned since the reader's check) or whose
  # binding has moved since refuses before anything of it is unsealed.
  defp load_fresh(%Prima.Actor{} = actor, entry_id, fence) do
    with {:ok, entry} <- Arca.VaultStorage.get(actor, entry_id),
         :ok <- active(entry),
         :ok <- fenced(entry, fence) do
      unseal_row(actor, entry)
    end
  end

  defp unseal_row(%Prima.Actor{athanor_id: athanor_id}, entry) do
    with {:ok, sealed} <- fetch_sealed(entry) do
      aad = CipherAAD.vault_entry(athanor_id, entry.id, entry.provider_hint)

      with {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad),
           {:ok, payload} <- Payload.decode(plaintext) do
        {:ok, entry, payload}
      else
        _ -> {:error, :unseal_failed}
      end
    end
  end

  defp active(%{status: "active"}), do: :ok
  defp active(%{status: status}), do: {:error, {:entry_unavailable, status}}

  # A conflict's re-read, fenced; a moved binding goes through
  # `refuse_moved/4`.
  defp fenced_reread(actor, entry_id, fence, consumed_oauth, rotated) do
    case load_fresh(actor, entry_id, fence) do
      {:error, :binding_mismatch} -> refuse_moved(actor, entry_id, consumed_oauth, rotated)
      other -> other
    end
  end

  # A refresh whose binding moved under it answers nothing. The provider
  # may already have rotated the refresh token it presented, though, and
  # retired the one consumed: where the row as it stands still holds that
  # consumed token, the rotated one alone is written into it, at the row's
  # own revision, with no access token and no narrower token, so nothing
  # widens and the entry is never left on a token the provider retired.
  # The moved binding holds the same token family; a re-authorization that
  # brought its own refresh token is left as it is. One attempt: a second
  # conflict means another writer owns the row now.
  defp refuse_moved(actor, entry_id, consumed_oauth, rotated) do
    consumed = consumed_oauth["refresh_token"]

    with true <- is_binary(consumed) and is_binary(rotated) and rotated not in ["", consumed],
         {:ok, current} <- Arca.VaultStorage.get(actor, entry_id),
         :ok <- active(current),
         {:ok, current, payload} <- unseal_row(actor, current),
         %{"refresh_token" => ^consumed} = oauth <- payload["oauth"] do
      kept = Map.put(payload, "oauth", Map.put(oauth, "refresh_token", rotated))

      case seal_and_cas(actor, current, kept) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.Vault.OAuth] a refresh refused for a moved binding could not keep its " <>
              "rotated refresh token for entry #{entry_id}: " <>
              inspect(Prima.Sanitizer.sanitize(reason))
          )
      end
    end

    {:error, :binding_mismatch}
  end

  defp fenced(entry, fence) do
    case fence(entry) do
      {:ok, ^fence} -> :ok
      _moved -> {:error, :binding_mismatch}
    end
  end

  # A refresh's write is fenced on `payload_rev` alone, and a binding move
  # that writes no payload (a `field_names` rebind) or a status change can
  # land while the refresh is at the provider. The row is read once more
  # after the write: its token, stored now and of the same family, is
  # answered only under the binding `entry` was validated at, while the
  # entry is active.
  defp answer_fenced(actor, entry, token) do
    with :ok <- still_fenced(actor, entry), do: {:ok, token}
  end

  defp still_fenced(actor, entry) do
    with {:ok, fence} <- fence(entry),
         {:ok, current} <- Arca.VaultStorage.get(actor, entry.id),
         :ok <- active(current) do
      fenced(current, fence)
    end
  end

  defp fetch_sealed(%{sealed_payload: sealed}) when is_binary(sealed), do: {:ok, sealed}
  defp fetch_sealed(_), do: {:error, :unseal_failed}

  # The entry's authorized scopes, its binding column, as a sorted set.
  defp entry_scopes(%{oauth_scopes: json}) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        list |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

      _ ->
        []
    end
  end

  defp entry_scopes(_entry), do: []

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

  defp fetch_provider_creds(%Prima.Actor{athanor_id: athanor_id}, provider) do
    Sanctum.ProviderCredentials.fetch_for_oauth(athanor_id, provider)
  end

  # A refresh's POST, in the entry's auth style, to its token endpoint: over
  # the network, or to the suites' scripted provider for a hint only it
  # answers. The scheme rule holds for both.
  defp token_post(entry, endpoints, creds, token_url, body_params) do
    auth_style = endpoints["auth_style"] || "params"
    {headers, body_params} = apply_auth_style(auth_style, creds, body_params)
    headers = [{"content-type", "application/x-www-form-urlencoded"} | headers]
    body = URI.encode_query(body_params)

    case scripted_provider(entry.provider_hint) do
      nil ->
        http_post(token_url, headers, body)

      module ->
        with :ok <- require_https(token_url, :refresh_token),
             do: module.post(token_url, headers, body)
    end
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
  # The token URL is an entry's endpoint (a preset's, or one given and
  # validated when the entry was created), so this POST rides the pinned
  # SSRF path like every other outbound request: resolve-validate once,
  # connect to the validated IP, never follow redirects. A private token
  # endpoint (an internal IdP) is reachable only when the operator named it
  # in the private-egress allowlist. The scheme rule is `require_https/2` —
  # the ONE spelling for both token-endpoint dialects, keyed on what the
  # POST carries.
  def http_post(url, headers, body, credential \\ :refresh_token) do
    with :ok <- require_https(url, credential) do
      case Sanctum.Egress.pinned_request(:post, url, headers, body,
             private_policy: :operator,
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

  # Refresh-token exchange always requires HTTPS. Authorization-code exchange
  # allows HTTP only on a server without an auth provider configured.
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
