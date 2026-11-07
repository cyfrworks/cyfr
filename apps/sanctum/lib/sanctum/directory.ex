# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory do
  @moduledoc """
  The directory's decisions over the account logs it orders
  (`Arca.IdentityLog`, `ARCHITECTURE.md` §9.1), `cyfr-directory/v2`:
  registering a genesis, appending an entry against the head it names,
  answering a page of a log with its head, from a position or after an
  entry's hash, and the operator's tombstone.
  `tests/fixtures/directory_wire.json` holds its HTTP conformance.

  Emissary's directory routes are the only caller of the reads and writes
  (`Emissary.Web.DirectoryController`). Each function takes the caller's
  address as `source`, the key of its per-source limits; nothing here
  reads a session, because every write is self-authenticating.

  ## Serving

  `directory_serve` decides: `off` answers `:not_served` to everything,
  `writer` serves reads and writes, and `mirror` is this module read-only,
  answering `:read_only` to every write before anything else is done.

  The directory a node serves is its origin (`Sanctum.origin/0`) and
  nothing else. Its routes are mounted at the root, `/directory/v1`, never
  under a path a proxy adds. The origin as configured need not be in the
  one spelling a genesis names its directory in (a local home on port 80
  is `http://localhost:80`, named `http://localhost`), so it is compared
  in that spelling (`Prima.Identity.Encoding.canonical_home/1`), byte for
  byte with the decoded genesis's directory. A genesis naming anything
  else, such as another host, this host on another port or scheme, or
  this host under a path, is refused `:wrong_directory` once it decodes,
  before its signature is checked and before anything is stored. An
  origin that is not a home however it is spelled, such as one with a
  path, names no directory, and every genesis is refused
  `:wrong_directory`. Every log this node registers names it.

  ## Order of work

  Every request is admitted to its bounds before any signature is checked:

    1. the body limit, before decoding (`CyfrWeb.Plugs.RawBodyReader`);
    2. the per-source and per-installation fixed windows, and for a
       genesis its own tighter pair: each shed first by this member's
       counter (`Prima.RateLimiter`), then claimed durably and shared by
       every member (`Arca.RequestRateWindows`);
    3. decoding, and an append's place against the head: an entry already
       the one after its `prev` answers `:exists` without spending an
       allowance, and a `prev` that is not the head is
       `{:stale_head, head}`;
    4. the signature, against the verified state the head stores
       (`Prima.Identity.extend/2`), so a forged request costs one
       signature check, never a walk of the log;
    5. only for an entry that verified, the identifier's signed-write
       window, so an invalid signature never spends the owner's
       allowance. An entry a listed key signed may take 50 of its 60 a
       minute and spends the identifier's day: at most 100 verified
       writes in a durable 24-hour window, claimed after the signature
       verifies and before the write, so one then refused as a stale head
       still spends one. Past it the answer is `{:capacity, :writes,
       seconds}`. An entry appended after the genesis that a recovery key
       signed may take all 60 a minute, is exempt from the day, and may
       spend the store's recovery reserve.

  Every bound is admitted before the log is written, so no bound changes
  an identifier's order: an overload answers `{:rate_limited, seconds}`,
  retryable.

  ## Answers

  A write answers its result: `:created` for a new genesis, `:accepted`
  for an appended entry, `:exists` for one already written, with the
  current head. A malformed entry, a non-genesis at registration and a
  genesis at an append are `{:invalid, reason}`; a key listed twice is
  `:duplicate_key`; any other refusal of the chain is
  `{:unverified, reason}`. A tombstoned identifier is `:gone` to every
  read and write.

  ## Pages

  `resolve/1` answers the entries after `after` (a sequence number, -1
  for the start) and `from/1` those after the entry hashing to `hash`, up
  to the head it read first, at most 100 entries and at most 64 KiB of
  entry bytes with the envelope, with `next` naming where the next page
  starts while more remain. The entries are the stored canonical bytes,
  which every acceptance verified; the reader verifies them again.
  """

  require Logger

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, State}

  @window_ms 60_000
  @per_source 300
  @per_installation 3_000
  @genesis_per_source 5
  @genesis_per_installation 100
  @signed_per_identifier 60
  @recovery_reserve 10
  # Verified writes a listed key signs, per identifier a day: at 50 a
  # minute a log would outgrow the client's page bound (1,000 pages of 100)
  # in about 33 hours.
  @writes_per_day 100
  @day_ms 86_400_000
  # One key for the installation-wide windows; the claim hashes it.
  @installation "installation"

  # A page's entries and envelope stay within 64 KiB: the envelope (the
  # identifier, the head and three integers) is far below this reserve.
  @page_bytes 65_536
  @envelope_bytes 1_024
  @max_position 2_147_483_647

  @typedoc "The caller's address, the key of its per-source limits."
  @type source :: String.t()

  @typedoc "Why a request is refused. The controller's moduledoc maps each to its wire code."
  @type reason ::
          :not_served
          | :read_only
          | :not_found
          | :gone
          | :wrong_directory
          | :duplicate_key
          | :conflict
          | :unavailable
          | :corrupt
          | {:invalid, atom() | {atom(), String.t()}}
          | {:unverified, atom()}
          | {:stale_head, String.t()}
          | {:rate_limited, pos_integer()}
          | {:capacity, :identities | :log_bytes}
          | {:capacity, :writes, pos_integer()}

  @typedoc "A write's answer: the identifier, the entry's position and hash, and its result."
  @type written :: %{
          required(:identifier) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:entry_hash) => String.t(),
          required(:result) => :created | :accepted | :exists,
          optional(:head) => String.t()
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

  # ---- the writes --------------------------------------------------------------

  @doc """
  Register a genesis: `genesis` is its JSON map. Answers the identifier it
  hashes to, `:created`, or `:exists` with the current head for the same
  genesis again. A genesis naming another directory than this node's is
  `:wrong_directory`.
  """
  @spec register(%{genesis: term(), source: source()}) :: {:ok, written()} | {:error, reason()}
  def register(%{genesis: genesis, source: source}) when is_binary(source) do
    with :ok <- serving(:write),
         :ok <- admit(every_request(source) ++ registration(source)),
         {:ok, entry} <- decode_entry(genesis),
         :ok <- genesis_kind(entry),
         :ok <- served_here(entry),
         {:ok, state} <- chain([Entry.encode(entry)]),
         {:ok, policy} <- policy() do
      attrs = %{
        identifier: state.identifier,
        entry: Identity.canonical(entry),
        entry_hash: state.head,
        state: encode_state(state)
      }

      case Arca.IdentityLog.register(system(), attrs, policy) do
        {:ok, row, :created} -> {:ok, written(state.identifier, row, :created)}
        {:ok, row, :exists} -> exists(state.identifier, row)
        {:error, :conflict} -> {:error, :conflict}
        {:error, reason} -> store_refusal(reason)
      end
    end
  end

  @doc """
  Append an entry to `identifier`'s log: `entry` is the signed entry's
  JSON map, naming in `prev` the head it extends. Answers `:accepted`, or
  `:exists` with the current head for an entry already the one after its
  `prev`.
  """
  @spec append(String.t(), %{entry: term(), source: source()}) ::
          {:ok, written()} | {:error, reason()}
  def append(identifier, %{entry: entry, source: source})
      when is_binary(identifier) and is_binary(source) do
    with :ok <- serving(:write),
         :ok <- known(identifier),
         :ok <- admit(every_request(source)),
         {:ok, entry} <- decode_entry(entry),
         :ok <- later_kind(entry),
         {:ok, head} <- head(identifier),
         :fresh <- placed(identifier, head, entry),
         {:ok, state} <- head_state(identifier, head),
         {:ok, next} <- extended(state, entry),
         recovery? = recovery_signed?(entry),
         :ok <- admit(signed(identifier, if(recovery?, do: :recovery, else: :key))),
         {:ok, policy} <- policy() do
      attrs = %{
        entry: Identity.canonical(entry),
        entry_hash: next.head,
        prev_hash: head.entry_hash,
        kind: Atom.to_string(entry.kind),
        state: encode_state(next),
        recovery: recovery?
      }

      case Arca.IdentityLog.append(system(), identifier, attrs, policy) do
        {:ok, row, :accepted} -> {:ok, written(identifier, row, :accepted)}
        {:ok, row, :exists} -> exists(identifier, row)
        {:error, :stale} -> stale_head(identifier)
        {:error, reason} -> store_refusal(reason)
      end
    end
  end

  @doc """
  The operator's tombstone: `identifier` is gone to every later read and
  write, its entries kept. A CYFR's platform administrator makes it
  through the operation `directory.tombstone`.
  """
  @spec tombstone(String.t()) :: :ok | {:error, reason()}
  def tombstone(identifier) when is_binary(identifier) do
    with :ok <- serving(:write),
         :ok <- known(identifier) do
      case Arca.IdentityLog.tombstone(system(), identifier) do
        :ok -> :ok
        {:error, reason} -> store_refusal(reason)
      end
    end
  end

  # ---- the reads ---------------------------------------------------------------

  @doc """
  One page of `identifier`'s log: the entries after position `after`
  (-1 for the start), with the head and length the page was read against
  and `next`, the position to ask after next, while more remain.
  """
  @spec resolve(%{identifier: String.t(), after: integer(), source: source()}) ::
          {:ok, page()} | {:error, reason()}
  def resolve(%{identifier: identifier, after: after_seq, source: source})
      when is_binary(identifier) and is_binary(source) do
    with :ok <- serving(:read),
         :ok <- known(identifier),
         :ok <- position(after_seq),
         :ok <- admit(every_request(source)) do
      page_after(identifier, after_seq)
    end
  end

  @doc """
  One page of `identifier`'s log after the entry hashing to `hash`, empty
  at the head; a hash the log does not hold, or one that is no hash, is
  `:not_found`.
  """
  @spec from(%{identifier: String.t(), hash: String.t(), source: source()}) ::
          {:ok, page()} | {:error, reason()}
  def from(%{identifier: identifier, hash: hash, source: source})
      when is_binary(identifier) and is_binary(hash) and is_binary(source) do
    with :ok <- serving(:read),
         :ok <- known(identifier),
         :ok <- digest(hash),
         :ok <- admit(every_request(source)),
         {:ok, seq} <- position_of(identifier, hash) do
      page_after(identifier, seq)
    end
  end

  defp page_after(identifier, after_seq) do
    with {:ok, head} <- head(identifier),
         {:ok, rows} <- entries(identifier, after_seq) do
      {:ok, page(identifier, after_seq, Enum.filter(rows, &(&1.seq <= head.seq)), head)}
    end
  end

  # ---- beside the directory -----------------------------------------------------

  @doc false
  # The gate every request to the registry served beside this directory
  # passes first (`Sanctum.Directory.Handles`): served for `need` as the
  # directory is, and admitted to the directory's per-source and
  # per-installation windows.
  @spec gate(source(), :read | :write) :: :ok | {:error, reason()}
  def gate(source, need) when is_binary(source) and need in [:read, :write] do
    with :ok <- serving(need), do: admit(every_request(source))
  end

  @doc false
  # Whether this node is its directory's writer, the node that serves the
  # account pages beside it (`Emissary.Web.AccountController`).
  @spec writer?() :: boolean()
  def writer?, do: mode() == {:ok, :writer}

  @doc false
  # The directory this node serves, in the one spelling a genesis names
  # it, or `:error` for an origin that is no home.
  @spec served() :: {:ok, String.t()} | :error
  def served do
    case Encoding.canonical_home(Sanctum.origin()) do
      {:ok, directory} -> {:ok, directory}
      _other -> :error
    end
  end

  @doc false
  # The verified state `identifier`'s head stores here: `:not_found` for an
  # identifier this directory does not hold, `:gone` for a tombstoned one.
  @spec state(String.t()) :: {:ok, State.t()} | {:error, reason()}
  def state(identifier) when is_binary(identifier) do
    with :ok <- known(identifier),
         {:ok, head} <- head(identifier),
         do: head_state(identifier, head)
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
  # request past it is told, a rate limit or the day's write capacity.
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

  # One window per identifier for its signed writes: an entry a listed key
  # signed stops short of the recovery reserve, one a recovery key signed
  # may spend all of it. A verified entry a listed key signed also spends
  # the identifier's day, after the minute, so one the minute refuses
  # spends none of the day; one the store then refuses as a stale head has
  # spent it. An entry a recovery key signed is exempt from the day.
  defp signed(identifier, :key),
    do: [
      {:directory_signed, identifier, @signed_per_identifier - @recovery_reserve, @window_ms,
       :rate},
      {:directory_writes_daily, identifier, @writes_per_day, @day_ms, :writes}
    ]

  defp signed(identifier, :recovery),
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
  defp over(:writes, seconds), do: {:error, {:capacity, :writes, seconds}}

  defp seconds(ms), do: max(div(ms + 999, 1000), 1)

  # ---- decoding ----------------------------------------------------------------

  defp decode_entry(map) when is_map(map) do
    case Entry.decode(map) do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:invalid, detail(reason)}}
    end
  end

  defp decode_entry(_value), do: {:error, {:invalid, :malformed}}

  defp genesis_kind(%Entry{kind: :genesis}), do: :ok
  defp genesis_kind(%Entry{}), do: {:error, {:invalid, :not_genesis}}

  defp later_kind(%Entry{kind: :genesis}), do: {:error, {:invalid, :unexpected_genesis}}
  defp later_kind(%Entry{}), do: :ok

  defp detail({tag, field}) when tag in [:unknown_field, :missing_field, :invalid_field],
    do: {tag, field}

  defp detail({:unknown_kind, _kind}), do: :unknown_kind
  defp detail(reason) when is_atom(reason), do: reason
  defp detail(_reason), do: :malformed

  defp known(identifier) do
    if Encoding.identifier?(identifier), do: :ok, else: {:error, :not_found}
  end

  defp digest(hash) do
    if Encoding.digest?(hash), do: :ok, else: {:error, :not_found}
  end

  # The store keeps a position as a 32-bit integer, so a position past it
  # names nothing and is refused here, before any rate claim or query.
  defp position(after_seq) when is_integer(after_seq) and after_seq in -1..@max_position,
    do: :ok

  defp position(_after_seq), do: {:error, {:invalid, {:invalid_field, "after"}}}

  defp served_here(%Entry{directory: directory}) do
    case Encoding.canonical_home(Sanctum.origin()) do
      {:ok, ^directory} -> :ok
      _ -> {:error, :wrong_directory}
    end
  end

  defp recovery_signed?(%Entry{signer: "recovery:" <> _}), do: true
  defp recovery_signed?(%Entry{}), do: false

  # ---- the chain ---------------------------------------------------------------

  defp chain(entries) do
    case Identity.verify_chain(entries) do
      {:ok, state} -> {:ok, state}
      {:error, {_index, reason}} -> {:error, {:unverified, reason_name(reason)}}
    end
  end

  # The entry against the state its head stores: one signature check.
  defp extended(state, entry) do
    case Identity.extend(state, entry) do
      {:ok, next} -> {:ok, next}
      {:error, :duplicate_key} -> {:error, :duplicate_key}
      {:error, reason} -> {:error, {:unverified, reason_name(reason)}}
    end
  end

  defp reason_name(reason) when is_atom(reason), do: reason
  defp reason_name({tag, _detail}) when is_atom(tag), do: tag

  # An entry whose `prev` is not the head is either the one already after
  # its `prev`, answered as written without spending an allowance, or
  # stale. The store decides the same again under its lock.
  defp placed(identifier, %{entry_hash: head}, %Entry{prev: head}) when is_binary(identifier),
    do: :fresh

  defp placed(identifier, head, %Entry{prev: prev} = entry) do
    canonical = Identity.canonical(entry)

    with {:ok, seq} <- position_of(identifier, prev),
         {:ok, [%{entry: ^canonical} = row]} <- entries(identifier, seq, limit: 1) do
      {:ok, written(identifier, row, :exists) |> Map.put(:head, head.entry_hash)}
    else
      _other -> {:error, {:stale_head, head.entry_hash}}
    end
  end

  # The verified state the head stores: every acceptance verified it before
  # it wrote, so a state that does not read back is damage.
  defp head_state(identifier, head) do
    with {:ok, map} <- Jason.decode(head.state),
         {:ok, %State{identifier: ^identifier, head: hash} = state} <- State.decode(map),
         true <- hash == head.entry_hash do
      {:ok, state}
    else
      _ -> corrupt(:state)
    end
  end

  defp encode_state(state), do: state |> State.encode() |> Jason.encode!()

  # The account is not named: the directory keeps no record of who was
  # asked about.
  defp corrupt(why) do
    Logger.error(
      "[Sanctum.Directory] a stored log does not verify (#{inspect(why)}); refusing to extend it"
    )

    {:error, :corrupt}
  end

  # ---- answers -----------------------------------------------------------------

  defp written(identifier, row, result),
    do: %{identifier: identifier, seq: row.seq, entry_hash: row.entry_hash, result: result}

  defp exists(identifier, row) do
    with {:ok, head} <- head(identifier) do
      {:ok, identifier |> written(row, :exists) |> Map.put(:head, head.entry_hash)}
    end
  end

  defp stale_head(identifier) do
    with {:ok, head} <- head(identifier), do: {:error, {:stale_head, head.entry_hash}}
  end

  defp head(identifier) do
    case Arca.IdentityLog.head(system(), identifier) do
      {:ok, head} -> {:ok, head}
      {:error, reason} -> store_refusal(reason)
    end
  end

  defp position_of(identifier, hash) do
    case Arca.IdentityLog.position(system(), identifier, hash) do
      {:ok, seq} -> {:ok, seq}
      {:error, reason} -> store_refusal(reason)
    end
  end

  defp entries(identifier, after_seq, opts \\ []) do
    case Arca.IdentityLog.entries(system(), identifier, [after: after_seq] ++ opts) do
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
  defp store_refusal(:gone), do: {:error, :gone}
  defp store_refusal(:entry_too_large), do: {:error, {:invalid, :too_large}}

  defp store_refusal(reason) do
    Logger.warning("[Sanctum.Directory] the directory's store refused: #{inspect(reason)}")
    {:error, :unavailable}
  end

  defp system, do: Prima.Actor.system()
end
