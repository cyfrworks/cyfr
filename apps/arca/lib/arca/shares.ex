# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Shares do
  @moduledoc """
  Persistence mechanics for shares: one of an athanor's vault entries
  offered to an audience, `everyone` or the active members of one group
  (`Arca.Schemas.Share`). A share is a row of its owner's athanor that
  names the entry, the audience and the caps; it holds no material and
  copies nothing, so every reader reaches the entry through it. Whether a
  person may read or use one, and every confirmation, are the layer
  above's; this module answers what the rows say.

  ## The owner's verbs

  `create/3`, `list/1`, `get/2`, `set_audience/4`, `set_caps/4` and
  `revoke/3` take the owner's actor first and work in its athanor. A share
  is made from a person's own athanor only: `create/3` takes the creator's
  person row and then the athanors it names (the owner's own and the
  group's) under lock, in `Arca.SecurityTransitions`' order, then the
  entry's row under lock, and re-checks from those rows that the athanor
  is the creator's own and active (`{:error, :not_own_athanor}`), that a
  group audience names an active group the creator is an active member of
  (`{:error, :not_member}`), and that the entry is active
  (`{:error, {:entry_unavailable, status}}`), attach-only
  (`{:error, :disclosed_not_shareable}`), of a shareable kind
  (`{:error, :kind_not_shareable}`) and has a destination naming its
  methods and paths (`{:error, :destination_incomplete}`). So a creation
  waits for a denial, an archive or a binding move holding those rows,
  and sees what they wrote. An entry the athanor does not hold is
  `{:error, :not_found}`, and a second active share of one entry to one
  audience `{:error, :already_shared}`, each with nothing written.

  `set_audience/4` is a compare-and-set against the audience the caller
  read, and takes no lock: a use's claim and a revision's lock each hold
  the audience they admitted under against the row they lock
  (`same_audience?/2`), so one racing a narrowing is refused rather than
  admitted outside the audience. `revoke/3` takes the share's row
  exclusive, so it serializes with a use's claim (`Arca.ShareUsage`),
  which reads it shared, and blocks every profile, in every athanor, whose
  head binds it (`Arca.ConsentStorage.block_dependents/4`) in the same
  transaction. A share has no delete: a revoked share stays, so a consent
  that bound it reads it no longer offered.

  `revoke_by_entry/3`, `revoke_by_athanor/2` and `revoke_all/1` are the
  cascades the entry's revoke and delete (`Arca.VaultStorage`), the
  standing transitions and the declared restore
  (`Arca.SecurityTransitions`) run inside their own transactions. Each
  answer names the shares it revoked.

  ## Reading across athanors

  A share is read for a recipient in their own athanor, so these reads
  cross athanors by design, each by the one key it is asked for:
  `offered_to/2` (the active shares whose audience holds the person),
  `member?/3` (one membership, read at use), `get_for_source/2` (one share
  by id, with its source entry's binding facts), `administrator_shares/1`
  (the active shares to everyone of an owner who holds the platform
  administrator's membership) and `head_profiles_referencing_share/2`
  (the profiles binding a share, platform scope only).
  """

  import Ecto.Query

  alias Arca.Schemas.{Athanor, Membership, Share, User, VaultEntry}

  @typedoc "A share as callers see it. It holds no material."
  @type share :: %{
          id: String.t(),
          athanor_id: String.t(),
          vault_entry_id: String.t(),
          audience: String.t(),
          group_id: String.t() | nil,
          person_daily: non_neg_integer() | nil,
          total_daily: non_neg_integer() | nil,
          status: String.t(),
          created_by: String.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @typedoc """
  A share's source entry, as a reader binds it: no material and no name,
  and every column its binding digest is derived from.
  """
  @type source :: %{
          id: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          field_names: String.t(),
          destination: String.t(),
          oauth_endpoints: String.t() | nil,
          oauth_scopes: String.t() | nil,
          binding_digest: String.t() | nil,
          attach_only: boolean(),
          status: String.t()
        }

  @typedoc "A share with its source entry and the person who owns its athanor."
  @type offered :: %{share: share(), source: source(), owner_user_id: String.t()}

  @typedoc "Who a share is offered to: `everyone`, or one group."
  @type audience :: %{audience: String.t(), group_id: String.t() | nil}

  @typedoc "What a revocation revoked and the profiles it blocked."
  @type revoked :: %{share_ids: [String.t()], blocked: [{String.t(), String.t()}]}

  @doc """
  Whether `audience`, `%{audience: _, group_id: _}`, is one a share may
  name (`Arca.Schemas.Share.audience_valid?/1`).
  """
  @spec audience_valid?(term()) :: boolean()
  defdelegate audience_valid?(audience), to: Share

  @doc """
  Whether the share row's audience `held` is the audience `admitted` a
  caller read it at, both `%{audience: _, group_id: _}`: the one compare
  a use's claim (`Arca.ShareUsage.claim/4`) and a revision's lock on the
  shares it binds (`Arca.ConsentStorage`) make, so a narrowing, which
  takes no lock, refuses what raced it rather than admitting outside the
  audience.
  """
  @spec same_audience?(audience(), map()) :: boolean()
  def same_audience?(%{audience: audience, group_id: group_id}, %{audience: audience} = admitted),
    do: Map.get(admitted, :group_id) == group_id

  def same_audience?(_held, _admitted), do: false

  @doc "Whether `cap` is a cap a share may hold (`Arca.Schemas.Share.cap?/1`)."
  @spec cap?(term()) :: boolean()
  defdelegate cap?(cap), to: Share

  @doc "The largest daily cap a share holds (`Arca.Schemas.Share.max_cap/0`)."
  @spec max_cap() :: pos_integer()
  defdelegate max_cap(), to: Share

  @doc "The audiences a share may name (`Arca.Schemas.Share.audiences/0`)."
  @spec audiences() :: [String.t()]
  defdelegate audiences(), to: Share

  defguardp resolved(athanor_id) when is_binary(athanor_id) and athanor_id != ""
  defguardp platform(actor) when is_struct(actor, Prima.Actor) and actor.scope == :platform

  @doc """
  Share the entry `attrs.entry_id` of the actor's athanor with
  `attrs.audience` (`"everyone"`, or `"group"` with `attrs.group_id`),
  with the optional caps `attrs.person_daily` and `attrs.total_daily`
  (absent for no limit). The actor names the creator (`user_id`).

  Refusals, each with nothing written, are the module doc's. A row outside
  the share's rules is `{:error, {:invalid, errors}}` before any query.

  `opts[:verify]` is the caller's check, run once every lock is held and
  before the insert: `:ok`, or `{:error, reason}`, which rolls the
  creation back and is answered. A confirmation is spent there, so the
  proof and the share commit together. The rows carry no standing: a
  person and their own athanor read active after a leave that retires
  them, and a lapsed company sign-in writes nothing, so `verify:` is also
  where the caller establishes that the creator stands.
  """
  @spec create(Prima.Actor.t(), map(), keyword()) ::
          {:ok, share()}
          | {:error,
             :not_own_athanor
             | :not_member
             | :not_found
             | {:entry_unavailable, String.t()}
             | :disclosed_not_shareable
             | :kind_not_shareable
             | :destination_incomplete
             | :already_shared
             | {:invalid, map()}
             | :no_athanor
             | :no_person
             | term()}
  def create(actor, attrs, opts \\ [])

  def create(%Prima.Actor{athanor_id: athanor_id, user_id: user_id}, attrs, opts)
      when resolved(athanor_id) and is_binary(user_id) and user_id != "" and is_map(attrs) and
             is_list(opts) do
    verify = Keyword.get(opts, :verify, fn -> :ok end)

    changeset =
      Share.changeset(%{
        id: Prima.UUID7.generate_id("shr"),
        athanor_id: athanor_id,
        vault_entry_id: Map.get(attrs, :entry_id),
        audience: Map.get(attrs, :audience),
        group_id: Map.get(attrs, :group_id),
        person_daily: Map.get(attrs, :person_daily),
        total_daily: Map.get(attrs, :total_daily),
        created_by: user_id
      })

    if changeset.valid? do
      row = Ecto.Changeset.apply_changes(changeset)

      Arca.Repo.Errors.with_db_rescue("Arca.Shares.create", fn ->
        Arca.Repo.locking_transaction(fn ->
          with :ok <- creator_stands(user_id),
               :ok <- athanors_admit(athanor_id, user_id, row),
               :ok <- shareable(athanor_id, row.vault_entry_id),
               :ok <- verify.() do
            insert(changeset)
          end
          |> Arca.Repo.committed()
        end)
      end)
    else
      {:error, Arca.Data.invalid(changeset)}
    end
  end

  def create(%Prima.Actor{athanor_id: athanor_id}, attrs, opts)
      when resolved(athanor_id) and is_map(attrs) and is_list(opts),
      do: {:error, :no_person}

  def create(%Prima.Actor{}, attrs, opts) when is_map(attrs) and is_list(opts),
    do: {:error, :no_athanor}

  # The creator's person row, under lock: people first, as every standing
  # transition takes them, so a denial and a creation serialize.
  defp creator_stands(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.status)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      "active" -> :ok
      _denied_or_absent -> {:error, :not_own_athanor}
    end
  end

  # The owner's athanor and the group the audience names, under lock in
  # id order, then the creator's seat in the group, read under the
  # creator's lock already held.
  defp athanors_admit(athanor_id, user_id, row) do
    ids = Enum.sort(Enum.uniq([athanor_id | List.wrap(row.group_id)]))

    held =
      from(a in Athanor, where: a.id in ^ids, order_by: a.id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.all()
      |> Map.new(&{&1.id, &1})

    with :ok <- own_athanor(held[athanor_id], user_id) do
      group_admits(row, held, user_id)
    end
  end

  @doc false
  # Whether `athanor`, a row read by the caller, is the active personal
  # athanor of the person `user_id`: the one rule a share is made from and
  # bound in (`Arca.ConsentStorage` binds by it too).
  @spec own_athanor(Athanor.t() | nil, String.t()) :: :ok | {:error, :not_own_athanor}
  def own_athanor(%Athanor{kind: "person", status: "active", owner_user_id: owner}, owner)
      when is_binary(owner),
      do: :ok

  def own_athanor(_athanor, _user_id), do: {:error, :not_own_athanor}

  defp group_admits(%Share{audience: "everyone"}, _held, _user_id), do: :ok

  defp group_admits(%Share{audience: "group", group_id: group_id}, held, user_id) do
    case held[group_id] do
      %Athanor{kind: "group", status: "active"} ->
        if active_member?(group_id, user_id), do: :ok, else: {:error, :not_member}

      _other ->
        {:error, :not_member}
    end
  end

  # Whether `user_id` is an active person seated, active, in the active
  # group `group_id`: the one membership read a group share is made,
  # moved and used by.
  # arca:unscoped-ok a share's group is another athanor than its owner's
  # or its reader's: one membership, read by the group and the person.
  defp active_member?(group_id, user_id) do
    from(m in Membership,
      join: g in Athanor,
      on: g.id == m.athanor_id,
      join: u in User,
      on: u.id == m.user_id,
      where:
        m.athanor_id == ^group_id and m.user_id == ^user_id and m.scope == "athanor" and
          m.status == "active" and g.kind == "group" and g.status == "active" and
          u.status == "active"
    )
    |> Arca.Repo.exists?()
  end

  # The entry's row under lock, after the athanors: a binding move holding
  # it is waited for, and its outcome is what the checks read.
  defp shareable(athanor_id, entry_id) do
    from(v in VaultEntry, where: v.id == ^entry_id)
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> eligible()
  end

  @doc """
  Whether `entry`, a vault entry as its store answers it, may be shared:
  `:ok`, or the refusal `create/3` answers for it (the module doc's).
  `create/3` holds the row it locks to this; a caller asks it of the row
  it read to refuse before it asks anything of a person.
  """
  @spec eligible(map() | nil) ::
          :ok
          | {:error,
             :not_found
             | {:entry_unavailable, String.t()}
             | :disclosed_not_shareable
             | :kind_not_shareable
             | :destination_incomplete}
  def eligible(nil), do: {:error, :not_found}

  def eligible(%{status: status}) when status != "active",
    do: {:error, {:entry_unavailable, status}}

  def eligible(%{attach_only: false}), do: {:error, :disclosed_not_shareable}

  def eligible(%{kind: _, destination: _} = entry) do
    cond do
      entry.kind not in Prima.CredentialKinds.shareable() -> {:error, :kind_not_shareable}
      not destination_complete?(entry.destination) -> {:error, :destination_incomplete}
      true -> :ok
    end
  end

  @doc """
  Whether an entry's stored destination (its canonical text) may carry a
  share: a shared key goes only where its destination names, so the
  destination names its methods and paths. `eligible/1` asks it of a new
  share, and `Arca.VaultStorage` of a binding move while a share is
  active.
  """
  @spec destination_complete?(String.t() | nil) :: boolean()
  def destination_complete?(text) when is_binary(text) do
    with {:ok, %{} = map} <- Jason.decode(text),
         {:ok, %Prima.Destination{methods: [_ | _], paths: [_ | _]}} <-
           Prima.Destination.from_map(map) do
      true
    else
      _ -> false
    end
  end

  def destination_complete?(_none), do: false

  # Both adapters' names for the natural key's index: PostgreSQL reports
  # the index, and ecto_sqlite3 the index SQLite names in its error text.
  defp insert(changeset) do
    changeset
    |> Ecto.Changeset.unique_constraint([:athanor_id, :vault_entry_id, :audience, :group_id],
      name: :shares_active_audience_index
    )
    |> Arca.Repo.insert()
    |> case do
      {:ok, share} -> {:ok, view(share)}
      {:error, %Ecto.Changeset{}} -> {:error, :already_shared}
    end
  end

  @doc "The actor's athanor's shares, active and revoked, oldest first."
  @spec list(Prima.Actor.t()) :: {:ok, [share()]} | {:error, :no_athanor | term()}
  def list(%Prima.Actor{athanor_id: athanor_id}) when resolved(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.list", fn ->
      shares =
        from(s in Share, order_by: [s.inserted_at, s.id])
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()
        |> Enum.map(&view/1)

      {:ok, shares}
    end)
  end

  def list(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc "The share with this id in the actor's athanor."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, share()} | {:error, :not_found | :no_athanor | term()}
  def get(%Prima.Actor{athanor_id: athanor_id}, id) when resolved(athanor_id) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.get", fn ->
      case owned_share(athanor_id, id) |> Arca.Repo.one() do
        nil -> {:error, :not_found}
        share -> {:ok, view(share)}
      end
    end)
  end

  def get(%Prima.Actor{}, id) when is_binary(id), do: {:error, :no_athanor}

  @doc """
  Move an active share of the actor's athanor from the audience
  `expected` the caller read to `audience`, each
  `%{audience: _, group_id: _}`, by compare-and-set and with no lock.

  A group audience names an active group the creator of the share is an
  active member of (`{:error, :not_member}`). A share no longer at
  `expected` is `{:error, :conflict}`, a revoked one
  `{:error, {:share_unavailable, "revoked"}}`, one the athanor does not
  hold `{:error, :not_found}`, and a move onto an audience another active
  share of the entry holds `{:error, :already_shared}`, each with nothing
  written.
  """
  @spec set_audience(Prima.Actor.t(), String.t(), audience(), audience()) ::
          {:ok, share()}
          | {:error,
             :conflict
             | :not_found
             | :not_member
             | :already_shared
             | {:share_unavailable, String.t()}
             | {:invalid, map()}
             | :no_athanor
             | term()}
  def set_audience(%Prima.Actor{athanor_id: athanor_id}, id, expected, audience)
      when resolved(athanor_id) and is_binary(id) do
    if Share.audience_valid?(expected) and Share.audience_valid?(audience) do
      Arca.Repo.Errors.with_db_rescue("Arca.Shares.set_audience", fn ->
        with {:ok, share} <- fetch(athanor_id, id),
             :ok <- group_open(audience, share.created_by) do
          move_audience(athanor_id, share, expected, audience)
        end
      end)
    else
      {:error, {:invalid, %{audience: ["is everyone with no group, or group with one"]}}}
    end
  end

  def set_audience(%Prima.Actor{}, id, _expected, _audience) when is_binary(id),
    do: {:error, :no_athanor}

  defp group_open(%{audience: "everyone"}, _user_id), do: :ok

  defp group_open(%{audience: "group", group_id: group_id}, user_id) do
    if active_member?(group_id, user_id), do: :ok, else: {:error, :not_member}
  end

  # The write lands only on the row still active at `expected`: its
  # filters are the compare, and `force:` makes a move onto the audience it
  # already holds compare too. An absent group needs no filter of its own,
  # since `everyone` holds none by the baseline's check. Both adapters'
  # names for the natural key's index are declared, as `insert/1` does.
  defp move_audience(athanor_id, share, expected, audience) do
    filters =
      %{athanor_id: athanor_id, status: "active", audience: expected.audience}
      |> then(&if expected.group_id, do: Map.put(&1, :group_id, expected.group_id), else: &1)

    share
    |> Ecto.Changeset.change(audience: audience.audience, group_id: audience.group_id)
    |> Map.update!(:filters, &Map.merge(&1, filters))
    |> Ecto.Changeset.unique_constraint([:athanor_id, :vault_entry_id, :audience, :group_id],
      name: :shares_active_audience_index
    )
    |> Arca.Repo.update(stale_error_field: :id, force: true)
    |> case do
      {:ok, moved} ->
        {:ok, view(moved)}

      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :id),
          do: with({:ok, now} <- fetch(athanor_id, share.id), do: unmoved(now)),
          else: {:error, :already_shared}
    end
  end

  defp unmoved(%{status: "active"}), do: {:error, :conflict}
  defp unmoved(%{status: status}), do: {:error, {:share_unavailable, status}}

  @doc """
  Set an active share's two caps, each `nil` for no limit, `0` for no use
  or an integer up to `Arca.Schemas.Share.max_cap/0`. A cap outside that is
  `{:error, {:invalid, _}}` before any query; a revoked share
  `{:error, {:share_unavailable, "revoked"}}` and one the athanor does not
  hold `{:error, :not_found}`.
  """
  @spec set_caps(Prima.Actor.t(), String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          {:ok, share()}
          | {:error,
             :not_found | {:share_unavailable, String.t()} | {:invalid, map()} | :no_athanor}
          | {:error, term()}
  def set_caps(%Prima.Actor{athanor_id: athanor_id}, id, person_daily, total_daily)
      when resolved(athanor_id) and is_binary(id) do
    if Share.cap?(person_daily) and Share.cap?(total_daily) do
      Arca.Repo.Errors.with_db_rescue("Arca.Shares.set_caps", fn ->
        query =
          from(s in Share, where: s.id == ^id and s.status == "active", select: s)
          |> Arca.QueryHelpers.where_athanor(athanor_id)

        case Arca.Repo.update_all(query,
               set: [person_daily: person_daily, total_daily: total_daily, updated_at: now()]
             ) do
          {1, [share]} -> {:ok, view(share)}
          {0, _} -> with {:ok, share} <- fetch(athanor_id, id), do: unmoved(share)
        end
      end)
    else
      {:error, {:invalid, %{caps: ["are absent or integers from 0 to #{Share.max_cap()}"]}}}
    end
  end

  def set_caps(%Prima.Actor{}, id, _person_daily, _total_daily) when is_binary(id),
    do: {:error, :no_athanor}

  @doc """
  Revoke a share of the actor's athanor and block its dependents, in one
  transaction: the share's row is taken exclusive and moved to `revoked`
  (`Arca.StatusTransitions`'s `:shares`), and every profile, in every
  athanor, whose head binds it and that is not itself revoked takes
  `blocked_status`. A share already revoked is revoked again and its
  dependents blocked again, so a retry finishes what an earlier attempt
  left. One the athanor does not hold is `{:error, :not_found}`.
  """
  @spec revoke(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, revoked()} | {:error, :not_found | :no_athanor | term()}
  def revoke(%Prima.Actor{athanor_id: athanor_id}, id, blocked_status)
      when resolved(athanor_id) and is_binary(id) and is_binary(blocked_status) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.revoke", fn ->
      Arca.Repo.locking_transaction(fn ->
        athanor_id
        |> revoking(from(s in Share, where: s.id == ^id), blocked_status)
        |> one_revoked()
        |> Arca.Repo.committed()
      end)
    end)
  end

  def revoke(%Prima.Actor{}, id, blocked_status) when is_binary(id) and is_binary(blocked_status),
    do: {:error, :no_athanor}

  @doc """
  Revoke every active share of the entry `entry_id` of the actor's
  athanor and block their dependents with `blocked_status`, in the
  caller's transaction: the entry's revoke and delete
  (`Arca.VaultStorage`), which hold the entry's row.
  """
  @spec revoke_by_entry(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, revoked()} | {:error, :no_athanor | term()}
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def revoke_by_entry(%Prima.Actor{athanor_id: athanor_id}, entry_id, blocked_status)
      when resolved(athanor_id) and is_binary(entry_id) and is_binary(blocked_status) do
    Arca.Repo.locking_transaction(fn ->
      athanor_id
      |> revoking(
        from(s in Share, where: s.vault_entry_id == ^entry_id and s.status == "active"),
        blocked_status
      )
      |> Arca.Repo.committed()
    end)
    |> revoked_result()
  end

  def revoke_by_entry(%Prima.Actor{}, entry_id, blocked_status)
      when is_binary(entry_id) and is_binary(blocked_status),
      do: {:error, :no_athanor}

  @doc """
  Revoke every active share of the actor's athanor and block their
  dependents with `blocked_status`, in the caller's transaction: a
  denial, a retirement or an archive (`Arca.SecurityTransitions`), which
  hold the owner's person and athanor rows.
  """
  @spec revoke_by_athanor(Prima.Actor.t(), String.t()) ::
          {:ok, revoked()} | {:error, :no_athanor | term()}
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def revoke_by_athanor(%Prima.Actor{athanor_id: athanor_id}, blocked_status)
      when resolved(athanor_id) and is_binary(blocked_status) do
    Arca.Repo.locking_transaction(fn ->
      athanor_id
      |> revoking(from(s in Share, where: s.status == "active"), blocked_status)
      |> Arca.Repo.committed()
    end)
    |> revoked_result()
  end

  def revoke_by_athanor(%Prima.Actor{}, blocked_status) when is_binary(blocked_status),
    do: {:error, :no_athanor}

  @doc """
  Move every active share on the server to `revoked`, answering their
  ids: the declared restore's statement (`Arca.SecurityTransitions`),
  inside its transaction, which blocks every profile itself. Platform
  scope only.
  """
  @spec revoke_all(Prima.Actor.t()) :: {:ok, [String.t()]} | {:error, :cross_tenant | term()}
  # arca:unscoped-ok a declared restore revokes every share of the server, in every athanor.
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def revoke_all(actor) when platform(actor) do
    {from, to} = Arca.StatusTransitions.restored(:shares)

    {_count, ids} =
      Arca.Repo.update_all(from(s in Share, where: s.status == ^from, select: s.id),
        set: [status: to, updated_at: now()]
      )

    {:ok, Enum.sort(ids || [])}
  end

  def revoke_all(%Prima.Actor{}), do: {:error, :cross_tenant}

  # The shares of `athanor_id` that `query` names, taken exclusive in id
  # order and moved to `revoked` from what the domain admits, then their
  # dependents blocked. Answers the shares it held, so a caller asking for
  # one share can tell an absent one apart.
  defp revoking(athanor_id, query, blocked_status) do
    {:ok, from} = Arca.StatusTransitions.from(:shares, "revoked")

    held =
      from(s in query, order_by: s.id, select: {s.id, s.status})
      |> Arca.QueryHelpers.where_athanor(athanor_id)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.all()

    ids = for {id, status} <- held, status in from, do: id

    {_count, _} =
      from(s in Share, where: s.id in ^ids)
      |> Arca.QueryHelpers.where_athanor(athanor_id)
      |> Arca.Repo.update_all(set: [status: "revoked", updated_at: now()])

    with {:ok, blocked} <-
           Arca.ConsentStorage.block_dependents(
             Prima.Actor.in_athanor(athanor_id),
             nil,
             ids,
             blocked_status
           ) do
      {:ok, %{share_ids: ids, blocked: blocked}}
    end
  end

  # A function transaction answers `{:ok, value}` or its rollback.
  defp revoked_result({:ok, revoked}), do: {:ok, revoked}
  defp revoked_result({:error, reason}), do: {:error, reason}

  defp one_revoked({:ok, %{share_ids: []}}), do: {:error, :not_found}
  defp one_revoked(result), do: result

  @doc """
  The active shares offered to the actor's person (`user_id`): every
  share to `everyone`, and every share to a group the person is an
  active member of, while that group is active. The person is active,
  and a share is never offered to its owner. Each comes with its source
  entry's binding facts and its owner, newest first. `provider_hint:`
  narrows to one provider's entries.
  """
  @spec offered_to(Prima.Actor.t(), keyword()) ::
          {:ok, [offered()]} | {:error, :no_person | term()}
  # arca:unscoped-ok a share is offered across athanors: the shares whose
  # audience holds one person, read by that person's memberships and the
  # audience column, each answered with the athanor it is in.
  def offered_to(%Prima.Actor{user_id: user_id}, opts)
      when is_binary(user_id) and user_id != "" and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.offered_to", fn ->
      groups =
        from(m in Membership,
          join: g in Athanor,
          on: g.id == m.athanor_id,
          where:
            m.user_id == ^user_id and m.scope == "athanor" and m.status == "active" and
              g.kind == "group" and g.status == "active",
          select: m.athanor_id
        )

      query =
        from([s, v, a] in offered_base(),
          join: u in User,
          on: u.id == ^user_id and u.status == "active",
          where: a.owner_user_id != ^user_id,
          where:
            s.audience == "everyone" or
              (s.audience == "group" and s.group_id in subquery(groups))
        )

      query =
        case Keyword.get(opts, :provider_hint) do
          nil -> query
          hint when is_binary(hint) -> where(query, [_s, v], v.provider_hint == ^hint)
        end

      {:ok, Enum.map(Arca.Repo.all(query), &offered/1)}
    end)
  end

  def offered_to(%Prima.Actor{}, opts) when is_list(opts), do: {:error, :no_person}

  @doc """
  Whether `user_id` is an active person and an active member of the
  active group `group_id`: the audience of a group share, read at use.
  The actor is the person themselves or the platform's.
  """
  @spec member?(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, :cross_tenant | term()}
  def member?(%Prima.Actor{} = actor, group_id, user_id)
      when is_binary(group_id) and is_binary(user_id) and user_id != "" do
    if platform(actor) or actor.user_id == user_id do
      Arca.Repo.Errors.with_db_rescue("Arca.Shares.member?", fn ->
        {:ok, active_member?(group_id, user_id)}
      end)
    else
      {:error, :cross_tenant}
    end
  end

  @doc """
  The share `share_id`, whatever its status, with its source entry's
  binding facts and its owner, by id alone: the reader that resolves a
  binding naming it. Whether the reader may use it is the caller's
  decision.
  """
  @spec get_for_source(Prima.Actor.t(), String.t()) ::
          {:ok, offered()} | {:error, :not_found | term()}
  # arca:unscoped-ok a binding names a share of another athanor by its bare
  # id: one share and its source entry, read by that id, answered with the
  # athanor they are in.
  def get_for_source(%Prima.Actor{}, share_id) when is_binary(share_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.get_for_source", fn ->
      from([s, v, a] in sources(), where: s.id == ^share_id, select: {s, v, a.owner_user_id})
      |> Arca.Repo.one()
      |> case do
        nil -> {:error, :not_found}
        row -> {:ok, offered(row)}
      end
    end)
  end

  @doc """
  The active shares to `everyone` whose owner holds the platform
  administrator's membership and is active, each with its active,
  attach-only source entry and its owner, newest first: the candidates a
  new person's first sign-in binds from.
  """
  @spec administrator_shares(Prima.Actor.t()) :: {:ok, [offered()]} | {:error, term()}
  # arca:unscoped-ok the administrator's shares are in their own athanor,
  # read for a person of another: every active share to everyone, kept by
  # its owner's platform membership.
  def administrator_shares(%Prima.Actor{}) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.administrator_shares", fn ->
      administrators =
        from(m in Membership,
          where: m.scope == "platform" and m.status == "active",
          select: m.user_id
        )

      query =
        from([s, v, a] in offered_base(),
          join: u in User,
          on: u.id == a.owner_user_id and u.status == "active",
          where: s.audience == "everyone" and a.owner_user_id in subquery(administrators)
        )

      {:ok, Enum.map(Arca.Repo.all(query), &offered/1)}
    end)
  end

  @doc """
  The profiles, in every athanor, whose **head** revision binds the share
  `share_id`, as `{athanor_id, profile_id}` pairs ordered by athanor and
  id. Platform scope only; any other actor is `{:error, :cross_tenant}`.
  """
  @spec head_profiles_referencing_share(Prima.Actor.t(), String.t()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :cross_tenant | term()}
  def head_profiles_referencing_share(actor, share_id)
      when platform(actor) and is_binary(share_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.Shares.head_profiles_referencing_share", fn ->
      Arca.ConsentStorage.share_heads(actor, [share_id])
    end)
  end

  def head_profiles_referencing_share(%Prima.Actor{}, share_id) when is_binary(share_id),
    do: {:error, :cross_tenant}

  # ---------------------------------------------------------------------------

  # A share with its source entry and the athanor it is in, joined on the
  # athanor: the composite reference keeps the two in one.
  defp sources do
    from(s in Share,
      join: v in VaultEntry,
      on: v.id == s.vault_entry_id and v.athanor_id == s.athanor_id,
      join: a in Athanor,
      on: a.id == s.athanor_id
    )
  end

  # What may be offered: an active share of an active, attach-only entry
  # in an owner's active athanor.
  defp offered_base do
    from([s, v, a] in sources(),
      where:
        s.status == "active" and v.status == "active" and v.attach_only == true and
          a.status == "active" and a.kind == "person",
      order_by: [desc: s.inserted_at, desc: s.id],
      select: {s, v, a.owner_user_id}
    )
  end

  defp owned_share(athanor_id, id) do
    from(s in Share, where: s.id == ^id)
    |> Arca.QueryHelpers.where_athanor(athanor_id)
  end

  defp fetch(athanor_id, id) do
    case owned_share(athanor_id, id) |> Arca.Repo.one() do
      nil -> {:error, :not_found}
      share -> {:ok, share}
    end
  end

  defp offered({share, entry, owner}),
    do: %{share: view(share), source: source(entry), owner_user_id: owner}

  defp view(%Share{} = s) do
    %{
      id: s.id,
      athanor_id: s.athanor_id,
      vault_entry_id: s.vault_entry_id,
      audience: s.audience,
      group_id: s.group_id,
      person_daily: s.person_daily,
      total_daily: s.total_daily,
      status: s.status,
      created_by: s.created_by,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp source(%VaultEntry{} = v) do
    %{
      id: v.id,
      kind: v.kind,
      provider_hint: v.provider_hint,
      field_names: v.field_names,
      destination: v.destination,
      oauth_endpoints: v.oauth_endpoints,
      oauth_scopes: v.oauth_scopes,
      binding_digest: v.binding_digest,
      attach_only: v.attach_only,
      status: v.status
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
