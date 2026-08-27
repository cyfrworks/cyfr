# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Pull do
  @moduledoc """
  Pull published components — and what they depend on — into an athanor.

  A component ref (`catalyst:moonmoon69.claude`, with or without a version)
  becomes an OCI reference on the canonical registry (`oci_reference_for/1`,
  resolving the latest semver tag when no version is given) and is pulled
  through `Compendium.OCI.Client.pull/2`, which registers the component in
  the caller's athanor. `ensure_published_deps/2` walks a set of refs and
  every static dependency of what it pulled, so a seeded athanor holds the
  whole closure its bundle needs. Local-publisher refs are never pulled:
  they are registered, not fetched.

  The pull credential is the caller's (`Compendium.OCI.Auth` selects it by
  `ctx.user_id`); a server-internal context pulls anonymously, which is
  enough for public components.
  """

  require Logger

  alias Compendium.DependencyResolver
  alias Compendium.OCI.{Client, Reference, Transport}
  alias Sanctum.Context

  @type outcome :: %{pulled: [String.t()], failed: [{String.t(), term()}], present: [String.t()]}

  @type progress :: :pulling | :pulled | {:failed, term()}

  @doc """
  Make sure every ref in `refs`, and everything those pull depend on, is
  registered in the caller's athanor. Refs already present are left alone.

  `on_progress: fn ref, progress -> _ end` is told about every ref this
  walk pulls (`:pulling`, then `:pulled` or `{:failed, reason}`) — the
  register/pull tools relay it to the console and the CLI.
  """
  @spec ensure_published_deps(Context.t(), [String.t()], keyword()) :: outcome()
  def ensure_published_deps(%Context{} = ctx, refs, opts \\ []) when is_list(refs) do
    on_progress = Keyword.get(opts, :on_progress, fn _ref, _progress -> :ok end)

    {outcome, _visited} =
      Enum.reduce(refs, {%{pulled: [], failed: [], present: []}, MapSet.new()}, fn ref, acc ->
        walk(ctx, ref, acc, on_progress)
      end)

    %{
      pulled: Enum.reverse(outcome.pulled),
      failed: Enum.reverse(outcome.failed),
      present: Enum.reverse(outcome.present)
    }
  end

  @doc """
  The static dependencies of a registered component's manifest that are
  not present in the caller's athanor, as ref strings.
  """
  @spec missing_deps(Context.t(), map()) :: [String.t()]
  def missing_deps(%Context{} = ctx, component) when is_map(component) do
    manifest = Compendium.Manifest.decode(Map.get(component, :manifest))

    with {:ok, deps} <-
           DependencyResolver.extract_from_manifest(manifest, component_id(component)) do
      %{missing: missing} = DependencyResolver.classify_availability(ctx, deps)
      Enum.map(missing, & &1.dependency_ref)
    else
      _ -> []
    end
  end

  @doc """
  The OCI reference (as a string) a component ref pulls from: the canonical
  registry, and the latest semver tag when the ref names no version.
  """
  @spec oci_reference_for(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def oci_reference_for(reference) when is_binary(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, %Sanctum.ComponentRef{namespace: ns} = cref} ->
        case Compendium.NamespacePolicy.refuse_remote_ingress(ns) do
          :ok -> to_oci_ref(cref)
          {:error, _message} = refused -> refused
        end

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  # ---- internal --------------------------------------------------------------

  defp walk(ctx, ref, {outcome, visited}, on_progress) do
    cond do
      MapSet.member?(visited, ref) ->
        {outcome, visited}

      present?(ctx, ref) ->
        {%{outcome | present: [ref | outcome.present]}, MapSet.put(visited, ref)}

      true ->
        visited = MapSet.put(visited, ref)
        on_progress.(ref, :pulling)

        case pull(ctx, ref) do
          {:ok, component} ->
            on_progress.(ref, :pulled)
            outcome = %{outcome | pulled: [ref | outcome.pulled]}

            Enum.reduce(missing_deps(ctx, component), {outcome, visited}, fn dep, acc ->
              walk(ctx, dep, acc, on_progress)
            end)

          {:error, reason} ->
            Logger.warning("[Compendium.Pull] #{ref}: #{inspect(reason)}")
            on_progress.(ref, {:failed, reason})
            {%{outcome | failed: [{ref, reason} | outcome.failed]}, visited}
        end
    end
  end

  defp present?(ctx, ref) do
    case Sanctum.ComponentRef.parse(ref) do
      {:ok, cref} ->
        dep = %{
          dep_name: cref.name,
          dep_version: cref.version,
          dep_namespace: cref.namespace,
          dep_type: cref.type
        }

        DependencyResolver.classify_availability(ctx, [dep]).all_satisfied

      _ ->
        false
    end
  end

  defp pull(ctx, ref) do
    with {:ok, oci_ref} <- oci_reference_for(ref),
         {:ok, %{component_ref: pulled_ref}} <- Client.pull(ctx, oci_ref),
         {:ok, component, _} <- Compendium.MCP.Shared.resolve_component(ctx, pulled_ref) do
      {:ok, component}
    end
  end

  defp component_id(%{id: id}) when is_binary(id), do: id
  defp component_id(component), do: to_string(component[:name] || "component")

  defp to_oci_ref(%Sanctum.ComponentRef{version: nil} = cref) do
    registry = Compendium.RegistryHost.canonical_host()
    {:ok, oci_ref} = Reference.from_component_ref(cref, registry)

    case resolve_latest_oci_tag(oci_ref) do
      {:ok, tag} -> {:ok, Reference.to_string(%{oci_ref | tag: tag})}
      {:error, _} -> {:ok, Reference.to_string(oci_ref)}
    end
  end

  defp to_oci_ref(%Sanctum.ComponentRef{} = cref) do
    registry = Compendium.RegistryHost.canonical_host()
    {:ok, oci_ref} = Reference.from_component_ref(cref, registry)
    {:ok, Reference.to_string(oci_ref)}
  end

  # Resolve the latest semver tag from an OCI repository (for versionless pulls).
  # Public `/tags/list` read (anonymous on cyfr.run) — passes `nil` ctx.
  defp resolve_latest_oci_tag(%Reference{} = ref) do
    path = "/v2/#{ref.repository}/tags/list"

    case Transport.request(nil, :get, path, ref) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"tags" => tags}} when is_list(tags) ->
            # Descending Version-aware sort (prereleases order correctly:
            # 1.0.0-rc1 < 1.0.0), so the head is the latest release.
            semver_tags =
              tags
              |> Enum.filter(&semver_tag?/1)
              |> Enum.sort(fn a, b -> not version_gt?(b, a) end)

            case semver_tags do
              [latest | _] -> {:ok, latest}
              [] -> {:error, :no_semver_tags}
            end

          _ ->
            {:error, :unexpected_response}
        end

      _ ->
        {:error, :tags_fetch_failed}
    end
  end

  defp semver_tag?(tag), do: Regex.match?(~r/^\d+\.\d+\.\d+/, tag)

  defp version_gt?(a, b) when is_binary(a) and is_binary(b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) == :gt
      _ -> a > b
    end
  end
end
