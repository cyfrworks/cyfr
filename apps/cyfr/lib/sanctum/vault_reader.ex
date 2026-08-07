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

  ## The legacy pointer

  Until credential re-entry, a sealed payload may be a **pointer** into
  the legacy stores rather than material:

      {"v":1,"legacy":{"secrets":[{"name":"KEY","scope":"project"}],
                       "oauth":[{"component_ref":"catalyst:local.gmail",
                                 "provider":"google"}]}}

  Pointer resolution reads `Arca.SecretStorage` and decrypts directly —
  deliberately not through `Sanctum.Secrets`' permission-gated grant
  plane, which serves a different authorization model. OAuth pointers
  resolve through `Sanctum.OAuth.get_access_token/3` by the pointer's own
  name-level ref, so the refresh single-flight lock serializes with any
  legacy caller of the same bundle.
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
         :ok <- check_provider_hint(entry, provider) do
      resolve_oauth(ctx, payload, provider)
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
    with {:ok, entry} <- Arca.VaultStorage.get(ctx.org_id, entry_id),
         :ok <- check_status(entry),
         :ok <- check_binding(entry, resource),
         {:ok, payload} <- unseal(ctx, entry) do
      Arca.VaultStorage.touch_last_used(ctx.org_id, entry.id)
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

  defp unseal(ctx, %{sealed_payload: sealed} = entry) when is_binary(sealed) do
    aad = CipherAAD.vault_entry(ctx.org_id, entry.project_id, entry.id, entry.provider_hint)

    case Sanctum.Cipher.decrypt(sealed, aad) do
      {:ok, plaintext} -> decode_payload(plaintext)
      {:error, _} -> {:error, :unseal_failed}
    end
  end

  defp unseal(_ctx, _entry), do: {:error, :unseal_failed}

  defp decode_payload(plaintext) do
    case Jason.decode(plaintext) do
      {:ok, %{"v" => 1} = payload} -> {:ok, payload}
      {:ok, other} -> {:error, {:invalid_payload, other}}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Secret material
  # ---------------------------------------------------------------------------

  defp resolve_secrets(ctx, _entry, %{"legacy" => %{"secrets" => pointers}}, fields)
       when is_list(pointers) do
    pointers
    |> Enum.filter(fn p -> fields == :all or p["name"] in fields end)
    |> Enum.reduce_while({:ok, %{}}, fn pointer, {:ok, acc} ->
      case resolve_legacy_secret(ctx, pointer) do
        {:ok, name, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_secrets(_ctx, _entry, %{"legacy" => _}, _fields), do: {:ok, %{}}

  defp resolve_secrets(_ctx, _entry, payload, _fields), do: {:error, {:invalid_payload, payload}}

  defp resolve_legacy_secret(ctx, %{"name" => name, "scope" => scope})
       when is_binary(name) and is_binary(scope) do
    case Arca.SecretStorage.get_secret(name, scope, ctx.org_id, ctx.project_id) do
      {:ok, encrypted} ->
        aad = CipherAAD.secret(scope, ctx.org_id, ctx.project_id, name)

        case Sanctum.Cipher.decrypt(encrypted, aad) do
          {:ok, value} -> {:ok, name, value}
          {:error, _} -> {:error, {:legacy_secret_unreadable, name}}
        end

      {:error, _} ->
        {:error, {:legacy_secret_missing, name}}
    end
  end

  defp resolve_legacy_secret(_ctx, pointer), do: {:error, {:invalid_payload, pointer}}

  # ---------------------------------------------------------------------------
  # OAuth
  # ---------------------------------------------------------------------------

  defp check_provider_hint(%{provider_hint: hint}, provider)
       when hint in [nil, "", "legacy"],
       do: check_provider_hint_ok(provider)

  defp check_provider_hint(%{provider_hint: hint}, provider) when hint == provider,
    do: :ok

  defp check_provider_hint(_entry, provider), do: {:error, {:provider_mismatch, provider}}

  defp check_provider_hint_ok(_provider), do: :ok

  defp resolve_oauth(ctx, %{"legacy" => %{"oauth" => pointers}}, provider)
       when is_list(pointers) do
    case Enum.find(pointers, fn p -> p["provider"] == provider end) do
      %{"component_ref" => ref} when is_binary(ref) ->
        Sanctum.OAuth.get_access_token(ctx, ref, provider)

      _ ->
        {:error, {:provider_mismatch, provider}}
    end
  end

  defp resolve_oauth(_ctx, payload, _provider), do: {:error, {:invalid_payload, payload}}

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
