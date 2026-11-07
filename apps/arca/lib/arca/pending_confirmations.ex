# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PendingConfirmations do
  @moduledoc """
  Pending confirmations of sensitive changes
  (`Arca.Schemas.PendingConfirmation`), athanor-scoped: each the stored
  form of one `Prima.Confirmation` record, with its digest, its
  secret-free preview, the credential that opened it, a name for the
  client that asked, how it was proven and by which paired client or key
  of the person's account, and its state.

  ## The ref and the secret

  A record is stored and named by its public `ref`, the record's `id` as
  the deciding site builds it (`Prima.Confirmation.ref/1` of the secret
  its `confirmation_required` signal answered to the asking request). The
  secret is never stored and never an argument here but one: proving,
  cancelling and reading take the `ref`, which any
  client of the person may know; consuming and checking take the secret,
  whose `ref` the store computes and looks the record up by. A `ref`
  presented as a secret names another record, so a client that learned a
  `ref` from a stream or a list never consumes with it.

  ## The opener

  A record names the credential of the context that opened it (`opener`,
  the identity domain's name for a session, a paired client or an API
  key). Only that credential consumes it, presenting the secret too: any
  client of the person may prove a record, but the change is repeated by
  the request that asked, so neither a second credential of the same
  person nor another holder of the same credential takes a change it did
  not ask for, even once it is proven. Arca compares the opener and reads
  nothing into it, nor into the `asker` it stores beside it.

  ## States

  `pending → confirmed → consumed`, or `cancelled`, `voided` or `expired`
  from either open state. Every move is a conditional write that succeeds
  once: a record confirmed, consumed or cancelled twice is refused the
  second time. Expiry is read on the database's clock.

    * `open/2` writes a new record for every request and never answers one
      that stands: two identical requests, by one credential or two, open
      two records, each under its own secret, and one never proven
      expires. One opener holds at most eight open records in an athanor:
      at the bound, its oldest is voided as the new one is written, so
      whoever holds a credential cannot flood its person's pending list.
      The count is read in the open's own transaction, so two opens racing
      on PostgreSQL may each find room: the bound is soft under concurrent
      opens, and the next open restores it.
    * `confirm/3` records the proof, a key of the person's account
      answering the record's request (`passkey` or `device`), with that
      key, the head it was verified under and the paired client that gave
      it, only while that client still stands, so a revocation that
      commits first leaves nothing to confirm with. It locks the client,
      then the record: the standing order (`Arca.SecurityTransitions`), so
      a confirm and a revocation of its confirmer never wait on each
      other.
    * `consume/3` consumes a confirmed, unexpired, unvoided record whose
      person, operation, argument digest, preview and opener are exactly
      the caller's. It runs in its own transaction or nested in a caller's, so
      an action whose effect opens a row consumes in the transaction that
      opens it. `check/3` asks the same question and writes nothing.
    * `void_confirmed_by!/2` voids the open records a revoked paired
      client confirmed, inside the transaction of the standing transition
      or the revocation that revokes it.

  A confirmed record carries the `kid` of the key that confirmed it and
  the account head it was verified under (`head`), which must be the
  cached head of the person's account when it is confirmed (`Arca.DirectoryHeads.fence!/2`,
  under the person's lock, the first of the standing order); the cached
  head's walk voids the open records a removed key confirmed, and a
  recovery every open record a key confirmed (`void_bound!/2`).

  Every function takes the actor first, and the athanor comes from the
  actor. Confirming proves first that this member still owns its slot
  (`:not_owner`); consuming, cancelling and voiding only narrow.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{DeviceCertificate, PairedClient, PendingConfirmation}
  alias Prima.Confirmation
  alias Prima.Confirmation.Preview

  # Confirming widens what the record lets a change do, so its transaction
  # first proves this member still owns its slot on the database's clock
  # (`Arca.Repo.owned/2`): a stale owner confirms nothing.

  @open ~w(pending confirmed)
  @max_asker 4096
  # The open records one opener holds in an athanor, at most.
  @open_per_opener 8

  @typedoc "A pending confirmation row, as a plain map, keyed by its `ref`."
  @type row :: map()

  @typedoc """
  What `consume/3` requires the record to still say, `:opener` the
  consuming context's credential.
  """
  @type expected :: %{
          required(:user_id) => String.t(),
          required(:operation) => String.t(),
          required(:args_digest) => String.t(),
          required(:preview) => Preview.t() | map(),
          required(:opener) => String.t()
        }

  @doc """
  Open a new pending confirmation in the actor's athanor: `attrs[:record]`
  is the `Prima.Confirmation` the deciding site built (its athanor the
  actor's, its `id` the record's ref, `Prima.Confirmation.ref?/1`, never
  the secret), `attrs[:opener]` the credential of the context that opens
  it (a non-empty name of at most 255 bytes), `attrs[:asker]` a name for
  the client that asked (a map the deciding site built, stored as JSON
  and read into by no one here). Every call writes a new record; none
  answers one that stands. A ref already stored is `:conflict`; a malformed
  attribute `{:invalid, _}`.

  The answer is the new record, with `:voided` the refs of the opener's
  oldest open records voided to keep it within `open_per_opener/0`
  (none, or one, unless concurrent opens had overrun the bound), which
  the caller announces as it announces any void.
  """
  @spec open(Prima.Actor.t(), map()) :: {:ok, row()} | {:error, term()}
  def open(%Prima.Actor{athanor_id: athanor_id}, %{record: %Confirmation{} = record} = attrs)
      when is_binary(athanor_id) and athanor_id != "" do
    cond do
      record.athanor != athanor_id ->
        {:error, :cross_tenant}

      not Confirmation.ref?(record.id) ->
        {:error, {:invalid, %{ref: ["names the record by its ref, never its secret"]}}}

      not opener?(Map.get(attrs, :opener)) ->
        {:error, {:invalid, %{opener: ["names the credential that opens the record"]}}}

      true ->
        with {:ok, asker} <- asker(Map.get(attrs, :asker)) do
          Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.open", fn ->
            Arca.Repo.locking_transaction(fn ->
              Arca.Repo.committed(open_in(athanor_id, record, attrs.opener, asker))
            end)
          end)
          |> Arca.Data.project()
          |> case do
            {:ok, {row, voided}} -> {:ok, Map.put(row, :voided, voided)}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  def open(%Prima.Actor{}, _attrs), do: {:error, :no_athanor}

  @doc "The open records one opener holds in an athanor, at most (`open/2`)."
  @spec open_per_opener() :: pos_integer()
  def open_per_opener, do: @open_per_opener

  @doc """
  Mark the pending record `ref` confirmed with `proof`: `:proof` is
  `"passkey"` or `"device"` (a protected device's signature over the
  record's request, which names the client), `:kid` the account key that
  signed and `:head` the account head it was verified under, both
  required, the head the cached head of the person's account
  (`:stale_head` otherwise), and `:client_id` the paired client that gave
  it, which must still stand. Succeeds once, before the record's expiry.
  Refusals: `:not_pending`, `:expired`, `:not_found`, `:revoked` (the
  client no longer stands), `:stale_head`, `{:invalid, errors}`,
  `:not_owner`, `:no_athanor`, `:database_error`.
  """
  @spec confirm(Prima.Actor.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def confirm(%Prima.Actor{athanor_id: athanor_id} = actor, ref, proof)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) and is_map(proof) do
    with {:ok, proof} <- proof(proof) do
      Arca.Repo.owned("Arca.PendingConfirmations.confirm", fn -> confirm_in(actor, ref, proof) end)
    end
  end

  def confirm(%Prima.Actor{}, _ref, _proof), do: {:error, :no_athanor}

  @doc """
  Consume the confirmed record whose secret is `id` (the store looks it
  up by `Prima.Confirmation.ref/1` of it) for exactly the change
  `expected` names (`t:expected/0`), by the credential that opened it.
  Succeeds once. The change and opener are compared before the state, so
  `:mismatch` (another person, operation, argument digest, preview or
  opener) answers whatever the record's state, and `:not_confirmed`
  means only that this exact change's unexpired record, opened by this
  credential, still waits for its proof. The other refusals: `:consumed`,
  `:cancelled`, `:voided`, `:expired`, `:not_found` (no record of that
  secret here, a `ref` presented as one among them), `:no_athanor`,
  `:database_error`.

  A refusal is a rollback of the transaction `consume/3` runs in. Nested
  in a caller's transaction, it therefore rolls the caller's whole
  transaction back, whatever the caller does next. A caller that must
  still write after a refused consume (a confirm-or-open that opens a new
  record in its place) calls `check/3` first, or runs `consume/3` in its
  own transaction.
  """
  @spec consume(Prima.Actor.t(), String.t(), expected()) :: {:ok, row()} | {:error, term()}
  def consume(%Prima.Actor{athanor_id: athanor_id} = actor, id, expected)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(expected) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.consume", fn ->
      Arca.Repo.locking_transaction(fn ->
        Arca.Repo.committed(consume_in(actor, Confirmation.ref(id), expected))
      end)
    end)
    |> Arca.Data.project()
  end

  def consume(%Prima.Actor{}, _id, _expected), do: {:error, :no_athanor}

  @doc """
  Whether `consume/3` would consume the record whose secret is `id` for
  `expected` now: `:ok`, or the refusal it would answer. Writes nothing
  and rolls nothing back, so a caller's transaction stays open for what
  it writes after a refusal. The record is read locked, so in a caller's
  transaction the answer holds until that transaction's own `consume/3`.
  """
  @spec check(Prima.Actor.t(), String.t(), expected()) :: :ok | {:error, term()}
  def check(%Prima.Actor{athanor_id: athanor_id} = actor, id, expected)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(id) and is_map(expected) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.check", fn ->
      now = Arca.ServerMetaStorage.now!()

      with {:ok, record} <- locked(actor, Confirmation.ref(id)),
           :ok <- matches(record, expected),
           :ok <- consumable(record, now) do
        device_stands(record, now)
      end
    end)
  end

  def check(%Prima.Actor{}, _id, _expected), do: {:error, :no_athanor}

  @doc "Cancel the open record `ref`. Succeeds once; a closed record answers `:not_open`."
  @spec cancel(Prima.Actor.t(), String.t()) :: {:ok, row()} | {:error, term()}
  def cancel(%Prima.Actor{athanor_id: athanor_id} = actor, ref)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.cancel", fn ->
      Arca.Repo.locking_transaction(fn ->
        Arca.Repo.committed(close(actor, ref, "cancelled"))
      end)
    end)
    |> Arca.Data.project()
  end

  def cancel(%Prima.Actor{}, _ref), do: {:error, :no_athanor}

  @doc "The record `ref` in the actor's athanor."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :no_athanor | :database_error}
  def get(%Prima.Actor{athanor_id: athanor_id} = actor, ref)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.get", fn ->
      PendingConfirmation
      |> QueryHelpers.where_tenant(actor)
      |> where([c], c.ref == ^ref)
      |> Arca.Repo.one()
      |> found()
    end)
    |> Arca.Data.project()
  end

  def get(%Prima.Actor{}, _ref), do: {:error, :no_athanor}

  @doc "The person's open, unexpired records in the actor's athanor, oldest first."
  @spec list_open(Prima.Actor.t(), String.t()) ::
          {:ok, [row()]} | {:error, :no_athanor | :database_error}
  def list_open(%Prima.Actor{athanor_id: athanor_id} = actor, user_id)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.list_open", fn ->
      now = Arca.ServerMetaStorage.now!()

      {:ok,
       PendingConfirmation
       |> QueryHelpers.where_tenant(actor)
       |> where([c], c.user_id == ^user_id and c.state in ^@open and c.expires_at > ^now)
       |> order_by([c], asc: c.opened_at, asc: c.ref)
       |> Arca.Repo.all()}
    end)
    |> Arca.Data.project()
  end

  def list_open(%Prima.Actor{}, _user_id), do: {:error, :no_athanor}

  @doc """
  The `Prima.Confirmation` a stored row records, rebuilt from its columns
  (its `id` the row's `ref`): the record whose digest the proof covers.
  """
  @spec confirmation(row()) :: {:ok, Confirmation.t()} | {:error, term()}
  def confirmation(%{} = row) do
    with {:ok, preview} <- row.preview |> Jason.decode!() |> Preview.decode() do
      Confirmation.new(
        id: row.ref,
        home: row.home,
        rp_id: row.rp_id,
        athanor: row.athanor_id,
        person: row.user_id,
        operation: row.operation,
        args_digest: row.args_digest,
        action: row.action,
        preview: preview,
        challenge: row.challenge,
        expires_at: DateTime.to_unix(row.expires_at, :millisecond)
      )
    end
  end

  @doc false
  @spec void_confirmed_by!(:paired_client, [String.t()]) :: [String.t()]
  # Void the open records confirmed by the paired clients `ids` names, in the caller's transaction: a revoked credential leaves
  # nothing it confirmed standing. Answers the refs it voided.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def void_confirmed_by!(_kind, []), do: []

  def void_confirmed_by!(:paired_client, ids),
    do: void_all(from(c in PendingConfirmation, where: c.confirmed_client_id in ^ids))

  @doc false
  @spec void_bound!([String.t()], String.t() | :all) :: [String.t()]
  # Void the open records of `user_ids` the key `kid` confirmed, or with
  # `:all` every open record a key confirmed, in the caller's transaction
  # (`Arca.DirectoryHeads.advance/5`).
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def void_bound!([], _kid), do: []

  def void_bound!(user_ids, :all) when is_list(user_ids),
    do:
      void_all(
        from(c in PendingConfirmation, where: c.user_id in ^user_ids and not is_nil(c.kid))
      )

  def void_bound!(user_ids, kid) when is_list(user_ids) and is_binary(kid),
    do: void_all(from(c in PendingConfirmation, where: c.user_id in ^user_ids and c.kid == ^kid))

  @doc false
  @spec void_all(Ecto.Queryable.t()) :: [String.t()]
  # Void every open record `query` names, answering the refs it voided,
  # sorted. The one voiding statement.
  # arca:unscoped-ok the caller's query carries its own scope: an athanor, a person or a credential.
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def void_all(query) do
    now = Arca.ServerMetaStorage.now!()

    {_count, refs} =
      Arca.Repo.update_all(
        from(c in query, where: c.state in ^@open, select: c.ref),
        set: [state: "voided", ended_at: now, updated_at: now]
      )

    Enum.sort(refs || [])
  end

  @doc false
  @spec delete_all!() :: [String.t()]
  # A declared restore's delete, in its transaction
  # (`Arca.SecurityTransitions.restore/1`): every record, open or ended,
  # goes, so no confirmation given before the backup was taken proves a
  # change after it. Answers the refs deleted.
  # arca:unscoped-ok a declared restore deletes every pending confirmation of the server.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def delete_all! do
    {_count, refs} = Arca.Repo.delete_all(from(c in PendingConfirmation, select: c.ref))
    Enum.sort(refs || [])
  end

  # ---- internals -------------------------------------------------------------

  # A new record, always: none that stands is answered, whoever opened it.
  # The person's lock first, the head of the standing order every write to
  # their records takes; room is made within the opener's bound.
  defp open_in(athanor_id, record, opener, asker) do
    _locked = Arca.DirectoryHeads.lock_person!(record.person)
    voided = make_room!(athanor_id, record.person, opener)
    now = Arca.ServerMetaStorage.now!()

    row = %{
      ref: record.id,
      athanor_id: athanor_id,
      user_id: record.person,
      operation: record.operation,
      args_digest: record.args_digest,
      action: record.action,
      preview: preview_text(record.preview),
      home: record.home,
      rp_id: record.rp_id,
      challenge: record.challenge,
      digest: Confirmation.digest(record),
      opener: opener,
      asker: asker,
      state: "pending",
      opened_at: now,
      expires_at: DateTime.from_unix!(record.expires_at * 1000, :microsecond),
      inserted_at: now,
      updated_at: now
    }

    case Arca.Repo.insert_all(PendingConfirmation, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, {Arca.Repo.get!(PendingConfirmation, record.id), voided}}
      {0, _} -> {:error, :conflict}
    end
  end

  # Void the opener's oldest open records in this athanor, of this person,
  # so that with the one about to be written it holds no more than its
  # bound. Answers the refs it voided, oldest first.
  defp make_room!(athanor_id, user_id, opener) do
    held =
      from(c in PendingConfirmation,
        where:
          c.athanor_id == ^athanor_id and c.user_id == ^user_id and c.opener == ^opener and
            c.state in ^@open,
        order_by: [asc: c.opened_at, asc: c.ref],
        select: c.ref
      )
      |> Arca.Repo.all()

    case length(held) - (@open_per_opener - 1) do
      excess when excess > 0 ->
        oldest = Enum.take(held, excess)

        voided =
          from(c in PendingConfirmation, where: c.athanor_id == ^athanor_id and c.ref in ^oldest)
          |> void_all()

        Enum.filter(oldest, &(&1 in voided))

      _room ->
        []
    end
  end

  # The confirmer's lock comes before the record's: the paired client,
  # then the record, the order every standing transition takes.
  # The record's person and athanor never change, so reading them unlocked
  # to find the confirmer is sound; its state is read again under lock.
  defp confirm_in(actor, ref, proof) do
    with {:ok, person} <- person_of(actor, ref),
         :ok <- fenced(person, proof),
         :ok <- confirmer_stands(person, proof),
         {:ok, record} <- locked(actor, ref),
         now = Arca.ServerMetaStorage.now!(),
         :ok <- device_certified(proof.proof, person.athanor_id, proof.client_id, now),
         :ok <- state_is(record, "pending"),
         :ok <- unexpired(record, now) do
      {count, _} =
        from(c in PendingConfirmation,
          where: c.athanor_id == ^record.athanor_id and c.ref == ^ref and c.state == "pending"
        )
        |> Arca.Repo.update_all(
          set: [
            state: "confirmed",
            proof: proof.proof,
            confirmed_client_id: proof.client_id,
            kid: proof.kid,
            head: proof.head,
            confirmed_at: now,
            updated_at: now
          ]
        )

      if count == 1,
        do: {:ok, Arca.Repo.get!(PendingConfirmation, ref)},
        else: {:error, :not_pending}
    end
  end

  defp person_of(actor, ref) do
    PendingConfirmation
    |> QueryHelpers.where_tenant(actor)
    |> where([c], c.ref == ^ref)
    |> select([c], %{user_id: c.user_id, athanor_id: c.athanor_id})
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :not_found}
      person -> {:ok, person}
    end
  end

  # The proof names the head its key was verified under, read under the
  # person's lock, the first of the standing order.
  defp fenced(person, %{head: head}) do
    with {:ok, _identifier} <- Arca.DirectoryHeads.fence!(person.user_id, head), do: :ok
  end

  # The paired client that gave the proof still stands, read under lock: a
  # revocation that committed first leaves nothing to confirm with, and one
  # that follows voids this record.
  defp confirmer_stands(_person, %{client_id: nil}), do: :ok

  defp confirmer_stands(person, %{client_id: client_id}) do
    from(p in PairedClient,
      where:
        p.athanor_id == ^person.athanor_id and p.id == ^client_id and
          p.user_id == ^person.user_id and p.standing == "active",
      select: p.id
    )
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> case do
      nil -> {:error, :revoked}
      _id -> :ok
    end
  end

  defp consume_in(actor, ref, expected) do
    now = Arca.ServerMetaStorage.now!()

    with {:ok, record} <- locked(actor, ref),
         :ok <- matches(record, expected),
         :ok <- consumable(record, now),
         :ok <- device_stands(record, now) do
      {count, _} =
        from(c in PendingConfirmation,
          where: c.athanor_id == ^record.athanor_id and c.ref == ^ref and c.state == "confirmed"
        )
        |> Arca.Repo.update_all(set: [state: "consumed", ended_at: now, updated_at: now])

      if count == 1,
        do: {:ok, Arca.Repo.get!(PendingConfirmation, ref)},
        else: {:error, :consumed}
    end
  end

  defp consumable(%PendingConfirmation{state: "confirmed"} = record, now),
    do: unexpired(record, now)

  # A pending record answers `:not_confirmed` only while it can still be
  # proven; the change and opener were compared first, so the answer means
  # that this very request's record waits for its proof.
  defp consumable(%PendingConfirmation{state: "pending"} = record, now) do
    with :ok <- unexpired(record, now), do: {:error, :not_confirmed}
  end

  defp consumable(%PendingConfirmation{state: "consumed"}, _now), do: {:error, :consumed}
  defp consumable(%PendingConfirmation{state: "cancelled"}, _now), do: {:error, :cancelled}
  defp consumable(%PendingConfirmation{state: "voided"}, _now), do: {:error, :voided}
  defp consumable(%PendingConfirmation{state: "expired"}, _now), do: {:error, :expired}

  # A protected device's confirmation stands on its device as it stands at
  # consumption too: the client active and holding a certificate unexpired
  # and unrevoked, read under the client's lock, so a revocation, a
  # rotation or an expiry since the proof leaves the change unconsumed.
  defp device_stands(%PendingConfirmation{proof: "device"} = record, now) do
    with :ok <-
           confirmer_stands(
             %{athanor_id: record.athanor_id, user_id: record.user_id},
             %{client_id: record.confirmed_client_id}
           ),
         do: device_certified("device", record.athanor_id, record.confirmed_client_id, now)
  end

  defp device_stands(%PendingConfirmation{}, _now), do: :ok

  # A device's proof stands only on a certificate of its client this home
  # recorded, unrevoked and unexpired now.
  defp device_certified("device", athanor_id, client_id, now) do
    if Arca.Repo.exists?(
         from(c in DeviceCertificate,
           where:
             c.athanor_id == ^athanor_id and c.paired_client_id == ^client_id and
               c.state == "active" and c.expires_at > ^now
         )
       ),
       do: :ok,
       else: {:error, :revoked}
  end

  defp device_certified(_proof, _athanor_id, _client_id, _now), do: :ok

  # The same change, asked by the credential that opened the record: a
  # consumer naming no opener, or another, matches nothing.
  defp matches(record, expected) do
    with {:ok, preview} <- expected_preview(Map.get(expected, :preview)) do
      same? =
        record.user_id == Map.get(expected, :user_id) and
          record.operation == Map.get(expected, :operation) and
          record.args_digest == Map.get(expected, :args_digest) and
          record.preview == preview_text(preview) and
          opener?(Map.get(expected, :opener)) and record.opener == Map.get(expected, :opener)

      if same?, do: :ok, else: {:error, :mismatch}
    else
      _ -> {:error, :mismatch}
    end
  end

  defp expected_preview(%Preview{} = preview), do: {:ok, preview}
  defp expected_preview(%{} = attrs), do: Preview.new(attrs)
  defp expected_preview(_other), do: {:error, :mismatch}

  defp close(actor, ref, state) do
    now = Arca.ServerMetaStorage.now!()

    with {:ok, record} <- locked(actor, ref) do
      {count, _} =
        from(c in PendingConfirmation,
          where: c.athanor_id == ^record.athanor_id and c.ref == ^ref and c.state in ^@open
        )
        |> Arca.Repo.update_all(set: [state: state, ended_at: now, updated_at: now])

      if count == 1,
        do: {:ok, Arca.Repo.get!(PendingConfirmation, ref)},
        else: {:error, :not_open}
    end
  end

  defp locked(actor, ref) do
    PendingConfirmation
    |> QueryHelpers.where_tenant(actor)
    |> where([c], c.ref == ^ref)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> found()
  end

  defp state_is(%PendingConfirmation{state: state}, state), do: :ok
  defp state_is(%PendingConfirmation{}, _state), do: {:error, :not_pending}

  defp unexpired(%PendingConfirmation{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: :ok, else: {:error, :expired}
  end

  # Every proof is a key of the person's account: it names the key and the
  # head it was verified under, which the fence holds to the cached head.
  defp proof(%{proof: kind} = proof) when kind in ~w(passkey device) do
    client_id = Map.get(proof, :client_id)
    kid = Map.get(proof, :kid)
    head = Map.get(proof, :head)

    cond do
      not (Prima.Identity.Encoding.digest?(kid) and Prima.Identity.Encoding.digest?(head)) ->
        {:error, {:invalid, %{kid: ["names the key that signed and the head, both"]}}}

      kind == "device" and not (is_binary(client_id) and client_id != "") ->
        {:error, {:invalid, %{client_id: ["names the device that signed"]}}}

      not (is_nil(client_id) or (is_binary(client_id) and client_id != "")) ->
        {:error, {:invalid, %{client_id: ["is malformed"]}}}

      true ->
        {:ok, %{proof: kind, client_id: client_id, kid: kid, head: head}}
    end
  end

  defp proof(_proof), do: {:error, {:invalid, %{proof: ["is passkey or device"]}}}

  defp opener?(opener),
    do: is_binary(opener) and byte_size(opener) > 0 and byte_size(opener) <= 255

  # The asker as the JSON the row keeps: a map the deciding site built,
  # bounded so a name never outgrows a record.
  defp asker(asker) when is_map(asker) and not is_struct(asker) and map_size(asker) > 0 do
    case Jason.encode(asker) do
      {:ok, json} when byte_size(json) <= @max_asker -> {:ok, json}
      _unencodable -> {:error, {:invalid, %{asker: ["is a small JSON object"]}}}
    end
  end

  defp asker(_asker),
    do: {:error, {:invalid, %{asker: ["names the client that asked"]}}}

  defp preview_text(%Preview{} = preview),
    do: preview |> Preview.encode() |> Prima.Identity.Encoding.jcs!()

  defp found(nil), do: {:error, :not_found}
  defp found(%PendingConfirmation{} = row), do: {:ok, row}
end
