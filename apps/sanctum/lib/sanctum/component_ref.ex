defmodule Sanctum.ComponentRef do
  @moduledoc """
  Canonical component reference parser and formatter.

  All component references in CYFR follow the canonical format:

      type:namespace.name:version

  Examples:
  - `catalyst:local.claude:0.1.0`
  - `c:local.claude:0.1.0` (shorthand)
  - `reagent:cyfr.sentiment:1.0.0`
  - `f:local.list-models:0.1.0`

  The type prefix is **required**. `normalize/1` rejects refs without a type
  prefix. `parse/1` still accepts untyped refs for internal use and migration.

  **Shorthand**: `c` = catalyst, `r` = reagent, `f` = formula

  ## Legacy Formats

  For backwards compatibility, the parser also accepts:
  - `namespace.name:version` — type defaults to `nil`
  - `name:version` — defaults namespace to `"local"`
  - `name` — defaults namespace to `"local"`, version to `"latest"`
  - `local:name:version` — legacy colon-separated format

  ## Validation

  - **Type**: one of `catalyst`, `reagent`, `formula` (or nil)
  - **Namespace**: lowercase alphanumeric + hyphens, 2-64 chars
  - **Name**: lowercase alphanumeric + hyphens, 2-64 chars, cannot start/end with hyphen
  - **Version**: semver (`1.0.0`, `1.0.0-beta.1`, `1.0.0+build.1`) or `"latest"`
  """

  @type t :: %__MODULE__{
          type: String.t() | nil,
          namespace: String.t(),
          name: String.t(),
          version: String.t()
        }

  defstruct [:type, :namespace, :name, :version]

  @valid_types ~w(catalyst reagent formula)
  @type_shorthands %{"c" => "catalyst", "r" => "reagent", "f" => "formula"}

  @name_regex ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
  @single_char_name_regex ~r/^[a-z0-9]$/
  @version_regex ~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$/
  @namespace_regex ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
  @single_char_ns_regex ~r/^[a-z0-9]$/

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Parse a component reference string into a `%ComponentRef{}`.

  Accepts typed and untyped formats:

  - `"catalyst:local.my-tool:1.0.0"` — typed canonical
  - `"c:local.my-tool:1.0.0"` — shorthand type
  - `"local.my-tool:1.0.0"` — canonical (type nil)
  - `"my-tool:1.0.0"` — legacy, namespace defaults to `"local"`
  - `"my-tool"` — bare name, version defaults to `"latest"`
  - `"local:my-tool:1.0.0"` — legacy colon-separated

  ## Examples

      iex> Sanctum.ComponentRef.parse("catalyst:local.my-tool:1.0.0")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: "1.0.0"}}

      iex> Sanctum.ComponentRef.parse("local.my-tool:1.0.0")
      {:ok, %Sanctum.ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "1.0.0"}}

      iex> Sanctum.ComponentRef.parse("my-tool")
      {:ok, %Sanctum.ComponentRef{type: nil, namespace: "local", name: "my-tool", version: "latest"}}

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      trimmed == "" ->
        {:error, "component ref cannot be empty"}

      # Typed ref: "type:namespace.name:version" or "c:namespace.name:version"
      typed_ref?(trimmed) ->
        parse_typed(trimmed)

      # Legacy colon-separated: "local:name:version"
      legacy_colon_separated?(trimmed) ->
        parse_legacy_colon(trimmed)

      # Canonical: "namespace.name:version" or "namespace.name"
      # A dot before the first colon (or with no colon) indicates namespace.name
      has_dot_before_colon?(trimmed) ->
        parse_canonical(trimmed)

      # Legacy: "name:version" (no namespace)
      String.contains?(trimmed, ":") ->
        parse_name_version(trimmed)

      # Bare name
      true ->
        {:ok, %__MODULE__{namespace: "local", name: trimmed, version: "latest"}}
    end
  end

  def parse(_), do: {:error, "component ref must be a string"}

  @doc """
  Convert a `%ComponentRef{}` to its canonical string representation.

  When type is non-nil, prepends `"type:"` prefix.

  ## Examples

      iex> ref = %Sanctum.ComponentRef{namespace: "local", name: "my-tool", version: "1.0.0"}
      iex> Sanctum.ComponentRef.to_string(ref)
      "local.my-tool:1.0.0"

      iex> ref = %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: "1.0.0"}
      iex> Sanctum.ComponentRef.to_string(ref)
      "catalyst:local.my-tool:1.0.0"

  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{type: nil, namespace: ns, name: name, version: version}) do
    "#{ns}.#{name}:#{version}"
  end

  def to_string(%__MODULE__{type: type, namespace: ns, name: name, version: version}) do
    "#{type}:#{ns}.#{name}:#{version}"
  end

  @doc """
  Normalize a component reference string to canonical format.

  Parses the input and returns the canonical string. The type prefix is
  **required** — untyped refs are rejected with a helpful error message.

  ## Examples

      iex> Sanctum.ComponentRef.normalize("catalyst:local.my-tool:1.0.0")
      {:ok, "catalyst:local.my-tool:1.0.0"}

      iex> Sanctum.ComponentRef.normalize("c:local.my-tool:1.0.0")
      {:ok, "catalyst:local.my-tool:1.0.0"}

      iex> Sanctum.ComponentRef.normalize("local.my-tool:1.0.0")
      {:error, "component ref must include a type prefix (e.g., catalyst:local.my-tool:1.0.0). Valid types: catalyst (c), reagent (r), formula (f)"}

  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(ref) when is_binary(ref) do
    case parse(ref) do
      {:ok, %__MODULE__{type: nil}} ->
        {:error, "component ref must include a type prefix " <>
          "(e.g., catalyst:#{String.trim(ref)}). " <>
          "Valid types: catalyst (c), reagent (r), formula (f)"}
      {:ok, parsed} -> {:ok, __MODULE__.to_string(parsed)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Extract a `%ComponentRef{}` from a canonical filesystem path.

  Expected path layout:
    `components/{type}s/{namespace}/{name}/{version}/{type}.wasm`

  The component type is extracted from the directory name (e.g., `catalysts` → `catalyst`).

  ## Examples

      iex> Sanctum.ComponentRef.from_path("components/catalysts/local/claude/0.1.0/catalyst.wasm")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}}

  """
  @spec from_path(String.t()) :: {:ok, t()} | {:error, String.t()}
  @component_type_dirs ~w(catalysts reagents formulas)
  def from_path(path) when is_binary(path) do
    parts = Path.split(path)

    case Enum.reverse(parts) do
      [_wasm_file, version, name, namespace, type_dir | _]
      when type_dir in @component_type_dirs ->
        component_type = String.trim_trailing(type_dir, "s")
        {:ok, %__MODULE__{type: component_type, namespace: namespace, name: name, version: version}}

      _ ->
        {:error,
          "Cannot derive component ref from path: #{path}\n\n" <>
          "WASM files must be in the canonical layout:\n" <>
          "  components/{catalysts,reagents,formulas}/{namespace}/{name}/{version}/{type}.wasm\n\n" <>
          "Example: components/catalysts/local/claude/0.1.0/catalyst.wasm => catalyst:local.claude:0.1.0\n"}
    end
  end

  @doc """
  Validate a component reference string.

  Returns `:ok` if valid, or `{:error, reason}` with a description of the problem.

  ## Examples

      iex> Sanctum.ComponentRef.validate("local.my-tool:1.0.0")
      :ok

      iex> Sanctum.ComponentRef.validate("")
      {:error, "component ref cannot be empty"}

  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(ref) when is_binary(ref) do
    case parse(ref) do
      {:ok, parsed} -> validate_parsed(parsed)
      {:error, _} = error -> error
    end
  end

  def validate(_), do: {:error, "component ref must be a string"}

  @doc """
  Validate that a type string is one of the known component types.

  ## Examples

      iex> Sanctum.ComponentRef.validate_type("catalyst")
      :ok

      iex> Sanctum.ComponentRef.validate_type("invalid")
      {:error, "invalid component type: invalid. Must be one of: catalyst, reagent, formula"}

  """
  @spec validate_type(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_type(nil), do: {:error, "component type is required. Must be one of: catalyst, reagent, formula"}
  def validate_type(type) when type in @valid_types, do: :ok
  def validate_type(type), do: {:error, "invalid component type: #{type}. Must be one of: catalyst, reagent, formula"}

  @doc """
  Expand a type shorthand to its full name.

  ## Examples

      iex> Sanctum.ComponentRef.expand_type_shorthand("c")
      "catalyst"

      iex> Sanctum.ComponentRef.expand_type_shorthand("catalyst")
      "catalyst"

  """
  @spec expand_type_shorthand(String.t()) :: String.t()
  def expand_type_shorthand(s), do: Map.get(@type_shorthands, s, s)

  @doc """
  Check if a string is a known type prefix (full name or shorthand).
  """
  @spec type_prefix?(String.t()) :: boolean()
  def type_prefix?(s), do: s in @valid_types or Map.has_key?(@type_shorthands, s)

  # ============================================================================
  # Private: Parsing Helpers
  # ============================================================================

  # Detect typed ref: first colon-segment is a known type/shorthand with no dots.
  # "catalyst:local.my-tool:1.0.0" → true
  # "c:local.my-tool:1.0.0" → true
  # "local.my-tool:1.0.0" → false (first segment before colon contains a dot)
  # "name:1.0.0" → false ("name" is not a known type)
  defp typed_ref?(ref) do
    case String.split(ref, ":", parts: 2) do
      [first, _rest] ->
        not String.contains?(first, ".") and type_prefix?(first)
      _ ->
        false
    end
  end

  # Parse a typed ref: "type:remainder" where remainder is any valid ref format
  defp parse_typed(ref) do
    [type_part, remainder] = String.split(ref, ":", parts: 2)
    expanded_type = expand_type_shorthand(type_part)

    case parse(remainder) do
      {:ok, parsed} -> {:ok, %{parsed | type: expanded_type}}
      {:error, _} = error -> error
    end
  end

  # Check if a dot appears before the first colon (or if there's a dot with no colon).
  # This distinguishes "namespace.name:version" from "name:1.0.0" where dots are in the version.
  defp has_dot_before_colon?(ref) do
    case String.split(ref, ":", parts: 2) do
      [before_colon, _] -> String.contains?(before_colon, ".")
      [no_colon] -> String.contains?(no_colon, ".")
    end
  end

  # Detect legacy "local:name:version" format.
  # Distinguished from canonical by having exactly 2 colons and no dots before the first colon.
  defp legacy_colon_separated?(ref) do
    case String.split(ref, ":") do
      [ns, _name, _version] when ns != "" -> not String.contains?(ns, ".")
      _ -> false
    end
  end

  defp parse_legacy_colon(ref) do
    [namespace, name, version] = String.split(ref, ":", parts: 3)
    {:ok, %__MODULE__{namespace: namespace, name: name, version: version}}
  end

  defp parse_canonical(ref) do
    # Split on first "." to get namespace, then on ":" for name:version
    case String.split(ref, ".", parts: 2) do
      [namespace, rest] when rest != "" ->
        case String.split(rest, ":", parts: 2) do
          [name, version] when version != "" ->
            {:ok, %__MODULE__{namespace: namespace, name: name, version: version}}

          [name] ->
            {:ok, %__MODULE__{namespace: namespace, name: name, version: "latest"}}

          _ ->
            {:error, "invalid component ref format: #{ref}"}
        end

      _ ->
        {:error, "invalid component ref format: #{ref}"}
    end
  end

  defp parse_name_version(ref) do
    case String.split(ref, ":", parts: 2) do
      [name, version] when name != "" and version != "" ->
        {:ok, %__MODULE__{namespace: "local", name: name, version: version}}

      _ ->
        {:error, "invalid component ref format: #{ref}"}
    end
  end

  # ============================================================================
  # Private: Validation
  # ============================================================================

  defp validate_parsed(%__MODULE__{type: type, namespace: ns, name: name, version: version}) do
    with :ok <- validate_type(type),
         :ok <- validate_namespace(ns),
         :ok <- validate_name(name),
         :ok <- validate_version(version) do
      :ok
    end
  end

  defp validate_namespace(ns) do
    cond do
      byte_size(ns) < 2 and not Regex.match?(@single_char_ns_regex, ns) ->
        {:error, "namespace must be at least 2 characters (or a single alphanumeric char)"}

      byte_size(ns) > 64 ->
        {:error, "namespace must be at most 64 characters"}

      byte_size(ns) == 1 ->
        if Regex.match?(@single_char_ns_regex, ns), do: :ok, else: {:error, "namespace must be lowercase alphanumeric"}

      not Regex.match?(@namespace_regex, ns) ->
        {:error, "namespace must be lowercase alphanumeric with hyphens, cannot start/end with hyphen"}

      true ->
        :ok
    end
  end

  defp validate_name(name) do
    cond do
      byte_size(name) < 2 and not Regex.match?(@single_char_name_regex, name) ->
        {:error, "name must be at least 2 characters"}

      byte_size(name) > 64 ->
        {:error, "name must be at most 64 characters"}

      byte_size(name) == 1 ->
        if Regex.match?(@single_char_name_regex, name), do: :ok, else: {:error, "name must be lowercase alphanumeric"}

      not Regex.match?(@name_regex, name) ->
        {:error, "name must be lowercase alphanumeric with hyphens, cannot start/end with hyphen"}

      true ->
        :ok
    end
  end

  defp validate_version("latest"), do: :ok

  defp validate_version(version) do
    if Regex.match?(@version_regex, version) do
      :ok
    else
      {:error, "version must be valid semver (e.g., 1.0.0) or 'latest'"}
    end
  end

  # ============================================================================
  # Protocol Implementations
  # ============================================================================

  defimpl String.Chars do
    def to_string(ref) do
      Sanctum.ComponentRef.to_string(ref)
    end
  end
end
