# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.Loader do
  @moduledoc """
  Fail-closed construction of a root `Prima.Authority` from a profile's
  head consent.

  The checks run in a fixed order, each refusing rather than degrading:

  1. profile status — only `:active` roots an execution
  2. head consent exists
  3. **origin admitted** — the context's `origin` (`Prima.Origin`, set by
     the admission path that started the run) must be among the
     revision's `admitted_origins`; a context with none, or with one the
     revision does not name, answers `consent_required` with its usual
     payload, so the surface asks the person to grant again
  4. consent internal validity (pinned ⟺ non-empty version — the database
     cannot enforce it portably, so the loader is the gate)
  5. the resolved policy blob parses (`Prima.Authority.Blob.parse/1`)
  6. **canonical storage paths** — every storage path the blob grants is
     spelled as the storage door reaches it
     (`Prima.ComponentPath.door_path/1`, `"*"` aside); a revision that
     names another spelling answers `consent_required`, and is never
     rewritten here
  7. **blob/refs equality** — every bound vault reference inside the blob
     must exactly equal the consent's stored `vault_refs`; any asymmetry
     means the blob and the reverse index disagree about what was
     granted, and the consent is refused
  8. **selections resolved** — an edge whose vault selects a labelled
     profile of its target is rewritten to that profile's own bound entry
     when the profile is an active owner profile, no profile row of the
     target is damaged, its head consent is intact and its ingress binds
     an entry of the pinned digest. A lender the store cannot answer
     (`{:lender_unavailable, target}`), or whose profile row or head does
     not decode (`{:lender_corrupt, target, profile_id}`), refuses the
     whole load, and so does a lender's head that does not admit the
     context's origin (`consent_required`, naming the lender's profile and
     revision). Otherwise the selection stays, and a run under that edge
     answers setup_required
  9. **binding digest consistency** — the same vault entry on two edges
     with unequal binding digests is refused; the loader never picks
  10. the `Sanctum.Consent.Loader.Decision` table over granted vs
      installed activation
  11. `Prima.Authority.root/3` — ceiling clamping happens inside

  Checks 4 to 9 are the stored head's own (`admitted_blob/3`), the one
  rule every read of what a grant reaches applies.

  The live side of the integrity evaluation (`live` and `live_shape_digest`)
  is supplied by the caller, because resolving installed components is
  registry work the loader deliberately cannot do — its inputs stay inert
  data. A nil `live_shape_digest` compares as unknown and fails closed to
  `consent_required` on drift.
  """

  require Logger

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Consent.Loader.Decision
  alias Prima.ComponentRef
  alias Sanctum.Context
  alias Prima.JCS

  @type load_error ::
          Sanctum.Consent.error()
          | {:profile_unavailable, :needs_consent | :revoked}
          | {:no_head_consent, String.t()}
          | {:head_corrupt, String.t()}
          | {:head_unavailable, String.t()}
          | {:lender_corrupt, String.t(), String.t()}
          | {:lender_unavailable, String.t()}
          | {:invalid_consent, atom()}
          | {:invalid_blob, Blob.error()}
          | {:blob_digest_mismatch, String.t()}
          | {:blob_refs_mismatch, %{blob_only: [tuple()], refs_only: [tuple()]}}
          | {:integrity_alarm, [String.t()]}
          | {:invalid_profile, atom()}
          | {:unknown_source_node, String.t()}
          | {:missing_ingress, String.t()}
          | {:inconsistent_binding_digest, String.t()}
          | :connection_not_granted

  @typedoc "What run_root stamps on the execution row."
  @type stamp :: %{activation_digest: String.t(), activation_graph: %{String.t() => String.t()}}

  @doc """
  Load the head consent of `profile` and build the root Authority.

  ## Options

  - `:live` — verified live activation (`Sanctum.Consent.Components.resolve_verified/2`
    result), required for the integrity evaluation
  - `:live_shape_digest` — the installed source's shape digest, nil = unknown
  - `:ceiling` — override the platform ceiling (tests only)
  - `:budget_id` — the reservation the authority's budget names (a turn
    resumed or taken over charges the one it was admitted with)
  - `:connection` — the account the root's own calls name, picked from
    the ingress by `Prima.Authority.root/3`; a name the ingress does not
    bind is `{:error, :connection_not_granted}`

  ## A head or a lender it cannot read

  The profile's own head is read three ways, never one: a profile with
  no head is `{:no_head_consent, profile_id}`, a head stored outside the
  closed vocabulary is `{:head_corrupt, profile_id}`, and one the store
  could not answer is `{:head_unavailable, profile_id}`. Each lender a
  selection names is read the same way, as `admitted_blob/3` reads it: a
  lender the store could not answer refuses the load
  `{:lender_unavailable, target}`, one whose profile row or head does not
  decode refuses it `{:lender_corrupt, target, profile_id}`, and an absent
  one leaves the selection in place.
  """
  @spec load_root(Context.t(), map(), keyword()) ::
          {:ok, Authority.t(), stamp()} | {:error, load_error()}
  def load_root(%Context{} = ctx, profile, opts \\ []) when is_map(profile) do
    actor = Context.actor(ctx)

    with :ok <- check_profile_status(profile),
         {:ok, consent} <- fetch_head(actor, profile),
         :ok <- check_origin(ctx, profile, consent),
         {:ok, blob} <- admitted_blob(ctx, profile, consent),
         {:ok, running} <- evaluate_activation(ctx, profile, consent, opts),
         {:ok, authority} <- build_root(profile, consent, blob, running, opts) do
      {:ok, authority, %{activation_digest: running.digest, activation_graph: running.graph}}
    end
  end

  @doc """
  The blob a stored head grants, as `load_root/3` carries it, or the
  refusal that stops `load_root/3` on the head itself: checks 4 to 9 of
  the module's order, in that order, under the context's origin. A read
  of what a grant reaches (`profile/grants`) asks this, so no grant shows
  wider or narrower than the loader runs it.

  It reads neither the profile's status nor the run's own origin against
  the head (checks 1 to 3), and asks nothing of the installed components
  (check 10): those belong to a run, not to the stored grant. The
  context's origin still decides each lender's admission (check 8), so the
  same head can carry a borrowed entry under one origin and refuse under
  another.

  A lender is read absent, damaged and unanswered apart. A lender the
  store could not answer, its profiles or its head, refuses
  `{:lender_unavailable, target}`; a lender whose profile row or head
  does not decode refuses `{:lender_corrupt, target, profile_id}`, where a
  damaged profile row of the target refuses a selection by label, since
  its label cannot be read. A lender that does not exist, has no head,
  is not active or lends nothing leaves the selection in place.
  """
  @spec admitted_blob(Context.t(), map(), map()) :: {:ok, Blob.t()} | {:error, load_error()}
  def admitted_blob(%Context{} = ctx, profile, consent)
      when is_map(profile) and is_map(consent) do
    with :ok <- check_consent_validity(consent),
         :ok <- check_blob_digest(consent),
         {:ok, blob} <- parse_blob(consent),
         :ok <- check_canonical_paths(blob, profile, consent),
         :ok <- check_blob_refs_equality(blob, consent),
         {:ok, blob} <- resolve_selections(ctx, Context.actor(ctx), blob),
         :ok <- check_entry_digest_conflicts(blob) do
      {:ok, blob}
    end
  end

  defp check_profile_status(%{status: :active}), do: :ok
  defp check_profile_status(%{status: status}), do: {:error, {:profile_unavailable, status}}
  defp check_profile_status(_), do: {:error, {:invalid_profile, :status}}

  # A head that is absent, one stored outside the closed vocabulary and
  # one the store cannot answer are three answers, never one: a caller
  # that read an outage or a damaged row as "no grant" would send the
  # person to grant again over a record that exists.
  defp fetch_head(actor, profile) do
    case Arca.ConsentStorage.head_consent(actor, profile.id) do
      {:ok, consent} ->
        {:ok, consent}

      {:error, absent} when absent in [:not_found, :no_head] ->
        {:error, {:no_head_consent, profile.id}}

      {:error, {:invalid_stored_value, _}} ->
        {:error, {:head_corrupt, profile.id}}

      {:error, _unanswered} ->
        {:error, {:head_unavailable, profile.id}}
    end
  end

  # The origin is the admission path's (`Prima.Origin`), never the
  # credential's: a revision admits the origins its person named, and a
  # context with none — or one the revision does not name — is asked to
  # grant again, as any other consent the run lacks.
  defp check_origin(%Context{origin: origin}, profile, %{admitted_origins: origins} = consent) do
    if origin in origins, do: :ok, else: regrant(profile, consent)
  end

  # `consent_required` with its usual payload: the surface that handles it
  # already raises the grant prompt for that profile.
  defp regrant(profile, consent) do
    {:error,
     {:consent_required,
      %{profile_id: profile.id, current_revision: consent.revision, shape_diff: []}}}
  end

  # A storage path is granted as the door reaches it. A revision written
  # before the manifest grammar refused other spellings (`data//secrets/`)
  # still runs nothing: it is asked again, under the canonical spelling,
  # and never rewritten here.
  defp check_canonical_paths(%Blob{nodes: nodes}, profile, consent) do
    canonical? =
      Enum.all?(nodes, fn {_ref, node} ->
        Enum.all?(node.edges, fn {_key, edge} ->
          Enum.all?(Blob.Edge.paths(edge), &Prima.Manifest.Caps.canonical_storage_path?/1)
        end)
      end)

    if canonical?, do: :ok, else: regrant(profile, consent)
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
  # entry" queries answer from, and what a binding's lifetime is kept on.
  # If they disagree, one of them lies about the grant, so neither is
  # trusted. Compared per binding: a bound entry by its key, entry and
  # digest, a selection by its key, label and pinned digest (nil when it
  # pinned none).
  defp check_blob_refs_equality(blob, consent) do
    blob_refs = blob_vault_refs(blob)

    stored_refs = MapSet.new(consent.vault_refs, &stored_ref/1)

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

  # Every binding the blob holds, as the tagged identity its row carries
  # (`Arca.ConsentStorage.row_identity/1`): each bound entry, its named
  # accounts included, and each selection, keyed where it sits. Provided
  # configuration names no binding.
  defp blob_vault_refs(%Blob{nodes: nodes}) do
    for {node_ref, node} <- nodes,
        {edge_key, %Blob.Edge{vault: vault}} <- node.edges,
        ref <- edge_refs(node_ref, edge_key, vault),
        into: MapSet.new(),
        do: ref
  end

  defp edge_refs(_node_ref, _edge_key, %{entry_id: _} = vault) do
    named = vault |> Map.get(:named, %{}) |> Map.values()
    for bound <- [vault | named], do: bound_identity(bound)
  end

  # A selection is resolved within the borrowing consent's own athanor.
  defp edge_refs(node_ref, edge_key, %{via: via}),
    do: [
      {:via, "athanor", Blob.binding_key(node_ref, edge_key, nil), via.label, via.binding_digest}
    ]

  defp edge_refs(_node_ref, _edge_key, _vault), do: []

  defp bound_identity(%{scope: "instance"} = bound),
    do: {:instance, "instance", bound.binding_key, bound.entry_id, bound.binding_digest}

  defp bound_identity(bound),
    do: {:entry, bound.scope, bound.binding_key, bound.entry_id, bound.binding_digest}

  defp stored_ref(ref), do: Arca.ConsentStorage.row_identity(ref)

  # ---------------------------------------------------------------------------
  # Selections — a vault borrowed from the target's own profile
  # ---------------------------------------------------------------------------

  # Every selected vault edge is resolved against the profile it names:
  # the edge's target must have an active owner profile of that label,
  # its head consent must be intact (the same digest check this consent
  # passed), and its ingress must bind an entry whose digest matches the
  # pinned one when the selection pinned it. The bound entry then rides
  # the edge, projected to what both the selection and the ingress allow,
  # under two identities: the borrower's binding key, where the selection
  # sits, and the lender's profile, consent and binding key, so a use
  # answers to both bindings. The lender's named accounts are not lent.
  # Anything else leaves the selection in place, which no run can unseal.
  #
  # The lender's head must admit the context's origin as the root's must:
  # a key lent under a grant that does not name this origin is not lent to
  # this run, and the whole load is refused, naming the lender.
  defp resolve_selections(%Context{} = ctx, actor, %Blob{nodes: nodes} = blob) do
    nodes
    |> Enum.reduce_while({:ok, %{}}, fn {node_ref, node}, {:ok, resolved} ->
      case resolve_node(ctx, actor, node_ref, node) do
        {:ok, node} -> {:cont, {:ok, Map.put(resolved, node_ref, node)}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, %{blob | nodes: resolved}}
      {:error, _} = refused -> refused
    end
  end

  defp resolve_node(ctx, actor, node_ref, %Blob.Node{edges: edges} = node) do
    edges
    |> Enum.reduce_while({:ok, %{}}, fn {key, edge}, {:ok, resolved} ->
      case resolve_edge(ctx, actor, node_ref, key, edge) do
        {:ok, edge} -> {:cont, {:ok, Map.put(resolved, key, edge)}}
        {:error, _} = refused -> {:halt, refused}
      end
    end)
    |> case do
      {:ok, resolved} -> {:ok, %{node | edges: resolved}}
      {:error, _} = refused -> refused
    end
  end

  defp resolve_edge(ctx, actor, node_ref, key, edge) do
    case {edge.vault, Blob.edge_target(key)} do
      {%{via: via, projection: projection}, {:ok, target}} ->
        borrower_key = Blob.binding_key(node_ref, key, nil)

        case resolve_selection(ctx, actor, target, via, projection, borrower_key) do
          {:ok, vault} ->
            {:ok, %{edge | vault: vault}}

          {:error, {:consent_required, _}} = refused ->
            refused

          # A lender that could not be read, or that does not decode, is
          # no lender that lends nothing: the run is refused as such,
          # never left to answer setup_required at its first use.
          {:error, {:lender_unavailable, _target}} = refused ->
            refused

          {:error, {:lender_corrupt, _target, _profile_id}} = refused ->
            refused

          {:error, reason} ->
            Logger.debug("[Consent.Loader] selection on #{key} not resolved: #{inspect(reason)}")

            {:ok, edge}
        end

      _bound_absent_or_ingress ->
        {:ok, edge}
    end
  end

  defp resolve_selection(ctx, actor, target, via, projection, borrower_key) do
    with {:ok, profile} <- selected_profile(actor, target, via.label),
         {:ok, consent} <- lender_head(actor, target, profile),
         :ok <- check_origin(ctx, profile, consent),
         :ok <- check_blob_digest(consent),
         {:ok, target_blob} <- parse_blob(consent),
         {:ok, ingress} <- ingress_edge(target_blob, target),
         {:ok, bound} <- bound_ingress_vault(ingress),
         :ok <- check_pinned_digest(via, bound),
         {:ok, narrowed} <- narrow_projection(projection, bound.projection) do
      {:ok,
       bound
       |> Map.delete(:named)
       |> Map.merge(%{
         projection: narrowed,
         binding_key: borrower_key,
         lender: %{profile_id: profile.id, consent_id: consent.id, binding_key: bound.binding_key}
       })}
    end
  end

  # A lender's head answers as the lender: `head_*` names a root's own
  # head alone, so a lender's head that could not be read or does not
  # decode is the lender's refusal, and one that is absent stays absent.
  defp lender_head(actor, target, profile) do
    case fetch_head(actor, profile) do
      {:ok, consent} -> {:ok, consent}
      {:error, {:head_unavailable, _profile_id}} -> {:error, {:lender_unavailable, target}}
      {:error, {:head_corrupt, profile_id}} -> {:error, {:lender_corrupt, target, profile_id}}
      {:error, {:no_head_consent, _profile_id}} = absent -> absent
    end
  end

  @doc """
  What one `vault_refs` row of the head revision `consent` binds now,
  read by its tag (`Arca.ConsentStorage.row_identity/1`):

    * `{:entry, entry_id, binding_digest}` — the athanor's own entry;
    * `{:selection, label, result}` — a selection (`via`) of the profile
      `label`, resolved exactly as `load_root/3` resolves it under
      `ctx`'s origin: `{:ok, vault}`, the lender's bound vault, or
      `{:error, reason}` when it resolves to nothing. The lender is read
      absent, damaged and unanswered apart: no such profile
      (`{:no_such_profile, target, label}`) or a lender with no head
      (`{:no_head_consent, profile_id}`); a lender whose profile row or
      head does not decode (`{:lender_corrupt, target, profile_id}`, a
      damaged profile row of the target refusing a selection by label);
      and a lender the store could not answer, its profiles or its head
      (`{:lender_unavailable, target}`). A lent instance entry is read
      live as an instance row is, so a refusal of the offer or a rebind is
      the selection's `{:error, reason}`;
    * `{:instance, instance_entry_id, result}` — an instance entry, read
      live as the context's person is offered it
      (`Sanctum.InstanceEntries.binding/2`): `{:ok, view}` while it stands
      at the digest the row was approved at, `{:error, :binding_went_stale}`
      when it was rebound since, and the offer's own refusal otherwise
      (`:not_offered`, `{:entry_unavailable, status}`, `:denied`,
      `:anonymous_denied`);
    * `:malformed` — a row naming none of them.

  The selection is the one the revision's own blob holds at the row's
  binding key; a blob that fails its digest, does not parse or holds no
  selection there resolves to `{:error, reason}`. Nothing is raised.
  """
  @spec row_binding(Context.t(), map(), map()) ::
          {:entry, String.t(), String.t()}
          | {:selection, String.t(), {:ok, map()} | {:error, term()}}
          | {:instance, String.t(), {:ok, map()} | {:error, term()}}
          | :malformed
  def row_binding(%Context{} = ctx, consent, ref) when is_map(consent) and is_map(ref) do
    case Arca.ConsentStorage.row_identity(ref) do
      {:entry, _scope, _key, entry_id, digest} ->
        {:entry, entry_id, digest}

      {:instance, _scope, _key, instance_entry_id, digest} ->
        {:instance, instance_entry_id, live_instance(ctx, instance_entry_id, digest)}

      {:via, _scope, key, label, _digest} ->
        {:selection, label, resolve_row_selection(ctx, consent, key)}

      :none ->
        :malformed
    end
  end

  # An instance row's liveness: the entry as the loading context's person
  # is offered it, at the digest the row names, as an athanor's entry is
  # held to its row's.
  defp live_instance(ctx, instance_entry_id, digest) do
    case Sanctum.InstanceEntries.binding(ctx, instance_entry_id) do
      {:ok, %{binding_digest: live} = view} when is_binary(live) and is_binary(digest) ->
        if Plug.Crypto.secure_compare(live, digest),
          do: {:ok, view},
          else: {:error, :binding_went_stale}

      {:ok, _undigested} ->
        {:error, :binding_went_stale}

      {:error, _} = refused ->
        refused
    end
  end

  defp resolve_row_selection(ctx, consent, key) do
    with :ok <- check_blob_digest(consent),
         {:ok, %Blob{nodes: nodes}} <- parse_blob(consent),
         {:ok, edge_key, vault} <- selection_at(nodes, key),
         {:ok, target} <- Blob.edge_target(edge_key) do
      ctx
      |> resolve_selection(Context.actor(ctx), target, vault.via, vault.projection, key)
      |> live_lent(ctx)
    else
      :ingress -> {:error, :selection_missing}
      {:error, _} = refused -> refused
    end
  end

  # A lent instance entry, held as an instance row is: offered to this
  # person and at the digest the lender bound it at.
  defp live_lent({:ok, %{scope: "instance", entry_id: id, binding_digest: digest} = vault}, ctx) do
    case live_instance(ctx, id, digest) do
      {:ok, _view} -> {:ok, vault}
      {:error, _} = refused -> refused
    end
  end

  defp live_lent(resolved, _ctx), do: resolved

  # The selection the blob holds at `key`: the edge whose place is the
  # row's.
  defp selection_at(nodes, key) do
    Enum.find_value(nodes, {:error, :selection_missing}, fn {node_ref, %Blob.Node{edges: edges}} ->
      Enum.find_value(edges, fn
        {edge_key, %Blob.Edge{vault: %{via: _} = vault}} ->
          if Blob.binding_key(node_ref, edge_key, nil) == key, do: {:ok, edge_key, vault}

        _other ->
          nil
      end)
    end)
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
    case Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id) do
      {:ok, %{status: "active", head_consent_id: ^consent_id}} -> true
      _ -> false
    end
  end

  defp root_pin_intact?(_ctx, _profile_id, _consent_id), do: false

  defp pin_intact?(_ctx, profile_id, consent_id)
       when not is_binary(profile_id) or not is_binary(consent_id),
       do: false

  defp pin_intact?(ctx, profile_id, consent_id) do
    case Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id) do
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

  # The lending profile, read as admission reads a root's: a row whose
  # kind or status is outside the closed vocabulary may carry the label
  # asked for, so it refuses the selection rather than being skipped, and
  # a store that cannot answer is not a lender that does not exist.
  defp selected_profile(actor, target, label) do
    case Arca.ConsentStorage.profile_entries(actor, target) do
      {:ok, entries} ->
        case Enum.find(entries, &(&1.status == :corrupt)) do
          %{id: id} -> {:error, {:lender_corrupt, target, id}}
          nil -> labelled_owner(entries, target, label)
        end

      {:error, _unanswered} ->
        {:error, {:lender_unavailable, target}}
    end
  end

  defp labelled_owner(entries, target, label) do
    case Enum.find(entries, &(&1.label == label and &1.kind == :owner)) do
      %{status: :active} = profile -> {:ok, profile}
      %{status: status} -> {:error, {:profile_unavailable, status}}
      nil -> {:error, {:no_such_profile, target, label}}
    end
  end

  defp ingress_edge(blob, target) do
    case Blob.ingress(blob, target) do
      {:ok, edge} -> {:ok, edge}
      {:error, :missing_ingress} -> {:error, {:missing_ingress, target}}
    end
  end

  # A lender lends an entry it binds; provided configuration is no entry.
  defp bound_ingress_vault(%Blob.Edge{vault: %{entry_id: _} = vault}), do: {:ok, vault}
  defp bound_ingress_vault(_edge), do: {:error, :nothing_bound}

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
        Prima.ComponentPath.local_publisher?(namespace)

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
      budget_id: Keyword.get(opts, :budget_id),
      connection: Keyword.get(opts, :connection)
    )
  end
end
