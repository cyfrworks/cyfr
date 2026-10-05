# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.ConsentSetupPlan do
  @moduledoc """
  The consent-sourced half of `Compendium.Component.setup_plan/2`.

  A profile is ready only when every required need has a live vault binding
  whose digest matches the consent. Rebinding or revocation can make it
  unready without changing the manifest.

  Each row of the head revision is read by what it names
  (`Sanctum.Consent.row_binding/3`): the athanor's own entry, held
  to the digest the person approved; a selection of another profile's
  key, resolved as a run resolves it and its lender's entry held to the
  same check, or reported not ready with the reason it resolves to
  nothing; and an instance entry, read as the person is offered it and
  held to the digest the person approved.

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

  @doc """
  The consent section for a source ref, or `nil` when no profile exists
  (the component then reads ready only if it requires nothing).

  A store that cannot be read, or a profile row that cannot be decoded
  where the one asked about would be, is a section that is not ready
  (`profile_status: :unavailable` or `:corrupt`, with `head_state`
  `"unavailable"` or `"damaged"` and its `reason`) — never `nil`, which
  would read "nothing granted" and let a component that needs nothing
  report ready on a store nobody could read.

  A profile's section carries its head's `head_state`, as `profile.list`
  names it: `"present"` when the head was read, and otherwise
  `"missing"`, `"damaged"` or `"unavailable"`, each with the `reason`
  sentence a person can act on.
  """
  @spec section(Context.t(), String.t()) :: map() | nil
  def section(%Context{} = ctx, source_ref) do
    with {:ok, name_ref} <- name_ref(source_ref),
         {:ok, [_ | _] = entries} <- read_profiles(ctx, name_ref) do
      case pick_profile(entries) do
        %{status: :corrupt} = corrupt -> not_ready(corrupt.id, :corrupt)
        profile -> describe(ctx, profile)
      end
    else
      {:error, :unavailable} -> not_ready(nil, :unavailable)
      _ -> nil
    end
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
      _ -> :error
    end
  end

  # The owner profile is what "is this set up" asks about; a public twin
  # is a separate, deliberately narrower grant. A row that cannot be
  # decoded may be the owner, so it is what the section reports whenever
  # no decoded owner answers.
  defp pick_profile(entries) do
    Enum.find(entries, &(Map.get(&1, :kind) == :owner)) ||
      Enum.find(entries, &(&1.status == :corrupt)) || hd(entries)
  end

  defp describe(ctx, profile) do
    case Sanctum.Consent.head_consent(ctx, profile.id) do
      {:ok, consent} ->
        bound = check_needs(ctx, consent)
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

  # One row per binding the head consent carries, read by what it names.
  defp check_needs(ctx, consent) do
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

      %{
        entry_id: entry_id,
        satisfied: satisfied,
        detail: detail
      }
    end)
  end

  # The bindings the component reads itself: the bound entries whose edge
  # carries no attach rule. An unreadable policy names none, which leaves
  # every row to its own check.
  defp read_itself_keys(consent) do
    case Prima.Authority.Blob.parse(consent.resolved_policy) do
      {:ok, %Prima.Authority.Blob{nodes: nodes}} ->
        for {_node, %{edges: edges}} <- nodes,
            {_key, %{vault: %{entry_id: _, attach: nil} = vault}} <- edges,
            bound <- [vault | Map.values(Map.get(vault, :named, %{}))],
            into: MapSet.new(),
            do: bound.binding_key

      _unreadable ->
        MapSet.new()
    end
  end

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

  # A lent instance entry, read live as the person is offered it at the
  # digest the lender bound (`Sanctum.Consent.row_binding/3`).
  defp check_ref(_ctx, {:selection, label, {:ok, %{scope: "instance"} = vault}}),
    do: {vault.entry_id, true, "bound to an instance entry (lent by its #{label} profile)"}

  defp check_ref(_ctx, {:selection, label, {:error, reason}}),
    do: {nil, false, unresolved(label, reason)}

  # An instance entry, as the person is offered it, at the digest approved.
  defp check_ref(_ctx, {:instance, id, {:ok, view}}),
    do: {id, true, "bound to #{view.name}, an instance entry"}

  defp check_ref(_ctx, {:instance, id, {:error, :binding_went_stale}}),
    do: {id, false, "the instance entry was rebound since this consent — re-approve to continue"}

  defp check_ref(_ctx, {:instance, id, {:error, :not_offered}}),
    do: {id, false, "the instance entry is no longer offered to you"}

  defp check_ref(_ctx, {:instance, id, {:error, {:entry_unavailable, status}}}),
    do: {id, false, "the instance entry is #{status}"}

  defp check_ref(_ctx, {:instance, id, {:error, _refused}}),
    do: {id, false, "the instance entry cannot be used by you"}

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

  defp unresolved(label, {:consent_required, _payload}),
    do: "the #{label} profile's grant does not admit this origin"

  defp unresolved(label, :not_offered),
    do: "the instance entry the #{label} profile lends is no longer offered to you"

  defp unresolved(label, :binding_went_stale),
    do: "the instance entry the #{label} profile lends was rebound since — re-approve to continue"

  defp unresolved(label, {:entry_unavailable, status}),
    do: "the instance entry the #{label} profile lends is #{status}"

  defp unresolved(label, _reason), do: "the selection of the #{label} profile resolves to nothing"
end
