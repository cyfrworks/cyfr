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

  ## The sentinel — crash-safe unit commits

  "Completed" is a fact the tree itself records: every valid directory
  unit carries its sentinel file, and `commit_unit/4` — the one way a
  unit lands, for scaffold, fork, publish, OCI pull and the shipped copy
  alike — writes it LAST. A crash or failure
  mid-commit leaves the unit without its sentinel, so it keeps reading
  as incomplete, and an error return rolls the partial back; the next
  commit replaces whatever remains wholesale. No hidden marker file: the
  sentinel is an ordinary, digest-counted member of the unit. A file
  unit is atomic by construction — a single put — and counts as
  completed when the tenant file exists. A build's output replaces one
  subtree of a completed unit (`replace_subtree/5`) and never touches its
  sentinel; readers see the previous subtree until the new one is whole.

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
  edit. The athanor's own units delete plainly.

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
  # Arca.Storage callbacks — reads answer from the athanor's tree alone;
  # writes ride the unit lock.
  # ---------------------------------------------------------------------------

  @impl true
  def get(%Context{} = ctx, path), do: tenant().get(ctx, path)

  @impl true
  def put(%Context{} = ctx, path, content) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- writable(path) do
        tenant().put(ctx, path, content)
      end
    end)
  end

  @impl true
  def append(%Context{} = ctx, path, content) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- writable(path) do
        tenant().append(ctx, path, content)
      end
    end)
  end

  @impl true
  def delete(%Context{} = ctx, path) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- deletable(path), do: tenant().delete(ctx, path)
    end)
  end

  @impl true
  def delete_tree(%Context{} = ctx, path) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- tree_deletable(ctx, path),
           :ok <- deletable(path) do
        tenant().delete_tree(ctx, path)
      end
    end)
  end

  # Tree deletion above units is allowed only when no tenant units exist
  # beneath the path; otherwise it returns `{:error, :above_unit}`.
  # Clear populated subtrees one unit at a time under each unit's lock.
  # The empty-tree check and deletion are not atomic with a new unit commit.
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

  # Under the containing unit's lock, inside a directory unit or outside
  # the units; the tenant adapter decides whether it can swap at all.
  @impl true
  def replace_tree(%Context{} = ctx, path, files) do
    with_unit_lock(ctx, path, fn ->
      with :ok <- replaceable(path) do
        adapter = tenant()

        if Code.ensure_loaded?(adapter) and function_exported?(adapter, :replace_tree, 3),
          do: adapter.replace_tree(ctx, path, files),
          else: {:error, :atomic_replace_unsupported}
      end
    end)
  end

  @impl true
  def usage(%Context{} = ctx, path), do: tenant().usage(ctx, path)

  @impl true
  def ensure_dir(%Context{} = ctx, path), do: tenant().ensure_dir(ctx, path)

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, path, opts),
    do: tenant().serve_to_conn(conn, ctx, path, opts)

  @impl true
  def list_typed(%Context{} = ctx, path), do: tenant().list_typed(ctx, path)

  @impl true
  def list_recursive(%Context{} = ctx, path), do: tenant().list_recursive(ctx, path)

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
  roots) is `{:ok, :absent}`. A tenant-adapter outage answers
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
        with {:ok, state} <- tenant_unit_state(ctx, loc) do
          {:ok, classify(state, seed_unit_present?(loc))}
        end
    end
  end

  @doc """
  Every unit under a seeded root, mapped to its status — the batch form
  of `unit_status/2`: two listings total (tenant and seed), no per-unit
  probes — classifying a leaf is a pure locator call. `:absent` units
  are, by definition, not in the map; `:available` ones are, so a caller
  can see what the seed ships that the athanor lacks. A tenant listing
  outage answers `{:error, term}`, never a seed-only map.
  """
  @spec unit_statuses(Context.t(), String.t()) ::
          {:ok, %{Arca.Storage.path() => unit_status()}} | {:error, term()}
  def unit_statuses(%Context{} = ctx, root) when is_binary(root) do
    if root in Arca.Storage.overlay_roots() do
      with {:ok, tenant_leaves} <- tenant().list_recursive(ctx, [root]),
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

            state =
              cond do
                completed_in_leaves?(loc, leaves) -> :complete
                leaves != [] -> :partial
                true -> :empty
              end

            {unit_of(loc), classify(state, MapSet.member?(seed_locs, loc))}
          end)

        {:ok, statuses}
      end
    else
      {:ok, %{}}
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
  droppings excluded, the sentinel last — replacing whatever stands at
  the path. What provisioning does for every shipped unit, what a pull of
  a shipped version does for one, and what a restore does over an edited
  copy. Shipped media is not capped: an estate must always be able to
  hold what the server ships.

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
           with_unit_lock_at(ctx, unit, fn ->
             do_commit_dir_unit(
               ctx,
               unit,
               sentinel,
               {:tree, seed_dir, exclude: &excluded?/1},
               :exempt,
               nil
             )
           end) do
      Logger.info("[Arca.Overlay] copied shipped #{Enum.join(unit, "/")} for #{ctx.athanor_id}")
      :ok
    end
  end

  # A file unit lands as one put — atomic by construction.
  defp do_pull_shipped(ctx, {:file, unit}) do
    with {:ok, bytes} <- seed_get(unit),
         :ok <- Arca.put(ctx, unit, bytes, cap: :exempt) do
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
  """
  @spec drop_unit(Context.t(), Arca.Storage.path()) ::
          {:ok, :deleted} | {:error, :bundled | :not_found | :not_overlaid | term()}
  def drop_unit(%Context{} = ctx, path) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        case unit_status(ctx, path) do
          {:ok, :own} -> with :ok <- delete_unit_locked(ctx, loc), do: {:ok, :deleted}
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
  Land one whole unit: refuse-or-replace, write the non-sentinel files,
  sentinel LAST — and on any error, delete the partial. Every ingress
  that lays a unit (scaffold, fork, publish, OCI pull, the shipped copy)
  commits through here, so sentinel-last,
  rollback, cap policy and usage accounting are one implementation, not
  a discipline each caller re-spells.

  Options:

    * `cap:` (required) — `:exempt` or `{:checked, bytes}`. Every call
      site states its policy, so the uncapped-by-design set stays
      explicit (`Sanctum.Tenancy.Caps` documents the roster).
    * `sentinel:` — the sentinel's bytes, overriding any sentinel entry
      the source carries (a fork's re-stamped manifest, a pull's
      authoritative config blob). A dir-unit commit with sentinel bytes
      from neither place refuses as `{:error, :missing_sentinel}` before
      any write.
    * `if_absent: true` — create, never replace: the athanor's tree is
      asked for the unit INSIDE its lock, and a complete unit already
      there refuses as `{:error, :exists}` before any write. A probe
      outside the lock (`exists?`, then commit) is a check-then-act race:
      two creators of one name could both pass it, and the second would
      silently replace the first.

  A file unit commits as one plain facade put — atomic by construction —
  and refuses `sentinel:`. A dir-unit commit over existing tenant content
  replaces it whole (stale files from a prior partial or an overwritten
  pull do not survive).

  Returns the written relatives in write order, sentinel last.
  """
  @spec commit_unit(Context.t(), Arca.Storage.path(), commit_source(), keyword()) ::
          {:ok, [Arca.Storage.path()]} | {:error, term()}
  def commit_unit(%Context{} = ctx, unit, source, opts) do
    cap = Keyword.fetch!(opts, :cap)
    override = Keyword.get(opts, :sentinel)
    if_absent? = Keyword.get(opts, :if_absent, false)

    case Arca.Storage.locate(unit) do
      {:file, ^unit} ->
        commit_file_unit(ctx, unit, source, cap, override, if_absent?)

      {:dir, ^unit, sentinel} ->
        commit_dir_unit(ctx, unit, sentinel, source, cap, override, if_absent?)

      other ->
        raise ArgumentError,
              "commit_unit needs a unit path; #{inspect(unit)} locates to #{inspect(other)}"
    end
  end

  @doc """
  One locked read-modify-write at a path inside a unit. `fun` receives
  the bytes at `path` and answers `{:ok, bytes}` to write them — a plain
  facade put, so the storage cap applies as for any write — or
  `{:error, reason}` to write nothing and answer that. The read and the
  write ride one hold of the unit's lock, so of two concurrent updates
  the second reads what the first wrote instead of overwriting it.
  `{:error, :not_found}` when nothing is at `path`,
  `{:error, :not_overlaid}` for a path no unit covers — there is no lock
  to hold there, and this must not promise one.
  """
  @spec update(
          Context.t(),
          Arca.Storage.path(),
          (binary() -> {:ok, binary()} | {:error, term()})
        ) :: :ok | {:error, term()}
  def update(%Context{} = ctx, path, fun) when is_function(fun, 1) do
    case Arca.Storage.locate(path) do
      loc when loc in [:not_overlaid, :above_unit] ->
        {:error, :not_overlaid}

      loc ->
        with_unit_lock_at(ctx, unit_of(loc), fn ->
          with {:ok, current} <- Arca.get(ctx, path) do
            case fun.(current) do
              {:ok, bytes} when is_binary(bytes) -> Arca.put(ctx, path, bytes)
              {:error, _reason} = error -> error
            end
          end
        end)
    end
  end

  @doc """
  Replace one subtree of a complete directory unit with `files`, under one
  hold of the unit's lock. `subtree` is relative to the unit and `files`
  relative to the subtree; nothing else in the unit — its sentinel
  included — is touched, and a concurrent writer to the unit waits for the
  whole replacement.

  The replacement is `Arca.replace_tree/4`: readers see the previous
  subtree until the new one is whole, then the new one, and a replacement
  that fails before the swap leaves the previous subtree whole and
  readable. On an adapter that cannot swap a tree
  (`c:Arca.Storage.replace_tree/3`, which an object store does not export)
  it refuses with `{:error, :atomic_replace_unsupported}`.

  `cap:` (required) is `commit_unit/4`'s, checked before any write.
  `{:error, :not_found}` when the unit is not complete.
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
      {:dir, ^unit, sentinel} when top != sentinel ->
        with_unit_lock_at(ctx, unit, fn ->
          with :ok <- complete_unit(internal_ctx(ctx), unit, sentinel) do
            Arca.replace_tree(ctx, unit ++ subtree, files, cap: cap)
          end
        end)

      other ->
        raise ArgumentError,
              "replace_subtree needs a directory unit and a subtree other than its sentinel; " <>
                "#{inspect(unit)} locates to #{inspect(other)}"
    end
  end

  defp complete_unit(ctx, unit, sentinel) do
    if Arca.exists?(ctx, unit ++ [sentinel]), do: :ok, else: {:error, :not_found}
  end

  # A file unit's completing write IS the caller's one atomic put: no
  # sentinel, no rollback (failure leaves the previous bytes).
  defp commit_file_unit(ctx, unit, {:files, [{[], content}]}, cap, nil, if_absent?) do
    # `cap: :exempt` on the put because the commit's own required policy
    # was just applied above — the caller stated it, and the one check is
    # this commit's, not the write gate's.
    with {:ok, bytes} <- resolve_content(content),
         :ok <- check_commit_cap(ctx, cap),
         :ok <- put_file_unit(ctx, unit, bytes, if_absent?) do
      {:ok, [[]]}
    end
  end

  defp commit_file_unit(_ctx, unit, _source, _cap, _override, _if_absent?) do
    raise ArgumentError,
          "a file unit (#{Enum.join(unit, "/")}) commits as {:files, [{[], bytes}]} " <>
            "with no sentinel: — the put is the commit"
  end

  # The presence probe and the put ride one hold of the unit's lock; the
  # nested facade put passes through the held-unit register.
  defp put_file_unit(ctx, unit, bytes, if_absent?) do
    with_unit_lock_at(ctx, unit, fn ->
      with :ok <- refuse_present(ctx, {:file, unit}, if_absent?) do
        Arca.put(ctx, unit, bytes, cap: :exempt)
      end
    end)
  end

  # Under the unit's lock: `clean_slate/2` clears the whole unit, so two of
  # these interleaving means the second one deletes the first one's files —
  # including files a caller has already been told were written. Nothing
  # inside a single commit can detect that; they simply must not overlap.
  defp commit_dir_unit(ctx, unit, sentinel, source, cap, override, if_absent?) do
    with_unit_lock_at(ctx, unit, fn ->
      with :ok <- refuse_present(ctx, {:dir, unit, sentinel}, if_absent?) do
        do_commit_dir_unit(ctx, unit, sentinel, source, cap, override)
      end
    end)
  end

  # `if_absent:` — a unit is present when the athanor holds a completed
  # copy. A partial (a crashed commit: no sentinel) is not — the commit
  # replaces it whole, as any commit would. What the seed ships is not
  # the athanor's until pulled, so it never counts as present here.
  defp refuse_present(_ctx, _loc, false), do: :ok

  defp refuse_present(ctx, loc, true) do
    if completed?(ctx, loc), do: {:error, :exists}, else: :ok
  end

  # The lock is per athanor and per unit: two athanors publishing the same
  # component name are different trees and never contend.
  defp lock_key(%Context{athanor_id: athanor_id}, unit), do: {athanor_id, unit}

  # ---------------------------------------------------------------------------
  # The unit lock, taken by the mutating callbacks themselves
  # ---------------------------------------------------------------------------

  # Serialize writes, appends and deletes under the containing unit's lock.
  #
  # UnitLock is not reentrant. Track locks held by this process so nested
  # Arca writes reuse the outer acquisition.
  #
  # Deletes above units are allowed only when no units remain beneath them.
  # To clear a subtree, drop each unit under its own lock first.
  @held_units_key {__MODULE__, :held_unit_locks}

  defp with_unit_lock(%Context{} = ctx, path, fun) do
    case Arca.Storage.locate(path) do
      {:file, unit} -> with_unit_lock_at(ctx, unit, fun)
      {:dir, unit, _sentinel} -> with_unit_lock_at(ctx, unit, fun)
      _not_overlaid_or_above_unit -> fun.()
    end
  end

  defp with_unit_lock_at(%Context{} = ctx, unit, fun) do
    key = lock_key(ctx, unit)
    held = Process.get(@held_units_key, MapSet.new())

    if MapSet.member?(held, key) do
      fun.()
    else
      Arca.Overlay.UnitLock.with_lock(key, fn ->
        Process.put(@held_units_key, MapSet.put(held, key))

        try do
          fun.()
        after
          Process.put(@held_units_key, held)
        end
      end)
    end
  end

  defp do_commit_dir_unit(ctx, unit, sentinel, source, cap, override) do
    internal = internal_ctx(ctx)

    with {:ok, sentinel_content} <- sentinel_bytes(internal, sentinel, source, override),
         :ok <- check_commit_cap(ctx, cap) do
      result =
        with_internal_writes(fn ->
          with :ok <- clean_slate(internal, unit),
               {:ok, written} <- write_source(internal, unit, sentinel, source),
               # The completion mark: the sentinel lands last, so a crash
               # anywhere above leaves the unit reading as incomplete and
               # the rollback (or the next commit) clears the remains.
               :ok <- Arca.put(internal, unit ++ [sentinel], sentinel_content) do
            {:ok, written ++ [[sentinel]]}
          end
        end)

      case result do
        {:ok, _written} = ok ->
          ok

        {:error, reason} = error ->
          with_internal_writes(fn -> rollback(ctx, unit, reason) end)
          error
      end
    end
  end

  # Resolved before any write: a commit that could never be completed
  # must not move a byte.
  defp sentinel_bytes(_internal, _sentinel, _source, override) when is_binary(override),
    do: {:ok, override}

  defp sentinel_bytes(_internal, sentinel, {:files, files}, nil) do
    case List.keyfind(files, [sentinel], 0) do
      {_rel, content} -> resolve_content(content)
      nil -> {:error, :missing_sentinel}
    end
  end

  defp sentinel_bytes(internal, sentinel, {:tree, src, _opts}, nil) do
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

  # A commit replaces the unit whole: stale files from a prior partial or
  # an overwritten pull must not survive beside the new content. Probed
  # first so a fresh-target commit never invalidates the usage counters
  # for nothing.
  defp clean_slate(internal, unit) do
    case tenant().list_typed(internal, unit) do
      {:ok, [_ | _]} -> Arca.delete_tree(internal, unit)
      {:ok, []} -> :ok
      # A file where the unit's tree belongs — replaced like any content.
      {:error, :enotdir} -> Arca.delete(internal, unit)
      {:error, _} = error -> error
    end
  end

  defp write_source(internal, unit, sentinel, {:files, files}) do
    files
    |> Enum.reject(fn {rel, _content} -> rel == [sentinel] end)
    |> Enum.reduce_while({:ok, []}, fn {rel, content}, {:ok, acc} ->
      with {:ok, bytes} <- resolve_content(content),
           :ok <- Arca.put(internal, unit ++ rel, bytes) do
        {:cont, {:ok, [rel | acc]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      {:error, _} = error -> error
    end
  end

  defp write_source(internal, unit, sentinel, {:tree, src, opts}) do
    exclude = Keyword.get(opts, :exclude, fn _relative -> false end)

    Arca.copy_tree(internal, src, unit,
      exclude: fn relative -> relative == [sentinel] or exclude.(relative) end
    )
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
  # take a unit's shape with it.
  defp replaceable(path) do
    case Arca.Storage.locate(path) do
      :not_overlaid ->
        :ok

      {:dir, unit, sentinel} ->
        if path in [unit, unit ++ [sentinel]], do: {:error, :invalid_path}, else: :ok

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
  # internal-write scope is exempt (its rollback and its replace delete
  # what it lays).
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

  # The completeness test: is the athanor's copy of the unit COMPLETE? A
  # directory copy is complete when it holds its sentinel file; a file
  # unit when the tenant file exists. `exists?/2` is total by the adapter
  # contract, so these probes cannot carry an outage: they serve the
  # write gates, whose failure directions are safe. Status surfaces ask
  # `tenant_unit_state/2` instead — the error-carrying form.
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

  # A failed commit must not linger: without its sentinel the partial unit
  # already reads as incomplete, but its bytes would count against the
  # cap and confuse direct reads of paths the write never reached. If the
  # rollback itself fails, the unit is stuck holding a partial — say so
  # loudly; the next successful commit replaces it wholesale.
  defp rollback(ctx, unit_dir, reason) do
    case Arca.delete_tree(internal_ctx(ctx), unit_dir) do
      :ok ->
        :ok

      {:error, rollback_reason} ->
        Logger.error(
          "[Arca.Overlay] unit commit at #{Enum.join(unit_dir, "/")} failed " <>
            "(#{inspect(reason)}) AND its rollback failed (#{inspect(rollback_reason)}) — " <>
            "a partial remains until the next commit replaces it"
        )

        :ok
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

  # Through the facade, so accounting applies as for any caller.
  defp delete_unit(ctx, {:file, unit}), do: Arca.delete(ctx, unit)
  defp delete_unit(ctx, {:dir, unit, _sentinel}), do: Arca.delete_tree(ctx, unit)

  # Serialize whole-unit deletion with commits using the same unit lock.
  defp delete_unit_locked(ctx, loc) do
    with_unit_lock_at(ctx, unit_of(loc), fn -> delete_unit(ctx, loc) end)
  end

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
