# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IdentityFreshness do
  @moduledoc """
  How fresh an identity's head is at this home (`ARCHITECTURE.md` §9.1).

  ## Freshness

  A remote person's head is cached here (`Arca.DirectoryHeads`), verified
  from their genesis, with the instant it was verified on the database's
  clock. `fresh?/2` answers the cached head while it is within
  `identity_freshness_seconds` of that clock, and past the bound reads the
  person's directory again through `Sanctum.Directory.Client`. The
  directory is the one the cached genesis names; with nothing cached it
  pauses, and only a live read (`fresh!/2`) takes the `:genesis` the
  caller passes. Freshness never comes from the person's own home, which may be
  the stolen one. The bound limits how long an honest directory's answer
  is reused here; it limits nothing a dishonest directory does, since an
  old head it keeps serving still verifies as current.

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
  own transaction, every session, identity-subject certificate and pending
  confirmation bound to the old one, and one that changes the
  `recovery_epoch` every passkey registered and door linked here under the
  old one (`Arca.DirectoryHeads`); the head is published only with that
  retirement committed. The retired sessions' memos are then dropped on
  every member (`Sanctum.Caller.drop_retired/2`).

  A local identity is never refreshed for its freshness: local work, local
  passkeys and local pairing use the stored identity.

  """

  require Logger

  alias Arca.Cache.Keys
  alias Prima.Identity.Encoding
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

  # ---- freshness ---------------------------------------------------------------

  @doc """
  `identifier`'s head, fresh within `identity_freshness_seconds`: the
  cached head while it is within the bound, else the head read again from
  the directory its genesis names (the module doc).

  Answers `{:ok, head}`, `{:refused, :identity_stale}` past the bound when
  the directory cannot refresh it, or `{:error, :unavailable}` when the
  store or the setting cannot answer. With nothing cached it pauses.
  `opts` takes only the directory client's `:resolver` and `:cacerts`.
  """
  @spec fresh?(String.t(), resolver: module(), cacerts: [binary()]) ::
          {:ok, head()} | {:refused, :identity_stale} | {:error, :unavailable}
  def fresh?(identifier, opts \\ []) when is_binary(identifier) do
    client_opts = client_options!(opts)

    with {:ok, bound} <- bound() do
      case Arca.DirectoryHeads.fresh(system(), identifier, bound) do
        {:ok, %{head: head, fresh: true}} ->
          {:ok, head}

        {:ok, %{head: head}} ->
          past_bound(identifier, {head.genesis, head.directory_url}, bound, client_opts)

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

  # A freshness check takes no locator: what is cached names the directory.
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

  # A reason's name for a log line: never a remote party's words.
  defp word(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp word({:refused, kind, _reason}) when is_atom(kind), do: "refused " <> Atom.to_string(kind)
  defp word(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: word(elem(reason, 0))
  defp word(_reason), do: "unexpected"

  defp system, do: Prima.Actor.system()
end
