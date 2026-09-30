# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory do
  @moduledoc """
  The directory's decisions over the identity logs it orders
  (`Arca.IdentityLog`, `ARCHITECTURE.md` §9.1): registering a genesis,
  appending a rotation against the head it names, applying a recovery
  against the current policy revision, and answering a page of a log with
  its head and a recorded request's outcome.

  Emissary's directory routes are the only caller
  (`Emissary.Web.DirectoryController`). Each function takes the caller's
  address as `source`, the key of its per-source limits; nothing here
  reads a session, because every write is self-authenticating.

  ## Serving

  `directory_serve` decides: `off` answers `:not_served` to everything,
  `writer` serves reads and writes, and `mirror` is this module read-only,
  answering `:read_only` to every write before anything else is done.

  ## Order of work

  Every request is admitted to its bounds before any signature is checked:

    1. the body limit, before decoding (`CyfrWeb.Plugs.RawBodyReader`);
    2. the per-source and per-installation fixed windows, and for a
       genesis its own tighter pair: each shed first by this member's
       counter (`Prima.RateLimiter`), then claimed durably and shared by
       every member (`Arca.RequestRateWindows`);
    3. decoding and signature work;
    4. only for a signed write that verified, the identifier's
       signed-write window, so an invalid signature never spends the
       owner's allowance. Rotations may take 50 of its 60 a minute and a
       recovery all 60: 10 are reserved for recovery whatever rotations do.
       A rotation then also spends the identifier's day: at most 100
       verified rotation attempts in a durable 24-hour window, so whoever
       holds the operational key cannot grow a log past what a reader can
       page through in hours. It counts verified attempts, not writes: it
       is claimed after the signature verifies and before the write, so a
       rotation then refused as a stale head still spends one, and no
       concurrency lets more than 100 through. A rotation past it is
       refused `{:capacity, :rotations, seconds}`, the seconds left in the
       window; a recovery is exempt.

  An overload that refuses a recovery answers `{:rate_limited, seconds}`,
  retryable, and never a stale policy.

  ## What every acceptance checks

  A signed write is first held to the head's keys alone
  (`Arca.IdentityLog.keys/2`: the head, the genesis and every accepted
  recovery, never the rotations between them). A rotation must name the
  head as `prev` and carry the signature of the operational key the last
  of those entries names; a recovery must name the genesis's identifier
  and directory, a revision the log has reached, and a signer in the
  recovery set in force at that revision. A request that fails is refused
  without the rotations being read or any stored entry re-verified, so a
  flood of forged requests naming the public head costs one signature
  check each, not one per stored entry; it still reads one row per
  accepted recovery.

  Only then is the stored log read whole and the new entry verified with
  it, `Prima.Identity.verify_chain/1` over the log and the entry, before
  the write. The store then serializes: a rotation names the head it extends
  (`{:stale_head, head}` when another landed first); a recovery is applied
  against the current policy revision, and a head moved by a rotation in
  between is re-based on the new head, at most three times, before
  answering `:busy`. A recovery request whose revision is no longer
  current is recorded as a stale-policy refusal once its signature
  verifies under the recovery set of the revision it names, so a retry
  answers the same refusal whatever the log does next.

  An exact retry answers its recorded outcome without spending an
  allowance: the rotation that is the head, a recovery request id already
  answered with the same digest. A rotation the log has moved past names
  a stale head and is answered so; its sender finds it in the chain it
  resolves. The same request id with another digest is
  `:request_id_reused`.

  ## Pages

  `resolve/1` answers the entries after `after` (a sequence number, -1
  for the start) up to the head it read first, at most 100 entries and at
  most 64 KiB of entry bytes with the envelope, with `next` naming where
  the next page starts while more remain. The entries are the stored
  canonical bytes, which every acceptance verified; the reader verifies
  them again.
  """

  require Logger

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, RecoverRequest, State}

  @window_ms 60_000
  @per_source 300
  @per_installation 3_000
  @genesis_per_source 5
  @genesis_per_installation 100
  @signed_per_identifier 60
  @recovery_reserve 10
  # Verified rotation attempts per identifier a day: at 50 a minute a log would
  # outgrow the client's page bound (1,000 pages of 100) in about 33
  # hours, and no recovery shortens a log.
  @rotations_per_day 100
  @day_ms 86_400_000
  # One key for the installation-wide windows; the claim hashes it.
  @installation "installation"

  # A page's entries and envelope stay within 64 KiB: the envelope (the
  # identifier, the head and three integers) is far below this reserve.
  @page_bytes 65_536
  @envelope_bytes 1_024

  @rebases 3
  @max_position 2_147_483_647

  @typedoc "The caller's address, the key of its per-source limits."
  @type source :: String.t()

  @typedoc "Why a request is refused. The controller's moduledoc maps each to its wire code."
  @type reason ::
          :not_served
          | :read_only
          | :not_found
          | :wrong_identifier
          | :request_id_reused
          | :conflict
          | :busy
          | :unavailable
          | :corrupt
          | {:invalid, atom() | {atom(), String.t()}}
          | {:unverified, atom()}
          | {:stale_head, String.t()}
          | {:stale_policy, map()}
          | {:rate_limited, pos_integer()}
          | {:capacity, :identities | :log_bytes}
          | {:capacity, :rotations, pos_integer()}

  @typedoc "An accepted write: the identifier, the entry's position and hash."
  @type accepted :: %{
          required(:identifier) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:entry_hash) => String.t(),
          optional(:entry) => binary()
        }

  @typedoc "One page of a log: canonical entry bytes, from position `from`."
  @type page :: %{
          identifier: String.t(),
          from: non_neg_integer(),
          entries: [binary()],
          next: non_neg_integer() | nil,
          head: String.t(),
          length: pos_integer()
        }

  @typedoc "A recorded recovery request's outcome."
  @type outcome ::
          %{
            identifier: String.t(),
            request_id: String.t(),
            request_digest: String.t(),
            outcome: :accepted,
            seq: non_neg_integer(),
            entry_hash: String.t(),
            entry: binary()
          }
          | %{
              identifier: String.t(),
              request_id: String.t(),
              request_digest: String.t(),
              outcome: :stale_policy,
              recorded: map()
            }

  # ---- the entries -------------------------------------------------------------

  @doc """
  Register a genesis: `genesis` is its JSON map. Answers the identifier it
  hashes to; the same genesis again answers the same registration.
  """
  @spec register(%{genesis: term(), source: source()}) :: {:ok, accepted()} | {:error, reason()}
  def register(%{genesis: genesis, source: source}) when is_binary(source) do
    with :ok <- serving(:write),
         :ok <- admit(every_request(source) ++ registration(source)),
         {:ok, entry} <- decode_entry(genesis, :genesis),
         {:ok, state} <- chain([Entry.encode(entry)]),
         {:ok, policy} <- policy() do
      attrs = %{
        identifier: state.identifier,
        entry: Identity.canonical(entry),
        entry_hash: state.head
      }

      case Arca.IdentityLog.register(system(), attrs, policy) do
        {:ok, row} -> {:ok, accepted(state.identifier, row)}
        {:error, :conflict} -> {:error, :conflict}
        {:error, reason} -> store_refusal(reason)
      end
    end
  end

  @doc """
  Append a rotation to `identifier`'s log: `entry` is the signed rotate
  entry's JSON map, naming in `prev` the head it extends.
  """
  @spec append(String.t(), %{entry: term(), source: source()}) ::
          {:ok, accepted()} | {:error, reason()}
  def append(identifier, %{entry: entry, source: source})
      when is_binary(identifier) and is_binary(source) do
    with :ok <- serving(:write),
         :ok <- known(identifier),
         :ok <- admit(every_request(source)),
         {:ok, rotation} <- decode_entry(entry, :rotate),
         {:ok, keys} <- keys(identifier),
         :fresh <- already_appended(identifier, keys, rotation),
         :ok <- extends(keys.head, rotation),
         :ok <- signed_by_operational(keys, rotation),
         {:ok, log} <- current(identifier),
         :ok <- extends(log.state.head, rotation),
         {:ok, _state} <- chain(log.entries ++ [Entry.encode(rotation)]),
         :ok <- admit(signed(identifier, :rotate)),
         {:ok, policy} <- policy() do
      attrs = %{
        entry: Identity.canonical(rotation),
        entry_hash: Identity.hash(rotation),
        prev_hash: log.state.head
      }

      case Arca.IdentityLog.append(system(), identifier, attrs, policy) do
        {:ok, row} -> {:ok, accepted(identifier, row)}
        {:error, :stale} -> stale_head(identifier)
        {:error, reason} -> store_refusal(reason)
      end
    end
  end

  @doc """
  Apply a recovery to `identifier`'s log: `request` is the signed recover
  request's JSON map, which must name `identifier`. The entry committed
  embeds it after the current head.
  """
  @spec recover(String.t(), %{request: term(), source: source()}) ::
          {:ok, accepted()} | {:error, reason()}
  def recover(identifier, %{request: request, source: source})
      when is_binary(identifier) and is_binary(source) do
    with :ok <- serving(:write),
         :ok <- known(identifier),
         :ok <- admit(every_request(source)),
         {:ok, request} <- decode_request(request),
         :ok <- names(request, identifier),
         digest = Identity.request_digest(request),
         :fresh <- recorded(identifier, request.request_id, digest),
         {:ok, keys} <- keys(identifier),
         :ok <- signed_by_recovery(keys, request),
         {:ok, log} <- current(identifier),
         {:ok, entry} <- recoverable(log, request),
         :ok <- admit(signed(identifier, :recover)),
         {:ok, policy} <- policy() do
      commit_recovery(identifier, request, digest, log, entry, policy, @rebases)
    end
  end

  # ---- the reads ---------------------------------------------------------------

  @doc """
  One page of `identifier`'s log: the entries after position `after`
  (nil or -1 for the start), with the head and length the page was read
  against and `next`, the position to ask after next, while more remain.
  """
  @spec resolve(%{identifier: String.t(), after: integer() | nil, source: source()}) ::
          {:ok, page()} | {:error, reason()}
  def resolve(%{identifier: identifier, after: after_seq, source: source})
      when is_binary(identifier) and is_binary(source) do
    after_seq = after_seq || -1

    with :ok <- serving(:read),
         :ok <- known(identifier),
         :ok <- position(after_seq),
         :ok <- admit(every_request(source)),
         {:ok, head} <- head(identifier),
         {:ok, rows} <- entries(identifier, after_seq) do
      {:ok, page(identifier, after_seq, Enum.filter(rows, &(&1.seq <= head.seq)), head)}
    end
  end

  @doc "The recorded outcome of recovery request `request_id` under `identifier`."
  @spec outcome(%{identifier: String.t(), request_id: String.t(), source: source()}) ::
          {:ok, outcome()} | {:error, reason()}
  def outcome(%{identifier: identifier, request_id: request_id, source: source})
      when is_binary(identifier) and is_binary(request_id) and is_binary(source) do
    with :ok <- serving(:read),
         :ok <- known(identifier),
         :ok <- request_id(request_id),
         :ok <- admit(every_request(source)) do
      case Arca.IdentityLog.outcome(system(), identifier, request_id) do
        {:ok, %{outcome: "accepted"} = row} ->
          {:ok, Map.merge(recorded_answer(identifier, row), accepted_outcome(row))}

        {:ok, %{outcome: "stale_policy"} = row} ->
          {:ok,
           Map.merge(recorded_answer(identifier, row), %{
             outcome: :stale_policy,
             recorded: recorded_body(row)
           })}

        {:error, :not_found} ->
          {:error, :not_found}

        {:error, reason} ->
          store_refusal(reason)
      end
    end
  end

  # ---- serving -----------------------------------------------------------------

  defp serving(need) do
    case mode() do
      {:ok, :off} -> {:error, :not_served}
      {:ok, :mirror} when need == :write -> {:error, :read_only}
      {:ok, _mode} -> :ok
      {:error, _reason} = refused -> refused
    end
  end

  # The setting refuses a stale value: a store that cannot answer it serves
  # nothing, as no other identity decision is made on a value this member
  # cannot read. Stored values come back as JSON decodes them.
  defp mode do
    case Arca.PlatformSettings.effective("directory_serve") do
      {:ok, mode} when mode in ["off", :off] ->
        {:ok, :off}

      {:ok, mode} when mode in ["writer", :writer] ->
        {:ok, :writer}

      {:ok, mode} when mode in ["mirror", :mirror] ->
        {:ok, :mirror}

      {:ok, other} ->
        Logger.error(
          "[Sanctum.Directory] the stored directory_serve #{inspect(other)} is not off, " <>
            "writer or mirror; serving nothing until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.Directory] directory_serve cannot be read: the setting is #{reason}"
    end
  end

  # The deployment's quotas, passed to the store that decides them under
  # its lock (`Arca.IdentityLog`).
  defp policy do
    with {:ok, identities} <- quota("directory_max_identities"),
         {:ok, bytes} <- quota("directory_log_bytes"),
         {:ok, reserve} <- quota("directory_recovery_reserve_bytes") do
      {:ok, %{max_identities: identities, log_bytes: bytes, recovery_reserve_bytes: reserve}}
    end
  end

  defp quota(key) do
    case Arca.PlatformSettings.effective(key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {:ok, other} ->
        Logger.error(
          "[Sanctum.Directory] the stored #{key} #{inspect(other)} is not a positive " <>
            "whole number; refusing writes until it is"
        )

        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.Directory] #{key} cannot be read: the setting is #{reason}"
    end
  end

  # ---- the bounds --------------------------------------------------------------

  # Each bound is `{bucket, key, cap, window_ms, over}`: `over` is what a
  # request past it is told, a rate limit or the day's rotation capacity.
  defp every_request(source),
    do: [
      {:directory_source, source, @per_source, @window_ms, :rate},
      {:directory_installation, @installation, @per_installation, @window_ms, :rate}
    ]

  defp registration(source),
    do: [
      {:directory_genesis_source, source, @genesis_per_source, @window_ms, :rate},
      {:directory_genesis_installation, @installation, @genesis_per_installation, @window_ms,
       :rate}
    ]

  # One window per identifier for its signed writes: a rotation stops
  # short of the recovery reserve, a recovery may spend all of it. A
  # verified rotation also spends the identifier's day, after the minute,
  # so a rotation the minute refuses spends none of the day; one the store
  # then refuses as a stale head has spent it.
  defp signed(identifier, :rotate),
    do: [
      {:directory_signed, identifier, @signed_per_identifier - @recovery_reserve, @window_ms,
       :rate},
      {:directory_rotation_daily, identifier, @rotations_per_day, @day_ms, :rotations}
    ]

  defp signed(identifier, :recover),
    do: [{:directory_signed, identifier, @signed_per_identifier, @window_ms, :rate}]

  # This member's counter sheds a flood before any claim reaches the
  # database; the durable claim is what every member shares.
  defp admit(buckets) do
    with :ok <- shed(buckets), do: claim(buckets)
  end

  defp shed(buckets) do
    Enum.reduce_while(buckets, :ok, fn {bucket, key, cap, window_ms, over}, :ok ->
      case Prima.RateLimiter.check({__MODULE__, bucket, key}, cap, window_ms) do
        :ok -> {:cont, :ok}
        {:deny, seconds} -> {:halt, over(over, seconds)}
      end
    end)
  end

  defp claim(buckets) do
    Enum.reduce_while(buckets, :ok, fn {bucket, key, cap, window_ms, over}, :ok ->
      case Arca.RequestRateWindows.claim(system(), bucket, key, cap, window_ms) do
        :ok -> {:cont, :ok}
        {:error, {:rate_limited, ms}} -> {:halt, over(over, seconds(ms))}
        {:error, _reason} -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  defp over(:rate, seconds), do: {:error, {:rate_limited, seconds}}
  defp over(:rotations, seconds), do: {:error, {:capacity, :rotations, seconds}}

  defp seconds(ms), do: max(div(ms + 999, 1000), 1)

  # ---- decoding ----------------------------------------------------------------

  defp decode_entry(map, kind) when is_map(map) do
    case Entry.decode(map) do
      {:ok, %Entry{kind: ^kind} = entry} -> {:ok, entry}
      {:ok, %Entry{}} -> {:error, {:invalid, not_kind(kind)}}
      {:error, reason} -> {:error, {:invalid, detail(reason)}}
    end
  end

  defp decode_entry(_value, _kind), do: {:error, {:invalid, :malformed}}

  defp not_kind(:genesis), do: :not_genesis
  defp not_kind(:rotate), do: :not_rotate

  defp decode_request(map) when is_map(map) do
    case RecoverRequest.decode(map) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:error, {:invalid, detail(reason)}}
    end
  end

  defp decode_request(_value), do: {:error, {:invalid, :malformed}}

  defp detail({tag, field}) when tag in [:unknown_field, :missing_field, :invalid_field],
    do: {tag, field}

  defp detail({:unknown_kind, _kind}), do: :unknown_kind
  defp detail(reason) when is_atom(reason), do: reason
  defp detail(_reason), do: :malformed

  defp known(identifier) do
    if Encoding.identifier?(identifier), do: :ok, else: {:error, :not_found}
  end

  defp request_id(request_id) do
    if Encoding.id?(request_id), do: :ok, else: {:error, :not_found}
  end

  # The store keeps a position as a 32-bit integer, so a position past it
  # names nothing and is refused here, before any rate claim or query.
  defp position(after_seq) when is_integer(after_seq) and after_seq in -1..@max_position,
    do: :ok

  defp position(_after_seq), do: {:error, {:invalid, {:invalid_field, "after"}}}

  defp names(%RecoverRequest{identifier: identifier}, identifier), do: :ok
  defp names(%RecoverRequest{}, _identifier), do: {:error, :wrong_identifier}

  # ---- the log -----------------------------------------------------------------

  # The whole stored log, verified from its genesis: its rows, their JSON
  # maps, the verified state, and the recovery set in force at each policy
  # revision, for judging a request that names a revision no longer current.
  defp current(identifier) do
    with {:ok, rows} <- all_rows(identifier, -1, []),
         {:ok, entries} <- stored_entries(identifier, rows),
         {:ok, state} <- stored_chain(identifier, entries) do
      # Every stored entry decodes: the chain just verified from them.
      decoded = Enum.map(entries, fn map -> map |> Entry.decode() |> elem(1) end)
      {:ok, %{entries: entries, state: state, sets: recovery_sets(decoded)}}
    end
  end

  defp all_rows(identifier, after_seq, pages) do
    case Arca.IdentityLog.entries(system(), identifier, after: after_seq) do
      {:ok, []} when pages == [] ->
        {:error, :not_found}

      {:ok, rows} ->
        pages = [rows | pages]

        if length(rows) < Arca.IdentityLog.max_page(),
          do: {:ok, pages |> Enum.reverse() |> Enum.concat()},
          else: all_rows(identifier, List.last(rows).seq, pages)

      {:error, reason} ->
        store_refusal(reason)
    end
  end

  defp stored_entries(identifier, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case Jason.decode(row.entry) do
        {:ok, %{} = map} -> {:cont, {:ok, [map | acc]}}
        _other -> {:halt, corrupt(identifier, :undecodable)}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      refused -> refused
    end
  end

  defp stored_chain(identifier, entries) do
    case Identity.verify_chain(entries) do
      {:ok, %State{identifier: ^identifier} = state} -> {:ok, state}
      {:ok, %State{}} -> corrupt(identifier, :wrong_identifier)
      {:error, {index, reason}} -> corrupt(identifier, {index, reason})
    end
  end

  # Every acceptance verifies before it writes: a stored log that does not
  # verify is damage, answered as such and never extended.
  defp corrupt(identifier, why) do
    Logger.error(
      "[Sanctum.Directory] the stored log of #{identifier} does not verify " <>
        "(#{inspect(why)}); refusing to extend it"
    )

    {:error, :corrupt}
  end

  # The recovery set at each revision: the genesis's at 0, then each
  # recover entry's new set, or the one before it when it names none.
  defp recovery_sets(entries) do
    entries
    |> Enum.reduce([], fn
      %Entry{kind: :genesis, recovery_keys: keys}, _sets -> [keys]
      %Entry{kind: :recover, request: request}, sets -> [request.recovery_keys || hd(sets) | sets]
      %Entry{}, sets -> sets
    end)
    |> Enum.reverse()
  end

  defp chain(entries) do
    case Identity.verify_chain(entries) do
      {:ok, state} -> {:ok, state}
      {:error, {_index, reason}} -> {:error, {:unverified, reason_name(reason)}}
    end
  end

  defp reason_name(reason) when is_atom(reason), do: reason
  defp reason_name({tag, _detail}) when is_atom(tag), do: tag

  # ---- rotation ----------------------------------------------------------------

  # A rotation that is the head is its own recorded outcome: an exact retry
  # after a lost answer, answered without spending an allowance. One the
  # log has moved past names a stale head, and its sender finds it in the
  # chain it resolves.
  defp already_appended(identifier, %{head: head}, rotation) do
    if Identity.hash(rotation) == head.entry_hash,
      do: {:ok, accepted(identifier, head)},
      else: :fresh
  end

  defp extends(%{entry_hash: head}, %Entry{prev: prev}), do: extends(head, prev)
  defp extends(head, %Entry{prev: prev}) when is_binary(head), do: extends(head, prev)
  defp extends(head, head) when is_binary(head), do: :ok
  defp extends(head, _prev), do: {:error, {:stale_head, head}}

  # ---- the head's keys ---------------------------------------------------------

  # The head and the key-bearing entries (the genesis and every accepted
  # recovery), read without the rotations between them: enough to check a
  # new entry's signature, so a request that fails it is refused without
  # the log being read or verified. The whole chain is still verified
  # before any write.
  defp keys(identifier) do
    case Arca.IdentityLog.keys(system(), identifier) do
      {:ok, %{head: head, keyed: rows}} ->
        with {:ok, keyed} <- keyed_entries(identifier, rows),
             do: {:ok, %{head: head, keyed: keyed}}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        store_refusal(reason)
    end
  end

  defp keyed_entries(identifier, rows) do
    entries =
      Enum.map(rows, fn row ->
        with {:ok, %{} = map} <- Jason.decode(row.entry),
             {:ok, %Entry{kind: kind} = entry} when kind in [:genesis, :recover] <-
               Entry.decode(map) do
          entry
        else
          _ -> nil
        end
      end)

    case entries do
      [%Entry{kind: :genesis} | _] = keyed ->
        if Enum.all?(keyed, & &1), do: {:ok, keyed}, else: corrupt(identifier, :keys)

      _other ->
        corrupt(identifier, :keys)
    end
  end

  # The operational key at the head is the last key-bearing entry's:
  # rotations name only a live key.
  defp signed_by_operational(%{keyed: keyed}, rotation) do
    key =
      case List.last(keyed) do
        %Entry{kind: :genesis, operational_key: key} -> key
        %Entry{kind: :recover, request: request} -> request.operational_key
      end

    case Identity.verify(rotation, key) do
      :ok -> :ok
      {:error, :wrong_signer} -> {:error, {:unverified, :wrong_signer}}
    end
  end

  # A recovery names the genesis's identifier and directory, a revision the
  # log has reached, and is signed by a holder of the recovery set in force
  # at that revision: the current one, or an earlier one for a request that
  # will be recorded as stale.
  defp signed_by_recovery(%{keyed: [genesis | _] = keyed}, %RecoverRequest{} = request) do
    sets = recovery_sets(keyed)

    cond do
      request.identifier != Identity.identifier(genesis) ->
        {:error, :wrong_identifier}

      request.directory != genesis.directory ->
        {:error, {:unverified, :directory_changed}}

      request.expected_revision >= length(sets) ->
        {:error, {:unverified, :stale_revision}}

      true ->
        signed_at(request, Enum.at(sets, request.expected_revision))
    end
  end

  defp stale_head(identifier) do
    case head(identifier) do
      {:ok, head} -> {:error, {:stale_head, head.entry_hash}}
      {:error, _reason} = refused -> refused
    end
  end

  # ---- recovery ----------------------------------------------------------------

  # A request already answered: its outcome, whatever the log became, when
  # the digest is the same; the same id with another digest is refused.
  defp recorded(identifier, request_id, digest) do
    case Arca.IdentityLog.outcome(system(), identifier, request_id) do
      {:error, :not_found} ->
        :fresh

      {:ok, %{request_digest: ^digest, outcome: "accepted"} = row} ->
        {:ok, accepted(identifier, row) |> Map.put(:entry, row.entry)}

      {:ok, %{request_digest: ^digest, outcome: "stale_policy"} = row} ->
        {:error, {:stale_policy, recorded_body(row)}}

      {:ok, _other_request} ->
        {:error, :request_id_reused}

      {:error, reason} ->
        store_refusal(reason)
    end
  end

  # The entry this request makes on the log as it stands, once the request
  # verifies. At the current revision the whole chain with the entry is
  # verified; a request naming an earlier revision is judged by the
  # recovery set of that revision, and is written as a recorded refusal.
  defp recoverable(%{state: state} = log, %RecoverRequest{} = request) do
    cond do
      request.expected_revision == state.revision ->
        with {:ok, entry} <- recover_entry(state.head, request),
             {:ok, _state} <- chain(log.entries ++ [Entry.encode(entry)]),
             do: {:ok, entry}

      request.expected_revision < state.revision ->
        with :ok <- same_directory(request, state),
             :ok <- signed_at(request, Enum.at(log.sets, request.expected_revision)),
             do: recover_entry(state.head, request)

      true ->
        {:error, {:unverified, :stale_revision}}
    end
  end

  defp recover_entry(prev, request) do
    case Entry.recover(prev, request) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:invalid, detail(reason)}}
    end
  end

  defp same_directory(%RecoverRequest{directory: directory}, %State{directory: directory}),
    do: :ok

  defp same_directory(_request, _state), do: {:error, {:unverified, :directory_changed}}

  defp signed_at(request, keys) when is_list(keys) do
    case RecoverRequest.signer(request, keys) do
      {:ok, _signer} -> :ok
      {:error, :wrong_signer} -> {:error, {:unverified, :wrong_signer}}
    end
  end

  defp signed_at(_request, nil), do: {:error, {:unverified, :stale_revision}}

  defp commit_recovery(identifier, request, digest, log, entry, policy, rebases) do
    attrs = %{
      entry: Identity.canonical(entry),
      entry_hash: Identity.hash(entry),
      prev_hash: log.state.head,
      request_id: request.request_id,
      request_digest: digest,
      expected_revision: request.expected_revision
    }

    case Arca.IdentityLog.recover(system(), identifier, attrs, policy) do
      {:ok, row} ->
        {:ok, accepted(identifier, row) |> Map.put(:entry, row.entry)}

      # Recorded under the lock, since a recovery landed in between: the
      # answer is the record, as every retry of the request will read it.
      {:error, :stale_policy} ->
        case recorded(identifier, request.request_id, digest) do
          :fresh -> {:error, :unavailable}
          answer -> answer
        end

      # A rotation moved the head between the read and the write, and the
      # revision still stands: the recovery is never refused for that; it
      # is built again on the new head and verified again.
      {:error, :stale} when rebases > 0 ->
        with {:ok, log} <- current(identifier),
             {:ok, entry} <- recoverable(log, request),
             do: commit_recovery(identifier, request, digest, log, entry, policy, rebases - 1)

      {:error, :stale} ->
        {:error, :busy}

      {:error, reason} ->
        store_refusal(reason)
    end
  end

  # ---- answers -----------------------------------------------------------------

  defp accepted(identifier, row),
    do: %{identifier: identifier, seq: row.seq, entry_hash: row.entry_hash}

  defp recorded_answer(identifier, row),
    do: %{identifier: identifier, request_id: row.request_id, request_digest: row.request_digest}

  defp accepted_outcome(row),
    do: %{outcome: :accepted, seq: row.seq, entry_hash: row.entry_hash, entry: row.entry}

  defp recorded_body(row) do
    case Jason.decode(row.outcome_body || "") do
      {:ok, %{} = body} -> body
      _other -> %{}
    end
  end

  defp head(identifier) do
    case Arca.IdentityLog.head(system(), identifier) do
      {:ok, head} -> {:ok, head}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> store_refusal(reason)
    end
  end

  defp entries(identifier, after_seq) do
    case Arca.IdentityLog.entries(system(), identifier, after: after_seq) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> store_refusal(reason)
    end
  end

  # As many rows as fit the page's byte bound, and always the first: an
  # entry is at most 16 KiB, well inside it.
  defp page(identifier, after_seq, rows, head) do
    budget = @page_bytes - @envelope_bytes

    {taken, _used} =
      Enum.reduce_while(rows, {[], 0}, fn row, {taken, used} ->
        size = byte_size(row.entry) + 1

        if taken != [] and used + size > budget,
          do: {:halt, {taken, used}},
          else: {:cont, {[row | taken], used + size}}
      end)

    last = if taken == [], do: after_seq, else: hd(taken).seq

    %{
      identifier: identifier,
      from: after_seq + 1,
      entries: taken |> Enum.reverse() |> Enum.map(& &1.entry),
      next: if(last < head.seq, do: last, else: nil),
      head: head.entry_hash,
      length: head.seq + 1
    }
  end

  defp store_refusal({:capacity, which}) when which in [:identities, :log_bytes],
    do: {:error, {:capacity, which}}

  defp store_refusal(:not_found), do: {:error, :not_found}
  defp store_refusal(:request_id_reused), do: {:error, :request_id_reused}
  defp store_refusal(:entry_too_large), do: {:error, {:invalid, :too_large}}

  defp store_refusal(reason) do
    Logger.warning("[Sanctum.Directory] the directory's store refused: #{inspect(reason)}")
    {:error, :unavailable}
  end

  defp system, do: Prima.Actor.system()
end
