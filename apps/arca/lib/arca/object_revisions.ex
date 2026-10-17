# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.ObjectRevisions do
  @moduledoc """
  Guest objects by generation: every path under `data/` is a row
  (`Arca.Schemas.ObjectRevision`), every write of it a generation of its
  own (`Arca.Schemas.ObjectGeneration`), and its bytes an object stored at
  that generation's key, `objects/<generation>/<path>`, under the
  athanor's reserved `objects/` root. Nothing writes or reads the path
  `data/…` itself: the `Arca` facade resolves every `data/` path here.

  ## A write

    1. **Mark.** One transaction locks the path's row, raises its
       `generation` to a number no ancestor or descendant path's
       generation has reached (so no two objects ever need one name as a
       file and as a directory), and inserts the generation's row with the
       bytes the writer will store and the sources those bytes carry: the
       writer's, joined for an append with the settled object's.
    2. **Store.** The bytes go to the generation's key, outside any
       transaction. A stalled or late store lands at its own key and is
       never another generation's bytes.
    3. **Settle.** A second transaction moves the row's
       `settled_generation`, the read pointer, to the generation, with its
       sources, only while the generation is newer than the pointer and
       than `deleted_at_generation`. A superseded settlement writes
       nothing; one at or below the deletion fence is `dead`.

  A guest's write runs its mark and its settlement inside its attempt's
  intent transactions (`Arca.ExecutionAttempts.while_held/6`), which settle
  with the generation's sources joined with the attempt's ledger. A write
  with no attempt — a person's Files write, an offer's create, an upload —
  runs all three steps here (`write/5`), each transaction its own, and its
  sources are the ones its caller names (an unnamed outside source when
  it names none: provenance nobody recorded is never the athanor's own).
  A write with no attempt settles within twelve hours of its mark or not
  at all, so a store stalled past the shortest retention window can never
  publish a generation retention has begun to collect.

  ## What each operation settles over

  | Operation | Derives from | Settles while |
  |---|---|---|
  | put | its own bytes | its generation is above the pointer |
  | append | the settled generation's bytes plus the suffix | the pointer is still the base it read |
  | create (`put_if_none_match`) | its own bytes | nothing is settled at the path |
  | replace (`put_if_match`) | its own bytes | the pointer is the generation the read answered |
  | copy | the source's settled bytes | as a put |
  | delete | nothing: no object | its generation is above the pointer |

  Every one also requires its generation above `deleted_at_generation`.
  An append whose base moved re-derives from the new base under a fresh
  generation, within five attempts with a doubling backoff; past the
  bound it is `{:error, :precondition_failed}` with nothing landed. A
  pending generation's bytes never enter a settled object: an append and
  a copy read only a settled generation.

  ## Reads

  One observation: the row, its `settled_generation` and the sources it
  settled with, then that generation's object. A path with no settled
  generation is `{:error, :not_found}`. An object retention collected
  under a reader that read the row before a newer settlement is read
  again from the row.

  ## Deletes

  A delete raises the generation, records it as `deleted_at_generation`,
  clears the pointer and sets `deleted`, keeping the row as a tombstone, so
  a store marked before the delete stays dead whatever it settles after;
  a recreate marks above the fence and clears `deleted` at its
  settlement. A prefix delete does it for every row under the prefix.

  ## Usage

  A scope holds what it visibly holds: its files are its rows with a
  settled generation, its bytes those generations' bytes. Retained
  generations — pending, superseded, tombstoned — are the home's
  physical cost (`physical/1`), collected by retention
  (`Arca.Retention.ObjectGenerations`, `collect/3`) and never charged to
  a tenant's quota or cap.

  Every function takes the `Prima.Actor` first and reads and writes only
  its athanor's rows; an actor with no athanor is refused before any
  query. Functions ending in `!` run inside a caller's transaction and
  raise on a store error.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Arca.Schemas.{ObjectGeneration, ObjectRevision, StorageWriteIntent}

  @root "data"
  @objects "objects"
  @append_attempts 5
  @append_backoff_base_ms 20
  @read_attempts 3
  @settle_within_ms :timer.hours(12)
  @collect_batch 500

  defmodule Mark do
    @moduledoc false
    # A generation a mark handed out: the path, the generation, the
    # operation it was marked for, the settled generation it derived from
    # (an append's base, a replace's precondition), the bytes the store
    # will hold, the bytes the path visibly held at the mark and whether
    # the path held a visible object then.
    @enforce_keys [:segments, :key, :generation, :op]
    defstruct [
      :segments,
      :key,
      :generation,
      :op,
      :base,
      bytes: 0,
      visible_bytes: 0,
      visible?: false
    ]

    @type t :: %__MODULE__{}
  end

  @typedoc "A mark handed out for a write (`mark!/4`), opaque to callers."
  @type mark :: Mark.t()

  @typedoc "The operations a mark is taken for."
  @type op :: :put | :append | :create | {:if_match, pos_integer()} | :delete

  @typedoc "What a settlement did (`settle!/3`)."
  @type settlement ::
          :settled
          | :superseded
          | :dead
          | :base_moved
          | :exists
          | :missing
          | :precondition_failed
          | :enotdir
          | :eisdir

  @doc "Whether `path` (normalized segments) names the guest-object tree, `data/` or below."
  @spec object_path?(Arca.Storage.path()) :: boolean()
  def object_path?([@root | _]), do: true
  def object_path?(_path), do: false

  @doc "The reserved tenant root generation objects are stored under."
  @spec objects_root() :: String.t()
  def objects_root, do: @objects

  @doc "How many attempts an append re-derives within before it refuses."
  @spec append_attempts() :: pos_integer()
  def append_attempts, do: @append_attempts

  @doc "Sleep the backoff before re-deriving attempt `attempt + 1` of an append."
  @spec backoff(pos_integer()) :: :ok
  def backoff(attempt) when is_integer(attempt) and attempt > 0,
    do: Process.sleep(backoff_ms(attempt))

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc """
  The settled object at `path` and the sources it settled with, in one
  observation: `{:ok, bytes, sources}`, `{:error, :not_found}` where
  nothing is settled, or the adapter's or the database's refusal.
  """
  @spec read(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, binary(), [Prima.Source.t()]} | {:error, term()}
  def read(%Prima.Actor{} = actor, path) do
    with {:ok, bytes, sources, _generation} <- observe(actor, path, @read_attempts),
         do: {:ok, bytes, sources}
  end

  @doc """
  `read/2` with the precondition a replace of it carries
  (`put_if_match`): the settled generation, as `{:generation, g}`.
  """
  @spec read_for_update(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, binary(), {:generation, pos_integer()}} | {:error, term()}
  def read_for_update(%Prima.Actor{} = actor, path) do
    with {:ok, bytes, _sources, generation} <- observe(actor, path, @read_attempts),
         do: {:ok, bytes, {:generation, generation}}
  end

  @doc "The settled bytes at `path` — `read/2` without its sources, as an adapter's `get/2` answers."
  @spec get(Prima.Actor.t(), Arca.Storage.path()) :: {:ok, binary()} | {:error, term()}
  def get(%Prima.Actor{} = actor, path) do
    with {:ok, bytes, _sources} <- read(actor, path), do: {:ok, bytes}
  end

  defp observe(actor, path, attempts) do
    adapter = adapter()

    with {:ok, athanor_id} <- athanor(actor) do
      case visible(athanor_id, key(path)) do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, %ObjectRevision{settled_generation: generation, sources: sources}} ->
          case adapter.get(actor, object_key(generation, path)) do
            {:ok, bytes} ->
              {:ok, bytes, Prima.Source.decode(sources), generation}

            # Collected after a newer settlement moved the pointer past it:
            # the row is read again.
            {:error, :not_found} when attempts > 1 ->
              observe(actor, path, attempts - 1)

            {:error, _} = error ->
              error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Stream the settled object at `path` to `conn` (`Arca.serve_to_conn/4`)."
  @spec serve_to_conn(Plug.Conn.t(), Prima.Actor.t(), Arca.Storage.path(), keyword()) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def serve_to_conn(conn, %Prima.Actor{} = actor, path, opts),
    do: serve(conn, actor, path, opts, @read_attempts)

  defp serve(conn, actor, path, opts, attempts) do
    with {:ok, athanor_id} <- athanor(actor) do
      case visible(athanor_id, key(path)) do
        {:ok, nil} ->
          {:error, :not_found}

        {:ok, %ObjectRevision{settled_generation: generation}} ->
          case adapter().serve_to_conn(conn, actor, object_key(generation, path), opts) do
            {:error, :not_found} when attempts > 1 -> serve(conn, actor, path, opts, attempts - 1)
            answer -> answer
          end

        {:error, _} = error ->
          error
      end
    end
  end

  @doc "Whether a settled object is at `path` — files only, as `Arca.exists?/2`."
  @spec exists?(Prima.Actor.t(), Arca.Storage.path()) :: boolean()
  def exists?(%Prima.Actor{} = actor, path) do
    case athanor(actor) do
      {:ok, athanor_id} -> match?({:ok, %ObjectRevision{}}, visible(athanor_id, key(path)))
      {:error, _} -> false
    end
  end

  @doc """
  The entries directly under `path`, each `:file` or `:dir`, from the
  settled rows: `{:error, :enotdir}` when `path` is itself a settled
  object, `{:ok, []}` when nothing is settled under it.
  """
  @spec list_typed(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, [{String.t(), :file | :dir}]} | {:error, term()}
  def list_typed(%Prima.Actor{} = actor, path) do
    with {:ok, athanor_id} <- athanor(actor),
         {:ok, rows} <- settled_under(athanor_id, path, :with_self) do
      prefix = key(path)

      if Enum.any?(rows, &(&1.path == prefix)) do
        {:error, :enotdir}
      else
        {:ok,
         rows
         |> Enum.map(&child(&1.path, prefix))
         |> Enum.uniq()}
      end
    end
  end

  defp child(row_path, prefix) do
    case row_path |> relative(prefix) |> String.split("/", parts: 2) do
      [name] -> {name, :file}
      [name, _deeper] -> {name, :dir}
    end
  end

  @doc "Every settled object under `path`, as full segment lists (`Arca.list_recursive/2`)."
  @spec list_recursive(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def list_recursive(%Prima.Actor{} = actor, path) do
    with {:ok, athanor_id} <- athanor(actor),
         {:ok, rows} <- settled_under(athanor_id, path, :below) do
      {:ok, Enum.map(rows, &String.split(&1.path, "/"))}
    end
  end

  @doc """
  The visible files and bytes at or under `path`: a settled object counts
  one file of its generation's bytes; a pending, superseded or tombstoned
  generation counts nothing.
  """
  @spec usage(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, %{files: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def usage(%Prima.Actor{} = actor, path) do
    with {:ok, athanor_id} <- athanor(actor) do
      prefix = key(path)

      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.usage", fn ->
        {files, bytes} =
          from(r in ObjectRevision,
            join: g in ObjectGeneration,
            on:
              g.athanor_id == r.athanor_id and g.path == r.path and
                g.generation == r.settled_generation,
            where: r.athanor_id == ^athanor_id and not is_nil(r.settled_generation),
            where: r.deleted == false,
            select: {count(r.path), coalesce(sum(g.bytes), 0)}
          )
          |> at_or_under(prefix)
          |> Arca.Repo.one()

        {:ok, %{files: files, bytes: to_integer(bytes)}}
      end)
    end
  end

  @doc """
  What the athanor's retained generations physically hold: every
  generation row and its bytes, the settled ones included. The home's
  cost under retention and the storage reserve, never a tenant's quota.
  """
  @spec physical(Prima.Actor.t()) ::
          {:ok, %{generations: non_neg_integer(), bytes: non_neg_integer()}} | {:error, term()}
  def physical(%Prima.Actor{} = actor) do
    with {:ok, athanor_id} <- athanor(actor) do
      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.physical", fn ->
        {count, bytes} =
          from(g in ObjectGeneration,
            where: g.athanor_id == ^athanor_id,
            select: {count(g.generation), coalesce(sum(g.bytes), 0)}
          )
          |> Arca.Repo.one()

        {:ok, %{generations: count, bytes: to_integer(bytes)}}
      end)
    end
  end

  @doc """
  The bytes `path` visibly holds and whether an object is settled there:
  what a write's admission charges its delta against.
  """
  @spec visible_size(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, %{bytes: non_neg_integer(), file?: boolean()}} | {:error, term()}
  def visible_size(%Prima.Actor{} = actor, path) do
    with {:ok, %{files: files, bytes: bytes}} <- usage_exact(actor, path),
         do: {:ok, %{bytes: bytes, file?: files == 1}}
  end

  defp usage_exact(actor, path) do
    with {:ok, athanor_id} <- athanor(actor) do
      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.visible_size", fn ->
        case visible_bytes!(athanor_id, key(path)) do
          nil -> {:ok, %{files: 0, bytes: 0}}
          bytes -> {:ok, %{files: 1, bytes: bytes}}
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Writes with no attempt
  # ---------------------------------------------------------------------------

  @doc """
  Write `content` at `path` for a caller with no attempt: mark, store at
  the generation's key, settle, each transaction its own. `op` is `:put`,
  `:append`, `:create` (`{:error, :exists}` once something is settled
  there) or `{:if_match, {:generation, g}}` (`{:error,
  :precondition_failed}` when the pointer moved, `{:error, :missing}`
  when nothing is settled). `sources:` names the bytes' sources, an
  unnamed outside source by default.

  `:ok` once the write settled or a newer one superseded it; `{:error,
  :dead}` when a delete fenced it; `{:error, :unknown}` when the store or
  the settlement could not say what it did, the generation then never
  settling; any other store refusal as the adapter answered it, nothing
  landed.
  """
  @spec write(
          Prima.Actor.t(),
          Arca.Storage.path(),
          op() | {:if_match, term()},
          binary(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def write(%Prima.Actor{} = actor, path, op, content, opts \\ []) when is_binary(content) do
    sources = Keyword.get_lazy(opts, :sources, fn -> [Prima.Source.outside(nil)] end)

    with {:ok, _athanor_id} <- athanor(actor),
         {:ok, op} <- host_op(op) do
      host_write(actor, path, op, content, sources, 1)
    end
  end

  defp host_op({:if_match, {:generation, generation}}) when is_integer(generation),
    do: {:ok, {:if_match, generation}}

  defp host_op({:if_match, _foreign}), do: {:error, :precondition_failed}
  defp host_op(op) when op in [:put, :append, :create], do: {:ok, op}

  defp host_write(actor, path, op, content, sources, attempt) do
    marked =
      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.mark", fn ->
        Arca.Repo.locking_transaction(fn ->
          case mark!(actor, path, op, %{bytes: byte_size(content), sources: sources}) do
            {:ok, mark} -> mark
            {:refused, reason} -> Arca.Repo.rollback({:refused, reason})
          end
        end)
      end)

    case marked do
      {:ok, mark} ->
        case store(actor, mark, content) do
          :ok ->
            host_settle(actor, mark, path, op, content, sources, attempt)

          {:error, :base_moved} ->
            rederive(actor, path, op, content, sources, attempt)

          {:error, _} = error ->
            error
        end

      {:error, {:refused, reason}} ->
        {:error, reason}

      {:error, _} = error ->
        error
    end
  end

  defp host_settle(actor, mark, path, op, content, sources, attempt) do
    settled =
      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.settle", fn ->
        Arca.Repo.locking_transaction(fn -> settle!(actor, mark, [], fresh: true) end)
      end)

    case settled do
      {:ok, outcome} when outcome in [:settled, :superseded] ->
        :ok

      {:ok, :base_moved} ->
        rederive(actor, path, op, content, sources, attempt)

      # A create a delete fenced after its mark: nothing landed, and the
      # caller's read of the path says so.
      {:ok, :dead} when op == :create ->
        {:error, :unknown}

      {:ok, outcome}
      when outcome in [:dead, :exists, :missing, :precondition_failed, :enotdir, :eisdir] ->
        {:error, outcome}

      # Past its settling window, or a database that could not answer once
      # the bytes were stored: the generation stays pending, never read.
      {:ok, :expired} ->
        {:error, :unknown}

      {:error, _reason} ->
        {:error, :unknown}
    end
  end

  defp rederive(actor, path, op, content, sources, attempt)
       when attempt < @append_attempts do
    backoff(attempt)
    host_write(actor, path, op, content, sources, attempt + 1)
  end

  defp rederive(_actor, _path, _op, _content, _sources, attempt) do
    Logger.warning("[Arca.ObjectRevisions] an append still losing after #{attempt} attempts")
    {:error, :precondition_failed}
  end

  @doc """
  Store `content` for `mark` at its generation's key, outside any
  transaction: a put's, create's or replace's own bytes; an append's
  base generation's bytes followed by `content`, the suffix. The store
  call of a guest's write (`Arca.ExecutionAttempts.while_held/6`) and of
  `write/5`. A base that is gone answers `{:error, :base_moved}`: a newer
  settlement moved the pointer past it, so the append re-derives from the
  new base as a refused settlement would make it.
  """
  @spec store(Prima.Actor.t(), mark(), binary()) :: :ok | {:error, term()}
  def store(%Prima.Actor{} = actor, %Mark{op: :append, base: nil} = mark, suffix),
    do: adapter().put(actor, object_key(mark.generation, mark.segments), suffix)

  def store(%Prima.Actor{} = actor, %Mark{op: :append, base: base} = mark, suffix) do
    case adapter().get(actor, object_key(base, mark.segments)) do
      {:ok, settled} ->
        adapter().put(actor, object_key(mark.generation, mark.segments), settled <> suffix)

      {:error, :not_found} ->
        {:error, :base_moved}

      {:error, _} = error ->
        error
    end
  end

  def store(%Prima.Actor{}, %Mark{op: :delete}, _content), do: :ok

  def store(%Prima.Actor{} = actor, %Mark{} = mark, content),
    do: adapter().put(actor, object_key(mark.generation, mark.segments), content)

  @doc """
  Delete the settled object at `path` for a caller with no attempt, in
  one transaction: the generation raised and recorded as the deletion
  fence, the pointer cleared, the row kept as a tombstone. `{:error,
  :not_found}` where nothing is settled.
  """
  @spec delete(Prima.Actor.t(), Arca.Storage.path()) :: :ok | {:error, term()}
  def delete(%Prima.Actor{} = actor, path) do
    with {:ok, _athanor_id} <- athanor(actor) do
      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.delete", fn ->
        Arca.Repo.locking_transaction(fn ->
          case mark!(actor, path, :delete, %{bytes: 0, sources: []}) do
            {:ok, mark} -> settle!(actor, mark, [])
            {:refused, reason} -> Arca.Repo.rollback(reason)
          end
        end)
      end)
      |> case do
        {:ok, _settled_or_superseded} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Tombstone every row at or under `path` in one transaction, as `delete/2`
  does one: each row's generation raised and recorded as its fence, its
  pointer cleared. The generation objects stay for retention. `:ok`
  whatever was there.
  """
  @spec delete_tree(Prima.Actor.t(), Arca.Storage.path()) :: :ok | {:error, term()}
  def delete_tree(%Prima.Actor{} = actor, path) do
    with {:ok, athanor_id} <- athanor(actor) do
      prefix = key(path)
      now = DateTime.utc_now()

      Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.delete_tree", fn ->
        Arca.Repo.locking_transaction(fn ->
          # Locked in path order, so two overlapping prefix deletes take
          # their rows in one order.
          from(r in ObjectRevision,
            where: r.athanor_id == ^athanor_id,
            order_by: [asc: r.path],
            select: r.path
          )
          |> at_or_under(prefix)
          |> Arca.QueryHelpers.for_update()
          |> Arca.Repo.all()

          from(r in ObjectRevision,
            where: r.athanor_id == ^athanor_id,
            update: [
              set: [
                generation: fragment("? + 1", r.generation),
                deleted_at_generation: fragment("? + 1", r.generation),
                settled_generation: nil,
                deleted: true,
                settled_at: ^now
              ]
            ]
          )
          |> at_or_under(prefix)
          |> Arca.Repo.update_all([])

          :ok
        end)
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inside a caller's transaction
  # ---------------------------------------------------------------------------

  @doc """
  Mark a generation of `path` for `op` inside the caller's transaction:
  the row locked (made when absent, for a write), its generation raised,
  and, for a write, the generation's row inserted with `bytes` (an
  append's settled bytes plus the suffix) and `sources` (an append's
  joined with the settled object's). `{:refused, reason}` writes nothing:
  `:not_found` for a delete where nothing is settled, `:exists` for a
  create over a settled object, `:missing` or `:precondition_failed` for
  a replace whose precondition does not hold, `:object_too_large` for an
  append past the object ceiling (`Prima.Limits.default_max_response_size/0`),
  `:enotdir` and `:eisdir` for a path that would be a file under a settled
  object or over settled objects.
  """
  @spec mark!(Prima.Actor.t(), Arca.Storage.path(), op(), %{
          bytes: non_neg_integer(),
          sources: [Prima.Source.t()]
        }) :: {:ok, mark()} | {:refused, atom()}
  # arca:db-raise-ok inside the caller's transaction
  def mark!(%Prima.Actor{athanor_id: athanor_id}, path, :delete, _what)
      when is_binary(athanor_id) and athanor_id != "" do
    key = key(path)
    lock_ancestors!(athanor_id, path)

    case lock!(athanor_id, key) do
      %ObjectRevision{settled_generation: settled, generation: generation, deleted: false}
      when is_integer(settled) ->
        next = generation + 1
        raise_generation!(athanor_id, key, next)

        {:ok,
         %Mark{
           segments: path,
           key: key,
           generation: next,
           op: :delete,
           visible_bytes: visible_bytes!(athanor_id, key) || 0,
           visible?: true
         }}

      _absent ->
        {:refused, :not_found}
    end
  end

  # arca:db-raise-ok inside the caller's transaction
  def mark!(%Prima.Actor{athanor_id: athanor_id}, path, op, %{bytes: bytes, sources: sources})
      when is_binary(athanor_id) and athanor_id != "" do
    key = key(path)
    lock_ancestors!(athanor_id, path)
    ensure_row!(athanor_id, key)
    row = lock!(athanor_id, key)
    visible = if is_integer(row.settled_generation), do: visible_bytes!(athanor_id, key)

    with :ok <- precondition(op, row),
         :ok <- shape(athanor_id, path, key),
         {:ok, stored, joined} <- derived(athanor_id, op, row, visible, bytes, sources) do
      next = next_generation!(athanor_id, path, row)
      raise_generation!(athanor_id, key, next)

      Arca.Repo.insert!(%ObjectGeneration{
        athanor_id: athanor_id,
        path: key,
        generation: next,
        bytes: stored,
        sources: Prima.Source.encode(joined),
        marked_at: DateTime.utc_now()
      })

      {:ok,
       %Mark{
         segments: path,
         key: key,
         generation: next,
         op: op,
         base: base(op, row),
         bytes: stored,
         visible_bytes: visible || 0,
         visible?: is_integer(visible)
       }}
    else
      {:refused, _reason} = refused ->
        forget_unmarked!(athanor_id, key, row)
        refused
    end
  end

  # A refused first write leaves no row behind: a row is kept only once a
  # generation of its path was handed out.
  # arca:db-raise-ok inside the caller's transaction
  defp forget_unmarked!(athanor_id, key, %ObjectRevision{generation: 0}) do
    Arca.Repo.delete_all(
      from(r in ObjectRevision,
        where: r.athanor_id == ^athanor_id and r.path == ^key and r.generation == 0
      )
    )

    :ok
  end

  defp forget_unmarked!(_athanor_id, _key, _row), do: :ok

  defp precondition(:create, %ObjectRevision{settled_generation: settled})
       when is_integer(settled),
       do: {:refused, :exists}

  defp precondition({:if_match, _generation}, %ObjectRevision{settled_generation: nil}),
    do: {:refused, :missing}

  defp precondition({:if_match, generation}, %ObjectRevision{settled_generation: settled})
       when generation != settled,
       do: {:refused, :precondition_failed}

  defp precondition(_op, _row), do: :ok

  # A path is a file or a directory, never both: no write lands under a
  # settled object, nor over settled objects.
  defp shape(athanor_id, path, key) do
    ancestors = ancestors(path)

    cond do
      ancestors != [] and
          Arca.Repo.exists?(
            from(r in ObjectRevision,
              where: r.athanor_id == ^athanor_id and r.path in ^ancestors,
              where: not is_nil(r.settled_generation)
            )
          ) ->
        {:refused, :enotdir}

      Arca.Repo.exists?(
        from(r in ObjectRevision,
          where: r.athanor_id == ^athanor_id and not is_nil(r.settled_generation)
        )
        |> strictly_under(key)
      ) ->
        {:refused, :eisdir}

      true ->
        :ok
    end
  end

  # What the generation holds: an append the settled bytes and their
  # sources, extended by the suffix and the writer's sources.
  defp derived(athanor_id, :append, row, visible, bytes, sources) do
    base_bytes = visible || 0

    if base_bytes + bytes > Prima.Limits.default_max_response_size() do
      {:refused, :object_too_large}
    else
      inherited =
        if is_integer(row.settled_generation), do: settled_sources!(athanor_id, row), else: []

      {:ok, base_bytes + bytes, Prima.Source.union(inherited, sources)}
    end
  end

  defp derived(_athanor_id, _op, _row, _visible, bytes, sources),
    do: {:ok, bytes, Prima.Source.set(sources)}

  defp settled_sources!(_athanor_id, %ObjectRevision{sources: sources}),
    do: Prima.Source.decode(sources)

  defp base(:append, row), do: row.settled_generation
  defp base({:if_match, generation}, _row), do: generation
  defp base(_op, _row), do: nil

  # Above the path's own last generation and every ancestor's and
  # descendant's, so `objects/<generation>/…` never needs a name as both a
  # file and a directory, whatever generations the other paths keep.
  defp next_generation!(athanor_id, path, row) do
    ancestors = ancestors(path)

    above_ancestors =
      if ancestors == [],
        do: 0,
        else:
          Arca.Repo.one(
            from(r in ObjectRevision,
              where: r.athanor_id == ^athanor_id and r.path in ^ancestors,
              select: max(r.generation)
            )
          ) || 0

    above_descendants =
      from(r in ObjectRevision, where: r.athanor_id == ^athanor_id, select: max(r.generation))
      |> strictly_under(row.path)
      |> Arca.Repo.one()

    Enum.max([row.generation, above_ancestors, above_descendants || 0]) + 1
  end

  @doc """
  Settle `mark` inside the caller's transaction (the table in the
  moduledoc): the row locked, the deletion fence and the operation's
  condition checked, and the pointer moved with the generation's recorded
  sources joined with `sources` (the settling attempt's ledger; none for
  a write with no attempt). `fresh: true` refuses `:expired` a mark older
  than the settling window of a write with no attempt. A generation whose
  row retention collected settles nothing (`:expired`).
  """
  @spec settle!(Prima.Actor.t(), mark(), [Prima.Source.t()], keyword()) :: settlement() | :expired
  # arca:db-raise-ok inside the caller's transaction
  def settle!(%Prima.Actor{athanor_id: athanor_id}, %Mark{} = mark, sources, opts \\ [])
      when is_binary(athanor_id) and athanor_id != "" do
    # Ancestors, own row, then every row under it: the one ascending path
    # order every locker of these rows takes. The range comes last because
    # it is what fences a parent marked after this settlement read its
    # ancestors: whichever of a file and a path under it settles second
    # waits on the other's row and reads the shape once the first commits.
    lock_ancestors!(athanor_id, mark.segments)
    row = lock!(athanor_id, mark.key)
    lock_under!(athanor_id, mark.key)

    case mark.op do
      :delete -> settle_delete!(athanor_id, row, mark)
      op -> settle_write!(athanor_id, row, mark, op, sources, Keyword.get(opts, :fresh, false))
    end
  end

  defp settle_delete!(athanor_id, row, mark) do
    cond do
      is_integer(row.settled_generation) and row.settled_generation > mark.generation ->
        :superseded

      is_integer(row.deleted_at_generation) and row.deleted_at_generation >= mark.generation ->
        :settled

      true ->
        update_row!(athanor_id, mark.key,
          settled_generation: nil,
          deleted: true,
          deleted_at_generation: mark.generation,
          settled_at: DateTime.utc_now()
        )

        :settled
    end
  end

  defp settle_write!(athanor_id, row, mark, op, sources, fresh?) do
    generation = generation!(athanor_id, mark)

    cond do
      is_nil(generation) or (fresh? and stale?(generation)) ->
        :expired

      mark.generation <= (row.deleted_at_generation || 0) ->
        :dead

      true ->
        # The shape the mark checked, checked again under the locks of the
        # path and its ancestors: of a file and a path under it marked
        # together, the second to settle refuses.
        case shape(athanor_id, mark.segments, mark.key) do
          :ok -> settle_condition(athanor_id, row, mark, op, generation, sources)
          {:refused, reason} -> reason
        end
    end
  end

  defp settle_condition(athanor_id, row, mark, op, generation, sources) do
    settled = row.settled_generation

    case op do
      :put when is_integer(settled) and settled >= mark.generation -> :superseded
      :append when settled != mark.base -> :base_moved
      :create when is_integer(settled) -> :exists
      {:if_match, _} when is_nil(settled) -> :missing
      {:if_match, expected} when settled != expected -> :precondition_failed
      _settles -> publish!(athanor_id, mark, generation, sources)
    end
  end

  defp publish!(athanor_id, mark, %ObjectGeneration{sources: recorded}, sources) do
    update_row!(athanor_id, mark.key,
      settled_generation: mark.generation,
      sources: Prima.Source.encode(Prima.Source.union(Prima.Source.decode(recorded), sources)),
      deleted: false,
      settled_at: DateTime.utc_now()
    )

    :settled
  end

  # Since when a write with no attempt may still settle what it marked.
  defp settling_since, do: DateTime.add(DateTime.utc_now(), -@settle_within_ms, :millisecond)

  defp stale?(%ObjectGeneration{marked_at: marked_at}),
    do: DateTime.diff(DateTime.utc_now(), marked_at, :millisecond) > @settle_within_ms

  defp generation!(athanor_id, %Mark{key: key, generation: generation}) do
    Arca.Repo.one(
      from(g in ObjectGeneration,
        where: g.athanor_id == ^athanor_id and g.path == ^key and g.generation == ^generation
      )
    )
  end

  # ---------------------------------------------------------------------------
  # Retention
  # ---------------------------------------------------------------------------

  @doc """
  Collect the athanor's generations marked before `cutoff` that nothing
  can read or settle any more — neither the pointer, nor a pending
  intent's mark, nor the row's last generation while it is above the
  pointer and the fence and inside the settling window of a write with no
  attempt (twelve hours: such a write in flight) — deleting
  each object, then its row, so a pass that dies between the two leaves a
  row the next pass collects; then the objects under `objects/` no row
  names once older than `cutoff`. `dry_run: true` counts. `{:ok, count}`.
  """
  @spec collect(Prima.Actor.t(), DateTime.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def collect(%Prima.Actor{} = actor, %DateTime{} = cutoff, dry_run) when is_boolean(dry_run) do
    with {:ok, athanor_id} <- athanor(actor),
         {:ok, candidates} <- candidates(athanor_id, cutoff) do
      if dry_run do
        with {:ok, orphans} <- orphans(actor, athanor_id, cutoff),
             do: {:ok, length(candidates) + length(orphans)}
      else
        with {:ok, collected} <- collect_rows(actor, athanor_id, cutoff, candidates),
             {:ok, orphans} <- orphans(actor, athanor_id, cutoff) do
          {:ok, collected + delete_orphans(actor, orphans)}
        end
      end
    end
  end

  defp candidates(athanor_id, cutoff) do
    Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.candidates", fn ->
      {:ok,
       athanor_id
       |> collectable(cutoff)
       |> limit_to(@collect_batch)
       |> Arca.Repo.all()}
    end)
  end

  defp collectable(athanor_id, cutoff) do
    from(g in ObjectGeneration,
      as: :generation,
      join: r in ObjectRevision,
      on: r.athanor_id == g.athanor_id and r.path == g.path,
      where: g.athanor_id == ^athanor_id and g.marked_at < ^cutoff,
      where: is_nil(r.settled_generation) or g.generation != r.settled_generation,
      where:
        not (g.generation == r.generation and
               g.generation > coalesce(r.settled_generation, 0) and
               g.generation > coalesce(r.deleted_at_generation, 0) and
               g.marked_at > ^settling_since()),
      where:
        not exists(
          from(i in StorageWriteIntent,
            where:
              i.athanor_id == parent_as(:generation).athanor_id and
                i.path == parent_as(:generation).path and
                i.generation == parent_as(:generation).generation and i.state == "pending",
            select: 1
          )
        ),
      order_by: [asc: g.marked_at],
      select: {g.path, g.generation}
    )
  end

  defp limit_to(query, n), do: from(q in query, limit: ^n)

  defp collect_rows(actor, athanor_id, cutoff, candidates) do
    Enum.reduce_while(candidates, {:ok, 0}, fn {path, generation}, {:ok, count} ->
      segments = String.split(path, "/")

      case adapter().delete(actor, object_key(generation, segments)) do
        result when result in [:ok, {:error, :not_found}] ->
          case drop_row(athanor_id, cutoff, path, generation) do
            {:ok, dropped} -> {:cont, {:ok, count + dropped}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, reason} ->
          Logger.warning(
            "[Arca.ObjectRevisions] a generation object could not be collected: " <>
              inspect(reason)
          )

          {:cont, {:ok, count}}
      end
    end)
  end

  # The row goes only while it is still collectable, read again under the
  # path row's lock.
  defp drop_row(athanor_id, cutoff, path, generation) do
    Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.drop_row", fn ->
      Arca.Repo.locking_transaction(fn ->
        _row = lock!(athanor_id, path)

        {count, _} =
          athanor_id
          |> collectable(cutoff)
          |> then(&from([g, _r] in &1, where: g.path == ^path and g.generation == ^generation))
          |> Arca.Repo.all()
          |> case do
            [] ->
              {0, nil}

            _still ->
              Arca.Repo.delete_all(
                from(g in ObjectGeneration,
                  where:
                    g.athanor_id == ^athanor_id and g.path == ^path and
                      g.generation == ^generation
                )
              )
          end

        count
      end)
    end)
  end

  # Objects under `objects/` no generation row names, dated by the
  # adapter's own last-modified time: a store that landed after its row
  # was collected. One the adapter cannot date is kept.
  defp orphans(actor, athanor_id, cutoff) do
    with {:ok, keys} <- Arca.Storage.list_prefix(actor, [@objects]) do
      named =
        Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.orphans", fn ->
          {:ok,
           from(g in ObjectGeneration,
             where: g.athanor_id == ^athanor_id,
             select: {g.generation, g.path}
           )
           |> Arca.Repo.all()
           |> MapSet.new()}
        end)

      with {:ok, named} <- named do
        {:ok,
         Enum.filter(keys, fn
           [@objects, number | rest] = object ->
             case Integer.parse(number) do
               {generation, ""} ->
                 not MapSet.member?(named, {generation, Enum.join(rest, "/")}) and
                   older?(actor, object, cutoff)

               _ ->
                 false
             end

           _other ->
             false
         end)}
      end
    end
  end

  defp older?(actor, object, cutoff) do
    case Arca.Storage.last_modified(actor, object) do
      {:ok, %DateTime{} = at} -> DateTime.before?(at, cutoff)
      _undated -> false
    end
  end

  defp delete_orphans(actor, orphans) do
    Enum.count(orphans, fn object ->
      adapter().delete(actor, object) in [:ok, {:error, :not_found}]
    end)
  end

  # ---------------------------------------------------------------------------
  # Rows
  # ---------------------------------------------------------------------------

  defp visible(athanor_id, key) do
    Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.visible", fn ->
      {:ok,
       Arca.Repo.one(
         from(r in ObjectRevision,
           where: r.athanor_id == ^athanor_id and r.path == ^key,
           where: not is_nil(r.settled_generation) and r.deleted == false
         )
       )}
    end)
  end

  defp settled_under(athanor_id, path, which) do
    prefix = key(path)

    Arca.Repo.Errors.with_db_rescue("Arca.ObjectRevisions.settled_under", fn ->
      query =
        from(r in ObjectRevision,
          where: r.athanor_id == ^athanor_id and not is_nil(r.settled_generation),
          where: r.deleted == false,
          order_by: [asc: r.path]
        )

      query = if which == :with_self, do: at_or_under(query, prefix), else: under(query, prefix)
      {:ok, Arca.Repo.all(query)}
    end)
  end

  # arca:db-raise-ok inside the caller's transaction or rescue
  defp visible_bytes!(athanor_id, key) do
    Arca.Repo.one(
      from(r in ObjectRevision,
        join: g in ObjectGeneration,
        on:
          g.athanor_id == r.athanor_id and g.path == r.path and
            g.generation == r.settled_generation,
        where: r.athanor_id == ^athanor_id and r.path == ^key and r.deleted == false,
        select: g.bytes
      )
    )
  end

  # arca:db-raise-ok inside the caller's transaction
  defp ensure_row!(athanor_id, key) do
    Arca.Repo.insert_all(
      ObjectRevision,
      [%{athanor_id: athanor_id, path: key, generation: 0, sources: "[]", deleted: false}],
      on_conflict: :nothing,
      conflict_target: [:athanor_id, :path]
    )
  end

  # The rows of the path's ancestors that exist, locked in path order
  # before the path's own. The order is global: every transaction that
  # locks object rows (a mark, a settlement, a prefix delete, retention)
  # takes them in ascending path order, ancestors, own, then those under
  # it, so no two of them wait on each other in a cycle.
  # arca:db-raise-ok inside the caller's transaction
  defp lock_ancestors!(athanor_id, path) do
    case ancestors(path) do
      [] ->
        :ok

      ancestors ->
        from(r in ObjectRevision,
          where: r.athanor_id == ^athanor_id and r.path in ^ancestors,
          order_by: [asc: r.path],
          select: r.path
        )
        |> Arca.QueryHelpers.for_update()
        |> Arca.Repo.all()

        :ok
    end
  end

  # The rows strictly under `key`, locked in path order after the path's
  # own (`settle!/4`).
  # arca:db-raise-ok inside the caller's transaction
  defp lock_under!(athanor_id, key) do
    from(r in ObjectRevision,
      where: r.athanor_id == ^athanor_id,
      order_by: [asc: r.path],
      select: r.path
    )
    |> strictly_under(key)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.all()

    :ok
  end

  # arca:db-raise-ok inside the caller's transaction
  defp lock!(athanor_id, key) do
    from(r in ObjectRevision, where: r.athanor_id == ^athanor_id and r.path == ^key)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
  end

  # arca:db-raise-ok inside the caller's transaction
  defp raise_generation!(athanor_id, key, generation),
    do: update_row!(athanor_id, key, generation: generation)

  # arca:db-raise-ok inside the caller's transaction
  defp update_row!(athanor_id, key, set) do
    {1, _} =
      from(r in ObjectRevision, where: r.athanor_id == ^athanor_id and r.path == ^key)
      |> Arca.Repo.update_all(set: set)

    :ok
  end

  # The row at `prefix` and every row under it; every row for the root
  # of the tree.
  defp at_or_under(query, ""), do: query
  defp at_or_under(query, @root), do: under(query, @root)

  defp at_or_under(query, prefix) do
    below = prefix <> "/"
    n = code_points(below)

    from(r in query,
      where: r.path == ^prefix or fragment("substr(?, 1, ?)", r.path, ^n) == ^below
    )
  end

  defp under(query, ""), do: query

  defp under(query, prefix), do: strictly_under(query, prefix)

  defp strictly_under(query, prefix) do
    below = prefix <> "/"
    n = code_points(below)
    from(r in query, where: fragment("substr(?, 1, ?)", r.path, ^n) == ^below)
  end

  # A prefix's length as SQL's `substr` counts it, in code points (a
  # grapheme can be several).
  defp code_points(text), do: text |> String.to_charlist() |> length()

  # ---------------------------------------------------------------------------
  # Keys
  # ---------------------------------------------------------------------------

  # A path's row key, once its segments are known safe: a traversal or
  # over-long segment raises here as the adapters' one validation site
  # does (`Prima.PathSafety`), before any row or object is asked for.
  defp key(path) do
    Prima.PathSafety.validate_segments!(path)
    Enum.join(path, "/")
  end

  defp relative(row_path, prefix), do: String.replace_prefix(row_path, prefix <> "/", "")

  defp ancestors([@root | rest]) do
    rest
    |> Enum.drop(-1)
    |> Enum.scan([@root], &(&2 ++ [&1]))
    |> Enum.map(&key/1)
  end

  defp ancestors(_path), do: []

  defp object_key(generation, path) when is_integer(generation),
    do: [@objects, Integer.to_string(generation) | path]

  # The configured tenant adapter, never the decorator the facade wraps
  # around it (`Arca.Overlay` refuses the same configuration).
  defp adapter do
    case Arca.Storage.configured_adapter() do
      Arca.Overlay ->
        raise ArgumentError,
              ":storage_adapter must name a real adapter (Local or S3) — " <>
                "Arca.Overlay is the decorator the facade already wraps around it"

      adapter ->
        adapter
    end
  end

  defp athanor(%Prima.Actor{athanor_id: athanor_id})
       when is_binary(athanor_id) and athanor_id != "",
       do: {:ok, athanor_id}

  defp athanor(%Prima.Actor{}), do: {:error, :no_athanor}

  defp backoff_ms(attempt) do
    ceiling = @append_backoff_base_ms * Integer.pow(2, attempt - 1)
    div(ceiling, 2) + :rand.uniform(div(ceiling, 2))
  end

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(nil), do: 0
end
