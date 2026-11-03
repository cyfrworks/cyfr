# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.SessionStorage do
  @moduledoc """
  Storage operations for sessions.

  This module provides the database layer for session storage.
  It's called by `Sanctum.Session` which handles token hashing.

  Tokens are stored as SHA-256 hashes for indexed lookups.
  Session metadata (user_id, email, provider) is stored as plaintext, and
  so is a command line's `cli_machine`, which marks the session as a
  command line's (`list_command_lines/1`, `delete_command_line/2`).

  A session of a person whose identity is `remote`
  (`Arca.PersonIdentities`) records the `identity_key_epoch` of the head
  verified when it was minted, whichever door admitted it, and a local
  person's session records none: the insert refuses either the other way
  round, and refuses an epoch that is not the cached head's current one
  (`Arca.DirectoryHeads.bindable!/2`, read under the person's lock, so an
  advance that retires the epoch either retires this session or refuses
  it). The advance ends every session carrying a `key_epoch` the fresh
  head retired.

  A protected device's unlock reserves a session row that records its
  paired `client_id` and that no token loads (`reserve_client_session/2`),
  and the ticket's redemption activates it under its token
  (`activate_client_session/3`). Its `expires_at` is the device channel's:
  `slide_client_sessions/4` moves it, never past the certificate's expiry
  and never for a session already expired, and `refresh_session/2`, the
  browser's sliding refresh, never moves it. A lock deletes exactly the
  session it names, reserved or active (`delete_client_sessions/2`); a
  revocation of the client, or of a certificate of the client that was
  still unexpired, deletes all of its sessions (`delete_clients!/1`).
  """

  import Ecto.Query

  alias Arca.Schemas.Session

  # A protected device's session: reserved at its unlock, which no token
  # loads, and active once its ticket is redeemed.
  @reserved "unlock_reserved"
  @unlocked "unlock"

  # ============================================================================
  # Sessions
  # ============================================================================

  @doc """
  Insert a new session, in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): `lock:` names the rows the
  session's standing rests on and `verify:` is the caller's policy over
  them, asked with them locked. A standing transition that retires the
  person or the athanor either commits first and is reread here, or waits
  for this session and then retires it.

  `attrs[:identity_key_epoch]` is required for a person whose identity is
  `remote` (`{:error, :identity_key_epoch_required}`), must be the cached
  head's current `key_epoch` (`{:error, :stale_key_epoch}`), and is refused
  for any other person (`{:error, :unexpected_key_epoch}`).
  `attrs[:cli_machine]` names the machine a command line's session is
  issued to, and is absent for a browser's. A protected device's session
  is never created here: its unlock reserves it and its redemption
  activates it (`activate_client_session/3`). `also:`
  (optional) is the higher owner's closure, run in the same transaction
  after the insert and handed the session's `%{id, user_id}`: it answers
  `:ok`, or `{:error, reason}` to roll the session back; any other answer
  raises `ArgumentError`, which rolls the session back too.

  Answers `:ok`, or the policy's refusal with nothing written, or
  `{:error, :not_owner}` from a member that no longer owns its slot.
  """
  @spec create_session(binary(), map(), keyword()) :: :ok | {:error, term()}
  def create_session(token_hash, attrs, opts) when is_binary(token_hash) and is_list(opts) do
    lock = Keyword.fetch!(opts, :lock)
    verify = Keyword.fetch!(opts, :verify)
    also = Keyword.get(opts, :also, fn _session -> :ok end)

    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.create_session", fn ->
      Arca.SecurityTransitions.Issuance.run(lock, verify, fn _locked ->
        with {:ok, session} <- insert_session(token_hash, attrs),
             :ok <- also_ran(also.(session)) do
          {:ok, :inserted}
        end
      end)
      |> case do
        {:ok, :inserted} -> :ok
        {:error, _reason} = refusal -> refusal
      end
    end)
  end

  defp insert_session(token_hash, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    epoch = attrs[:identity_key_epoch]

    row = %{
      id: Prima.UUID7.generate_id("ses"),
      token_hash: token_hash,
      token_prefix: attrs[:token_prefix],
      user_id: attrs.user_id,
      email: attrs[:email],
      provider: attrs.provider,
      # A nil athanor is a real state: the session exists from sign-in on,
      # before the caller's athanor is resolved. Membership re-resolution
      # runs on the next load; nothing is coerced.
      athanor_id: attrs[:athanor_id],
      identity_key_epoch: epoch,
      cli_machine: attrs[:cli_machine],
      expires_at: attrs.expires_at,
      inserted_at: Map.get(attrs, :inserted_at, now)
    }

    with :ok <- Arca.DirectoryHeads.bindable!(attrs.user_id, epoch) do
      Arca.Repo.insert_all(Session, [row])
      {:ok, %{id: row.id, user_id: row.user_id}}
    end
  end

  defp also_ran(:ok), do: :ok
  defp also_ran({:error, _reason} = refusal), do: refusal

  defp also_ran(other) do
    raise ArgumentError,
          "an also: closure answers :ok or {:error, reason}, got " <>
            Prima.LoggerContext.shape(other)
  end

  @doc """
  Get a session by token_hash. Returns `{:ok, row}` or `{:error, :not_found}`.

  Only returns non-expired sessions.
  """
  @spec get_session(binary()) :: {:ok, map()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok sessions are credential-keyed; athanor_id is nullable pre-resolution (tenancy fabric).
  def get_session(token_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.get_session", fn ->
      now = DateTime.utc_now()

      # Select a struct with everything except the secret token_hash/token_prefix.
      query =
        from(s in Session,
          where: s.token_hash == ^token_hash and s.expires_at > ^now,
          limit: 1,
          select: [
            :id,
            :user_id,
            :email,
            :provider,
            :athanor_id,
            :identity_key_epoch,
            :cli_machine,
            :client_id,
            :expires_at,
            :inserted_at
          ]
        )

      case Arca.Repo.one(query) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end)
    |> Arca.Data.project()
  end

  @doc """
  Update a session's expires_at. A protected device's session is not
  found here: only its device channel moves it (`slide_client_sessions/4`).
  """
  @spec refresh_session(binary(), DateTime.t()) :: :ok | {:error, :not_found | :database_error}
  # arca:unscoped-ok sessions are addressed by token hash — the credential is
  # the scope, and the athanor is a column on the row it finds.
  def refresh_session(token_hash, new_expires_at) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.refresh_session", fn ->
      query = from(s in Session, where: s.token_hash == ^token_hash and is_nil(s.client_id))

      case Arca.Repo.update_all(query, set: [expires_at: new_expires_at]) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end)
  end

  @doc """
  Reserve the session `id` of the protected device `attrs.client_id` when
  its unlock challenge names it: a row of the person (`attrs.user_id`,
  `:email`, `:athanor_id`) that no token loads, since its token hash has no
  token behind it, expiring at `attrs.expires_at`, the challenge's
  deadline, which the proof carries to the ticket's
  (`hold_client_reservation/3`). A lock retires it
  (`delete_client_sessions/2`), before the proof or after, and the
  ticket's redemption activates it (`activate_client_session/3`); whether
  a lock happened is this row's absence, never a cache entry's. Written under
  the member's slot (`Arca.Repo.owned/2`).
  """
  @spec reserve_client_session(String.t(), map()) ::
          :ok | {:error, :not_owner | :database_error}
  def reserve_client_session("ses_" <> _ = id, %{client_id: client_id} = attrs)
      when is_binary(client_id) do
    Arca.Repo.owned("Arca.SessionStorage.reserve_client_session", fn ->
      row = %{
        id: id,
        token_hash: :crypto.strong_rand_bytes(32),
        user_id: attrs.user_id,
        email: attrs[:email],
        provider: @reserved,
        athanor_id: attrs[:athanor_id],
        client_id: client_id,
        expires_at: usec(attrs.expires_at),
        inserted_at: Arca.ServerMetaStorage.now!()
      }

      {1, _} = Arca.Repo.insert_all(Session, [row])
      {:ok, :reserved}
    end)
    |> case do
      {:ok, :reserved} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Carry the reservation `id` of the protected device `client_id` to
  `until`, its ticket's deadline, under the member's slot, while it is
  still reserved and unexpired on the database's clock; one a lock or the
  channel's end deleted, or that expired, is
  `{:error, :reservation_retired}`.
  """
  @spec hold_client_reservation(String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, :reservation_retired | :not_owner | :database_error}
  # arca:unscoped-ok a reserved session is addressed by its own id and the client its unlock reserved it for.
  def hold_client_reservation(client_id, id, %DateTime{} = until)
      when is_binary(client_id) and is_binary(id) do
    Arca.Repo.owned("Arca.SessionStorage.hold_client_reservation", fn ->
      now = Arca.ServerMetaStorage.now!()

      from(s in Session,
        where:
          s.id == ^id and s.client_id == ^client_id and s.provider == ^@reserved and
            s.expires_at > ^now
      )
      |> Arca.Repo.update_all(set: [expires_at: usec(until)])
      |> case do
        {1, _} -> {:ok, :held}
        {0, _} -> {:error, :reservation_retired}
      end
    end)
    |> case do
      {:ok, :held} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Activate the reserved session `attrs.id` of the protected device
  `attrs.client_id` under the token whose hash is `token_hash`, in the
  issuance transaction (`create_session/3`'s `lock:` and `verify:`): after
  the person, athanor, seat, client and certificates are locked and
  reread, the reserved row is locked and, while it is still reserved and
  unexpired on the database's clock, takes the token, the provider
  `unlock`, `attrs.expires_at` and `attrs.identity_key_epoch` (bound as
  `create_session/3` binds it). A row a lock retired, the channel's end
  deleted or that expired is `{:error, :reservation_retired}`, with
  nothing written. The client's lock is taken before the row's, as a lock
  takes it, so a lock that committed first is read here and one that
  starts later waits and then retires the session.
  """
  @spec activate_client_session(binary(), map(), keyword()) :: :ok | {:error, term()}
  # arca:unscoped-ok a reserved session is addressed by its own id and the client its unlock reserved it for.
  def activate_client_session(token_hash, %{id: id, client_id: client_id} = attrs, opts)
      when is_binary(token_hash) and is_binary(id) and is_binary(client_id) and is_list(opts) do
    lock = Keyword.fetch!(opts, :lock)
    verify = Keyword.fetch!(opts, :verify)

    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.activate_client_session", fn ->
      Arca.SecurityTransitions.Issuance.run(lock, verify, fn _locked ->
        now = Arca.ServerMetaStorage.now!()

        reserved =
          from(s in Session,
            where:
              s.id == ^id and s.client_id == ^client_id and s.provider == ^@reserved and
                s.expires_at > ^now,
            select: s.id
          )
          |> Arca.QueryHelpers.for_update()
          |> Arca.Repo.one()

        with id when is_binary(id) <- reserved || {:error, :reservation_retired},
             :ok <- Arca.DirectoryHeads.bindable!(attrs.user_id, attrs[:identity_key_epoch]) do
          {1, _} =
            Arca.Repo.update_all(from(s in Session, where: s.id == ^id),
              set: [
                token_hash: token_hash,
                token_prefix: attrs[:token_prefix],
                provider: @unlocked,
                identity_key_epoch: attrs[:identity_key_epoch],
                expires_at: usec(attrs.expires_at),
                inserted_at: now
              ]
            )

          {:ok, :activated}
        end
      end)
      |> case do
        {:ok, :activated} -> :ok
        {:error, _reason} = refusal -> refusal
      end
    end)
  end

  @doc """
  Slide the active sessions `ids` of the protected device `client_id` to
  `lifetime_ms` past the database's clock, capped at `cap`, the expiry of
  the certificate the device's channel stands under, under the member's
  slot (`Arca.Repo.owned/2`): a member that lost it moves nothing. A
  session already expired stays expired, a reservation keeps the ticket's
  deadline, and one of another client is not moved. Answers the ids of
  `ids` that still stand, active or reserved.
  """
  @spec slide_client_sessions(String.t(), [String.t()], pos_integer(), DateTime.t()) ::
          {:ok, [String.t()]} | {:error, :not_owner | :database_error}
  # arca:unscoped-ok sessions are addressed by the client their unlock created them for, and their own ids.
  def slide_client_sessions(client_id, ids, lifetime_ms, %DateTime{} = cap)
      when is_binary(client_id) and is_list(ids) and is_integer(lifetime_ms) do
    Arca.Repo.owned("Arca.SessionStorage.slide_client_sessions", fn ->
      now = Arca.ServerMetaStorage.now!()
      until = usec(Enum.min([DateTime.add(now, lifetime_ms, :millisecond), cap], DateTime))

      standing =
        from(s in Session,
          where: s.client_id == ^client_id and s.id in ^ids and s.expires_at > ^now
        )

      Arca.Repo.update_all(from(s in standing, where: s.provider == ^@unlocked),
        set: [expires_at: until]
      )

      {:ok, standing |> select([s], s.id) |> Arca.Repo.all() |> Enum.sort()}
    end)
  end

  @doc """
  Delete the sessions `ids` of the protected device `client_id`, whatever
  their expiry: a lock, or the end of the device's channel. The paired
  client's row is locked first, the lock a session's issuance under that
  client takes (`Arca.SecurityTransitions.Issuance`), so an issuance that
  committed first is deleted here and one that starts later reads what
  its caller marked before this ran. A session already gone, or one of
  another client, is left as it is. Answers the token hashes it deleted.
  """
  @spec delete_client_sessions(String.t(), [String.t()]) ::
          {:ok, [binary()]} | {:error, :database_error}
  # arca:unscoped-ok a lock names its client and the sessions it retires.
  def delete_client_sessions(client_id, ids) when is_binary(client_id) and is_list(ids) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.delete_client_sessions", fn ->
      fn ->
        _client =
          from(p in Arca.Schemas.PairedClient, where: p.id == ^client_id, select: p.id)
          |> Arca.QueryHelpers.for_update()
          |> Arca.Repo.one()

        {_count, hashes} =
          Arca.Repo.delete_all(
            from(s in Session,
              where: s.client_id == ^client_id and s.id in ^ids,
              select: s.token_hash
            )
          )

        hashes || []
      end
      |> Arca.Repo.locking_transaction()
      |> case do
        {:ok, hashes} -> {:ok, hashes}
        {:error, _reason} -> {:error, :database_error}
      end
    end)
  end

  @doc false
  @spec delete_clients!([String.t()]) :: [binary()]
  # Delete every session the protected devices `client_ids` created, in
  # the caller's transaction: their revocation (`Arca.PairedClients`).
  # Answers the deleted rows' token hashes.
  def delete_clients!([]), do: []

  # arca:unscoped-ok sessions addressed by the clients the caller revokes.
  # arca:db-raise-ok a transaction step: its callers rescue around it.
  def delete_clients!(client_ids) when is_list(client_ids) do
    {_count, hashes} =
      Arca.Repo.delete_all(
        from(s in Session, where: s.client_id in ^client_ids, select: s.token_hash)
      )

    hashes || []
  end

  @doc """
  Delete a session by token_hash.
  """
  @spec delete_session(binary()) :: :ok | {:error, :database_error}
  # arca:unscoped-ok signing out is addressed by the token being retired.
  def delete_session(token_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.delete_session", fn ->
      query = from(s in Session, where: s.token_hash == ^token_hash)
      Arca.Repo.delete_all(query)
      :ok
    end)
  end

  @doc """
  Delete every session of one user. Returns `{:ok, count}`.
  """
  @spec delete_by_user(String.t()) :: {:ok, non_neg_integer()} | {:error, :database_error}
  # arca:unscoped-ok crossing athanors is the point: a person denied at the
  # door loses every session, wherever it was established.
  def delete_by_user(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.delete_by_user", fn ->
      {count, _} = Arca.Repo.delete_all(from(s in Session, where: s.user_id == ^user_id))
      {:ok, count}
    end)
  end

  @doc """
  The token hashes of every session of one user — what a user-wide
  revocation invalidates in the established-context memo, which is keyed
  by hash. A store failure returns `[]`: the delete that follows still
  lands, and the memo entries it misses lapse with the TTL.
  """
  @spec hashes_by_user(String.t()) :: [binary()]
  def hashes_by_user(user_id) when is_binary(user_id) do
    # Deliberate fail-open to []: the revocation's delete still runs, and a
    # memo entry this read missed dies with the memo TTL — never a grant.
    # arca:unscoped-ok sessions are user-owned rows (a session exists from
    # sign-in on, before any athanor is resolved); user_id is the scope.
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.hashes_by_user", [], fn ->
      Arca.Repo.all(from(s in Session, where: s.user_id == ^user_id, select: s.token_hash))
    end)
  end

  @doc """
  The live command-line sessions of the person `user_id` (those minted
  with a `cli_machine`), oldest first: `%{id, cli_machine, inserted_at,
  expires_at}` each, never a token's hash or prefix.
  """
  @spec list_command_lines(String.t()) :: {:ok, [map()]} | {:error, :database_error}
  # arca:unscoped-ok sessions are person-owned rows that exist before any
  # athanor is resolved; the person is the scope.
  def list_command_lines(user_id) when is_binary(user_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.list_command_lines", fn ->
      now = DateTime.utc_now()

      rows =
        Arca.Repo.all(
          from(s in Session,
            where: s.user_id == ^user_id and not is_nil(s.cli_machine) and s.expires_at > ^now,
            order_by: [asc: s.inserted_at, asc: s.id],
            select: %{
              id: s.id,
              cli_machine: s.cli_machine,
              inserted_at: s.inserted_at,
              expires_at: s.expires_at
            }
          )
        )

      {:ok, rows}
    end)
  end

  @doc """
  End the person `user_id`'s command-line session `id`: answers the
  token hash it deleted, for the caller to announce, or `{:error,
  :not_found}` when the person holds no command-line session by that id.
  A browser's session is never ended here.
  """
  @spec delete_command_line(String.t(), String.t()) ::
          {:ok, binary()} | {:error, :not_found | :database_error}
  # arca:unscoped-ok sessions are person-owned rows; the person is the scope.
  def delete_command_line(user_id, id) when is_binary(user_id) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.delete_command_line", fn ->
      query =
        from(s in Session,
          where: s.id == ^id and s.user_id == ^user_id and not is_nil(s.cli_machine),
          select: s.token_hash
        )

      case Arca.Repo.delete_all(query) do
        {0, _} -> {:error, :not_found}
        {_count, [hash | _]} -> {:ok, hash}
      end
    end)
  end

  @doc false
  # The statement that ends the session minted under `token_hash`, run in
  # a caller's transaction (`Arca.CliSignIns.cancel/1`): answers the
  # person it was, or nil when no session holds that token.
  @spec delete_token!(binary()) :: String.t() | nil
  # arca:unscoped-ok a session is addressed by its token's hash; the credential is the scope.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def delete_token!(token_hash) when is_binary(token_hash) do
    case Arca.Repo.delete_all(
           from(s in Session, where: s.token_hash == ^token_hash, select: s.user_id)
         ) do
      {_count, [user_id | _]} -> user_id
      {_count, _none} -> nil
    end
  end

  @doc false
  # End every session of the people `user_ids` that carries `key_epoch`: a
  # fresh head retired it, and a session minted under a live key the head
  # no longer names must not outlive the refresh. Answers the token hashes
  # it ended, for the caller to invalidate after commit. Run in the
  # caller's transaction (`Arca.DirectoryHeads.advance/4`).
  @spec delete_key_epoch!([String.t()], String.t()) :: [binary()]
  def delete_key_epoch!([], _key_epoch), do: []

  # arca:unscoped-ok sessions are person-owned; the people and the epoch are the scope.
  # arca:db-raise-ok a transaction step: its callers rescue around the transaction.
  def delete_key_epoch!(user_ids, key_epoch) when is_list(user_ids) and is_binary(key_epoch) do
    {_count, hashes} =
      Arca.Repo.delete_all(
        from(s in Session,
          where: s.user_id in ^user_ids and s.identity_key_epoch == ^key_epoch,
          select: s.token_hash
        )
      )

    hashes || []
  end

  @doc """
  Delete all expired sessions globally. Used by daemon processes for housekeeping.

  Returns `{:ok, count}`, or `{:error, :database_error}` when the store
  cannot answer.
  """
  @spec cleanup_expired_sessions() :: {:ok, non_neg_integer()} | {:error, :database_error}
  # arca:unscoped-ok expiry is server-wide housekeeping over a column that
  # has nothing to do with tenancy.
  def cleanup_expired_sessions do
    Arca.Repo.Errors.with_db_rescue("Arca.SessionStorage.cleanup_expired_sessions", fn ->
      now = DateTime.utc_now()
      query = from(s in Session, where: s.expires_at <= ^now)

      {count, _} = Arca.Repo.delete_all(query)
      {:ok, count}
    end)
  end

  # An instant at the column's microsecond precision, as a certificate's
  # millisecond expiry arrives.
  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}
end
