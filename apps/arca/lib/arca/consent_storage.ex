# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ConsentStorage do
  @moduledoc """
  Persistence mechanics for consent revisions.

  Consents are insert-only: this module deliberately exports **no update
  function** of a revision, and a test pins the export list. A revision,
  its bindings (`consent_vault_refs`, one row per binding key) and the
  profile's head advance commit in one transaction — a consent that
  exists but is not the head is history, and a head pointing at a missing
  revision is unrepresentable. The one write a binding row takes after
  its revision commits is the consumption of a `once` binding
  (`consume_once/5`).

  ## Consumption and replacement serialize on the profile

  `insert_revision/4` and `consume_once/5` each take the profile row's
  lock (`Arca.QueryHelpers.for_update/1` inside
  `Arca.Repo.locking_transaction/2`) before anything else. A consumption
  is admitted only against the profile's current head and writes that
  head's row alone; a superseding revision reads the superseded head's
  rows under the same lock and copies each `consumed_by_root` onto the
  new row with the same key, entry, scope and lifetime, unless the
  decision marks that binding `renew`. So a revision observes every
  consumption committed before it, a consumption observes the head it is
  written against, and a consumed `once` is renewed only by a decision
  that says so.

  ## A revision and a change to an entry it binds serialize on the entry

  `insert_revision/4` and `mint_profile_with_revision/4` take, as their
  transaction's first steps and before the profile's lock or insert, a
  shared lock on every instance entry their bindings name and then on
  every entry of the athanor's own they name
  (`Arca.QueryHelpers.for_share/1`, each in id order), and refuse with
  nothing written when one is not `active` (`{:error, {:entry_unavailable,
  status}}`) or has no row (`{:error, :not_found}`; an athanor's entry is
  read in the revision's athanor alone). `Arca.InstanceEntries`' revoke
  and tombstone, and `Arca.VaultStorage`'s binding move, write the entry
  row and then lock the profiles whose heads bind it, so the two meet in
  one order: a change that lands first is seen here (a status refused, a
  moved digest refused by the caller's in-transaction re-read), and a
  revision that lands first is seen by the change's head query, which
  blocks its profile. A revoke of an athanor's entry writes the row and
  blocks no profile, so the status refused here is what holds a revision
  to it. A selection names no entry on the borrower's row and takes no
  lock.

  The one order is the entry rows by id, then the profile. Every writer
  that holds more than one entry row in a transaction takes them in it:
  this revision (each table in id order, instance entries first; no other
  transaction holds rows of both tables), `Arca.RecordSink`'s batch of
  last-used touches (`{athanor_id, id}` order) and
  `Arca.TenantTables.delete_all_for/1`, which runs only on an archived
  athanor, one no context can focus and no seed sync revises, so no
  revision is written beside it. Every other writer of an entry
  row holds that one row: a binding move, a status or payload write, a
  tombstone, a cipher rotation's compare-and-set, a last-used touch and
  `Arca.VaultDefaults.set/3`'s read of the entry it names.

  `profiles/2` and `head_consent/2` are the read side the consent decision
  logic (`Sanctum.Consent.Loader` and the walk around it) sees. They decode
  strictly and fail closed: a stored kind, status, scope or invoke mode
  outside the closed vocabulary, or an activation blob that does not parse,
  drops the profile or refuses the consent rather than guessing. Rows can
  only get that way through a bug or a hand edit, and neither may root an
  execution. `profile_entries/2` is the same read with nothing dropped: an
  undecodable profile is present as `%{id: id, status: :corrupt}`, for the
  readers that must tell a damaged row from an absent one.
  """

  import Ecto.Query

  alias Arca.Schemas.Consent
  alias Arca.Schemas.ConsentVaultRef

  @typedoc """
  One immutable consent revision, decoded.

  `vault_refs` carries the derived reverse-index rows for the revision —
  the consent decision's blob/refs equality check needs both sides, and
  delivering them together keeps the check atomic with the read.

  The atoms are spelled here rather than borrowed from the layer above:
  this is the closed vocabulary the column holds, and the decision layer's
  own types are defined against the same words.
  """
  @type consent :: %{
          required(:id) => String.t(),
          required(:revision) => non_neg_integer(),
          required(:scope) => :versionless | :pinned,
          required(:pinned_version) => String.t(),
          required(:invoke_mode) => :open_inert | :edge_only,
          required(:shape_digest) => String.t(),
          required(:commit_digest) => String.t(),
          required(:blob_digest) => String.t() | nil,
          required(:resolved_policy) => String.t(),
          required(:activation) => %{String.t() => String.t()},
          required(:admitted_origins) => [Prima.Origin.t(), ...],
          required(:vault_refs) => [binding_ref()]
        }

  @typedoc """
  One binding of a revision as it is read back: its key, its scope, the
  one thing it names (an athanor's entry, an instance entry or a
  selection's label; the other two nil), the digest it was approved at
  (nil for a selection that pinned none) and its lifetime.
  """
  @type binding_ref :: %{
          binding_key: String.t(),
          scope: String.t(),
          vault_entry_id: String.t() | nil,
          instance_entry_id: String.t() | nil,
          via_label: String.t() | nil,
          binding_digest: String.t() | nil,
          lifetime_kind: String.t(),
          expires_at: DateTime.t() | nil,
          consumed_by_root: String.t() | nil
        }

  @typedoc """
  One binding as a revision's writer names it: `binding_key`, `scope`
  (`"athanor"` or `"instance"`), exactly one of `vault_entry_id` (scope
  `athanor`), `instance_entry_id` (scope `instance`) and `via_label` (a
  selection, scope `athanor`), `binding_digest` (required of an entry, the
  pinned one or nil for a selection), the lifetime (`lifetime_kind`,
  `standing` when absent, and `expires_at`, required of `until` and
  refused of the others) and `renew`, whether the decision renews a
  consumed `once` binding.
  """
  @type ref_input :: %{
          required(:binding_key) => String.t(),
          required(:scope) => String.t(),
          optional(:vault_entry_id) => String.t() | nil,
          optional(:instance_entry_id) => String.t() | nil,
          optional(:via_label) => String.t() | nil,
          optional(:binding_digest) => String.t() | nil,
          optional(:lifetime_kind) => String.t(),
          optional(:expires_at) => DateTime.t() | nil,
          optional(:renew) => boolean()
        }

  @doc """
  Insert one revision with its bindings and advance the profile head,
  atomically. `expected_head` is the CAS token (nil for revision 1).

  `vault_refs` is one `t:ref_input/0` per binding, unique by
  `binding_key`; a row naming none or two of an entry, an instance entry
  and a selection, a scope its entry does not match, an entry without its
  digest, an `until` without `expires_at`, any other lifetime with one,
  or a key twice is refused `{:error, {:invalid, %{vault_refs: [why]}}}`
  with nothing written (`Arca.Schemas.ConsentVaultRef.changeset/1`). The profile row is locked before anything else, the
  superseded head's rows are read under that lock, and a new row whose
  key, entry, scope and lifetime equal a superseded row's keeps that
  row's `consumed_by_root` unless it says `renew`. The head then advances
  by compare-and-set as a second guard. Before the profile's lock, every
  instance entry and then every athanor's entry a binding names is locked
  shared and must be `active` (`{:error, {:entry_unavailable, status}}`,
  or `{:error, :not_found}` for one with no row), with nothing written
  otherwise.

  `opts[:verify]` is a zero-arity function run **inside the transaction**,
  after the refs land and before the head advances — the seam a consent
  commit uses to re-verify binding liveness so a `vault.rebind` racing the
  commit rolls the whole revision back. It must return `:ok` or
  `{:error, reason}` and must only read.

  `opts[:reactivate]` (default false) makes the revision a re-consent:
  after the head advances, under the profile lock already held, a profile
  at `needs_consent` is set `active` by a conditional write, and any
  other status is left as it is. A revoke that blocks the profile then
  lands wholly before the revision or after it, never between the
  revision and its reactivation.

  `attrs[:admitted_origins]` is the non-empty list of origins the revision
  admits (`Prima.Origin` atoms or their wire spellings), stored as their
  spellings in the enum's order; a revision without it, an empty list, a
  duplicate or an origin outside the enum is refused `{:error, {:invalid,
  %{admitted_origins: …}}}` with nothing written. A stored revision whose
  origins are absent or do not parse does not decode, so no reader meets
  a revision that admits none.
  """
  @spec insert_revision(map(), [map()], String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def insert_revision(attrs, vault_refs, expected_head, opts \\ []) when is_map(attrs) do
    athanor_id = Map.fetch!(attrs, :athanor_id)

    with {:ok, row} <- revision_row(attrs, athanor_id),
         {:ok, refs} <- ref_inputs(vault_refs, row.id, athanor_id) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:instances, fn _repo, _done -> lock_instance_entries(refs) end)
      |> Ecto.Multi.run(:entries, fn _repo, _done -> lock_vault_entries(refs, athanor_id) end)
      |> Ecto.Multi.run(:locked, fn _repo, _done ->
        {:ok, lock_profile!(athanor_id, row.profile_id)}
      end)
      |> Ecto.Multi.run(:superseded, fn _repo, %{locked: head} ->
        {:ok, superseded_rows(athanor_id, head, expected_head)}
      end)
      |> revision_multi(row, refs, expected_head, athanor_id, opts)
      |> run_multi(:consent)
    end
  end

  @doc """
  Mint a profile together with its first revision in one transaction —
  a failed consent insert must not leave an orphan profile whose
  `head_consent_id` is forever NULL. The instance entries and the
  athanor's entries its bindings name are locked and held to `active`
  first, as `insert_revision/4` holds them.
  """
  @spec mint_profile_with_revision(map(), map(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mint_profile_with_revision(profile_attrs, consent_attrs, vault_refs, opts \\ []) do
    athanor_id = Map.fetch!(profile_attrs, :athanor_id)

    with {:ok, row} <- revision_row(consent_attrs, athanor_id),
         {:ok, refs} <- ref_inputs(vault_refs, row.id, athanor_id) do
      # Through the schema's changeset, never a raw struct: the label rule
      # and the kind/status vocabulary are the changeset's, and this is the
      # one production mint of a profile. A new profile supersedes nothing.
      Ecto.Multi.new()
      |> Ecto.Multi.run(:instances, fn _repo, _done -> lock_instance_entries(refs) end)
      |> Ecto.Multi.run(:entries, fn _repo, _done -> lock_vault_entries(refs, athanor_id) end)
      |> Ecto.Multi.insert(
        :profile,
        Arca.Schemas.Profile.changeset(%Arca.Schemas.Profile{}, profile_attrs)
      )
      |> Ecto.Multi.put(:superseded, %{})
      |> revision_multi(row, refs, nil, athanor_id, opts)
      |> run_multi(:consent)
    end
  end

  # Every binding a revision names, held to the row's rules before
  # anything is written, so a refusal is a typed answer and never a
  # constraint raised from the middle of the transaction.
  defp ref_inputs(refs, consent_id, athanor_id) when is_list(refs) do
    with {:ok, rows} <- collect(refs, &ref_input(&1, consent_id, athanor_id)),
         :ok <- distinct_keys(rows) do
      {:ok, rows}
    end
  end

  defp ref_inputs(_refs, _consent_id, _athanor_id), do: invalid_refs("is a list of bindings")

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # One binding through the row's changeset: the row it inserts, with the
  # decision's `renew` beside it for the carry.
  defp ref_input(%{} = ref, consent_id, athanor_id) do
    renew = Map.get(ref, :renew, false)
    expires_at = Map.get(ref, :expires_at)

    attrs =
      ref
      |> Map.take([
        :binding_key,
        :scope,
        :vault_entry_id,
        :instance_entry_id,
        :via_label,
        :binding_digest,
        :lifetime_kind
      ])
      |> Map.put_new(:lifetime_kind, "standing")
      |> Map.put(:expires_at, expires_at && truncated(expires_at))
      |> Map.merge(%{consent_id: consent_id, athanor_id: athanor_id})

    changeset = ConsentVaultRef.changeset(attrs)

    cond do
      not is_boolean(renew) ->
        invalid_refs("says renew as true or false")

      not changeset.valid? ->
        {:error, {:invalid, %{vault_refs: Enum.map(changeset.errors, &ref_error/1)}}}

      true ->
        row = Ecto.Changeset.apply_changes(changeset)

        {:ok,
         %{
           binding_key: row.binding_key,
           scope: row.scope,
           vault_entry_id: row.vault_entry_id,
           instance_entry_id: row.instance_entry_id,
           via_label: row.via_label,
           binding_digest: row.binding_digest,
           lifetime_kind: row.lifetime_kind,
           expires_at: row.expires_at,
           renew: renew
         }}
    end
  end

  defp ref_input(_ref, _consent_id, _athanor_id), do: invalid_refs("is a binding")

  defp ref_error({field, {message, _meta}}), do: "#{field} #{message}"

  defp truncated(%DateTime{} = at), do: DateTime.truncate(at, :microsecond)
  defp truncated(other), do: other

  defp distinct_keys(rows) do
    keys = Enum.map(rows, & &1.binding_key)

    if length(Enum.uniq(keys)) == length(keys),
      do: :ok,
      else: invalid_refs("names a binding key twice")
  end

  defp invalid_refs(why), do: {:error, {:invalid, %{vault_refs: [why]}}}

  # The instance entries the bindings name, held shared in id order to the
  # end of the transaction: a revoke or a tombstone, which writes the
  # entry row before it reads the heads that bind it, waits for this
  # revision or is seen by it. Each must be active, and a row that is gone
  # names nothing to bind.
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows a revision names, read by id.
  defp lock_instance_entries(refs) do
    case refs |> Enum.map(& &1.instance_entry_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        {:ok, %{}}

      ids ->
        from(i in Arca.Schemas.InstanceEntry,
          where: i.id in ^ids,
          order_by: i.id,
          select: {i.id, i.status}
        )
        |> Arca.QueryHelpers.for_share()
        |> Arca.Repo.all()
        |> all_active(ids)
    end
  end

  # The athanor's own entries the bindings name, held shared in id order
  # the same way, after the instance entries and before the profile: a
  # rebind, which writes the entry row by compare-and-set before it reads
  # the heads that bind it, waits for this revision or is seen by its
  # in-transaction digest re-read, and a revoke, which writes the row and
  # blocks no profile, is refused here by the status. Each must be active,
  # and a row that is gone, or another athanor's, names nothing to bind.
  defp lock_vault_entries(refs, athanor_id) do
    case refs |> Enum.map(& &1.vault_entry_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        {:ok, %{}}

      ids ->
        from(v in Arca.Schemas.VaultEntry,
          where: v.id in ^ids,
          order_by: v.id,
          select: {v.id, v.status}
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.QueryHelpers.for_share()
        |> Arca.Repo.all()
        |> all_active(ids)
    end
  end

  defp all_active(rows, ids) do
    held = Map.new(rows)

    Enum.reduce_while(Enum.sort(ids), {:ok, held}, fn id, acc ->
      case Map.fetch(held, id) do
        {:ok, "active"} -> {:cont, acc}
        {:ok, status} -> {:halt, {:error, {:entry_unavailable, status}}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
  end

  # The profile row, locked before the revision reads or writes anything,
  # answering the head it holds (nil for none, or a profile that is gone:
  # the head's compare-and-set then refuses).
  # arca:db-raise-ok a step inside the revision's transaction; a raise rolls it back.
  defp lock_profile!(athanor_id, profile_id) do
    from(p in Arca.Schemas.Profile, where: p.id == ^profile_id, select: p.head_consent_id)
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # The rows of the head this revision supersedes, read under the
  # profile's lock, by key. Only when the head is the one the writer
  # expected: otherwise the compare-and-set refuses and nothing is copied.
  defp superseded_rows(_athanor_id, nil, _expected_head), do: %{}

  defp superseded_rows(athanor_id, head, head) do
    from(r in ConsentVaultRef, where: r.consent_id == ^head)
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.Repo.all()
    |> Map.new(&{&1.binding_key, &1})
  end

  defp superseded_rows(_athanor_id, _head, _expected_head), do: %{}

  # A consumed `once` stays consumed across a revision that leaves its
  # binding as it was; `renew` is the decision that makes it consumable
  # again.
  defp carried_root(%{renew: true}, _superseded), do: nil

  defp carried_root(ref, superseded) do
    case Map.get(superseded, ref.binding_key) do
      %ConsentVaultRef{} = old ->
        if same_binding?(old, ref), do: old.consumed_by_root, else: nil

      nil ->
        nil
    end
  end

  # The same binding: the same tagged identity (what it names, under which
  # scope and key, at which digest) and the same lifetime. Rows naming no
  # entry never match on their null ids: a selection matches a selection
  # of the same label and pin, and nothing else.
  defp same_binding?(old, ref) do
    row_identity(old) == row_identity(ref) and
      old.lifetime_kind == ref.lifetime_kind and
      same_time?(old.expires_at, ref.expires_at)
  end

  @doc false
  # A binding row's identity, tagged by what it names: an athanor's entry,
  # an instance entry or a selection, each with its scope, key and the
  # digest it was approved at. `Sanctum.Consent.Loader` holds a blob to its
  # rows by the same identity.
  @spec row_identity(map()) ::
          {:entry | :instance, String.t(), String.t(), String.t(), String.t()}
          | {:via, String.t(), String.t(), String.t(), String.t() | nil}
          | :none
  def row_identity(%{vault_entry_id: id} = row) when is_binary(id),
    do: {:entry, row.scope, row.binding_key, id, row.binding_digest}

  def row_identity(%{instance_entry_id: id} = row) when is_binary(id),
    do: {:instance, row.scope, row.binding_key, id, row.binding_digest}

  def row_identity(%{via_label: label} = row) when is_binary(label),
    do: {:via, row.scope, row.binding_key, label, row.binding_digest}

  def row_identity(_row), do: :none

  defp same_time?(nil, nil), do: true

  defp same_time?(%DateTime{} = a, %DateTime{} = b),
    do: DateTime.compare(DateTime.truncate(a, :microsecond), b) == :eq

  defp same_time?(_a, _b), do: false

  defp revision_row(attrs, athanor_id) do
    # A nonempty blob_digest is required to verify resolved_policy.
    # Reject nil and empty strings before the raw struct insert.
    case Map.fetch!(attrs, :blob_digest) do
      digest when is_binary(digest) and digest != "" ->
        :ok

      other ->
        raise ArgumentError,
              "consent revisions require a blob_digest, got: #{Prima.LoggerContext.shape(other)}"
    end

    with {:ok, origins} <- admitted_origins(Map.get(attrs, :admitted_origins)) do
      {:ok,
       attrs
       |> Map.put(:athanor_id, athanor_id)
       |> Map.put(:admitted_origins, origins)
       |> Map.put_new(:id, Prima.UUID7.generate_id("cons"))
       |> Map.put_new(:granted_at, DateTime.utc_now())}
    end
  end

  # The origins a revision admits, as the column stores them: a JSON array
  # of wire spellings in the enum's order. A revision names them or is not
  # written.
  defp admitted_origins(origins) when is_list(origins) do
    spellings =
      Enum.map(origins, fn
        origin when is_atom(origin) and not is_nil(origin) and not is_boolean(origin) ->
          if Prima.Origin.origin?(origin), do: Prima.Origin.to_wire(origin), else: origin

        spelling ->
          spelling
      end)

    case Prima.Origin.parse_list(spellings) do
      {:ok, parsed} -> {:ok, Jason.encode!(Prima.Origin.to_wire_list(parsed))}
      {:error, reason} -> {:error, {:invalid, %{admitted_origins: [origin_refusal(reason)]}}}
    end
  end

  defp admitted_origins(_origins),
    do: {:error, {:invalid, %{admitted_origins: ["is a non-empty list of origins"]}}}

  defp origin_refusal(:empty_origins), do: "is a non-empty list of origins"
  defp origin_refusal(:duplicate_origin), do: "names an origin twice"
  defp origin_refusal({:unknown_origin, _spelling}), do: "names an origin outside the enum"

  defp revision_multi(multi, row, refs, expected_head, athanor_id, opts) do
    verify = Keyword.get(opts, :verify, fn -> :ok end)

    # A writer that lost the race to the same revision meets the unique
    # index before the head CAS; both answer `:head_moved`.
    consent =
      Consent
      |> struct(row)
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:profile_id, :revision])

    multi
    |> Ecto.Multi.insert(:consent, consent)
    |> Ecto.Multi.run(:refs, fn _repo, %{superseded: superseded} ->
      ref_rows =
        Enum.map(refs, fn ref ->
          %{
            consent_id: row.id,
            athanor_id: athanor_id,
            binding_key: ref.binding_key,
            scope: ref.scope,
            vault_entry_id: ref.vault_entry_id,
            instance_entry_id: ref.instance_entry_id,
            via_label: ref.via_label,
            binding_digest: ref.binding_digest,
            lifetime_kind: ref.lifetime_kind,
            expires_at: ref.expires_at,
            consumed_by_root: carried_root(ref, superseded)
          }
        end)

      # insert_all cannot signal a partial write through its return shape;
      # the count assertion is what makes the refs leg able to fail at all.
      case insert_refs(ref_rows) do
        {count, _} when count == length(ref_rows) -> {:ok, count}
        {count, _} -> {:error, {:refs_partial_insert, count, length(ref_rows)}}
      end
    end)
    |> Ecto.Multi.run(:verify, fn _repo, _done ->
      case verify.() do
        :ok -> {:ok, :verified}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Ecto.Multi.run(:head, fn _repo, _done ->
      case Arca.ProfileStorage.advance_head(
             Prima.Actor.in_athanor(athanor_id),
             row.profile_id,
             expected_head,
             row.id
           ) do
        :ok -> {:ok, :advanced}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Ecto.Multi.run(:reactivated, fn _repo, _done ->
      if Keyword.get(opts, :reactivate, false),
        do: {:ok, reactivate(athanor_id, row.profile_id)},
        else: {:ok, 0}
    end)
  end

  # A profile blocked at `needs_consent` is unblocked by the revision that
  # re-consents it, in the revision's own transaction and under the
  # profile lock it holds: a revoke that blocks the profile lands wholly
  # before the revision (its instance lock refuses the entry) or after it
  # (its head query sees this head, and its block stands). Only
  # `needs_consent` moves; every other status stays as it is.
  # arca:db-raise-ok a step inside the revision's transaction; a raise rolls it back.
  defp reactivate(athanor_id, profile_id) do
    {count, _} =
      from(p in Arca.Schemas.Profile,
        where: p.id == ^profile_id and p.status == "needs_consent"
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)
      |> Arca.Repo.update_all(set: [status: "active", updated_at: DateTime.utc_now()])

    count
  end

  defp run_multi(multi, return_key) do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.run_multi", fn ->
      case Arca.Repo.locking_transaction(multi) do
        {:ok, done} ->
          {:ok, Map.fetch!(done, return_key)}

        {:error, :consent, %Ecto.Changeset{errors: errors} = changeset, _done} ->
          if Keyword.has_key?(errors, :profile_id),
            do: {:error, :head_moved},
            else: {:error, changeset}

        {:error, _step, reason, _done} ->
          {:error, reason}
      end
    end)
    |> Arca.Data.project()
  end

  defp insert_refs([]), do: {0, nil}
  # arca:unscoped-ok each row was derived from the consent being committed, athanor included.
  defp insert_refs(rows), do: Arca.Repo.insert_all(ConsentVaultRef, rows)

  @doc "The head consent revision of a profile, with its vault refs."
  # `get_head/2` and `head_profiles_referencing/2` take the `Prima.Actor`
  # first and match it in the head, so the athanor comes from the caller;
  # an actor whose athanor is nil or the empty string is
  # `{:error, :no_athanor}` before any query. The two multi writers take
  # attribute maps their caller assembled and stamp no tenant of their
  # own.
  @spec get_head(Prima.Actor.t(), String.t()) ::
          {:ok, map(), [map()]}
          | {:error, :no_athanor | :not_found | :no_head | term()}
  def get_head(%Prima.Actor{athanor_id: athanor_id} = actor, profile_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.get_head", fn ->
      with {:ok, profile} <- Arca.ProfileStorage.get(actor, profile_id),
           head_id when is_binary(head_id) <- profile.head_consent_id || {:error, :no_head},
           %Consent{} = consent <-
             Arca.Repo.get_by(Consent, id: head_id, athanor_id: athanor_id) do
        refs =
          from(r in ConsentVaultRef, where: r.consent_id == ^head_id)
          |> Arca.QueryHelpers.where_athanor(athanor_id)
          |> Arca.Repo.all()

        {:ok, consent, refs}
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Arca.Data.project()
  end

  def get_head(%Prima.Actor{}, _profile_id), do: {:error, :no_athanor}

  @doc """
  Profiles whose **head** revision references a vault entry.

  Deliberately head-only: counting every historical revision would
  over-report — a profile that dropped the entry two revisions ago is not
  affected right now.
  """
  @spec head_profiles_referencing(Prima.Actor.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def head_profiles_referencing(%Prima.Actor{athanor_id: athanor_id}, vault_entry_id)
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.head_profiles_referencing", fn ->
      ids =
        from(r in ConsentVaultRef,
          join: c in Consent,
          on: c.id == r.consent_id and c.athanor_id == r.athanor_id,
          join: p in Arca.Schemas.Profile,
          on: p.head_consent_id == c.id and p.athanor_id == c.athanor_id,
          where: r.vault_entry_id == ^vault_entry_id,
          distinct: true,
          select: p.id
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, ids}
    end)
    |> Arca.Data.project()
  end

  def head_profiles_referencing(%Prima.Actor{}, _vault_entry_id), do: {:error, :no_athanor}

  @doc """
  The profiles, in every athanor, whose **head** revision binds the
  instance entry `instance_entry_id`, as `{athanor_id, profile_id}` pairs:
  a revoked or deleted instance entry blocks its dependents wherever they
  are. Platform scope only; any other actor is `{:error, :cross_tenant}`.
  """
  @spec head_profiles_referencing_instance(Prima.Actor.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :cross_tenant | term()}
  # arca:unscoped-ok a revoked instance entry blocks its dependents in every
  # athanor: the instance entry is offered across athanors, so the heads
  # binding it are found in every one, keyed by the entry and answered with
  # the athanor each profile is in.
  def head_profiles_referencing_instance(%Prima.Actor{scope: :platform}, instance_entry_id)
      when is_binary(instance_entry_id) do
    Arca.Repo.Errors.with_db_rescue(
      "Arca.ConsentStorage.head_profiles_referencing_instance",
      fn ->
        pairs =
          from(r in ConsentVaultRef,
            join: c in Consent,
            on: c.id == r.consent_id and c.athanor_id == r.athanor_id,
            join: p in Arca.Schemas.Profile,
            on: p.head_consent_id == c.id and p.athanor_id == c.athanor_id,
            where: r.instance_entry_id == ^instance_entry_id,
            distinct: true,
            order_by: [p.athanor_id, p.id],
            select: {p.athanor_id, p.id}
          )
          |> Arca.Repo.all()

        {:ok, pairs}
      end
    )
    |> Arca.Data.project()
  end

  def head_profiles_referencing_instance(%Prima.Actor{}, instance_entry_id)
      when is_binary(instance_entry_id),
      do: {:error, :cross_tenant}

  @doc """
  Consume the `once` binding `binding_key` for the root execution
  `root_execution_id`, against the revision the caller is pinned to.

  One locking transaction: the profile row is locked first; a pin that is
  not the profile's current head is `{:error, :superseded}`, whether or
  not it consumed before; then the head's row alone is written
  conditionally, from unconsumed or already this root's to this root. So
  the same root may use the binding again, another root is refused
  `{:error, :already_consumed}`, and two roots racing for it admit one. A
  binding the head does not hold is `{:error, :not_found}`, and one whose
  lifetime is not `once` `{:error, :not_once}`. A borrowed binding is
  consumed against each profile with its own pin.
  """
  @spec consume_once(Prima.Actor.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok
          | {:error,
             :no_athanor | :superseded | :already_consumed | :not_found | :not_once | term()}
  def consume_once(
        %Prima.Actor{athanor_id: athanor_id},
        profile_id,
        pinned_consent_id,
        binding_key,
        root_execution_id
      )
      when is_binary(athanor_id) and athanor_id != "" and is_binary(profile_id) and
             is_binary(pinned_consent_id) and is_binary(binding_key) and
             is_binary(root_execution_id) and root_execution_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.consume_once", fn ->
      Arca.Repo.locking_transaction(fn ->
        with :ok <- pinned_head(athanor_id, profile_id, pinned_consent_id),
             :ok <- consume_row(athanor_id, pinned_consent_id, binding_key, root_execution_id) do
          :ok
        else
          {:error, reason} -> Arca.Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def consume_once(%Prima.Actor{}, _profile_id, _pinned, _binding_key, _root),
    do: {:error, :no_athanor}

  # Under the profile's lock: only the current head admits a consumption.
  defp pinned_head(athanor_id, profile_id, pinned_consent_id) do
    case lock_profile!(athanor_id, profile_id) do
      ^pinned_consent_id -> :ok
      _other -> {:error, :superseded}
    end
  end

  defp consume_row(athanor_id, consent_id, binding_key, root) do
    row =
      from(r in ConsentVaultRef,
        where: r.consent_id == ^consent_id and r.binding_key == ^binding_key
      )
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    claimable =
      from(r in row,
        where:
          r.lifetime_kind == "once" and
            (is_nil(r.consumed_by_root) or r.consumed_by_root == ^root)
      )

    case Arca.Repo.update_all(claimable, set: [consumed_by_root: root]) do
      {1, _} ->
        :ok

      {0, _} ->
        case Arca.Repo.one(from(r in row, select: r.lifetime_kind)) do
          nil -> {:error, :not_found}
          "once" -> {:error, :already_consumed}
          _other -> {:error, :not_once}
        end
    end
  end

  @doc """
  The entries some profile's **head** revision in the actor's athanor
  binds, each id once: the athanor's own vault entries and the instance
  entries alike, `head_profiles_referencing/2` for every entry in one
  query.
  """
  @spec head_referenced_entries(Prima.Actor.t()) :: {:ok, [String.t()]} | {:error, term()}
  def head_referenced_entries(%Prima.Actor{athanor_id: athanor_id})
      when is_binary(athanor_id) and athanor_id != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.head_referenced_entries", fn ->
      # A selection's row names no entry and contributes nothing.
      ids =
        from(r in ConsentVaultRef,
          join: c in Consent,
          on: c.id == r.consent_id and c.athanor_id == r.athanor_id,
          join: p in Arca.Schemas.Profile,
          on: p.head_consent_id == c.id and p.athanor_id == c.athanor_id,
          where: not is_nil(r.vault_entry_id) or not is_nil(r.instance_entry_id),
          distinct: true,
          select: coalesce(r.vault_entry_id, r.instance_entry_id)
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, ids}
    end)
    |> Arca.Data.project()
  end

  def head_referenced_entries(%Prima.Actor{}), do: {:error, :no_athanor}

  @typedoc "An active profile and its head revision, as `active_heads/2` answers them."
  @type active_head :: %{
          profile: Prima.Authority.RootSelect.profile_summary(),
          consent: consent()
        }

  @doc """
  The first `limit:` `active` profiles of the actor's athanor, in profile-id
  order, each with its **head** revision and that revision's vault refs,
  decoded as `profiles/2` and `head_consent/2` decode them: the grants the
  athanor holds now, never more than `limit` of them.

  The third element says whether more active heads stand past the limit:
  the read fetches one row beyond it to know, and answers that row's
  presence rather than a count it would need another query for.

  Two queries: the profiles with their heads, then the refs of those
  heads by consent id. A revision and its refs commit in one transaction
  and never change, so the second query reads exactly the first one's
  revisions whatever advances in between. A profile with no head, or a
  row that does not decode, is dropped, as `profiles/2` drops one: it
  roots nothing, and it still counts toward the limit, which bounds the
  rows read. An actor whose athanor is nil or the empty string is
  `{:error, :no_athanor}` before any query.
  """
  @spec active_heads(Prima.Actor.t(), limit: pos_integer()) ::
          {:ok, [active_head()], truncated? :: boolean()} | {:error, :no_athanor | term()}
  def active_heads(actor, opts)

  def active_heads(%Prima.Actor{athanor_id: athanor_id}, limit: limit)
      when is_binary(athanor_id) and athanor_id != "" and is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.active_heads", fn ->
      rows =
        from(p in Arca.Schemas.Profile,
          join: c in Consent,
          on: c.id == p.head_consent_id and c.athanor_id == p.athanor_id,
          where: p.status == "active",
          order_by: p.id,
          limit: ^(limit + 1),
          select: {p, c}
        )
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      heads = Enum.take(rows, limit)
      refs = refs_by_consent(athanor_id, Enum.map(heads, fn {_profile, c} -> c.id end))

      decoded =
        Enum.flat_map(heads, fn {profile, consent} ->
          with %{} = summary <- profile_summary(profile),
               {:ok, head} <- decode_consent(consent, Map.get(refs, consent.id, [])) do
            [%{profile: summary, consent: head}]
          else
            _undecodable -> []
          end
        end)

      {:ok, decoded, length(rows) > limit}
    end)
    |> Arca.Data.project()
  end

  def active_heads(%Prima.Actor{}, limit: limit) when is_integer(limit) and limit > 0,
    do: {:error, :no_athanor}

  @typedoc "One active head as the stored-grant check reads it (`active_head_policies/2`)."
  @type head_policy :: %{
          athanor_id: String.t(),
          profile_id: String.t(),
          source_ref: String.t(),
          revision: non_neg_integer(),
          resolved_policy: String.t()
        }

  @doc """
  One page of every athanor's active heads, for the boot check of stored
  grants (`Sanctum.Consent.StoredGrants`): up to `limit` rows in profile-id
  order after `after_id` (`nil` for the first page), each naming its own
  athanor, the profile and its source, and the head's revision and
  resolved policy as stored. Nothing is decoded or checked here: the
  reader says what a policy grants.
  """
  @spec active_head_policies(String.t() | nil, pos_integer()) ::
          {:ok, [head_policy()]} | {:error, term()}
  # arca:unscoped-ok the stored-grant check walks every athanor's active
  # heads by design, a page at a time, at boot; each row names its own
  # athanor, and what the check finds is announced to that athanor alone.
  def active_head_policies(after_id, limit)
      when (is_nil(after_id) or is_binary(after_id)) and is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.ConsentStorage.active_head_policies", fn ->
      page =
        from(p in Arca.Schemas.Profile,
          join: c in Consent,
          on: c.id == p.head_consent_id and c.athanor_id == p.athanor_id,
          where: p.status == "active",
          order_by: p.id,
          limit: ^limit,
          select: %{
            athanor_id: p.athanor_id,
            profile_id: p.id,
            source_ref: p.source_ref,
            revision: c.revision,
            resolved_policy: c.resolved_policy
          }
        )
        |> after_profile(after_id)
        |> Arca.Repo.all()

      {:ok, page}
    end)
  end

  defp after_profile(query, nil), do: query
  defp after_profile(query, after_id), do: where(query, [p], p.id > ^after_id)

  defp refs_by_consent(_athanor_id, []), do: %{}

  defp refs_by_consent(athanor_id, consent_ids) do
    from(r in ConsentVaultRef, where: r.consent_id in ^consent_ids)
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.Repo.all()
    |> Enum.group_by(& &1.consent_id)
  end

  @doc """
  Candidate profiles for a name-level source ref within the actor's tenant,
  decoded into the selection vocabulary.

  A row whose stored kind or status is outside the closed vocabulary is
  dropped rather than guessed at: it cannot be selected, and a selection
  that silently admitted it would root an execution on a value no writer
  of this table can produce.
  """
  @spec profiles(Prima.Actor.t(), String.t()) ::
          {:ok, [Prima.Authority.RootSelect.profile_summary()]} | {:error, term()}
  def profiles(%Prima.Actor{} = actor, source_ref) do
    with {:ok, entries} <- profile_entries(actor, source_ref) do
      {:ok, Enum.reject(entries, &(&1.status == :corrupt))}
    end
  end

  @typedoc "A stored profile whose kind or status is outside the closed vocabulary."
  @type corrupt_profile :: %{required(:id) => String.t(), required(:status) => :corrupt}

  @doc """
  `profiles/2` with every row accounted for: each candidate profile
  decoded as `profiles/2` decodes it, or, when its stored kind or status
  is outside the closed vocabulary, `%{id: id, status: :corrupt}`. The
  marker carries nothing that could be selected.
  """
  @spec profile_entries(Prima.Actor.t(), String.t()) ::
          {:ok, [Prima.Authority.RootSelect.profile_summary() | corrupt_profile()]}
          | {:error, term()}
  def profile_entries(%Prima.Actor{} = actor, source_ref) do
    with {:ok, rows} <- Arca.ProfileStorage.list_for_source(actor, source_ref) do
      {:ok, Enum.map(rows, &(profile_summary(&1) || %{id: &1.id, status: :corrupt}))}
    end
  end

  @doc """
  The head consent revision of a profile, fully decoded with its vault refs.

  Decoding fails closed — a stored scope or invoke mode outside the closed
  vocabulary, or an activation blob that does not parse, refuses the
  consent. `resolved_policy` stays a string: `Prima.Authority.Blob.parse/1`
  is the single fail-closed entry for those bytes and this is not it.
  """
  @spec head_consent(Prima.Actor.t(), String.t()) ::
          {:ok, consent()} | {:error, :no_athanor | :not_found | :no_head | term()}
  def head_consent(%Prima.Actor{} = actor, profile_id) do
    with {:ok, consent, refs} <- get_head(actor, profile_id) do
      decode_consent(consent, refs)
    end
  end

  defp profile_summary(row) do
    with {:ok, kind} <- decode_enum(row.kind, %{"owner" => :owner, "public" => :public}),
         {:ok, status} <-
           decode_enum(row.status, %{
             "active" => :active,
             "needs_consent" => :needs_consent,
             "revoked" => :revoked
           }) do
      %{id: row.id, kind: kind, source_ref: row.source_ref, label: row.label, status: status}
    else
      _ -> nil
    end
  end

  defp decode_consent(consent, refs) do
    with {:ok, scope} <-
           decode_enum(consent.scope, %{"versionless" => :versionless, "pinned" => :pinned}),
         {:ok, invoke_mode} <-
           decode_enum(consent.invoke_mode, %{
             "open_inert" => :open_inert,
             "edge_only" => :edge_only
           }),
         {:ok, activation} <- decode_activation(consent.activation),
         {:ok, origins} <- decode_origins(consent.admitted_origins) do
      {:ok,
       %{
         id: consent.id,
         revision: consent.revision,
         scope: scope,
         pinned_version: consent.pinned_version,
         invoke_mode: invoke_mode,
         shape_digest: consent.shape_digest,
         commit_digest: consent.commit_digest,
         blob_digest: consent.blob_digest,
         resolved_policy: consent.resolved_policy,
         activation: activation,
         admitted_origins: origins,
         vault_refs: Enum.map(refs, &binding_ref/1)
       }}
    end
  end

  defp binding_ref(%{} = r) do
    %{
      binding_key: r.binding_key,
      scope: r.scope,
      vault_entry_id: r.vault_entry_id,
      instance_entry_id: r.instance_entry_id,
      via_label: r.via_label,
      binding_digest: r.binding_digest,
      lifetime_kind: r.lifetime_kind,
      expires_at: r.expires_at,
      consumed_by_root: r.consumed_by_root
    }
  end

  defp decode_enum(value, mapping) do
    case Map.fetch(mapping, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_stored_value, value}}
    end
  end

  defp decode_activation(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, %{} = graph} ->
        if Enum.all?(graph, fn {k, v} -> is_binary(k) and is_binary(v) end) do
          {:ok, graph}
        else
          {:error, {:invalid_stored_value, :activation}}
        end

      _ ->
        {:error, {:invalid_stored_value, :activation}}
    end
  end

  defp decode_activation(_), do: {:error, {:invalid_stored_value, :activation}}

  # A stored list that is absent or does not parse refuses the consent
  # rather than guessing which origins it admits.
  defp decode_origins(json) when is_binary(json) do
    with {:ok, spellings} <- Jason.decode(json),
         {:ok, origins} <- Prima.Origin.parse_list(spellings) do
      {:ok, origins}
    else
      _ -> {:error, {:invalid_stored_value, :admitted_origins}}
    end
  end

  defp decode_origins(_absent), do: {:error, {:invalid_stored_value, :admitted_origins}}
end
