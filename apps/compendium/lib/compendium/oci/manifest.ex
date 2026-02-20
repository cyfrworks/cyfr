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

  @type_media_types %{
    "catalyst" => "application/vnd.cyfr.catalyst.v1+wasm",
    "reagent" => "application/vnd.cyfr.reagent.v1+wasm",
    "formula" => "application/vnd.cyfr.formula.v1+wasm"
  }

  @doc "OCI Image Manifest media type."
  def manifest_media_type, do: @manifest_media_type

  @doc "CYFR config blob media type."
  def config_media_type, do: @config_media_type

  @doc "CYFR artifact type."
  def artifact_type, do: @artifact_type

  @doc "Get the WASM layer media type for a component type."
  @spec wasm_media_type(String.t()) :: String.t()
  def wasm_media_type(component_type) do
    Map.get(@type_media_types, component_type, "application/vnd.cyfr.reagent.v1+wasm")
  end

  @doc """
  Build an OCI Image Manifest from CYFR component data.

  ## Parameters

  - `config_json` - The cyfr-manifest.json content as a map or JSON string
  - `wasm_bytes` - Raw WASM binary
  - `component_type` - One of "catalyst", "reagent", "formula"
  - `annotations` - Additional OCI annotations map

  ## Returns

  `{:ok, manifest_json, config_digest, wasm_digest}` where manifest_json is
  the JSON-encoded OCI Image Manifest.
  """
  @spec build(map() | String.t(), binary(), String.t(), map()) ::
          {:ok, String.t(), String.t(), String.t()}
  def build(config_json, wasm_bytes, component_type, annotations \\ %{}) do
    config_bytes =
      case config_json do
        s when is_binary(s) -> s
        m when is_map(m) -> Jason.encode!(m)
      end

    config_digest = Blob.compute_digest(config_bytes)
    wasm_digest = Blob.compute_digest(wasm_bytes)
    wasm_media = wasm_media_type(component_type)

    manifest = %{
      "schemaVersion" => 2,
      "mediaType" => @manifest_media_type,
      "artifactType" => @artifact_type,
      "config" => %{
        "mediaType" => @config_media_type,
        "size" => byte_size(config_bytes),
        "digest" => config_digest
      },
      "layers" => [
        %{
          "mediaType" => wasm_media,
          "size" => byte_size(wasm_bytes),
          "digest" => wasm_digest
        }
      ],
      "annotations" => annotations
    }

    {:ok, Jason.encode!(manifest), config_digest, wasm_digest}
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

        {:ok, %{
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

  @doc """
  Check if a parsed manifest is a CYFR component.
  """
  @spec cyfr_component?(map()) :: boolean()
  def cyfr_component?(%{artifact_type: @artifact_type}), do: true
  def cyfr_component?(%{config: %{"mediaType" => @config_media_type}}), do: true
  def cyfr_component?(_), do: false

  @doc """
  Extract the WASM layer descriptor from a parsed manifest.
  Returns the first layer with a CYFR WASM media type.
  """
  @spec wasm_layer(map()) :: {:ok, map()} | {:error, String.t()}
  def wasm_layer(%{layers: layers}) do
    wasm = Enum.find(layers, fn layer ->
      media = layer["mediaType"] || ""
      String.starts_with?(media, "application/vnd.cyfr.") and String.ends_with?(media, "+wasm")
    end)

    case wasm do
      nil -> {:error, "No WASM layer found in manifest"}
      layer -> {:ok, layer}
    end
  end

  @doc """
  Infer the component type from a WASM layer media type.
  """
  @spec component_type_from_media(String.t()) :: String.t() | nil
  def component_type_from_media(media_type) do
    Enum.find_value(@type_media_types, fn {type, mt} ->
      if mt == media_type, do: type
    end)
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
      "dev.cyfr.component.publisher" => metadata[:publisher] || metadata["publisher"] || "local"
    }

    base
    |> maybe_put("org.opencontainers.image.description", metadata[:description] || metadata["description"])
    |> maybe_put("org.opencontainers.image.licenses", metadata[:license] || metadata["license"])
    |> maybe_put("dev.cyfr.component.category", metadata[:category] || metadata["category"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
