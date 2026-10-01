# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PendingConfirmations do
  @moduledoc """
  Pending confirmations of sensitive changes
  (`Arca.Schemas.PendingConfirmation`), athanor-scoped: each the stored
  form of one `Prima.Confirmation` record, with its digest, its
  secret-free preview, the credential that opened it, a name for the
  client that asked, how it was proven and by which paired client or
  passkey, and its state.

  ## The ref and the secret

  A record is stored and named by its public `ref`, the record's `id` as
  the deciding site builds it (`Prima.Confirmation.ref/1` of the secret
  its `confirmation_required` signal answered to the asking request). The
  secret is never stored and never an argument here but one: proving,
  cancelling, holding a challenge and reading take the `ref`, which any
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
    * `confirm/3` records the proof (`passkey`, `oidc_reauth` or
      `email_code`) and the paired client or passkey that gave it, only
      while that client or passkey still stands, so a revocation that
      commits first leaves nothing to confirm with. It locks the client,
      then the passkey, then the record: the standing order
      (`Arca.SecurityTransitions`), so a confirm and a revocation of its
      confirmer never wait on each other.
    * `consume/3` consumes a confirmed, unexpired, unvoided record whose
      person, operation, argument digest, preview and opener are exactly
      the caller's. It runs in its own transaction or nested in a caller's, so
      an action whose effect opens a row consumes in the transaction that
      opens it. `check/3` asks the same question and writes nothing.
    * `void_for/2` voids the open records a revoked paired client or
      passkey confirmed; the standing transitions and passkey revocation
      void them in their own transactions.

  A remote person's record carries the `identity_key_epoch` it depends on,
  which must be the cached head's current one when it opens
  (`Arca.DirectoryHeads.bindable!/2`, under the person's lock), and a head
  that retires the epoch voids it (`void_key_epoch!/2`); a local person's
  carries none.

  Every function takes the actor first, and the athanor comes from the
  actor. Confirming and holding a challenge prove first that this member
  still owns its slot (`:not_owner`); consuming, cancelling and voiding
  only narrow.
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{PairedClient, Passkey, PendingConfirmation}
  alias Prima.Confirmation
  alias Prima.Confirmation.Preview

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
  and read into by no one here), and `attrs[:identity_key_epoch]` the
  epoch a remote person's record depends on (required for a remote person
  and the cached head's current one, `:stale_key_epoch` otherwise;
  refused for a local one). Every call writes a new record; none answers
  one that stands. A ref already stored is `:conflict`; a malformed
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
              committed(
                open_in(
                  athanor_id,
                  record,
                  attrs.opener,
                  asker,
                  Map.get(attrs, :identity_key_epoch)
                )
              )
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
  `"passkey"`, `"oidc_reauth"` or `"email_code"`, and `:passkey_id` or
  `:client_id` name the passkey or paired client that gave it, which must
  still stand. Succeeds once, before the record's expiry. Refusals:
  `:not_pending`, `:expired`, `:not_found`, `:revoked` (the passkey or
  client no longer stands), `{:invalid, errors}`, `:not_owner`,
  `:no_athanor`, `:database_error`.
  """
  @spec confirm(Prima.Actor.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def confirm(%Prima.Actor{athanor_id: athanor_id} = actor, ref, proof)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) and is_map(proof) do
    with {:ok, proof} <- proof(proof) do
      Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.confirm", fn ->
        fenced(fn -> confirm_in(actor, ref, proof) end)
      end)
      |> Arca.Data.project()
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
        committed(consume_in(actor, Confirmation.ref(id), expected))
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
           :ok <- matches(record, expected) do
        consumable(record, now)
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
        committed(close(actor, ref, "cancelled"))
      end)
    end)
    |> Arca.Data.project()
  end

  def cancel(%Prima.Actor{}, _ref), do: {:error, :no_athanor}

  @doc """
  Void the open records a revoked paired client (`{:paired_client, id}`,
  in the actor's athanor) or passkey (`{:passkey, id}`, which is the
  person's and so crosses athanors: the platform's own actor only)
  confirmed. Answers the refs it voided.
  """
  @spec void_for(Prima.Actor.t(), {:paired_client | :passkey, String.t()}) ::
          {:ok, [String.t()]} | {:error, :no_athanor | :cross_tenant | :database_error}
  def void_for(%Prima.Actor{athanor_id: athanor_id}, {:paired_client, client_id})
      when is_binary(athanor_id) and athanor_id != "" and is_binary(client_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.void_for", fn ->
      Arca.Repo.locking_transaction(fn ->
        void_all(
          from(c in PendingConfirmation,
            where: c.athanor_id == ^athanor_id and c.confirmed_client_id == ^client_id
          )
        )
      end)
    end)
  end

  def void_for(%Prima.Actor{scope: :platform, system: true}, {:passkey, passkey_id})
      when is_binary(passkey_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.void_for", fn ->
      Arca.Repo.locking_transaction(fn -> void_confirmed_by!(:passkey, [passkey_id]) end)
    end)
  end

  def void_for(%Prima.Actor{athanor_id: nil}, {:paired_client, _client_id}),
    do: {:error, :no_athanor}

  def void_for(%Prima.Actor{athanor_id: ""}, {:paired_client, _client_id}),
    do: {:error, :no_athanor}

  def void_for(%Prima.Actor{}, _confirmer), do: {:error, :cross_tenant}

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
  Hold a re-authentication's nonce, or an email code's hash, on the
  pending record `ref`, replacing any earlier one and resetting the code's
  failure count; the record's expiry does not move. A held challenge is
  what a proof answers, so this member first proves it still owns its
  slot (`:not_owner`).
  """
  @spec put_challenge(Prima.Actor.t(), String.t(), map()) :: {:ok, row()} | {:error, term()}
  def put_challenge(%Prima.Actor{athanor_id: athanor_id} = actor, ref, challenge)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) and is_map(challenge) do
    set =
      case challenge do
        %{reauth_nonce: nonce} when is_binary(nonce) and nonce != "" ->
          [reauth_nonce: nonce]

        %{email_code_hash: hash} when is_binary(hash) and hash != "" ->
          [email_code_hash: hash, email_code_failures: 0]

        _ ->
          nil
      end

    if set do
      Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.put_challenge", fn ->
        fenced(fn ->
          now = Arca.ServerMetaStorage.now!()

          PendingConfirmation
          |> QueryHelpers.where_tenant(actor)
          |> where([c], c.ref == ^ref and c.state == "pending" and c.expires_at > ^now)
          |> Arca.Repo.update_all(set: Keyword.put(set, :updated_at, now))
          |> case do
            {1, _} -> {:ok, Arca.Repo.get!(PendingConfirmation, ref)}
            {0, _} -> {:error, :not_pending}
          end
        end)
      end)
      |> Arca.Data.project()
    else
      {:error, {:invalid, %{challenge: ["is a reauth_nonce or an email_code_hash"]}}}
    end
  end

  def put_challenge(%Prima.Actor{}, _ref, _challenge), do: {:error, :no_athanor}

  @doc """
  Count a wrong email code against the pending record `ref`: at `limit`
  failures the record is cancelled. Answers the record as it stands after.
  """
  @spec count_code_failure(Prima.Actor.t(), String.t(), pos_integer()) ::
          {:ok, row()} | {:error, term()}
  def count_code_failure(%Prima.Actor{athanor_id: athanor_id} = actor, ref, limit)
      when is_binary(athanor_id) and athanor_id != "" and is_binary(ref) and is_integer(limit) and
             limit > 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.PendingConfirmations.count_code_failure", fn ->
      Arca.Repo.locking_transaction(fn ->
        now = Arca.ServerMetaStorage.now!()

        mine =
          PendingConfirmation
          |> QueryHelpers.where_tenant(actor)
          |> where([c], c.ref == ^ref and c.state == "pending")

        {_count, _} =
          Arca.Repo.update_all(mine, inc: [email_code_failures: 1], set: [updated_at: now])

        mine
        |> where([c], c.email_code_failures >= ^limit)
        |> Arca.Repo.update_all(set: [state: "cancelled", ended_at: now, updated_at: now])

        case Arca.Repo.get(PendingConfirmation, ref) do
          %PendingConfirmation{athanor_id: ^athanor_id} = row -> row
          _ -> Arca.Repo.rollback(:not_found)
        end
      end)
    end)
    |> Arca.Data.project()
  end

  def count_code_failure(%Prima.Actor{}, _ref, _limit), do: {:error, :no_athanor}

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
  @spec void_confirmed_by!(:passkey | :paired_client, [String.t()]) :: [String.t()]
  # Void the open records confirmed by the passkeys or paired clients
  # `ids` names, in the caller's transaction: a revoked credential leaves
  # nothing it confirmed standing. Answers the refs it voided.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def void_confirmed_by!(_kind, []), do: []

  def void_confirmed_by!(:passkey, ids),
    do: void_all(from(c in PendingConfirmation, where: c.confirmed_passkey_id in ^ids))

  def void_confirmed_by!(:paired_client, ids),
    do: void_all(from(c in PendingConfirmation, where: c.confirmed_client_id in ^ids))

  @doc false
  @spec void_key_epoch!([String.t()], String.t()) :: [String.t()]
  # Void the open records of `user_ids` that depend on `key_epoch`, in the
  # caller's transaction (`Arca.DirectoryHeads.advance/4`).
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def void_key_epoch!([], _key_epoch), do: []

  def void_key_epoch!(user_ids, key_epoch) when is_list(user_ids) and is_binary(key_epoch) do
    void_all(
      from(c in PendingConfirmation,
        where: c.user_id in ^user_ids and c.identity_key_epoch == ^key_epoch
      )
    )
  end

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

  # ---- internals -------------------------------------------------------------

  # A new record, always: none that stands is answered, whoever opened it.
  # Room is made first, within the opener's bound.
  defp open_in(athanor_id, record, opener, asker, epoch) do
    with :ok <- Arca.DirectoryHeads.bindable!(record.person, epoch) do
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
        identity_key_epoch: epoch,
        state: "pending",
        email_code_failures: 0,
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

  # The confirmer's lock comes before the record's: paired client, then
  # passkey, then the record, the order every standing transition takes.
  # The record's person and athanor never change, so reading them unlocked
  # to find the confirmer is sound; its state is read again under lock.
  defp confirm_in(actor, ref, proof) do
    with {:ok, person} <- person_of(actor, ref),
         :ok <- confirmer_stands(person, proof),
         {:ok, record} <- locked(actor, ref),
         now = Arca.ServerMetaStorage.now!(),
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
            confirmed_passkey_id: proof.passkey_id,
            confirmed_client_id: proof.client_id,
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

  # The paired client, then the passkey, that gave the proof still stands,
  # read under lock: a revocation that committed first leaves nothing to
  # confirm with, and one that follows voids this record.
  defp confirmer_stands(person, %{passkey_id: passkey_id, client_id: client_id}) do
    client_ok =
      is_nil(client_id) or
        from(p in PairedClient,
          where:
            p.athanor_id == ^person.athanor_id and p.id == ^client_id and
              p.user_id == ^person.user_id and p.standing == "active",
          select: p.id
        )
        |> QueryHelpers.for_update()
        |> Arca.Repo.one()
        |> is_binary()

    passkey_ok =
      client_ok and
        (is_nil(passkey_id) or
           from(p in Passkey,
             where: p.id == ^passkey_id and p.user_id == ^person.user_id and p.state == "active",
             select: p.id
           )
           |> QueryHelpers.for_update()
           |> Arca.Repo.one()
           |> is_binary())

    if passkey_ok, do: :ok, else: {:error, :revoked}
  end

  defp consume_in(actor, ref, expected) do
    now = Arca.ServerMetaStorage.now!()

    with {:ok, record} <- locked(actor, ref),
         :ok <- matches(record, expected),
         :ok <- consumable(record, now) do
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

  defp proof(%{proof: kind} = proof) when kind in ~w(passkey oidc_reauth email_code) do
    passkey_id = Map.get(proof, :passkey_id)
    client_id = Map.get(proof, :client_id)

    cond do
      kind == "passkey" and not (is_binary(passkey_id) and passkey_id != "") ->
        {:error, {:invalid, %{passkey_id: ["names the passkey that asserted"]}}}

      kind != "passkey" and not is_nil(passkey_id) ->
        {:error, {:invalid, %{passkey_id: ["only a passkey proof names one"]}}}

      not (is_nil(client_id) or (is_binary(client_id) and client_id != "")) ->
        {:error, {:invalid, %{client_id: ["is malformed"]}}}

      true ->
        {:ok, %{proof: kind, passkey_id: passkey_id, client_id: client_id}}
    end
  end

  defp proof(_proof),
    do: {:error, {:invalid, %{proof: ["is passkey, oidc_reauth or email_code"]}}}

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

  # Confirming, and holding the challenge a proof answers, widen what the
  # record lets a change do, so their transaction first proves this member
  # still owns its slot on the database's clock
  # (`Arca.ControlPlane.verify_held/1`): a stale owner confirms nothing.
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
end
