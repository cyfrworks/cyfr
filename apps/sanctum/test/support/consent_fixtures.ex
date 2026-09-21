# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.ConsentFixtures do
  @moduledoc """
  Seeds a bindable owner profile so tests can create profile-bound
  registrations (webhooks, schedules) without walking the full consent
  sheet, and connects a key to a component through the full walk
  (`bind_key!/4`).

  `bindable_profile/3` writes the profile and its first revision the way
  provisioning does — one transaction through `Arca.ConsentStorage` — so
  the fixture is the same row a run reads, and no store of its own has to
  be started or forgotten.
  """

  import Ecto.Query

  alias Sanctum.Context

  @doc """
  Seed an active owner profile + head consent for `target_ref` in the
  context's tenant and return its profile id.

  The profile is keyed at name level (binding authorizes against the
  registration's own target), and the consent is a minimal open_inert
  versionless head — enough for `RegistrationBinding.authorize/3` to pass
  for an interactive (oidc) context.

  An athanor has at most one active owner profile per target and label, so
  a second call for the same target answers the first one's id rather than
  minting a row the active-identity index would refuse. `:profile_id`
  spells the id and replaces whatever is there.
  """
  def bindable_profile(%Context{} = ctx, target_ref, opts \\ []) do
    {:ok, name_ref} = Cyfr.ComponentRef.to_name_ref(target_ref)
    policy = "{}"

    case {opts[:profile_id], existing_owner(ctx, name_ref)} do
      {nil, id} when is_binary(id) -> id
      {given, _} -> mint_bindable(ctx, name_ref, given, policy)
    end
  end

  defp existing_owner(%Context{} = ctx, name_ref) do
    case Arca.ConsentStorage.profiles(Context.actor(ctx), name_ref) do
      {:ok, profiles} ->
        Enum.find_value(profiles, fn p ->
          if p.kind == :owner and p.label == "default" and p.status == :active, do: p.id
        end)

      _ ->
        nil
    end
  end

  defp mint_bindable(%Context{} = ctx, name_ref, given_id, policy) do
    profile_id = given_id || "prof-#{System.unique_integer([:positive])}"
    forget!(ctx, profile_id)

    {:ok, _consent} =
      Arca.ConsentStorage.mint_profile_with_revision(
        %{
          id: profile_id,
          athanor_id: ctx.athanor_id,
          source_ref: name_ref,
          kind: "owner",
          label: "default",
          status: "active"
        },
        %{
          profile_id: profile_id,
          revision: 1,
          scope: "versionless",
          pinned_version: "",
          invoke_mode: "open_inert",
          shape_digest: "sha256:shape-#{profile_id}",
          commit_digest: "sha256:commit-#{profile_id}",
          # Derived, never a literal: `Consent.Loader` refuses a row whose
          # stored digest does not match its policy bytes, so a fixture that
          # hardcoded one would drift the moment the policy changed.
          blob_digest: Cyfr.JCS.hash_binary(policy),
          resolved_policy: policy,
          activation: Jason.encode!(%{name_ref => "sha256:act"}),
          granted_by: "system:fixture",
          granted_via: "bootstrap"
        },
        []
      )

    profile_id
  end

  @doc """
  Connect a key to `ref` as a person does: a new vault entry holding
  `fields`, bound to the component's `api_key` need through the consent
  walk (plan, preview, commit) under the profile `opts[:label]` (default
  `"default"`). Answers the entry.
  """
  def bind_key!(%Context{} = ctx, ref, fields, opts \\ []) when is_map(fields) do
    label = Keyword.get(opts, :label, "default")

    {:ok, entry} =
      Sanctum.Vault.create(ctx, %{
        name: Keyword.get(opts, :name, "key #{System.unique_integer([:positive])}"),
        kind: "api_key",
        fields: fields
      })

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref, label: label})
    decisions = %{ref: ref, label: label, bindings: [%{need: "api_key", entry_id: entry.id}]}
    {:ok, preview} = Sanctum.Consent.Commit.preview(ctx, decisions)

    {:ok, _} =
      Sanctum.Consent.Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    entry
  end

  @doc """
  Write `profile` and its head revision as rows, spelled in the vocabulary
  a consent read answers in: atoms for kind, status, scope and invoke
  mode, and the activation as a graph. This is the one place those become
  the stored strings, so a case spells the shape it asserts on rather than
  the columns underneath it.

  `blob_digest` is derived from the policy when the case does not spell
  one — the loader refuses a row whose digest and bytes disagree, and a
  case that swapped the policy is usually about something else. A case
  that IS about the mismatch spells the digest and keeps it.

  Re-seeding the same profile id within a case replaces what the previous
  seed wrote: several cases re-spell one profile to walk it through the
  states a load must refuse, and the active-identity index would otherwise
  stop the second spelling.

  Each vault entry a ref names is minted first if it does not exist: a
  reference row carries a foreign key to the entry, so a case that spells
  a binding spells an entry that is there, as a commit's would be.
  """
  def seed_head!(%Context{} = ctx, profile, consent) do
    consent =
      Map.put_new_lazy(consent, :blob_digest, fn ->
        Cyfr.JCS.hash_binary(consent.resolved_policy)
      end)

    forget!(ctx, profile.id)
    vault_refs = Map.get(consent, :vault_refs, [])
    Enum.each(vault_refs, &ensure_entry!(ctx, &1))

    {:ok, _} =
      Arca.ConsentStorage.mint_profile_with_revision(
        profile_attrs(ctx, profile),
        consent_attrs(profile, consent),
        vault_refs
      )

    :ok
  end

  @doc """
  The vault entry `id`, minted empty in the fixture's tenant if it is not
  there. A consent reference row names an entry through a foreign key,
  and a binding that named no row could not be committed either.
  """
  def ensure_entry!(%Context{} = ctx, %{vault_entry_id: id} = ref) do
    actor = Context.actor(ctx)

    case Arca.VaultStorage.get(actor, id) do
      {:ok, entry} ->
        entry

      {:error, :not_found} ->
        {:ok, entry} =
          Arca.VaultStorage.put(actor, %{
            id: id,
            name: "fixture #{id} #{System.unique_integer([:positive])}",
            kind: "api_key",
            field_names: "[]",
            binding_digest: Map.get(ref, :binding_digest)
          })

        entry
    end
  end

  @doc """
  Write `changes` straight onto the profile's head revision, past every
  writer's guard — a hand edit, a restored backup, or any write path that
  reaches the column.

  This is the only way to express a stored row the storage layer refuses
  to create (a NULL `blob_digest`, say). The loader's checks against those
  rows exist precisely because the column can be reached without the
  writer, so a case that asserts on one has to reach it the same way.
  """
  def hand_edit_head!(%Context{} = ctx, profile_id, changes) when is_list(changes) do
    {:ok, profile} = Arca.ProfileStorage.get(Context.actor(ctx), profile_id)

    {1, _} =
      Arca.Repo.update_all(
        from(c in Arca.Schemas.Consent,
          where: c.athanor_id == ^ctx.athanor_id and c.id == ^profile.head_consent_id
        ),
        set: changes
      )

    :ok
  end

  @doc """
  A profile row with no head revision — the shape `Consent.Loader` refuses
  with `{:no_head_consent, id}`, and the only one the two-row mint above
  cannot produce.
  """
  def seed_profile!(%Context{} = ctx, profile) do
    forget!(ctx, profile.id)
    {:ok, _} = Arca.ProfileStorage.put(profile_attrs(ctx, profile))
    :ok
  end

  # Drop a seeded profile and everything hanging from it, within the
  # fixture's own tenant. Test support, so it reaches the tables directly;
  # production has no such verb and must not grow one — a consent is
  # history, and history is not deleted.
  defp forget!(%Context{athanor_id: athanor_id}, profile_id) do
    consent_ids =
      Arca.Repo.all(
        from(c in Arca.Schemas.Consent,
          where: c.athanor_id == ^athanor_id and c.profile_id == ^profile_id,
          select: c.id
        )
      )

    Arca.Repo.delete_all(
      from(r in Arca.Schemas.ConsentVaultRef,
        where: r.athanor_id == ^athanor_id and r.consent_id in ^consent_ids
      )
    )

    Arca.Repo.delete_all(
      from(c in Arca.Schemas.Consent,
        where: c.athanor_id == ^athanor_id and c.profile_id == ^profile_id
      )
    )

    Arca.Repo.delete_all(
      from(p in Arca.Schemas.Profile,
        where: p.athanor_id == ^athanor_id and p.id == ^profile_id
      )
    )

    :ok
  end

  defp profile_attrs(%Context{} = ctx, profile) do
    %{
      id: profile.id,
      athanor_id: ctx.athanor_id,
      source_ref: profile.source_ref,
      kind: Atom.to_string(profile.kind),
      label: Map.get(profile, :label, "default"),
      status: Atom.to_string(Map.get(profile, :status, :active))
    }
  end

  defp consent_attrs(profile, consent) do
    %{
      id: consent.id,
      profile_id: profile.id,
      revision: consent.revision,
      scope: Atom.to_string(consent.scope),
      pinned_version: Map.get(consent, :pinned_version, ""),
      invoke_mode: Atom.to_string(Map.get(consent, :invoke_mode, :open_inert)),
      shape_digest: consent.shape_digest,
      commit_digest: consent.commit_digest,
      blob_digest: consent.blob_digest,
      resolved_policy: consent.resolved_policy,
      activation: Jason.encode!(consent.activation),
      granted_by: "system:fixture",
      granted_via: "bootstrap"
    }
  end
end
