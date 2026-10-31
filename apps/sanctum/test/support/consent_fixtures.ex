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

  `:origins` are the origins the head admits (`Prima.Origin`), as a
  commit's decisions name them; `[:interactive]` when absent, which is
  what a commit writes when its decisions name none. A case whose runs
  start from a schedule or a webhook names that origin.
  """
  def bindable_profile(%Context{} = ctx, target_ref, opts \\ []) do
    {:ok, name_ref} = Prima.ComponentRef.to_name_ref(target_ref)
    # The smallest policy a head can hold and still be read: a blob that
    # parses and grants nothing. A head whose bytes are no blob is a damaged
    # head, which the loader and the grant plan refuse as such.
    policy = ~s({"canonical":"jcs-1","nodes":{}})
    origins = Keyword.get(opts, :origins, [:interactive])

    case {opts[:profile_id], existing_owner(ctx, name_ref)} do
      {nil, id} when is_binary(id) -> id
      {given, _} -> mint_bindable(ctx, name_ref, given, policy, origins)
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

  defp mint_bindable(%Context{} = ctx, name_ref, given_id, policy, origins) do
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
          blob_digest: Prima.Digest.sha256(policy),
          resolved_policy: policy,
          activation: Jason.encode!(%{name_ref => "sha256:act"}),
          admitted_origins: origins,
          granted_by: "system:fixture",
          granted_via: "bootstrap"
        },
        []
      )

    profile_id
  end

  # Where a key this fixture enters may go when the case names no
  # destination of its own: a host of the fixture's, which no request of a
  # case is ever sent to. Stated here, once, so the entry it writes names
  # its destination as every entry must.
  @fixture_destination %{"hosts" => ["fixture.test"], "scheme" => "https"}

  @doc "The destination this fixture's entries name when a case names none."
  def fixture_destination, do: @fixture_destination

  @doc """
  Connect a key to `ref` as a person does: a new vault entry holding
  `fields`, bound to the component's `api_key` need through the consent
  walk (plan, preview, commit) under the profile `opts[:label]` (default
  `"default"`). `opts[:origins]` names the origins the grant admits, as a
  person ticks them; absent, the commit admits `interactive` alone.

  The component reads the key itself, so the entry is created disclosed
  (`disclose: true`), to `opts[:destination]` or the hosts the
  component's `api_key` need calls, as a consent matches an entry to a
  need, and labelled with the provider that need names. Answers the
  entry.
  """
  def bind_key!(%Context{} = ctx, ref, fields, opts \\ []) when is_map(fields) do
    label = Keyword.get(opts, :label, "default")
    need = declared_need!(ctx, ref, "api_key")

    params = %{
      name: Keyword.get(opts, :name, "key #{System.unique_integer([:positive])}"),
      kind: "api_key",
      provider_hint: need.qualifier,
      fields: fields,
      destination: Keyword.get(opts, :destination, %{"hosts" => need.hosts, "scheme" => "https"}),
      disclose: true
    }

    # Entering the key is a sensitive change, confirmed as its person
    # confirms it (`Sanctum.TestContext.confirmed/3`).
    entering =
      Sanctum.TestContext.confirmed(ctx, :credential_entry, %{
        operation: "vault.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.Vault.create(entering, params)

    {:ok, plan} = Sanctum.Consent.Plan.plan(ctx, %{ref: ref, label: label})

    decisions =
      %{ref: ref, label: label, bindings: [%{need: "api_key", entry_id: entry.id}]}
      |> Prima.MapUtil.put_present(:origins, Keyword.get(opts, :origins))

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

  # `ref`'s credential need `need`, read from the component's manifest as
  # a consent reads it.
  defp declared_need!(ctx, ref, need) do
    {:ok, cref} = Prima.ComponentRef.parse(ref)
    {:ok, row} = Sanctum.Consent.Components.get_latest(ctx, cref.name, cref.namespace, cref.type)
    {:ok, manifest} = Prima.Manifest.decode_strict(Map.get(row, :manifest))
    Enum.find(Prima.Manifest.Needs.from_manifest(manifest), &(&1.name == need))
  end

  @doc """
  Write `profile` and its head revision as rows, spelled in the vocabulary
  a consent read answers in: atoms for kind, status, scope and invoke
  mode, and the activation as a graph. This is the one place those become
  the stored strings, so a case spells the shape it asserts on rather than
  the columns underneath it.

  `admitted_origins` is `[:interactive]` when the case does not spell it,
  as a commit whose decisions name no origins writes it; a case whose
  runs start from another admission path spells the origins it admits.

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

  `shape_digest: :live` is the shape of the source's newest installed
  version, derived as `Sanctum.Consent.ShapeDerivation.live_digest/2`
  derives it, as a commit made now records it, so the head stands for
  that version: a tincture's frame opens under it, and a version that
  reads more asks again. A source with none installed, and a case that
  spells a digest of its own, hold a head that matches no version.
  """
  def seed_head!(%Context{} = ctx, profile, consent) do
    consent =
      consent
      |> Map.put_new_lazy(:blob_digest, fn -> Prima.Digest.sha256(consent.resolved_policy) end)
      |> live_shape(ctx, profile)

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

  # Derived fresh, never from the live-shape cache: a case's rows are
  # written beside the registry, whose sweep would drop a shape an earlier
  # case cached for the same source. A source with no installed version
  # has no shape, and its head names one no version has.
  defp live_shape(%{shape_digest: :live} = consent, ctx, %{source_ref: source_ref}) do
    digest =
      case Sanctum.Consent.ShapeDerivation.shape_input(ctx, source_ref) do
        {:ok, input} ->
          {:ok, digest} = Sanctum.Consent.ShapeDigest.compute(input)
          digest

        {:error, _no_installed_version} ->
          "sha256:no-installed-version"
      end

    %{consent | shape_digest: digest}
  end

  defp live_shape(consent, _ctx, _profile), do: consent

  @doc """
  Grant the tincture `ref` (name-level) as the person would for its newest
  installed version: an active owner profile and an open, versionless head
  at `revision` whose shape is that version's and whose policy grants its
  own node an ingress edge with nothing on it, so its frame opens. The
  profile is `prof_<name>`, `-` spelled `_`, under the label a commit's
  default grant takes, so a case that seeds that id later replaces this
  grant and a commit the person makes revises it. Answers the profile id.
  """
  def grant_tincture!(%Context{} = ctx, ref, revision \\ 1) do
    {:ok, %{name: name}} = Prima.ComponentRef.parse(ref)
    profile_id = "prof_" <> String.replace(name, "-", "_")

    :ok =
      seed_head!(
        ctx,
        %{id: profile_id, kind: :owner, source_ref: ref, label: "default", status: :active},
        %{
          id: "cons_" <> String.replace(name, "-", "_"),
          revision: revision,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: :live,
          commit_digest: "sha256:commit",
          resolved_policy: empty_policy(ref),
          activation: %{ref => "sha256:act"}
        }
      )

    profile_id
  end

  @doc """
  The policy of a grant of the source `ref` (name-level) that gives its
  own node an ingress edge with nothing on it: a head the loader admits,
  granting nothing.
  """
  def empty_policy(ref) when is_binary(ref) do
    Jason.encode!(%{
      "canonical" => "jcs-1",
      "nodes" => %{
        ref => %{
          "limits" => Prima.Test.AuthorityFixtures.limits_map(),
          "edges" => %{"@ingress" => %{}}
        }
      }
    })
  end

  @doc """
  The head of `profile_id` granted again admitting `origins` alone: its
  revision written once more with every other column as it was, as a
  person re-granting with other origins ticked leaves it. Answers the new
  revision.
  """
  def regrant_origins!(%Context{} = ctx, profile_id, origins) when is_list(origins) do
    {:ok, head} = Arca.ConsentStorage.head_consent(Context.actor(ctx), profile_id)

    {:ok, consent} =
      Arca.ConsentStorage.insert_revision(
        %{
          athanor_id: ctx.athanor_id,
          profile_id: profile_id,
          revision: head.revision + 1,
          scope: Atom.to_string(head.scope),
          pinned_version: head.pinned_version,
          invoke_mode: Atom.to_string(head.invoke_mode),
          shape_digest: head.shape_digest,
          commit_digest: head.commit_digest,
          blob_digest: head.blob_digest,
          resolved_policy: head.resolved_policy,
          activation: Jason.encode!(head.activation),
          admitted_origins: origins,
          granted_by: ctx.user_id,
          granted_via: "interactive"
        },
        Enum.map(head.vault_refs, &Map.delete(&1, :scope)),
        head.id
      )

    consent
  end

  @doc """
  The vault entry `id`, minted empty in the fixture's tenant if it is not
  there. A consent reference row names an entry through a foreign key,
  and a binding that named no row could not be committed either. The
  entry holds no material, so it is attach-only, to the fixture's
  destination. A selection's row names no entry and mints none.
  """
  def ensure_entry!(%Context{} = ctx, %{vault_entry_id: id} = ref) when is_binary(id) do
    actor = Context.actor(ctx)

    case Arca.VaultStorage.get(actor, id) do
      {:ok, entry} ->
        entry

      {:error, :not_found} ->
        {:ok, destination} = Sanctum.Vault.destination_text(@fixture_destination)

        {:ok, entry} =
          Arca.VaultStorage.put(actor, %{
            id: id,
            name: "fixture #{id} #{System.unique_integer([:positive])}",
            kind: "api_key",
            field_names: "[]",
            destination: destination,
            attach_only: true,
            binding_digest: Map.get(ref, :binding_digest)
          })

        entry
    end
  end

  def ensure_entry!(%Context{}, _ref), do: nil

  @doc """
  Write `changes` straight onto the profile's head revision, past every
  writer's guard — a hand edit, a restored backup, or any write path that
  reaches the column.

  This is the only way to express a stored row the storage layer refuses
  to create (an empty `blob_digest`, say). The loader's checks against those
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
    {:ok, _} = Arca.Test.Writers.put_profile(profile_attrs(ctx, profile))
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
      # What a commit writes when its decisions name no origins; a case
      # whose runs start elsewhere spells the origins it admits.
      admitted_origins: Map.get(consent, :admitted_origins, [:interactive]),
      granted_by: "system:fixture",
      granted_via: "bootstrap"
    }
  end
end
