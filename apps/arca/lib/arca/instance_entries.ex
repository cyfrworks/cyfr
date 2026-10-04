# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.InstanceEntries do
  @moduledoc """
  Persistence mechanics for instance entries: the credentials the
  instance owns and offers to the people on it. A Sanctum-only store
  (`Cyfr.Boundaries`' security-store roster); sealing, the audience and
  component-policy decisions and every confirmation live in
  `Sanctum.InstanceEntries`, and `sealed_payload` arrives and leaves
  encrypted.

  An instance entry is no athanor's: its rows (`instance_entries`,
  `instance_entry_members`) carry no tenant, and every read here crosses
  athanors by design. So every verb but two takes the platform's actor
  (`%Prima.Actor{scope: :platform}`) and refuses any other
  `{:error, :cross_tenant}` before a query. `offered/2` and
  `get_offered/3` take a person's actor and answer only living entries
  whose audience covers `actor.user_id`: `everyone`, or `listed` with the
  person among `instance_entry_members`.

  ## The row

  A vault entry's columns less the athanor: always attach-only, its
  `destination` a destination's canonical text naming methods and paths
  (`Prima.Destination.new/2` with both required), plus `audience`,
  `person_daily` and `total_daily` (`nil` takes the platform setting's
  default), `component_policy` and `created_by`. The policy is exactly
  `any` or `shipped`: omitted at creation it is `any`, and any other
  value, null, empty or a collection included, is refused by the
  changeset here and by the baseline's check underneath.

  ## Writes

  `set_audience/4` and `set_component_policy/4` are compare-and-sets on
  what the caller read and decided against: the audience with its member
  list, and the policy. Each writes only while the row still holds it,
  and otherwise answers `{:error, :conflict}` without writing, so a
  widening that needed a confirmation is never written over a state it
  was not decided against. `put/3` and `set_audience/4` take the lock of
  every person a listed audience names first, people being first in
  `Arca.SecurityTransitions`' lock order. They refuse an id no person row
  has `{:error, {:person_unknown, user_id}}`, so a typed email is never
  stored, and then a denied person `{:error, {:person_denied, user_id}}`,
  each with nothing written, so a denial and an audience naming the
  person serialize, and a denied person is never listed again.
  `set_caps/3` writes only the caps it names. `move_binding/5` moves the
  destination by
  compare-and-set on the binding digest. `commit_payload/3` rotates the
  material under `payload_rev`, on an active row only. `revoke/3` and
  `tombstone/3` end the entry; `tombstone/3` also erases the material and
  removes every athanor's default naming the entry (`Arca.VaultDefaults`).
  The row stays, so the consents that bound it keep theirs.

  `move_binding/5`, `revoke/3` and `tombstone/3` each block every profile,
  in every athanor, whose head consent binds the entry, with the
  `blocked_status` the caller names, in the same transaction as their own
  write: a profile is never left ready against an entry that moved or
  ended, and a write whose dependents cannot be blocked is rolled back. A
  profile already revoked is not blocked; it stays revoked.
  """

  import Ecto.Query

  alias Arca.Schemas.InstanceEntry
  alias Arca.Schemas.InstanceEntryMember
  alias Arca.Schemas.Profile
  alias Arca.Schemas.User

  @typedoc """
  An instance entry as callers see it: the metadata, the binding columns,
  the offer and the sealed bytes.
  """
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          provenance: String.t(),
          field_names: String.t(),
          binding_digest: String.t() | nil,
          oauth_endpoints: String.t() | nil,
          oauth_scopes: String.t() | nil,
          destination: String.t(),
          attach_only: true,
          status: String.t(),
          payload_rev: non_neg_integer(),
          sealed_payload: binary() | nil,
          last_used_at: DateTime.t() | nil,
          audience: String.t(),
          person_daily: non_neg_integer() | nil,
          total_daily: non_neg_integer() | nil,
          component_policy: String.t(),
          created_by: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type refusal :: {:error, :cross_tenant | :database_error}

  # The binding columns a move may write: the destination and the digest
  # that covers it. The OAuth endpoints are fixed at creation.
  @movable [:destination, :binding_digest]

  defguardp platform(actor) when is_struct(actor, Prima.Actor) and actor.scope == :platform

  @doc """
  Insert an instance entry and, for a `listed` audience, its `members`
  (person ids), in one transaction.

  `{:error, :name_taken}` when a living entry holds the name,
  `{:error, :destination_required}` or `{:error, {:invalid_destination,
  reason}}` for a destination that is absent, not a destination's
  canonical text, or missing its methods or paths,
  `{:error, {:invalid, errors}}` for a row outside the vocabularies,
  `{:error, {:person_unknown, user_id}}` for a listed id no person has,
  and `{:error, {:person_denied, user_id}}` for a listed person who is
  denied, each read under the listed people's locks.
  """
  @spec put(Prima.Actor.t(), map(), [String.t()]) ::
          {:ok, entry()}
          | {:error,
             :name_taken
             | :destination_required
             | {:invalid_destination, term()}
             | {:invalid, map()}
             | {:person_unknown, String.t()}
             | {:person_denied, String.t()}}
          | refusal()
  def put(actor, attrs, members \\ [])

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the row carries no athanor to scope to.
  def put(actor, attrs, members) when platform(actor) and is_map(attrs) and is_list(members) do
    attrs =
      attrs |> Map.put_new(:id, Prima.UUID7.generate_id("ine")) |> Map.put(:attach_only, true)

    with :ok <- destination_attr(attrs),
         :ok <- member_ids(members) do
      changeset =
        attrs
        |> InstanceEntry.changeset()
        |> Ecto.Changeset.unique_constraint(:name, name: :instance_entries_active_name_index)
        |> Ecto.Changeset.unique_constraint(:name, name: :instance_entries_name_index)

      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.put", fn ->
        transact(fn ->
          with :ok <- listed_people(Map.get(attrs, :audience), members) do
            case Arca.Repo.insert(changeset) do
              {:ok, row} ->
                replace_members!(row.id, if(row.audience == "listed", do: members, else: []))
                {:ok, view(row)}

              {:error, %Ecto.Changeset{errors: errors}} ->
                if Keyword.has_key?(errors, :name) and name_taken?(errors),
                  do: {:error, :name_taken},
                  else: {:error, {:invalid, errors_map(errors)}}
            end
          end
        end)
      end)
    end
  end

  def put(%Prima.Actor{}, attrs, members) when is_map(attrs) and is_list(members),
    do: {:error, :cross_tenant}

  @doc "The instance entry with this id, whatever its status."
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, entry()} | {:error, :not_found} | refusal()
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: read by id, with no athanor to scope to.
  def get(actor, id) when platform(actor) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.get", fn ->
      case Arca.Repo.get(InstanceEntry, id) do
        nil -> {:error, :not_found}
        row -> {:ok, view(row)}
      end
    end)
  end

  def get(%Prima.Actor{}, id) when is_binary(id), do: {:error, :cross_tenant}

  @doc """
  The living instance entries, by name; `include_tombstoned: true` widens
  to all. Each answers with its listed members (`members`, person ids).
  """
  @spec list(Prima.Actor.t(), keyword()) ::
          {:ok, [entry() | %{members: [String.t()]}]} | refusal()
  def list(actor, opts \\ [])

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the platform lists them all.
  def list(actor, opts) when platform(actor) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.list", fn ->
      query = from(i in InstanceEntry, order_by: i.name)

      query =
        if Keyword.get(opts, :include_tombstoned, false),
          do: query,
          else: where(query, [i], i.status != "tombstoned")

      rows = Arca.Repo.all(query)
      members = members_of(Enum.map(rows, & &1.id))

      {:ok, Enum.map(rows, &Map.put(view(&1), :members, Map.get(members, &1.id, [])))}
    end)
  end

  def list(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :cross_tenant}

  @typedoc "Who an entry is offered to: `everyone`, or the `listed` person ids."
  @type audience :: %{audience: String.t(), members: [String.t()]}

  @doc """
  Set who an entry is offered to, by compare-and-set: `change` names the
  `audience` (`everyone` or `listed`) and the listed `members` (person
  ids), which replace the entry's list (an `everyone` audience keeps
  none), and `expected` the audience and members the caller read and
  decided against. Whether the change widens the audience, and the
  confirmation that asks, are the caller's.

  In one locking transaction the people a listed `change` names are
  locked first, an id no person has refused `{:error, {:person_unknown,
  user_id}}` and a denied person `{:error, {:person_denied, user_id}}`;
  then the entry's row and its member rows are read under a
  lock, and the write lands only while they still hold `expected`,
  members compared as a set, and otherwise answers `{:error, :conflict}`
  with nothing written. So two writers who read the same audience cannot
  both land, and the one that loses never puts back a person the other
  removed. An entry that does not exist or is tombstoned is
  `{:error, :not_found}`.
  """
  @spec set_audience(Prima.Actor.t(), String.t(), audience(), audience()) ::
          :ok
          | {:error,
             :conflict
             | :not_found
             | {:invalid, map()}
             | {:person_unknown, String.t()}
             | {:person_denied, String.t()}}
          | refusal()
  def set_audience(
        actor,
        id,
        %{audience: expected_audience, members: expected_members},
        %{audience: audience, members: members}
      )
      when platform(actor) and is_binary(id) and is_list(expected_members) and
             is_list(members) do
    with :ok <- audience_value(audience),
         :ok <- audience_value(expected_audience),
         :ok <- member_ids(members),
         :ok <- member_ids(expected_members) do
      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.set_audience", fn ->
        transact(fn ->
          with :ok <- listed_people(audience, members),
               :ok <- audience_held(id, expected_audience, expected_members),
               :ok <- write(id, audience: audience, updated_at: now()) do
            replace_members!(id, if(audience == "listed", do: members, else: []))
            :ok
          end
        end)
      end)
    end
  end

  def set_audience(%Prima.Actor{}, id, %{audience: _, members: _}, %{audience: _, members: _})
      when is_binary(id),
      do: {:error, :cross_tenant}

  @doc """
  Set the component policy by compare-and-set: the write lands only while
  the stored policy is still `expected`, including a call whose `policy`
  equals it. Both are exactly `any` or `shipped`; anything else is
  refused `{:error, {:invalid, %{component_policy: _}}}` before a query.
  A row holding another policy answers `{:error, :conflict}` and nothing
  is written; a row that does not exist `{:error, :not_found}`.
  """
  @spec set_component_policy(Prima.Actor.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :conflict | :not_found | {:invalid, map()}} | refusal()
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: written by id, with no athanor to scope to.
  def set_component_policy(actor, id, expected, policy) when platform(actor) and is_binary(id) do
    if InstanceEntry.policy?(expected) and InstanceEntry.policy?(policy) do
      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.set_component_policy", fn ->
        query =
          from(i in InstanceEntry,
            where: i.id == ^id and i.component_policy == ^expected and i.status != "tombstoned"
          )

        case Arca.Repo.update_all(query, set: [component_policy: policy, updated_at: now()]) do
          {1, _} -> :ok
          {0, _} -> if exists?(id), do: {:error, :conflict}, else: {:error, :not_found}
        end
      end)
    else
      {:error, {:invalid, %{component_policy: ["is any or shipped"]}}}
    end
  end

  def set_component_policy(%Prima.Actor{}, id, _expected, _policy) when is_binary(id),
    do: {:error, :cross_tenant}

  @doc """
  The largest daily cap an entry holds (`Arca.Schemas.InstanceEntry.max_cap/0`):
  the bound a caller holds a cap to before it asks for the write.
  """
  @spec max_cap() :: pos_integer()
  defdelegate max_cap(), to: InstanceEntry

  @doc """
  Set the daily caps `caps` names, `person_daily`, `total_daily` or both,
  each an integer from 0 to `Arca.Schemas.InstanceEntry.max_cap/0` (the
  columns' 32-bit range on PostgreSQL) or nil (unset, taking the platform
  setting's default). `0` admits no use. One statement writes exactly the
  named columns, so a concurrent write to the other cap stands. A map
  naming neither, or anything beside them, is refused before a query.
  """
  @spec set_caps(Prima.Actor.t(), String.t(), %{
          optional(:person_daily) => non_neg_integer() | nil,
          optional(:total_daily) => non_neg_integer() | nil
        }) :: :ok | {:error, :not_found | {:invalid, map()}} | refusal()
  def set_caps(actor, id, caps) when platform(actor) and is_binary(id) and is_map(caps) do
    named = Map.take(caps, [:person_daily, :total_daily])

    if named != %{} and map_size(named) == map_size(caps) and
         Enum.all?(Map.values(named), &cap?/1) do
      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.set_caps", fn ->
        write(id, Map.to_list(named) ++ [updated_at: now()])
      end)
    else
      {:error,
       {:invalid,
        %{
          caps: [
            "name person_daily, total_daily or both, each an integer from 0 to " <>
              "#{InstanceEntry.max_cap()} or nil"
          ]
        }}}
    end
  end

  def set_caps(%Prima.Actor{}, id, caps) when is_binary(id) and is_map(caps),
    do: {:error, :cross_tenant}

  @doc """
  Set the entry's status (`active`, `needs_reauth` or `revoked`), as a
  transition `Arca.StatusTransitions` admits: the write is conditional on
  the row's current status, so a `revoked` or `tombstoned` row never comes
  back, and a row whose status may not reach the one asked for is refused
  `{:error, {:entry_unavailable, status}}` with nothing written.
  """
  @spec set_status(Prima.Actor.t(), String.t(), String.t()) ::
          :ok
          | {:error, :not_found | {:entry_unavailable, String.t()} | {:invalid, map()}}
          | refusal()
  def set_status(actor, id, status) when platform(actor) and is_binary(id) do
    case Arca.StatusTransitions.from(status) do
      {:ok, _from} ->
        Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.set_status", fn ->
          write_status(id, status)
        end)

      :error ->
        {:error, {:invalid, %{status: ["is active, needs_reauth or revoked"]}}}
    end
  end

  def set_status(%Prima.Actor{}, id, _status) when is_binary(id), do: {:error, :cross_tenant}

  @doc """
  Revoke an entry and block its dependents, in one transaction: the
  status moves to `revoked` as `Arca.StatusTransitions` admits, and every
  profile, in every athanor, whose head consent binds the entry and that
  is not itself revoked takes `blocked_status`. Answers the blocked
  `{athanor_id, profile_id}` pairs.

  An entry already revoked is revoked again and its dependents blocked
  again, so a retry finishes what an earlier attempt left. A tombstoned
  entry is `{:error, {:entry_unavailable, "tombstoned"}}` and one that
  does not exist `{:error, :not_found}`, each with nothing written; a
  block that fails rolls the status write back.
  """
  @spec revoke(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, :not_found | {:entry_unavailable, String.t()}}
          | refusal()
  def revoke(actor, id, blocked_status)
      when platform(actor) and is_binary(id) and is_binary(blocked_status) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.revoke", fn ->
      transact(fn ->
        with :ok <- write_status(id, "revoked") do
          block_dependents(actor, id, blocked_status)
        end
      end)
    end)
  end

  def revoke(%Prima.Actor{}, id, blocked_status)
      when is_binary(id) and is_binary(blocked_status),
      do: {:error, :cross_tenant}

  @doc """
  Tombstone an entry and block its dependents, in one transaction: the
  status flip and the material's erasure, every athanor's default naming
  the entry removed, and every profile, in every athanor, whose head
  consent binds the entry and that is not itself revoked given
  `blocked_status`. Answers the blocked
  `{athanor_id, profile_id}` pairs. The name is free again; the row stays
  for the consents that bound it.

  An entry already tombstoned is tombstoned again and its dependents
  blocked again, so a retry finishes what an earlier attempt left. One
  that does not exist is `{:error, :not_found}`; a block that fails rolls
  the whole tombstone back.
  """
  @spec tombstone(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :not_found} | refusal()
  def tombstone(actor, id, blocked_status)
      when platform(actor) and is_binary(id) and is_binary(blocked_status) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.tombstone", fn ->
      transact(fn ->
        with :ok <-
               write(id, status: "tombstoned", sealed_payload: nil, updated_at: now()),
             :ok <- Arca.VaultDefaults.drop_instance_entry!(id) do
          block_dependents(actor, id, blocked_status)
        end
      end)
    end)
  end

  def tombstone(%Prima.Actor{}, id, blocked_status)
      when is_binary(id) and is_binary(blocked_status),
      do: {:error, :cross_tenant}

  @doc """
  Move a living entry's destination from the binding digest it was read
  at, and block every profile in every athanor whose head binds the entry
  and that is not itself revoked with `blocked_status`, as one
  transaction.

  `changes` carries `destination` (a destination's canonical text naming
  methods and paths) and the recomputed `binding_digest`; naming the OAuth
  endpoints is `{:error, :endpoints_immutable}` and anything else beside
  them `{:error, {:invalid, _}}`, before any write.
  `{:error, :binding_moved}` when another change landed first. Answers
  the blocked `{athanor_id, profile_id}` pairs.
  """
  @spec move_binding(Prima.Actor.t(), String.t(), String.t() | nil, map(), String.t()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error,
             :binding_moved
             | :endpoints_immutable
             | {:invalid_destination, term()}
             | {:invalid, map()}}
          | refusal()
  def move_binding(actor, id, from_digest, changes, blocked_status)
      when platform(actor) and is_binary(id) and is_map(changes) and
             (is_binary(from_digest) or is_nil(from_digest)) and is_binary(blocked_status) do
    with :ok <- movable(changes) do
      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.move_binding", fn ->
        transact(fn ->
          with :ok <- cas_binding(id, from_digest, changes) do
            block_dependents(actor, id, blocked_status)
          end
        end)
      end)
    end
  end

  def move_binding(%Prima.Actor{}, id, from_digest, changes, blocked_status)
      when is_binary(id) and is_map(changes) and
             (is_binary(from_digest) or is_nil(from_digest)) and is_binary(blocked_status),
      do: {:error, :cross_tenant}

  @doc """
  Write new sealed material (a rotation), with the status flip that
  belongs to it, as one transaction: `plan` names the `expected_rev` the
  caller read, the `sealed_payload` and a `status`: `"active"`, to
  reactivate an entry read at `needs_reauth`, or nil. The status is
  written only as `needs_reauth` → `active` (an `active` row stays as it
  is); any other is refused `{:error, {:invalid_status, status}}`, and a
  row that is `tombstoned` or `revoked` is refused
  `{:error, {:entry_unavailable, status}}`, each before anything is
  written, so a delete or a revoke that landed after the caller's read is
  never undone. The material lands only on an active row at that
  revision: `{:error, :payload_conflict}` when it moved on, and
  `{:error, {:entry_unavailable, status}}` when the row is no longer
  active.
  """
  @spec commit_payload(Prima.Actor.t(), String.t(), %{
          expected_rev: non_neg_integer(),
          sealed_payload: binary(),
          status: String.t() | nil
        }) ::
          {:ok, %{payload_rev: non_neg_integer()}}
          | {:error,
             :payload_conflict
             | :not_found
             | {:entry_unavailable, String.t()}
             | {:invalid_status, String.t()}}
          | refusal()
  def commit_payload(
        actor,
        id,
        %{expected_rev: expected_rev, sealed_payload: sealed, status: status}
      )
      when platform(actor) and is_binary(id) and is_integer(expected_rev) and expected_rev >= 0 and
             is_binary(sealed) and (is_binary(status) or is_nil(status)) do
    with :ok <- plan_status(status) do
      Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.commit_payload", fn ->
        transact(fn ->
          with :ok <- still_living(id),
               :ok <- maybe_status(id, status),
               :ok <- cas_payload(id, expected_rev, sealed) do
            {:ok, %{payload_rev: expected_rev + 1}}
          end
        end)
      end)
    end
  end

  def commit_payload(%Prima.Actor{}, id, %{expected_rev: _, sealed_payload: _, status: _})
      when is_binary(id),
      do: {:error, :cross_tenant}

  @doc "Mark an entry used now."
  @spec touch_last_used(Prima.Actor.t(), String.t()) :: :ok | {:error, :not_found} | refusal()
  def touch_last_used(actor, id) when platform(actor) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.touch_last_used", fn ->
      write(id, last_used_at: now())
    end)
  end

  def touch_last_used(%Prima.Actor{}, id) when is_binary(id), do: {:error, :cross_tenant}

  @doc """
  The living, active entries offered to the actor's person, by name:
  those whose audience is `everyone`, and those `listed` with the person
  among their members. `provider_hint:` narrows to one provider. An actor
  naming no person is `{:error, :no_person}`.
  """
  @spec offered(Prima.Actor.t(), keyword()) :: {:ok, [entry()]} | {:error, :no_person | term()}
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: what a person is offered is read by person.
  def offered(%Prima.Actor{user_id: user_id}, opts) when is_binary(user_id) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.offered", fn ->
      query =
        from(i in offered_query(user_id), where: i.status == "active", order_by: i.name)

      query =
        case Keyword.get(opts, :provider_hint) do
          nil -> query
          hint when is_binary(hint) -> where(query, [i], i.provider_hint == ^hint)
        end

      {:ok, Enum.map(Arca.Repo.all(query), &view/1)}
    end)
  end

  def offered(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_person}

  @doc """
  The entry with this id when it is offered to the actor's person, else
  `{:error, :not_offered}` — an entry that does not exist, is tombstoned,
  or whose audience does not cover the person answers the same.
  `active_only: false` also answers an offered entry that is not active
  (revoked or awaiting re-authorization), for a caller that says why it
  cannot be used.
  """
  @spec get_offered(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, entry()} | {:error, :not_offered | :no_person | term()}
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: one entry, read by id and by person.
  def get_offered(%Prima.Actor{user_id: user_id}, id, opts)
      when is_binary(user_id) and is_binary(id) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.InstanceEntries.get_offered", fn ->
      query = from(i in offered_query(user_id), where: i.id == ^id)

      query =
        if Keyword.get(opts, :active_only, true),
          do: where(query, [i], i.status == "active"),
          else: query

      case Arca.Repo.one(query) do
        nil -> {:error, :not_offered}
        row -> {:ok, view(row)}
      end
    end)
  end

  def get_offered(%Prima.Actor{}, id, opts) when is_binary(id) and is_list(opts),
    do: {:error, :no_person}

  @doc false
  # Inside a deny's transaction (`Arca.SecurityTransitions`): the person
  # leaves every instance entry's listed audience. Answers how many lists.
  @spec remove_person!(String.t()) :: non_neg_integer()
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  # arca:unscoped-ok the instance's own audiences, keyed by the person
  # denied; no athanor holds them.
  def remove_person!(user_id) when is_binary(user_id) do
    # The person's rows are locked by entry id before they go, in the one
    # order an audience write takes member rows in (person id, then entry
    # id), so the two never wait on each other in a cycle.
    from(m in InstanceEntryMember,
      where: m.user_id == ^user_id,
      order_by: [asc: m.instance_entry_id],
      select: m.instance_entry_id
    )
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.all()

    {count, _} =
      from(m in InstanceEntryMember, where: m.user_id == ^user_id)
      |> Arca.Repo.delete_all()

    count
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp offered_query(user_id) do
    listed =
      from(m in InstanceEntryMember,
        where: m.user_id == ^user_id,
        select: m.instance_entry_id
      )

    from(i in InstanceEntry,
      where:
        i.status != "tombstoned" and
          (i.audience == "everyone" or (i.audience == "listed" and i.id in subquery(listed)))
    )
  end

  defp view(%InstanceEntry{} = row) do
    %{
      id: row.id,
      name: row.name,
      kind: row.kind,
      provider_hint: row.provider_hint,
      provenance: row.provenance,
      field_names: row.field_names,
      binding_digest: row.binding_digest,
      oauth_endpoints: row.oauth_endpoints,
      oauth_scopes: row.oauth_scopes,
      destination: row.destination,
      attach_only: row.attach_only,
      status: row.status,
      payload_rev: row.payload_rev,
      sealed_payload: row.sealed_payload,
      last_used_at: row.last_used_at,
      audience: row.audience,
      person_daily: row.person_daily,
      total_daily: row.total_daily,
      component_policy: row.component_policy,
      created_by: row.created_by,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  defp members_of([]), do: %{}

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp members_of(ids) do
    from(m in InstanceEntryMember,
      where: m.instance_entry_id in ^ids,
      order_by: [m.instance_entry_id, m.user_id]
    )
    |> Arca.Repo.all()
    |> Enum.group_by(& &1.instance_entry_id, & &1.user_id)
  end

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp replace_members!(id, members) do
    from(m in InstanceEntryMember, where: m.instance_entry_id == ^id) |> Arca.Repo.delete_all()

    rows =
      for user_id <- Enum.uniq(members),
          do: %{instance_entry_id: id, user_id: user_id, inserted_at: now()}

    if rows != [], do: Arca.Repo.insert_all(InstanceEntryMember, rows)
    :ok
  end

  defp member_ids(members) do
    if Enum.all?(members, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid, %{members: ["are person ids"]}}}
  end

  defp audience_value(audience) do
    if audience in InstanceEntry.audiences(),
      do: :ok,
      else: {:error, {:invalid, %{audience: ["is everyone or listed"]}}}
  end

  defp cap?(nil), do: true
  defp cap?(cap), do: is_integer(cap) and cap >= 0 and cap <= InstanceEntry.max_cap()

  # An instance entry's destination names its methods and paths: the
  # account is reached only where the administrator said.
  defp destination_attr(attrs) do
    case Map.get(attrs, :destination) do
      nil -> {:error, :destination_required}
      text -> instance_destination(text)
    end
  end

  defp instance_destination(text) when is_binary(text) do
    with {:ok, %{} = map} <- decode(text),
         {:ok, destination} <- Prima.Destination.new(map, true) do
      if Prima.Destination.canonical(destination) == text,
        do: :ok,
        else: {:error, {:invalid_destination, :not_canonical}}
    else
      {:error, {:invalid_destination, reason}} -> {:error, {:invalid_destination, reason}}
      _ -> {:error, {:invalid_destination, :not_json}}
    end
  end

  defp instance_destination(_other), do: {:error, {:invalid_destination, :not_text}}

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :not_json}
    end
  end

  defp movable(changes) do
    cond do
      Map.has_key?(changes, :oauth_endpoints) ->
        {:error, :endpoints_immutable}

      Map.keys(changes) -- @movable != [] ->
        {:error, {:invalid, %{changes: ["move the destination and its digest only"]}}}

      not is_binary(Map.get(changes, :binding_digest)) ->
        {:error, {:invalid, %{binding_digest: ["is the digest the move lands at"]}}}

      true ->
        instance_destination(Map.get(changes, :destination))
    end
  end

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp cas_binding(id, from_digest, changes) do
    query = from(i in InstanceEntry, where: i.id == ^id and i.status != "tombstoned")

    query =
      if is_nil(from_digest),
        do: from(i in query, where: is_nil(i.binding_digest)),
        else: from(i in query, where: i.binding_digest == ^from_digest)

    set = changes |> Map.take(@movable) |> Map.to_list() |> Keyword.put(:updated_at, now())

    case Arca.Repo.update_all(query, set: set) do
      {1, _} -> :ok
      {0, _} -> {:error, :binding_moved}
    end
  end

  # Every profile, in every athanor, whose head consent binds the entry,
  # given `blocked_status`: a step inside the caller's transaction, whose
  # refusal rolls back the write it follows. A revoked profile is not
  # blocked: it stays revoked and nothing attaches through it, and a
  # status write would revive it beside the live profile of its identity.
  defp block_dependents(actor, id, blocked_status) do
    with {:ok, heads} <- Arca.ConsentStorage.head_profiles_referencing_instance(actor, id),
         affected = unrevoked(heads),
         :ok <- block_profiles(affected, blocked_status) do
      {:ok, affected}
    end
  end

  # The pairs whose profile is not revoked, read under a lock athanor by
  # athanor, so a revoke that commits before the block is seen and one
  # that starts after it waits.
  defp unrevoked(pairs) do
    pairs
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {athanor_id, profile_ids} ->
      from(p in Profile,
        where: p.athanor_id == ^athanor_id and p.id in ^profile_ids and p.status != "revoked",
        select: {p.athanor_id, p.id}
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.all()
    end)
    |> Enum.sort()
  end

  defp block_profiles(pairs, blocked_status) do
    Enum.reduce_while(pairs, :ok, fn {athanor_id, profile_id}, :ok ->
      case Arca.ProfileStorage.set_status(
             Prima.Actor.in_athanor(athanor_id),
             profile_id,
             blocked_status
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # A status write held to `Arca.StatusTransitions`: conditional on the
  # row's current status, so a row the transition does not admit is
  # refused with the status it holds and nothing is written.
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp write_status(id, status) do
    {:ok, from} = Arca.StatusTransitions.from(status)
    query = from(i in InstanceEntry, where: i.id == ^id and i.status in ^from)

    case Arca.Repo.update_all(query, set: [status: status, updated_at: now()]) do
      {1, _} ->
        :ok

      {0, _} ->
        case current_status(id) do
          nil -> {:error, :not_found}
          current -> {:error, {:entry_unavailable, current}}
        end
    end
  end

  # The people a listed audience names, locked first and in id order, the
  # order every security transition takes people in: a denial, which
  # removes the person from every list under the same lock, and an
  # audience write naming the person serialize there. An id with no person
  # row (a typed email among them) names no one, so it is refused, the
  # first in id order, before any denied person; a person who is denied is
  # refused, naming them. Either way nothing is written. Person rows are
  # never deleted, so a row found here stays found.
  defp listed_people("listed", members) do
    listed = members |> Enum.uniq() |> Enum.sort()

    found =
      from(u in User,
        where: u.id in ^listed,
        order_by: [asc: u.id],
        select: {u.id, u.status}
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.all()

    known = MapSet.new(found, fn {id, _status} -> id end)

    with nil <- Enum.find(listed, &(not MapSet.member?(known, &1))),
         nil <- Enum.find(found, fn {_id, status} -> status == "denied" end) do
      :ok
    else
      {user_id, _status} -> {:error, {:person_denied, user_id}}
      user_id -> {:error, {:person_unknown, user_id}}
    end
  end

  defp listed_people(_audience, _members), do: :ok

  # The audience a compare-and-set was decided against, read under a lock:
  # the entry's row first, so a second audience write waits here, then its
  # member rows. Members compare as a set. A tombstoned or missing entry
  # has no audience to write.
  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp audience_held(id, expected_audience, expected_members) do
    stored =
      from(i in InstanceEntry,
        where: i.id == ^id and i.status != "tombstoned",
        select: i.audience
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()

    # Member rows are locked in one order everywhere, person id then entry
    # id (`remove_person!/1` takes a person's rows by entry id), so an
    # audience write and a denial never wait on each other in a cycle.
    members =
      from(m in InstanceEntryMember,
        where: m.instance_entry_id == ^id,
        order_by: [asc: m.user_id],
        select: m.user_id
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.all()

    cond do
      is_nil(stored) ->
        {:error, :not_found}

      stored == expected_audience and MapSet.new(members) == MapSet.new(expected_members) ->
        :ok

      true ->
        {:error, :conflict}
    end
  end

  # A plan's status only reactivates an entry.
  defp plan_status(nil), do: :ok
  defp plan_status("active"), do: :ok
  defp plan_status(status), do: {:error, {:invalid_status, status}}

  # A delete or a revoke that landed after the caller's read is never
  # undone: such a row is refused before anything is written.
  defp still_living(id) do
    case current_status(id) do
      status when status in ["tombstoned", "revoked"] -> {:error, {:entry_unavailable, status}}
      _living_or_absent -> :ok
    end
  end

  # `needs_reauth` → `active`, by a conditional write: an `active` row
  # stays as it is, and a row that left both since the read above is
  # refused rather than flipped back.
  defp maybe_status(_id, nil), do: :ok

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp maybe_status(id, "active") do
    query = from(i in InstanceEntry, where: i.id == ^id and i.status == "needs_reauth")

    case Arca.Repo.update_all(query, set: [status: "active", updated_at: now()]) do
      {1, _} ->
        :ok

      {0, _} ->
        case current_status(id) do
          "active" -> :ok
          nil -> {:error, :not_found}
          status -> {:error, {:entry_unavailable, status}}
        end
    end
  end

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp current_status(id),
    do: Arca.Repo.one(from(i in InstanceEntry, where: i.id == ^id, select: i.status))

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp cas_payload(id, expected_rev, sealed) do
    query =
      from(i in InstanceEntry,
        where: i.id == ^id and i.payload_rev == ^expected_rev and i.status == "active"
      )

    case Arca.Repo.update_all(query,
           set: [sealed_payload: sealed, payload_rev: expected_rev + 1, updated_at: now()]
         ) do
      {1, _} ->
        :ok

      {0, _} ->
        case current_status(id) do
          nil -> {:error, :not_found}
          "active" -> {:error, :payload_conflict}
          status -> {:error, {:entry_unavailable, status}}
        end
    end
  end

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp exists?(id),
    do:
      Arca.Repo.exists?(from(i in InstanceEntry, where: i.id == ^id and i.status != "tombstoned"))

  # arca:unscoped-ok the instance's own credentials, offered to athanors and
  # deleted with none of them: the rows carry no athanor to scope to.
  defp write(id, set) do
    case Arca.Repo.update_all(from(i in InstanceEntry, where: i.id == ^id), set: set) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp name_taken?(errors) do
    Enum.any?(errors, fn
      {:name, {_message, meta}} -> meta[:constraint] == :unique
      _ -> false
    end)
  end

  defp errors_map(errors) do
    Enum.reduce(errors, %{}, fn {field, {message, _meta}}, acc ->
      Map.update(acc, field, [message], &(&1 ++ [message]))
    end)
  end

  # A refusal answered from inside rolls the transaction back and is
  # handed to the caller with its own word. A locking transaction, so the
  # rows a compare-and-set reads under `Arca.QueryHelpers.for_update/1`
  # stay as read until it ends.
  defp transact(fun) do
    case Arca.Repo.locking_transaction(fn ->
           case fun.() do
             {:error, reason} -> Arca.Repo.rollback(reason)
             other -> other
           end
         end) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
