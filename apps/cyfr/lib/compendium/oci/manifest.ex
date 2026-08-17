# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.Manifest do
  @moduledoc """
  OCI Image Manifest builder and parser for CYFR components.

  Maps CYFR components to OCI Image Manifests:
  - Config blob = `cyfr-manifest.json` (application/vnd.cyfr.manifest.v1+json)
  - Layer 0 = WASM binary (application/vnd.cyfr.{type}.v1+wasm)
  - Annotations carry component metadata for registry-level discovery
  - artifactType = application/vnd.cyfr.component.v1
  """

  alias Compendium.OCI.Blob

  # Media type constants
  @manifest_media_type "application/vnd.oci.image.manifest.v1+json"
  @config_media_type "application/vnd.cyfr.manifest.v1+json"
  @artifact_type "application/vnd.cyfr.component.v1"

  @readme_media_type "application/vnd.cyfr.readme.v1+markdown"
  @source_media_type "application/vnd.cyfr.source.v1.tar+gzip"

  @type_media_types %{
    "catalyst" => "application/vnd.cyfr.catalyst.v1+wasm",
    "reagent" => "application/vnd.cyfr.reagent.v1+wasm",
    "formula" => "application/vnd.cyfr.formula.v1+wasm",
    "tincture" => "application/vnd.cyfr.tincture.v1.tar+gzip"
  }

  @doc "OCI Image Manifest media type."
  def manifest_media_type, do: @manifest_media_type

  @doc "CYFR config blob media type."
  def config_media_type, do: @config_media_type

  @doc "CYFR README layer media type."
  def readme_media_type, do: @readme_media_type

  @doc "CYFR source tarball layer media type."
  def source_media_type, do: @source_media_type

  @doc "Get the WASM layer media type for a component type."
  @spec wasm_media_type(String.t()) :: String.t()
  def wasm_media_type(component_type) do
    Map.get(@type_media_types, component_type, "application/vnd.cyfr.reagent.v1+wasm")
  end

  @doc """
  Build an OCI Image Manifest from CYFR component data.

  ## Parameters

  - `config_json` - The cyfr-manifest.json content as a map or JSON string
  - `wasm_bytes` - Raw WASM binary (or tar+gzip bundle for tinctures)
  - `component_type` - One of "catalyst", "reagent", "formula", "tincture"
  - `annotations` - Additional OCI annotations map
  - `opts` - Optional keyword list:
    - `:readme_bytes` - README.md content (adds a README layer)
    - `:source_bytes` - src.tar.gz content (adds a source layer)

  ## Returns

  `{:ok, manifest_json, config_digest, wasm_digest}` where manifest_json is
  the JSON-encoded OCI Image Manifest.
  """
  @spec build(map() | String.t(), binary(), String.t(), map(), keyword()) ::
          {:ok, String.t(), String.t(), String.t()} | {:error, String.t()}
  def build(config_json, wasm_bytes, component_type, annotations \\ %{}, opts \\ []) do
    with {:ok, config_bytes} <- encode_config_json(config_json) do
      config_digest = Blob.compute_digest(config_bytes)
      wasm_digest = Blob.compute_digest(wasm_bytes)
      wasm_media = wasm_media_type(component_type)

      wasm_layer = %{
        "mediaType" => wasm_media,
        "size" => byte_size(wasm_bytes),
        "digest" => wasm_digest
      }

      layers = [wasm_layer]

      layers =
        case Keyword.get(opts, :readme_bytes) do
          nil ->
            layers

          readme when is_binary(readme) ->
            layers ++
              [
                %{
                  "mediaType" => @readme_media_type,
                  "size" => byte_size(readme),
                  "digest" => Blob.compute_digest(readme)
                }
              ]
        end

      layers =
        case Keyword.get(opts, :source_bytes) do
          nil ->
            layers

          source when is_binary(source) ->
            layers ++
              [
                %{
                  "mediaType" => @source_media_type,
                  "size" => byte_size(source),
                  "digest" => Blob.compute_digest(source)
                }
              ]
        end

      manifest = %{
        "schemaVersion" => 2,
        "mediaType" => @manifest_media_type,
        "artifactType" => @artifact_type,
        "config" => %{
          "mediaType" => @config_media_type,
          "size" => byte_size(config_bytes),
          "digest" => config_digest
        },
        "layers" => layers,
        "annotations" => annotations
      }

      case Jason.encode(manifest) do
        {:ok, manifest_json} -> {:ok, manifest_json, config_digest, wasm_digest}
        {:error, reason} -> {:error, "Failed to encode manifest: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Parse an OCI Image Manifest JSON into its component descriptors.

  Returns `{:ok, parsed}` where parsed contains:
  - `:config` - Config descriptor map
  - `:layers` - List of layer descriptor maps
  - `:annotations` - Annotations map
  - `:artifact_type` - The artifactType field
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(manifest_json) when is_binary(manifest_json) do
    case Jason.decode(manifest_json) do
      {:ok, %{"schemaVersion" => 2} = manifest} ->
        config = manifest["config"]
        layers = manifest["layers"] || []
        annotations = manifest["annotations"] || %{}
        artifact_type = manifest["artifactType"]

        {:ok,
         %{
           config: config,
           layers: layers,
           annotations: annotations,
           artifact_type: artifact_type,
           media_type: manifest["mediaType"],
           raw: manifest
         }}

      {:ok, %{"schemaVersion" => v}} ->
        {:error, "Unsupported manifest schema version: #{v}"}

      {:ok, _} ->
        {:error, "Manifest missing schemaVersion"}

      {:error, reason} ->
        {:error, "Invalid manifest JSON: #{inspect(reason)}"}
    end
  end

  @type_media_type_values Map.values(@type_media_types) |> MapSet.new()

  @doc """
  Extract the primary content layer descriptor from a parsed manifest.

  Finds the first layer whose mediaType matches any known CYFR component
  type media type (WASM binary or tincture tar+gzip bundle).
  """
  @spec content_layer(map()) :: {:ok, map()} | {:error, String.t()}
  def content_layer(%{layers: layers}) do
    layer =
      Enum.find(layers, fn layer ->
        MapSet.member?(@type_media_type_values, layer["mediaType"] || "")
      end)

    case layer do
      nil -> {:error, "No content layer found in manifest"}
      found -> {:ok, found}
    end
  end

  @doc """
  Extract the WASM layer descriptor from a parsed manifest.
  Returns the first layer with a CYFR WASM media type.

  For type-agnostic lookups, prefer `content_layer/1`.
  """
  @spec wasm_layer(map()) :: {:ok, map()} | {:error, String.t()}
  def wasm_layer(%{layers: layers}) do
    wasm =
      Enum.find(layers, fn layer ->
        media = layer["mediaType"] || ""
        String.starts_with?(media, "application/vnd.cyfr.") and String.ends_with?(media, "+wasm")
      end)

    case wasm do
      nil -> {:error, "No WASM layer found in manifest"}
      layer -> {:ok, layer}
    end
  end

  @doc """
  Extract the README layer descriptor from a parsed manifest.
  Returns `{:ok, layer}` or `:none` if no README layer is present.
  """
  @spec readme_layer(map()) :: {:ok, map()} | :none
  def readme_layer(%{layers: layers}) do
    case Enum.find(layers, fn layer -> layer["mediaType"] == @readme_media_type end) do
      nil -> :none
      layer -> {:ok, layer}
    end
  end

  @doc """
  Extract the source tarball layer descriptor from a parsed manifest.
  Returns `{:ok, layer}` or `:none` if no source layer is present.
  """
  @spec source_layer(map()) :: {:ok, map()} | :none
  def source_layer(%{layers: layers}) do
    case Enum.find(layers, fn layer -> layer["mediaType"] == @source_media_type end) do
      nil -> :none
      layer -> {:ok, layer}
    end
  end

  @doc """
  Build standard CYFR annotations from component metadata.
  """
  @spec build_annotations(map()) :: map()
  def build_annotations(metadata) do
    base = %{
      "org.opencontainers.image.title" => metadata[:name] || metadata["name"],
      "org.opencontainers.image.version" => metadata[:version] || metadata["version"],
      "dev.cyfr.component.type" => metadata[:type] || metadata["type"],
      "dev.cyfr.component.publisher" =>
        Compendium.ComponentPath.normalize_publisher(
          metadata[:publisher] || metadata["publisher"]
        )
    }

    base
    |> maybe_put(
      "org.opencontainers.image.description",
      metadata[:description] || metadata["description"]
    )
    |> maybe_put("org.opencontainers.image.licenses", metadata[:license] || metadata["license"])
    |> maybe_put("dev.cyfr.component.category", metadata[:category] || metadata["category"])
  end

  defp encode_config_json(s) when is_binary(s), do: {:ok, s}

  defp encode_config_json(m) when is_map(m) do
    case Jason.encode(m) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, "Failed to encode config: #{inspect(reason)}"}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
