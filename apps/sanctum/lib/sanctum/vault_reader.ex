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
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.Context
  alias Cyfr.JCS

  @type vault_resource :: %{
          required(:entry_id) => String.t(),
          required(:binding_digest) => String.t(),
          optional(:projection) => %{fields: [String.t()], scopes: [String.t()]} | nil
        }

  @typedoc """
  What `revisions/2` answers for an active entry: the payload revision a
  rotation moves, and the binding digest a rebind moves.
  """
  @type revision :: {non_neg_integer(), String.t() | nil}

  @type error ::
          :anonymous_denied
          | :not_found
          | {:entry_unavailable, String.t()}
          | :binding_mismatch
          | :unseal_failed
          | :invalid_payload
          | {:invalid_payload, atom() | tuple()}
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

  For the external MCP servers' credentials, which have **no consent edge**:
  a `vault:<name>` template in an http server's headers or a stdio backend's
  env maps to a single-field entry. The binding is the server definition
  itself, and only an interactive session writes one (`mcp_servers.create`
  and `update` declare `consent: :interactive`). No binding-digest check
  (there is no consent digest to compare against) and no projection; the
  caller enforces its own single-value policy. This is host code, not guest
  code, so there is no anonymous caller to reject. Fails closed on a
  missing, non-`active`, or unreadable entry, exactly as the consent path
  does.
  """
  @spec unseal_by_name(String.t(), String.t()) ::
          {:ok, %{String.t() => String.t()}} | {:error, error()}
  def unseal_by_name(athanor_id, name) when is_binary(athanor_id) and is_binary(name) do
    actor = tenant_actor(athanor_id)

    with {:ok, entry} <- Arca.VaultStorage.get_by_name(actor, name),
         :ok <- check_status(entry),
         {:ok, %{"v" => 2, "fields" => fields}} <- unseal_material(actor, entry) do
      Arca.VaultStorage.touch_last_used(actor, entry.id)
      {:ok, fields}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The revision token of each named entry of `athanor_id`, metadata only:
  nothing is unsealed and no use is recorded.

  An active entry answers `{payload_rev, binding_digest}` — its payload
  revision, which a rotation moves, paired with the binding digest derived
  from its binding fields, which a rebind moves — so the token changes on
  either. One that is missing, tombstoned or otherwise not `active`
  answers `:inactive`. A holder of material resolved by name
  (`unseal_by_name/2`) compares these with the tokens it resolved under,
  so a rotation, rebind or revocation whose announcement never reached it
  is still found. A store that cannot answer refuses whole, so an outage
  never reads as a changed credential.
  """
  @spec revisions(String.t(), [String.t()]) ::
          {:ok, %{String.t() => revision() | :inactive}} | {:error, term()}
  def revisions(athanor_id, names) when is_binary(athanor_id) and is_list(names) do
    actor = tenant_actor(athanor_id)

    names
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, acc} ->
      case Arca.VaultStorage.get_by_name(actor, name) do
        {:ok, %{status: "active"} = entry} ->
          {:cont, {:ok, Map.put(acc, name, revision(entry))}}

        {:ok, _not_active} ->
          {:cont, {:ok, Map.put(acc, name, :inactive)}}

        {:error, :not_found} ->
          {:cont, {:ok, Map.put(acc, name, :inactive)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # A binding whose fields cannot be read derives no digest; the token
  # still moves with the payload, and a later readable binding moves it.
  defp revision(entry) do
    case binding_digest(entry) do
      {:ok, digest} -> {entry.payload_rev, digest}
      {:error, _} -> {entry.payload_rev, nil}
    end
  end

  @doc """
  Derive an entry's binding digest from its binding fields.

  `JCS` over the provider hint, sorted field names, endpoints and scopes —
  the identity of *what this credential talks to*, excluding the material
  (rotation must not re-consent) and including everything a rebind edit
  would change.
  """
  @spec binding_digest(Arca.VaultStorage.entry() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def binding_digest(entry) do
    input = %{
      "provider_hint" => entry.provider_hint || "",
      "field_names" => decode_list(entry.field_names, "field_names"),
      "oauth_endpoints" => decode_map(entry.oauth_endpoints, "oauth_endpoints"),
      "oauth_scopes" => decode_list(entry.oauth_scopes, "oauth_scopes")
    }

    JCS.hash(input)
  end

  defp load_and_unseal(%Context{anonymous: true}, _resource), do: {:error, :anonymous_denied}

  defp load_and_unseal(%Context{} = ctx, %{entry_id: entry_id} = resource) do
    actor = Context.actor(ctx)

    with {:ok, entry} <- Arca.VaultStorage.get(actor, entry_id),
         :ok <- check_status(entry),
         :ok <- check_binding(entry, resource),
         {:ok, payload} <- unseal_material(actor, entry) do
      Arca.VaultStorage.touch_last_used(actor, entry.id)
      {:ok, entry, payload}
    end
  end

  @doc """
  Checks whether an active vault entry’s binding digest matches the
  consent binding, using the same read checks as `load_and_unseal/2`.
  """
  @spec usable(String.t(), String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :not_found}
          | {:error, {:entry_unavailable, name :: String.t() | nil, status :: String.t()}}
          | {:error, {:binding_mismatch, name :: String.t() | nil}}
  def usable(athanor_id, entry_id, binding_digest) when is_binary(binding_digest) do
    case Arca.VaultStorage.get(tenant_actor(athanor_id), entry_id) do
      {:ok, entry} ->
        with :ok <- check_status(entry),
             :ok <- check_binding(entry, %{binding_digest: binding_digest}) do
          {:ok, entry}
        else
          {:error, {:entry_unavailable, status}} ->
            {:error, {:entry_unavailable, entry.name, status}}

          {:error, :binding_mismatch} ->
            {:error, {:binding_mismatch, entry.name}}
        end

      {:error, _} ->
        {:error, :not_found}
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

  # The AAD's athanor is the CALLER's, taken from the actor that read the
  # row and never from the row itself. The facade has already refused any
  # row outside that athanor, and binding the ciphertext to the reader's
  # tenant means a row that reached a foreign context by any path fails to
  # unseal instead of decrypting under the tenant it brought with it.
  defp unseal_material(%Cyfr.Actor{athanor_id: athanor_id}, %{sealed_payload: sealed} = entry)
       when is_binary(sealed) do
    aad = CipherAAD.vault_entry(athanor_id, entry.id, entry.provider_hint)

    case Sanctum.Cipher.decrypt(sealed, aad) do
      {:ok, plaintext} -> decode_payload(plaintext)
      {:error, _} -> {:error, :unseal_failed}
    end
  end

  defp unseal_material(%Cyfr.Actor{}, _entry), do: {:error, :unseal_failed}

  # The one place a bare athanor becomes an actor, and it is inside the
  # layer that owns tenancy. `usable/3` and `unseal_by_name/2` are reached
  # by host-side callers that hold a resolved tenant and no context — the
  # external-MCP reconciler resolving a `vault:<name>` template, the
  # consent planner checking an edge — so what they get is the narrowest
  # actor there is: this athanor, no person, athanor scope, no system
  # authority. Nothing here widens a caller; it names the tenant it was
  # already given.
  defp tenant_actor(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    %Cyfr.Actor{athanor_id: athanor_id}
  end

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

  # Exclude decrypted material from error tuples.
  defp resolve_secrets(_ctx, _entry, _payload, _fields), do: {:error, :invalid_payload}

  # ---------------------------------------------------------------------------
  # OAuth
  # ---------------------------------------------------------------------------

  # An unset provider_hint is deliberately not validated: the hint is an
  # optional pin, and an entry that never declared one serves any provider
  # the consent walk already authorized.
  defp check_provider_hint(%{provider_hint: hint}, _provider) when hint in [nil, ""], do: :ok

  defp check_provider_hint(%{provider_hint: hint}, provider) when hint == provider,
    do: :ok

  defp check_provider_hint(_entry, provider), do: {:error, {:provider_mismatch, provider}}

  # A scope projection narrows an OAuth grant, but the provider cannot
  # attenuate an issued token — so a projection asking for scopes the
  # entry was never authorized for is unsatisfiable and refused, never
  # silently served with a broader token.
  defp check_scope_projection(entry, %{projection: %{scopes: scopes}})
       when is_list(scopes) and scopes != [] do
    case scopes -- decode_list(entry.oauth_scopes, "oauth_scopes") do
      [] -> :ok
      missing -> {:error, {:scope_projection_unsatisfiable, Enum.sort(missing)}}
    end
  end

  defp check_scope_projection(_entry, _resource), do: :ok

  defp resolve_oauth(%Context{} = ctx, entry, %{"v" => 2} = payload, provider) do
    case payload["oauth"] do
      %{} = oauth -> Sanctum.Vault.OAuth.dispense(Context.actor(ctx), entry, oauth, provider)
      _ -> {:error, :no_oauth_material}
    end
  end

  defp resolve_oauth(_ctx, _entry, _payload, _provider), do: {:error, :invalid_payload}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp projection_fields(%{projection: %{fields: fields}}) when is_list(fields), do: fields
  defp projection_fields(_), do: :all

  defp decode_list(nil, _field), do: []

  defp decode_list(json, field) when is_binary(json) do
    case decode_stored(json, [], field) do
      list when is_list(list) -> Enum.sort(Enum.filter(list, &is_binary/1))
      _ -> []
    end
  end

  defp decode_map(nil, _field), do: %{}

  defp decode_map(json, field) when is_binary(json) do
    case decode_stored(json, %{}, field) do
      %{} = map -> map
      _ -> %{}
    end
  end

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes. `decode_list/2`
  # and `decode_map/2` answer nil themselves.
  defp decode_stored("", default, _field), do: default

  defp decode_stored(json, default, field) when is_binary(json) do
    case Cyfr.Json.decode(json) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Sanctum.VaultReader] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end
end
