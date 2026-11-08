# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DirectoryHeads do
  @moduledoc """
  This home's verified cache of account heads (`Arca.Schemas.DirectoryHead`),
  one row per identifier (`ARCHITECTURE.md` §9.1).

  A row keeps the genesis the chain was verified from and the directory it
  names: both are immutable once cached, so a later refresh can never move
  an identifier to another directory or another genesis
  (`:binding_changed`). The head, the verified state it leaves
  (`Prima.Identity.State`'s JSON: the listed keys and the recovery set)
  and `keys_added` (JSON: when each listed key was added, and a passkey's
  maker) move together by compare-and-set on the head the caller last read (`advance/5`),
  and `verified_at` is written on the database's clock, which is also the
  clock `fresh/3` compares against. Arca verifies no signature: the
  caller verified the chain before it asks.

  ## The walk

  An advance is handed the walk of the entries after the cached head, in
  log order, as their retiring steps (`t:step/0`): `{:remove_key, kid}`
  retires the bindings to that key, and `:recover` every binding of the
  account and every session of its people, bound to a key or not (a
  company login's included; API keys and webhooks are no sessions and
  stand); an `add_key` or `add_recovery` retires nothing and is not a
  step. A binding is a row an account's key signed for, naming that key's
  `kid` and the head it was verified under: a session
  (`Arca.SessionStorage`), a device certificate
  (`Arca.DeviceCertificates`), a pending confirmation a key confirmed
  (`Arca.PendingConfirmations`) and a paired client that is a key
  (`Arca.PairedClients`, whose revocation takes its certificates,
  confirmations and sessions with it). Every step runs in the advance's
  transaction before the head moves, so a key removed and added again
  between two reads is retired and then admitted afresh, never kept. The
  identifier's people's rows (`Arca.PersonIdentities`) take the new head
  as the head last read. The answer names what retired, for the caller to
  announce after commit.

  ## Gone

  `gone/2` marks an account the directory answered gone: every binding of
  it and every session of its people retire, as a recovery's would, and
  `gone_at` is set for good. A gone
  head never advances, is never touched and binds nothing; freshness reads
  the mark (`Sanctum.IdentityFreshness`).

  ## The issuance fence

  An advance and a gone mark lock the identifier's people first, in the
  standing lock order (`Arca.SecurityTransitions`), then the cached head,
  then what they retire. Every write that binds an account's key holds the
  same person's lock and names the head it was verified under, which must
  be the cached head under that lock (`fence!/2`, `:stale_head`
  otherwise). So a binding verified against an old head either commits
  before the advance and is retired by it, or waits for it and is refused.

  ## A head no one holds

  `sweep/3` removes a head whose identifier no person's identity row and
  no pending invitation names, once it was last verified longer ago than
  the caller's bound. A head a person holds stays whatever its age.

  ## Who writes

  The platform's own actor, for the home's identity freshness and its
  housekeeping. Rows are plain maps (`Arca.Data`) with `state` and
  `keys_added` as the JSON the caller stored.
  """

  import Ecto.Query

  alias Arca.{DeviceCertificates, PairedClients, PendingConfirmations, SessionStorage}
  alias Arca.Schemas.{DirectoryHead, PersonIdentity, SharedThreadMember, User}

  # Publishing a head decides which keys this home accepts, so each write
  # first proves this member still owns its slot on the database's clock
  # (`Arca.Repo.owned/2`): a stale owner publishes nothing.

  @typedoc "A cached head, as a plain map."
  @type row :: map()

  @typedoc "One retiring step of a walk, in log order."
  @type step :: {:remove_key, String.t()} | :recover

  @typedoc "What a walk or a gone mark retired."
  @type retired :: %{
          session_hashes: [binary()],
          certificate_ids: [String.t()],
          confirmation_ids: [String.t()],
          client_ids: [String.t()]
        }

  @doc "The cached head of `identifier`."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{scope: :platform}, identifier) when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.get", fn ->
      case Arca.Repo.get(DirectoryHead, identifier) do
        nil -> {:error, :not_found}
        head -> {:ok, head}
      end
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  The cached head of `identifier` and whether it was verified within
  `max_age_seconds` of the database's clock now:
  `{:ok, %{head: row, fresh: boolean}}`. A gone head is answered with its
  `gone_at`, never fresh.
  """
  @spec fresh(Prima.Actor.t(), String.t(), pos_integer()) ::
          {:ok, %{head: row(), fresh: boolean()}}
          | {:error, :not_found | :cross_tenant | :database_error}
  def fresh(%Prima.Actor{scope: :platform}, identifier, max_age_seconds)
      when is_binary(identifier) and is_integer(max_age_seconds) and max_age_seconds > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.fresh", fn ->
      now = Arca.ServerMetaStorage.now!()

      case Arca.Repo.get(DirectoryHead, identifier) do
        nil ->
          {:error, :not_found}

        head ->
          age_ms = DateTime.diff(now, head.verified_at, :millisecond)
          {:ok, %{head: head, fresh: is_nil(head.gone_at) and age_ms <= max_age_seconds * 1000}}
      end
    end)
    |> Arca.Data.project()
  end

  def fresh(%Prima.Actor{}, _identifier, _max_age_seconds), do: {:error, :cross_tenant}

  @doc """
  Cache a first verified head: `attrs` names the `:identifier`, the
  `:genesis` bytes, the `:directory_url` it names, the `:head_hash` and
  the verified `:state` and its `:keys_added` (JSON text). An identifier already cached is
  `{:error, :exists}`, answered with nothing written: a later head moves
  through `advance/5`.
  """
  @spec put(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def put(%Prima.Actor{scope: :platform, system: true}, attrs) when is_map(attrs) do
    attrs = Map.new(attrs)

    with :ok <-
           valid(attrs, [:identifier, :genesis, :directory_url, :head_hash, :state, :keys_added]) do
      Arca.Repo.owned("Arca.DirectoryHeads.put", fn ->
        now = Arca.ServerMetaStorage.now!()

        row = %{
          identifier: attrs.identifier,
          genesis: attrs.genesis,
          directory_url: attrs.directory_url,
          head_hash: attrs.head_hash,
          state: attrs.state,
          keys_added: attrs.keys_added,
          verified_at: now,
          gone_at: nil,
          revision: 1,
          inserted_at: now,
          updated_at: now
        }

        case Arca.Repo.insert_all(DirectoryHead, [row], on_conflict: :nothing) do
          {1, _} -> {:ok, Arca.Repo.get!(DirectoryHead, attrs.identifier)}
          {0, _} -> {:error, :exists}
        end
      end)
    end
  end

  def put(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  Move `identifier`'s cached head from `expected_head` to a newly verified
  one, walking `steps` (the retiring steps of the entries between them,
  in log order) in the same transaction: `attrs` names the `:genesis` and
  `:directory_url` the chain was verified from (which must be the cached
  ones), the `:head_hash`, the `:state` and its `:keys_added`. `verified_at` is the
  database's clock.

  Answers `{:ok, %{head: row, retired: retired}}`, or `{:error, :stale}`
  when the cached head is no longer `expected_head`, `{:error,
  :binding_changed}` for another genesis or directory, `{:error, :gone}`
  for an account marked gone, `{:error, :not_found}` for an identifier
  never cached.
  """
  @spec advance(Prima.Actor.t(), String.t(), String.t(), map(), [step()]) ::
          {:ok, %{head: row(), retired: retired()}} | {:error, term()}
  def advance(
        %Prima.Actor{scope: :platform, system: true},
        identifier,
        expected_head,
        attrs,
        steps
      )
      when is_binary(identifier) and is_binary(expected_head) and is_map(attrs) and
             is_list(steps) do
    attrs = Map.new(attrs)

    with :ok <- valid(attrs, [:genesis, :directory_url, :head_hash, :state, :keys_added]),
         :ok <- valid_steps(steps) do
      Arca.Repo.owned("Arca.DirectoryHeads.advance", fn ->
        advance_in(identifier, expected_head, attrs, steps)
      end)
    end
  end

  def advance(%Prima.Actor{}, _identifier, _expected_head, _attrs, _steps),
    do: {:error, :cross_tenant}

  @doc """
  Record that `identifier`'s cached head was verified again unchanged:
  `verified_at` moves to the database's clock while the head is still
  `head_hash` and the account is not gone. `{:error, :stale}` otherwise.
  """
  @spec touch(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :stale | :cross_tenant | :database_error}
  def touch(%Prima.Actor{scope: :platform, system: true}, identifier, head_hash)
      when is_binary(identifier) and is_binary(head_hash) do
    Arca.Repo.owned("Arca.DirectoryHeads.touch", fn ->
      now = Arca.ServerMetaStorage.now!()

      from(h in DirectoryHead,
        where: h.identifier == ^identifier and h.head_hash == ^head_hash and is_nil(h.gone_at)
      )
      |> Arca.Repo.update_all(set: [verified_at: now, updated_at: now])
      |> case do
        {1, _} -> {:ok, Arca.Repo.get!(DirectoryHead, identifier)}
        {0, _} -> {:error, :stale}
      end
    end)
  end

  def touch(%Prima.Actor{}, _identifier, _head_hash), do: {:error, :cross_tenant}

  @doc """
  Mark `identifier`'s account gone, as its directory answered: every
  binding of it retires in the same transaction, and `gone_at` is set on
  the database's clock, once. Answers `{:ok, %{head: row, retired:
  retired}}`; marking a gone account again retires what still stands and
  keeps its first `gone_at`. `{:error, :not_found}` for an identifier
  never cached: there is nothing here to mark, and an account never read
  binds nothing.
  """
  @spec gone(Prima.Actor.t(), String.t()) ::
          {:ok, %{head: row(), retired: retired()}} | {:error, term()}
  def gone(%Prima.Actor{scope: :platform, system: true}, identifier)
      when is_binary(identifier) do
    Arca.Repo.owned("Arca.DirectoryHeads.gone", fn -> gone_in(identifier) end)
  end

  def gone(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  Remove at most `limit` cached heads no one here holds, least recently
  verified first: a head whose identifier no person's identity row names
  (`Arca.PersonIdentities`, whatever its provenance) and no pending
  invitation names (an invited shared-thread seat's `person_identifier`),
  last verified more than `older_than_ms` before the database's clock now.
  Answers how many went.

  A head verified again while the sweep runs is judged on the row the
  delete reaches, so one a refresh has just verified stays.
  """
  @spec sweep(Prima.Actor.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :cross_tenant | :database_error}
  def sweep(%Prima.Actor{scope: :platform, system: true}, older_than_ms, limit)
      when is_integer(older_than_ms) and older_than_ms > 0 and is_integer(limit) and limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.sweep", fn ->
      Arca.Repo.locking_transaction(fn -> unheld_swept(older_than_ms, limit) end)
    end)
  end

  def sweep(%Prima.Actor{}, _older_than_ms, _limit), do: {:error, :cross_tenant}

  @doc false
  @spec fence!(String.t(), term()) :: {:ok, String.t()} | {:error, :stale_head}
  # Whether a write binding a key of the person `user_id` may name `head`,
  # decided in the caller's transaction with the person's row locked
  # first: `head` must be the cached head of the person's account, which
  # must not be gone. Answers the account's identifier. A person with no
  # account, or an account this home never read, has no head a write may
  # name: `:stale_head`, as for any other head.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def fence!(user_id, head) when is_binary(user_id) do
    lock_person!(user_id)

    cached =
      Arca.Repo.one(
        from(p in PersonIdentity,
          join: h in DirectoryHead,
          on: h.identifier == p.identifier,
          where: p.user_id == ^user_id and is_nil(h.gone_at),
          select: {h.identifier, h.head_hash}
        )
      )

    case cached do
      {identifier, ^head} when is_binary(head) -> {:ok, identifier}
      _other -> {:error, :stale_head}
    end
  end

  @doc false
  @spec lock_person!(String.t()) :: String.t() | nil
  # The person's row, locked: the first lock of every standing order.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def lock_person!(user_id) when is_binary(user_id) do
    from(u in User, where: u.id == ^user_id, select: u.id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # ---- internals -------------------------------------------------------------

  # The heads to go are chosen by a subquery, and the delete names the age
  # again on the row it reaches: on PostgreSQL a delete that waited on a
  # refresh re-reads the refreshed row's own columns, never the subquery's
  # choice, so a head verified meanwhile is kept.
  # arca:unscoped-ok the platform's housekeeping keeps a head any shared thread's pending invitation names, whichever thread it is.
  defp unheld_swept(older_than_ms, limit) do
    before = DateTime.add(Arca.ServerMetaStorage.now!(), -older_than_ms, :millisecond)

    people = from(p in PersonIdentity, where: not is_nil(p.identifier), select: p.identifier)

    invited =
      from(m in SharedThreadMember,
        where: m.status == "invited" and not is_nil(m.person_identifier),
        select: m.person_identifier
      )

    unheld =
      from(h in DirectoryHead,
        where:
          h.verified_at < ^before and h.identifier not in subquery(people) and
            h.identifier not in subquery(invited),
        order_by: [asc: h.verified_at],
        limit: ^limit,
        select: h.identifier
      )

    {count, _} =
      Arca.Repo.delete_all(
        from(h in DirectoryHead,
          where: h.identifier in subquery(unheld) and h.verified_at < ^before
        )
      )

    count
  end

  defp advance_in(identifier, expected_head, attrs, steps) do
    user_ids = lock_people!(identifier)

    with %DirectoryHead{} = cached <- locked(identifier) || {:error, :not_found},
         :ok <- same_binding(cached, attrs),
         :ok <- if(is_nil(cached.gone_at), do: :ok, else: {:error, :gone}),
         :ok <- if(cached.head_hash == expected_head, do: :ok, else: {:error, :stale}) do
      retired = Enum.reduce(steps, nothing_retired(), &walked(&1, identifier, user_ids, &2))
      now = Arca.ServerMetaStorage.now!()

      {1, _} =
        from(h in DirectoryHead,
          where: h.identifier == ^identifier and h.head_hash == ^expected_head
        )
        |> Arca.Repo.update_all(
          set: [
            head_hash: attrs.head_hash,
            state: attrs.state,
            keys_added: attrs.keys_added,
            verified_at: now,
            updated_at: now
          ],
          inc: [revision: 1]
        )

      Arca.Repo.update_all(
        from(p in PersonIdentity, where: p.identifier == ^identifier),
        set: [head_hash: attrs.head_hash, updated_at: now],
        inc: [revision: 1]
      )

      {:ok, %{head: Arca.Repo.get!(DirectoryHead, identifier), retired: retired}}
    end
  end

  defp gone_in(identifier) do
    user_ids = lock_people!(identifier)

    with %DirectoryHead{} = cached <- locked(identifier) || {:error, :not_found} do
      retired = walked(:recover, identifier, user_ids, nothing_retired())
      now = Arca.ServerMetaStorage.now!()

      if is_nil(cached.gone_at) do
        Arca.Repo.update_all(from(h in DirectoryHead, where: h.identifier == ^identifier),
          set: [gone_at: now, updated_at: now],
          inc: [revision: 1]
        )
      end

      {:ok, %{head: Arca.Repo.get!(DirectoryHead, identifier), retired: retired}}
    end
  end

  # One step of the walk, over the account's people: a removed key's
  # bindings, or every binding a recovery replaced and every session of
  # the people, bound to a key or not. The paired clients go first, with
  # what stands on them, then the bindings named directly.
  defp walked(step, identifier, user_ids, acc) do
    clients = PairedClients.revoke_bound!(user_ids, kid_of(step))
    certificates = DeviceCertificates.revoke_bound!(identifier, kid_of(step))
    confirmations = PendingConfirmations.void_bound!(user_ids, kid_of(step))
    sessions = SessionStorage.delete_bound!(user_ids, kid_of(step))

    %{
      session_hashes:
        Enum.uniq(
          acc.session_hashes ++
            clients.session_hashes ++ certificates.session_hashes ++ sessions
        ),
      certificate_ids:
        Enum.uniq(acc.certificate_ids ++ clients.certificate_ids ++ certificates.certificate_ids),
      confirmation_ids:
        Enum.uniq(acc.confirmation_ids ++ clients.confirmation_ids ++ confirmations),
      client_ids: Enum.uniq(acc.client_ids ++ clients.client_ids)
    }
  end

  # The key a step retires the bindings of; `:all` for every binding.
  defp kid_of({:remove_key, kid}), do: kid
  defp kid_of(:recover), do: :all

  defp locked(identifier) do
    from(h in DirectoryHead, where: h.identifier == ^identifier)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  defp same_binding(%DirectoryHead{genesis: genesis, directory_url: url}, %{
         genesis: genesis,
         directory_url: url
       }),
       do: :ok

  defp same_binding(_cached, _attrs), do: {:error, :binding_changed}

  # The identifier's people, locked in id order before anything else.
  # Answers their ids.
  defp lock_people!(identifier) do
    people = from(p in PersonIdentity, where: p.identifier == ^identifier, select: p.user_id)

    from(u in User, where: u.id in subquery(people), order_by: [asc: u.id], select: u.id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  defp nothing_retired,
    do: %{session_hashes: [], certificate_ids: [], confirmation_ids: [], client_ids: []}

  defp valid_steps(steps) do
    if Enum.all?(steps, &step?/1),
      do: :ok,
      else: {:error, {:invalid, %{steps: ["are {:remove_key, kid} or :recover"]}}}
  end

  defp step?({:remove_key, kid}), do: Prima.Identity.Encoding.digest?(kid)
  defp step?(:recover), do: true
  defp step?(_step), do: false

  defp valid(attrs, fields) do
    errors =
      for field <- fields, not valid?(field, Map.get(attrs, field)), into: %{} do
        {field, ["is required"]}
      end

    if errors == %{}, do: :ok, else: {:error, {:invalid, errors}}
  end

  defp valid?(:identifier, value), do: Prima.Identity.Encoding.identifier?(value)

  defp valid?(:genesis, value),
    do: is_binary(value) and value != "" and byte_size(value) <= Prima.Identity.max_entry_bytes()

  defp valid?(:directory_url, value), do: Prima.Identity.Encoding.directory_url?(value)
  defp valid?(:head_hash, value), do: Prima.Identity.Encoding.digest?(value)
  defp valid?(:state, value), do: is_binary(value) and value != ""
  defp valid?(:keys_added, value), do: is_binary(value) and value != ""
end
