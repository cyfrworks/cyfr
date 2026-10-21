# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Compendium.Activation do
  @moduledoc """
  The resolved code identity of an execution graph: every node it can reach
  statically, mapped to the release digest actually installed.

  A consent governs the *shape* of what a component may do; an activation
  records the exact code that shape was granted to. Recording it per
  execution is what makes "the same version, different bytes" detectable
  after the fact — a version string cannot say that, and the artifact
  digest alone says nothing about declared capability.

  Nodes are keyed by **name-level ref** (`type:namespace.name`, no version),
  matching `Prima.Authority.Blob`'s node-key grammar — code identity lives
  in the digest, never in the key.

  Only static dependencies are walked. Dynamic dispatch is deliberately
  outside the graph: a dynamically reached component holds no authority, so
  there is nothing for an activation to attest about it.

  Resolution is **all or nothing** over what the manifest requires. A node
  whose release digest is missing (a row published before release digests
  existed) or whose required dependency is not installed makes the whole
  activation `:incomplete`, and nothing is recorded — a partial graph
  would read as a complete attestation. The refusal names what is
  missing, so a person can be told: `{:missing_release_digest, key}` the
  node with no digest, `{:unresolvable_dependency, ref}` the name-level ref
  of the required dependency that is not installed, or of the node whose
  dependencies cannot be read. A dependency the manifest marks
  `optional` and that is not installed is simply absent from the graph:
  the attestation covers what can run, and when the component arrives the
  graph — and so the digest — changes with it. Only a dependency the
  registry answers `:not_found` for is not installed; any other answer —
  a store that cannot answer, a registry projection not yet caught up —
  is the resolution's own error, never an absence.

  A node whose stored manifest does not decode, the root's or any
  dependency's, is damage: `{:corrupt, {:manifest, key}}`, `key` the
  node's name-level ref. Read as declaring nothing, it would walk no
  dependencies and, for a release whose manifest declares no security
  block, recompute the digest it was published with and verify as
  intact.

  The rows are the `components` root's projection, so a resolution first
  waits for it (`Compendium.ProjectionReconciler.await/2`), before its
  cache is asked: `{:error, :projection_unavailable}` rather than a graph
  of rows the tree has moved past.
  """

  alias Sanctum.Context
  alias Prima.JCS

  require Logger

  # Mirrors Compendium.DependencyResolver's traversal bound.
  @max_depth 10

  @type graph :: %{String.t() => String.t()}
  @type t :: %{digest: String.t(), graph: graph()}

  @type error ::
          {:incomplete,
           {:missing_release_digest | :unresolvable_dependency, String.t()} | :depth_exceeded}
          | {:invalid_graph, JCS.error()}
          | {:corrupt, {:manifest, String.t()}}
          | :projection_unavailable
          | :unavailable
          | :database_error
          | :no_athanor

  # A resolved graph is a function of the athanor's registered rows; it is
  # cached briefly per root (node key + release digest) under the registry
  # epoch read before its walk, and read only under the epoch current then
  # (`Arca.Cache.Epoch`): the registry's sweep advances the epoch before it
  # drops the entries (`Compendium.Registry.invalidate_executor_caches/1`),
  # so a graph walked before a change answers no read that begins after it.
  @cache_ttl_ms :timer.seconds(60)

  @doc """
  Resolve the activation of a component row and its static closure.

  Returns `{:ok, %{digest: digest, graph: graph}}` or `{:error, reason}`.
  A warm root answers from `Arca.Cache` without a walk; the telemetry
  event `[:cyfr, :compendium, :activation, :resolve]` says which.
  """
  @spec resolve(Context.t(), map()) :: {:ok, t()} | {:error, error()}
  def resolve(%Context{} = ctx, component) when is_map(component) do
    with :ok <- Compendium.ProjectionReconciler.await(ctx, "components"),
         do: resolve_current(ctx, component)
  end

  defp resolve_current(ctx, component) do
    case cache_key(ctx, component) do
      nil ->
        resolve_uncached(ctx, component)

      key ->
        epoch = Arca.Cache.Epoch.current(epoch_key(ctx))

        case Arca.Cache.Epoch.get(key, epoch) do
          {:ok, %{digest: _, graph: _} = activation} ->
            emit_resolve(ctx, component, true)
            {:ok, activation}

          _ ->
            with {:ok, activation} <- resolve_uncached(ctx, component) do
              Arca.Cache.Epoch.put(key, epoch, activation, @cache_ttl_ms)
              {:ok, activation}
            end
        end
    end
  end

  defp epoch_key(%Context{athanor_id: athanor_id}),
    do: Arca.Cache.Keys.registry_epoch(Prima.Actor.in_athanor(athanor_id))

  defp resolve_uncached(ctx, component) do
    with {:ok, rows} <- walk(ctx, component, %{}, 0),
         graph = graph_from_rows(rows),
         {:ok, digest} <- hash_graph(graph) do
      emit_resolve(ctx, component, false)
      {:ok, %{digest: digest, graph: graph}}
    end
  end

  defp cache_key(%Context{athanor_id: athanor_id}, component)
       when is_binary(athanor_id) and athanor_id != "" do
    case release_digest(component) do
      digest when is_binary(digest) ->
        Arca.Cache.Keys.activation(
          Prima.Actor.in_athanor(athanor_id),
          Prima.ComponentRow.node_key(component),
          digest
        )

      _ ->
        nil
    end
  end

  defp cache_key(_ctx, _component), do: nil

  defp emit_resolve(ctx, component, cached?) do
    :telemetry.execute(
      [:cyfr, :compendium, :activation, :resolve],
      %{count: 1},
      %{
        athanor_id: ctx.athanor_id,
        node_key: Prima.ComponentRow.node_key(component),
        cached: cached?
      }
    )
  end

  @type verified_node :: %{release_digest: String.t(), integrity: :ok | :mismatch}

  @doc """
  Resolve the activation and verify each node's stored release digest
  against a recomputation from its artifact digest and manifest.

  A `release_digest` column that no longer matches its own inputs means the
  row was altered outside the publish path — the consent loader treats that
  as tampering, never as a new release.
  """
  @spec resolve_verified(Context.t(), map()) ::
          {:ok, %{digest: String.t(), graph: graph(), nodes: %{String.t() => verified_node()}}}
          | {:error, error()}
  def resolve_verified(%Context{} = ctx, component) when is_map(component) do
    with :ok <- Compendium.ProjectionReconciler.await(ctx, "components"),
         {:ok, rows} <- walk(ctx, component, %{}, 0),
         graph = graph_from_rows(rows),
         {:ok, digest} <- hash_graph(graph) do
      # Deliberately uncached (verification must be fresh) — but it is the
      # walk on the consent-load hot path, so it must be visible in the
      # same telemetry the cached resolve emits, or its cost is invisible.
      emit_resolve(ctx, component, false)

      nodes =
        Map.new(rows, fn {key, {row, manifest}} ->
          {key, %{release_digest: release_digest(row), integrity: integrity(row, manifest)}}
        end)

      {:ok, %{digest: digest, graph: graph, nodes: nodes}}
    end
  end

  defp integrity(row, manifest) do
    case Compendium.ReleaseDigest.compute(field(row, :digest), manifest) do
      {:ok, recomputed} ->
        if recomputed == release_digest(row), do: :ok, else: :mismatch

      {:error, _} ->
        :mismatch
    end
  end

  defp graph_from_rows(rows),
    do: Map.new(rows, fn {key, {row, _manifest}} -> {key, release_digest(row)} end)

  # ============================================================================
  # Private
  # ============================================================================

  defp walk(_ctx, _component, _acc, depth) when depth > @max_depth do
    {:error, {:incomplete, :depth_exceeded}}
  end

  # Accumulates the full component row and its decoded manifest per node
  # key; resolve/2 and resolve_verified/2 project what they need from them.
  defp walk(ctx, component, acc, depth) do
    key = Prima.ComponentRow.node_key(component)

    cond do
      Map.has_key?(acc, key) ->
        # Already recorded — a cycle or a diamond, both fine.
        {:ok, acc}

      is_nil(release_digest(component)) ->
        {:error, {:incomplete, {:missing_release_digest, key}}}

      true ->
        with {:ok, manifest} <- manifest(component, key) do
          acc = Map.put(acc, key, {component, manifest})

          case Compendium.DependencyResolver.extract_from_manifest(manifest) do
            {:ok, deps} -> walk_deps(ctx, deps, acc, depth)
            {:error, _} -> {:error, {:incomplete, {:unresolvable_dependency, key}}}
          end
        end
    end
  end

  defp walk_deps(ctx, deps, acc, depth) do
    Enum.reduce_while(deps, {:ok, acc}, fn dep, {:ok, acc} ->
      case resolve_dependency(ctx, dep) do
        {:ok, row} ->
          case walk(ctx, row, acc, depth + 1) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _} = error -> {:halt, error}
          end

        {:error, :not_found} ->
          if dep.optional == true,
            do: {:cont, {:ok, acc}},
            else: {:halt, {:error, {:incomplete, {:unresolvable_dependency, dep_ref(dep)}}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Behind the barrier `resolve/2` passed: the rows read here are the
  # projection it waited for.
  defp resolve_dependency(ctx, dep) do
    if dep.dep_version do
      Arca.ComponentStorage.get_component(
        Sanctum.Context.actor(ctx),
        dep.dep_name,
        dep.dep_version,
        dep.dep_namespace,
        dep.dep_type
      )
    else
      # A versionless dep must resolve to the same release everywhere — the
      # activation digest is computed from this row, so "latest" is the
      # registry's semver-aware pick, never adapter row order.
      Compendium.Registry.latest_row(ctx, dep.dep_name, dep.dep_namespace, dep.dep_type)
    end
  end

  # The name-level ref a dependency names, as a graph keys its node.
  defp dep_ref(dep), do: Prima.ComponentRef.build(dep.dep_type, dep.dep_namespace, dep.dep_name)

  defp release_digest(component), do: field(component, :release_digest)

  # Component rows arrive atom-keyed, as Ecto structs from storage and as
  # plain maps from the registry; neither implements Access.
  defp field(component, key), do: Map.get(component, key)

  # A stored manifest that does not decode is the node's damage, which
  # fails the whole resolution. The line names the node, never the
  # manifest's bytes.
  defp manifest(row, key) do
    case Prima.Manifest.decode_strict(field(row, :manifest)) do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, :malformed_manifest} ->
        Logger.warning("[Compendium.Activation] manifest malformed: #{key}")
        {:error, {:corrupt, {:manifest, key}}}
    end
  end

  defp hash_graph(graph) do
    case JCS.hash(graph) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, {:invalid_graph, reason}}
    end
  end

  @doc """
  Encode a graph for storage. The stored form is the same canonical JSON the
  digest is computed over, so a recorded graph always re-hashes to its
  recorded digest.
  """
  @spec encode_graph(graph()) :: {:ok, String.t()} | {:error, error()}
  def encode_graph(graph) do
    case JCS.encode(graph) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:invalid_graph, reason}}
    end
  end
end
