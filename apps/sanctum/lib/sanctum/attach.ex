# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Attach do
  @moduledoc """
  Decide the value CYFR attaches to one request a component names a
  connection on, and hand it to the control plane's transport
  (`Crucible.Host.AttachedFetch`), which alone holds it.

  `resolve/5` takes the context the run's guest calls run in, the vault
  resource of the edge the running node reached its need through, the
  need's name, the request's `uri` and `method`, and what the attempt
  knows of its own run (`t:facts/0`): the running node's reference and
  trusted digest, its root execution, and the profile and consent the run
  is pinned to. Nothing a guest's request carries stands in for any of
  them. In order, nothing touched before a check that refuses:

    1. the resource names one value (`{:ambiguous, [key]}` otherwise): an
       OAuth projection, which names its `scopes`, the token dispensed for
       them; a key or bundle projection, exactly one field; a provided
       resource, exactly one value. No value is ever guessed;
    2. the binding is live for this use (`lifetime/3`): the run's pins
       still name the profiles' heads, the head is the pinned consent, its
       `consent_vault_refs` row at the binding's key admits the use, and a
       borrowed binding answers to the lender's row as well (`:grant_expired`
       otherwise); a `once` binding is consumed here by the run's root;
    3. the material: an athanor's entry through
       `Sanctum.VaultReader.load_and_unseal/2` (active, at the consented
       binding digest, unsealed), then its destination against the
       request; an instance entry through `Sanctum.InstanceEntries`, held
       first to the digest the consent approved (`:binding_went_stale`)
       and refused for an OAuth entry (`{:entry_unavailable, "oauth"}`),
       then resolved under its audience, component policy, destination
       and caps (`Sanctum.InstanceEntries.resolve/4`); a provided value
       from the resource itself, held to its destination.

  An OAuth entry's value is the token `Sanctum.Vault.OAuth.dispense/5`
  answers for the projection's scopes. The answer's `masking` lists the
  value's raw form, which the caller joins to the attempt's masking set.
  The value is never logged and no refusal names it.
  """

  alias Prima.Authority
  alias Prima.Authority.Blob.Edge
  alias Sanctum.Context
  alias Sanctum.InstanceEntries
  alias Sanctum.VaultReader

  @typedoc """
  What the attempt knows of its own run: the running node's reference
  (`node_ref`, the version it runs) and the digest it is trusted at
  (`activation_digest`), the run's root execution, and the profile and
  consent it is pinned to.
  """
  @type facts :: %{
          required(:node_ref) => String.t(),
          required(:activation_digest) => String.t() | nil,
          required(:root_execution_id) => String.t(),
          required(:profile_id) => String.t() | nil,
          required(:consent_id) => String.t() | nil
        }

  @typedoc "The request a value is attached to: its URI and method."
  @type request :: %{uri: URI.t(), method: String.t()}

  @typedoc """
  The value to attach, the rule it is attached by, and the raw forms the
  caller masks every answer and event against.
  """
  @type answer :: %{
          value: String.t(),
          attach: Prima.Manifest.Needs.attach(),
          masking: [String.t()]
        }

  @doc """
  The value the vault resource `vault` attaches to `request` for the need
  `need`, as the module doc orders it, or why not.
  """
  @spec resolve(Context.t(), Edge.vault() | nil, String.t(), request(), facts()) ::
          {:ok, answer()} | {:error, term()}
  def resolve(%Context{} = ctx, vault, need, %{uri: %URI{}, method: method} = request, facts)
      when is_binary(need) and is_binary(method) and is_map(facts) do
    case vault do
      %{provided: %{attach: %{}} = provided} -> provided(provided, need, request)
      %{entry_id: _, attach: %{}} -> bound(ctx, vault, request, facts)
      _unbound_or_disclose_only -> {:error, :connection_not_granted}
    end
  end

  # ---------------------------------------------------------------------------
  # Provided configuration
  # ---------------------------------------------------------------------------

  # A publisher's values are public: no lifetime, no entry, no unseal.
  defp provided(%{values: values, destination: destination, attach: attach}, need, request) do
    with {:ok, value} <- one_value(values, need),
         :ok <- inside(destination, request) do
      {:ok, %{value: value, attach: attach, masking: [value]}}
    end
  end

  defp one_value(values, need) do
    case Map.values(values) do
      [value] when is_binary(value) and value != "" -> {:ok, value}
      _none_or_several -> {:error, {:ambiguous, [need]}}
    end
  end

  # ---------------------------------------------------------------------------
  # A bound entry
  # ---------------------------------------------------------------------------

  defp bound(%Context{anonymous: true}, _vault, _request, _facts),
    do: {:error, :anonymous_denied}

  defp bound(ctx, vault, request, facts) do
    use = Map.take(facts, [:root_execution_id, :profile_id, :consent_id])

    with {:ok, take} <- one_take(vault),
         :ok <- lifetime(ctx, vault, use) do
      case vault do
        %{scope: "instance"} -> instance(ctx, vault, take, request, facts)
        %{scope: "athanor"} -> athanor(ctx, vault, take, request)
        _other_scope -> {:error, :connection_not_granted}
      end
    end
  end

  # What fills the rule's `{value}`, decided on the projection alone.
  defp one_take(%{projection: %{scopes: [_ | _]}}), do: {:ok, :token}

  defp one_take(%{projection: %{fields: [field]}}) when is_binary(field),
    do: {:ok, {:field, field}}

  defp one_take(vault), do: {:error, {:ambiguous, [Map.get(vault, :binding_key)]}}

  defp athanor(ctx, vault, take, request) do
    with {:ok, entry, payload} <- VaultReader.load_and_unseal(ctx, vault),
         :ok <- inside(entry, request),
         {:ok, value} <- athanor_value(ctx, entry, payload, take, vault) do
      {:ok, %{value: value, attach: vault.attach, masking: [value]}}
    end
  end

  defp athanor_value(_ctx, _entry, payload, {:field, field}, _vault),
    do: field_value(payload, field)

  # An OAuth entry serves the provider it names and none other; one naming
  # none serves nothing.
  defp athanor_value(ctx, entry, %{"oauth" => %{} = oauth}, :token, vault) do
    case entry.provider_hint do
      hint when is_binary(hint) and hint != "" ->
        Sanctum.Vault.OAuth.dispense(
          Context.actor(ctx),
          entry,
          oauth,
          hint,
          vault.projection.scopes
        )

      _none ->
        {:error, {:provider_mismatch, ""}}
    end
  end

  defp athanor_value(_ctx, _entry, _payload, :token, _vault), do: {:error, :no_oauth_material}

  # An instance entry is the instance's: offered to the context's person,
  # held to the digest the consent approved before any claim, and resolved
  # under its live policy, destination and caps. An instance entry holds
  # no token, so an OAuth one attaches nothing.
  defp instance(ctx, vault, take, request, facts) do
    with {:ok, view} <- InstanceEntries.binding(ctx, vault.entry_id),
         :ok <- same_binding(view, vault),
         {:ok, field} <- instance_field(view, take),
         {:ok, _view, payload} <-
           InstanceEntries.resolve(ctx, vault.entry_id, request, %{
             node_ref: facts.node_ref,
             activation_digest: facts.activation_digest
           }),
         {:ok, value} <- field_value(payload, field) do
      {:ok, %{value: value, attach: vault.attach, masking: [value]}}
    end
  end

  defp same_binding(%{binding_digest: live}, %{binding_digest: approved})
       when is_binary(live) and is_binary(approved) do
    if Plug.Crypto.secure_compare(live, approved), do: :ok, else: {:error, :binding_went_stale}
  end

  defp same_binding(_view, _vault), do: {:error, :binding_went_stale}

  defp instance_field(%{kind: "oauth"}, _take), do: {:error, {:entry_unavailable, "oauth"}}
  defp instance_field(_view, :token), do: {:error, {:entry_unavailable, "oauth"}}
  defp instance_field(_view, {:field, field}), do: {:ok, field}

  defp field_value(%{"fields" => %{} = fields}, field) do
    case Map.fetch(fields, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _absent -> {:error, {:missing_field, field}}
    end
  end

  defp field_value(_payload, _field), do: {:error, :invalid_payload}

  # The request inside the destination a resource or an entry names: the
  # entry's stored text read back through the grammar, so a row whose
  # destination does not read admits nothing.
  defp inside(%Prima.Destination{} = destination, %{uri: uri, method: method}) do
    if Prima.Destination.matches?(destination, uri, method),
      do: :ok,
      else: {:error, :destination_mismatch}
  end

  defp inside(%{destination: text}, request) when is_binary(text) do
    with {:ok, %{} = map} <- Prima.Json.decode(text),
         {:ok, destination} <- Prima.Destination.from_map(map) do
      inside(destination, request)
    else
      _unreadable -> {:error, :destination_mismatch}
    end
  end

  defp inside(_entry, _request), do: {:error, :destination_mismatch}

  # ---------------------------------------------------------------------------
  # Lifetimes
  # ---------------------------------------------------------------------------

  @doc false
  # Whether the binding `resource` carries is live for `use`, shared with
  # `Sanctum.VaultReader`'s disclosed dispense. A resource with no
  # `binding_key` (an MCP stdio environment's) carries no lifetime. Any
  # other: the run's pins name the profiles' heads
  # (`Sanctum.Consent.Loader.pinned_intact?/2`, which also refuses a
  # blocked profile), the head is the pinned consent, and its row at the
  # binding's key admits the use; a borrowed binding answers to the
  # lender's profile, consent and row as well. A `once` row is consumed by
  # the root through `Arca.ConsentStorage.consume_once/5`, under the
  # profile's lock and against the pinned consent. A missing consent or
  # row is `:grant_expired`, never a standing binding.
  @spec lifetime(Context.t(), map(), map()) :: :ok | {:error, :grant_expired | :unavailable}
  def lifetime(%Context{} = ctx, %{binding_key: key} = resource, %{} = use) when is_binary(key) do
    # The pins a run under `use` carries for this binding: the root's, and
    # the lender's a borrowed binding names. Nothing else of an authority
    # is read.
    pins = %{
      Authority.zero()
      | profile_id: Map.get(use, :profile_id),
        consent_id: Map.get(use, :consent_id),
        resources: %Edge{vault: resource}
    }

    if Sanctum.Consent.Loader.pinned_intact?(ctx, pins) do
      root = Map.get(use, :root_execution_id)

      with :ok <- row_admits(ctx, pins.profile_id, pins.consent_id, key, root) do
        lender(ctx, resource, root)
      end
    else
      {:error, :grant_expired}
    end
  end

  def lifetime(%Context{}, _resource, %{}), do: :ok

  defp lender(
         ctx,
         %{lender: %{profile_id: profile, consent_id: consent, binding_key: key}},
         root
       ),
       do: row_admits(ctx, profile, consent, key, root)

  defp lender(_ctx, _resource, _root), do: :ok

  defp row_admits(ctx, profile_id, consent_id, key, root) do
    actor = Context.actor(ctx)

    case Arca.ConsentStorage.get_head(actor, profile_id) do
      {:ok, %{id: ^consent_id}, refs} ->
        refs
        |> Enum.find(&(&1.binding_key == key))
        |> admits(actor, profile_id, consent_id, root)

      {:ok, _another_head, _refs} ->
        {:error, :grant_expired}

      {:error, reason} when reason in [:database_error, :unavailable] ->
        {:error, :unavailable}

      {:error, _no_head} ->
        {:error, :grant_expired}
    end
  end

  defp admits(nil, _actor, _profile_id, _consent_id, _root), do: {:error, :grant_expired}
  defp admits(%{lifetime_kind: "standing"}, _actor, _profile, _consent, _root), do: :ok

  defp admits(%{lifetime_kind: "until", expires_at: %DateTime{} = at}, _a, _p, _c, _root) do
    if DateTime.compare(DateTime.utc_now(), at) == :lt,
      do: :ok,
      else: {:error, :grant_expired}
  end

  defp admits(%{lifetime_kind: "once", binding_key: key}, actor, profile_id, consent_id, root)
       when is_binary(root) and root != "" do
    case Arca.ConsentStorage.consume_once(actor, profile_id, consent_id, key, root) do
      :ok -> :ok
      {:error, reason} when reason in [:database_error, :unavailable] -> {:error, :unavailable}
      {:error, _superseded_consumed_or_gone} -> {:error, :grant_expired}
    end
  end

  defp admits(_row, _actor, _profile_id, _consent_id, _root), do: {:error, :grant_expired}
end
