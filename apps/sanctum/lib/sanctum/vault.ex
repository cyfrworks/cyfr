# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Vault do
  @moduledoc """
  The operator's credential verbs: list, create, rename, rotate, rebind,
  revoke, delete.

  Two mutations are deliberately different classes:

    * **rotate** replaces the sealed *material* under a `payload_rev`
      compare-and-swap. Binding fields are untouched, so the derived
      binding digest is unchanged and no consent is disturbed.
    * **rebind** changes what the credential *talks to* (endpoints,
      scopes, field schema). The derived binding digest moves, every
      profile whose head consent references the entry flips to
      `needs_consent`, and nothing runs against the new binding until a
      human re-consents.

  Every mutation requires the interactive consent class (`:oidc`
  surface, external plane) — no permission wildcard and no scoped key
  reaches these verbs. Each broadcasts `{:vault_entry_changed, id, verb}`
  on the tenant `"vault:changed"` topic so dependents (external MCP
  server processes holding resolved headers) reconcile immediately.

  What ships to callers is metadata only: names, kinds, field *names*,
  status. Material stays sealed; there is no read-back verb.

  The keyring, the AEAD and every plaintext stay here. Rows move through
  `Arca.VaultStorage`, which takes the caller's actor and answers plain
  maps of ciphertext and metadata — the tenant a read runs under is the
  actor's, and a row cannot name its own. Each verb decides everything a
  write will contain before asking for it, so the writes that must land
  together are one call and one transaction below, with nothing left for
  this module to abort.
  """

  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  require Logger

  @kinds ~w(api_key oauth bundle)
  @rebind_attempts 3

  # The status a profile takes when the binding under its head consent
  # moves. One word, written in one place: the operator's rebind and the
  # OAuth grant's rebind block dependents identically.
  @needs_consent "needs_consent"

  @type entry_view :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          status: String.t(),
          provenance: String.t(),
          field_names: [String.t()],
          oauth_scopes: [String.t()],
          payload_rev: non_neg_integer(),
          last_used_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Read
  # ---------------------------------------------------------------------------

  @doc "Living entries in the caller's athanor, metadata only."
  @spec list(Context.t()) :: {:ok, [entry_view()]} | {:error, term()}
  def list(%Context{} = ctx) do
    with {:ok, rows} <- Arca.VaultStorage.list(Context.actor(ctx)) do
      {:ok, Enum.map(rows, &view/1)}
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  @doc """
  Create an entry holding v2 material. `params`:

    * `:name` (required) — athanor-unique label among living entries
    * `:kind` (required) — `"api_key" | "oauth" | "bundle"`
    * `:fields` — `%{name => value}` material map (default empty)
    * `:oauth` — token bundle map (see `Sanctum.Vault.Payload`)
    * `:provider_hint` — immutable; defaults `""`
    * `:oauth_endpoints` / `:oauth_scopes` — binding fields
  """
  @spec create(Context.t(), map()) :: {:ok, entry_view()} | {:error, term()}
  def create(%Context{} = ctx, params) when is_map(params) do
    fields = Map.get(params, :fields, %{})

    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, name} <- required_name(params),
         {:ok, kind} <- required_kind(params),
         :ok <- check_name_free(ctx, name),
         {:ok, json} <- Payload.encode_material(fields, Map.get(params, :oauth)),
         id = Cyfr.UUID7.generate_id("vlt"),
         hint = Map.get(params, :provider_hint, ""),
         aad = CipherAAD.vault_entry(Context.athanor!(ctx), id, hint),
         {:ok, sealed} <- seal(json, aad) do
      binding = %{
        provider_hint: hint,
        field_names: Jason.encode!(Enum.sort(Map.keys(fields))),
        oauth_endpoints: encode_optional_map(Map.get(params, :oauth_endpoints)),
        oauth_scopes: encode_optional_list(Map.get(params, :oauth_scopes))
      }

      # The tenant is the caller's, never an attribute's: the facade stamps
      # the actor's athanor onto the row and refuses one supplied here.
      with {:ok, digest} <- VaultReader.binding_digest(binding),
           {:ok, entry} <-
             Arca.VaultStorage.put(
               Context.actor(ctx),
               Map.merge(binding, %{
                 id: id,
                 name: name,
                 kind: kind,
                 provenance: Map.get(params, :provenance, "user"),
                 status: "active",
                 sealed_payload: sealed,
                 binding_digest: digest
               })
             ) do
        broadcast(ctx, id, :create, %{name: entry.name})
        {:ok, view(entry)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rename
  # ---------------------------------------------------------------------------

  @doc """
  Rename the mutable label. Identity, bindings and consents are untouched.

  It is announced like every other mutation even so. Consents bind an entry
  *id*, but the external-MCP header plane binds a `vault:<name>` reference
  that `Sanctum.VaultReader.unseal_by_name/2` resolves at request time — so
  moving a name from one entry to another changes what a running server
  dispenses without any entry's material changing. That is a resolution
  change, and the reconciler is what acts on those.
  """
  @spec rename(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def rename(%Context{} = ctx, id, new_name) when is_binary(new_name) and new_name != "" do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_living(ctx, id),
         :ok <- check_name_free(ctx, new_name),
         :ok <- Arca.VaultStorage.update_meta(Context.actor(ctx), id, %{name: new_name}) do
      # The signal carries the name being VACATED: header templates
      # reference entries by name, so the servers a rename breaks are the
      # ones still spelling the old one — a post-hoc read of the row can
      # only ever see the new name.
      broadcast(ctx, id, :rename, %{name: new_name, old_name: entry.name})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Rotate — material only, never a re-consent
  # ---------------------------------------------------------------------------

  @doc """
  Replace the secret material under CAS. The field schema must match the
  entry's `field_names` — changing the schema is a rebind, and silently
  accepting a different shape here would smuggle a binding change past
  re-consent.
  """
  @spec rotate(Context.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rotate(%Context{} = ctx, %{id: id, fields: fields, expected_payload_rev: expected} = params)
      when is_map(fields) and is_integer(expected) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_rotatable(ctx, id),
         :ok <- check_schema(entry, fields),
         {:ok, current} <- unseal(ctx, entry),
         {:ok, oauth} <- rotation_oauth(current, Map.get(params, :oauth)),
         {:ok, json} <- Payload.encode_material(fields, oauth),
         aad = CipherAAD.vault_entry(Context.athanor!(ctx), entry.id, entry.provider_hint),
         {:ok, sealed} <- seal(json, aad) do
      # The material and the reactivation that belongs to it are one
      # transaction, the same one an OAuth grant commits through: a rotate
      # that fails part-way leaves the entry at the version it was already
      # readable at, never at a payload its status has not caught up to.
      plan = %{
        expected_rev: expected,
        sealed_payload: sealed,
        status: if(entry.status == "needs_reauth", do: "active"),
        rebind: nil
      }

      case Arca.VaultStorage.commit_payload(Context.actor(ctx), id, plan) do
        {:ok, %{payload_rev: rev}} ->
          broadcast(ctx, id, :rotate, %{name: entry.name})
          {:ok, rev}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rebind — a binding change, always a re-consent
  # ---------------------------------------------------------------------------

  @doc """
  Change the binding fields (`:field_names`, `:oauth_endpoints`,
  `:oauth_scopes`). `provider_hint` cannot change — it lives in the AAD.

  Returns the new derived binding digest and the profiles now blocked at
  `needs_consent`.
  """
  @spec rebind(Context.t(), map()) ::
          {:ok, %{binding_digest: String.t(), affected: [String.t()]}} | {:error, term()}
  def rebind(%Context{} = ctx, %{id: id} = params) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_living(ctx, id) do
      changes =
        %{}
        |> put_change(:field_names, params, &encode_optional_list/1)
        |> put_change(:oauth_endpoints, params, &encode_optional_map/1)
        |> put_change(:oauth_scopes, params, &encode_optional_list/1)

      if changes == %{} do
        {:error, :no_binding_changes}
      else
        with {:ok, rebound} <- rebind_entry(ctx, entry, changes, @rebind_attempts) do
          broadcast(ctx, id, :rebind, %{name: entry.name})
          {:ok, rebound}
        end
      end
    end
  end

  # A rebind that lost the race recomputes against what landed.
  defp rebind_entry(ctx, entry, changes, attempts) do
    case move_binding(ctx, entry, changes) do
      {:error, :binding_moved} when attempts > 1 ->
        with {:ok, fresh} <- get_living(ctx, entry.id),
             do: rebind_entry(ctx, fresh, changes, attempts - 1)

      result ->
        result
    end
  end

  # The new digest is derived here, from the entry as it was read merged
  # with the edit: a decision, made before any transaction opens. What
  # crosses into Arca is data — the digest the row must still read, the
  # columns to write, and the word a blocked profile takes. The binding
  # move and the invalidation of every profile that depended on it are one
  # transaction there, so no consent is ever left covering a binding it
  # did not approve, and a lost compare-and-set leaves neither behind.
  defp move_binding(%Context{} = ctx, entry, changes) when is_map(changes) do
    with {:ok, digest} <- VaultReader.binding_digest(Map.merge(entry, changes)),
         {:ok, affected} <-
           Arca.VaultStorage.move_binding(
             Context.actor(ctx),
             entry.id,
             entry.binding_digest,
             Map.put(changes, :binding_digest, digest),
             @needs_consent
           ) do
      {:ok, %{binding_digest: digest, affected: affected}}
    end
  end

  @doc false
  # What a profile's status becomes when the binding under its head consent
  # moves. `Sanctum.Vault.OAuthGrant` blocks dependents with the same word
  # and reads it from here rather than spelling it a second time.
  @spec blocked_profile_status() :: String.t()
  def blocked_profile_status, do: @needs_consent

  # ---------------------------------------------------------------------------
  # Revoke / delete
  # ---------------------------------------------------------------------------

  @doc """
  Stop the entry dispensing anything, effective at the next credential
  retrieval. Consents stay as history; the affected list is who loses
  access now.
  """
  @spec revoke(Context.t(), String.t()) :: {:ok, %{affected: [String.t()]}} | {:error, term()}
  def revoke(%Context{} = ctx, id) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_living(ctx, id),
         :ok <- Arca.VaultStorage.set_status(Context.actor(ctx), id, "revoked"),
         {:ok, affected} <-
           Arca.ConsentStorage.head_profiles_referencing(Context.actor(ctx), id) do
      broadcast(ctx, id, :revoke, %{name: entry.name})
      {:ok, %{affected: Enum.sort(affected)}}
    end
  end

  @doc "Tombstone the entry and erase its sealed material. The name frees up."
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, id) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_any(ctx, id),
         :ok <- Arca.VaultStorage.tombstone(Context.actor(ctx), id) do
      broadcast(ctx, id, :delete, %{name: entry.name})
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp view(entry) do
    %{
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      provider_hint: entry.provider_hint,
      status: entry.status,
      provenance: entry.provenance,
      field_names: decode_list(entry.field_names, "field_names"),
      oauth_scopes: decode_list(entry.oauth_scopes, "oauth_scopes"),
      payload_rev: entry.payload_rev,
      last_used_at: entry.last_used_at
    }
  end

  defp required_name(%{name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp required_name(_), do: {:error, :name_required}

  defp required_kind(%{kind: kind}) when kind in @kinds, do: {:ok, kind}
  defp required_kind(_), do: {:error, {:invalid_kind, @kinds}}

  defp check_name_free(ctx, name) do
    case Arca.VaultStorage.get_by_name(Context.actor(ctx), name) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :name_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_any(ctx, id), do: Arca.VaultStorage.get(Context.actor(ctx), id)

  defp get_living(ctx, id) do
    case get_any(ctx, id) do
      {:ok, %{status: "tombstoned"}} -> {:error, :not_found}
      other -> other
    end
  end

  defp get_rotatable(ctx, id) do
    case get_any(ctx, id) do
      {:ok, %{status: status} = entry} when status in ["active", "needs_reauth"] ->
        {:ok, entry}

      {:ok, %{status: status}} ->
        {:error, {:entry_unavailable, status}}

      other ->
        other
    end
  end

  defp check_schema(entry, fields) do
    declared = decode_list(entry.field_names, "field_names")
    provided = Enum.sort(Map.keys(fields))

    if provided == declared do
      :ok
    else
      {:error, :schema_change_requires_rebind}
    end
  end

  # `Sanctum.Cipher.encrypt/2` raises rather than returning errors — boot
  # validates the keyring, so a raise here is a mid-flight misconfiguration
  # (a rotated-away label, a truncated key). The request path answers with
  # a typed refusal instead of a bare MatchError taking the caller down.
  defp seal(json, aad) do
    Sanctum.Cipher.encrypt(json, aad)
  rescue
    e ->
      Logger.error("[Sanctum.Vault] sealing failed: #{Exception.message(e)}")
      {:error, :seal_failed}
  end

  # The AAD's athanor is the CALLER's, not the row's. The facade has
  # already refused any row outside the caller's athanor, and binding the
  # ciphertext to the caller's tenant means a row that reached a foreign
  # context by any path fails to unseal rather than decrypting under the
  # tenant it brought with it.
  defp unseal(%Context{} = ctx, entry) do
    aad = CipherAAD.vault_entry(Context.athanor!(ctx), entry.id, entry.provider_hint)

    with sealed when is_binary(sealed) <- entry.sealed_payload,
         {:ok, plaintext} <- Sanctum.Cipher.decrypt(sealed, aad) do
      Payload.decode(plaintext)
    else
      _ -> {:error, :unseal_failed}
    end
  end

  # What the rotated payload's oauth block becomes. A supplied bundle wins;
  # otherwise the current bundle is kept — rotating the secret fields must
  # not silently revoke a live grant.
  defp rotation_oauth(%{"v" => 2} = current, nil), do: {:ok, current["oauth"]}
  defp rotation_oauth(%{"v" => 2}, oauth) when is_map(oauth), do: {:ok, oauth}

  # Total, like every validator here: a non-map :oauth is a typed refusal,
  # not a FunctionClauseError out of a public API.
  defp rotation_oauth(%{"v" => 2}, _oauth),
    do: {:error, "oauth must be an object when supplied"}

  defp put_change(changes, key, params, encoder) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(changes, key, encoder.(value))
      :error -> changes
    end
  end

  defp encode_optional_map(nil), do: nil
  defp encode_optional_map(map) when is_map(map), do: Jason.encode!(map)
  defp encode_optional_map(json) when is_binary(json), do: json

  defp encode_optional_list(nil), do: nil
  defp encode_optional_list(list) when is_list(list), do: Jason.encode!(list)
  defp encode_optional_list(json) when is_binary(json), do: json

  defp decode_list(nil, _field), do: []

  defp decode_list(json, field) when is_binary(json) do
    case decode_stored(json, [], field) do
      list when is_list(list) -> Enum.sort(Enum.filter(list, &is_binary/1))
      _ -> []
    end
  end

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes. `decode_list/2`
  # answers nil itself.
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Cyfr.Json.decode(json) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Sanctum.Vault] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  # One announcement, two topics: the athanor's own, and a deliberately
  # global one (the "sanctum:sessions" precedent) so singletons that
  # cannot know every tenant topic — the external-MCP reconciler — still
  # see every mutation. Both are the host bridge's to broadcast.
  defp broadcast(ctx, entry_id, verb, %{name: _} = meta),
    do: Sanctum.Telemetry.vault_entry_changed(Context.athanor!(ctx), entry_id, verb, meta)
end
