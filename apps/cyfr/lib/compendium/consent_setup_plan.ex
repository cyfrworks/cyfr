# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlan do
  @moduledoc """
  The consent-sourced half of `Compendium.Component.setup_plan/2`.

  A profile is ready only when every required need has a live vault binding
  whose digest matches the consent, and its head stands for the release a
  run would start, as the run's own load decides it
  (`Sanctum.Consent.head_stands/4`): a release whose shape moved since the
  grant is not ready. Rebinding or revocation can make it unready without
  changing the manifest. A component with no profile is not ready either,
  since a run has no grant to stand on: never granted, or revoked
  (`Sanctum.Consent.ungranted/2`). So `ready` and a run agree.

  Each row of the head revision is read by what it names
  (`Sanctum.Consent.row_binding/3`): the athanor's own entry, held
  to the digest the person approved; a selection of another profile's
  key, resolved as a run resolves it and its lender's entry held to the
  same check, or reported not ready with the reason it resolves to
  nothing; and a share, read as the person is offered it, its owner
  standing and its source entry held to the digest the person approved.
  A bound entry the store could not answer, the athanor's own or one
  reached through a share, is said as one to read again, never as an
  entry that no longer exists or one the person cannot use.

  An attach-only entry bound where the component reads the value itself
  (its edge carries no attach rule: a need of a version published before
  attaching existed) is not ready, and the remedy named is the update —
  the newer version the install media ships when there is one — or
  disclosing the entry. A need the app's `provides` covers is the
  publisher's configuration, never an unbound need.

  `Compendium.Component.setup_plan/2` embeds this as the `consent` section
  of its response and derives the top-level `ready` from it — the consent
  state is the only thing that answers "is this component set up".
  """

  alias Sanctum.Context
  alias Sanctum.VaultReader

  # A bound entry the store could not answer: a retry, never an entry that
  # no longer exists or one this person cannot use.
  @entry_unread "the bound vault entry cannot be read right now — try again"

  @doc """
  The consent section for a source ref whose installed release is
  `component` (its registry row).

  A source with no profile a run could stand on is a section that is not
  ready, with `head_state` `"missing"` when it was never granted or
  `"revoked"` when its grant was revoked, and its `reason`; so is one
  with several active owner profiles, which a run refuses as ambiguous
  (`head_state` `"ambiguous"`). The profile described is the one a run
  would stand on, picked by the run's own selection.

  A store that cannot be read, or any profile row of the source that
  cannot be decoded, which refuses a run's selection, is a section that
  is not ready (`profile_status: :unavailable` or `:corrupt`, with
  `head_state` `"unavailable"` or `"damaged"` and its `reason`), never
  one that reads as a grant still to make.

  A profile's section carries its head's `head_state`, as `profile.list`
  names it: `"present"` when the head was read, and otherwise
  `"missing"`, `"damaged"` or `"unavailable"`, each with the `reason`
  sentence a person can act on.
  """
  @spec section(Context.t(), String.t(), map()) :: map()
  def section(%Context{} = ctx, source_ref, component) when is_map(component) do
    with {:ok, name_ref} <- name_ref(source_ref),
         {:ok, entries} <- read_profiles(ctx, name_ref) do
      case Prima.Authority.RootSelect.candidates(entries, nil) do
        {:ok, candidates} -> selected(ctx, name_ref, candidates, component)
        {:error, {:corrupt, {:profile, id}}} -> not_ready(id, :corrupt)
      end
    else
      {:error, :unavailable} -> not_ready(nil, :unavailable)
      :none -> not_ready(nil, :unavailable)
    end
  end

  # No profile a run could stand on: the run is refused, so the component
  # is not ready, and the section says whether it was ever granted.
  defp ungranted(ctx, name_ref) do
    case Sanctum.Consent.ungranted(ctx, name_ref) do
      {:ok, :no_grant} ->
        unset("missing", "this component has not been granted yet — grant it to run it")

      {:ok, :revoked} ->
        unset("revoked", "this component's grant was revoked — grant it again to run it")

      {:error, _unanswered} ->
        not_ready(nil, :unavailable)
    end
  end

  defp unset(state, reason) do
    %{
      profile_id: nil,
      profile_kind: nil,
      profile_status: nil,
      head_state: state,
      reason: reason,
      revision: nil,
      scope: nil,
      needs: [],
      ready: false
    }
  end

  defp read_profiles(ctx, name_ref) do
    case Sanctum.Consent.profiles(ctx, name_ref) do
      {:ok, entries} -> {:ok, entries}
      {:error, :unavailable} -> {:error, :unavailable}
      {:error, _no_tenant} -> :none
    end
  end

  # A section whose profile could not be read: its row does not decode, or
  # the store could not answer the profile list. Neither is a grant to
  # make, so each says what the person can do, as a head that cannot be
  # given does.
  defp not_ready(profile_id, status) do
    {state, reason} = unread_profile(status, profile_id)

    %{
      profile_id: profile_id,
      profile_kind: nil,
      profile_status: status,
      head_state: state,
      reason: reason,
      revision: nil,
      scope: nil,
      needs: [],
      ready: false
    }
  end

  defp unread_profile(:corrupt, profile_id),
    do:
      {"damaged",
       "this profile is damaged and cannot be used — " <>
         "revoke profile #{profile_id} and grant it again"}

  defp unread_profile(:unavailable, _profile_id),
    do: {"unavailable", "this component's consent cannot be read right now — try again"}

  defp name_ref(ref) do
    case Prima.ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      _ -> :none
    end
  end

  # The profile a run of the source would stand on, picked by the run's own
  # default selection (`Prima.Authority.RootSelect.candidates/2`, then
  # `select/2`): the one active owner profile. None is a run with no grant, as the run says
  # it (a public twin is no grant of the person's runs); one owner waiting
  # for consent is described not ready; several active owners are the
  # ambiguity a run refuses.
  defp selected(ctx, name_ref, entries, component) do
    case Prima.Authority.RootSelect.select(entries, :default) do
      {:ok, profile} ->
        describe(ctx, profile, component)

      {:error, :no_profile} ->
        ungranted(ctx, name_ref)

      {:error, {:profile_unavailable, _status}} ->
        describe(ctx, Enum.find(entries, &(&1.kind == :owner)), component)

      {:error, {:ambiguous, ids}} ->
        unset(
          "ambiguous",
          "this component has several active grants (#{Enum.join(ids, ", ")}) — " <>
            "name one to run it, or revoke the others"
        )
    end
  end

  defp describe(ctx, profile, component) do
    case Sanctum.Consent.head_consent(ctx, profile.id) do
      {:ok, consent} ->
        bound = check_needs(ctx, profile.id, consent)
        needs = bound ++ unbound_required(ctx, profile.source_ref, bound)

        %{
          profile_id: profile.id,
          profile_kind: profile.kind,
          profile_status: profile.status,
          head_state: "present",
          revision: consent.revision,
          scope: consent.scope,
          needs: needs,
          ready: profile.status == :active and Enum.all?(needs, & &1.satisfied)
        }
        |> stands(ctx, profile, consent, component)

      {:error, refused} ->
        {state, reason} = unread_head(refused, profile.id)

        %{
          profile_id: profile.id,
          profile_kind: profile.kind,
          profile_status: profile.status,
          head_state: state,
          reason: reason,
          revision: nil,
          scope: nil,
          needs: [],
          ready: false
        }
    end
  end

  # A head whose needs are met is ready only where it stands for the
  # release a run would start, read as admission reads it: the verified
  # activation of the installed row and the source's live shape, a shape
  # that cannot be derived being unknown, which the decision asks again
  # for. A refusal the run would meet makes the section not ready, with
  # the sentence for it.
  defp stands(%{ready: false} = section, _ctx, _profile, _consent, _component), do: section

  defp stands(section, ctx, profile, consent, component) do
    live = live_activation(ctx, component)

    shape =
      case Sanctum.Consent.ShapeDerivation.live_digest(ctx, profile.source_ref) do
        {:ok, digest} -> digest
        {:error, _underivable} -> nil
      end

    case Sanctum.Consent.head_stands(ctx, profile, consent,
           live: live,
           live_shape_digest: shape
         ) do
      :ok -> section
      {:error, reason} -> %{section | ready: false} |> Map.put(:reason, unstood(reason, profile))
    end
  end

  defp live_activation(ctx, component) do
    case Compendium.resolve_verified_activation(ctx, component) do
      {:ok, _verified} = verified -> verified
      {:error, {:incomplete, _}} = incomplete -> incomplete
      {:error, _unresolved} -> {:error, {:incomplete, :invalid_graph}}
    end
  end

  defp unstood({:consent_required, _ask}, _profile),
    do: "this component asks for more than its grant holds — grant it again to run it"

  defp unstood({unread, _target}, _profile)
       when unread in [:lender_unavailable, :head_unavailable],
       do: "this profile's consent cannot be read right now — try again"

  defp unstood({:setup_required, _need}, _profile),
    do: "this component's release is not ready to run — install it again"

  defp unstood(_damaged_or_unread, profile),
    do:
      "this profile's consent cannot be used for the installed release — " <>
        "revoke profile #{profile.id} and grant it again"

  # A head that could not be given, as `profile.list` names its state, and
  # what the person can do: a head never granted asks for a grant, a
  # damaged one names the profile to revoke (approving it again cannot
  # repair a head the walk cannot decode), and one the store could not
  # answer asks to try again, never for a grant over a consent that exists.
  defp unread_head(:not_found, _profile_id),
    do: {"missing", "this profile has no grant yet — grant it to continue"}

  defp unread_head(:corrupt, profile_id),
    do:
      {"damaged",
       "this profile's consent is damaged and cannot be used — " <>
         "revoke profile #{profile_id} and grant it again"}

  defp unread_head(_unanswered, _profile_id),
    do: {"unavailable", "this profile's consent cannot be read right now — try again"}

  # One row per binding the head consent carries, read by what it names,
  # and live as a run's attach reads its lifetime
  # (`Sanctum.Consent.binding_live/4`):
  # a binding whose `until` has passed, or whose `once` a run has used, is
  # not satisfied, so the grant reads not ready and is offered again.
  defp check_needs(ctx, profile_id, consent) do
    read_itself = read_itself_keys(consent)

    Enum.map(consent.vault_refs, fn ref ->
      {entry_id, satisfied, detail} =
        case Sanctum.Consent.row_binding(ctx, consent, ref) do
          {:entry, id, digest} ->
            reads? = MapSet.member?(read_itself, ref.binding_key)
            usable(ctx, id, digest, "", if(reads?, do: ref.binding_key))

          other ->
            check_ref(ctx, other)
        end

      {satisfied, detail} = live(ctx, profile_id, consent, ref, {satisfied, detail})

      %{
        entry_id: entry_id,
        satisfied: satisfied,
        detail: detail
      }
    end)
  end

  defp live(_ctx, _profile_id, _consent, _ref, {false, _detail} = unsatisfied), do: unsatisfied

  defp live(ctx, profile_id, consent, ref, satisfied) do
    case Sanctum.Consent.binding_live(ctx, profile_id, consent, ref) do
      :ok -> satisfied
      {:error, :grant_expired} -> {false, "its grant has expired — grant it again"}
      {:error, _unanswered} -> {false, "its grant cannot be read right now — try again"}
    end
  end

  # The bindings the component reads itself: the bound entries whose edge
  # carries no attach rule, apart from a login entry, which is mounted into
  # its program and read by nobody (`Sanctum.Mount`). An unreadable policy
  # names none, which leaves every row to its own check.
  defp read_itself_keys(consent) do
    case Prima.Authority.Blob.parse(consent.resolved_policy) do
      {:ok, %Prima.Authority.Blob{nodes: nodes}} ->
        for {_node, %{edges: edges}} <- nodes,
            {_key, %{vault: %{entry_id: _, attach: nil} = vault}} <- edges,
            bound <- [vault | Map.values(Map.get(vault, :named, %{}))],
            not mounted?(bound),
            into: MapSet.new(),
            do: bound.binding_key

      _unreadable ->
        MapSet.new()
    end
  end

  defp mounted?(%{destination: %Prima.Destination{program: program}}) when is_binary(program),
    do: true

  defp mounted?(_bound), do: false

  defp remedy(ctx, binding_key) do
    with {:ok, {node, edge_key, _slot}} <- Prima.Authority.Blob.parse_binding_key(binding_key),
         target = edge_component(node, edge_key),
         {:ok, cref} <- Prima.ComponentRef.parse(target),
         {:ok, row} <- Compendium.Registry.get_latest(ctx, cref.name, cref.namespace, cref.type),
         {:ok, version} when is_binary(version) <- Compendium.ConsentFacts.newer_shipped(ctx, row) do
      "update #{target} to version #{version}, which attaches it, or disclose the entry"
    else
      _ -> "update the component to a version that attaches it, or disclose the entry"
    end
  end

  defp edge_component(node, edge_key) do
    case Prima.Authority.Blob.edge_target(edge_key) do
      :ingress -> node
      {:ok, dep} -> dep
    end
  end

  # Check each required need for a binding. Commit validation ensures each
  # binding names a declared need and that no need has duplicate bindings.
  defp unbound_required(ctx, source_ref, bound) do
    with [] <- bound,
         {:ok, declared, _caps} when is_list(declared) <-
           Sanctum.Consent.ShapeDerivation.manifest_blocks(ctx, source_ref) do
      for need <- declared, need.required do
        %{
          need: need.name,
          satisfied: false,
          detail: "no vault entry bound for '#{need.name}' — grant one to continue"
        }
      end
    else
      _ -> []
    end
  end

  # A selection resolved to its lender's entry is held to the same check.
  defp check_ref(ctx, {:selection, label, {:ok, %{scope: "athanor"} = vault}}),
    do: usable(ctx, vault.entry_id, vault.binding_digest, " (lent by its #{label} profile)", nil)

  # A lent share, read live as the person is offered it at the digest the
  # lender bound (`Sanctum.Consent.row_binding/3`).
  defp check_ref(_ctx, {:selection, label, {:ok, %{scope: "share"} = vault}}),
    do: {vault.entry_id, true, "bound to a shared key (lent by its #{label} profile)"}

  defp check_ref(_ctx, {:selection, label, {:error, reason}}),
    do: {nil, false, unresolved(label, reason)}

  # A share, as the person is offered it, its source at the digest approved.
  defp check_ref(_ctx, {:share, id, {:ok, view}}),
    do: {id, true, "bound to a key shared by #{view.owner}"}

  defp check_ref(_ctx, {:share, id, {:error, :binding_went_stale}}),
    do: {id, false, "the shared key was rebound since this consent — re-approve to continue"}

  defp check_ref(_ctx, {:share, id, {:error, :not_offered}}),
    do: {id, false, "the shared key is no longer offered to you"}

  defp check_ref(_ctx, {:share, id, {:error, :owner_not_standing}}),
    do: {id, false, "the shared key is not available"}

  defp check_ref(_ctx, {:share, id, {:error, {:entry_unavailable, status}}}),
    do: {id, false, "the shared key is #{status}"}

  defp check_ref(_ctx, {:share, id, {:error, refused}})
       when refused in [:denied, :anonymous_denied],
       do: {id, false, "the shared key cannot be used by you"}

  # Any other refusal is a read that failed (`Sanctum.Shares.binding/2`
  # answers the share, its owner and the person in the words above), never
  # a key this person cannot use.
  defp check_ref(_ctx, {:share, id, {:error, _unread}}),
    do: {id, false, "the shared key cannot be read right now — try again"}

  defp check_ref(_ctx, :malformed), do: {nil, false, "the binding names no entry"}

  # The athanor's own entry, live and still at the digest approved; under
  # a binding the component reads itself (`read_itself`, that binding's
  # key, nil otherwise), a disclosed one.
  defp usable(ctx, entry_id, digest, lent, read_itself) do
    # Use the shared vault resolution check for status and binding validity.
    case VaultReader.usable(ctx.athanor_id, entry_id, digest) do
      {:ok, %{attach_only: true}} when is_binary(read_itself) ->
        {entry_id, false,
         "the component reads this value itself and its entry is attach-only — " <>
           remedy(ctx, read_itself)}

      {:ok, entry} ->
        {entry_id, true, "bound to #{entry.name}#{lent}"}

      {:error, {:binding_mismatch, name}} ->
        {entry_id, false,
         "#{name}#{lent} was rebound since this consent — re-approve to continue"}

      {:error, {:entry_unavailable, name, status}} ->
        {entry_id, false, "#{name}#{lent} is #{status}"}

      {:error, :not_found} ->
        {entry_id, false, "the bound vault entry no longer exists"}

      {:error, {:unavailable, _what}} ->
        {entry_id, false, @entry_unread}
    end
  end

  # Why a selection resolves to nothing, in the person's words. A lender
  # the store cannot answer, a damaged one and an absent one are told
  # apart, so an outage or a damaged record never sends the person to
  # grant again over a record that exists. A lender's profile and its
  # head answer alike (`Sanctum.Consent.row_binding/3`).
  defp unresolved(label, {:profile_unavailable, status}),
    do: "the #{label} profile it borrows from is #{status} — re-approve that profile to continue"

  defp unresolved(label, {:lender_unavailable, _target}),
    do: "the #{label} profile it borrows from cannot be read right now — try again"

  # Re-approving cannot repair a damaged lender: the walk reads the head
  # it would revise and refuses one it cannot decode, and never sees a
  # profile row it cannot decode. Revoking that profile by its id
  # (`profile.revoke`) takes it off the target's active profiles, so a
  # new grant takes its place.
  defp unresolved(label, {:lender_corrupt, _target, profile_id}),
    do:
      "the #{label} profile it borrows from is damaged and cannot lend its key — " <>
        "revoke profile #{profile_id} and grant it again"

  defp unresolved(label, {:no_head_consent, _profile_id}),
    do: "the #{label} profile it borrows from has no grant — re-approve that profile to continue"

  defp unresolved(label, {:no_such_profile, _target, _label}),
    do: "no #{label} profile lends a key here — grant one to continue"

  defp unresolved(label, :binding_moved),
    do: "the #{label} profile's key was rebound since this consent — re-approve to continue"

  defp unresolved(label, :nothing_bound), do: "the #{label} profile binds no key"

  # A lent share's answers (`Sanctum.Consent.row_binding/3` tags them), as a
  # share row's are said.
  defp unresolved(label, {:share, :not_offered}),
    do: "the shared key the #{label} profile lends is no longer offered to you"

  defp unresolved(label, {:share, :binding_went_stale}),
    do: "the shared key the #{label} profile lends was rebound since — re-approve to continue"

  defp unresolved(label, {:share, :owner_not_standing}),
    do: "the shared key the #{label} profile lends is not available"

  defp unresolved(label, {:share, {:entry_unavailable, status}}),
    do: "the shared key the #{label} profile lends is #{status}"

  defp unresolved(label, {:share, refused}) when refused in [:denied, :anonymous_denied],
    do: "the shared key the #{label} profile lends cannot be used by you"

  defp unresolved(label, {:share, _unread}),
    do: "the shared key the #{label} profile lends cannot be read right now — try again"

  defp unresolved(label, _reason), do: "the selection of the #{label} profile resolves to nothing"
end
