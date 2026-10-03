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
  2. the edge's projection names what it reads: a key or bundle edge its
     non-empty `fields` (`fetch/2`), an OAuth edge its non-empty `scopes`
     (`oauth_token/3`). An edge without one — including every edge stored
     before projections named their fields — is corrupt and dispenses
     nothing; re-consenting to the component's current version writes a
     named projection
  3. the entry exists in the caller's tenant and is `active`
  4. the binding digest **derived from the row's binding fields** equals
     the consent's copy — the stored column is a cache, never an
     authority, so a write path that edited endpoints without recomputing
     it cannot pass
  5. the payload unseals under the entry's AEAD (a tampered pointer fails
     decrypt)
  6. every projected field is present in the entry's material, and
     nothing outside `projection.fields` leaves this module: a field the
     entry lacks refuses the whole resolution, never a partial projection

  ## The payload

  The sealed payload (`Sanctum.Vault.Payload`) carries the material
  itself: secret fields resolve from the sealed `fields` map, OAuth tokens
  dispense through `Sanctum.Vault.OAuth` with refresh single-flighted per
  entry. An OAuth `projection.scopes` is enforced at dispense: the
  requested scopes must be a subset of what the entry was authorized for,
  and a projection naming fewer is answered only by a token a refresh the
  provider attenuates obtained for exactly those scopes, never by the
  entry's broader token (`Sanctum.Vault.OAuth.dispense/5`).
  """

  require Logger

  alias Sanctum.CipherAAD
  alias Sanctum.Context
  alias Prima.JCS

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
          | :scope_not_attenuable
          | :no_oauth_material
          | :corrupt
          | {:missing_field, String.t()}
          | term()

  @doc """
  Resolve the entry's secret material as a name → value map, projected.

  The edge's `projection.fields` is required: an edge without a non-empty
  field list answers `{:error, :corrupt}` before the entry is read, and a
  projected field the entry's material lacks answers
  `{:error, {:missing_field, name}}`. Either way nothing is dispensed.
  """
  @spec fetch(Context.t(), vault_resource()) ::
          {:ok, %{String.t() => String.t()}} | {:error, error()}
  def fetch(%Context{anonymous: true}, _resource), do: {:error, :anonymous_denied}

  def fetch(%Context{} = ctx, resource) do
    with {:ok, fields} <- projection_fields(resource),
         {:ok, entry, payload} <- load_and_unseal(ctx, resource) do
      resolve_secrets(ctx, entry, payload, fields)
    end
  end

  @doc """
  Resolve an OAuth access token for `provider` from the entry.

  The edge's projection is its `scopes`: an edge naming none is corrupt
  (`{:error, :corrupt}`) unless it names fields, which makes it a key or
  bundle edge that carries no OAuth grant (`{:error, :no_oauth_material}`);
  either way the entry is not read. The requested provider must be
  exactly the entry's provider hint, and an entry naming none dispenses
  for no provider (`{:provider_mismatch, provider}`) — a consent for one
  provider can never dispense another's token. Scopes the
  entry lacks are refused `{:scope_projection_unsatisfiable, missing}`,
  and fewer than it holds are dispensed only where its provider
  attenuates a refresh (`:scope_not_attenuable` otherwise).
  """
  @spec oauth_token(Context.t(), vault_resource(), String.t()) ::
          {:ok, String.t()} | {:error, error()}
  def oauth_token(%Context{anonymous: true}, _resource, provider) when is_binary(provider),
    do: {:error, :anonymous_denied}

  def oauth_token(%Context{} = ctx, resource, provider) when is_binary(provider) do
    with :ok <- oauth_projection(resource),
         {:ok, entry, payload} <- load_and_unseal(ctx, resource),
         :ok <- check_provider_hint(entry, provider),
         :ok <- check_scope_projection(entry, resource) do
      resolve_oauth(ctx, entry, payload, resource, provider)
    end
  end

  @doc """
  Unseal an entry's material by name, returning `%{field => value}`.

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
         {:ok, %{"v" => 3, "fields" => fields}} <- unseal_material(actor, entry) do
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
  defp unseal_material(%Prima.Actor{athanor_id: athanor_id}, %{sealed_payload: sealed} = entry)
       when is_binary(sealed) do
    aad = CipherAAD.vault_entry(athanor_id, entry.id, entry.provider_hint)

    case Sanctum.Cipher.decrypt(sealed, aad) do
      {:ok, plaintext} -> decode_payload(plaintext)
      {:error, _} -> {:error, :unseal_failed}
    end
  end

  defp unseal_material(%Prima.Actor{}, _entry), do: {:error, :unseal_failed}

  # The one place a bare athanor becomes an actor, and it is inside the
  # layer that owns tenancy. `usable/3` and `unseal_by_name/2` are reached
  # by host-side callers that hold a resolved tenant and no context — the
  # external-MCP reconciler resolving a `vault:<name>` template, the
  # consent planner checking an edge — so what they get is the narrowest
  # actor there is: this athanor, no person, athanor scope, no system
  # authority. Nothing here widens a caller; it names the tenant it was
  # already given.
  defp tenant_actor(athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    %Prima.Actor{athanor_id: athanor_id}
  end

  defp decode_payload(plaintext), do: Sanctum.Vault.Payload.decode(plaintext)

  # ---------------------------------------------------------------------------
  # Secret material
  # ---------------------------------------------------------------------------

  # Every projected field must be in the material: a partial projection
  # would hand the guest less than the operator consented to without saying
  # so, so the first absent field (in sorted order) refuses the whole read.
  defp resolve_secrets(_ctx, _entry, %{"v" => 3, "fields" => material}, fields)
       when is_map(material) do
    Enum.reduce_while(fields, {:ok, %{}}, fn name, {:ok, acc} ->
      case Map.fetch(material, name) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        :error -> {:halt, {:error, {:missing_field, name}}}
      end
    end)
  end

  # Exclude decrypted material from error tuples.
  defp resolve_secrets(_ctx, _entry, _payload, _fields), do: {:error, :invalid_payload}

  # ---------------------------------------------------------------------------
  # OAuth
  # ---------------------------------------------------------------------------

  # An OAuth entry serves exactly the provider it names. An entry naming
  # none serves none: otherwise one created with its own endpoints could
  # stand in for a preset provider's, and a refresh would carry that
  # provider's client credentials to the entry's token URL.
  defp check_provider_hint(%{provider_hint: hint}, provider)
       when is_binary(hint) and hint != "" and hint == provider,
       do: :ok

  defp check_provider_hint(_entry, provider), do: {:error, {:provider_mismatch, provider}}

  # An OAuth edge names its scopes; a token is never dispensed under an
  # edge that names none, which would be the whole grant the entry holds.
  defp oauth_projection(%{projection: %{scopes: [_ | _] = scopes}} = resource) do
    if Enum.all?(scopes, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: corrupt_projection(resource)
  end

  defp oauth_projection(%{projection: %{fields: [_ | _]}}), do: {:error, :no_oauth_material}
  defp oauth_projection(resource), do: corrupt_projection(resource)

  # A projection asking for scopes the entry was never authorized for is
  # unsatisfiable and refused, never silently served with a broader token.
  # Whether fewer than the entry holds can be served is the dispense's to
  # decide, by the provider's attenuation. `oauth_projection/1` has already
  # refused an edge that names no scopes.
  defp check_scope_projection(entry, %{projection: %{scopes: scopes}}) do
    case scopes -- decode_list(entry.oauth_scopes, "oauth_scopes") do
      [] -> :ok
      missing -> {:error, {:scope_projection_unsatisfiable, Enum.sort(missing)}}
    end
  end

  defp resolve_oauth(%Context{} = ctx, entry, %{"v" => 3} = payload, resource, provider) do
    case payload["oauth"] do
      %{} = oauth ->
        Sanctum.Vault.OAuth.dispense(
          Context.actor(ctx),
          entry,
          oauth,
          provider,
          resource.projection.scopes
        )

      _ ->
        {:error, :no_oauth_material}
    end
  end

  defp resolve_oauth(_ctx, _entry, _payload, _resource, _provider),
    do: {:error, :invalid_payload}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A key or bundle projection names its fields. An absent projection, an
  # absent or non-list field list, an empty one or a non-string name is a
  # corrupt edge — never "every field" — and the refusal names its remedy.
  defp projection_fields(%{projection: %{fields: [_ | _] = fields}} = resource) do
    if Enum.all?(fields, &(is_binary(&1) and &1 != "")),
      do: {:ok, fields |> Enum.uniq() |> Enum.sort()},
      else: corrupt_projection(resource)
  end

  defp projection_fields(resource), do: corrupt_projection(resource)

  defp corrupt_projection(resource) do
    Logger.warning(
      "[Sanctum.VaultReader] the consent edge for vault entry #{entry_label(resource)} " <>
        "names no projection and dispenses nothing; " <>
        "re-consent to the component's current version"
    )

    {:error, :corrupt}
  end

  defp entry_label(%{entry_id: entry_id}) when is_binary(entry_id), do: entry_id
  defp entry_label(_resource), do: "(unnamed)"

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
    case Prima.Json.decode(json) do
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
