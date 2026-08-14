# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.VaultReader do
  @moduledoc """
  Resolve a consent edge's vault resource into credential material.

  This is the **only** path by which an authority execution reaches
  credentials — the callee-keyed grant plane is never consulted. Every
  check fails closed, in order:

  1. the caller is not anonymous (a public invocation must never reach
     operator credentials, whatever its edges say)
  2. the entry exists in the caller's tenant and is `active`
  3. the binding digest **derived from the row's binding fields** equals
     the consent's copy — the stored column is a cache, never an
     authority, so a write path that edited endpoints without recomputing
     it cannot pass
  4. the payload unseals under the entry's AEAD (a tampered pointer fails
     decrypt)
  5. the projection filters what the edge may see; nothing outside
     `projection.fields` leaves this module

  ## Payload versions

  A v2 payload (`Sanctum.Vault.Payload`) carries the material itself:
  secret fields resolve from the sealed `fields` map, OAuth tokens
  dispense through `Sanctum.Vault.OAuth` with refresh single-flighted
  per entry. An OAuth `projection.scopes` is enforced at dispense: the
  requested scopes must be a subset of what the entry was authorized
  for, because an issued token cannot be attenuated after the fact.

  A retired pre-capability-model v1 pointer payload decodes to
  `{:error, :legacy_pointer_retired}` inside `Sanctum.Vault.Payload` itself —
  nothing here needs to know that document shape existed.
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.Context
  alias Sanctum.JCS

  @type vault_resource :: %{
          required(:entry_id) => String.t(),
          required(:binding_digest) => String.t(),
          optional(:projection) => %{fields: [String.t()], scopes: [String.t()]} | nil
        }

  @type error ::
          :anonymous_denied
          | :not_found
          | {:entry_unavailable, String.t()}
          | :binding_mismatch
          | :unseal_failed
          | {:invalid_payload, term()}
          | {:provider_mismatch, String.t()}
          | {:scope_projection_unsatisfiable, [String.t()]}
          | :no_oauth_material
          | term()

  @doc """
  Resolve the entry's secret material as a name → value map, projected.
  """
  @spec fetch(Context.t(), vault_resource()) ::
          {:ok, %{String.t() => String.t()}} | {:error, error()}
  def fetch(%Context{} = ctx, resource) do
    with {:ok, entry, payload} <- load_and_unseal(ctx, resource) do
      resolve_secrets(ctx, entry, payload, projection_fields(resource))
    end
  end

  @doc """
  Resolve an OAuth access token for `provider` from the entry.

  The requested provider must match both the entry's provider hint (when
  set) and a pointer entry — a consent for one provider can never dispense
  another's token.
  """
  @spec oauth_token(Context.t(), vault_resource(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def oauth_token(%Context{} = ctx, resource, provider) when is_binary(provider) do
    with {:ok, entry, payload} <- load_and_unseal(ctx, resource),
         :ok <- check_provider_hint(entry, provider),
         :ok <- check_scope_projection(entry, resource) do
      resolve_oauth(ctx, entry, payload, provider)
    end
  end

  @doc """
  Unseal an entry's v2 material by name, returning `%{field => value}`.

  For host-side credential resolution that has **no consent edge** — the
  external-MCP header plane, where a `vault:<name>` reference maps to a
  single-field entry. Deliberately no binding-digest check (there is no consent
  digest to compare against) and no projection; the caller enforces its own
  single-value policy. This is host code, not guest code, so there is no
  anonymous caller to reject. Fails closed on a missing, non-`active`, or v1
  entry, exactly as the consent path does.
  """
  @spec unseal_by_name(String.t(), String.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, error()}
  def unseal_by_name(org_id, project_id, name)
      when is_binary(org_id) and is_binary(project_id) and is_binary(name) do
    with {:ok, entry} <- Arca.VaultStorage.get_by_name(org_id, project_id, name),
         :ok <- check_status(entry),
         {:ok, %{"v" => 2, "fields" => fields}} <- unseal_material(org_id, entry) do
      Arca.VaultStorage.touch_last_used(org_id, project_id, entry.id)
      {:ok, fields}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Derive an entry's binding digest from its binding fields.

  `JCS` over the provider hint, sorted field names, endpoints and scopes —
  the identity of *what this credential talks to*, excluding the material
  (rotation must not re-consent) and including everything a rebind edit
  would change.
  """
  @spec binding_digest(Arca.Schemas.VaultEntry.t() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def binding_digest(entry) do
    input = %{
      "provider_hint" => entry.provider_hint || "",
      "field_names" => decode_list(entry.field_names),
      "oauth_endpoints" => decode_map(entry.oauth_endpoints),
      "oauth_scopes" => decode_list(entry.oauth_scopes)
    }

    JCS.hash(input)
  end

  defp load_and_unseal(%Context{anonymous: true}, _resource), do: {:error, :anonymous_denied}

  defp load_and_unseal(%Context{} = ctx, %{entry_id: entry_id} = resource) do
    with {:ok, entry} <- Arca.VaultStorage.get(ctx.org_id, ctx.project_id, entry_id),
         :ok <- check_status(entry),
         :ok <- check_binding(entry, resource),
         {:ok, payload} <- unseal(ctx, entry) do
      Arca.VaultStorage.touch_last_used(ctx.org_id, ctx.project_id, entry.id)
      {:ok, entry, payload}
    end
  end

  defp check_status(%{status: "active"}), do: :ok
  defp check_status(%{status: status}), do: {:error, {:entry_unavailable, status}}

  defp check_binding(entry, %{binding_digest: expected}) when is_binary(expected) do
    case binding_digest(entry) do
      {:ok, derived} ->
        if Plug.Crypto.secure_compare(derived, expected) do
          :ok
        else
          Logger.warning(
            "[Sanctum.VaultReader] binding digest mismatch for entry #{entry.id} — " <>
              "the entry was rebound after this consent"
          )

          {:error, :binding_mismatch}
        end

      {:error, _} ->
        {:error, :binding_mismatch}
    end
  end

  defp check_binding(_entry, _resource), do: {:error, :binding_mismatch}

  defp unseal(ctx, entry), do: unseal_material(ctx.org_id, entry)

  defp unseal_material(org_id, %{sealed_payload: sealed} = entry) when is_binary(sealed) do
    aad = CipherAAD.vault_entry(org_id, entry.project_id, entry.id, entry.provider_hint)

    case Sanctum.Cipher.decrypt(sealed, aad) do
      {:ok, plaintext} -> decode_payload(plaintext)
      {:error, _} -> {:error, :unseal_failed}
    end
  end

  defp unseal_material(_org_id, _entry), do: {:error, :unseal_failed}

  defp decode_payload(plaintext), do: Sanctum.Vault.Payload.decode(plaintext)

  # ---------------------------------------------------------------------------
  # Secret material
  # ---------------------------------------------------------------------------

  defp resolve_secrets(_ctx, _entry, %{"v" => 2, "fields" => material}, fields) do
    projected =
      material
      |> Enum.filter(fn {name, _value} -> fields == :all or name in fields end)
      |> Map.new()

    {:ok, projected}
  end

  defp resolve_secrets(_ctx, _entry, payload, _fields), do: {:error, {:invalid_payload, payload}}

  # ---------------------------------------------------------------------------
  # OAuth
  # ---------------------------------------------------------------------------

  defp check_provider_hint(%{provider_hint: hint}, provider)
       when hint in [nil, ""],
       do: check_provider_hint_ok(provider)

  defp check_provider_hint(%{provider_hint: hint}, provider) when hint == provider,
    do: :ok

  defp check_provider_hint(_entry, provider), do: {:error, {:provider_mismatch, provider}}

  defp check_provider_hint_ok(_provider), do: :ok

  # A scope projection narrows an OAuth grant, but the provider cannot
  # attenuate an issued token — so a projection asking for scopes the
  # entry was never authorized for is unsatisfiable and refused, never
  # silently served with a broader token.
  defp check_scope_projection(entry, %{projection: %{scopes: scopes}})
       when is_list(scopes) and scopes != [] do
    case scopes -- decode_list(entry.oauth_scopes) do
      [] -> :ok
      missing -> {:error, {:scope_projection_unsatisfiable, Enum.sort(missing)}}
    end
  end

  defp check_scope_projection(_entry, _resource), do: :ok

  defp resolve_oauth(_ctx, entry, %{"v" => 2} = payload, provider) do
    case payload["oauth"] do
      %{} = oauth -> Sanctum.Vault.OAuth.dispense(entry, oauth, provider)
      _ -> {:error, :no_oauth_material}
    end
  end

  defp resolve_oauth(_ctx, _entry, payload, _provider), do: {:error, {:invalid_payload, payload}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp projection_fields(%{projection: %{fields: fields}}) when is_list(fields), do: fields
  defp projection_fields(_), do: :all

  defp decode_list(nil), do: []

  defp decode_list(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> Enum.sort(Enum.filter(list, &is_binary/1))
      _ -> []
    end
  end

  defp decode_map(nil), do: %{}

  defp decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end
end
