# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Loader do
  @moduledoc """
  Fail-closed construction of a root `Cyfr.Authority` from a profile's
  head consent.

  The checks run in a fixed order, each refusing rather than degrading:

  1. profile status — only `:active` roots an execution
  2. head consent exists
  3. consent internal validity (pinned ⟺ non-empty version — the database
     cannot enforce it portably, so the loader is the gate)
  4. the resolved policy blob parses (`Cyfr.Authority.Blob.parse/1`)
  5. **blob/refs equality** — every bound vault reference inside the blob
     must exactly equal the consent's stored `vault_refs`; any asymmetry
     means the blob and the reverse index disagree about what was
     granted, and the consent is refused
  6. **selections resolved** — an edge whose vault selects a labelled
     profile of its target is rewritten to that profile's own bound entry
     when the profile is an active owner profile, its head consent is
     intact and its ingress binds an entry of the pinned digest;
     otherwise the selection stays, and a run under that edge answers
     setup_required
  7. **binding digest consistency** — the same vault entry on two edges
     with unequal binding digests is refused; the loader never picks
  8. the `Sanctum.Consent.Loader.Decision` table over granted vs installed
     activation
  9. `Cyfr.Authority.root/3` — ceiling clamping happens inside

  The live side of the integrity evaluation (`live` and `live_shape_digest`)
  is supplied by the caller, because resolving installed components is
  registry work the loader deliberately cannot do — its inputs stay inert
  data. A nil `live_shape_digest` compares as unknown and fails closed to
  `consent_required` on drift.
  """

  require Logger

  alias Cyfr.Authority
  alias Cyfr.Authority.Blob
  alias Sanctum.Consent.Loader.Decision
  alias Sanctum.Consent.Source
  alias Cyfr.ComponentRef
  alias Sanctum.Context
  alias Cyfr.JCS

  @type load_error ::
          Sanctum.Consent.error()
          | {:profile_unavailable, :needs_consent | :revoked}
          | {:no_head_consent, String.t()}
          | {:invalid_consent, atom()}
          | {:invalid_blob, Blob.error()}
          | {:blob_digest_mismatch, String.t()}
          | {:blob_refs_mismatch, %{blob_only: [tuple()], refs_only: [tuple()]}}
          | {:integrity_alarm, [String.t()]}
          | {:invalid_profile, atom()}
          | {:unknown_source_node, String.t()}
          | {:missing_ingress, String.t()}
          | {:inconsistent_binding_digest, String.t()}

  @typedoc "What run_root stamps on the execution row."
  @type stamp :: %{activation_digest: String.t(), activation_graph: %{String.t() => String.t()}}

  @doc """
  Load the head consent of `profile` and build the root Authority.

  ## Options

  - `:live` — verified live activation (`Compendium.Activation.resolve_verified/2`
    result), required for the integrity evaluation
  - `:live_shape_digest` — the installed source's shape digest, nil = unknown
  - `:ceiling` — override the platform ceiling (tests only)
  - `:budget_id` — the reservation the authority's budget names (a turn
    resumed or taken over charges the one it was admitted with)
  - `:source` — override the configured `Sanctum.Consent.Source` (tests only)
  """
  @spec load_root(Context.t(), map(), keyword()) ::
          {:ok, Authority.t(), stamp()} | {:error, load_error()}
  def load_root(%Context{} = ctx, profile, opts \\ []) when is_map(profile) do
    source = Keyword.get(opts, :source, Source.impl())

    with :ok <- check_profile_status(profile),
         {:ok, consent} <- fetch_head(source, ctx, profile),
         :ok <- check_consent_validity(consent),
         :ok <- check_blob_digest(consent),
         {:ok, blob} <- parse_blob(consent),
         :ok <- check_blob_refs_equality(blob, consent),
         blob = resolve_selections(ctx, source, blob),
         :ok <- check_entry_digest_conflicts(blob),
         {:ok, running} <- evaluate_activation(ctx, profile, consent, opts),
         {:ok, authority} <- build_root(profile, consent, blob, running, opts) do
      {:ok, authority, %{activation_digest: running.digest, activation_graph: running.graph}}
    end
  end

  defp check_profile_status(%{status: :active}), do: :ok
  defp check_profile_status(%{status: status}), do: {:error, {:profile_unavailable, status}}
  defp check_profile_status(_), do: {:error, {:invalid_profile, :status}}

  defp fetch_head(source, ctx, profile) do
    case source.head_consent(ctx, profile.id) do
      {:ok, consent} -> {:ok, consent}
      {:error, _} -> {:error, {:no_head_consent, profile.id}}
    end
  end

  defp check_consent_validity(consent) do
    cond do
      consent.scope not in [:versionless, :pinned] ->
        {:error, {:invalid_consent, :scope}}

      consent.scope == :pinned and consent.pinned_version == "" ->
        {:error, {:invalid_consent, :pinned_version}}

      consent.scope == :versionless and consent.pinned_version != "" ->
        {:error, {:invalid_consent, :pinned_version}}

      not is_map(consent.activation) or consent.activation == %{} ->
        {:error, {:invalid_consent, :activation}}

      true ->
        :ok
    end
  end

  # Verify blob integrity before parsing. The blob defines capabilities,
  # resources, and limits; commit_digest covers the decisions, not these bytes.
  # Tampering returns an integrity error regardless of parse validity.
  defp check_blob_digest(%{blob_digest: stored, resolved_policy: policy})
       when is_binary(stored) and is_binary(policy) do
    if Plug.Crypto.secure_compare(JCS.hash_binary(policy), stored) do
      :ok
    else
      {:error, {:blob_digest_mismatch, stored}}
    end
  end

  defp check_blob_digest(%{blob_digest: nil}), do: {:error, {:invalid_consent, :blob_digest}}
  defp check_blob_digest(_), do: {:error, {:invalid_consent, :blob_digest}}

  defp parse_blob(consent) do
    case Blob.parse(consent.resolved_policy) do
      {:ok, blob} -> {:ok, blob}
      {:error, reason} -> {:error, {:invalid_blob, reason}}
    end
  end

  # The blob is what runs; the refs are what "which profiles touch this
  # entry" queries answer from. If they disagree, one of them lies about
  # the grant, so neither is trusted.
  defp check_blob_refs_equality(blob, consent) do
    blob_refs = blob_vault_refs(blob)

    stored_refs =
      MapSet.new(consent.vault_refs, fn ref -> {ref.vault_entry_id, ref.binding_digest} end)

    if MapSet.equal?(blob_refs, stored_refs) do
      :ok
    else
      {:error,
       {:blob_refs_mismatch,
        %{
          blob_only: blob_refs |> MapSet.difference(stored_refs) |> Enum.sort(),
          refs_only: stored_refs |> MapSet.difference(blob_refs) |> Enum.sort()
        }}}
    end
  end

  defp check_entry_digest_conflicts(blob) do
    case Blob.entry_digest_conflicts(blob) do
      [id | _] -> {:error, {:inconsistent_binding_digest, id}}
      [] -> :ok
    end
  end

  defp blob_vault_refs(%Blob{nodes: nodes}) do
    for {_ref, node} <- nodes,
        {_key, edge} <- node.edges,
        Blob.bound_vault?(edge.vault),
        into: MapSet.new() do
      {edge.vault.entry_id, edge.vault.binding_digest}
    end
  end

  # ---------------------------------------------------------------------------
  # Selections — a vault borrowed from the target's own profile
  # ---------------------------------------------------------------------------

  # Every selected vault edge is resolved against the profile it names:
  # the edge's target must have an active owner profile of that label,
  # its head consent must be intact (the same digest check this consent
  # passed), and its ingress must bind an entry whose digest matches the
  # pinned one when the selection pinned it. The bound entry then rides
  # the edge, projected to what both the selection and the ingress allow.
  # Anything else leaves the selection in place, which no run can unseal.
  defp resolve_selections(ctx, source, %Blob{} = blob) do
    Blob.map_edges(blob, fn _node_ref, key, edge ->
      case {edge.vault, Blob.edge_target(key)} do
        {%{via: via, projection: projection}, {:ok, target}} ->
          case resolve_selection(ctx, source, target, via, projection) do
            {:ok, vault} ->
              %{edge | vault: vault}

            {:error, reason} ->
              Logger.debug(
                "[Consent.Loader] selection on #{key} not resolved: #{inspect(reason)}"
              )

              edge
          end

        _bound_absent_or_ingress ->
          edge
      end
    end)
  end

  defp resolve_selection(ctx, source, target, via, projection) do
    with {:ok, profile} <- selected_profile(ctx, source, target, via.label),
         {:ok, consent} <- fetch_head(source, ctx, profile),
         :ok <- check_blob_digest(consent),
         {:ok, target_blob} <- parse_blob(consent),
         {:ok, ingress} <- ingress_edge(target_blob, target),
         {:ok, bound} <- bound_ingress_vault(ingress),
         :ok <- check_pinned_digest(via, bound),
         {:ok, narrowed} <- narrow_projection(projection, bound.projection) do
      {:ok,
       Map.put(%{bound | projection: narrowed}, :lender, %{
         profile_id: profile.id,
         consent_id: consent.id
       })}
    end
  end

  @doc """
  Whether the pins this authority carries still name the live heads:
  the root profile is active at `consent_id`, and every lender pin on
  the current edge or the loaded blob is active at its consent. One
  primary-key read per pin.
  """
  @spec pinned_intact?(Context.t(), Authority.t()) :: boolean()
  def pinned_intact?(%Context{} = ctx, %Authority{} = auth) do
    root_pin_intact?(ctx, auth.profile_id, auth.consent_id) and
      Enum.all?(lender_pins(auth), fn %{profile_id: profile_id, consent_id: consent_id} ->
        pin_intact?(ctx, profile_id, consent_id)
      end)
  end

  # The root pin holds only while its profile row is active at the pinned
  # consent; a missing row, a moved head or a store that cannot answer all
  # refuse.
  defp root_pin_intact?(ctx, profile_id, consent_id)
       when is_binary(profile_id) and is_binary(consent_id) do
    case Arca.ProfileStorage.get(ctx.athanor_id, profile_id) do
      {:ok, %{status: "active", head_consent_id: ^consent_id}} -> true
      _ -> false
    end
  end

  defp root_pin_intact?(_ctx, _profile_id, _consent_id), do: false

  defp pin_intact?(_ctx, profile_id, consent_id)
       when not is_binary(profile_id) or not is_binary(consent_id),
       do: false

  defp pin_intact?(ctx, profile_id, consent_id) do
    case Arca.ProfileStorage.get(ctx.athanor_id, profile_id) do
      {:ok, %{status: "active", head_consent_id: ^consent_id}} -> true
      _ -> false
    end
  end

  defp lender_pins(%Authority{} = auth) do
    from_resources =
      case auth.resources do
        %Blob.Edge{vault: %{lender: lender}} -> [lender]
        _ -> []
      end

    from_policy =
      case auth.policy do
        %Blob{nodes: nodes} ->
          for {_ref, node} <- nodes,
              {_key, %Blob.Edge{vault: %{lender: lender}}} <- node.edges,
              do: lender

        _ ->
          []
      end

    Enum.uniq(from_resources ++ from_policy)
  end

  defp selected_profile(ctx, source, target, label) do
    with {:ok, profiles} <- source.profiles(ctx, target) do
      case Enum.find(profiles, &(&1.label == label and &1.kind == :owner)) do
        %{status: :active} = profile -> {:ok, profile}
        %{status: status} -> {:error, {:profile_unavailable, status}}
        nil -> {:error, {:no_such_profile, target, label}}
      end
    end
  end

  defp ingress_edge(blob, target) do
    case Blob.ingress(blob, target) do
      {:ok, edge} -> {:ok, edge}
      {:error, :missing_ingress} -> {:error, {:missing_ingress, target}}
    end
  end

  defp bound_ingress_vault(%Blob.Edge{vault: vault}) do
    if Blob.bound_vault?(vault), do: {:ok, vault}, else: {:error, :nothing_bound}
  end

  defp check_pinned_digest(%{binding_digest: nil}, _bound), do: :ok

  defp check_pinned_digest(%{binding_digest: pinned}, %{binding_digest: bound}) do
    if Plug.Crypto.secure_compare(pinned, bound), do: :ok, else: {:error, :binding_moved}
  end

  # A projection narrows: the selection's fields and scopes intersect the
  # ingress's, an empty list on either side meaning "all of the other's".
  # A selection that asks for fields the ingress does not grant resolves
  # to nothing rather than to a wider set.
  defp narrow_projection(nil, bound), do: {:ok, bound}
  defp narrow_projection(selected, nil), do: {:ok, selected}

  defp narrow_projection(selected, bound) do
    with {:ok, fields} <- narrow_list(selected.fields, bound.fields),
         {:ok, scopes} <- narrow_list(selected.scopes, bound.scopes) do
      {:ok, %{fields: fields, scopes: scopes}}
    end
  end

  defp narrow_list([], bound), do: {:ok, bound}
  defp narrow_list(selected, []), do: {:ok, selected}

  defp narrow_list(selected, bound) do
    case Enum.filter(selected, &(&1 in bound)) do
      [] -> {:error, :projection_unsatisfiable}
      common -> {:ok, common}
    end
  end

  defp evaluate_activation(_ctx, profile, consent, opts) do
    live = Keyword.get(opts, :live, {:error, {:incomplete, :not_resolved}})
    shape = compare_shape(Keyword.get(opts, :live_shape_digest), consent.shape_digest)

    with {:ok, granted_digest} <- hash_activation(consent.activation) do
      case Decision.evaluate(consent.scope, granted_digest, live, shape, local_source?(profile)) do
        :allow ->
          {:ok, live_running(live)}

        {:allow_record, running} ->
          {:ok, running}

        outcome when outcome in [:needs_consent, :needs_consent_repin] ->
          if outcome == :needs_consent_repin do
            Logger.info("[Consent.Loader] local rebuild under pin — re-pin needed: #{profile.id}")
          end

          # The diff arrives as a thunk so the loader stays inert data
          # logic: it is computed only when re-consent is actually
          # required, and never influences the decision above.
          shape_diff = Keyword.get(opts, :shape_diff, fn -> [] end)

          {:error,
           {:consent_required,
            %{
              profile_id: profile.id,
              current_revision: consent.revision,
              shape_diff: safe_diff(shape_diff)
            }}}

        {:integrity_alarm, nodes} ->
          Logger.error(
            "[Consent.Loader] activation integrity alarm — release digest does not " <>
              "re-derive from its row: profile=#{profile.id} nodes=#{inspect(nodes)}"
          )

          :telemetry.execute(
            [:cyfr, :sanctum, :consent, :integrity_alarm],
            %{count: length(nodes)},
            %{profile_id: profile.id, nodes: nodes}
          )

          {:error, {:integrity_alarm, nodes}}

        {:setup_required, reason} ->
          {:error,
           {:setup_required,
            %{profile_id: profile.id, node_ref: profile.source_ref, need: "", reason: reason}}}
      end
    end
  end

  defp hash_activation(activation) do
    case JCS.hash(activation) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, {:invalid_consent, :activation}}
    end
  end

  defp safe_diff(fun) when is_function(fun, 0) do
    case fun.() do
      diff when is_list(diff) -> diff
      _ -> []
    end
  rescue
    e ->
      # Log diff-rendering failures without changing the authorization refusal.
      Logger.warning("[Consent.Loader] shape diff failed: #{Exception.message(e)}")
      []
  end

  defp safe_diff(_), do: []

  defp compare_shape(nil, _stored), do: :unknown
  defp compare_shape(live, stored) when live == stored, do: :match
  defp compare_shape(_live, _stored), do: :differ

  defp local_source?(%{source_ref: source_ref}) do
    case ComponentRef.parse(source_ref) do
      {:ok, %ComponentRef{namespace: namespace}} ->
        Compendium.ComponentPath.local_publisher?(namespace)

      _ ->
        false
    end
  end

  defp live_running({:ok, %{digest: digest, graph: graph}}), do: %{digest: digest, graph: graph}

  defp build_root(profile, consent, blob, running, opts) do
    profile_map = %{
      profile_id: profile.id,
      consent_id: consent.id,
      source_ref: profile.source_ref,
      kind: profile.kind,
      invoke_mode: consent.invoke_mode,
      # Use the running activation for self-invocation under versionless consent.
      activation: running.graph
    }

    ceiling = Keyword.get(opts, :ceiling) || Sanctum.Policy.Ceiling.platform_ceiling()

    Authority.root(profile_map, blob,
      ceiling: ceiling,
      budget_id: Keyword.get(opts, :budget_id)
    )
  end
end
