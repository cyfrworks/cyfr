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
  in an estate; the newer units read as `:available` until pulled.

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
       token, moves the pointer and appends one journal row;
    4. finish: move the staged objects to the served location — the
       unit's own path, where every reader reads — the sentinel last, and
       remove the prefix.

  A crash before step 3 publishes nothing: readers keep the previous
  revision, or no unit. A failure in step 4 is never a lost commit: the
  row stands, the staged objects stay under their prefix, the answer is
  `{:error, {:finish_failed, reason}}` and `repair_unit/2` finishes the
  move. Repair reads only the prefix of the revision the row names, and
  promotes it only when it hashes to the identity the journal recorded
  for that revision, so neither a losing writer's objects nor the
  remainder of a move that stopped part-way through removing its own
  prefix is ever served over a unit.

  ## What a reader sees while step 4 runs

  Where the tenant adapter can swap a tree
  (`c:Arca.Storage.replace_tree/3`, the Local adapter) readers of the
  served location see the previous revision whole and then the new one.
  Where it cannot — an object store, which has no rename — the move is
  object by object (`serve_each/3`): the pointer and the journal already
  name the new revision, each object changes whole, and a reader between
  the first object and the last can see some objects of the new revision
  and some of the one before it. The unit still reads complete
  throughout, since its completion object is served the whole time and
  written last. A reader that must have one revision whole pins it
  (`Arca.StorageGC.pin/4`) and reads the staged prefix, which is
  immutable.

  A reader resolves the row once per operation. A unit reads complete
  when its row is committed AND its served completion object — a
  directory unit's sentinel, a file unit's file — is there: a complete
  object set no row names is at most a partial, and a row whose served
  objects were cleared points at nothing a reader could read. There is no
  lock: a plain write into a unit is an edit of its served objects, last
  writer wins per object, a commit replaces the unit whole, and
  `update/3` is the read-modify-write that loses neither
  (`c:Arca.Storage.put_if_match/4`).

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
  retires its row first.

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
  alias Arca.StorageUnits
  alias Sanctum.Context

  @internal_writes_key {__MODULE__, :internal_writes}

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

  # ---------------------------------------------------------------------------
  # Arca.Storage callbacks — reads answer from the athanor's tree alone.
  # ---------------------------------------------------------------------------

  @impl true
  def get(%Context{} = ctx, path), do: tenant().get(ctx, path)

  @impl true
  def put(%Context{} = ctx, path, content) do
    with :ok <- writable(path), do: tenant().put(ctx, path, content)
  end

  @impl true
  def append(%Context{} = ctx, path, content) do
    with :ok <- writable(path), do: tenant().append(ctx, path, content)
  end

  @impl true
  def delete(%Context{} = ctx, path) do
    with :ok <- deletable(path),
         :ok <- retire_at_unit(ctx, path),
         :ok <- tenant().delete(ctx, path) do
      clear_staging_at_unit(ctx, path)
    end
  end

  @impl true
  def delete_tree(%Context{} = ctx, path) do
    with :ok <- tree_deletable(ctx, path),
         :ok <- deletable(path),
         :ok <- retire_at_unit(ctx, path),
         :ok <- tenant().delete_tree(ctx, path) do
      clear_staging_at_unit(ctx, path)
    end
  end

  # A delete AT a unit is the unit's removal, so its row goes first: a
  # reader never finds a committed pointer over a tree being cleared. A
  # unit with no row, or one already retired, deletes as plain bytes.
  defp retire_at_unit(ctx, path) do
    case at_unit(path) do
      nil ->
        :ok

      unit ->
        {root, key} = UnitLocator.unit_key(unit)

        case StorageUnits.retire(Context.actor(ctx), root, key) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, _} = error -> error
        end
    end
  end

  # What the unit staged goes with it. The facade's accounting for the
  # delete has already dropped the cached usage.
  defp clear_staging_at_unit(ctx, path) do
    case at_unit(path) do
      nil -> :ok
      unit -> tenant().delete_tree(ctx, UnitLocator.staging_prefix(unit))
    end
  end

  defp at_unit(path) do
    case Arca.Storage.locate(path) do
      {:file, ^path} -> path
      {:dir, ^path, _sentinel} -> path
      _inside_above_or_outside -> nil
    end
  end

  # Tree deletion above units is allowed only when no tenant units exist
  # beneath the path; otherwise it returns `{:error, :above_unit}`: a
  # populated subtree is cleared one unit at a time, so each unit's row is
  # retired with it. The empty-tree check and deletion are not atomic with
  # a new unit commit.
  defp tree_deletable(%Context{} = ctx, path) do
    if not internal_writes?() and Arca.Storage.locate(path) == :above_unit do
      case tenant().list_recursive(ctx, path) do
        {:ok, leaves} ->
          if Enum.any?(leaves, &leaf_loc/1), do: {:error, :above_unit}, else: :ok

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  @impl true
  def exists?(%Context{} = ctx, path), do: tenant().exists?(ctx, path)

  # The conditional writes, the versioned read and the prefix listing pass
  # through to the tenant adapter under the same write shapes the
  # unconditional ones are held to. The staging registry's own calls go
  # straight to the tenant adapter (`Arca.Storage.put_if_none_match/3` and
  # its kin), which is why nothing here filters staging out of
  # `list_prefix/2` as `list_recursive/2` does: a key listing of a staging
  # area is exactly what that callback is for.

  @impl true
  def put_if_none_match(%Context{} = ctx, path, content) do
    with :ok <- writable(path), do: tenant().put_if_none_match(ctx, path, content)
  end

  @impl true
  def put_if_match(%Context{} = ctx, path, content, precondition) do
    with :ok <- writable(path), do: tenant().put_if_match(ctx, path, content, precondition)
  end

  @impl true
  def get_for_update(%Context{} = ctx, path), do: tenant().get_for_update(ctx, path)

  @impl true
  def list_prefix(%Context{} = ctx, prefix), do: tenant().list_prefix(ctx, prefix)

  # Inside a directory unit or outside the units; the tenant adapter
  # decides whether it can swap at all.
  @impl true
  def replace_tree(%Context{} = ctx, path, files) do
    with :ok <- replaceable(path) do
      adapter = tenant()

      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :replace_tree, 3),
        do: adapter.replace_tree(ctx, path, files),
        else: {:error, :atomic_replace_unsupported}
    end
  end

  @impl true
  def usage(%Context{} = ctx, path), do: tenant().usage(ctx, path)

  @impl true
  def ensure_dir(%Context{} = ctx, path), do: tenant().ensure_dir(ctx, path)

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, path, opts),
    do: tenant().serve_to_conn(conn, ctx, path, opts)

  # A root's staging area is this module's bookkeeping, never the
  # athanor's content: a listing made from above it does not show it. A
  # listing of the area itself answers plainly — that is how a staged
  # revision is validated and repaired. `usage/2` still counts it: staged
  # bytes are bytes the athanor holds.
  @impl true
  def list_typed(%Context{} = ctx, path) do
    with {:ok, entries} <- tenant().list_typed(ctx, path) do
      {:ok, Enum.reject(entries, fn {name, _kind} -> UnitLocator.staging?(path ++ [name]) end)}
    end
  end

  @impl true
  def list_recursive(%Context{} = ctx, path) do
    with {:ok, leaves} <- tenant().list_recursive(ctx, path) do
      if UnitLocator.staging?(path),
        do: {:ok, leaves},
        else: {:ok, Enum.reject(leaves, &UnitLocator.staging?/1)}
    end
  end

  # No read_subtree here: the facade's shared algorithm
  # (`Arca.Storage.read_subtree_via/4`) runs over this module's
  # `list_recursive/2` + `get/2`.

  # ---------------------------------------------------------------------------
  # Unit status — the public questions the tree can answer about itself.
  # `Compendium.Provenance` and the status/reset surfaces consume these.
  # ---------------------------------------------------------------------------

  @doc """
  What one shadow unit holds — see `t:unit_status/0`. A path below a unit
  is answered for its unit; a path above any unit (or outside the seeded
  roots) is `{:ok, :absent}`. The unit's row is resolved once: a copy is
  complete only when the row is committed and the served completion
  object is there. A tenant-adapter or row-store outage answers
  `{:error, term}` — a status surface must not misreport the athanor's
  own units as shipped.
  """
  @spec unit_status(Context.t(), Arca.Storage.path()) ::
          {:ok, unit_status()} | {:error, term()}
  def unit_status(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:ok, :absent}

      loc ->
        # The same classification the batch form applies over its walked
        # leaf sets — the parity test in overlay_test pins the two
        # together.
        with {:ok, published?} <- published?(ctx, unit_of(loc)),
             {:ok, held} <- tenant_unit_state(ctx, loc) do
          {:ok, classify(unit_state(held, published?), seed_unit_present?(loc))}
        end
    end
  end

  @doc """
  Every unit under a seeded root, mapped to its status — the batch form
  of `unit_status/2`: one row query and two listings (tenant and seed), no
  per-unit probes — classifying a leaf is a pure locator call. `:absent`
  units are, by definition, not in the map; `:available` ones are, so a
  caller can see what the seed ships that the athanor lacks. A tenant
  listing or row-store outage answers `{:error, term}`, never a seed-only
  map.
  """
  @spec unit_statuses(Context.t(), String.t()) ::
          {:ok, %{Arca.Storage.path() => unit_status()}} | {:error, term()}
  def unit_statuses(%Context{} = ctx, root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, pointers} <- StorageUnits.current_under(Context.actor(ctx), root),
           {:ok, tenant_leaves} <- tenant().list_recursive(ctx, [root]),
           {:ok, seed_leaves} <- seed_list_recursive([root]) do
        seed_locs = MapSet.new(for leaf <- seed_leaves, loc = leaf_loc(leaf), do: loc)

        tenant_by_loc =
          tenant_leaves
          |> Enum.group_by(&Arca.Storage.locate/1)
          |> Map.drop([:above_unit, :not_overlaid])

        all_locs = MapSet.union(seed_locs, MapSet.new(Map.keys(tenant_by_loc)))

        statuses =
          Map.new(all_locs, fn loc ->
            leaves = Map.get(tenant_by_loc, loc, [])
            {_root, key} = UnitLocator.unit_key(unit_of(loc))

            held =
              cond do
                completed_in_leaves?(loc, leaves) -> :complete
                leaves != [] -> :partial
                true -> :empty
              end

            state = unit_state(held, Map.has_key?(pointers, key))
            {unit_of(loc), classify(state, MapSet.member?(seed_locs, loc))}
          end)

        {:ok, statuses}
      end
    else
      {:ok, %{}}
    end
  end

  # The row is what publishes: served objects no committed row names are
  # at most a partial, however whole they look.
  defp unit_state(:complete, false), do: :partial
  defp unit_state(held, _published?), do: held

  defp published?(ctx, unit) do
    {root, key} = UnitLocator.unit_key(unit)

    case StorageUnits.current(Context.actor(ctx), root, key) do
      {:ok, _pointer} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
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
  @spec diff_unit(Context.t(), Arca.Storage.path()) ::
          {:ok,
           %{
             added: [Arca.Storage.path()],
             removed: [Arca.Storage.path()],
             changed: [Arca.Storage.path()]
           }}
          | {:error, term()}
  def diff_unit(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        {:error, :not_overlaid}

      :above_unit ->
        {:error, :not_a_unit}

      {:file, unit} ->
        with {:ok, tenant_pairs} <- file_pairs(fn -> tenant().get(ctx, unit) end),
             {:ok, seed_pairs} <- file_pairs(fn -> seed_get(unit) end) do
          {:ok, diff_pairs(tenant_pairs, seed_pairs)}
        end

      {:dir, unit, _sentinel} ->
        with {:ok, tenant_pairs} <-
               subtree_pairs(fn -> Arca.Storage.read_subtree_via(tenant(), ctx, unit) end),
             {:ok, seed_pairs} <- subtree_pairs(fn -> seed_read_subtree(unit) end) do
          {:ok, diff_pairs(tenant_pairs, seed_pairs)}
        end
    end
  end

  @doc """
  Whether the athanor's unit differs from what ships — `diff_unit/2` read
  as one boolean. A unit the seed does not ship differs by everything the
  athanor holds there.
  """
  @spec edited?(Context.t(), Arca.Storage.path()) :: {:ok, boolean()} | {:error, term()}
  def edited?(%Context{} = ctx, path) do
    with {:ok, %{added: added, removed: removed, changed: changed}} <- diff_unit(ctx, path) do
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
  restore does over an edited copy. Shipped media is not capped: an estate
  must always be able to hold what the server ships.

  A unit the seed does not ship refuses as `{:error, :not_shipped}`; a
  path that is not a unit as `{:error, :not_a_unit}`.
  """
  @spec pull_shipped(Context.t(), Arca.Storage.path()) ::
          :ok | {:error, :not_shipped | :not_a_unit | :not_overlaid | term()}
  def pull_shipped(%Context{} = ctx, unit) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        cond do
          unit_of(loc) != unit -> {:error, :not_a_unit}
          not seed_unit_present?(loc) -> {:error, :not_shipped}
          true -> do_pull_shipped(ctx, loc)
        end
    end
  end

  defp do_pull_shipped(ctx, {:dir, unit, sentinel}) do
    seed_dir = seed(unit)

    with :ok <- seed_sentinel_present(seed_dir, sentinel),
         {:ok, _written} <-
           commit_unit(ctx, unit, {:tree, seed_dir, exclude: &excluded?/1}, cap: :exempt) do
      Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{ctx.athanor_id}")
      :ok
    end
  end

  defp do_pull_shipped(ctx, {:file, unit}) do
    with {:ok, bytes} <- seed_get(unit),
         {:ok, _written} <- commit_unit(ctx, unit, {:files, [{[], bytes}]}, cap: :exempt) do
      Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{ctx.athanor_id}")
      :ok
    end
  end

  @doc """
  Copy every shipped unit under `root` the athanor does not hold — the
  `:available` ones — leaving what it holds alone, edited or not. What
  fills a fresh estate at provisioning and what heals an estate whose
  tree lost a copy. Answers the units copied; stops at the first unit
  that cannot be copied.
  """
  @spec materialize_shipped(Context.t(), String.t()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def materialize_shipped(%Context{} = ctx, root) when is_binary(root) do
    with {:ok, statuses} <- unit_statuses(ctx, root) do
      statuses
      |> Enum.filter(fn {_unit, status} -> status == :available end)
      |> Enum.map(fn {unit, _status} -> unit end)
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn unit, {:ok, copied} ->
        case pull_shipped(ctx, unit) do
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
  The unit's row is retired before its objects are removed, and what it
  staged goes with it.
  """
  @spec drop_unit(Context.t(), Arca.Storage.path()) ::
          {:ok, :deleted} | {:error, :bundled | :not_found | :not_overlaid | term()}
  def drop_unit(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(ctx, path) do
          {:ok, :own} -> with :ok <- delete_unit(ctx, loc), do: {:ok, :deleted}
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
      explicit (`Sanctum.Tenancy.Caps` documents the roster). Checked
      before the draft is registered and before any write.
    * `sentinel:` — the sentinel's bytes, overriding any sentinel entry
      the source carries (a fork's re-stamped manifest, a pull's
      authoritative config blob). A dir-unit commit with sentinel bytes
      from neither place refuses as `{:error, :missing_sentinel}` before
      any write.
    * `if_absent: true` — create, never replace: asked while this writer
      holds the unit's draft, so no other commit can land between the
      question and this one. A unit whose completion object is already
      served — its sentinel, or a file unit's file, whatever row names it
      — refuses as `{:error, :exists}` before any write.
    * `release_digest:` — the activation identity of a component release,
      recorded on the unit's row; nil for every other unit.

  A file unit commits as `{:files, [{[], bytes}]}` and refuses
  `sentinel:`. A commit over existing tenant content replaces it whole
  (stale files from a prior partial or an overwritten pull do not
  survive).

  Returns the written relatives in write order, sentinel last. Refusals
  of the row: `{:error, :stale_writer}` when another writer's live draft
  holds the unit, `{:error, :stale_revision}` when another commit landed
  first, `{:error, :missing_unit}` when the unit was dropped under this
  writer, `{:error, :invalid_objects}` when what was staged is not what
  was written — in each case nothing is published and the staged objects
  are removed. `{:error, :unavailable}` from the commit leaves the staged
  objects where they are: the outcome is unknown.
  `{:error, {:finish_failed, reason}}` is a published unit whose move to
  the served location did not finish (`repair_unit/2`).
  """
  @spec commit_unit(Context.t(), Arca.Storage.path(), commit_source(), keyword()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def commit_unit(%Context{} = ctx, unit, source, opts) do
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
                "commit_unit needs a unit path; #{inspect(unit)} locates to #{inspect(other)}"
      end

    internal = internal_ctx(ctx)

    # Resolved before the draft and before any write: a commit that could
    # never be completed must not move a byte or hold the unit.
    with {:ok, entries} <- entries(internal, loc, source, override),
         :ok <- check_commit_cap(ctx, cap) do
      write(ctx, internal, loc, opts, fn _draft ->
        if Keyword.get(opts, :if_absent, false) and occupied?(ctx, loc),
          do: {:error, :exists},
          else: {:ok, entries}
      end)
    end
  end

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
          Context.t(),
          Arca.Storage.path(),
          Arca.Storage.path(),
          [{Arca.Storage.path(), binary() | (-> {:ok, binary()} | {:error, term()})}],
          keyword()
        ) :: :ok | {:error, term()}
  def replace_subtree(%Context{} = ctx, unit, [top | _] = subtree, files, opts)
      when is_list(files) do
    cap = Keyword.fetch!(opts, :cap)

    case Arca.Storage.locate(unit) do
      {:dir, ^unit, sentinel} = loc when top != sentinel ->
        internal = internal_ctx(ctx)

        with :ok <- subtree_files(files),
             :ok <- check_commit_cap(ctx, cap),
             {:ok, _written} <-
               write(ctx, internal, loc, opts, fn _draft ->
                 if occupied?(ctx, loc),
                   do: carried_entries(internal, loc, subtree, files),
                   else: {:error, :not_found}
               end) do
          :ok
        end

      other ->
        raise ArgumentError,
              "replace_subtree needs a directory unit and a subtree other than its sentinel; " <>
                "#{inspect(unit)} locates to #{inspect(other)}"
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
  Finish the move of a published unit whose commit answered
  `{:error, {:finish_failed, _}}`, or whose writer died after the row
  commit: the staged objects of the revision the row names are moved to
  the served location and their prefix removed. Only that revision's
  prefix is read — a losing writer's objects are never promoted.

  The staged set is promoted only when it IS the revision the journal
  recorded: its content identity must be the newest commit's
  (`content_identity/1`). What a move that stopped part-way through
  removing its own prefix leaves behind is a subset of a revision that is
  already served whole, and serving it would take the rest of the unit
  with it (`serve_each/3` prunes, a tree swap replaces). Such a remainder
  is `{:error, :staged_incomplete}` and nothing is moved;
  `{:error, :journal_mismatch}` when the newest commit does not name the
  pointer's revision, which is a repair no journal supports.

  `{:ok, :nothing_pending}` when the prefix holds nothing;
  `{:error, :not_found}` for a unit no committed row names.
  """
  @spec repair_unit(Context.t(), Arca.Storage.path()) ::
          {:ok, :repaired | :nothing_pending}
          | {:error, :staged_incomplete | :journal_mismatch | term()}
  def repair_unit(%Context{} = ctx, unit) do
    case Arca.Storage.locate(unit) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        if unit_of(loc) == unit, do: repair(ctx, loc), else: {:error, :not_a_unit}
    end
  end

  defp repair(ctx, loc) do
    unit = unit_of(loc)
    {root, key} = UnitLocator.unit_key(unit)
    actor = Context.actor(ctx)
    internal = internal_ctx(ctx)

    with {:ok, pointer} <- StorageUnits.current(actor, root, key),
         revision = pointer.current_revision,
         {:ok, staged} <- staged_relatives(internal, loc, revision) do
      case staged do
        [] ->
          {:ok, :nothing_pending}

        relatives ->
          with :ok <- staged_as_committed(actor, internal, loc, revision, relatives),
               {:ok, _written} <- finish(internal, loc, revision, in_write_order(loc, relatives)),
               do: {:ok, :repaired}
      end
    end
  end

  # The guard on every promotion: what is staged must hash to what the
  # newest commit recorded, read from the journal the commit appended to.
  defp staged_as_committed(actor, internal, loc, revision, relatives) do
    unit = unit_of(loc)
    {root, key} = UnitLocator.unit_key(unit)

    with {:ok, commits} <- StorageUnits.journal(actor, root, key),
         {:ok, committed} <- newest_commit_of(commits, revision),
         {:ok, manifest} <- staged_manifest(internal, unit, revision, relatives) do
      if content_identity(manifest) == committed, do: :ok, else: {:error, :staged_incomplete}
    end
  end

  defp newest_commit_of(commits, revision) do
    case List.last(commits) do
      %{new_revision: ^revision, content_identity: identity} -> {:ok, identity}
      _no_commit_names_the_pointer -> {:error, :journal_mismatch}
    end
  end

  # The staged objects as a content manifest, one object at a time, so a
  # unit never sits in memory whole.
  defp staged_manifest(internal, unit, revision, relatives) do
    relatives
    |> Enum.reduce_while({:ok, []}, fn rel, {:ok, acc} ->
      case Arca.get(internal, UnitLocator.staged_object(unit, revision, rel)) do
        {:ok, bytes} -> {:cont, {:ok, [{rel, Cyfr.Digest.sha256(bytes), byte_size(bytes)} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, manifest} -> {:ok, Enum.reverse(manifest)}
      {:error, _} = error -> error
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

  `{:error, :conflict}` when the object was still moving after the last
  attempt: nothing was written and asking again is safe.
  `{:error, :not_found}` when nothing is at `path`,
  `{:error, :not_overlaid}` for a path no unit covers, and
  `{:error, :unsupported}` from a store that can give no proof of the
  version it read — an update is refused there rather than made a
  last-writer-wins put.
  """
  @spec update(
          Context.t(),
          Arca.Storage.path(),
          (binary() -> {:ok, binary()} | {:error, term()})
        ) :: :ok | {:error, :conflict | :not_found | :not_overlaid | term()}
  def update(%Context{} = ctx, path, fun) when is_function(fun, 1) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] -> {:error, :not_overlaid}
      _inside_a_unit -> compare_and_set(ctx, path, fun, 1)
    end
  end

  defp compare_and_set(ctx, path, fun, attempt) do
    with {:ok, current, precondition} <- Arca.get_for_update(ctx, path),
         {:ok, bytes} when is_binary(bytes) <- fun.(current) do
      case Arca.put_if_match(ctx, path, bytes, precondition, cap: :checked) do
        :ok ->
          :ok

        # The object moved between the read and the write: nothing was
        # written, so reading it again and applying `fun` to what is there
        # now loses neither writer's work.
        {:error, :precondition_failed} when attempt < @update_attempts ->
          Process.sleep(update_backoff_ms(attempt))
          compare_and_set(ctx, path, fun, attempt + 1)

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

  defp check_commit_cap(ctx, {:checked, bytes}) when is_integer(bytes) and bytes >= 0,
    do: Sanctum.Tenancy.Caps.check_storage(ctx, bytes)

  # Step 1's row half. `gate` is asked while this writer holds the draft,
  # so no other commit can land between its answer and this commit; it
  # answers what to write, or the refusal.
  defp write(ctx, internal, loc, opts, gate) do
    actor = Context.actor(ctx)
    {root, key} = UnitLocator.unit_key(unit_of(loc))
    token = StorageUnits.new_writer_token()

    with {:ok, draft} <- StorageUnits.register_draft(actor, root, key, token) do
      case gate.(draft) do
        {:ok, entries} ->
          with_internal_writes(fn ->
            publish(actor, internal, loc, draft, token, entries, opts)
          end)

        {:error, _} = refusal ->
          StorageUnits.abandon_draft(actor, draft, token)
          refusal
      end
    end
  end

  # What `if_absent:` and a subtree replacement ask under the draft: is
  # the unit's completion object served, whatever row names it? A create
  # must never replace, and hand-laid bytes are still someone's bytes; a
  # replacement carries over what is served. Only a commit's finish writes
  # the served location, so nothing served is ever a losing writer's. A
  # partial (no completion object) is neither: a commit replaces it whole.
  # What the seed ships is not the athanor's until pulled, so it never
  # counts.
  defp occupied?(ctx, loc), do: completed?(ctx, loc)

  # Steps 1–3 on the object side, then the commit. Everything a refusal
  # leaves behind is this revision's own prefix, which goes with it —
  # except when the commit's outcome is unknown.
  defp publish(actor, internal, loc, draft, token, entries, opts) do
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
          commit_identity: actor.user_id || "system",
          release_digest: Keyword.get(opts, :release_digest)
        }

        case StorageUnits.commit(actor, draft, draft.current_revision, token, identity) do
          :committed ->
            finish(internal, loc, revision, Enum.map(manifest, &elem(&1, 0)))

          {:error, :unavailable} = unknown ->
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
      {:ok, Cyfr.Digest.sha256(bytes), byte_size(bytes)}
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
          if Cyfr.Digest.sha256(bytes) == digest,
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

  defp in_write_order({:file, _unit}, relatives), do: relatives

  defp in_write_order({:dir, _unit, sentinel}, relatives) do
    {last, body} = Enum.split_with(relatives, &(&1 == [sentinel]))
    Enum.sort(body) ++ last
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
    |> Cyfr.Digest.sha256_stream()
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

  # Step 4. The commit stands whatever happens here: a failure leaves the
  # staged objects under their prefix for `repair_unit/2`.
  defp finish(internal, loc, revision, relatives) do
    unit = unit_of(loc)

    moved =
      with_internal_writes(fn ->
        with :ok <- serve(internal, loc, revision, relatives) do
          Arca.delete_tree(internal, UnitLocator.revision_prefix(unit, revision))
        end
      end)

    case moved do
      :ok ->
        {:ok, relatives}

      {:error, reason} ->
        Logger.error(
          "[Arca.Overlay] revision #{revision} of #{Enum.join(unit, "/")} is committed but " <>
            "its move to the served location failed (#{inspect(reason)}); repair_unit/2 finishes it"
        )

        {:error, {:finish_failed, reason}}
    end
  end

  defp serve(internal, {:file, unit}, revision, [[]]) do
    with {:ok, bytes} <- Arca.get(internal, UnitLocator.staged_object(unit, revision, [])) do
      Arca.put(internal, UnitLocator.served_path(unit), bytes)
    end
  end

  defp serve(internal, {:dir, unit, _sentinel}, revision, relatives) do
    files =
      for rel <- relatives do
        {rel, fn -> Arca.get(internal, UnitLocator.staged_object(unit, revision, rel)) end}
      end

    case Arca.replace_tree(internal, UnitLocator.served_path(unit), files, cap: :exempt) do
      {:error, :atomic_replace_unsupported} -> serve_each(internal, unit, files)
      answer -> answer
    end
  end

  # The move on an adapter that cannot swap a tree: every object in write
  # order, the sentinel last, then whatever the previous content left
  # beside them.
  defp serve_each(internal, unit, files) do
    with :ok <- clear_file_at(internal, unit),
         :ok <- put_each(internal, unit, files) do
      prune(internal, unit, MapSet.new(files, &elem(&1, 0)))
    end
  end

  # A file where the unit's tree belongs is replaced like any content. It
  # goes through the tenant adapter: the decorator's delete at a unit
  # would retire the row this commit just moved.
  defp clear_file_at(internal, unit) do
    case tenant().list_typed(internal, unit) do
      {:error, :enotdir} ->
        result = tenant().delete(internal, unit)
        Arca.Usage.account(internal, unit, :delete, result)
        result

      {:ok, _entries} ->
        :ok

      {:error, _} = error ->
        error
    end
  end

  defp put_each(internal, unit, files) do
    Enum.reduce_while(files, :ok, fn {rel, read}, :ok ->
      with {:ok, bytes} <- read.(),
           :ok <- Arca.put(internal, unit ++ rel, bytes) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp prune(internal, unit, keep) do
    with {:ok, leaves} <- Arca.list_recursive(internal, unit) do
      leaves
      |> Enum.reject(&MapSet.member?(keep, Enum.drop(&1, length(unit))))
      |> Enum.reduce_while(:ok, fn leaf, :ok ->
        case Arca.delete(internal, leaf) do
          :ok -> {:cont, :ok}
          {:error, :not_found} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  # An internal context focused on the caller's athanor, writing back
  # THROUGH the facade so every committed byte passes the facade's usage
  # accounting like any other write. The user_id is attribution only —
  # the exemption is the lexical internal-write scope.
  defp internal_ctx(%Context{} = ctx) do
    Sanctum.internal_context(user_id: "_overlay", athanor_id: ctx.athanor_id, scope: :athanor)
  end

  # ---------------------------------------------------------------------------
  # Write shapes, and the delete refusal
  # ---------------------------------------------------------------------------

  # A tree is replaced inside a directory unit or outside the units: at a
  # unit, above units, in place of a sentinel or below a file unit it would
  # take a unit's shape with it. A commit's own move replaces the tree AT
  # its directory unit, inside the internal-write scope.
  defp replaceable(path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        :ok

      {:dir, ^path, _sentinel} ->
        if internal_writes?(), do: :ok, else: {:error, :invalid_path}

      {:dir, unit, sentinel} ->
        if path == unit ++ [sentinel], do: {:error, :invalid_path}, else: :ok

      _above_or_at_a_file_unit ->
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

  # The served completion object: a directory copy holds its sentinel
  # file, a file unit its file. `exists?/2` is total by the adapter
  # contract, so this probe cannot carry an outage: it serves the
  # `if_absent:` gate, whose failure direction is safe. Status surfaces
  # ask `tenant_unit_state/2` instead — the error-carrying form.
  defp completed?(ctx, {:file, unit}), do: tenant().exists?(ctx, unit)

  defp completed?(ctx, {:dir, unit, sentinel}),
    do: tenant().exists?(ctx, unit ++ [sentinel])

  # The status-surface probe: what the athanor's own tree holds at the
  # unit, with the error channel the total `exists?/2` probes cannot
  # carry — a status answer must not misreport a copy as `:available`
  # during an adapter outage. `:enotdir` is a real answer (a file where a
  # tree belongs): content, but never a complete copy.
  defp tenant_unit_state(ctx, {:file, unit}) do
    parent = Enum.drop(unit, -1)
    name = List.last(unit)

    case tenant().list_typed(ctx, parent) do
      {:ok, entries} ->
        {:ok, if({name, :file} in entries, do: :complete, else: :empty)}

      {:error, :enotdir} ->
        {:ok, :empty}

      {:error, _} = error ->
        error
    end
  end

  defp tenant_unit_state(ctx, {:dir, unit, sentinel}) do
    case tenant().list_typed(ctx, unit) do
      {:ok, entries} ->
        cond do
          {sentinel, :file} in entries -> {:ok, :complete}
          entries != [] -> {:ok, :partial}
          true -> {:ok, :empty}
        end

      {:error, :enotdir} ->
        {:ok, :partial}

      {:error, _} = error ->
        error
    end
  end

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
    if Arca.Adapters.Local.exists?(seed_ctx(), seed_dir ++ [sentinel]) do
      :ok
    else
      {:error, {:materialize_failed, :seed_sentinel_missing}}
    end
  end

  # Through the facade, so accounting applies as for any caller; this
  # module's own delete callbacks retire the row and clear the staging.
  defp delete_unit(ctx, {:file, unit}), do: Arca.delete(ctx, unit)
  defp delete_unit(ctx, {:dir, unit, _sentinel}), do: Arca.delete_tree(ctx, unit)

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

  # Unit completeness from an already-walked leaf list (the batch form of
  # `completed?/2`): a file unit is its own leaf; a directory unit is
  # complete when its sentinel leaf is present.
  defp completed_in_leaves?({:file, unit}, unit_leaves), do: unit in unit_leaves

  defp completed_in_leaves?({:dir, unit, sentinel}, unit_leaves),
    do: (unit ++ [sentinel]) in unit_leaves

  defp excluded?(relative), do: Arca.Storage.build_dropping?(relative)

  defp seed([root | rest]), do: Arca.Storage.seed_prefix(root) ++ rest

  # The seed side is always the Local adapter, reading install media in
  # place — whatever tenant adapter is configured.
  defp seed_get(path), do: Arca.Adapters.Local.get(seed_ctx(), seed(path))
  defp seed_exists?(path), do: Arca.Adapters.Local.exists?(seed_ctx(), seed(path))
  defp seed_list_typed(path), do: Arca.Adapters.Local.list_typed(seed_ctx(), seed(path))

  # Total in practice (Local answers {:ok, []} for a missing tree), but
  # the adapter tuple propagates — install media that cannot be listed is
  # a fault, not an empty bundle.
  defp seed_list_recursive(path) do
    with {:ok, leaves} <- Arca.Adapters.Local.list_recursive(seed_ctx(), seed(path)) do
      {:ok, Enum.map(leaves, &Arca.Storage.seed_logical/1)}
    end
  end

  defp seed_read_subtree(path),
    do: Arca.Storage.read_subtree_via(Arca.Adapters.Local, seed_ctx(), seed(path))

  # The context the overlay's DIRECT `Arca.Adapters.Local` seed reads run
  # under — the one read path that does not pass through the `Arca` facade.
  # Its safety rests on three facts stated in three modules, gathered here:
  # the facade's `authorize_path/2` would admit a system context anyway
  # (`Arca.Storage`), the adapter itself refuses seed WRITES
  # (`Arca.Adapters.Local.refuse_seed_write!/1`), and the seed tree is
  # tracked source, never tenant data. If any of the three moves, this
  # bypass must move with it.
  defp seed_ctx, do: Sanctum.system_context()
end
