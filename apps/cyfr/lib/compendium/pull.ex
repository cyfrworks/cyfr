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
  whole closure its bundle needs. A `local` ref names the server's own
  shipped media: `pull_shipped/2` copies it from the seed tree instead.

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
  Copy a shipped component into the caller's athanor and register it: a
  `local` ref names what the server ships, so the pull is from the seed
  tree, never a registry. A versionless ref takes the newest shipped
  version. Its baseline consent is `Compendium.Provisioning.install_shipped/2`'s
  to mint, as the first fill did for what shipped then.

  `{:error, :not_shipped}` when the seed carries no such version;
  `{:error, :not_local}` for a ref outside the `local` namespace.
  """
  @spec pull_shipped(Context.t(), String.t()) ::
          {:ok, %{status: String.t(), component_ref: String.t()}} | {:error, term()}
  def pull_shipped(%Context{} = ctx, reference) when is_binary(reference) do
    with {:ok, %Cyfr.ComponentRef{} = cref} <- Cyfr.ComponentRef.parse(reference),
         :ok <- local_ref(cref),
         {:ok, version} <- shipped_version(cref),
         unit =
           Compendium.ComponentPath.version_dir(cref.type, cref.namespace, cref.name, version),
         :ok <- Arca.Overlay.pull_shipped(ctx, unit),
         {:ok, _} <- Compendium.Registry.register_from_arca(ctx, unit) do
      pulled = %Cyfr.ComponentRef{cref | version: version}
      {:ok, %{status: "pulled", component_ref: Cyfr.ComponentRef.to_string(pulled)}}
    end
  end

  defp local_ref(%Cyfr.ComponentRef{namespace: namespace}) do
    if Compendium.ComponentPath.local_publisher?(namespace), do: :ok, else: {:error, :not_local}
  end

  # The version the seed ships for the ref: the named one when it does,
  # else the newest.
  defp shipped_version(%Cyfr.ComponentRef{} = cref) do
    with {:ok, versions} <- Compendium.Provenance.shipped_versions(cref.type, cref.name) do
      cond do
        is_nil(cref.version) and versions != [] -> {:ok, hd(versions)}
        cref.version in versions -> {:ok, cref.version}
        true -> {:error, :not_shipped}
      end
    end
  end

  @doc """
  The static dependencies of a registered component's manifest that are
  not present in the caller's athanor, as ref strings. The required ones
  by default; `include: :all` adds the optional ones.
  """
  @spec missing_deps(Context.t(), map(), keyword()) :: [String.t()]
  def missing_deps(%Context{} = ctx, component, opts \\ []) when is_map(component) do
    manifest = Cyfr.Manifest.decode(Map.get(component, :manifest))

    with {:ok, deps} <-
           DependencyResolver.extract_from_manifest(manifest, component_id(component)) do
      %{missing: missing, optional_missing: optional} =
        DependencyResolver.classify_availability(ctx, deps)

      wanted =
        case Keyword.get(opts, :include, :required) do
          :all -> missing ++ optional
          :required -> missing
        end

      Enum.map(wanted, & &1.dependency_ref)
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
    case Cyfr.ComponentRef.parse(reference) do
      {:ok, %Cyfr.ComponentRef{namespace: ns} = cref} ->
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
    case Cyfr.ComponentRef.parse(ref) do
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
         {:ok, component, _} <- Compendium.Component.resolve_component(ctx, pulled_ref) do
      {:ok, component}
    end
  end

  defp component_id(%{id: id}) when is_binary(id), do: id
  defp component_id(component), do: to_string(component[:name] || "component")

  defp to_oci_ref(%Cyfr.ComponentRef{version: nil} = cref) do
    registry = Compendium.RegistryHost.canonical_host()

    # Ask whether there is a registry BEFORE resolving a tag: the tag list is
    # an HTTP call of its own, made before `Client.pull/2` reaches its own
    # host check, so an appliance with no registry would dial one to be told
    # it has none.
    with :ok <- registry_configured(),
         {:ok, oci_ref} <- Reference.from_component_ref(cref, registry) do
      case resolve_latest_oci_tag(oci_ref) do
        {:ok, tag} -> {:ok, Reference.to_string(%{oci_ref | tag: tag})}
        {:error, _} -> {:ok, Reference.to_string(oci_ref)}
      end
    end
  end

  defp to_oci_ref(%Cyfr.ComponentRef{} = cref) do
    registry = Compendium.RegistryHost.canonical_host()

    with :ok <- registry_configured(),
         {:ok, oci_ref} <- Reference.from_component_ref(cref, registry) do
      {:ok, Reference.to_string(oci_ref)}
    end
  end

  defp registry_configured do
    if Compendium.RegistryHost.configured?(),
      do: :ok,
      else: {:error, Compendium.OCI.Errors.unconfigured()}
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
            # Non-semver tags drop entirely — a remote's "latest" or
            # "1.2.3.4" is never a release candidate.
            semver_tags =
              tags
              |> Enum.filter(&Compendium.Semver.semver?/1)
              |> Compendium.Semver.sort_desc()

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
end
