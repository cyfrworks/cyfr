# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IdentityFreshness do
  @moduledoc """
  How fresh an identity's head is at this home, and the rotation of a
  local person's live key (`ARCHITECTURE.md` §9.1).

  ## Freshness

  A remote person's head is cached here (`Arca.DirectoryHeads`), verified
  from their genesis, with the instant it was verified on the database's
  clock. `fresh?/2` answers the cached head while it is within
  `identity_freshness_seconds` of that clock, and past the bound reads the
  person's directory again through `Sanctum.Directory.Client`. The
  directory is the one the genesis names: the cached genesis when there
  is one, and only when nothing is cached the `:genesis` the caller
  passes. Freshness never comes from the person's own home, which may be
  the stolen one.

  Past the bound with the directory unreachable, or serving a log that
  does not contain the head this home verified, the answer is
  `{:refused, :identity_stale}`: that person's protected work here pauses,
  distinguishably from a denial and from an absent person, and the bound
  is named in the log line and the telemetry
  (`Sanctum.Telemetry.identity_stale/3`). The 300-second default is a
  revocation guarantee and is not lengthened to hide an outage. A store
  that cannot answer is `{:error, :unavailable}`, never a verdict.

  Inside a transaction `fresh?/2` answers from the cached head alone and
  writes nothing: within the bound it answers the head, and past it the
  work pauses as `identity_stale` without reading the directory, since
  the transaction holds locks the read would wait on the network under.
  A request revalidates outside a transaction before it enters one, and
  the refresh happens there. `fresh!/2` always reads the directory, so its
  callers call it outside any transaction.

  A directory found unreachable, or timed out, is not read again for that
  identifier for 15 seconds on this member (`Arca.Cache.Keys.identity_unreachable/1`):
  within that window `fresh?/2` pauses the work at once, so an outage is
  not met with a directory request on every request it pauses. A read that
  succeeds ends the window.

  `fresh!/2` reads the directory whatever the cache and the window say:
  for enrollment, remote sign-in and a remote person's fresh confirmation,
  which need a live read.

  A refreshed head that changes the `key_epoch` retires, in the cache's
  own transaction, every session, passkey, identity-subject certificate
  and pending confirmation bound to the old one (`Arca.DirectoryHeads`),
  and the head is published only with that retirement committed. The
  retired sessions' memos are then dropped on every member
  (`Sanctum.Caller.drop_retired/2`).

  A local identity is never refreshed for its freshness: local work, local
  passkeys and local pairing use the stored identity. Only a rotation,
  below, reads a local person's own directory.

  ## Rotating the live key

  `rotate_live/3` rotates an enrolled local person's live key through one
  immutable attempt (`Arca.IdentityAttempts`), each phase durable before
  the next:

    1. the `key_rotation` confirmation is asked (`Sanctum.Consent.Authz.check/3`);
    2. the directory's head is read and cached, and must be the head the
       person's row names (`:stale_head` otherwise, with nothing opened);
    3. a new live key is staged and the rotate entry signed
       (`Sanctum.Person.sign_rotate/2`), and the attempt opens with the
       confirmation consumed in its transaction;
    4. the entry is submitted to the directory the genesis names
       (`Arca.IdentityAttempts.genesis/2`), never this home's enrollment
       setting;
    5. on acceptance the head is read again: the cache advances to the new
       head, retiring what was bound to the old `key_epoch`, and only then,
       while the new head is still this entry, is the staged key
       activated. A certificate issued between the two is refused, since
       its `key_epoch` is no longer the cached head's.

  A retry under the same request id resumes the attempt from the phase it
  reached: no second key is generated and nothing rotates twice. A lost
  reply is reconciled from the directory: an entry still at the head is
  answered accepted on its exact retry. A log that moved past the head the
  entry extended ends the attempt `refused` (`:stale_head`), and a log
  that moved past the accepted entry before activation ends it
  `superseded`; neither activates the staged key, and a new rotation
  needs a new confirmation. The operational key is unchanged.
  """

  require Logger

  alias Arca.Cache.Keys
  alias Prima.Identity.Encoding
  alias Sanctum.Consent.Authz
  alias Sanctum.Context
  alias Sanctum.Directory.Client

  # How long this member leaves an identity's directory unread after
  # finding it unreachable or timed out.
  @unreachable_ms 15_000

  @typedoc """
  A cached head (`Arca.DirectoryHeads`), as a plain map: its
  `identifier`, `head_hash`, `key_epoch`, `verified_at`, `genesis`,
  `directory_url` and the verified `state` as JSON text.
  """
  @type head :: map()

  @typedoc """
  `:genesis`, the locator used only when nothing is cached, and the
  directory client's `:resolver` and `:cacerts`.
  """
  @type opts :: [genesis: Client.genesis(), resolver: module(), cacerts: [binary()]]

  @typedoc "A completed rotation: its request id, its phase and the new `key_epoch`."
  @type rotation :: %{request_id: String.t(), phase: String.t(), key_epoch: String.t()}

  @typedoc "Why a rotation did not complete (the module doc)."
  @type rotation_refusal ::
          :invalid_request
          | :not_found
          | :not_enrolled
          | :stale_head
          | :superseded
          | :rotation_refused
          | {:attempt_in_progress, String.t() | nil}
          | :request_id_reused
          | :directory_unavailable
          | {:rate_limited, pos_integer()}
          | :unavailable
          | {:confirmation_required, map()}
          | Authz.refusal()

  @rotation_phases ~w(staged submitted accepted keys_active completed refused superseded)

  # ---- freshness ---------------------------------------------------------------

  @doc """
  `identifier`'s head, fresh within `identity_freshness_seconds`: the
  cached head while it is within the bound, else the head read again from
  the directory its genesis names (the module doc).

  Answers `{:ok, head}`, `{:refused, :identity_stale}` past the bound when
  the directory cannot refresh it, or `{:error, :unavailable}` when the
  store or the setting cannot answer.
  """
  @spec fresh?(String.t(), opts()) ::
          {:ok, head()} | {:refused, :identity_stale} | {:error, :unavailable}
  def fresh?(identifier, opts \\ []) when is_binary(identifier) do
    {genesis, client_opts} = options!(opts)

    with {:ok, bound} <- bound() do
      case Arca.DirectoryHeads.fresh(system(), identifier, bound) do
        {:ok, %{head: head, fresh: true}} ->
          {:ok, head}

        {:ok, %{head: head}} ->
          past_bound(identifier, {head.genesis, head.directory_url}, bound, client_opts)

        {:error, :not_found} when not is_nil(genesis) ->
          past_bound(identifier, {genesis, directory_of(genesis)}, bound, client_opts)

        {:error, :not_found} ->
          stale(identifier, nil, bound, :past_bound, :not_cached)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  # Past the bound the directory is read again, unless this member found it
  # unreachable within the last `@unreachable_ms`: then the work pauses at
  # once, so an outage is not met with a directory request, and its
  # timeout, on every request it pauses. Inside a caller's transaction the
  # directory is never read and the cache never written: the transaction
  # holds the person's row lock (on SQLite, the one write lock) while a
  # read would wait on the network, and a head published there would be
  # announced before the caller's commit. The work pauses instead; the
  # request revalidates outside a transaction before it enters one, and
  # the refresh happens there.
  defp past_bound(identifier, {_genesis, directory} = locator, bound, client_opts) do
    cond do
      Arca.in_transaction?() ->
        stale(identifier, directory, bound, :past_bound, :in_transaction)

      match?({:ok, _unreachable}, Arca.Cache.get(Keys.identity_unreachable(identifier))) ->
        stale(identifier, directory, bound, :past_bound, :recently_unreachable)

      true ->
        refresh(identifier, locator, bound, client_opts, :past_bound)
    end
  end

  @doc """
  `identifier`'s head read from its directory now, whatever the cache
  says: for the paths that need a live read. The locator is the cached
  genesis, or `:genesis` when nothing is cached. Answers as `fresh?/2`
  does; a directory that cannot answer refuses, however recently the
  cache was verified.
  """
  @spec fresh!(String.t(), opts()) ::
          {:ok, head()} | {:refused, :identity_stale} | {:error, :unavailable}
  def fresh!(identifier, opts \\ []) when is_binary(identifier) do
    {genesis, client_opts} = options!(opts)

    with {:ok, bound} <- bound() do
      case Arca.DirectoryHeads.get(system(), identifier) do
        {:ok, head} ->
          refresh(identifier, {head.genesis, head.directory_url}, bound, client_opts, :live)

        {:error, :not_found} when not is_nil(genesis) ->
          refresh(identifier, {genesis, directory_of(genesis)}, bound, client_opts, :live)

        {:error, :not_found} ->
          stale(identifier, nil, bound, :live, :not_cached)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  # ---- rotation ------------------------------------------------------------------

  @doc """
  Rotate the live key of the person of `ctx`, an enrolled local person,
  under the request id `request_id` (the module doc). `opts` takes only the
  directory client's `:resolver` and `:cacerts`.

  Answers `{:ok, %{request_id, phase: "completed", key_epoch}}`, the new
  `key_epoch` being the rotate entry's hash, or a refusal:
  `{:confirmation_required, _}` and the confirmation's other refusals
  (`Sanctum.Consent.Authz`); `:invalid_request` (a malformed request id);
  `:not_found` (no local key set: the person's keys are at another home);
  `:not_enrolled`; `:stale_head` (the log moved past the person's head);
  `:superseded` (a recovery or another rotation replaced the accepted
  entry before it was activated); `:rotation_refused` (the directory
  refused the entry); `{:attempt_in_progress, request_id}` (another
  rotation of the person stands); `:request_id_reused` (the id names
  another request); and the retryable `:directory_unavailable`,
  `{:rate_limited, seconds}` and `:unavailable`, after which a retry under
  the same request id resumes the same attempt.
  """
  @spec rotate_live(Context.t(), String.t(), resolver: module(), cacerts: [binary()]) ::
          {:ok, rotation()} | {:error, rotation_refusal()}
  def rotate_live(%Context{user_id: user_id} = ctx, request_id, opts \\ [])
      when is_binary(request_id) and is_list(opts) do
    client_opts = client_options!(opts)

    with :ok <- request_id_valid(request_id),
         {:ok, identity} <- own_identity(ctx) do
      case Arca.IdentityAttempts.get_by_request(Context.actor(ctx), request_id) do
        {:ok, %{kind: "rotation", user_id: ^user_id} = attempt} ->
          with {:ok, binding} <- binding(ctx, identity),
               do: continue(ctx, attempt, binding, client_opts)

        {:ok, _another} ->
          {:error, :request_id_reused}

        {:error, :cross_tenant} ->
          {:error, :request_id_reused}

        {:error, :not_found} ->
          begin(ctx, identity, request_id, client_opts)

        {:error, :database_error} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  What confirming a rotation approves (`t:Sanctum.Consent.Authz.change/0`),
  the change `rotate_live/3` decides: the operation, its request id and
  the identifier whose live key it replaces.
  """
  @spec rotation_change(String.t(), String.t()) :: Authz.change()
  def rotation_change(request_id, identifier) do
    %{
      operation: "person.rotate",
      arguments: %{"request_id" => request_id},
      resource: identifier,
      details: %{
        "effect" =>
          "Replaces the live key that signs for you. Every other home ends the sessions, " <>
            "devices and passkeys it bound to the old key once it sees the new one."
      }
    }
  end

  # ---- freshness internals ------------------------------------------------------

  # A refresh through the directory client. A head that changed its
  # `key_epoch` retired what was bound to the old one in the cache's own
  # transaction; its sessions' memos are dropped now that it committed.
  # Past the bound, a resolution that failed for want of the cache (another
  # resolution moved it meanwhile) answers the cache if it is now fresh.
  defp refresh(identifier, {genesis, directory}, bound, client_opts, why) do
    case Client.resolve(identifier, genesis, client_opts) do
      {:ok, %{head: head, retired: retired}} ->
        Arca.Cache.invalidate(Keys.identity_unreachable(identifier))
        drop_retired(identifier, retired)
        {:ok, head}

      {:error, reason} when reason in [:unreachable, :timeout] and why == :past_bound ->
        unreachable!(identifier)

        case Arca.DirectoryHeads.fresh(system(), identifier, bound) do
          {:ok, %{head: head, fresh: true}} -> {:ok, head}
          _still_stale -> stale(identifier, directory, bound, why, reason)
        end

      {:error, reason} when reason in [:unreachable, :timeout] ->
        unreachable!(identifier)
        stale(identifier, directory, bound, why, reason)

      {:error, :not_descendant} ->
        Sanctum.Telemetry.identity_not_descendant(identifier, directory || "")
        stale(identifier, directory, bound, why, :not_descendant)

      {:error, reason} when why == :past_bound ->
        case Arca.DirectoryHeads.fresh(system(), identifier, bound) do
          {:ok, %{head: head, fresh: true}} -> {:ok, head}
          _still_stale -> stale(identifier, directory, bound, why, reason)
        end

      {:error, reason} ->
        stale(identifier, directory, bound, why, reason)
    end
  end

  # The pause after a directory that could not be reached or timed out:
  # this member reads it again for this identifier only once the entry
  # lapses, or once another read of it succeeds.
  defp unreachable!(identifier),
    do: Arca.Cache.put(Keys.identity_unreachable(identifier), :unreachable, @unreachable_ms)

  defp stale(identifier, directory, bound, why, reason) do
    where = if directory, do: "its directory #{directory}", else: "no directory this home knows"

    sentence =
      case why do
        :past_bound -> "is past its #{bound}-second freshness bound"
        :live -> "needed a live read (its freshness bound is #{bound} seconds)"
      end

    # A pause answered from the unreachable entry or inside a transaction
    # read nothing new: the warning is the read's, logged once when the
    # directory was found unreachable.
    level = if reason in [:recently_unreachable, :in_transaction], do: :debug, else: :warning

    Logger.log(
      level,
      "[Sanctum.IdentityFreshness] #{identifier}'s head #{sentence}, and #{where} could " <>
        "not refresh it (#{word(reason)}): its protected work here pauses"
    )

    Sanctum.Telemetry.identity_stale(identifier, directory, bound)
    {:refused, :identity_stale}
  end

  defp drop_retired(_identifier, %{session_hashes: []}), do: :ok

  defp drop_retired(identifier, %{session_hashes: hashes}) do
    people =
      case Arca.PersonIdentities.lookup_identifier(system(), identifier) do
        {:ok, %{user_id: user_id}} -> [user_id]
        _none -> []
      end

    Sanctum.Caller.drop_retired(people, hashes)
  end

  # The setting refuses a stale value: a store that cannot answer it
  # confirms no head, as a certificate's validity is not read from a
  # window this member cannot read.
  defp bound do
    case Arca.PlatformSettings.effective("identity_freshness_seconds") do
      {:ok, seconds} when is_integer(seconds) and seconds > 0 ->
        {:ok, seconds}

      {:ok, _other} ->
        Logger.error(
          "[Sanctum.IdentityFreshness] the stored identity_freshness_seconds is not a " <>
            "positive whole number of seconds; refusing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.IdentityFreshness] identity_freshness_seconds cannot be read: " <>
                "the setting is #{reason}"
    end
  end

  # The directory a genesis names, for the log line and the telemetry
  # alone: the client holds the genesis to its identifier before any
  # request.
  defp directory_of(genesis) when is_binary(genesis) do
    case Prima.Json.decode(genesis) do
      {:ok, %{} = map} -> directory_of(map)
      _malformed -> nil
    end
  end

  defp directory_of(%{"directory" => directory}) when is_binary(directory) do
    if Encoding.directory_url?(directory), do: directory
  end

  defp directory_of(_genesis), do: nil

  defp options!(opts) when is_list(opts) do
    case Keyword.validate(opts, [:genesis, :resolver, :cacerts]) do
      {:ok, opts} -> Keyword.pop(opts, :genesis)
      {:error, unknown} -> raise ArgumentError, unknown_options(unknown)
    end
  end

  # A rotation's directory is its genesis's alone: no locator is taken.
  defp client_options!(opts) when is_list(opts) do
    case Keyword.validate(opts, [:resolver, :cacerts]) do
      {:ok, opts} -> opts
      {:error, unknown} -> raise ArgumentError, unknown_options(unknown)
    end
  end

  defp unknown_options(unknown) do
    "Sanctum.IdentityFreshness does not take " <>
      Enum.map_join(unknown, ", ", &Prima.LoggerContext.shape/1)
  end

  # ---- rotation internals --------------------------------------------------------

  defp request_id_valid(request_id) do
    if Encoding.id?(request_id), do: :ok, else: {:error, :invalid_request}
  end

  # The person's own identity row, read as the person: an enrolled local
  # identity, the only kind whose live key this home rotates.
  defp own_identity(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case Arca.PersonIdentities.get(Context.actor(ctx), user_id) do
      {:ok,
       %{provenance: "local", enrollment: "enrolled", identifier: identifier, head_hash: head} =
           row}
      when is_binary(identifier) and is_binary(head) ->
        {:ok, row}

      {:ok, %{provenance: "local"}} ->
        {:error, :not_enrolled}

      {:ok, %{provenance: "remote"}} ->
        {:error, :not_found}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  defp own_identity(%Context{}), do: {:error, :not_found}

  # The genesis the person's identity rests on, which alone names the
  # directory a rotation is submitted to.
  defp binding(ctx, identity) do
    case Arca.IdentityAttempts.genesis(Context.actor(ctx), ctx.user_id) do
      {:ok, %{identifier: identifier} = binding} when identifier == identity.identifier ->
        {:ok, binding}

      {:ok, _another} ->
        Logger.error(
          "[Sanctum.IdentityFreshness] the genesis on record for #{ctx.user_id} names " <>
            "another identifier than their identity row; refusing to rotate"
        )

        {:error, :unavailable}

      {:error, :not_found} ->
        Logger.error(
          "[Sanctum.IdentityFreshness] #{ctx.user_id} is enrolled but no genesis is on " <>
            "record; refusing to rotate"
        )

        {:error, :unavailable}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # A rotation already in progress is named first: the directory's head may
  # be its own accepted entry, which no new attempt may read as stale.
  defp begin(ctx, identity, request_id, client_opts) do
    change = rotation_change(request_id, identity.identifier)

    with :ok <- none_in_progress(ctx),
         :ok <- Authz.check(ctx, :key_rotation, change),
         {:ok, binding} <- binding(ctx, identity),
         :ok <- at_head(identity, binding, client_opts),
         {:ok, staged} <- staged(ctx.user_id, identity.head_hash) do
      open(ctx, identity, request_id, {staged, change}, binding, client_opts)
    end
  end

  # The directory's head, read and cached before anything is staged: it
  # must be the head the person's row names. The cache then holds the head
  # the rotation extends, so its advance past it retires what was bound
  # to that `key_epoch`.
  defp at_head(identity, binding, client_opts) do
    case Client.resolve(identity.identifier, binding.genesis, client_opts) do
      {:ok, %{state: %{head: head}, retired: retired}} ->
        drop_retired(identity.identifier, retired)

        if head == identity.head_hash do
          :ok
        else
          Logger.warning(
            "[Sanctum.IdentityFreshness] #{identity.identifier}'s directory names a head " <>
              "past the one this home holds; refusing to rotate from it"
          )

          {:error, :stale_head}
        end

      {:error, reason} ->
        retryable(identity.identifier, binding.directory_url, reason)
    end
  end

  defp staged(user_id, head) do
    case Sanctum.Person.sign_rotate(user_id, head) do
      {:ok, staged} ->
        {:ok, staged}

      {:error, reason} when reason in [:not_found, :not_enrolled, :unavailable] ->
        {:error, reason}

      {:error, _malformed} ->
        {:error, :unavailable}
    end
  end

  # The attempt opens with the confirmation consumed in its transaction:
  # either both commit or neither does.
  defp open(ctx, identity, request_id, {staged, change}, binding, client_opts) do
    attrs = %{
      kind: "rotation",
      request_id: request_id,
      user_id: ctx.user_id,
      entry: staged.entry,
      entry_hash: staged.entry_hash,
      expected_head: identity.head_hash,
      staged_live_public_key: staged.staged_live_public_key,
      staged_live_key_sealed: staged.staged_live_key_sealed
    }

    consume = fn _attempt -> Authz.consume(ctx, {:key_rotation, change}) end

    case Arca.IdentityAttempts.open(Context.actor(ctx), attrs, also: consume) do
      {:ok, attempt} ->
        # Announced once the consumption committed with the attempt.
        Authz.consumed(ctx)
        continue(ctx, attempt, binding, client_opts)

      # Another call under this request id opened it first: that attempt
      # is the one this id resumes, and the key staged here is dropped.
      {:error, :request_id_reused} ->
        case Arca.IdentityAttempts.get_by_request(Context.actor(ctx), request_id) do
          {:ok, %{kind: "rotation", user_id: user_id} = attempt} when user_id == ctx.user_id ->
            continue(ctx, attempt, binding, client_opts)

          _another ->
            {:error, :request_id_reused}
        end

      {:error, :attempt_in_progress} ->
        {:error, {:attempt_in_progress, in_progress(ctx)}}

      {:error, reason} when reason in [:database_error, :not_owner] ->
        {:error, :unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp in_progress(ctx) do
    case Arca.IdentityAttempts.in_progress(Context.actor(ctx), ctx.user_id, "rotation") do
      {:ok, %{request_id: request_id}} -> request_id
      _none -> nil
    end
  end

  defp none_in_progress(ctx) do
    case Arca.IdentityAttempts.in_progress(Context.actor(ctx), ctx.user_id, "rotation") do
      {:error, :not_found} -> :ok
      {:ok, %{request_id: request_id}} -> {:error, {:attempt_in_progress, request_id}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The attempt carried on from the phase it holds. A move another call
  # under the same request id made first is read back, and the attempt is
  # carried on from there; phases only move forward, so this ends.
  defp continue(ctx, attempt, binding, client_opts, rounds \\ 6) do
    case resume(ctx, attempt, binding, client_opts) do
      {:error, {:moved, moved}} when rounds > 0 ->
        continue(ctx, moved, binding, client_opts, rounds - 1)

      {:error, {:moved, _moved}} ->
        {:error, :unavailable}

      answer ->
        answer
    end
  end

  # Each phase goes on from where the attempt stands.
  defp resume(ctx, %{phase: "staged"} = attempt, binding, client_opts) do
    with {:ok, attempt} <- move(ctx, attempt, "submitted"),
         do: resume(ctx, attempt, binding, client_opts)
  end

  defp resume(ctx, %{phase: "submitted"} = attempt, binding, client_opts),
    do: submit(ctx, attempt, binding, client_opts)

  defp resume(ctx, %{phase: "accepted"} = attempt, binding, client_opts),
    do: settle(ctx, attempt, binding, client_opts)

  defp resume(ctx, %{phase: "keys_active"} = attempt, binding, client_opts) do
    with {:ok, attempt} <- move(ctx, attempt, "completed"),
         do: resume(ctx, attempt, binding, client_opts)
  end

  defp resume(_ctx, %{phase: "completed"} = attempt, _binding, _client_opts),
    do:
      {:ok, %{request_id: attempt.request_id, phase: "completed", key_epoch: attempt.entry_hash}}

  defp resume(_ctx, %{phase: "superseded"}, _binding, _client_opts), do: {:error, :superseded}

  defp resume(_ctx, %{phase: "refused", outcome: "stale_head"}, _binding, _client_opts),
    do: {:error, :stale_head}

  defp resume(_ctx, %{phase: "refused"}, _binding, _client_opts),
    do: {:error, :rotation_refused}

  # The entry, submitted to the directory its genesis names. Its exact
  # retry is answered accepted while it is still the head.
  defp submit(ctx, attempt, binding, client_opts) do
    identifier = binding.identifier

    case Client.append(identifier, binding.genesis, attempt.entry, client_opts) do
      {:ok, %{entry_hash: hash}} when hash == attempt.entry_hash ->
        with {:ok, attempt} <- move(ctx, attempt, "accepted", %{outcome: "accepted"}),
             do: settle(ctx, attempt, binding, client_opts)

      {:ok, _another} ->
        retryable(identifier, binding.directory_url, :invalid_response)

      {:error, {:stale_head, _head}} ->
        reconcile(ctx, attempt, binding, client_opts)

      {:error, reason} ->
        if refused?(reason) do
          Logger.warning(
            "[Sanctum.IdentityFreshness] #{identifier}'s directory refused a rotation " <>
              "(#{word(reason)}); nothing was rotated"
          )

          with {:ok, _ended} <- move(ctx, attempt, "refused", %{outcome: "refused"}),
               do: {:error, :rotation_refused}
        else
          retryable(identifier, binding.directory_url, reason)
        end
    end
  end

  # The directory answered that its head is not the one the entry extends:
  # the log is read again, which also moves this home's cache. An entry
  # that is the head now was accepted; any other log moved past the head
  # the entry extended, and the attempt ends without its key.
  defp reconcile(ctx, attempt, binding, client_opts) do
    case Client.resolve(binding.identifier, binding.genesis, client_opts) do
      {:ok, %{state: %{head: head}, retired: retired}} ->
        drop_retired(binding.identifier, retired)

        if head == attempt.entry_hash do
          with {:ok, attempt} <- move(ctx, attempt, "accepted", %{outcome: "accepted"}),
               do: activate(ctx, attempt)
        else
          with {:ok, _ended} <- move(ctx, attempt, "refused", %{outcome: "stale_head"}),
               do: {:error, :stale_head}
        end

      {:error, reason} ->
        retryable(binding.identifier, binding.directory_url, reason)
    end
  end

  # An accepted entry: the head is read again, so the cache advances past
  # the old `key_epoch` (retiring what was bound to it) before the staged
  # key is activated, and only while the entry is still the head.
  defp settle(ctx, attempt, binding, client_opts) do
    case Client.resolve(binding.identifier, binding.genesis, client_opts) do
      {:ok, %{state: %{head: head}, retired: retired}} ->
        drop_retired(binding.identifier, retired)

        if head == attempt.entry_hash,
          do: activate(ctx, attempt),
          else: supersede(ctx, attempt)

      {:error, reason} ->
        retryable(binding.identifier, binding.directory_url, reason)
    end
  end

  defp activate(ctx, attempt) do
    case move(ctx, attempt, "keys_active") do
      {:ok, active} ->
        with {:ok, done} <- move(ctx, active, "completed"),
             do: resume(ctx, done, nil, [])

      # The person's head moved here since the attempt opened.
      {:error, :stale_head} ->
        supersede(ctx, attempt)

      {:error, _reason} = refusal ->
        refusal
    end
  end

  defp supersede(ctx, attempt) do
    Logger.warning(
      "[Sanctum.IdentityFreshness] a later entry replaced the accepted rotation " <>
        "#{attempt.request_id} before its key was activated; nothing was rotated here"
    )

    with {:ok, _ended} <- move(ctx, attempt, "superseded", %{outcome: "superseded"}),
         do: {:error, :superseded}
  end

  # One phase move from the phase the attempt holds. A move another call
  # made first is read back as `{:moved, attempt}` (`continue/5`).
  defp move(ctx, attempt, to, attrs \\ %{}) do
    actor = Context.actor(ctx)

    case Arca.IdentityAttempts.advance(actor, attempt.id, attempt.phase, to, attrs) do
      {:ok, moved} ->
        {:ok, moved}

      {:error, :stale} ->
        case Arca.IdentityAttempts.get(actor, attempt.id) do
          {:ok, %{phase: phase} = moved} when phase in @rotation_phases ->
            {:error, {:moved, moved}}

          _unanswered ->
            {:error, :unavailable}
        end

      {:error, :stale_head} ->
        {:error, :stale_head}

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.IdentityFreshness] rotation #{attempt.request_id} could not move to " <>
            "#{to} (#{word(reason)})"
        )

        {:error, :unavailable}
    end
  end

  # The directory's own refusals of an entry; everything else may answer
  # differently later, and the attempt waits for its retry.
  defp refused?({:refused, _kind, _reason}), do: true
  defp refused?(reason) when reason in [:body_too_large, :conflict], do: true
  defp refused?(_reason), do: false

  defp retryable(identifier, directory, reason) do
    if reason == :not_descendant,
      do: Sanctum.Telemetry.identity_not_descendant(identifier, directory)

    Logger.warning(
      "[Sanctum.IdentityFreshness] #{identifier}'s directory could not answer a rotation " <>
        "(#{word(reason)}); a retry under the same request id resumes it"
    )

    case reason do
      {kind, seconds} when kind in [:rate_limited, :capacity, :busy] and is_integer(seconds) ->
        {:error, {:rate_limited, seconds}}

      _other ->
        {:error, :directory_unavailable}
    end
  end

  # A reason's name for a log line: never a remote party's words.
  defp word(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp word({:refused, kind, _reason}) when is_atom(kind), do: "refused " <> Atom.to_string(kind)
  defp word(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: word(elem(reason, 0))
  defp word(_reason), do: "unexpected"

  defp system, do: Prima.Actor.system()
end
