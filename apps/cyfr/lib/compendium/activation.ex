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
  matching `Sanctum.Authority.Blob`'s node-key grammar — code identity lives
  in the digest, never in the key.

  Only static dependencies are walked. Dynamic dispatch is deliberately
  outside the graph: a dynamically reached component holds no authority, so
  there is nothing for an activation to attest about it.

  Resolution is **all or nothing**. A node whose release digest is missing
  (a row published before release digests existed) or whose dependency
  cannot be found makes the whole activation `:incomplete`, and nothing is
  recorded — a partial graph would read as a complete attestation.
  """

  alias Sanctum.ComponentRef
  alias Sanctum.Context
  alias Sanctum.JCS

  # Mirrors Compendium.DependencyResolver's traversal bound.
  @max_depth 10

  @type graph :: %{String.t() => String.t()}
  @type t :: %{digest: String.t(), graph: graph()}

  @type error ::
          {:incomplete, :missing_release_digest | :unresolvable_dependency | :depth_exceeded}
          | {:invalid_graph, JCS.error()}

  @doc """
  Resolve the activation of a component row and its static closure.

  Returns `{:ok, %{digest: digest, graph: graph}}` or `{:error, reason}`.
  """
  @spec resolve(Context.t(), map()) :: {:ok, t()} | {:error, error()}
  def resolve(%Context{} = ctx, component) when is_map(component) do
    with {:ok, rows} <- walk(ctx, component, %{}, 0),
         graph = graph_from_rows(rows),
         {:ok, digest} <- hash_graph(graph) do
      {:ok, %{digest: digest, graph: graph}}
    end
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
    with {:ok, rows} <- walk(ctx, component, %{}, 0),
         graph = graph_from_rows(rows),
         {:ok, digest} <- hash_graph(graph) do
      nodes =
        Map.new(rows, fn {key, row} ->
          {key, %{release_digest: release_digest(row), integrity: integrity(row)}}
        end)

      {:ok, %{digest: digest, graph: graph, nodes: nodes}}
    end
  end

  defp integrity(row) do
    manifest = Compendium.Manifest.decode(field(row, :manifest))

    case Compendium.ReleaseDigest.compute(field(row, :digest), manifest) do
      {:ok, recomputed} ->
        if recomputed == release_digest(row), do: :ok, else: :mismatch

      {:error, _} ->
        :mismatch
    end
  end

  defp graph_from_rows(rows), do: Map.new(rows, fn {key, row} -> {key, release_digest(row)} end)

  @doc """
  The name-level key a component row occupies in an activation graph.
  """
  @spec node_key(map()) :: String.t()
  def node_key(component) do
    type = field(component, :component_type)
    publisher = Compendium.ComponentPath.normalize_publisher(field(component, :publisher))
    name = field(component, :name)

    "#{type}:#{publisher}.#{name}"
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp walk(_ctx, _component, _acc, depth) when depth > @max_depth do
    {:error, {:incomplete, :depth_exceeded}}
  end

  # Accumulates the full component row per node key; resolve/2 and
  # resolve_verified/2 project what they need from the rows.
  defp walk(ctx, component, acc, depth) do
    key = node_key(component)

    cond do
      Map.has_key?(acc, key) ->
        # Already recorded — a cycle or a diamond, both fine.
        {:ok, acc}

      is_nil(release_digest(component)) ->
        {:error, {:incomplete, :missing_release_digest}}

      true ->
        acc = Map.put(acc, key, component)
        manifest = Compendium.Manifest.decode(field(component, :manifest))

        case Compendium.DependencyResolver.extract_from_manifest(manifest, key) do
          {:ok, deps} -> walk_deps(ctx, deps, acc, depth)
          {:error, _} -> {:error, {:incomplete, :unresolvable_dependency}}
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

        {:error, _} ->
          {:halt, {:error, {:incomplete, :unresolvable_dependency}}}
      end
    end)
  end

  defp resolve_dependency(ctx, dep) do
    if dep.dep_version do
      Arca.ComponentStorage.get_component(
        ctx,
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

  defp release_digest(component), do: field(component, :release_digest)

  # Component rows arrive as Ecto structs from storage and as plain maps
  # from the registry's build path; neither implements Access.
  defp field(component, key) do
    Map.get(component, key) || Map.get(component, Atom.to_string(key))
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

  @doc """
  The name-level ref of a parsed or string component reference — the same
  spelling `node_key/1` produces from a row.
  """
  @spec key_for_ref(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def key_for_ref(ref) when is_binary(ref), do: ComponentRef.to_name_ref(ref)
end
