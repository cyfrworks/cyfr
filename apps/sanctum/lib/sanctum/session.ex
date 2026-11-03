# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Session do
  @moduledoc """
  Session management for CYFR.

  Provides session storage backed by `Arca.SessionStorage`.
  Tokens are hashed (SHA-256) before storage —
  the actual token is never persisted.

  ## Usage

      # Create a session — only after the door admitted the identity
      # (`PrismWeb.AuthController.callback/2`, `Sanctum.Auth.DeviceFlow`)
      {:ok, session} = Sanctum.Session.create(ctx)

      # Load context from session token
      {:ok, ctx} = Sanctum.Session.load(session.token)

      # Refresh session (extend expiration)
      {:ok, session} = Sanctum.Session.refresh(session.token)

      # Destroy session on logout
      :ok = Sanctum.Session.destroy(session.token)

  ## Session Format

  Each session contains:
  - `token` - Random 32-byte base64 token
  - `user_id` - The person's id on this server (`usr_…`, `Prima.PersonId`)
  - `email` - Email (optional)
  - `provider` - Auth provider (e.g., "github", "google")
  - `created_at` - ISO 8601 timestamp
  - `expires_at` - ISO 8601 timestamp (30 days by default; extended on activity)

  ## Storage

  Sessions are stored via `Arca.SessionStorage`.
  Tokens are stored as SHA-256 hashes for indexed lookups.
  Expired sessions are automatically cleaned up.
  """

  require Logger

  alias Sanctum.Context

  # The idle timeout is the `session_ttl_hours` platform setting (720, 30
  # days, by default), read through `Arca.PlatformSettings.effective/1` on
  # each create and refresh. Sessions slide forward on activity (see
  # `refresh_if_stale/1`), so it is an idle timeout, not a hard cap.
  @token_bytes 32
  # Year 9999 — used as expires_at when TTL is 0 (infinite)
  # Microsecond precision so it dumps cleanly into the `:utc_datetime_usec`
  # `expires_at` column on both adapters.
  @never_expires ~U[9999-12-31 23:59:59.999999Z]

  # `{:ok, 0}` is sessions that never idle out, an intentional self-hosted
  # choice. The setting refuses a stale value: a store that cannot answer
  # it is `{:error, :unavailable}`, and nothing is issued or extended on a
  # window this member cannot read.
  defp session_ttl_hours do
    case Arca.PlatformSettings.effective("session_ttl_hours") do
      {:ok, hours} when is_integer(hours) and hours >= 0 ->
        {:ok, hours}

      {:ok, other} ->
        Logger.error(
          "[Sanctum.Session] the stored session_ttl_hours #{inspect(other)} is not a " <>
            "whole number of hours; refusing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.Session] session_ttl_hours cannot be read: the setting is #{reason}"
    end
  end

  defp expires_at(0, _now), do: @never_expires
  defp expires_at(hours, now), do: DateTime.add(now, hours * 3600, :second)

  @type session :: %{
          token: String.t(),
          user_id: String.t(),
          email: String.t() | nil,
          provider: String.t(),
          created_at: String.t(),
          expires_at: String.t()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new session for an authenticated context. Callers are the
  sign-in paths (the module doc of `Sanctum`), after the door admitted
  the person and `Sanctum.Tenancy.resolve_status/2` bound the admitted
  context, and the installation-authorized restore (`restore:` below);
  nothing else mints one.

  The session is written in the issuance transaction
  (`Arca.SecurityTransitions.Issuance`): the person and the session's
  athanor are locked and reread, and must still be active at the
  generations the context read (`ctx.credential_binding`), and the
  athanor must still be the person's own. A context that read
  its standing before a denial or an archive therefore cannot mint a
  session after the allow or the reopen: `{:error, :stale_generation}`.
  A context with no binding is `{:error, :missing_generation}` — except
  where `generation_snapshot:` supplies one read from the rows
  (`Sanctum.Tenancy.generation_snapshot/2`), which only a test fixture
  building a context by hand does. `{:error, :unauthenticated}` is a
  person or athanor that no longer stands, and
  `{:error, :unavailable}` an idle timeout the store cannot answer.

  The session's provider `restore` is reserved
  (`Sanctum.Auth.Identity.reserved_provider?/1`): only the
  installation-authorized restore issues one, naming in `restore:` the
  restore attempt that minted this very person and has reached `minted`
  or `completed` (`Sanctum.Recovery`). Any other request for it is
  `{:error, :reserved_provider}`, so neither an external identity claim nor
  an ordinary session request selects the provider whose recent session
  may initialize a person's first fresh method.

  ## A remote person's session

  A session of a person whose identity is `remote` records the
  `identity_key_epoch` of their head, read fresh from their directory
  (`Sanctum.IdentityFreshness.fresh!/2`) before the session's transaction
  opens, whichever door admitted them: the `cyfr` door, a passkey
  registered here or a door linked here. The store binds it under the
  person's lock to the cached head's current epoch
  (`Arca.SessionStorage.create_session/3`), so a rotation or a recovery
  either retires the session or refuses it (`{:error, :stale_key_epoch}`),
  whenever it lands after that read. A directory that cannot be read
  mints nothing (`{:error, :identity_stale}`). A local person's session
  records none.

  A sign-in a door admitted stands on that door (the context's `door`,
  which its binding names): the session is issued only while the door is
  still the person's, read under the person's lock in the issuing
  transaction (`{:error, :unauthenticated}` otherwise). So a door the
  fresh read above retired, because the head it found is a recovery that
  replaced the live key (`Arca.DirectoryHeads`), signs no one in.

  ## The epoch a door verified under

  `key_epoch:` is the `key_epoch` of the head the door verified the
  person's proof against, nil for a local person, whose proof stands on
  no head. When it is given, the fresh read must answer the same epoch
  (`{:error, :stale_key_epoch}` otherwise): a rotation or a recovery that
  lands between the door's verification and this read moved the head
  the proof was checked against, and what the new head retired (a
  passkey a recovery replaced among it) is not judged here, so nothing
  is minted and the door verifies again. Absent, the session records
  whatever epoch the fresh read answers.

  ## A login receipt

  `login_receipt: %{token: token, receipt: attrs}` is the `cyfr` door's
  (`Sanctum.Auth.CyfrDoor`): the session's token is the one the door
  derived for its challenge rather than a random one, and the receipt
  (`Arca.CarryActions.record_receipt/2`'s `attrs`) commits in the
  session's own transaction, so a session and its receipt exist together
  or not at all. The receipt's `key_epoch`, the one the assertion was
  verified under, must be the fresh head's (`{:error, :stale_key_epoch}`):
  a rotation between the proof and the session admits nothing.

  Returns a session map containing the token and identity fields.
  """
  @spec create(Context.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def create(%Context{} = ctx, opts \\ []) when is_list(opts) do
    receipt = Keyword.get(opts, :login_receipt)

    with :ok <- provider_permitted(ctx, Keyword.get(opts, :restore)),
         {:ok, epoch} <- identity_epoch(ctx.user_id),
         :ok <- verified_epoch(Keyword.fetch(opts, :key_epoch), epoch),
         :ok <- receipt_epoch(receipt, epoch),
         {:ok, expectation} <- Sanctum.Issuance.expectation(ctx, opts) do
      token = if receipt, do: receipt.token, else: generate_token()

      minting = %{
        token_hash: hash_token(token),
        token_prefix: String.slice(token, 0, 8),
        also: record_receipt(receipt)
      }

      minting = Map.put(minting, :client_id, Keyword.get(opts, :client_id))

      with {:ok, session} <- insert(ctx, expectation, epoch, minting),
           do: {:ok, Map.put(session, :token, token)}
    end
  end

  @doc """
  Activate the session a protected device's unlock ticket was redeemed for
  (`Sanctum.DeviceUnlock.redeem/1`): the explicit entry from a device's
  standing to a person's session, never a relaxation of `create/2`.
  `held` is what the ticket held: the session id the unlock reserved as a
  row no token loads, the client, the person, athanor and email, the
  issuance expectation the device channel's context read and that
  context's credential deadline, its certificate's expiry. The row takes
  a new token, the provider `unlock`, and an expiry 60 seconds after the
  database's clock, never past the certificate: `session_ttl_hours` plays
  no part, so zero never lifts the bound. It is activated in the issuance
  transaction the expectation names, which locks and rereads the person,
  athanor, client and certificate, then the reserved row
  (`Arca.SessionStorage.activate_client_session/3`): a row a lock retired
  is `{:error, :reservation_retired}`. Answers `%{token, expires_at}`, or
  the refusals `create/2` answers.
  """
  @spec create_unlocked(map()) ::
          {:ok, %{token: String.t(), expires_at: DateTime.t()}} | {:error, term()}
  def create_unlocked(
        %{session_id: "ses_" <> _ = session_id, client_id: client_id, expectation: expectation} =
          held
      )
      when is_binary(client_id) do
    token = generate_token()

    with {:ok, now} <- db_now() do
      expires_at =
        Enum.min(
          [DateTime.add(now, Sanctum.DeviceUnlock.lifetime_ms(), :millisecond), held.deadline],
          DateTime
        )

      attrs = %{
        id: session_id,
        client_id: client_id,
        user_id: held.user_id,
        token_prefix: String.slice(token, 0, 8),
        identity_key_epoch: Map.get(expectation, :key_epoch),
        expires_at: expires_at
      }

      case Arca.SessionStorage.activate_client_session(hash_token(token), attrs,
             lock: Sanctum.Issuance.lock(expectation),
             verify: Sanctum.Issuance.verify(expectation)
           ) do
        :ok ->
          broadcast_session_created(%{})
          {:ok, %{token: token, expires_at: expires_at}}

        {:error, _reason} = refusal ->
          refusal
      end
    end
  end

  defp db_now do
    {:ok, Arca.ServerMetaStorage.now!()}
  rescue
    _unanswered -> {:error, :unavailable}
  end

  # The epoch the door verified the person's proof under, held to the one
  # the fresh read answers: a head that moved in between mints nothing.
  defp verified_epoch(:error, _epoch), do: :ok
  defp verified_epoch({:ok, epoch}, epoch), do: :ok
  defp verified_epoch({:ok, _another}, _epoch), do: {:error, :stale_key_epoch}

  # A remote person's head, read fresh from their directory outside any
  # transaction: its `key_epoch` is what the session records. A local
  # person's session records none.
  defp identity_epoch(user_id) when is_binary(user_id) do
    case Arca.PersonIdentities.get(Prima.Actor.system(), user_id) do
      {:ok, %{provenance: "remote", identifier: identifier}} when is_binary(identifier) ->
        case Sanctum.IdentityFreshness.fresh!(identifier) do
          {:ok, %{key_epoch: epoch}} -> {:ok, epoch}
          {:refused, :identity_stale} -> {:error, :identity_stale}
          {:error, :unavailable} -> {:error, :unavailable}
        end

      {:ok, %{provenance: "remote"}} ->
        {:error, :identity_key_epoch_required}

      {:ok, _local} ->
        {:ok, nil}

      # A person's identity row is minted with their person row: one
      # missing is damage. An id of another shape names no person here.
      {:error, :not_found} ->
        if Prima.PersonId.person?(user_id),
          do: {:error, {:corrupt, :person_identity}},
          else: {:ok, nil}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp identity_epoch(_user_id), do: {:ok, nil}

  defp receipt_epoch(nil, _epoch), do: :ok

  defp receipt_epoch(%{token: token, receipt: %{key_epoch: epoch}}, epoch) when is_binary(token),
    do: :ok

  defp receipt_epoch(%{token: token, receipt: %{}}, _epoch) when is_binary(token),
    do: {:error, :stale_key_epoch}

  defp receipt_epoch(_malformed, _epoch), do: {:error, :invalid_request}

  # The reserved `restore` provider stands only on the restore attempt that
  # minted the person, read again here: a context that merely names the
  # provider, or names another person's attempt, issues nothing.
  defp provider_permitted(%Context{provider: provider} = ctx, restore) do
    cond do
      not Sanctum.Auth.Identity.reserved_provider?(provider) ->
        :ok

      is_binary(restore) and restored?(restore, ctx.user_id) ->
        :ok

      true ->
        {:error, :reserved_provider}
    end
  end

  defp restored?(attempt_id, user_id) when is_binary(user_id) do
    case Arca.IdentityAttempts.get(Prima.Actor.system(), attempt_id) do
      {:ok, %{kind: "restore", user_id: ^user_id, phase: phase}} ->
        phase in ["minted", "completed"]

      _other ->
        false
    end
  end

  defp restored?(_attempt_id, _user_id), do: false

  # The `cyfr` door's receipt, recorded in the session's own transaction
  # for the person the session is minted for.
  defp record_receipt(nil), do: fn _session -> :ok end

  defp record_receipt(%{receipt: attrs}) do
    fn %{user_id: user_id} ->
      case Arca.CarryActions.record_receipt(
             Prima.Actor.system(),
             Map.put(attrs, :user_id, user_id)
           ) do
        {:ok, _receipt} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # What a session is minted under: its token's hash and first
  # characters, and the step run after the insert in its transaction.
  defp insert(%Context{} = ctx, expectation, epoch, minting) do
    with {:ok, hours} <- session_ttl_hours() do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      insert(ctx, expectation, now, expires_at(hours, now), epoch, minting)
    end
  end

  defp insert(%Context{} = ctx, expectation, now, expires_at, epoch, minting) do
    # A session carries no permission list: it is a person's, and what
    # they may do is decided by their own athanor, its consents
    # and the policy on every request — never by a bag frozen at sign-in.
    attrs = %{
      token_prefix: minting.token_prefix,
      user_id: ctx.user_id,
      email: ctx.email,
      provider: ctx.provider,
      # A resolved context carries its athanor; a nil marks a not-yet-resolved
      # session (user with no athanor) and is re-resolved on load. No
      # scope is persisted: every session works inside its athanor, and the
      # platform-admin capability is re-read from the person's row on load.
      athanor_id: ctx.athanor_id,
      identity_key_epoch: epoch,
      # A passkey sign-in's session names the credential's platform holder,
      # so the passkey's revocation ends it; it keeps the ordinary idle
      # expiry, since no device of this home's observes its lock.
      client_id: Map.get(minting, :client_id),
      expires_at: expires_at,
      inserted_at: now
    }

    case Arca.SessionStorage.create_session(minting.token_hash, attrs,
           lock: Sanctum.Issuance.lock(expectation),
           verify: Sanctum.Issuance.verify(expectation),
           also: minting.also
         ) do
      :ok ->
        session = %{
          user_id: ctx.user_id,
          email: ctx.email,
          provider: ctx.provider,
          created_at: DateTime.to_iso8601(now),
          expires_at: DateTime.to_iso8601(expires_at)
        }

        broadcast_session_created(session)
        {:ok, session}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Load a Context from a session token.

  Returns a Context with the persistent identity fields populated and
  ephemeral fields (request_id, etc.) nil. Returns `{:error, :invalid_session}`
  if the token is unknown or expired.

  The context is the console's interactive class (`auth_method: :oidc`),
  the one a person's session carries on every surface.

  ## Examples

      {:ok, ctx} = Sanctum.Session.load("abc123...")
      ctx.user_id
      #=> "123"

  """
  @spec load(String.t()) ::
          {:ok, Context.t()}
          | {:error, :invalid_session | :database_error | :namespace_unavailable}
  def load(token) when is_binary(token), do: load_by_hash(hash_token(token))

  @doc """
  `load/1`, also saying whether the session is due its sliding refresh
  (about a day, or half the TTL, since it was last extended), read off
  the row the load already read — so the caller starts a refresh only
  when one would write.
  """
  @spec load_sliding(String.t()) ::
          {:ok, Context.t(), boolean()}
          | {:error, :invalid_session | :database_error | :namespace_unavailable}
  def load_sliding(token) when is_binary(token) do
    token_hash = hash_token(token)

    with {:ok, row} <- stored(token_hash),
         {:ok, ctx} <- row_to_context(row, token_hash) do
      {:ok, ctx, row.slides and slide_due?(row.expires_at)}
    end
  end

  @doc """
  Load a Context from a session's row key (`token_hash/1`) rather than its
  token: what `Sanctum.Caller.revalidate_session/1` rebuilds a retained
  context from, since a holder keeps the hash and never the token. The
  same assembly as `load/1`, with the same results.
  """
  @spec load_by_hash(binary()) ::
          {:ok, Context.t()}
          | {:error, :invalid_session | :database_error | :namespace_unavailable}
  def load_by_hash(token_hash) when is_binary(token_hash) do
    with {:ok, row} <- stored(token_hash), do: row_to_context(row, token_hash)
  end

  # A session that names a client stands on it too, read again at every
  # load: the client still active. Its revocation, its certificate's and
  # every other retirement end the session's row in their own transition
  # (`Arca.DeviceCertificates`, `Arca.PairedClients`, `Arca.Passkeys`); a
  # load reads that row and recomputes no retirement. Whether the session
  # slides with use (`slides`) follows the client's verified source, never
  # what it reports of its holder: a passkey sign-in's slides as any
  # session does, and a protected device's only on its channel.
  defp stored(token_hash) do
    case Arca.SessionStorage.get_session(token_hash) do
      {:ok, %{client_id: nil} = row} -> {:ok, Map.put(row, :slides, true)}
      {:ok, row} -> client_stands(row)
      {:error, :not_found} -> {:error, :invalid_session}
      {:error, :database_error} -> {:error, :database_error}
    end
  end

  defp client_stands(%{client_id: client_id, user_id: user_id} = row) do
    case Arca.PairedClients.list(Prima.Actor.system(), user_id: user_id, standing: :active) do
      {:ok, clients} ->
        case Enum.find(clients, &(&1.id == client_id)) do
          %{source_kind: source} -> {:ok, Map.put(row, :slides, source == "passkey")}
          nil -> {:error, :invalid_session}
        end

      {:error, _unanswered} ->
        {:error, :database_error}
    end
  end

  defp client_stands(_row), do: {:error, :invalid_session}

  @doc """
  Get session details from token.

  Returns the full session map if valid and not expired.
  """
  @spec get(String.t()) :: {:ok, session()} | {:error, :invalid_session | :database_error}
  def get(token) when is_binary(token) do
    case get_session_direct(token) do
      {:ok, row} ->
        {:ok, row_to_external(row, token)}

      {:error, :not_found} ->
        {:error, :invalid_session}

      {:error, :database_error} ->
        {:error, :database_error}
    end
  end

  @doc """
  When the session whose row key is `token_hash` (`token_hash/1`, a
  context's `session_token_hash`) ends unless activity extends it: its
  row's `expires_at`. `{:error, :invalid_session}` when no living session
  has that key, `{:error, :database_error}` when the store cannot say.
  """
  @spec expires_at_by_hash(binary()) ::
          {:ok, DateTime.t()} | {:error, :invalid_session | :database_error}
  def expires_at_by_hash(token_hash) when is_binary(token_hash) do
    case Arca.SessionStorage.get_session(token_hash) do
      {:ok, row} -> {:ok, row.expires_at}
      {:error, :not_found} -> {:error, :invalid_session}
      {:error, :database_error} -> {:error, :database_error}
    end
  end

  @doc """
  Refresh a session, extending its expiration time.

  ## Examples

      {:ok, session} = Sanctum.Session.refresh("abc123...")
      # Expires `session_ttl_hours` (30 days by default) from the refresh

  """
  @spec refresh(String.t()) ::
          {:ok, session()} | {:error, :invalid_session | :database_error | :unavailable}
  def refresh(token) when is_binary(token) do
    token_hash = hash_token(token)

    with {:ok, _row} <- get_session_direct(token),
         {:ok, hours} <- session_ttl_hours() do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      case Arca.SessionStorage.refresh_session(token_hash, expires_at(hours, now)) do
        :ok ->
          case get_session_direct(token) do
            {:ok, row} -> {:ok, row_to_external(row, token)}
            {:error, :not_found} -> {:error, :invalid_session}
            {:error, :database_error} -> {:error, :database_error}
          end

        {:error, :not_found} ->
          {:error, :invalid_session}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :not_found} -> {:error, :invalid_session}
      {:error, :database_error} -> {:error, :database_error}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @doc """
  Extend a session's expiration, but only if it hasn't been extended recently.
  Never a protected device's session, which only its device channel moves
  (`Sanctum.DeviceUnlock.slide/2`); `refresh/1` does not find one either.
  A passkey sign-in's slides as any session does: its client is the
  credential's platform holder, decided by the client's source.

  This is the activity-based ("sliding window") refresh used on the hot path —
  calling `refresh/1` on every authenticated request would write the session
  row each time, so this no-ops unless more than ~1 day (or half the TTL,
  whichever is smaller) has elapsed since the last extension. Always returns `:ok`
  (best-effort — load/write failures are swallowed). No-op for infinite (TTL 0)
  sessions.
  """
  @spec refresh_if_stale(String.t()) :: :ok
  def refresh_if_stale(token) when is_binary(token) do
    with {:ok, %{slides: true} = row} <- stored(hash_token(token)),
         true <- slide_due?(row.expires_at),
         {:ok, _session} <- refresh(token) do
      :ok
    else
      _ -> :ok
    end
  end

  # Whether a session expiring at `expires_at` is due its sliding refresh:
  # more than ~1 day (or half the TTL, whichever is smaller) has passed
  # since it was last extended. Never for infinite (TTL 0) sessions, nor
  # while the idle timeout cannot be read.
  defp slide_due?(%DateTime{} = expires_at) do
    case session_ttl_hours() do
      {:ok, 0} ->
        false

      {:error, :unavailable} ->
        false

      {:ok, ttl_hours} ->
        ttl_seconds = ttl_hours * 3600
        stale_after = ttl_seconds - min(86_400, div(ttl_seconds, 2))
        DateTime.diff(expires_at, DateTime.utc_now()) < stale_after
    end
  end

  @doc """
  Drop the established-context memo for every session the user holds,
  without revoking any of them.

  For mutations that narrow what a LIVE session may reach — an athanor
  archived, not a door action: the next request re-derives
  through `Sanctum.Tenancy.revalidate/1` instead of serving the cached
  athanor for the memo TTL. The door's revocations go through
  `revoke_all_for_user/1`, which drops the memo as a side effect of
  deleting the rows.
  """
  @spec invalidate_memo_for_user(String.t()) :: :ok
  def invalidate_memo_for_user(user_id) when is_binary(user_id) do
    user_id
    |> Arca.SessionStorage.hashes_by_user()
    |> Enum.each(&Sanctum.Caller.invalidate_hash/1)
  end

  @doc """
  Revoke every session of a person (server-denied, or removed as an
  operator). Announces the revocation (`Sanctum.Telemetry.sessions_revoked/1`)
  so mounted LiveViews let go.
  """
  @spec revoke_all_for_user(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_for_user(user_id) when is_binary(user_id) do
    # The memo is keyed by token hash, so a user-wide revocation collects
    # the hashes first, deletes the rows, then drops each memo — a session
    # racing in between misses the row and cannot re-cache.
    hashes = Arca.SessionStorage.hashes_by_user(user_id)

    with {:ok, count} <- Arca.SessionStorage.delete_by_user(user_id) do
      Enum.each(hashes, &Sanctum.Caller.invalidate_hash/1)
      broadcast_sessions_revoked(user_id)
      {:ok, count}
    end
  end

  @doc """
  Announce sessions a committed transaction already removed: drop the
  established-context memo of each token hash that transaction's DELETE
  returned, then announce the revocation as `revoke_all_for_user/1`
  does. Called only after the commit, so a
  context re-established in between finds no row to cache.
  """
  @spec announce_revoked(String.t(), [binary()]) :: :ok
  def announce_revoked(user_id, hashes) when is_binary(user_id) and is_list(hashes) do
    Enum.each(hashes, &Sanctum.Caller.invalidate_hash/1)
    broadcast_sessions_revoked(user_id)
    :ok
  end

  @doc """
  Destroy a session (logout).

  ## Examples

      :ok = Sanctum.Session.destroy("abc123...")

  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(token) when is_binary(token) do
    destroy_by_hash(hash_token(token))
  end

  @doc """
  Clean up expired sessions.

  Returns `{:ok, count}`, the number of rows removed, or
  `{:error, :database_error}` when the store cannot answer.
  """
  @spec cleanup() :: {:ok, non_neg_integer()} | {:error, :database_error}
  def cleanup do
    Arca.SessionStorage.cleanup_expired_sessions()
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp get_session_direct(token) do
    Arca.SessionStorage.get_session(hash_token(token))
  end

  defp generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The row key for a session token: its SHA-256.

  Handed to a context so a caller can retire its own session without the
  token travelling any further than the plug that read it.
  """
  @spec token_hash(String.t()) :: binary()
  def token_hash(token) when is_binary(token), do: hash_token(token)

  @doc """
  Destroy a session addressed by its row key rather than its token.
  """
  @spec destroy_by_hash(binary()) :: :ok | {:error, term()}
  def destroy_by_hash(hash) when is_binary(hash) do
    with :ok <- Arca.SessionStorage.delete_session(hash) do
      # After the row delete, so an establish racing the logout cannot
      # re-cache a context the delete is about to orphan.
      Sanctum.Caller.invalidate_hash(hash)
    end
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  # One return shape — {:ok, ctx} | {:error, :namespace_unavailable} — so
  # the caller stops discriminating structurally on struct-vs-tuple.
  #
  # The one assembly of a session's context: the row key
  # (`session_token_hash`) and the binding that names it are stamped here
  # together and nowhere else.
  defp row_to_context(row, token_hash) do
    # A namespace is a publishing credential, not identity: a person
    # without one is as signed in as anyone, with `namespace: nil`.
    case namespace_of(row.user_id) do
      {:ok, ns} ->
        ctx =
          Context.build(
            user_id: row.user_id,
            email: row.email,
            provider: row.provider,
            namespace: ns,
            # A person holds every declared permission; the gates that
            # matter are their own athanor, consent and policy, applied on
            # every request.
            permissions: Context.person_permissions(),
            # The persisted athanor is a STARTING POINT, never trusted on its
            # own: revalidate/1 re-checks it against the person's own athanor.
            # A nil means the session was never resolved (no athanor at create
            # time); revalidation reads it again and the tenant gate still
            # bounces a genuinely athanor-less user.
            athanor_id: row.athanor_id,
            scope: :athanor,
            auth_method: :oidc,
            session_token_hash: token_hash,
            # A protected device's session ends at its row's expiry unless
            # the device's channel slides it: a holder of this context, a
            # mounted page or an open stream, is bounded by it.
            credential_deadline: if(row.slides, do: nil, else: row.expires_at),
            authenticated: true
          )

        # Re-validated against the person's CURRENT standing, so a denial,
        # a cleared mark or an archived athanor takes effect at once;
        # a store that cannot say is a 503, never yesterday's answer.
        with {:ok, revalidated} <- revalidated(ctx) do
          bound(revalidated, token_hash)
        end

      {:error, _reason} ->
        # The users row could not be read — distinct from "no namespace".
        # Surface a retryable error so the caller returns 503 rather than
        # signing a valid person in as someone with no publisher namespace.
        {:error, :namespace_unavailable}
    end
  end

  defp revalidated(ctx) do
    case Sanctum.Tenancy.revalidate(ctx) do
      {:ok, revalidated} -> {:ok, revalidated}
      {:error, :unavailable} -> {:error, :database_error}
    end
  end

  # The generations this context read, from a second read of the rows
  # after revalidation chose the athanor: a read that raced a transition
  # names the older generation, and the locked check at issuance refuses
  # it. A person with no row, and a context the door no longer admits,
  # carry no binding and can issue nothing.
  defp bound(%Context{authenticated: false} = ctx, _token_hash), do: {:ok, ctx}

  defp bound(%Context{} = ctx, token_hash) do
    with {:ok, snapshot} <- snapshot_of(ctx) do
      binding =
        snapshot &&
          %{
            source_kind: :session,
            source_id: Base.url_encode64(token_hash, padding: false),
            user_generation: snapshot.user_generation,
            athanor_generation: snapshot.athanor_generation
          }

      {:ok, %{ctx | credential_binding: binding}}
    end
  end

  defp snapshot_of(%Context{} = ctx) do
    case Sanctum.Tenancy.generation_snapshot(ctx.user_id, ctx.athanor_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :not_found} -> {:ok, nil}
      {:error, :unavailable} -> {:error, :database_error}
    end
  end

  defp namespace_of(user_id) do
    case Sanctum.Namespace.lookup_status(user_id) do
      {:ok, ns} -> {:ok, ns}
      :not_claimed -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  defp row_to_external(row, token) do
    %{
      token: token,
      user_id: row.user_id,
      email: row.email,
      provider: row.provider,
      created_at: Prima.Time.iso8601(row.inserted_at),
      expires_at: Prima.Time.iso8601(row.expires_at)
    }
  end

  # Subscribers hear that a session was created. No token travels: a
  # subscriber holds only the session of its own request. Sanctum
  # announces; the host's bridge is what broadcasts.
  defp broadcast_session_created(_session), do: Sanctum.Telemetry.session_created()

  defp broadcast_sessions_revoked(user_id), do: Sanctum.Telemetry.sessions_revoked(user_id)
end
