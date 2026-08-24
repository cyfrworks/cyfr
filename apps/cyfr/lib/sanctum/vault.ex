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
  """

  alias Sanctum.CipherAAD
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Vault.Payload
  alias Sanctum.VaultReader

  @kinds ~w(api_key oauth bundle)

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
    with {:ok, rows} <- Arca.VaultStorage.list(Context.athanor!(ctx)) do
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
         {:ok, json} <- Payload.encode_material(fields, Map.get(params, :oauth)) do
      id = Emissary.UUID7.generate_id("vlt")
      hint = Map.get(params, :provider_hint, "")
      aad = CipherAAD.vault_entry(Context.athanor!(ctx), id, hint)
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

      attrs = %{
        id: id,
        athanor_id: Context.athanor!(ctx),
        name: name,
        kind: kind,
        provider_hint: hint,
        provenance: Map.get(params, :provenance, "user"),
        field_names: Jason.encode!(Enum.sort(Map.keys(fields))),
        oauth_endpoints: encode_optional_map(Map.get(params, :oauth_endpoints)),
        oauth_scopes: encode_optional_list(Map.get(params, :oauth_scopes)),
        status: "active",
        sealed_payload: sealed
      }

      with {:ok, entry} <- Arca.VaultStorage.put(attrs),
           {:ok, digest} <- VaultReader.binding_digest(entry),
           :ok <-
             Arca.VaultStorage.update_binding(Context.athanor!(ctx), id, %{
               binding_digest: digest
             }) do
        broadcast(ctx, id, :create)
        {:ok, view(%{entry | binding_digest: digest})}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Rename
  # ---------------------------------------------------------------------------

  @doc "Rename the mutable label. Identity, bindings and consents are untouched."
  @spec rename(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def rename(%Context{} = ctx, id, new_name) when is_binary(new_name) and new_name != "" do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, _entry} <- get_living(ctx, id),
         :ok <- check_name_free(ctx, new_name) do
      Arca.VaultStorage.update_meta(Context.athanor!(ctx), id, %{name: new_name})
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

  A retired v1 pointer row cannot rotate — its payload no longer decodes
  (`:legacy_pointer_retired`); recreate the entry with real material.
  """
  @spec rotate(Context.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def rotate(%Context{} = ctx, %{id: id, fields: fields, expected_payload_rev: expected} = params)
      when is_map(fields) and is_integer(expected) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, entry} <- get_rotatable(ctx, id),
         :ok <- check_schema(entry, fields),
         {:ok, current} <- unseal(entry),
         {:ok, oauth} <- rotation_oauth(current, Map.get(params, :oauth)),
         {:ok, json} <- Payload.encode_material(fields, oauth) do
      aad = CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)
      {:ok, sealed} = Sanctum.Cipher.encrypt(json, aad)

      case Arca.VaultStorage.rotate_payload(Context.athanor!(ctx), id, expected, sealed) do
        :ok ->
          if entry.status == "needs_reauth" do
            Arca.VaultStorage.set_status(Context.athanor!(ctx), id, "active")
          end

          broadcast(ctx, id, :rotate)
          {:ok, expected + 1}

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
        rebound = Map.merge(Map.from_struct(entry), changes)

        with {:ok, digest} <- VaultReader.binding_digest(rebound),
             :ok <-
               Arca.VaultStorage.update_binding(
                 Context.athanor!(ctx),
                 id,
                 Map.put(changes, :binding_digest, digest)
               ),
             {:ok, affected} <-
               Arca.ConsentStorage.head_profiles_referencing(Context.athanor!(ctx), id) do
          Enum.each(affected, fn profile_id ->
            Arca.ProfileStorage.set_status(Context.athanor!(ctx), profile_id, "needs_consent")
          end)

          broadcast(ctx, id, :rebind)
          {:ok, %{binding_digest: digest, affected: Enum.sort(affected)}}
        end
      end
    end
  end

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
         {:ok, _entry} <- get_living(ctx, id),
         :ok <- Arca.VaultStorage.set_status(Context.athanor!(ctx), id, "revoked"),
         {:ok, affected} <-
           Arca.ConsentStorage.head_profiles_referencing(Context.athanor!(ctx), id) do
      broadcast(ctx, id, :revoke)
      {:ok, %{affected: Enum.sort(affected)}}
    end
  end

  @doc "Tombstone the entry and erase its sealed material. The name frees up."
  @spec delete(Context.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, id) do
    with {:ok, :interactive} <- Authz.authorize_interactive(ctx),
         {:ok, _entry} <- get_any(ctx, id),
         :ok <- Arca.VaultStorage.tombstone(Context.athanor!(ctx), id) do
      broadcast(ctx, id, :delete)
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
      field_names: decode_list(entry.field_names),
      oauth_scopes: decode_list(entry.oauth_scopes),
      payload_rev: entry.payload_rev,
      last_used_at: entry.last_used_at
    }
  end

  defp required_name(%{name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp required_name(_), do: {:error, :name_required}

  defp required_kind(%{kind: kind}) when kind in @kinds, do: {:ok, kind}
  defp required_kind(_), do: {:error, {:invalid_kind, @kinds}}

  defp check_name_free(ctx, name) do
    case Arca.VaultStorage.get_by_name(Context.athanor!(ctx), name) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :name_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_any(ctx, id), do: Arca.VaultStorage.get(Context.athanor!(ctx), id)

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
    declared = decode_list(entry.field_names)
    provided = Enum.sort(Map.keys(fields))

    if provided == declared do
      :ok
    else
      {:error, :schema_change_requires_rebind}
    end
  end

  defp unseal(entry) do
    aad = CipherAAD.vault_entry(entry.athanor_id, entry.id, entry.provider_hint)

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

  defp decode_list(nil), do: []

  defp decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.sort(Enum.filter(list, &is_binary/1))
      _ -> []
    end
  end

  defp broadcast(ctx, entry_id, verb) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      Prism.Topics.vault_changed(ctx),
      {:vault_entry_changed, entry_id, verb}
    )

    # A second, deliberately global signal (the "sanctum:sessions"
    # precedent) so singletons that cannot know every tenant topic —
    # the external-MCP reconciler — still see every mutation.
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      Prism.Topics.vault_changed_global(),
      {:vault_entry_changed_global, Context.athanor!(ctx), entry_id, verb}
    )
  end
end
