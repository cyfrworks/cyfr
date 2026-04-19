defmodule Compendium.OCI.Reference do
  @moduledoc """
  Parse and build OCI Distribution reference strings.

  An OCI reference has the form:
    `registry/repository:tag` or `registry/repository@sha256:digest`

  CYFR components map to OCI repositories via the convention:
    `<registry>/<publisher>/<type>s/<name>:<version>`

  Examples:
    - `registry.cyfr.run/alice/catalysts/claude:0.1.0` (Core apex)
    - `registry.acme.example/team/reagents/data-processor:1.2.0` (Arx self-hosted)

  Post-auth-refactor scope is single-registry: cyfr talks to the apex cyfr.run
  (Core) or a self-deployed cyfr.run (Arx). Generic OCI registries like ghcr.io
  are not in the supported set — see auth_refactor.md §1.6.
  """

  @type t :: %__MODULE__{
          registry: String.t(),
          repository: String.t(),
          tag: String.t() | nil,
          digest: String.t() | nil,
          default_registry: boolean()
        }

  defstruct [:registry, :repository, :tag, :digest, default_registry: false]

  # Compile-time fallback for the OCI host when neither `:cyfr, :oci_registry_url`
  # nor an explicit registry-prefix in the ref is available. At runtime we
  # prefer `default_registry/0` below so Arx deployments with
  # `CYFR_OCI_REGISTRY_URL` picked up there too.
  @default_registry_fallback "registry.cyfr.run"
  @default_tag "latest"

  defp default_registry do
    Application.get_env(:cyfr, :oci_registry_url, @default_registry_fallback)
  end

  @doc """
  Parse an OCI reference string into a `%Reference{}`.

  ## Examples

      iex> Compendium.OCI.Reference.parse("registry.cyfr.run/alice/catalysts/claude:0.1.0")
      {:ok, %Compendium.OCI.Reference{
        registry: "registry.cyfr.run",
        repository: "alice/catalysts/claude",
        tag: "0.1.0",
        digest: nil,
        default_registry: false
      }}

      iex> Compendium.OCI.Reference.parse("registry.acme.example/team/reagents/data-processor:1.2.0")
      {:ok, %Compendium.OCI.Reference{
        registry: "registry.acme.example",
        repository: "team/reagents/data-processor",
        tag: "1.2.0",
        digest: nil,
        default_registry: false
      }}

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(ref) when is_binary(ref) do
    ref = String.trim(ref)

    if ref == "" do
      {:error, "OCI reference cannot be empty"}
    else
      do_parse(ref)
    end
  end

  def parse(_), do: {:error, "OCI reference must be a string"}

  @doc """
  Convert an OCI reference struct to its string representation.

  ## Examples

      iex> ref = %Compendium.OCI.Reference{registry: "registry.cyfr.run", repository: "alice/catalysts/claude", tag: "0.1.0"}
      iex> Compendium.OCI.Reference.to_string(ref)
      "registry.cyfr.run/alice/catalysts/claude:0.1.0"

  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{registry: reg, repository: repo, tag: nil, digest: digest})
      when is_binary(digest) do
    "#{reg}/#{repo}@#{digest}"
  end

  def to_string(%__MODULE__{registry: reg, repository: repo, tag: tag}) do
    "#{reg}/#{repo}:#{tag || @default_tag}"
  end

  @doc """
  Build an OCI reference from a `Sanctum.ComponentRef` and a registry hostname.

  Maps the CYFR convention: `<registry>/<publisher>/<type>s/<name>:<version>`

  ## Examples

      iex> component_ref = %Sanctum.ComponentRef{type: "catalyst", namespace: "alice", name: "claude", version: "0.1.0"}
      iex> Compendium.OCI.Reference.from_component_ref(component_ref, "registry.cyfr.run")
      {:ok, %Compendium.OCI.Reference{
        registry: "registry.cyfr.run",
        repository: "alice/catalysts/claude",
        tag: "0.1.0"
      }}

  """
  @spec from_component_ref(Sanctum.ComponentRef.t(), String.t()) ::
          {:ok, t()} | {:error, String.t()}
  def from_component_ref(%Sanctum.ComponentRef{} = cref, registry) when is_binary(registry) do
    repository = "#{cref.namespace}/#{cref.type}s/#{cref.name}"

    {:ok,
     %__MODULE__{
       registry: registry,
       repository: repository,
       tag: cref.version
     }}
  end

  @doc """
  Convert an OCI reference back to a `Sanctum.ComponentRef`.

  Expects the CYFR repository convention: `<publisher>/<type>s/<name>`

  ## Examples

      iex> ref = %Compendium.OCI.Reference{registry: "registry.cyfr.run", repository: "alice/catalysts/claude", tag: "0.1.0"}
      iex> Compendium.OCI.Reference.to_component_ref(ref)
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "alice", name: "claude", version: "0.1.0"}}

  """
  @spec to_component_ref(t()) :: {:ok, Sanctum.ComponentRef.t()} | {:error, String.t()}
  def to_component_ref(%__MODULE__{repository: repo, tag: tag, digest: digest}) do
    version = tag || digest

    case String.split(repo, "/") do
      [publisher, type_plural, name] ->
        type = String.trim_trailing(type_plural, "s")

        if type in ~w(catalyst reagent formula tincture) do
          {:ok,
           %Sanctum.ComponentRef{
             type: type,
             namespace: publisher,
             name: name,
             version: version
           }}
        else
          {:error,
           "Unknown component type directory: #{type_plural}. Expected catalysts, reagents, formulas, or tinctures."}
        end

      _ ->
        {:error,
         "OCI repository '#{repo}' does not follow CYFR convention: <publisher>/<type>s/<name>"}
    end
  end

  @doc """
  Returns the API base URL for the registry.
  """
  @spec api_base(t()) :: String.t()
  def api_base(%__MODULE__{registry: registry}) do
    registry_api_url(registry)
  end

  @doc """
  Check if a string looks like an OCI reference (contains `/` or a registry hostname).
  """
  @spec oci_ref?(String.t()) :: boolean()
  def oci_ref?(ref) when is_binary(ref) do
    String.contains?(ref, "/") and not String.starts_with?(ref, "./") and
      not String.starts_with?(ref, "/")
  end

  def oci_ref?(_), do: false

  # ============================================================================
  # Private
  # ============================================================================

  defp do_parse(ref) do
    # Split off @digest if present
    {ref_without_digest, digest} =
      case String.split(ref, "@", parts: 2) do
        [r, d] -> {r, d}
        [r] -> {r, nil}
      end

    # Split off :tag if present (and no digest)
    {ref_without_tag, tag} =
      if digest do
        {ref_without_digest, nil}
      else
        split_tag(ref_without_digest)
      end

    # Parse registry and repository from the path
    case split_registry_repo(ref_without_tag) do
      {:ok, registry, repository, defaulted} ->
        {:ok,
         %__MODULE__{
           registry: registry,
           repository: repository,
           tag: tag,
           digest: digest,
           default_registry: defaulted
         }}

      {:error, _} = error ->
        error
    end
  end

  # Split tag from the last path segment.
  # We need to be careful: the tag is after the last `:` but only in the
  # last path segment (to avoid splitting on port numbers).
  defp split_tag(ref) do
    parts = String.split(ref, "/")
    last = List.last(parts)

    case String.split(last, ":", parts: 2) do
      [name, tag] when tag != "" ->
        init = Enum.slice(parts, 0..-2//1)
        {Enum.join(init ++ [name], "/"), tag}

      _ ->
        {ref, nil}
    end
  end

  # Determine which part of the path is the registry and which is the repository.
  # A registry host is identified by containing a "." or ":" (port), or being "localhost".
  # Returns {:ok, registry, repository, default_registry?} where default_registry? is true
  # when the default registry was applied (no explicit registry in the input).
  defp split_registry_repo(ref) do
    parts = String.split(ref, "/")

    case parts do
      [single] ->
        # No slash at all — treat as repository on default registry
        {:ok, default_registry(), single, true}

      [first | rest] ->
        if registry_host?(first) do
          repo = Enum.join(rest, "/")

          if repo == "" do
            {:error, "OCI reference has registry but no repository: #{ref}"}
          else
            {:ok, first, repo, false}
          end
        else
          # No registry host detected — use default registry
          {:ok, default_registry(), ref, true}
        end
    end
  end

  defp registry_host?(part) do
    String.contains?(part, ".") or String.contains?(part, ":") or part == "localhost"
  end

  defp registry_api_url("docker.io"), do: "https://registry-1.docker.io"
  defp registry_api_url("localhost:" <> _ = host), do: "http://#{host}"
  defp registry_api_url(registry), do: "https://#{registry}"
end
