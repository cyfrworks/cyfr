# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Overlay do
  @moduledoc """
  The seeded roots the layout table marks `:overlay` — `components/` and
  `aqua/` — as the athanor's own tree, filled from the seed tree, the
  shipped default.

  An ADAPTER DECORATOR, not a facade layer: this module implements the
  `Arca.Storage` behaviour, wrapping the configured tenant adapter. Every
  read answers from the athanor's tree alone; the seed tree — install
  media, read-only, on local disk — is where shipped units are copied
  FROM: at provisioning (`materialize_shipped/2`), and when a person
  pulls a shipped version or restores a unit to what ships
  (`pull_shipped/2`). A release that ships newer versions changes nothing
  in an athanor; the newer units read as `:available` until pulled.

  ## Shadow units — the domain's grammar, not a depth

  Where a root's units sit and how they are shaped is the answer of its
  `Arca.Storage.UnitLocator` (`Arca.Storage.locate/1`): a component
  version directory is a directory unit sentinel'd by its manifest, an
  aqua agent a file unit, an aqua skill a directory unit sentinel'd by
  `SKILL.md`. The grammar is pure — shape is known before any file
  exists — so nothing here ever probes the tree to learn what kind of
  unit a path belongs to.

  ## Publication — the row, never the objects

  A unit is published by its `Arca.StorageUnits` row, and `commit_unit/4`
  — the one way a unit lands, for scaffold, fork, publish, OCI pull and
  the shipped copy alike — runs the write protocol over it:

    1. register the unit's draft under a fresh writer token, and create
       the in-progress marker of a revision-unique staging prefix
       (`Arca.Storage.UnitLocator.revision_prefix/2`) before any upload;
    2. stage the revision's objects under that prefix and validate them —
       every object listed, every object read back against its digest —
       outside any transaction;
    3. commit: one short transaction compares the pointer and the writer
       token, moves the pointer and appends one journal row. The token is
       kept: the writer holds the unit's draft through step 4;
    4. release, under the fence: re-read the row — still this writer's,
       still naming this revision — and give the draft back in one short
       transaction that again requires the pointer to name this revision
       and the token to be this writer's
       (`Arca.StorageUnits.release_served/4`); then mark the projection
       generation ready.

  Nothing moves: the committed revision is served from the prefix it was
  staged under, which stays as it was committed, and readers resolve the
  row to find it. The previous revision's prefix is the collector's once
  the pointer has left it (`Arca.StorageGC`), and stays through the
  collector's grace for a reader that resolved the row before the commit.

  ## The fence

  The draft is the unit's write lease. While a writer holds it no other
  commit lands, no other draft registers and no removal begins, so the
  pointer cannot move under a release and a revision cannot be deleted
  under one: a second writer is refused `{:error, :stale_writer}` at step
  1 and asks again. A removal takes the same lease
  (`Arca.StorageUnits.stamped_retire/4`): its row is `retiring` under the
  deleter's token while the retired revision's prefix is deleted, a
  commit against it is refused, and the row is `retired` only once the
  delete has returned. A repair takes the lease too, and only when it is
  free.

  On one node the lease is taken and held under one node-local lock on
  the unit as well: a writer holds it from its registration to its
  release, a removal from its retirement to its retired row, a repair
  from its registration to its release, and a lease take finding the
  lock held answers `{:error, :stale_writer}` at once rather than wait.
  So on one node nothing takes a draft, however old its holder's token,
  while the holder is inside its publication or removal; a stalled
  holder's token can be taken only by another member or once the holder
  is gone. Across members the lease alone is the fence, and a member
  stalled past the draft's lifetime between its row read and its store
  request changes nothing a reader keeps: a writer makes no store request
  after its commit, so a stalled writer's release is refused and its
  staged revision is the collector's; a remover's one request after its
  retirement names the revision it retired, which no successor's commit
  can name again. Every step that touches a prefix reads the row as the
  holder's first, and the release is refused when the token was taken
  meanwhile, so a stall is never reported as success.

  A crash before step 3 publishes nothing: readers keep the previous
  revision, or no unit. A writer that dies between steps 3 and 4 has
  published: readers resolve the row and read its revision; the draft it
  holds is given back by `repair_unit/2` once the token has outlived the
  draft's lifetime, and the generation the commit stamped is marked ready
  then. `repair_unit/2` never moves or invents an object: a committed
  revision whose prefix lacks its completion object is reported, and left.

  ## Where a unit's bytes are

  A reader resolves the row once per operation (`Arca.StorageUnits.current/3`)
  and reads the object under the committed revision's prefix
  (`Arca.Storage.UnitLocator.in_revision/3`). A unit whose row is not
  committed — never committed, being removed, retired — reads
  `{:error, :not_found}` at every path, whatever bytes stand under its
  staging: a complete object set no row names is nothing a reader sees,
  and hand-laid bytes are never a unit. A unit reads complete when its
  row is committed and the revision's completion object — a directory
  unit's sentinel, a file unit's file — is in the prefix. There is no
  lock: a plain write into a unit is an edit of the committed revision's
  objects in place, last writer wins per object, a commit replaces the
  unit whole with a new revision, and `update/3` is the read-modify-write
  that loses neither (`c:Arca.Storage.put_if_match/4`). A plain write
  where no committed row names the unit lands nowhere — refused
  `{:error, :no_unit}` — except at the completion object of a unit its
  grammar lets a write create
  (`c:Arca.Storage.UnitLocator.creates_by_write?/1`: a role, the soul, a
  scroll), where the write is the unit's one-object commit. A pin
  (`Arca.StorageGC.pin/4`) keeps a revision's prefix from collection; the
  current revision's objects can still be edited in place, as the served
  objects could before.

  A revision committed before units were served from their prefixes was
  moved to the unit's own path and its prefix removed. Such a revision is
  read where it is until it is adopted: the first edit of the unit,
  `repair_unit/2` and the collector's audit commit it as a revision of
  its own — its objects staged under a new prefix from the unit's own
  path, the pointer moved to it under the lease like any publication's —
  so two adopters never share a prefix and a stalled one is refused at
  its commit; nothing is ever written at a unit's own path again. The
  unit's own path is cleared once the adopting, or any later, publication
  is released, unless a live pin names the revision it served, and then
  the collector clears it once the pin is gone (`collect_unit_path/2`); a
  removal leaves it to the collector the same way.

  ## Whose unit it is

  A unit the seed ships at the same path is a shipped copy, whatever its
  bytes: `unit_status/2` answers `:shipped` for a complete one the
  athanor holds and `:available` for one it lacks. A complete unit the
  seed does not ship is the athanor's own (`:own`). Whether a copy has
  been edited is a byte question — `diff_unit/2` — asked by the surfaces
  that show it, never recorded.

  ## Deletes

  A shipped copy is restored, never deleted: `delete/2` and
  `delete_tree/2` at a shipped unit refuse as `{:error, :bundled}`, and
  `drop_unit/2` says the same. A delete inside a shipped copy is an
  edit. The athanor's own units delete plainly, and a delete AT a unit
  takes the unit's draft and moves its row to `retiring` first — a unit
  that never had a row gets one — deletes the retired revision's prefix
  and whatever an earlier revision left at the unit's own path while it
  holds the draft, and retires the row last; the unit's other prefixes
  are the collector's. While another writer's draft is live the delete is
  refused `{:error, :stale_writer}` and deletes nothing. A delete the
  store refuses retires the row all the same — no reader finds the unit,
  the caller is told, and the bytes are the collector's.

  ## What the root's projection is told

  Every change of a unit's bytes stamps a generation on the unit for the
  root's domain projection (`Arca.StorageProjectionChanges`), not ready
  while the change is made and ready once it is: a commit once its draft
  is released, a repair that releases a dead writer's draft, a delete at
  a unit around the delete (a tombstone, ready once the delete has
  returned whatever it answered), and a plain edit inside a
  unit — a put, an append, a conditional put, a delete or a tree delete
  or replacement below the unit's root — with a pending generation before
  its write and a newer, ready one after it. An edit whose pending mark
  cannot be written is refused before any byte moves. The internal-write
  scope and the staging areas stamp nothing: their writes are a commit's,
  which stamps its own, or bookkeeping no reader sees.

  ## The internal-write scope

  Shipped copies and unit commits write back through the `Arca` facade —
  so every copied byte passes the same usage accounting as any other
  write — inside `with_internal_writes/1`, a lexical, process-local scope
  that exempts exactly those writes from the `:bundled` refusal, the
  above-unit tree-delete refusal and the reserved-root gate
  (`Arca.Storage.reserved_roots/0`). The exemption cannot be reached by
  constructing any context shape; the internal context's
  `user_id: "_overlay"` is attribution only.
  """

  @behaviour Arca.Storage

  require Logger

  alias Arca.Storage.UnitLocator
  alias Arca.{StorageProjectionChanges, StorageUnits}

  @internal_writes_key {__MODULE__, :internal_writes}
  @claim_key {__MODULE__, :claim}

  @typedoc """
  What one shadow unit holds: `:available` (the seed ships it, the athanor
  holds no complete copy — pull it), `:shipped` (the athanor's complete
  copy of a unit the seed ships), `:own` (the athanor's content, no seed
  counterpart), `:absent` (neither side).
  """
  @type unit_status :: :available | :shipped | :own | :absent

  # ---------------------------------------------------------------------------
  # The internal-write scope
  # ---------------------------------------------------------------------------

  @doc """
  Run `fun` with this process exempt from the `:bundled` delete refusal,
  the above-unit tree-delete refusal and the reserved-root write gate —
  the shipped copy's and the unit commit's own scope, lexical and
  process-local (`try/after`), so no context shape can carry the
  exemption. Per-process by design: work handed to another process does
  not inherit it and refuses loudly.
  """
  @spec with_internal_writes((-> result)) :: result when result: term()
  def with_internal_writes(fun) when is_function(fun, 0) do
    prev = Process.put(@internal_writes_key, true)

    try do
      fun.()
    after
      if prev, do: :ok, else: Process.delete(@internal_writes_key)
    end
  end

  @doc false
  @spec internal_writes?() :: boolean()
  def internal_writes?, do: Process.get(@internal_writes_key, false)

  @doc """
  Run `fun` with every unit removal it makes held to `claim` — a
  provisioning attempt's claim and the member slot it was taken under,
  `%{owner: owner, fence: fence, slot: slot}`: the unit's retirement
  verifies that slot and holds that claim in its own transaction
  (`Arca.StorageUnits.stamped_retire/4`), and a removal by an attempt
  that lost either retires nothing and deletes nothing,
  `{:error, :not_owner}`. How an attempt's publish cleans up the unit it
  committed when its row is refused, through the `Arca` facade's own
  delete and its gates. Lexical and process-local, as
  `with_internal_writes/1` is: work handed to another process does not
  carry the claim. `nil` runs `fun` with no claim.
  """
  @spec with_claim(map() | nil, (-> result)) :: result when result: term()
  def with_claim(nil, fun) when is_function(fun, 0), do: fun.()

  def with_claim(%{owner: owner, fence: fence, slot: _} = claim, fun)
      when is_binary(owner) and is_integer(fence) and is_function(fun, 0) do
    prev = Process.put(@claim_key, claim)

    try do
      fun.()
    after
      if prev, do: Process.put(@claim_key, prev), else: Process.delete(@claim_key)
    end
  end

  # The claim a removal in this process names, if `with_claim/2` set one.
  defp retire_opts do
    case Process.get(@claim_key) do
      nil -> []
      claim -> [claim: claim]
    end
  end

  # ---------------------------------------------------------------------------
  # Where a unit's bytes are
  # ---------------------------------------------------------------------------

  # The committed revision a reader of the unit resolves the row to, once
  # per operation. A unit whose row is not committed has nothing a reader
  # may see, `{:error, :not_found}`.
  defp revision_of(actor, loc) do
    {root, key} = UnitLocator.unit_key(unit_of(loc))

    case StorageUnits.current(actor, root, key) do
      {:ok, %{current_revision: revision}} -> {:ok, revision}
      {:error, _} = error -> error
    end
  end

  # One read at a path, answered from the committed revision's prefix. A
  # miss there for a revision that was served at the unit's own path
  # before this shape (`legacy?/3`) is answered from that path, until the
  # revision has been moved back into its prefix.
  defp read(actor, path, reader) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        reader.(path)

      loc ->
        if marker_name?(loc, path) do
          {:error, :not_found}
        else
          with {:ok, revision} <- revision_of(actor, loc) do
            case reader.(UnitLocator.in_revision(loc, revision, path)) do
              {:error, :not_found} = miss ->
                if legacy?(actor, loc, revision), do: reader.(path), else: miss

              answer ->
                answer
            end
          end
        end
    end
  end

  # The one name inside a directory unit no object carries: the prefix's
  # in-progress marker, at the unit's top, where no commit stages an
  # object of that name (`stage/4`). A read there misses and a write there
  # is refused, so the marker is never read or written as content.
  defp marker_name?({:dir, unit, _sentinel}, path),
    do: path == unit ++ [UnitLocator.marker_name()]

  defp marker_name?(_loc, _path), do: false

  # Where a write inside a unit lands: the object under the committed
  # revision's prefix. A revision still at the unit's own path is moved
  # into its prefix first, under the lease, so no write ever lands at a
  # unit's own path; a unit with no committed revision has nothing to
  # edit, `{:error, :not_found}`. Inside the internal-write scope a path
  # is its own: those writes are a commit's, under the staging area.
  defp edit_target(actor, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:ok, path}

      loc ->
        cond do
          internal_writes?() ->
            {:ok, path}

          marker_name?(loc, path) ->
            {:error, :reserved_name}

          true ->
            with {:ok, revision} <- revision_of(actor, loc),
                 {:ok, revision} <- adopted_revision(actor, loc, revision) do
              {:ok, UnitLocator.in_revision(loc, revision, path)}
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Arca.Storage callbacks — reads answer from the athanor's tree alone.
  # ---------------------------------------------------------------------------

  @impl true
  def get(%Prima.Actor{} = actor, path), do: read(actor, path, &tenant().get(actor, &1))

  @impl true
  def put(%Prima.Actor{} = actor, path, content) do
    with :ok <- writable(path) do
      case edit_target(actor, path) do
        {:ok, target} -> edit(actor, path, fn -> tenant().put(actor, target, content) end)
        {:error, :not_found} -> create_by_write(actor, path, content)
        {:error, _} = refused -> refused
      end
    end
  end

  @impl true
  def append(%Prima.Actor{} = actor, path, content) do
    with :ok <- writable(path) do
      case edit_target(actor, path) do
        {:ok, target} -> edit(actor, path, fn -> tenant().append(actor, target, content) end)
        {:error, :not_found} -> create_by_write(actor, path, content)
        {:error, _} = refused -> refused
      end
    end
  end

  # A plain write inside a unit no committed row names. At the unit's
  # completion object — a file unit's file, a directory unit's sentinel —
  # of a unit its grammar lets a write create
  # (`Arca.Storage.UnitLocator.creates_by_write?/1`: a role, the soul, a
  # scroll), it is the unit's one-object commit, so the unit is created by
  # writing its own file. Anywhere else, or for a unit its verbs create (a
  # component), it is refused `{:error, :no_unit}`: nothing lands inside a
  # unit before the unit exists. The facade accounted the written bytes
  # as a put's and the commit accounted its staged objects as a commit's,
  # so the counters are dropped to be walked true again.
  defp create_by_write(actor, path, content) do
    loc = Arca.Storage.locate(path)
    unit = unit_of(loc)

    if path == completion_of(loc) and UnitLocator.creates_by_write?(unit) do
      source =
        case loc do
          {:file, ^unit} -> {:files, [{[], content}]}
          {:dir, ^unit, sentinel} -> {:files, [{[sentinel], content}]}
        end

      with {:ok, _written} <- commit_unit(actor, unit, source, cap: :exempt) do
        Arca.Usage.invalidate(actor)
        :ok
      end
    else
      {:error, :no_unit}
    end
  end

  # A conditional write or a tree replacement inside a unit no committed
  # row names has nothing to land in.
  defp no_unit({:error, :not_found}), do: {:error, :no_unit}
  defp no_unit(answer), do: answer

  @impl true
  def delete(%Prima.Actor{} = actor, path) do
    with :ok <- deletable(path) do
      case at_unit(path) do
        nil ->
          with {:ok, target} <- edit_target(actor, path),
               do: edit(actor, path, fn -> tenant().delete(actor, target) end)

        unit ->
          removal(actor, unit)
      end
    end
  end

  @impl true
  def delete_tree(%Prima.Actor{} = actor, path) do
    with :ok <- tree_deletable(actor, path),
         :ok <- deletable(path) do
      case {at_unit(path), Arca.Storage.locate(path)} do
        {unit, _loc} when is_list(unit) ->
          removal(actor, unit)

        {nil, :above_unit} ->
          with :ok <- clear_units_beneath(actor, path),
               do: edit(actor, path, fn -> tenant().delete_tree(actor, path) end)

        {nil, _inside_or_outside} ->
          with {:ok, target} <- edit_target(actor, path),
               do: edit(actor, path, fn -> tenant().delete_tree(actor, target) end)
      end
    end
  end

  # A delete AT a unit is the unit's removal, so its row goes first: under
  # the unit's node-local lock it takes the unit's draft — making the row
  # when the unit never had one, so bytes no row names are removed under
  # the same lease a first publication must take — and moves to
  # `retiring`, and a reader never finds a committed pointer over a
  # revision being deleted. The retired revision's prefix, and whatever an
  # earlier revision left at the unit's own path, are deleted while it
  # holds the lock and the lease, the row re-read as the deleter's before
  # and after, so no commit lands under the delete and no successor's
  # revision is deleted by it: a successor's revision is another prefix,
  # and the unit's other prefixes are the collector's. The row is retired
  # last. Another writer's live draft, or a holder of the lock, refuses
  # the removal as `{:error, :stale_writer}`, with nothing deleted. Inside
  # `with_claim/2` the retirement names the attempt's claim
  # (`Arca.StorageUnits.stamped_retire/4`), and a refusal deletes nothing.
  # A unit already retired is taken the same way: what a removal that
  # died or was refused left behind is cleared under the lease too. The
  # root's projection is told the unit is going — a tombstone, pending
  # until the delete returns and ready then whatever it answered, since
  # the row is retired either way and no reader finds the unit; a refused
  # delete leaves bytes the collector takes, and the caller is told.
  defp removal(actor, unit) do
    {root, key} = UnitLocator.unit_key(unit)

    deleted =
      fenced(actor, unit, fn ->
        case StorageUnits.stamped_retire(actor, root, key, retire_opts()) do
          {:retiring, generation, token} -> retire_held(actor, unit, token, generation)
          {:error, _} = error -> error
        end
      end)

    # The tombstone is marked outside the fence, as a release marks.
    case deleted do
      {:deleted, generation, answer} ->
        actor |> mark_ready(root, key, generation, nil) |> report_readiness(unit, generation)

        with {:error, reason} <- answer do
          Logger.warning(
            "[Arca.Overlay] #{Enum.join(unit, "/")} is retired; its revision's bytes could " <>
              "not be deleted (#{inspect(reason)}) and are the collector's"
          )

          answer
        end

      {:error, _} = refused ->
        refused
    end
  end

  # The removal's steps under the fence, each made only while the row is
  # still this deleter's `retiring` row: the retired revision's prefix is
  # deleted, then what an earlier revision left at the unit's own path,
  # the row read again, and the row retired. A token taken meanwhile —
  # the deleter's lease given back by the collector, or taken by another
  # member — ends the removal as `{:error, :stale_writer}` with nothing
  # further deleted: what the taker staged is the taker's. The row is
  # retired whatever the delete answered: a refused delete leaves bytes a
  # later drop clears, never a unit a reader sees.
  defp retire_held(actor, unit, token, generation) do
    {root, key} = UnitLocator.unit_key(unit)

    with {:ok, row} <- retiring(actor, root, key, token),
         answer = delete_revision(actor, unit, row.current_revision),
         {:ok, _row} <- retiring(actor, root, key, token),
         :ok <- StorageUnits.finish_retire(actor, root, key, token) do
      {:deleted, generation, answer}
    else
      {:error, _} = lost ->
        Logger.error(
          "[Arca.Overlay] the removal of #{Enum.join(unit, "/")} lost the unit's lease " <>
            "(#{inspect(lost)}); nothing further of it is deleted"
        )

        {:error, :stale_writer}
    end
  end

  # What a removal deletes: the retired revision's prefix (through the
  # facade, so its bytes leave the athanor's accounting), and the unit's
  # own path, where a revision served before this shape may still stand.
  # A row that never named a revision has only the latter. A revision a
  # live reader has pinned (`Arca.StorageGC.pin/4`) is left to the
  # collector, which takes it once the pin is gone: the pin keeps the
  # bytes the reader resolved, and the retired row keeps every new reader
  # out.
  defp delete_revision(actor, unit, revision) do
    internal = internal_actor(actor)
    pinned? = is_binary(revision) and Arca.StorageGC.pinned?(actor, unit, revision)

    prefix =
      cond do
        is_nil(revision) or pinned? ->
          :ok

        true ->
          with_internal_writes(fn ->
            Arca.delete_tree(internal, UnitLocator.revision_prefix(unit, revision))
          end)
      end

    # The unit's own path holds the retired revision when it was served
    # there before this shape: a pin keeps it as it keeps the prefix.
    with :ok <- prefix, false <- pinned? do
      case tenant().delete_tree(actor, unit) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, _} = error -> error
      end
    else
      true -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Delete what a revision served at the unit's own path before units were
  served from their prefixes left there, once nothing reads it: when the
  unit's row is retired or never committed, or committed with its
  revision's completion object in its prefix, and no live pin names a
  revision of the unit (`Arca.StorageGC.pinned_unit?/2`). The collector's
  call, made under the unit's node-local lock. `{:ok, :collected}` when
  it went or nothing stood there, `{:ok, :kept}` when a reader may still
  find it there, `{:error, :stale_writer}` while a writer holds the unit,
  `{:error, :not_a_unit}` for a path that is no unit.
  """
  @spec collect_unit_path(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, :collected | :kept} | {:error, :stale_writer | :not_a_unit | term()}
  def collect_unit_path(%Prima.Actor{} = actor, unit) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_a_unit}

      loc ->
        if unit_of(loc) == unit,
          do: collect_at_unit(actor, loc),
          else: {:error, :not_a_unit}
    end
  end

  defp collect_at_unit(actor, loc) do
    unit = unit_of(loc)

    fenced(actor, unit, fn ->
      with {:ok, false} <- read_at_unit_path?(actor, loc),
           false <- Arca.StorageGC.pinned_unit?(actor, unit) do
        case tenant().delete_tree(actor, unit) do
          :ok -> {:ok, :collected}
          {:error, :not_found} -> {:ok, :collected}
          {:error, _} = error -> error
        end
      else
        {:ok, true} -> {:ok, :kept}
        true -> {:ok, :kept}
        {:error, _} = error -> error
      end
    end)
  end

  # Whether the unit's own path is where its readers read now: a committed
  # row whose revision has not been adopted. A row that is not committed
  # has no reader there.
  defp read_at_unit_path?(actor, loc) do
    {root, key} = UnitLocator.unit_key(unit_of(loc))

    case StorageUnits.current(actor, root, key) do
      {:ok, %{current_revision: revision}} -> {:ok, legacy?(actor, loc, revision)}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  # A tree delete above the units inside the internal-write scope clears
  # every committed unit beneath it as a removal would, so each row is
  # retired with its revision; outside that scope `tree_deletable/2` has
  # refused the path while a unit stands beneath it.
  defp clear_units_beneath(actor, path) do
    with {:ok, units} <- units_beneath(actor, path) do
      Enum.reduce_while(units, :ok, fn unit, :ok ->
        case removal(actor, unit) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # The committed units under `path`, from the rows.
  defp units_beneath(%Prima.Actor{} = actor, [root | _] = path) do
    with {:ok, pointers} <- StorageUnits.current_under(actor, root) do
      units =
        for {key, _pointer} <- pointers,
            unit = UnitLocator.unit_path(root, key),
            List.starts_with?(unit, path),
            do: unit

      {:ok, units}
    end
  end

  defp retiring(actor, root, key, token) do
    case StorageUnits.held(actor, root, key, token) do
      {:ok, %{state: "retiring"}} = held -> held
      {:ok, _not_retiring} -> {:error, :stale_writer}
      {:error, _} = lost -> lost
    end
  end

  # A plain edit inside a unit: a pending generation before the write and
  # a newer, ready one after it, whatever the write answered — the bytes
  # are what they are, and the projection derives from them. An edit whose
  # pending mark cannot be written moves no byte: the projection would
  # never learn of it.
  defp edit(actor, path, write) do
    case edited_unit(path) do
      nil ->
        write.()

      unit ->
        {root, key} = UnitLocator.unit_key(unit)

        with {:ok, pending} <- StorageProjectionChanges.begin_edit(actor, root, key) do
          written = write.()

          case StorageProjectionChanges.finish_edit(actor, root, key, pending) do
            {:ok, _generation_or_covered} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[Arca.Overlay] #{Enum.join(unit, "/")} was written and its generation " <>
                  "#{pending} could not be marked ready (#{inspect(reason)}); the settle " <>
                  "marks it once it is stale"
              )
          end

          written
        end
    end
  end

  # The unit a plain write lands inside: at a file unit's file, or below a
  # directory unit's root. Not inside the internal-write scope, whose
  # writes are a commit's, a repair's or bookkeeping; never under a
  # staging area, which locates above the units.
  defp edited_unit(path) do
    if internal_writes?() do
      nil
    else
      case Arca.Storage.locate(path) do
        {:file, ^path} -> path
        {:dir, unit, _sentinel} when unit != path -> unit
        _at_above_below_or_outside -> nil
      end
    end
  end

  # Whether the generation a publication, a repair or a removal stamped is
  # ready now: `:ok`, or `:overtaken` when a later change of the unit — a
  # plain edit, whose writer marks its own generation — holds the row.
  # Under the fence no other publication or removal can overtake a held
  # unit's generation; the answer is never read as success, and every
  # caller reports it (`report_readiness/3`).
  defp mark_ready(actor, root, key, generation, revision) do
    case StorageProjectionChanges.mark_ready(actor, root, key, generation, revision) do
      :ok -> :ok
      {:error, :stale_generation} -> :overtaken
      {:error, _reason} = refused -> refused
    end
  end

  defp report_readiness(:ok, _unit, _generation), do: :ok

  defp report_readiness(:overtaken, unit, generation) do
    Logger.info(
      "[Arca.Overlay] #{Enum.join(unit, "/")} generation #{generation} was overtaken by a " <>
        "later change of the unit, whose writer marks it ready"
    )
  end

  defp report_readiness({:error, reason}, unit, generation) do
    Logger.warning(
      "[Arca.Overlay] #{Enum.join(unit, "/")} generation #{generation} could not be marked " <>
        "ready (#{inspect(reason)}); the settle marks it once it is stale"
    )
  end

  # The node-local half of the fence: one publication, repair or removal
  # of a unit at a time on this node, from its lease take to its release.
  # The lock is never waited for: a unit whose lock is held is another
  # writer's, `{:error, :stale_writer}`, the answer the row gives for a
  # live draft, so a holder stalled inside its section — a token even the
  # lease would let go of — keeps the unit against every taker on this
  # node until it is done or dead. The lock of a process that dies is
  # released with it; no transaction waits on it.
  defp fenced(%Prima.Actor{athanor_id: athanor}, unit, fun) when is_function(fun, 0) do
    id = {{__MODULE__, athanor, unit}, self()}

    if :global.set_lock(id, [node()], 0) do
      try do
        fun.()
      after
        :global.del_lock(id, [node()])
      end
    else
      {:error, :stale_writer}
    end
  end

  defp at_unit(path) do
    case Arca.Storage.locate(path) do
      {:file, ^path} -> path
      {:dir, ^path, _sentinel} -> path
      _inside_above_or_outside -> nil
    end
  end

  # Tree deletion above units is allowed only when no committed unit
  # stands beneath the path, by the rows; otherwise it returns
  # `{:error, :above_unit}`: a populated subtree is cleared one unit at a
  # time, so each unit's row is retired with it. The check and the
  # deletion are not atomic with a new unit commit. The internal-write
  # scope clears the units beneath itself (`clear_units_beneath/2`).
  defp tree_deletable(%Prima.Actor{} = actor, path) do
    if not internal_writes?() and Arca.Storage.locate(path) == :above_unit do
      case units_beneath(actor, path) do
        {:ok, []} -> :ok
        {:ok, _units} -> {:error, :above_unit}
        {:error, _} = error -> error
      end
    else
      :ok
    end
  end

  @impl true
  def exists?(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        tenant().exists?(actor, path)

      loc ->
        case revision_of(actor, loc) do
          {:ok, revision} ->
            not marker_name?(loc, path) and
              (tenant().exists?(actor, UnitLocator.in_revision(loc, revision, path)) or
                 (legacy?(actor, loc, revision) and tenant().exists?(actor, path)))

          {:error, _} ->
            false
        end
    end
  end

  # The conditional writes and the versioned read land where the
  # unconditional ones land, under the same write shapes; the prefix
  # listing passes through. The staging registry's own calls go straight
  # to the tenant adapter (`Arca.Storage.put_if_none_match/3` and its
  # kin), which is why nothing here filters staging out of `list_prefix/2`
  # as `list_recursive/2` does: a key listing of a staging area is exactly
  # what that callback is for.

  @impl true
  def put_if_none_match(%Prima.Actor{} = actor, path, content) do
    with :ok <- writable(path),
         {:ok, target} <- no_unit(edit_target(actor, path)),
         do: tenant().put_if_none_match(actor, target, content)
  end

  @impl true
  def put_if_match(%Prima.Actor{} = actor, path, content, precondition) do
    with :ok <- writable(path),
         {:ok, target} <- no_unit(edit_target(actor, path)),
         do:
           edit(actor, path, fn ->
             tenant().put_if_match(actor, target, content, precondition)
           end)
  end

  @impl true
  def get_for_update(%Prima.Actor{} = actor, path),
    do: read(actor, path, &tenant().get_for_update(actor, &1))

  @impl true
  def list_prefix(%Prima.Actor{} = actor, prefix),
    do: tenant().list_prefix(actor, prefix)

  # Inside a directory unit or outside the units; the tenant adapter
  # decides whether it can swap at all.
  @impl true
  def replace_tree(%Prima.Actor{} = actor, path, files) do
    with :ok <- replaceable(path),
         {:ok, target} <- no_unit(edit_target(actor, path)) do
      adapter = tenant()

      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :replace_tree, 3),
        do: edit(actor, path, fn -> adapter.replace_tree(actor, target, files) end),
        else: {:error, :atomic_replace_unsupported}
    end
  end

  # Bytes held. Above the units, and outside them, the tenant's tree
  # there — the staging areas included, since every revision a unit holds
  # is bytes the athanor holds. At or inside a unit, the object or subtree
  # readers read, from the revision the row names: what a file's size is.
  @impl true
  def usage(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        tenant().usage(actor, path)

      loc ->
        case revision_of(actor, loc) do
          {:ok, revision} -> tenant().usage(actor, source_of(actor, loc, revision, path))
          {:error, :not_found} -> tenant().usage(actor, path)
          {:error, _} = error -> error
        end
    end
  end

  @impl true
  def ensure_dir(%Prima.Actor{} = actor, path),
    do: tenant().ensure_dir(actor, path)

  @impl true
  def serve_to_conn(conn, %Prima.Actor{} = actor, path, opts),
    do: read(actor, path, &tenant().serve_to_conn(conn, actor, &1, opts))

  # A root's staging area is this module's bookkeeping, never the
  # athanor's content: a listing made from above it does not show it, and
  # shows the committed units in its place, from the rows. A listing of
  # the area itself answers plainly — that is how a staged revision is
  # validated and audited. `usage/2` still counts it: a unit's bytes are
  # the bytes the athanor holds.
  @impl true
  def list_typed(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        tenant().list_typed(actor, path)

      :above_unit ->
        if UnitLocator.staging?(path),
          do: tenant().list_typed(actor, path),
          else: typed_above_units(actor, path)

      loc ->
        case revision_of(actor, loc) do
          {:ok, revision} ->
            with {:ok, entries} <-
                   tenant().list_typed(actor, source_of(actor, loc, revision, path)),
                 do: {:ok, without_marker(loc, path, entries)}

          # A unit no committed row names lists as a missing directory does.
          {:error, :not_found} ->
            {:ok, []}

          {:error, _} = error ->
            error
        end
    end
  end

  # The in-progress marker is the prefix's own, never an entry of the
  # unit: it stands at the top of a directory unit's prefix, where no
  # commit stages an object of its name (`stage/4`).
  defp without_marker({:dir, unit, _sentinel}, path, entries) when path == unit,
    do: Enum.reject(entries, &(&1 == {UnitLocator.marker_name(), :file}))

  defp without_marker(_loc, _path, entries), do: entries

  @impl true
  def list_recursive(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        tenant().list_recursive(actor, path)

      :above_unit ->
        if UnitLocator.staging?(path),
          do: tenant().list_recursive(actor, path),
          else: leaves_above_units(actor, path)

      loc ->
        case revision_of(actor, loc) do
          {:ok, revision} ->
            if legacy?(actor, loc, revision) do
              tenant().list_recursive(actor, path)
            else
              with {:ok, keys} <-
                     tenant().list_recursive(actor, UnitLocator.in_revision(loc, revision, path)),
                   do: {:ok, unit_paths(loc, revision, keys)}
            end

          {:error, :not_found} ->
            {:ok, []}

          {:error, _} = error ->
            error
        end
    end
  end

  # A listing above the units: the tenant's own entries there — the
  # staging area left out, and the directories of units whose row is not
  # committed, which are nothing a reader sees — and the committed units
  # beneath the path, from the rows, each as the next segment of its path.
  defp typed_above_units(actor, [root | _] = path) do
    with {:ok, entries} <- tenant().list_typed(actor, path),
         {:ok, pointers} <- StorageUnits.current_under(actor, root) do
      committed = for {key, _} <- pointers, do: UnitLocator.unit_path(root, key)
      depth = length(path)

      synthesized =
        for unit <- committed, List.starts_with?(unit, path), do: typed_entry(unit, depth)

      kept =
        Enum.reject(entries, fn {name, _kind} ->
          child = path ++ [name]

          UnitLocator.staging?(child) or
            (leaf_loc(child) != nil and not Enum.any?(committed, &List.starts_with?(&1, child)))
        end)

      {:ok, Enum.uniq_by(kept ++ synthesized, &elem(&1, 0))}
    end
  end

  # The entry a unit shows at `depth` segments above its leaf: a directory
  # while the unit's path goes on, the unit's own kind at its last
  # segment.
  defp typed_entry(unit, depth) do
    name = Enum.at(unit, depth)

    if length(unit) > depth + 1 do
      {name, :dir}
    else
      case Arca.Storage.locate(unit) do
        {:file, ^unit} -> {name, :file}
        _dir -> {name, :dir}
      end
    end
  end

  # Every leaf under a path above the units: the tenant's leaves there
  # that belong to no unit, and each committed unit's leaves, read from
  # its revision's prefix and spelled as the unit's own paths.
  defp leaves_above_units(actor, [root | _] = path) do
    with {:ok, leaves} <- tenant().list_recursive(actor, path),
         {:ok, pointers} <- StorageUnits.current_under(actor, root) do
      plain = Enum.reject(leaves, &(UnitLocator.staging?(&1) or leaf_loc(&1) != nil))

      Enum.reduce_while(pointers, {:ok, plain}, fn {key, %{current_revision: revision}},
                                                   {:ok, acc} ->
        unit = UnitLocator.unit_path(root, key)

        if List.starts_with?(unit, path) do
          case unit_leaves(actor, unit, revision) do
            {:ok, unit_leaves} -> {:cont, {:ok, acc ++ unit_leaves}}
            {:error, _} = error -> {:halt, error}
          end
        else
          {:cont, {:ok, acc}}
        end
      end)
    end
  end

  # Every leaf of one committed unit as the unit's own paths: a file unit's
  # one object when it is there, a directory unit's prefix listed and
  # spelled back; a revision still at the unit's own path, listed there.
  defp unit_leaves(actor, unit, revision) do
    case Arca.Storage.locate(unit) do
      {:file, ^unit} = loc ->
        cond do
          tenant().exists?(actor, UnitLocator.in_revision(loc, revision, unit)) -> {:ok, [unit]}
          legacy?(actor, loc, revision) -> {:ok, [unit]}
          true -> {:ok, []}
        end

      {:dir, ^unit, _sentinel} = loc ->
        if legacy?(actor, loc, revision) do
          tenant().list_recursive(actor, unit)
        else
          with {:ok, keys} <-
                 tenant().list_recursive(actor, UnitLocator.in_revision(loc, revision, unit)),
               do: {:ok, unit_paths(loc, revision, keys)}
        end
    end
  end

  # Where a unit's objects are listed and read whole from: the committed
  # revision's prefix once its completion object is there; the unit's own
  # path while a revision served there before this shape has not been
  # adopted — an adoption that stops leaves it whole, and no reader is
  # answered from a prefix the pointer's revision is not complete in; the
  # prefix otherwise, so a damaged revision reads as what its prefix
  # holds.
  defp source_of(actor, loc, revision, path) do
    if legacy?(actor, loc, revision),
      do: path,
      else: UnitLocator.in_revision(loc, revision, path)
  end

  # The keys under a revision's prefix as the unit's own paths, the
  # prefix's in-progress marker left out.
  defp unit_paths(loc, revision, keys) do
    marker = UnitLocator.marker_path(unit_of(loc), revision)
    for key <- keys, key != marker, do: UnitLocator.from_revision(loc, revision, key)
  end

  @doc """
  Read a whole subtree as `{relative_path, bytes}` pairs, resolving a
  unit's row once for the whole read: at or inside a unit the committed
  revision's prefix — or the unit's own path, for a revision not yet
  adopted — is listed and read as one revision, so a commit landing
  meanwhile changes nothing of what this read answers; above the units,
  the tenant's own leaves there and every committed unit's beneath, each
  unit resolved once. `Arca.read_subtree/2` runs this for the overlaid
  roots; `Arca.Storage.read_subtree_via/4` is the walk over the physical
  paths it names. A path no committed row names reads empty, as a
  missing directory does; a file unit's own path reads as a file does.
  """
  @spec read_subtree(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, [{Arca.Storage.path(), binary()}]} | {:error, term()}
  def read_subtree(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        Arca.Storage.read_subtree_via(tenant(), actor, path)

      :above_unit ->
        if UnitLocator.staging?(path),
          do: Arca.Storage.read_subtree_via(tenant(), actor, path),
          else: subtree_above_units(actor, path)

      loc ->
        case revision_of(actor, loc) do
          {:ok, revision} -> unit_subtree(actor, loc, revision, path)
          {:error, :not_found} -> {:ok, []}
          {:error, _} = error -> error
        end
    end
  end

  # Above the units: the tenant's own leaves under the path — nothing of
  # the staging areas, nothing under a unit's path — and each committed
  # unit beneath, read from its revision once.
  defp subtree_above_units(actor, [root | _] = path) do
    with {:ok, leaves} <- tenant().list_recursive(actor, path),
         {:ok, plain} <-
           bytes_of(
             actor,
             Enum.reject(leaves, &(UnitLocator.staging?(&1) or leaf_loc(&1) != nil)),
             path
           ),
         {:ok, pointers} <- StorageUnits.current_under(actor, root) do
      pointers
      |> Enum.map(fn {key, %{current_revision: revision}} ->
        {UnitLocator.unit_path(root, key), revision}
      end)
      |> Enum.filter(fn {unit, _revision} -> List.starts_with?(unit, path) end)
      |> Enum.reduce_while({:ok, plain}, fn {unit, revision}, {:ok, acc} ->
        case unit_pairs(actor, Arca.Storage.locate(unit), revision) do
          {:ok, pairs} ->
            below = Enum.drop(unit, length(path))
            {:cont, {:ok, acc ++ for({rel, bytes} <- pairs, do: {below ++ rel, bytes})}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
  end

  # The bytes of the tenant's own leaves, relative to `path`; a leaf that
  # vanished between the listing and its read is no error of the read.
  defp bytes_of(actor, leaves, path) do
    Enum.reduce_while(leaves, {:ok, []}, fn leaf, {:ok, acc} ->
      case tenant().get(actor, leaf) do
        {:ok, bytes} -> {:cont, {:ok, acc ++ [{Enum.drop(leaf, length(path)), bytes}]}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # One committed unit's objects relative to the unit, read from one
  # revision: a directory unit's subtree, a file unit's one object at
  # `[]` (what `read_subtree_via/4` cannot list, a file being no
  # directory).
  defp unit_pairs(actor, {:file, unit} = loc, revision) do
    case tenant().get(actor, source_of(actor, loc, revision, unit)) do
      {:ok, bytes} -> {:ok, [{[], bytes}]}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp unit_pairs(actor, {:dir, unit, _sentinel} = loc, revision),
    do: unit_subtree(actor, loc, revision, unit)

  # One unit's subtree at `path` — the unit or a path inside it — read
  # whole from one revision (`source_of/4`), the prefix's marker left out.
  # A file unit's own path answers as a file's does under a subtree read:
  # `{:error, :enotdir}` on every adapter.
  defp unit_subtree(actor, loc, revision, path) do
    marker = [UnitLocator.marker_name()]
    source = source_of(actor, loc, revision, path)

    with {:ok, pairs} <- Arca.Storage.read_subtree_via(tenant(), actor, source) do
      {:ok, Enum.reject(pairs, &(elem(&1, 0) == marker))}
    end
  end

  # ---------------------------------------------------------------------------
  # Unit status — the public questions the tree can answer about itself.
  # `Compendium.Provenance` and the status/reset surfaces consume these.
  # ---------------------------------------------------------------------------

  @doc """
  What one shadow unit holds — see `t:unit_status/0`. A path below a unit
  is answered for its unit; a path above any unit (or outside the seeded
  roots) is `{:ok, :absent}`. The unit's row is resolved once: a copy is
  complete only when the row is committed and the revision's completion
  object is in its prefix; bytes no committed row names are nothing the
  athanor holds. A tenant-adapter or row-store outage answers
  `{:error, term}` — a status surface must not misreport the athanor's
  own units as shipped.
  """
  @spec unit_status(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, unit_status()} | {:error, term()}
  def unit_status(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:ok, :absent}

      loc ->
        # The same classification the batch form applies over its listed
        # keys — the parity test in overlay_test pins the two together.
        with {:ok, held} <- held_state(actor, loc) do
          {:ok, classify(held, seed_unit_present?(loc))}
        end
    end
  end

  @doc """
  Every unit under a seeded root, mapped to its status — the batch form
  of `unit_status/2`: one row query and three listings (the root's
  staging area, the root's own tree for revisions served there before
  units were served from their prefixes, and the seed), no per-unit
  probes — classifying a key is a pure locator call. `:absent` units
  are, by definition, not in the map; `:available` ones are, so a caller
  can see what the seed ships that the athanor lacks. A tenant listing or
  row-store outage answers `{:error, term}`, never a seed-only map.
  """
  @spec unit_statuses(Prima.Actor.t(), String.t()) ::
          {:ok, %{Arca.Storage.path() => unit_status()}} | {:error, term()}
  def unit_statuses(%Prima.Actor{} = actor, root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, pointers} <- StorageUnits.current_under(actor, root),
           {:ok, staged} <- tenant().list_recursive(actor, UnitLocator.staging_area(root)),
           {:ok, tenant_leaves} <- tenant().list_recursive(actor, [root]),
           {:ok, seed_leaves} <- seed_list_recursive([root]) do
        staged = MapSet.new(staged)
        seed_locs = MapSet.new(for leaf <- seed_leaves, loc = leaf_loc(leaf), do: loc)

        legacy_by_loc =
          tenant_leaves
          |> Enum.reject(&UnitLocator.staging?/1)
          |> Enum.group_by(&Arca.Storage.locate/1)
          |> Map.drop([:above_unit, :not_overlaid])

        committed =
          Map.new(pointers, fn {key, %{current_revision: revision}} ->
            {Arca.Storage.locate(UnitLocator.unit_path(root, key)), revision}
          end)

        all_locs = MapSet.union(seed_locs, MapSet.new(Map.keys(committed)))

        statuses =
          Map.new(all_locs, fn loc ->
            held =
              case Map.fetch(committed, loc) do
                {:ok, revision} ->
                  if MapSet.member?(staged, completion_in(loc, revision)) or
                       completed_in_leaves?(loc, Map.get(legacy_by_loc, loc, [])),
                     do: :complete,
                     else: :partial

                :error ->
                  :empty
              end

            {unit_of(loc), classify(held, MapSet.member?(seed_locs, loc))}
          end)

        {:ok, statuses}
      end
    else
      {:ok, %{}}
    end
  end

  # What the athanor holds of one unit: `:complete` when its row is
  # committed and the revision's completion object is in its prefix (or,
  # for a revision served at the unit's own path before this shape,
  # there), `:partial` when the row is committed and the completion object
  # is nowhere, `:empty` when no committed row names the unit, whatever
  # bytes stand under its paths. Probed through listings, which carry an
  # outage: a status answer must not misreport a copy as `:available`
  # while the adapter is down.
  defp held_state(actor, loc) do
    {root, key} = UnitLocator.unit_key(unit_of(loc))

    case StorageUnits.current(actor, root, key) do
      {:ok, %{current_revision: revision}} ->
        with {:ok, in_prefix} <- completion_listed?(actor, loc, completion_in(loc, revision)),
             {:ok, at_unit} <- completion_listed?(actor, loc, completion_of(loc)) do
          {:ok, if(in_prefix or at_unit, do: :complete, else: :partial)}
        end

      {:error, :not_found} ->
        {:ok, :empty}

      {:error, _} = error ->
        error
    end
  end

  # Whether an object is there, asked of its directory's listing so an
  # outage answers as one. `:enotdir` is a real answer: a file where the
  # directory belongs holds no object of that name.
  defp completion_listed?(actor, _loc, object) do
    case tenant().list_typed(actor, Enum.drop(object, -1)) do
      {:ok, entries} -> {:ok, {List.last(object), :file} in entries}
      {:error, :enotdir} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  # One classification for both status forms: what the athanor holds,
  # and whether the seed ships the unit. A release that stopped shipping
  # a unit leaves the copy as the athanor's own to keep.
  defp classify(:complete, true), do: :shipped
  defp classify(:complete, false), do: :own
  defp classify(_incomplete, true), do: :available
  defp classify(:partial, false), do: :own
  defp classify(:empty, false), do: :absent

  @doc """
  How a unit's copy differs from its seed counterpart, as relative paths:
  `added` (tenant-only), `removed` (seed-only), `changed` (both, bytes
  differ). The seed side is filtered by the same droppings exclusion the
  shipped copy uses, so an unedited copy diffs empty. A file unit diffs
  as the single relative path `[]`. Memory-bounded to one unit — the
  same bound as a copy.
  """
  @spec diff_unit(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok,
           %{
             added: [Arca.Storage.path()],
             removed: [Arca.Storage.path()],
             changed: [Arca.Storage.path()]
           }}
          | {:error, term()}
  def diff_unit(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        {:error, :not_overlaid}

      :above_unit ->
        {:error, :not_a_unit}

      {:file, unit} = loc ->
        with {:ok, tenant_pairs} <- file_pairs(fn -> held_file(actor, loc) end),
             {:ok, seed_pairs} <- file_pairs(fn -> seed_get(unit) end) do
          {:ok, diff_pairs(tenant_pairs, seed_pairs)}
        end

      {:dir, unit, _sentinel} = loc ->
        with {:ok, tenant_pairs} <- subtree_pairs(fn -> held_subtree(actor, loc) end),
             {:ok, seed_pairs} <- subtree_pairs(fn -> seed_read_subtree(unit) end) do
          {:ok, diff_pairs(tenant_pairs, seed_pairs)}
        end
    end
  end

  # The athanor's side of a diff: the committed revision's objects, read
  # from where they are (`read/3`); no committed row is no side at all.
  defp held_file(actor, {:file, unit} = loc) do
    case revision_of(actor, loc) do
      {:ok, _revision} -> read(actor, unit, &tenant().get(actor, &1))
      {:error, _} = error -> error
    end
  end

  defp held_subtree(actor, {:dir, unit, _sentinel} = loc) do
    with {:ok, revision} <- revision_of(actor, loc), do: unit_subtree(actor, loc, revision, unit)
  end

  @doc """
  Whether the athanor's unit differs from what ships — `diff_unit/2` read
  as one boolean. A unit the seed does not ship differs by everything the
  athanor holds there.
  """
  @spec edited?(Prima.Actor.t(), Arca.Storage.path()) :: {:ok, boolean()} | {:error, term()}
  def edited?(%Prima.Actor{} = actor, path) do
    with {:ok, %{added: added, removed: removed, changed: changed}} <- diff_unit(actor, path) do
      {:ok, added != [] or removed != [] or changed != []}
    end
  end

  # ---------------------------------------------------------------------------
  # The seed as the shipped default: what it ships, and copying it in.
  # ---------------------------------------------------------------------------

  @doc """
  Every unit the seed ships under a seeded root, as unit paths — what
  provisioning copies and a release offers. Install media that cannot be
  listed is a fault, never an empty bundle.
  """
  @spec shipped_units(String.t()) :: {:ok, [Arca.Storage.path()]}
  def shipped_units(root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, seed_leaves} <- seed_list_recursive([root]) do
        units =
          for leaf <- seed_leaves, loc = leaf_loc(leaf), uniq: true, do: unit_of(loc)

        {:ok, Enum.sort(units)}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Copy one shipped unit into the athanor, whole — the seed's bytes,
  droppings excluded, committed as any unit is (`commit_unit/4`) —
  replacing whatever stands at the path. What provisioning does for every
  shipped unit, what a pull of a shipped version does for one, and what a
  restore does over an edited copy. Shipped media is not capped: an athanor
  must always be able to hold what the server ships.

  A unit the seed does not ship refuses as `{:error, :not_shipped}`; a
  path that is not a unit as `{:error, :not_a_unit}`.

  `claim:` in `opts` is `commit_unit/4`'s: the copy is a provisioning
  attempt's, published only while that attempt still holds its claim and
  the slot it was taken under.
  """
  @spec pull_shipped(Prima.Actor.t(), Arca.Storage.path(), keyword()) ::
          :ok | {:error, :not_shipped | :not_a_unit | :not_overlaid | term()}
  def pull_shipped(%Prima.Actor{} = actor, unit, opts \\ []) when is_list(opts) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        cond do
          unit_of(loc) != unit -> {:error, :not_a_unit}
          not seed_unit_present?(loc) -> {:error, :not_shipped}
          true -> do_pull_shipped(actor, loc, Keyword.take(opts, [:claim]))
        end
    end
  end

  defp do_pull_shipped(actor, {:dir, unit, sentinel}, claim) do
    seed_dir = seed(unit)

    with :ok <- seed_sentinel_present(seed_dir, sentinel),
         {:ok, _written} <-
           commit_unit(
             actor,
             unit,
             {:tree, seed_dir, exclude: &excluded?/1},
             [cap: :exempt] ++ claim
           ) do
      Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{actor.athanor_id}")
      :ok
    end
  end

  defp do_pull_shipped(actor, {:file, unit}, claim) do
    with {:ok, bytes} <- seed_get(unit),
         {:ok, _written} <-
           commit_unit(actor, unit, {:files, [{[], bytes}]}, [cap: :exempt] ++ claim) do
      Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{actor.athanor_id}")
      :ok
    end
  end

  @doc """
  Copy every shipped unit under `root` the athanor does not hold — the
  `:available` ones — leaving what it holds alone, edited or not. What
  fills a fresh athanor at provisioning and what heals an athanor whose
  tree lost a copy. Answers the units copied; stops at the first unit
  that cannot be copied.

  `claim:` in `opts` makes every copy a provisioning attempt's
  (`pull_shipped/3`): a unit the athanor's next attempt committed after
  this one listed the root is never replaced by this one's copy, since
  the copy's commit holds this attempt's claim and slot or moves nothing.
  """
  @spec materialize_shipped(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def materialize_shipped(%Prima.Actor{} = actor, root, opts \\ [])
      when is_binary(root) and is_list(opts) do
    with {:ok, statuses} <- unit_statuses(actor, root) do
      statuses
      |> Enum.filter(fn {_unit, status} -> status == :available end)
      |> Enum.map(fn {unit, _status} -> unit end)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn unit, {:ok, copied} ->
        case pull_shipped(actor, unit, opts) do
          :ok -> {:cont, {:ok, [unit | copied]}}
          {:error, reason} -> {:halt, {:error, {:materialize_failed, unit, reason}}}
        end
      end)
      |> case do
        {:ok, copied} -> {:ok, Enum.reverse(copied)}
        error -> error
      end
    end
  end

  @doc """
  Delete one unit the athanor made itself, explicitly (`aqua.delete`,
  `reset all: true`): `{:ok, :deleted}` for its own work. A shipped copy,
  edited or not, refuses as `{:error, :bundled}` — it is restored, never
  deleted — and a unit the athanor does not hold as `{:error, :not_found}`.
  The same disposition vocabulary `Compendium.Registry.delete/4` speaks.
  The unit's row is `retiring` under the removal's lease before the
  retired revision's prefix is deleted, and the row is retired last;
  `{:error, :stale_writer}` while another writer holds the
  unit — a publication staging or finishing, or another removal — and the
  caller asks again once it is done, which a writer that died holds off
  for the draft's lifetime (`Arca.StorageUnits.draft_ttl_ms/0`).
  """
  @spec drop_unit(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, :deleted} | {:error, :bundled | :not_found | :not_overlaid | term()}
  def drop_unit(%Prima.Actor{} = actor, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(actor, path) do
          {:ok, :own} -> with :ok <- delete_unit(actor, loc), do: {:ok, :deleted}
          {:ok, :shipped} -> {:error, :bundled}
          {:ok, _available_or_absent} -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Commit — the one way a unit lands: whole, or not at all.
  # ---------------------------------------------------------------------------

  @typedoc """
  What a unit commit writes: explicit relative files — bytes, or a lazy
  read for sources streamed from outside Arca (a scratch dir) — or
  another Arca tree, streamed one file at a time.
  """
  @type commit_source ::
          {:files,
           [
             {relative :: Arca.Storage.path(), binary() | (-> {:ok, binary()} | {:error, term()})}
           ]}
          | {:tree, src :: Arca.Storage.path(), [{:exclude, (Arca.Storage.path() -> boolean())}]}

  @doc """
  Land one whole unit through the write protocol (the moduledoc's four
  steps). Every ingress that lays a unit (scaffold, fork, publish, OCI
  pull, the shipped copy) commits through here, so the draft, the staged
  revision, its validation, the row commit, cap policy and usage
  accounting are one implementation, not a discipline each caller
  re-spells.

  Options:

    * `cap:` (required) — `:exempt` or `{:checked, bytes}`. Every call
      site states its policy, so the uncapped-by-design set stays
      explicit (`Prima.Caps` documents the roster). Checked
      before the draft is registered and before any write.
    * `sentinel:` — the sentinel's bytes, overriding any sentinel entry
      the source carries (a fork's re-stamped manifest, a pull's
      authoritative config blob). A dir-unit commit with sentinel bytes
      from neither place refuses as `{:error, :missing_sentinel}` before
      any write.
    * `if_absent: true` — create, never replace: asked of the unit's row
      while this writer holds its draft, so no other commit can land
      between the question and this one, and enforced again by the
      commit's own compare, which expects no pointer. A unit whose row is
      committed — released by its writer or not — refuses as
      `{:error, :exists}` before any write, as does one held by another
      writer's draft whose row is committed; bytes no committed row names
      are nothing. A unit another writer is creating or removing refuses
      as `{:error, :stale_writer}`: ask again.
    * `claim:` — `%{owner: owner, fence: fence, slot: slot}`, the
      provisioning claim a fill holds and the member slot it was taken
      under. The row commit then verifies that slot and holds that claim
      in its transaction (`Arca.StorageUnits.stamped_commit/6`) instead of
      verifying the slot the member holds now, and refuses
      `{:error, :not_owner}` once the attempt lost either.
  A file unit commits as `{:files, [{[], bytes}]}` and refuses
  `sentinel:`. A commit over existing tenant content replaces it whole
  (stale files from a prior partial or an overwritten pull do not
  survive).

  Returns the written relatives in write order, sentinel last. Refusals
  of the row: `{:error, :stale_writer}` when another writer's live draft
  holds the unit — a commit being staged or finished, or a removal under
  way — `{:error, :stale_revision}` when another commit landed first,
  `{:error, :missing_unit}` when the unit was dropped under this writer,
  `{:error, :invalid_objects}` when what was staged is not what was
  written, `{:error, :not_owner}` when this member no longer holds its
  slot in the cell (`Arca.StorageUnits.commit/5`) — in each case nothing
  is published and the staged objects are removed. `{:error, :outcome_unknown}` from the commit leaves the
  staged objects where they are: the outcome is unknown.
  `{:error, :stale_writer}` after the commit is a writer whose draft was
  taken between its commit and its release — by another member once the
  token outlived the draft's lifetime, or by the collector giving back a
  draft that looked dead: the row is the taker's, and this revision's
  objects stay for collection.
  """
  @spec commit_unit(Prima.Actor.t(), Arca.Storage.path(), commit_source(), keyword()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def commit_unit(%Prima.Actor{} = actor, unit, source, opts) do
    cap = Keyword.fetch!(opts, :cap)
    override = Keyword.get(opts, :sentinel)

    loc =
      case Arca.Storage.locate(unit) do
        {:file, ^unit} = loc ->
          file_unit_source!(unit, source, override)
          loc

        {:dir, ^unit, _sentinel} = loc ->
          loc

        other ->
          raise ArgumentError,
                "commit_unit needs a unit path; the unit locates to #{Prima.LoggerContext.shape(other)}"
      end

    internal = internal_actor(actor)
    if_absent = Keyword.get(opts, :if_absent, false)

    # Resolved before the draft and before any write: a commit that could
    # never be completed must not move a byte or hold the unit.
    with {:ok, entries} <- entries(internal, loc, source, override),
         :ok <- check_commit_cap(actor, cap) do
      actor
      |> write(
        internal,
        loc,
        fn draft ->
          if if_absent and occupied?(draft),
            do: {:error, :exists},
            else: {:ok, entries}
        end,
        Keyword.take(opts, [:claim])
      )
      |> created(if_absent, actor, loc)
    end
  end

  # A create refused the draft because another writer holds it: the unit
  # exists when that writer's row is committed — a publication between
  # its commit and its release — and is theirs to create or remove
  # otherwise.
  defp created({:error, :stale_writer} = refused, true, actor, loc) do
    {root, key} = UnitLocator.unit_key(unit_of(loc))

    case StorageUnits.current(actor, root, key) do
      {:ok, _committed} -> {:error, :exists}
      _draft_retiring_or_unknown -> refused
    end
  end

  defp created(answer, _if_absent, _actor, _loc), do: answer

  defp file_unit_source!(_unit, {:files, [{[], _content}]}, nil), do: :ok

  defp file_unit_source!(unit, _source, _override) do
    raise ArgumentError,
          "a file unit (#{Enum.join(unit, "/")}) commits as {:files, [{[], bytes}]} " <>
            "with no sentinel: — the put is the commit"
  end

  @doc """
  Replace one subtree of a complete directory unit with `files` — how a
  tincture build publishes its `dist/`. `subtree` is relative to the unit
  and `files` relative to the subtree.

  The replacement is a new revision of the unit through the same write
  protocol as `commit_unit/4`: what the unit serves outside the subtree —
  its sentinel included — is carried over as it is, the subtree is
  `files` and nothing else, and the row commit publishes the two
  together. It needs nothing of the adapter a commit does not, so it
  lands on an object store as on a filesystem. A commit that lands on the
  unit while this one stages refuses this one as
  `{:error, :stale_revision}`; the other refusals are `commit_unit/4`'s.

  `cap:` (required) is `commit_unit/4`'s, checked before any write.
  `{:error, :not_found}` when the unit's sentinel is not served — asked
  of the served objects, so a unit laid by hand is carried into its first
  committed revision — and `{:error, :invalid_path}` for an empty relative
  path.
  """
  @spec replace_subtree(
          Prima.Actor.t(),
          Arca.Storage.path(),
          Arca.Storage.path(),
          [{Arca.Storage.path(), binary() | (-> {:ok, binary()} | {:error, term()})}],
          keyword()
        ) :: :ok | {:error, term()}
  def replace_subtree(
        %Prima.Actor{} = actor,
        unit,
        [top | _] = subtree,
        files,
        opts
      )
      when is_list(files) do
    cap = Keyword.fetch!(opts, :cap)

    case Arca.Storage.locate(unit) do
      {:dir, ^unit, sentinel} = loc when top != sentinel ->
        internal = internal_actor(actor)

        with :ok <- subtree_files(files),
             :ok <- check_commit_cap(actor, cap),
             {:ok, _written} <-
               write(actor, internal, loc, fn draft ->
                 if draft.state == "committed",
                   do: carried_entries(internal, loc, subtree, files),
                   else: {:error, :not_found}
               end) do
          :ok
        end

      other ->
        raise ArgumentError,
              "replace_subtree needs a directory unit and a subtree other than its sentinel; " <>
                "the unit locates to #{Prima.LoggerContext.shape(other)}"
    end
  end

  defp subtree_files(files) do
    if Enum.any?(files, &match?({[], _content}, &1)), do: {:error, :invalid_path}, else: :ok
  end

  # The next revision of a unit whose one subtree is replaced: every
  # served object outside the subtree, streamed from where it is served,
  # then the new subtree, the sentinel last.
  defp carried_entries(internal, {:dir, unit, sentinel}, subtree, files) do
    with {:ok, leaves} <- Arca.list_recursive(internal, unit) do
      carried =
        for leaf <- leaves,
            rel = Enum.drop(leaf, length(unit)),
            rel != [sentinel],
            not List.starts_with?(rel, subtree),
            do: {rel, fn -> Arca.get(internal, leaf) end, :streamed}

      replaced = for {rel, content} <- files, do: {subtree ++ rel, content, :required}
      kept_sentinel = {[sentinel], fn -> Arca.get(internal, unit ++ [sentinel]) end, :required}

      {:ok, carried ++ replaced ++ [kept_sentinel]}
    end
  end

  @doc """
  Give a committed unit back what its writer left undone, and say what it
  holds; nothing is moved and no object is invented.

  A writer that died between its commit and its release holds the unit's
  draft: once the token has outlived the draft's lifetime, repair takes
  the draft, marks the revision's generation ready and releases it,
  `{:ok, :repaired}`; a live draft is its holder's, `{:error, :stale_writer}`.
  A revision served at the unit's own path before units were served from
  their prefixes is adopted — committed as a revision of its own from the
  unit's own path, under the lease — and the unit's own path cleared,
  `{:ok, :repaired}`. A committed revision whose
  completion object is in its prefix and whose draft is free has nothing
  pending, `{:ok, :nothing_pending}`; one whose completion object is
  nowhere is `{:error, :staged_incomplete}`, reported and left. The
  collector's audit (`Arca.StorageGC.repair/1`) reads every object of
  such a revision against the journal; this answers from the completion
  object alone. `{:error, :not_found}` for a unit no committed row names.
  """
  @spec repair_unit(Prima.Actor.t(), Arca.Storage.path()) ::
          {:ok, :repaired | :nothing_pending}
          | {:error, :staged_incomplete | :stale_writer | :not_found | term()}
  def repair_unit(%Prima.Actor{} = actor, unit) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        if unit_of(loc) == unit, do: repair(actor, loc), else: {:error, :not_a_unit}
    end
  end

  defp repair(actor, loc) do
    {root, key} = UnitLocator.unit_key(unit_of(loc))

    case StorageUnits.current(actor, root, key) do
      {:ok, %{current_revision: revision, draft_writer_token: token}} ->
        cond do
          completion_in_prefix?(actor, loc, revision) and is_nil(token) ->
            {:ok, :nothing_pending}

          completion_in_prefix?(actor, loc, revision) ->
            release_dead(actor, loc, revision)

          completion_at_unit?(actor, loc) ->
            with {:ok, _adopted} <- adopt(actor, loc), do: {:ok, :repaired}

          true ->
            {:error, :staged_incomplete}
        end

      {:error, _} = error ->
        error
    end
  end

  # The draft of a writer that died after its commit, taken once it has
  # outlived the lifetime and released at a repair's generation, which is
  # marked ready for the revision the row names.
  defp release_dead(actor, loc, revision) do
    unit = unit_of(loc)
    {root, key} = UnitLocator.unit_key(unit)
    token = StorageUnits.new_writer_token()

    released =
      fenced(actor, unit, fn ->
        with {:ok, _draft} <- StorageUnits.register_draft(actor, root, key, token) do
          release(actor, loc, token, revision, fn ->
            StorageProjectionChanges.begin_repair(actor, root, key, revision)
          end)
        end
      end)

    with {:served, ^revision, generation} <- released do
      marked(actor, unit, revision, generation)
      {:ok, :repaired}
    end
  end

  # The bound on an update's compare-and-set: attempts in all, and the
  # base of the doubling backoff between them.
  @update_attempts 5
  @update_backoff_base_ms 20

  @doc """
  One serialized read-modify-write at a path inside a unit. `fun` receives
  the bytes at `path` and answers `{:ok, bytes}` to write them — a gated
  facade write, so the storage cap applies as for any write — or
  `{:error, reason}` to write nothing and answer that.

  Serialized against EVERY writer of the object, on every node: the read
  answers the object's precondition
  (`c:Arca.Storage.get_for_update/2`) and the write carries it
  (`c:Arca.Storage.put_if_match/4`), so the bytes `fun` was given are
  still the bytes at the path when its answer lands, or nothing is
  written. An object another writer moved in between — a commit, a pull,
  a reset, another update — is read again and `fun` applied to what is
  there now, up to #{@update_attempts} attempts with a doubling,
  jittered backoff. Nothing is overwritten unseen and no edit is lost.

  `fun` is therefore called once per attempt, and must be a pure rewrite
  of the bytes it is given: an effect inside it happens once per attempt,
  not once per update.

  `{:error, :conflict}` when the object was still moving after the last
  attempt: nothing was written and asking again is safe.
  `{:error, :not_found}` when nothing is at `path`,
  `{:error, :not_overlaid}` for a path no unit covers, and
  `{:error, :unsupported}` from a store that can give no proof of the
  version it read — an update is refused there rather than made a
  last-writer-wins put.
  """
  @spec update(
          Prima.Actor.t(),
          Arca.Storage.path(),
          (binary() -> {:ok, binary()} | {:error, term()})
        ) :: :ok | {:error, :conflict | :not_found | :not_overlaid | term()}
  def update(%Prima.Actor{} = actor, path, fun) when is_function(fun, 1) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] -> {:error, :not_overlaid}
      _inside_a_unit -> compare_and_set(actor, path, fun, 1)
    end
  end

  defp compare_and_set(actor, path, fun, attempt) do
    with {:ok, current, precondition} <- Arca.get_for_update(actor, path),
         {:ok, bytes} when is_binary(bytes) <- fun.(current) do
      case Arca.put_if_match(actor, path, bytes, precondition, cap: :checked) do
        :ok ->
          :ok

        # The object moved between the read and the write: nothing was
        # written, so reading it again and applying `fun` to what is there
        # now loses neither writer's work.
        {:error, :precondition_failed} when attempt < @update_attempts ->
          Process.sleep(update_backoff_ms(attempt))
          compare_and_set(actor, path, fun, attempt + 1)

        {:error, :precondition_failed} ->
          Logger.warning(
            "[Arca.Overlay] update of #{Enum.join(path, "/")} still losing after " <>
              "#{attempt} attempts"
          )

          {:error, :conflict}

        # The object was removed while the edit was being made. There is
        # nothing to rewrite, and a create is not what was asked for.
        {:error, :missing} ->
          {:error, :not_found}

        {:error, _} = error ->
          error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  # Doubling from the base, with jitter so the losers of one round do not
  # collide again in the next.
  defp update_backoff_ms(attempt) do
    ceiling = @update_backoff_base_ms * Integer.pow(2, attempt - 1)
    div(ceiling, 2) + :rand.uniform(div(ceiling, 2))
  end

  # ---------------------------------------------------------------------------
  # The write protocol
  # ---------------------------------------------------------------------------

  # What the commit will write, in write order with the sentinel last,
  # each content still unresolved: `{relative, content, :required}`, or
  # `:streamed` for a tree source's leaf, which may vanish between the
  # listing and its read (a concurrent delete is not a copy's error).
  defp entries(_internal, {:file, _unit}, {:files, [{[], content}]}, _override),
    do: {:ok, [{[], content, :required}]}

  defp entries(_internal, {:dir, _unit, sentinel}, {:files, files}, override) do
    with {:ok, sentinel_content} <- files_sentinel(files, sentinel, override) do
      body = for {rel, content} <- files, rel != [sentinel], do: {rel, content, :required}
      {:ok, body ++ [{[sentinel], sentinel_content, :required}]}
    end
  end

  defp entries(internal, {:dir, _unit, sentinel}, {:tree, src, opts}, override) do
    exclude = Keyword.get(opts, :exclude, fn _relative -> false end)

    with {:ok, sentinel_bytes} <- tree_sentinel(internal, src, sentinel, override),
         {:ok, leaves} <- Arca.list_recursive(internal, src) do
      body =
        for leaf <- leaves,
            rel = Enum.drop(leaf, length(src)),
            rel != [sentinel],
            not exclude.(rel),
            do: {rel, fn -> Arca.get(internal, leaf) end, :streamed}

      {:ok, body ++ [{[sentinel], sentinel_bytes, :required}]}
    end
  end

  defp files_sentinel(_files, _sentinel, override) when is_binary(override), do: {:ok, override}

  defp files_sentinel(files, sentinel, nil) do
    case List.keyfind(files, [sentinel], 0) do
      {_rel, content} -> {:ok, content}
      nil -> {:error, :missing_sentinel}
    end
  end

  defp tree_sentinel(_internal, _src, _sentinel, override) when is_binary(override),
    do: {:ok, override}

  defp tree_sentinel(internal, src, sentinel, nil) do
    case Arca.get(internal, src ++ [sentinel]) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :not_found} -> {:error, :missing_sentinel}
      {:error, _} = error -> error
    end
  end

  defp resolve_content(bytes) when is_binary(bytes), do: {:ok, bytes}
  defp resolve_content(thunk) when is_function(thunk, 0), do: thunk.()

  defp check_commit_cap(_ctx, :exempt), do: :ok

  defp check_commit_cap(actor, {:checked, bytes}) when is_integer(bytes) and bytes >= 0,
    do: Prima.Caps.check_storage(actor, bytes)

  # Steps 1 to 4 under the fence: the draft is registered, `gate` asked
  # while this writer holds it — so no other commit can land between its
  # answer and this commit; it answers what to write, or the refusal — and
  # the revision staged, committed and released, all under the unit's
  # node-local lock. The generation is marked outside it. `commit_opts`
  # name the writer the row commit verifies
  # (`Arca.StorageUnits.stamped_commit/6`).
  defp write(actor, internal, loc, gate, commit_opts \\ []) do
    unit = unit_of(loc)
    {root, key} = UnitLocator.unit_key(unit)
    token = StorageUnits.new_writer_token()

    served =
      fenced(actor, unit, fn ->
        with {:ok, draft} <- StorageUnits.register_draft(actor, root, key, token) do
          case gate.(draft) do
            {:ok, entries} ->
              with_internal_writes(fn ->
                case publish(actor, internal, loc, draft, token, entries, commit_opts) do
                  {:served, revision, generation, relatives} ->
                    {:served, revision, generation, relatives, draft.current_revision}

                  other ->
                    other
                end
              end)

            {:error, _} = refusal ->
              StorageUnits.abandon_draft(actor, draft, token)
              refusal
          end
        end
      end)

    case served do
      {:served, revision, generation, relatives, prior} ->
        marked(actor, unit, revision, generation)
        cleared_unit_path(actor, loc, prior)
        {:ok, relatives}

      other ->
        other
    end
  end

  # What a revision served at the unit's own path before units were served
  # from their prefixes left there is superseded by a publication into a
  # prefix: no reader resolves the row to it any more, and it goes —
  # unless a live pin names the revision it served (`prior`, the pointer
  # the publication replaced), which keeps it for the pinned reader until
  # the collector takes it. A refusal is logged — the publication stands,
  # and a removal or the collector clears the path again.
  defp cleared_unit_path(actor, loc, prior) do
    unit = unit_of(loc)

    standing? =
      case loc do
        {:file, ^unit} -> tenant().exists?(actor, unit)
        {:dir, ^unit, _sentinel} -> match?({:ok, [_ | _]}, tenant().list_recursive(actor, unit))
      end

    with true <- standing?,
         false <- is_binary(prior) and Arca.StorageGC.pinned?(actor, unit, prior) do
      case tenant().delete_tree(actor, unit) do
        # The bytes left the tree beneath the facade's accounting: the
        # counters are dropped, to be walked true again.
        :ok ->
          Arca.Usage.invalidate(actor)

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Arca.Overlay] #{Enum.join(unit, "/")}: what an earlier revision left at the " <>
              "unit's own path could not be removed (#{inspect(reason)}); the collector clears it"
          )
      end
    end

    :ok
  end

  # What `if_absent:` asks under the draft, of the row alone: a committed
  # row IS the unit, whether its writer has released it or not, so a
  # create must never replace it; a row never committed, or retired, is
  # nothing, whatever bytes stand under the unit's paths. What the seed
  # ships is not the athanor's until pulled, so it never counts.
  defp occupied?(%Arca.Schemas.StorageUnit{state: "committed"}), do: true
  defp occupied?(%Arca.Schemas.StorageUnit{}), do: false

  # Steps 1–3 on the object side, then the commit. Everything a refusal
  # leaves behind is this revision's own prefix, which goes with it —
  # except when the commit's outcome is unknown.
  defp publish(actor, internal, loc, draft, token, entries, commit_opts) do
    unit = unit_of(loc)
    revision = StorageUnits.new_revision()

    staged =
      with :ok <- mark_in_progress(internal, unit, revision, draft),
           {:ok, manifest} <- stage(internal, unit, revision, entries),
           :ok <- validate(internal, loc, revision, manifest) do
        {:ok, manifest}
      end

    case staged do
      {:ok, manifest} ->
        identity = %{
          new_revision: revision,
          content_identity: content_identity(manifest),
          commit_identity: actor.user_id || "system"
        }

        case StorageUnits.stamped_commit(
               actor,
               draft,
               draft.current_revision,
               token,
               identity,
               commit_opts
             ) do
          {:committed, generation} ->
            with {:served, ^revision, ^generation} <-
                   release(actor, loc, token, revision, fn -> {:ok, generation} end) do
              {:served, revision, generation, Enum.map(manifest, &elem(&1, 0))}
            end

          {:error, :outcome_unknown} = unknown ->
            unknown

          {:error, _} = refused ->
            discard(actor, internal, unit, revision, draft, token)
            refused
        end

      {:error, _} = error ->
        discard(actor, internal, unit, revision, draft, token)
        error
    end
  end

  # The prefix is registered before any upload: create-once where the
  # adapter can make a create conditional, a plain put elsewhere — the
  # revision name is unique either way, so nothing is ever overwritten.
  defp mark_in_progress(internal, unit, revision, draft) do
    path = UnitLocator.marker_path(unit, revision)

    marker =
      Jason.encode!(%{
        "revision" => revision,
        "prior_revision" => draft.current_revision,
        "started_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    case Arca.Storage.put_if_none_match(internal, path, marker) do
      {:ok, _precondition} ->
        Arca.Usage.account(internal, path, {:create, byte_size(marker)}, :ok)

      {:error, :unsupported} ->
        Arca.put(internal, path, marker)

      {:error, _} = error ->
        error
    end
  end

  # One object at a time, so a unit never sits in memory whole. The
  # manifest is what validation and the content identity read.
  defp stage(internal, unit, revision, entries) do
    marker = [UnitLocator.marker_name()]

    entries
    |> Enum.reduce_while({:ok, []}, fn
      {^marker, _content, _kind}, _acc ->
        {:halt, {:error, :reserved_name}}

      {rel, content, kind}, {:ok, acc} ->
        case stage_object(internal, UnitLocator.staged_object(unit, revision, rel), content) do
          {:ok, digest, size} -> {:cont, {:ok, [{rel, digest, size} | acc]}}
          {:error, :not_found} when kind == :streamed -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, manifest} -> {:ok, Enum.reverse(manifest)}
      {:error, _} = error -> error
    end
  end

  defp stage_object(internal, path, content) do
    with {:ok, bytes} <- resolve_content(content),
         :ok <- Arca.put(internal, path, bytes) do
      {:ok, Prima.Digest.sha256(bytes), byte_size(bytes)}
    end
  end

  # What was staged must be exactly what was written: every object listed,
  # none besides, each read back against its digest. A listing or a read
  # that cannot answer is its own error, never `:invalid_objects`.
  defp validate(internal, loc, revision, manifest) do
    with {:ok, staged} <- staged_relatives(internal, loc, revision) do
      if Enum.sort(staged) == manifest |> Enum.map(&elem(&1, 0)) |> Enum.sort() do
        verify_objects(internal, unit_of(loc), revision, manifest)
      else
        {:error, :invalid_objects}
      end
    end
  end

  defp verify_objects(internal, unit, revision, manifest) do
    Enum.reduce_while(manifest, :ok, fn {rel, digest, _size}, :ok ->
      case Arca.get(internal, UnitLocator.staged_object(unit, revision, rel)) do
        {:ok, bytes} ->
          if Prima.Digest.sha256(bytes) == digest,
            do: {:cont, :ok},
            else: {:halt, {:error, :invalid_objects}}

        {:error, :not_found} ->
          {:halt, {:error, :invalid_objects}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # The objects under a revision's prefix, as unit-relative paths, the
  # marker left out. A file unit's one object is `[]`.
  defp staged_relatives(internal, loc, revision) do
    prefix = UnitLocator.revision_prefix(unit_of(loc), revision)
    marker = UnitLocator.marker_name()

    with {:ok, leaves} <- Arca.Storage.list_prefix(internal, prefix) do
      relatives =
        for leaf <- leaves, rel = Enum.drop(leaf, length(prefix)), rel != [marker] do
          case loc do
            {:file, _unit} -> []
            {:dir, _unit, _sentinel} -> rel
          end
        end

      {:ok, relatives}
    end
  end

  @typedoc """
  What a revision holds, one entry per object: its path relative to the
  unit, the SHA-256 of its bytes and their size.
  """
  @type content_manifest :: [{Arca.Storage.path(), String.t(), non_neg_integer()}]

  @doc """
  The content identity of a revision: each object in path order, framed
  as its path, its digest and its size, NUL-separated, hashed.

  The one framing there is. A commit records it in the journal, and every
  reader that must tell one revision's objects from another's — this
  module's repair, `Arca.StorageGC`'s collection and its own repair —
  compares against it rather than restating the framing.
  """
  @spec content_identity(content_manifest()) :: String.t()
  def content_identity(manifest) do
    manifest
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {rel, digest, size} ->
      [Enum.join(rel, "/"), <<0>>, digest, <<0>>, Integer.to_string(size), <<0>>]
    end)
    |> Prima.Digest.sha256_stream()
  end

  # A refused revision leaves nothing: its prefix goes, and the draft is
  # given back so the next writer is not held for the draft's lifetime.
  defp discard(actor, internal, unit, revision, draft, token) do
    case Arca.delete_tree(internal, UnitLocator.revision_prefix(unit, revision)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Arca.Overlay] could not remove the refused revision #{revision} of " <>
            "#{Enum.join(unit, "/")} (#{inspect(reason)}); its objects stay unpublished"
        )
    end

    StorageUnits.abandon_draft(actor, draft, token)
    :ok
  end

  # Step 4, for a commit and for a repair alike, inside the fence: the
  # writer holds the unit's draft under `token`, and `stamp` answers the
  # projection generation to mark ready — the commit's own, or a repair's
  # written here. The row is read as this writer's and as naming
  # `revision`, and the draft is released only while the pointer still
  # names it. Answers `{:served, revision, generation}` for `marked/4` to
  # mark outside the fence. The commit stands whatever happens here: a
  # writer whose token was taken — by another member, or by the collector
  # giving a dead-looking draft back — is told so, and its staged
  # revision stays for the collector; every other exit gives the draft
  # back, so repair can take it.
  defp release(actor, loc, token, revision, stamp) do
    unit = unit_of(loc)
    {root, key} = UnitLocator.unit_key(unit)

    released =
      with {:ok, row} <- StorageUnits.held(actor, root, key, token) do
        answer =
          with :ok <- names(row, revision),
               {:ok, generation} <- stamp.(),
               :ok <- StorageUnits.release_served(actor, row, token, revision) do
            {:released, generation}
          end

        case answer do
          {:released, _generation} = released ->
            released

          {:error, _} = failed ->
            StorageUnits.abandon_draft(actor, row, token)
            failed
        end
      end

    case released do
      {:released, generation} ->
        {:served, revision, generation}

      {:error, taken} when taken in [:stale_writer, :stale_revision] ->
        Logger.error(
          "[Arca.Overlay] revision #{revision} of #{Enum.join(unit, "/")} was committed but " <>
            "the unit was taken from its writer (#{inspect(taken)}); the row is the taker's " <>
            "and the revision's objects await collection"
        )

        {:error, :stale_writer}

      {:error, _} = refused ->
        refused
    end
  end

  defp names(%{state: "committed", current_revision: revision}, revision), do: :ok
  defp names(_row, _revision), do: {:error, :stale_revision}

  # What follows a released revision, outside the fence: the mark
  # announces the change, and what a listener does with it must not hold
  # the unit's lock or its lease.
  defp marked(actor, unit, revision, generation) do
    {root, key} = UnitLocator.unit_key(unit)

    actor
    |> mark_ready(root, key, generation, revision)
    |> report_readiness(unit, generation)
  end

  # A revision served at the unit's own path before units were served
  # from their prefixes is adopted by a commit of its own: every object
  # at the unit's own path is staged under a new revision's prefix and
  # the pointer moved to it under the lease, as any publication is — so
  # no two adopters ever write into one prefix, a stalled adopter is
  # refused at its commit (`{:error, :stale_writer}`) and its prefix is
  # the collector's, and an adoption that dies leaves the unit's own path
  # whole for the next. The unit's own path is cleared once the new
  # revision is released, unless a live pin names the revision it served
  # (`cleared_unit_path/3`). Answers the revision readers resolve the row
  # to afterwards.
  defp adopt(actor, {:file, unit} = loc) do
    internal = internal_actor(actor)
    adopted(actor, loc, {:files, [{[], fn -> Arca.get(internal, unit) end}]})
  end

  defp adopt(actor, {:dir, unit, _sentinel} = loc), do: adopted(actor, loc, {:tree, unit, []})

  defp adopted(actor, loc, source) do
    unit = unit_of(loc)
    {root, key} = UnitLocator.unit_key(unit)

    with {:ok, _written} <- commit_unit(actor, unit, source, cap: :exempt),
         {:ok, %{current_revision: revision}} <- StorageUnits.current(actor, root, key) do
      {:ok, revision}
    end
  end

  # The revision an edit lands in: the pointer's, once a revision still at
  # the unit's own path has been adopted into a prefix of its own.
  defp adopted_revision(actor, loc, revision) do
    if legacy?(actor, loc, revision), do: adopt(actor, loc), else: {:ok, revision}
  end

  # An internal context focused on the caller's athanor, writing back
  # THROUGH the facade so every committed byte passes the facade's usage
  # accounting like any other write. The user_id is attribution only —
  # the exemption is the lexical internal-write scope.
  # Narrowed, never widened: the server's own actor with this athanor and
  # `scope: :athanor`, so the internal write keeps the system authority it
  # needs for the reserved roots and gives up the cross-tenant read. A bare
  # `Prima.Actor.system/0` here would put every internal overlay write on
  # platform scope, and no test would fail.
  defp internal_actor(%Prima.Actor{athanor_id: athanor_id}) do
    %{
      Prima.Actor.system()
      | athanor_id: athanor_id,
        scope: :athanor,
        user_id: "_overlay"
    }
  end

  # ---------------------------------------------------------------------------
  # Write shapes, and the delete refusal
  # ---------------------------------------------------------------------------

  # A tree is replaced inside a directory unit or outside the units: at a
  # unit, above units, in place of a sentinel or below a file unit it would
  # take a unit's shape with it. A unit is replaced whole by its commit,
  # never by a swap at its path.
  defp replaceable(path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        :ok

      {:dir, unit, sentinel} when unit != path ->
        if path == unit ++ [sentinel], do: {:error, :invalid_path}, else: :ok

      _at_a_unit_above_or_below_a_file_unit ->
        {:error, :invalid_path}
    end
  end

  # A put or append must land inside a unit, or outside the units
  # altogether: below a file unit there is no interior to write into, and
  # a put exactly at a directory unit would drop a file where the unit's
  # tree belongs.
  defp writable(path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] -> :ok
      {:file, unit} when unit != path -> {:error, :invalid_path}
      {:dir, unit, _sentinel} when unit == path -> {:error, :invalid_path}
      _inside_a_dir_unit_or_at_a_file_unit -> :ok
    end
  end

  # Refuse deleting a shipped unit whole: `{:error, :bundled}` for a
  # delete AT a unit the seed ships. A file inside a directory unit
  # deletes as an edit; the athanor's own unit deletes normally. Only the
  # internal-write scope is exempt.
  defp deletable(path) do
    if internal_writes?() do
      :ok
    else
      case Arca.Storage.locate(path) do
        {:file, unit} = loc when unit == path -> refuse_shipped(loc)
        {:dir, unit, _sentinel} = loc when unit == path -> refuse_shipped(loc)
        _inside_above_or_outside -> :ok
      end
    end
  end

  defp refuse_shipped(loc) do
    if seed_unit_present?(loc), do: {:error, :bundled}, else: :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # The inner tenant adapter — the configured one. This module is the
  # decorator the facade always wraps around it; configured as the
  # adapter itself it would recurse without bound, so refuse loudly.
  defp tenant do
    case Arca.Storage.configured_adapter() do
      __MODULE__ ->
        raise ArgumentError,
              ":storage_adapter must name a real adapter (Local or S3) — " <>
                "Arca.Overlay is the decorator the facade already wraps around it"

      adapter ->
        adapter
    end
  end

  defp unit_of({:file, unit}), do: unit
  defp unit_of({:dir, unit, _sentinel}), do: unit

  defp leaf_loc(path) do
    case Arca.Storage.locate(path) do
      {:file, _} = loc -> loc
      {:dir, _, _} = loc -> loc
      _above_or_outside -> nil
    end
  end

  # A unit's completion object — a directory copy's sentinel, a file
  # unit's one file — at the unit's own path, and under a revision's
  # prefix.
  defp completion_of({:file, unit}), do: unit
  defp completion_of({:dir, unit, sentinel}), do: unit ++ [sentinel]

  defp completion_in(loc, revision),
    do: UnitLocator.in_revision(loc, revision, completion_of(loc))

  # Whether the committed revision is in its prefix, and whether a
  # revision stands at the unit's own path — the one place a revision
  # served before this shape still is. `exists?/2` is total by the
  # adapter contract, so these probes cannot carry an outage; they decide
  # where a read looks, whose failure direction is a miss, and status
  # surfaces ask `held_state/2` instead.
  defp completion_in_prefix?(actor, loc, revision),
    do: tenant().exists?(actor, completion_in(loc, revision))

  defp completion_at_unit?(actor, loc), do: tenant().exists?(actor, completion_of(loc))

  defp legacy?(actor, loc, revision),
    do: not completion_in_prefix?(actor, loc, revision) and completion_at_unit?(actor, loc)

  # Whether the seed ships the unit — shaped as the grammar declares it,
  # so a stray seed file where a directory unit belongs reads as absent
  # (broken install media is never copied anyway).
  defp seed_unit_present?({:file, unit}), do: seed_exists?(unit)

  defp seed_unit_present?({:dir, unit, _sentinel}) do
    case seed_list_typed(unit) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  # A seed unit without its sentinel is broken install media — the copy
  # could never be marked complete, so refuse before moving a byte.
  defp seed_sentinel_present(seed_dir, sentinel) do
    if Arca.Adapters.Local.exists?(seed_actor(), seed_dir ++ [sentinel]) do
      :ok
    else
      {:error, {:materialize_failed, :seed_sentinel_missing}}
    end
  end

  # Through the facade, so accounting applies as for any caller; this
  # module's own delete callbacks retire the row and clear the staging.
  defp delete_unit(actor, {:file, unit}), do: Arca.delete(actor, unit)
  defp delete_unit(actor, {:dir, unit, _sentinel}), do: Arca.delete_tree(actor, unit)

  # ---------------------------------------------------------------------------
  # Diff plumbing and the seed side
  # ---------------------------------------------------------------------------

  # A file unit's side as pairs: the single relative path `[]`, or none.
  defp file_pairs(get_fun) do
    case get_fun.() do
      {:ok, bytes} -> {:ok, [{[], bytes}]}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  # A directory unit's side as pairs; an absent side is no pairs at all.
  defp subtree_pairs(subtree_fun) do
    case subtree_fun.() do
      {:ok, pairs} -> {:ok, pairs}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  defp diff_pairs(tenant_pairs, seed_pairs) do
    tenant_map = Map.new(tenant_pairs)
    seed_map = Map.new(Enum.reject(seed_pairs, fn {rel, _} -> excluded?(rel) end))

    added = Map.keys(tenant_map) -- Map.keys(seed_map)
    removed = Map.keys(seed_map) -- Map.keys(tenant_map)

    changed =
      for {rel, bytes} <- tenant_map,
          Map.has_key?(seed_map, rel) and Map.fetch!(seed_map, rel) != bytes,
          do: rel

    %{added: Enum.sort(added), removed: Enum.sort(removed), changed: Enum.sort(changed)}
  end

  # Unit completeness from an already-walked leaf list at the unit's own
  # path, where a revision served before this shape may still stand: a
  # file unit is its own leaf; a directory unit is complete when its
  # sentinel leaf is present.
  defp completed_in_leaves?({:file, unit}, unit_leaves), do: unit in unit_leaves

  defp completed_in_leaves?({:dir, unit, sentinel}, unit_leaves),
    do: (unit ++ [sentinel]) in unit_leaves

  defp excluded?(relative), do: Arca.Storage.build_dropping?(relative)

  defp seed([root | rest]), do: Arca.Storage.seed_prefix(root) ++ rest

  # The seed side is always the Local adapter, reading install media in
  # place — whatever tenant adapter is configured.
  defp seed_get(path), do: Arca.Adapters.Local.get(seed_actor(), seed(path))
  defp seed_exists?(path), do: Arca.Adapters.Local.exists?(seed_actor(), seed(path))
  defp seed_list_typed(path), do: Arca.Adapters.Local.list_typed(seed_actor(), seed(path))

  # Total in practice (Local answers {:ok, []} for a missing tree), but
  # the adapter tuple propagates — install media that cannot be listed is
  # a fault, not an empty bundle.
  defp seed_list_recursive(path) do
    with {:ok, leaves} <- Arca.Adapters.Local.list_recursive(seed_actor(), seed(path)) do
      {:ok, Enum.map(leaves, &Arca.Storage.seed_logical/1)}
    end
  end

  defp seed_read_subtree(path),
    do: Arca.Storage.read_subtree_via(Arca.Adapters.Local, seed_actor(), seed(path))

  # The context the overlay's DIRECT `Arca.Adapters.Local` seed reads run
  # under — the one read path that does not pass through the `Arca` facade.
  # Its safety rests on three facts stated in three modules, gathered here:
  # the facade's `authorize_path/2` would admit a system context anyway
  # (`Arca.Storage`), the adapter itself refuses seed WRITES
  # (`Arca.Adapters.Local.refuse_seed_write!/1`), and the seed tree is
  # tracked source, never tenant data. If any of the three moves, this
  # bypass must move with it.
  # The server acting as itself: no athanor, platform scope, and the
  # system authority `Arca.Storage.authorize_path/2` requires of anything
  # that reads the seed roots.
  defp seed_actor, do: Prima.Actor.system()
end
