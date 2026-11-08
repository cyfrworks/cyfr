# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.IdentityFreshness do
  @moduledoc """
  How fresh an account's head is at this home (`ARCHITECTURE.md` §9.1).

  ## The cached head

  An account's head is cached here (`Arca.DirectoryHeads`) with the
  verified state it leaves (`Prima.Identity.State`: the listed keys and
  the recovery set), when each listed key was added (`added/2`) and the
  instant it was verified on the database's clock, so the next entries
  verify against it alone. `keys/1` answers the listed keys with when
  each was added and a passkey's maker, which the person's own surfaces
  show (`Sanctum.AccountKeys`). `fresh?/2` answers
  the cached head while it is within `identity_freshness_seconds` of that
  clock, and past the bound reads the directory the cached genesis names
  again. `fresh!/2` reads it whatever the cache says, for the paths that
  need a live read; with nothing cached it reads the whole log at the
  directory the caller names (`:directory`), verifies it from the genesis
  (`Prima.Identity.verify_chain/1`) and caches it. An identifier this home
  never read is never answered from anything else.

  ## Refresh and the walk

  A refresh reads the entries after the cached head
  (`Sanctum.Directory.Client.entries_after/5`) and verifies them as a
  chain from the cached state (`Prima.Identity.extend/2`), to the head and
  length the directory named. Then, in the cache's transaction, it walks
  them in order: each `remove_key` retires the sessions, certificates,
  pending confirmations and clients bound to that key, a `recover` every
  binding of the account and every session of its people, bound to a key
  or not, and `add_key` and `add_recovery` nothing; then
  the head advances (`Arca.DirectoryHeads.advance/5`). A key removed and
  added again between two refreshes is therefore retired and admitted
  afresh, never kept. The retired sessions' memos are dropped on every
  member once the walk committed (`Sanctum.Caller.drop_retired/2`).

  A log that does not hold the cached head (`/from/{hash}` answers
  `not_found`) is not the history this home verified: the cache is left as
  it was, the event is counted (`Sanctum.Telemetry.identity_not_descendant/2`)
  and the work pauses.

  ## Gone

  A directory answering `gone` is terminal: every binding of the account
  retires and the cached head is marked gone (`Arca.DirectoryHeads.gone/2`),
  and every later answer here is `{:refused, :identity_gone}`, distinct
  from an outage.

  ## An unreachable directory

  Past the bound with the directory not answering (unreachable, timed
  out, refused by the address policy, shedding, a 5xx or a 429), or inside
  a transaction, or within 15 seconds of finding it so on this member
  (`Arca.Cache.Keys.identity_unreachable/1`), the answer follows how this
  home is reached (`Sanctum.access_mode/0`):

    * `public`: `{:refused, :identity_stale}`: that person's protected
      work here pauses, distinguishably from a denial and from an absent
      person, and the bound is named in the log line and the telemetry
      (`Sanctum.Telemetry.identity_stale/3`). The 300-second default is a
      revocation guarantee and is not lengthened to hide an outage.
    * `local` and `tailnet`: the cached head, so the people this home
      holds keep working on the keys it last read; the next reachable
      moment refreshes it. A removed key keeps working here until then
      (`ARCHITECTURE.md` §1.3).

  An identifier never read refuses in every mode. A directory that
  answers but serves no log this home can verify (a redirect, a body too
  large or unreadable, its own store's corruption, any other status, a
  log that does not verify or does not hold the cached head) pauses the
  work in every mode: that is no outage. A store that cannot answer is `{:error,
  :unavailable}`, never a verdict.

  Inside a transaction nothing is read and nothing written: the
  transaction holds the person's lock (on SQLite, the one write lock),
  which the walk takes first, and a network read would wait under it. A
  request revalidates outside a transaction before it enters one, and the
  refresh happens there. `fresh!/2` always reads the directory, so its
  callers call it outside any transaction.
  """

  require Logger

  alias Arca.Cache.Keys
  alias Prima.Identity
  alias Prima.Identity.{Entry, State}
  alias Sanctum.Directory.Client

  # How long this member leaves an account's directory unread after
  # finding it unreachable or timed out.
  @unreachable_ms 15_000
  # A refresh that loses the cache to another refresh reads again, at most
  # this many times in all.
  @rounds 2

  @typedoc """
  A cached head (`Arca.DirectoryHeads`), as a plain map: its `identifier`,
  `head_hash`, `verified_at`, `genesis`, `directory_url`, `gone_at`, the
  verified `state` and its `keys_added`, each as JSON text.
  """
  @type head :: map()

  @typedoc """
  When each listed key was added, by its `kid`: the `at` of the entry
  that listed it last, and the `aaguid` its `add_key` named for a
  passkey's maker, or nil.
  """
  @type added :: %{optional(String.t()) => %{at: non_neg_integer(), aaguid: String.t() | nil}}

  @typedoc "A listed key with when it was added and its maker (`keys/1`)."
  @type listed :: %{
          key: Prima.Identity.Key.t(),
          added_at: non_neg_integer(),
          aaguid: String.t() | nil
        }

  @typedoc "Why freshness refuses: the work pauses, or the account is gone."
  @type refusal :: {:refused, :identity_stale | :identity_gone}

  @typedoc """
  `:directory`, the directory to read an identifier this home never read
  at, and the directory client's `:resolver` and `:cacerts`.
  """
  @type opts :: [directory: String.t(), resolver: module(), cacerts: [binary()]]

  # ---- freshness ---------------------------------------------------------------

  @doc """
  `identifier`'s head, fresh within `identity_freshness_seconds`: the
  cached head while it is within the bound, else the head read again from
  the directory its genesis names (the module doc).

  Answers `{:ok, head}`, `{:refused, :identity_stale}` when it pauses,
  `{:refused, :identity_gone}` for an account gone, or `{:error,
  :unavailable}` when the store or the setting cannot answer. `opts`
  takes only the directory client's `:resolver` and `:cacerts`.
  """
  @spec fresh?(String.t(), resolver: module(), cacerts: [binary()]) ::
          {:ok, head()} | refusal() | {:error, :unavailable}
  def fresh?(identifier, opts \\ []) when is_binary(identifier) do
    client_opts = client_options!(opts)

    with {:ok, bound} <- bound() do
      case Arca.DirectoryHeads.fresh(system(), identifier, bound) do
        {:ok, %{head: %{gone_at: %DateTime{}}}} -> {:refused, :identity_gone}
        {:ok, %{head: head, fresh: true}} -> {:ok, head}
        {:ok, %{head: head}} -> past_bound(head, bound, client_opts)
        {:error, :not_found} -> stale(identifier, nil, bound, :past_bound, :never_read)
        {:error, _unanswered} -> {:error, :unavailable}
      end
    end
  end

  @doc """
  `identifier`'s head read from its directory now, whatever the cache
  says: for the paths that need a live read. With nothing cached it is
  read at `opts[:directory]`. Answers as `fresh?/2` does, the access
  mode deciding for a directory that does not answer.
  """
  @spec fresh!(String.t(), opts()) :: {:ok, head()} | refusal() | {:error, :unavailable}
  def fresh!(identifier, opts \\ []) when is_binary(identifier) do
    {directory, client_opts} = options!(opts)

    with {:ok, bound} <- bound() do
      case Arca.DirectoryHeads.get(system(), identifier) do
        {:ok, %{gone_at: %DateTime{}}} ->
          {:refused, :identity_gone}

        {:ok, head} ->
          refresh(head, bound, client_opts, :live, @rounds)

        {:error, :not_found} when is_binary(directory) ->
          first_read(identifier, directory, bound, client_opts, opts)

        {:error, :not_found} ->
          stale(identifier, nil, bound, :live, :never_read)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  Remove at most `batch` cached heads no one here holds: a head an answer
  to a sign-in request read for an account this CYFR then admitted
  nowhere, once it was last verified longer ago than a request lives
  (`Prima.SignIn.lifetime_ms/0`, `Arca.DirectoryHeads.sweep/3`). A head a
  person or a pending invitation here names stays. Answers how many went.
  """
  @spec sweep(pos_integer()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def sweep(batch) when is_integer(batch) and batch > 0 do
    case Arca.DirectoryHeads.sweep(system(), Prima.SignIn.lifetime_ms(), batch) do
      {:ok, count} -> {:ok, count}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @doc """
  The verified state a cached head holds, held to the head's identifier
  and hash: `{:ok, state}`, or `{:error, :corrupt}` for a row whose stored
  state does not decode to them.
  """
  @spec state(head()) :: {:ok, State.t()} | {:error, :corrupt}
  def state(%{identifier: identifier, head_hash: head, state: json}) when is_binary(json) do
    with {:ok, %{} = map} <- Jason.decode(json),
         {:ok, %State{identifier: ^identifier, head: ^head} = state} <- State.decode(map) do
      {:ok, state}
    else
      _ -> {:error, :corrupt}
    end
  end

  def state(_head), do: {:error, :corrupt}

  @doc """
  The keys a cached head lists, in the order they were added, each with
  when it was added and, for a passkey whose `add_key` named one, its
  maker's `aaguid`: `{:ok, listed}`, or `{:error, :corrupt}` for a row
  whose state does not decode or whose `keys_added` does not name exactly
  its keys.
  """
  @spec keys(head()) :: {:ok, [listed()]} | {:error, :corrupt}
  def keys(head) do
    with {:ok, state, added} <- stored(head) do
      {:ok,
       Enum.map(state.keys, fn key ->
         %{key: key, added_at: added[key.kid].at, aaguid: added[key.kid].aaguid}
       end)}
    end
  end

  @doc """
  When each key `entries` list was added, walked on from `added`: an
  `add_key` notes its key at its `at` with its `aaguid`, a `remove_key`
  drops its key, and a `recover` lists its keys at its own `at`, their
  makers unknown; the account pages' `addedAt` reads a log the same way.
  `entries` are a log's, verified, in order.
  """
  @spec added([Entry.t()], added()) :: added()
  def added(entries, added \\ %{}) when is_list(entries) and is_map(added),
    do: Enum.reduce(entries, added, &noted/2)

  defp noted(%Entry{kind: :add_key, key: key, at: at, aaguid: aaguid}, added),
    do: Map.put(added, key.kid, %{at: at, aaguid: aaguid})

  defp noted(%Entry{kind: :remove_key, kid: kid}, added), do: Map.delete(added, kid)

  defp noted(%Entry{kind: :recover, keys: keys, at: at}, _added),
    do: Map.new(keys, &{&1.kid, %{at: at, aaguid: nil}})

  defp noted(%Entry{}, added), do: added

  # The state and its keys_added, held to each other: exactly the state's
  # keys, each at a time, with a maker or none.
  defp stored(%{keys_added: json} = head) when is_binary(json) do
    with {:ok, state} <- state(head),
         {:ok, %{} = map} <- Jason.decode(json),
         {:ok, added} <- decoded_added(map),
         true <- Enum.sort(Map.keys(added)) == Enum.sort(Enum.map(state.keys, & &1.kid)) do
      {:ok, state, added}
    else
      _ -> {:error, :corrupt}
    end
  end

  defp stored(_head), do: {:error, :corrupt}

  defp decoded_added(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {kid, note}, {:ok, acc} ->
      case note do
        %{"at" => at} = note when map_size(note) == 1 ->
          noted_at(acc, kid, at, nil)

        %{"at" => at, "aaguid" => aaguid} = note when map_size(note) == 2 and is_binary(aaguid) ->
          noted_at(acc, kid, at, aaguid)

        _other ->
          {:halt, :error}
      end
    end)
  end

  defp noted_at(acc, kid, at, aaguid) do
    if Prima.Identity.Encoding.ms?(at),
      do: {:cont, {:ok, Map.put(acc, kid, %{at: at, aaguid: aaguid})}},
      else: {:halt, :error}
  end

  @doc """
  The `keys_added` a cached head keeps for a log's `entries`, as JSON
  text: `added/2` from nothing, each key's `at` and, for a passkey whose
  `add_key` named one, its `aaguid`. What a first read caches beside the
  state the same entries verify to (`Arca.DirectoryHeads.put/2`).
  """
  @spec keys_added([Entry.t()]) :: String.t()
  def keys_added(entries) when is_list(entries), do: entries |> added() |> encode_added()

  defp encode_added(added) do
    added
    |> Map.new(fn
      {kid, %{at: at, aaguid: nil}} -> {kid, %{"at" => at}}
      {kid, %{at: at, aaguid: aaguid}} -> {kid, %{"at" => at, "aaguid" => aaguid}}
    end)
    |> Jason.encode!()
  end

  # ---- reading the directory ---------------------------------------------------

  # Past the bound the directory is read again, unless this member found it
  # unreachable within the last `@unreachable_ms`, or a caller's
  # transaction holds the person's lock: then the access mode decides on
  # what is cached.
  defp past_bound(head, bound, client_opts) do
    cond do
      Arca.in_transaction?() ->
        offline(head, bound, :past_bound, :in_transaction)

      match?({:ok, _unreachable}, Arca.Cache.get(Keys.identity_unreachable(head.identifier))) ->
        offline(head, bound, :past_bound, :recently_unreachable)

      true ->
        refresh(head, bound, client_opts, :past_bound, @rounds)
    end
  end

  # The entries after the cached head, verified from its state and walked
  # in the advance's transaction. A cache another refresh moved meanwhile
  # is read again.
  defp refresh(head, bound, client_opts, why, rounds) do
    with {:ok, state, added} <- cached_state(head),
         {:ok, log} <- read_after(head, state, client_opts),
         {:ok, next, steps, entries} <- walked(state, log) do
      settle(head, {next, added(entries, added)}, steps, bound, client_opts, why, rounds)
    else
      {:error, reason} -> unrefreshed(head, bound, why, reason)
    end
  end

  defp cached_state(head) do
    case stored(head) do
      {:ok, state, added} ->
        {:ok, state, added}

      {:error, :corrupt} ->
        Logger.error(
          "[Sanctum.IdentityFreshness] the cached head of #{head.identifier} does not " <>
            "decode to its state and the keys it lists; refusing to extend it"
        )

        {:error, :corrupt_cache}
    end
  end

  defp read_after(head, state, client_opts) do
    Client.entries_after(
      head.identifier,
      head.directory_url,
      head.head_hash,
      state.seq,
      client_opts
    )
  end

  # The entries verified one by one from the cached state, to exactly the
  # head and length the directory named, with the steps they retire and
  # the entries themselves, in order.
  defp walked(state, %{entries: entries, head: head, length: length}) do
    entries
    |> Enum.reduce_while({:ok, state, [], []}, fn map, {:ok, state, steps, read} ->
      with {:ok, entry} <- Entry.decode(map),
           {:ok, next} <- Identity.extend(state, entry) do
        {:cont, {:ok, next, step(entry, steps), [entry | read]}}
      else
        {:error, reason} -> {:halt, {:error, {:unverified, reason}}}
      end
    end)
    |> case do
      {:ok, %State{head: ^head, seq: seq} = next, steps, read} when seq + 1 == length ->
        {:ok, next, Enum.reverse(steps), Enum.reverse(read)}

      {:ok, %State{}, _steps, _read} ->
        {:error, :truncated}

      {:error, _reason} = refused ->
        refused
    end
  end

  defp step(%Entry{kind: :remove_key, kid: kid}, steps), do: [{:remove_key, kid} | steps]
  defp step(%Entry{kind: :recover}, steps), do: [:recover | steps]
  defp step(%Entry{}, steps), do: steps

  defp settle(head, {next, _added}, [], _bound, _client_opts, _why, _rounds)
       when next.head == head.head_hash do
    case Arca.DirectoryHeads.touch(system(), head.identifier, head.head_hash) do
      {:ok, touched} -> reached(touched)
      {:error, :stale} -> reread(head.identifier)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp settle(head, {next, added}, steps, bound, client_opts, why, rounds) do
    attrs = %{
      genesis: head.genesis,
      directory_url: head.directory_url,
      head_hash: next.head,
      state: encode(next),
      keys_added: encode_added(added)
    }

    case Arca.DirectoryHeads.advance(system(), head.identifier, head.head_hash, attrs, steps) do
      {:ok, %{head: advanced, retired: retired}} ->
        drop_retired(head.identifier, retired)
        reached(advanced)

      {:error, :stale} when rounds > 1 ->
        case Arca.DirectoryHeads.get(system(), head.identifier) do
          {:ok, moved} -> refresh(moved, bound, client_opts, why, rounds - 1)
          {:error, _reason} -> {:error, :unavailable}
        end

      {:error, :gone} ->
        {:refused, :identity_gone}

      {:error, reason} ->
        Logger.warning("[Sanctum.IdentityFreshness] the head cache refused: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  # A head another refresh verified meanwhile: the cache as it stands now.
  defp reread(identifier) do
    case Arca.DirectoryHeads.get(system(), identifier) do
      {:ok, %{gone_at: %DateTime{}}} -> {:refused, :identity_gone}
      {:ok, head} -> reached(head)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  # A read that succeeded ends this member's unreachable window.
  defp reached(head) do
    Arca.Cache.invalidate(Keys.identity_unreachable(head.identifier))
    {:ok, head}
  end

  # An identifier never read: its whole log, verified from the genesis,
  # which must hash to it and name the directory it was read at.
  defp first_read(identifier, directory, bound, client_opts, opts) do
    with {:ok, log} <- Client.log(identifier, directory, client_opts),
         {:ok, state, entries} <- verified(identifier, directory, log) do
      attrs = %{
        identifier: identifier,
        genesis: Identity.canonical(hd(entries)),
        directory_url: directory,
        head_hash: state.head,
        state: encode(state),
        keys_added: keys_added(entries)
      }

      case Arca.DirectoryHeads.put(system(), attrs) do
        {:ok, head} -> reached(head)
        {:error, :exists} -> fresh!(identifier, opts)
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :gone} -> {:refused, :identity_gone}
      {:error, reason} -> stale(identifier, directory, bound, :live, reason)
    end
  end

  defp verified(identifier, directory, %{entries: [_genesis | _] = entries} = log) do
    case Identity.verify_chain(entries) do
      {:ok, %State{identifier: ^identifier, directory: ^directory} = state}
      when state.head == log.head and state.seq + 1 == log.length ->
        {:ok, state, Enum.map(entries, &verified_entry/1)}

      {:ok, %State{identifier: ^identifier, directory: ^directory}} ->
        {:error, :truncated}

      {:ok, %State{}} ->
        {:error, :identifier_mismatch}

      {:error, {_index, reason}} ->
        {:error, {:unverified, reason}}
    end
  end

  defp verified(_identifier, _directory, _log), do: {:error, :invalid_page}

  # An entry of a log that verified: it decodes.
  defp verified_entry(map) do
    {:ok, entry} = Entry.decode(map)
    entry
  end

  # Why a refresh did not reach a head: the account gone, a log that does
  # not hold the cached head, an outage the access mode decides on, or a
  # log that does not verify, which pauses the work.
  defp unrefreshed(head, bound, why, reason) do
    cond do
      reason == :gone ->
        gone!(head.identifier)

      reason == :not_found ->
        Sanctum.Telemetry.identity_not_descendant(head.identifier, head.directory_url)
        stale(head.identifier, head.directory_url, bound, why, :not_descendant)

      outage?(reason) ->
        if reason in [:unreachable, :timeout], do: unreachable!(head.identifier)
        offline(head, bound, why, reason)

      true ->
        stale(head.identifier, head.directory_url, bound, why, reason)
    end
  end

  # Only a directory that did not answer is an outage: a transport failure,
  # a 5xx or a 429 (this member's own shed among them). A directory that
  # answered, with a redirect, a body too large or unreadable, its own
  # store's corruption or any other status, served no log this home can
  # verify, and that pauses the work in every mode.
  defp outage?(reason) when reason in [:unreachable, :timeout, :egress_refused], do: true
  defp outage?({tag, _seconds}) when tag in [:rate_limited, :capacity, :unavailable], do: true
  defp outage?({:status, status}) when status in 500..599, do: true
  defp outage?(_reason), do: false

  # The directory answered gone: every binding of the account retires with
  # the mark, and the retired sessions' memos go once it committed.
  defp gone!(identifier) do
    case Arca.DirectoryHeads.gone(system(), identifier) do
      {:ok, %{retired: retired}} ->
        drop_retired(identifier, retired)

        Logger.warning(
          "[Sanctum.IdentityFreshness] the directory answered #{identifier} gone: every " <>
            "binding of it here is retired"
        )

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.IdentityFreshness] #{identifier} is gone at its directory, and the " <>
            "head cache refused the mark: #{inspect(reason)}"
        )
    end

    {:refused, :identity_gone}
  end

  # The access mode decides on a cached head this home could not refresh:
  # a public home pauses the work, a local or tailnet one answers the keys
  # it last read.
  defp offline(head, bound, why, reason) do
    case Sanctum.access_mode() do
      :public ->
        stale(head.identifier, head.directory_url, bound, why, reason)

      mode when mode in [:local, :tailnet] ->
        Logger.debug(
          "[Sanctum.IdentityFreshness] #{head.identifier}'s directory could not refresh its " <>
            "head (#{word(reason)}); this #{mode} home answers the keys it last read"
        )

        {:ok, head}
    end
  end

  # The pause after a directory that could not be reached or timed out:
  # this member reads it again for this account only once the entry
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

  defp encode(state), do: state |> State.encode() |> Jason.encode!()

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

  defp options!(opts) when is_list(opts) do
    case Keyword.validate(opts, [:directory, :resolver, :cacerts]) do
      {:ok, opts} -> Keyword.pop(opts, :directory)
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
