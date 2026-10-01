# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DirectoryHeads do
  @moduledoc """
  This home's verified cache of other people's identity heads
  (`Arca.Schemas.DirectoryHead`), one row per identifier.

  A row keeps the genesis the chain was verified from and the directory it
  names: both are immutable once cached, so a later refresh can never move
  an identifier to another directory or another genesis
  (`:binding_changed`). The head, its `key_epoch`, its `recovery_epoch`
  and the verified state move by compare-and-set on the head the caller
  last read (`advance/4`), and `verified_at` is written on the database's
  clock, which is also the clock `fresh/3` compares against.

  ## A changed epoch

  When an advance changes an epoch, everything this home bound to the old
  one retires in the same transaction, before the new head is visible.
  A changed `key_epoch` (any rotation or recovery) retires the sessions of
  the identifier's people that carry it (`Arca.SessionStorage`), the
  identity-subject device certificates issued under it
  (`Arca.DeviceCertificates`) and their open confirmations that depend on
  it (`Arca.PendingConfirmations`). A changed `recovery_epoch` (a recovery
  that replaced the live key) retires their passkeys registered under it
  (`Arca.Passkeys`): a passkey registered at this home never depended on
  the live key an ordinary rotation replaces, so it outlives that
  rotation, and a recover that only adds a recovery holder. The answer
  names what retired, for the caller to announce after commit.

  ## One order with every epoch-bound write

  An advance locks the identifier's people first, in the standing lock
  order (`Arca.SecurityTransitions`), then the cached head, then what it
  retires. Every write that binds an epoch — a session, a pending
  confirmation or an identity-subject certificate its `key_epoch`, a
  passkey its `recovery_epoch` — holds the same person's lock and reads
  the cached epoch under it (`bindable!/2`, `certifiable!/3`,
  `recovery_bindable!/2`), refusing one that is no longer current
  (`:stale_key_epoch`). So a credential bound to an epoch either commits
  before the advance and is retired by it, or waits for it and is
  refused.

  ## Who writes

  The platform's own actor, for the home's identity freshness. Rows are
  plain maps (`Arca.Data`) with `state` as the JSON the caller stored.
  """

  import Ecto.Query

  alias Arca.{DeviceCertificates, Passkeys, PendingConfirmations, SessionStorage}
  alias Arca.Schemas.{DirectoryHead, PersonIdentity, User}

  @typedoc "A cached head, as a plain map."
  @type row :: map()

  @typedoc "What an advance retired."
  @type retired :: %{
          session_hashes: [binary()],
          passkey_ids: [String.t()],
          confirmation_ids: [String.t()],
          certificate_ids: [String.t()]
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
  `{:ok, %{head: row, fresh: boolean}}`.
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
          {:ok, %{head: head, fresh: age_ms <= max_age_seconds * 1000}}
      end
    end)
    |> Arca.Data.project()
  end

  def fresh(%Prima.Actor{}, _identifier, _max_age_seconds), do: {:error, :cross_tenant}

  @doc """
  Cache a first verified head: `attrs` names the `:identifier`, the
  `:genesis` bytes, the `:directory_url` it names, the `:head_hash`, the
  `:key_epoch`, the `:recovery_epoch` and the verified `:state` (JSON
  text). An identifier already cached is `{:error, :exists}`, answered
  with nothing written: a later head moves through `advance/4`.
  """
  @spec put(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def put(%Prima.Actor{scope: :platform, system: true}, attrs) when is_map(attrs) do
    attrs = Map.new(attrs)

    with :ok <-
           valid(attrs, [
             :identifier,
             :genesis,
             :directory_url,
             :head_hash,
             :key_epoch,
             :recovery_epoch,
             :state
           ]) do
      Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.put", fn ->
        fenced(fn ->
          now = Arca.ServerMetaStorage.now!()

          row = %{
            identifier: attrs.identifier,
            genesis: attrs.genesis,
            directory_url: attrs.directory_url,
            head_hash: attrs.head_hash,
            key_epoch: attrs.key_epoch,
            recovery_epoch: attrs.recovery_epoch,
            state: attrs.state,
            verified_at: now,
            revision: 1,
            inserted_at: now,
            updated_at: now
          }

          case Arca.Repo.insert_all(DirectoryHead, [row], on_conflict: :nothing) do
            {1, _} -> {:ok, Arca.Repo.get!(DirectoryHead, attrs.identifier)}
            {0, _} -> {:error, :exists}
          end
        end)
      end)
      |> Arca.Data.project()
    end
  end

  def put(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc """
  Move `identifier`'s cached head from `expected_head` to a newly verified
  one: `attrs` names the `:genesis` and `:directory_url` the chain was
  verified from (which must be the cached ones), the `:head_hash`, the
  `:key_epoch`, the `:recovery_epoch` and the `:state`. `verified_at` is
  the database's clock.

  When the `key_epoch` or the `recovery_epoch` changes, what was bound to
  the old one retires in the same transaction (the module doc). Answers
  `{:ok, %{head: row, retired: retired}}`, or `{:error, :stale}` when the
  cached head is no longer `expected_head`, `{:error, :binding_changed}`
  for another genesis or directory, `{:error, :not_found}` for an
  identifier never cached.
  """
  @spec advance(Prima.Actor.t(), String.t(), String.t(), map()) ::
          {:ok, %{head: row(), retired: retired()}} | {:error, term()}
  def advance(%Prima.Actor{scope: :platform, system: true}, identifier, expected_head, attrs)
      when is_binary(identifier) and is_binary(expected_head) and is_map(attrs) do
    attrs = Map.new(attrs)

    with :ok <-
           valid(attrs, [
             :genesis,
             :directory_url,
             :head_hash,
             :key_epoch,
             :recovery_epoch,
             :state
           ]) do
      Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.advance", fn ->
        fenced(fn -> advance_in(identifier, expected_head, attrs) end)
      end)
      |> Arca.Data.project()
    end
  end

  def advance(%Prima.Actor{}, _identifier, _expected_head, _attrs), do: {:error, :cross_tenant}

  @doc """
  Record that `identifier`'s cached head was verified again unchanged:
  `verified_at` moves to the database's clock while the head is still
  `head_hash`. `{:error, :stale}` otherwise.
  """
  @spec touch(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :stale | :cross_tenant | :database_error}
  def touch(%Prima.Actor{scope: :platform, system: true}, identifier, head_hash)
      when is_binary(identifier) and is_binary(head_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.touch", fn ->
      fenced(fn ->
        now = Arca.ServerMetaStorage.now!()

        from(h in DirectoryHead, where: h.identifier == ^identifier and h.head_hash == ^head_hash)
        |> Arca.Repo.update_all(set: [verified_at: now, updated_at: now])
        |> case do
          {1, _} -> {:ok, Arca.Repo.get!(DirectoryHead, identifier)}
          {0, _} -> {:error, :stale}
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def touch(%Prima.Actor{}, _identifier, _head_hash), do: {:error, :cross_tenant}

  @doc "Drop `identifier`'s cached head. Idempotent."
  @spec delete(Prima.Actor.t(), String.t()) :: :ok | {:error, :cross_tenant | :database_error}
  def delete(%Prima.Actor{scope: :platform, system: true}, identifier)
      when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.DirectoryHeads.delete", fn ->
      {:ok, _} =
        Arca.Repo.locking_transaction(fn ->
          Arca.Repo.delete_all(from(h in DirectoryHead, where: h.identifier == ^identifier))
        end)

      :ok
    end)
  end

  def delete(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  # ---- internals -------------------------------------------------------------

  defp advance_in(identifier, expected_head, attrs) do
    lock_people!(identifier)

    with %DirectoryHead{} = cached <- locked(identifier) || {:error, :not_found},
         :ok <- same_binding(cached, attrs),
         :ok <- if(cached.head_hash == expected_head, do: :ok, else: {:error, :stale}) do
      now = Arca.ServerMetaStorage.now!()

      {1, _} =
        from(h in DirectoryHead,
          where: h.identifier == ^identifier and h.head_hash == ^expected_head
        )
        |> Arca.Repo.update_all(
          set: [
            head_hash: attrs.head_hash,
            key_epoch: attrs.key_epoch,
            recovery_epoch: attrs.recovery_epoch,
            state: attrs.state,
            verified_at: now,
            updated_at: now
          ],
          inc: [revision: 1]
        )

      retired =
        retire!(
          identifier,
          {cached.key_epoch, attrs.key_epoch},
          {cached.recovery_epoch, attrs.recovery_epoch}
        )

      {:ok, %{head: Arca.Repo.get!(DirectoryHead, identifier), retired: retired}}
    end
  end

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

  # What this home bound to an epoch the advance replaced, for the
  # identifier's people, in the standing order: sessions and certificates
  # bound to the old `key_epoch`, passkeys registered under the old
  # `recovery_epoch` (with the confirmations they proved), and the open
  # confirmations bound to the old `key_epoch`. Only a recovery that
  # replaced the live key moves the `recovery_epoch`.
  defp retire!(_identifier, {key, key}, {recovery, recovery}), do: nothing_retired()

  defp retire!(identifier, {old_key, new_key}, {old_recovery, new_recovery}) do
    user_ids = people_of(identifier)
    key_moved? = old_key != new_key

    session_hashes =
      if key_moved?, do: SessionStorage.delete_key_epoch!(user_ids, old_key), else: []

    certificate_ids =
      if key_moved?, do: DeviceCertificates.revoke_key_epoch!(identifier, old_key), else: []

    passkey_ids =
      if old_recovery != new_recovery,
        do: Passkeys.revoke_recovery_epoch!(user_ids, old_recovery),
        else: []

    confirmation_ids =
      if key_moved?, do: PendingConfirmations.void_key_epoch!(user_ids, old_key), else: []

    %{
      session_hashes: session_hashes,
      certificate_ids: certificate_ids,
      passkey_ids: passkey_ids,
      confirmation_ids: confirmation_ids
    }
  end

  defp people_of(identifier) do
    Arca.Repo.all(
      from(p in PersonIdentity,
        where: p.identifier == ^identifier,
        order_by: [asc: p.user_id],
        select: p.user_id
      )
    )
  end

  # The identifier's people, locked in id order before anything else.
  defp lock_people!(identifier) do
    people = from(p in PersonIdentity, where: p.identifier == ^identifier, select: p.user_id)

    from(u in User, where: u.id in subquery(people), order_by: [asc: u.id], select: u.id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.all()
  end

  @doc false
  @spec bindable!(String.t(), String.t() | nil) ::
          :ok | {:error, :identity_key_epoch_required | :unexpected_key_epoch | :stale_key_epoch}
  # Whether a credential of the person `user_id` may bind `epoch`, decided
  # in the caller's transaction with the person's row locked first: a
  # remote person's credential binds the cached head's current
  # `key_epoch` (`:identity_key_epoch_required` without one,
  # `:stale_key_epoch` for any other), and a local person's binds none
  # (`:unexpected_key_epoch`).
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def bindable!(user_id, epoch) when is_binary(user_id) do
    lock_person!(user_id)

    identity =
      Arca.Repo.one(
        from(p in PersonIdentity,
          where: p.user_id == ^user_id and p.provenance == "remote",
          select: p.identifier
        )
      )

    cond do
      is_nil(identity) and is_nil(epoch) -> :ok
      is_nil(identity) -> {:error, :unexpected_key_epoch}
      not Prima.Identity.Encoding.digest?(epoch) -> {:error, :identity_key_epoch_required}
      current_epoch!(identity) == epoch -> :ok
      true -> {:error, :stale_key_epoch}
    end
  end

  @doc false
  @spec recovery_bindable!(String.t(), String.t() | nil) ::
          :ok | {:error, :identity_key_epoch_required | :unexpected_key_epoch | :stale_key_epoch}
  # Whether a passkey of the person `user_id` may bind the recovery epoch
  # `epoch`, decided in the caller's transaction with the person's row
  # locked first: a remote person's passkey binds the cached head's
  # current `recovery_epoch` (`:identity_key_epoch_required` without one,
  # `:stale_key_epoch` for any other), and a local person's binds none
  # (`:unexpected_key_epoch`), as `bindable!/2` holds a `key_epoch`.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def recovery_bindable!(user_id, epoch) when is_binary(user_id) do
    lock_person!(user_id)

    identity =
      Arca.Repo.one(
        from(p in PersonIdentity,
          where: p.user_id == ^user_id and p.provenance == "remote",
          select: p.identifier
        )
      )

    cond do
      is_nil(identity) and is_nil(epoch) -> :ok
      is_nil(identity) -> {:error, :unexpected_key_epoch}
      not Prima.Identity.Encoding.digest?(epoch) -> {:error, :identity_key_epoch_required}
      current_recovery_epoch!(identity) == epoch -> :ok
      true -> {:error, :stale_key_epoch}
    end
  end

  @doc false
  @spec certifiable!(String.t(), String.t(), String.t()) :: :ok | {:error, :stale_key_epoch}
  # Whether an identity-subject certificate of the person `user_id` may
  # bind `identifier`'s `epoch`, decided in the caller's transaction with
  # the person's row and then the cached head's row locked, the order an
  # advance takes: the cached head's current `key_epoch`, or, for an
  # identifier this home caches no head of, the person's own local
  # identity (whose epoch no directory head retires). Anything else is
  # `:stale_key_epoch`.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def certifiable!(user_id, identifier, epoch)
      when is_binary(user_id) and is_binary(identifier) and is_binary(epoch) do
    lock_person!(user_id)

    head_epoch =
      from(h in DirectoryHead, where: h.identifier == ^identifier, select: h.key_epoch)
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()

    # A person's own local identity has no cached head: its current
    # `key_epoch` is the hash of its latest log entry, since every entry
    # introduces a live key, which the identity row holds as its head.
    # The row is read under its own lock, so a rotation moving its head
    # cannot pass between this read and the certificate's insert.
    own_epoch = fn ->
      from(p in PersonIdentity,
        where: p.user_id == ^user_id and p.identifier == ^identifier and p.provenance == "local",
        select: p.head_hash
      )
      |> Arca.QueryHelpers.for_update()
      |> Arca.Repo.one()
    end

    cond do
      head_epoch == epoch -> :ok
      is_nil(head_epoch) and own_epoch.() == epoch -> :ok
      true -> {:error, :stale_key_epoch}
    end
  end

  @doc false
  @spec current_epoch!(String.t()) :: String.t() | nil
  # The `key_epoch` of `identifier`'s cached head, or nil for one this home
  # has not cached, read in the caller's transaction after it took the
  # person's lock.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def current_epoch!(identifier) when is_binary(identifier) do
    Arca.Repo.one(
      from(h in DirectoryHead, where: h.identifier == ^identifier, select: h.key_epoch)
    )
  end

  @doc false
  @spec current_recovery_epoch!(String.t()) :: String.t() | nil
  # The `recovery_epoch` of `identifier`'s cached head, or nil for one this
  # home has not cached, read in the caller's transaction after it took
  # the person's lock.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def current_recovery_epoch!(identifier) when is_binary(identifier) do
    Arca.Repo.one(
      from(h in DirectoryHead, where: h.identifier == ^identifier, select: h.recovery_epoch)
    )
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

  # Publishing a head decides which remote credentials this home accepts,
  # so each write first proves this member still owns its slot on the
  # database's clock (`Arca.ControlPlane.verify_held/1`): a stale owner
  # publishes nothing.
  defp fenced(write) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot() do
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> committed(write.())
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)

  defp nothing_retired,
    do: %{session_hashes: [], passkey_ids: [], confirmation_ids: [], certificate_ids: []}

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
  defp valid?(:key_epoch, value), do: Prima.Identity.Encoding.digest?(value)
  defp valid?(:recovery_epoch, value), do: Prima.Identity.Encoding.digest?(value)
  defp valid?(:state, value), do: is_binary(value) and value != ""
end
