# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ComponentRef do
  @moduledoc """
  Canonical component reference parser and formatter.

  All component references in CYFR follow the canonical format:

      type:namespace.name:version

  Two valid formats:
  - `type:namespace.name:version` — pinned (e.g., `catalyst:local.claude:0.1.0`)
  - `type:namespace.name` — versionless (e.g., `c:local.claude`)

  The type prefix is **required**. Both `parse/1` and `normalize/1` reject
  refs without a type prefix.

  **Shorthand**: `c` = catalyst, `r` = reagent, `f` = formula, `t` = tincture

  ## Namespace shapes

  The `namespace` slot admits two syntactically distinct shapes:

  | Shape     | Marker                | Example      |
  |-----------|-----------------------|--------------|
  | Publisher | contains `.` (≥1 dot) | `stripe.com` |
  | Personal  | bare (no dot)         | `alice`      |

  `@` is forbidden in any slug. Personal slugs follow GitHub-style naming
  (`^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars). Publisher slugs follow RFC 1035
  hostname rules (≤253 chars, labels 1–63, no IDN / IP / localhost / port).

  Authority for namespace claims is cyfr.run — including which slugs are
  reserved (e.g. `local`). cyfr does not maintain its own reserved list;
  the defense-in-depth check at lookup time is the regex in
  `Sanctum.Namespace.lookup/1`.

  Parser uses **last-`:`** to isolate version and **last-`.`** to split
  namespace/name — so multi-dot publishers like `stripe.com.api` round-trip.

  ## Validation

  - **Type**: one of `catalyst`, `reagent`, `formula`, `tincture` (required)
  - **Namespace**: publisher or personal shape (see above)
  - **Name**: lowercase alphanumeric + hyphens, 1–64 chars, cannot start/end with hyphen
  - **Version**: semver (`1.0.0`, `1.0.0-beta.1`, `1.0.0+build.1`)
  """

  @type t :: %__MODULE__{
          type: String.t(),
          namespace: String.t(),
          name: String.t(),
          version: String.t() | nil
        }

  defstruct [:type, :namespace, :name, :version]

  @valid_types ~w(catalyst reagent formula tincture)
  @type_shorthands %{"c" => "catalyst", "r" => "reagent", "f" => "formula", "t" => "tincture"}

  @name_regex ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/
  @single_char_name_regex ~r/^[a-z0-9]$/
  @version_regex ~r/^\d+\.\d+\.\d+(-[a-zA-Z0-9.-]+)?(\+[a-zA-Z0-9.-]+)?$/

  # Personal slug: GitHub-style. 1–39 chars, lowercase alphanumeric with
  # single-hyphen separators; no leading/trailing/consecutive hyphens.
  @personal_regex ~r/^[a-z0-9]+(-[a-z0-9]+)*$/
  @personal_max_length 39

  # Publisher label (single DNS label per RFC 1035): 1–63 chars, lowercase
  # alphanumeric + hyphens, cannot start/end with hyphen.
  @publisher_label_regex ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/
  @publisher_max_length 253

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Parse a component reference string into a `%ComponentRef{}`.

  Only accepts typed formats:

  - `"catalyst:local.my-tool:1.0.0"` — pinned
  - `"c:local.my-tool:1.0.0"` — shorthand type
  - `"catalyst:local.my-tool"` — versionless
  - `"c:local.my-tool"` — shorthand versionless

  ## Examples

      iex> Sanctum.ComponentRef.parse("catalyst:local.my-tool:1.0.0")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: "1.0.0"}}

      iex> Sanctum.ComponentRef.parse("c:local.my-tool")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: nil}}

      iex> Sanctum.ComponentRef.parse("c:stripe.com.api:0.1.0")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "stripe.com", name: "api", version: "0.1.0"}}

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      trimmed == "" ->
        {:error, "component ref cannot be empty"}

      typed_ref?(trimmed) ->
        parse_typed(trimmed)

      true ->
        {:error,
         "component ref must include a type prefix " <>
           "(e.g., catalyst:#{trimmed} or c:#{trimmed}). " <>
           "Valid types: catalyst (c), reagent (r), formula (f), tincture (t)"}
    end
  end

  def parse(_), do: {:error, "component ref must be a string"}

  @doc """
  Convert a `%ComponentRef{}` to its canonical string representation.

  ## Examples

      iex> ref = %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: "1.0.0"}
      iex> Sanctum.ComponentRef.to_string(ref)
      "catalyst:local.my-tool:1.0.0"

      iex> ref = %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: nil}
      iex> Sanctum.ComponentRef.to_string(ref)
      "catalyst:local.my-tool"

  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{type: type, namespace: ns, name: name, version: nil}) do
    "#{type}:#{ns}.#{name}"
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
      {:error, "component ref must include a type prefix (e.g., catalyst:local.my-tool:1.0.0 or c:local.my-tool:1.0.0). Valid types: catalyst (c), reagent (r), formula (f), tincture (t)"}

  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(ref) when is_binary(ref) do
    case parse(ref) do
      {:ok, %__MODULE__{version: nil} = parsed} ->
        name_part = "#{parsed.namespace}.#{parsed.name}"

        {:error,
         "version must be explicit " <>
           "(e.g., #{parsed.type}:#{name_part}:1.0.0). " <>
           "Run 'cyfr search #{parsed.name}' to find available versions, " <>
           "or 'cyfr inspect #{parsed.type}:#{name_part}' to see the latest."}

      {:ok, parsed} ->
        {:ok, __MODULE__.to_string(parsed)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Normalize a component reference, allowing version to be omitted.

  Like `normalize/1` but allows `version: nil` to pass through.
  Type prefix is still required. Returns `{:ok, struct}` (not a string)
  so the caller can check whether the version needs resolution.

  ## Examples

      iex> Sanctum.ComponentRef.normalize_flexible("c:local.my-tool:1.0.0")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: "1.0.0"}}

      iex> Sanctum.ComponentRef.normalize_flexible("c:local.my-tool")
      {:ok, %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "my-tool", version: nil}}

      iex> Sanctum.ComponentRef.normalize_flexible("local.my-tool:1.0.0")
      {:error, "component ref must include a type prefix (e.g., catalyst:local.my-tool:1.0.0 or c:local.my-tool:1.0.0). Valid types: catalyst (c), reagent (r), formula (f), tincture (t)"}

  """
  @spec normalize_flexible(String.t()) :: {:ok, t()} | {:error, String.t()}
  def normalize_flexible(ref) when is_binary(ref) do
    case parse(ref) do
      {:ok, %__MODULE__{version: nil} = parsed} ->
        with :ok <- validate_type(parsed.type),
             :ok <- validate_namespace(parsed.namespace),
             :ok <- validate_name(parsed.name) do
          {:ok, parsed}
        end

      {:ok, parsed} ->
        case validate_parsed(parsed) do
          :ok -> {:ok, parsed}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Normalize a component reference, allowing version-less refs.

  Tries strict `normalize/1` first (type + version required). If that fails,
  falls back to `normalize_flexible/1` which allows `version: nil`. Version-less
  refs are returned as name-level refs (e.g., `"catalyst:local.claude"`).

  This is the canonical "accept flexible input" function — use it wherever you
  need to accept both `c:local.claude:0.1.0` and `c:local.claude`.

  ## Examples

      iex> Sanctum.ComponentRef.normalize_or_name_ref("c:local.claude:0.1.0")
      {:ok, "catalyst:local.claude:0.1.0"}

      iex> Sanctum.ComponentRef.normalize_or_name_ref("c:local.claude")
      {:ok, "catalyst:local.claude"}

      iex> Sanctum.ComponentRef.normalize_or_name_ref("not valid")
      {:error, _}

  """
  @spec normalize_or_name_ref(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_or_name_ref(ref) when is_binary(ref) do
    case normalize_flexible(ref) do
      {:ok, %__MODULE__{version: nil} = parsed} -> {:ok, to_name_ref(parsed)}
      {:ok, parsed} -> {:ok, __MODULE__.to_string(parsed)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Check if a component reference has a pinned (explicit) version.

  ## Examples

      iex> Sanctum.ComponentRef.pinned?(%Sanctum.ComponentRef{namespace: "local", name: "claude", version: "0.1.0"})
      true

      iex> Sanctum.ComponentRef.pinned?(%Sanctum.ComponentRef{namespace: "local", name: "claude", version: nil})
      false

  """
  @spec pinned?(t()) :: boolean()
  def pinned?(%__MODULE__{version: nil}), do: false
  def pinned?(%__MODULE__{version: _}), do: true

  @doc """
  Convert a component reference to its name-level form (without version).

  Used for name-level policy lookups.

  ## Examples

      iex> ref = %Sanctum.ComponentRef{type: "catalyst", namespace: "local", name: "claude", version: "0.1.0"}
      iex> Sanctum.ComponentRef.to_name_ref(ref)
      "catalyst:local.claude"

      iex> Sanctum.ComponentRef.to_name_ref("catalyst:local.claude:0.1.0")
      {:ok, "catalyst:local.claude"}

  """
  @spec to_name_ref(t()) :: String.t()
  def to_name_ref(%__MODULE__{type: type, namespace: ns, name: name}) do
    "#{type}:#{ns}.#{name}"
  end

  @spec to_name_ref(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def to_name_ref(ref_string) when is_binary(ref_string) do
    case parse(ref_string) do
      {:ok, parsed} -> {:ok, to_name_ref(parsed)}
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
  @component_type_dirs ~w(catalysts reagents formulas tinctures)
  def from_path(path) when is_binary(path) do
    parts = Path.split(path)

    case Enum.reverse(parts) do
      [_wasm_file, version, name, namespace, type_dir | _]
      when type_dir in @component_type_dirs ->
        component_type = String.trim_trailing(type_dir, "s")

        {:ok,
         %__MODULE__{type: component_type, namespace: namespace, name: name, version: version}}

      _ ->
        {:error,
         "Cannot derive component ref from path: #{path}\n\n" <>
           "WASM files must be in the canonical layout:\n" <>
           "  components/{catalysts,reagents,formulas,tinctures}/{namespace}/{name}/{version}/{type}.wasm\n\n" <>
           "Example: components/catalysts/local/claude/0.1.0/catalyst.wasm => catalyst:local.claude:0.1.0\n"}
    end
  end

  @doc """
  Validate a component reference string.

  Returns `:ok` if valid, or `{:error, reason}` with a description of the problem.

  ## Examples

      iex> Sanctum.ComponentRef.validate("catalyst:local.my-tool:1.0.0")
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
      {:error, "invalid component type: invalid. Must be one of: catalyst, reagent, formula, tincture"}

  """
  @spec validate_type(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_type(nil),
    do: {:error, "component type is required. Must be one of: catalyst, reagent, formula, tincture"}

  def validate_type(type) when type in @valid_types, do: :ok

  def validate_type(type),
    do: {:error, "invalid component type: #{type}. Must be one of: catalyst, reagent, formula, tincture"}

  @doc """
  All valid component types — the canonical list.

  ## Examples

      iex> Sanctum.ComponentRef.valid_types()
      ["catalyst", "reagent", "formula", "tincture"]

  """
  @spec valid_types() :: [String.t()]
  def valid_types, do: @valid_types

  @doc """
  The canonical component types as atoms, for callers whose guards and keys
  are atom-typed (e.g. type-default policies).

  ## Examples

      iex> Sanctum.ComponentRef.valid_type_atoms()
      [:catalyst, :reagent, :formula, :tincture]

  """
  @spec valid_type_atoms() :: [atom()]
  def valid_type_atoms, do: Enum.map(@valid_types, &String.to_atom/1)

  @doc """
  Component types that execute through the Opus runtime. Tinctures are
  browser-side frontend components and never execute server-side, so they
  are excluded — an execution record must not carry type "tincture".

  ## Examples

      iex> Sanctum.ComponentRef.executable_types()
      ["catalyst", "reagent", "formula"]

  """
  @spec executable_types() :: [String.t()]
  def executable_types, do: @valid_types -- ["tincture"]

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

  # Parse a typed ref: "type:remainder" where remainder is "namespace.name:version"
  # or "namespace.name". Uses last-`:` then last-`.` so multi-dot publishers
  # (stripe.com.api) round-trip correctly.
  defp parse_typed(ref) do
    [type_part, remainder] = String.split(ref, ":", parts: 2)
    expanded_type = expand_type_shorthand(type_part)

    case parse_ns_name(remainder) do
      {:ok, parsed} -> {:ok, %{parsed | type: expanded_type}}
      {:error, _} = error -> error
    end
  end

  # Parse "namespace.name:version" or "namespace.name" (remainder after type prefix stripped).
  # Split on LAST ':' for version, then LAST '.' for namespace/name.
  # `version == "latest"` is normalized to `nil` to preserve existing semantics.
  defp parse_ns_name(ref) do
    {ns_name, version} = split_version(ref)

    case split_last(ns_name, ".") do
      {namespace, name} when namespace != "" and name != "" ->
        {:ok, %__MODULE__{namespace: namespace, name: name, version: version}}

      _ ->
        {:error,
         "invalid component ref format: must be namespace.name[:version] " <>
           "(e.g., local.my-tool:1.0.0 or stripe.com.api:0.1.0)"}
    end
  end

  defp split_version(ref) do
    case split_last(ref, ":") do
      {ns_name, ""} ->
        {ns_name, nil}

      {ns_name, "latest"} ->
        {ns_name, nil}

      {ns_name, version} ->
        {ns_name, version}
    end
  end

  # Split a binary on the last occurrence of `sep`. Returns `{whole, ""}` if
  # `sep` is not present.
  defp split_last(str, sep) do
    case :binary.matches(str, sep) do
      [] ->
        {str, ""}

      matches ->
        {last_pos, len} = List.last(matches)
        before = binary_part(str, 0, last_pos)

        after_ =
          binary_part(str, last_pos + len, byte_size(str) - last_pos - len)

        {before, after_}
    end
  end

  # ============================================================================
  # Field Validators (single source of truth for all services)
  # ============================================================================

  defp validate_parsed(%__MODULE__{type: type, namespace: ns, name: name, version: version}) do
    with :ok <- validate_type(type),
         :ok <- validate_namespace(ns),
         :ok <- validate_name(name),
         :ok <- validate_version(version) do
      :ok
    end
  end

  @doc """
  Validate a namespace string by syntactic shape.

  Dispatches on syntactic shape:
  - Contains `.` → publisher (RFC 1035 hostname rules).
  - Bare (no dot) → personal (GitHub-style, 1–39 chars).

  `@` is rejected anywhere in the slug — personal slugs are bare, publishers
  use dots, and there is no `@alice` short form. cyfr.run is the authority
  for which bare slugs are reserved (e.g. `local`); validation here is
  shape-only.

  ## Examples

      iex> Sanctum.ComponentRef.validate_namespace("local")
      :ok

      iex> Sanctum.ComponentRef.validate_namespace("alice")
      :ok

      iex> Sanctum.ComponentRef.validate_namespace("stripe.com")
      :ok

      iex> Sanctum.ComponentRef.validate_namespace("@alice")
      {:error, "namespace must not contain '@' — personal slugs are bare (e.g. 'alice'); publishers require a dot (e.g. 'stripe.com')"}

  """
  @spec validate_namespace(String.t()) :: :ok | {:error, String.t()}
  def validate_namespace(ns) when is_binary(ns) do
    cond do
      ns == "" ->
        {:error, "namespace cannot be empty"}

      String.contains?(ns, "@") ->
        {:error,
         "namespace must not contain '@' — personal slugs are bare (e.g. 'alice'); " <>
           "publishers require a dot (e.g. 'stripe.com')"}

      String.contains?(ns, ".") ->
        validate_publisher_slug(ns)

      true ->
        validate_personal_slug(ns)
    end
  end

  def validate_namespace(_), do: {:error, "namespace must be a string"}

  @doc """
  The canonical personal-namespace slug regex (GitHub-style): lowercase
  alphanumerics with single-hyphen separators, no leading/trailing/consecutive
  hyphens. Length (1–39 bytes) is enforced separately — use
  `valid_personal_slug?/1` for the full rule.
  """
  def personal_slug_regex, do: @personal_regex

  @doc """
  True when `slug` satisfies the full personal-namespace rule: 1–39 bytes and
  `personal_slug_regex/0`.
  """
  def valid_personal_slug?(slug) when is_binary(slug), do: validate_personal_slug(slug) == :ok
  def valid_personal_slug?(_), do: false

  defp validate_personal_slug(ns) do
    cond do
      byte_size(ns) > @personal_max_length ->
        {:error,
         "personal namespace must be at most #{@personal_max_length} characters (GitHub-style)"}

      not Regex.match?(@personal_regex, ns) ->
        {:error,
         "personal namespace must match /^[a-z0-9]+(-[a-z0-9]+)*$/ " <>
           "(lowercase letters, digits, single hyphens; no leading/trailing/consecutive hyphens)"}

      true ->
        :ok
    end
  end

  defp validate_publisher_slug(ns) do
    cond do
      byte_size(ns) > @publisher_max_length ->
        {:error,
         "publisher namespace must be at most #{@publisher_max_length} characters (RFC 1035)"}

      String.starts_with?(ns, ".") ->
        {:error, "publisher namespace must not have a leading dot"}

      String.ends_with?(ns, ".") ->
        {:error, "publisher namespace must not have a trailing dot"}

      String.contains?(ns, "..") ->
        {:error, "publisher namespace must not have empty labels"}

      String.contains?(ns, ":") ->
        {:error, "publisher namespace must not have a port suffix"}

      ns == "localhost" ->
        {:error, "'localhost' is not a valid publisher namespace"}

      looks_like_ipv4?(ns) ->
        {:error, "publisher namespace must not be an IP address (use a DNS hostname)"}

      true ->
        validate_publisher_labels(ns)
    end
  end

  defp validate_publisher_labels(ns) do
    labels = String.split(ns, ".")

    bad_label =
      Enum.find(labels, fn label -> not Regex.match?(@publisher_label_regex, label) end)

    case bad_label do
      nil ->
        :ok

      label ->
        {:error,
         "invalid publisher label #{inspect(label)} in #{inspect(ns)} — " <>
           "must match RFC 1035 (1–63 chars, lowercase alphanumeric + hyphens, " <>
           "no leading/trailing hyphen). Use punycode for internationalized domains."}
    end
  end

  defp looks_like_ipv4?(ns) do
    case String.split(ns, ".") do
      parts when length(parts) == 4 ->
        Enum.all?(parts, fn p -> Regex.match?(~r/^\d+$/, p) end)

      _ ->
        false
    end
  end

  @doc """
  Validate a publisher string. Alias for `validate_namespace/1`.

  Publishers follow the same three-shape validation rules as namespaces
  (the semantic distinction — "this is the publishing side" — doesn't
  change the syntactic rules).

  ## Examples

      iex> Sanctum.ComponentRef.validate_publisher("cyfr")
      :ok

      iex> Sanctum.ComponentRef.validate_publisher("stripe.com")
      :ok

  """
  @spec validate_publisher(String.t()) :: :ok | {:error, String.t()}
  def validate_publisher(publisher), do: validate_namespace(publisher)

  @doc """
  Validate a component name string.

  Names must be 1–64 lowercase alphanumeric characters with hyphens,
  not starting or ending with a hyphen.

  ## Examples

      iex> Sanctum.ComponentRef.validate_name("my-tool")
      :ok

      iex> Sanctum.ComponentRef.validate_name("MY_CAPS")
      {:error, "name must be lowercase alphanumeric with hyphens, cannot start/end with hyphen"}

  """
  @spec validate_name(String.t()) :: :ok | {:error, String.t()}
  def validate_name(name) do
    cond do
      byte_size(name) < 2 and not Regex.match?(@single_char_name_regex, name) ->
        {:error, "name must be at least 2 characters"}

      byte_size(name) > 64 ->
        {:error, "name must be at most 64 characters"}

      byte_size(name) == 1 ->
        if Regex.match?(@single_char_name_regex, name),
          do: :ok,
          else: {:error, "name must be lowercase alphanumeric"}

      not Regex.match?(@name_regex, name) ->
        {:error, "name must be lowercase alphanumeric with hyphens, cannot start/end with hyphen"}

      true ->
        :ok
    end
  end

  @doc """
  Validate a publisher + name pair in one call.

  Convenience for callers that validate both fields together (e.g.,
  `TinctureAccess`).
  """
  @spec validate_ref_parts(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_ref_parts(publisher, name) do
    with :ok <- validate_publisher(publisher),
         :ok <- validate_name(name) do
      :ok
    end
  end

  @doc """
  Validate a version string.

  Must be valid semver (e.g., `1.0.0`, `1.0.0-beta.1`). `nil` is rejected
  (version is required for strict validation).

  ## Examples

      iex> Sanctum.ComponentRef.validate_version("1.0.0")
      :ok

      iex> Sanctum.ComponentRef.validate_version(nil)
      {:error, "version is required. Use an explicit semver version (e.g., 1.0.0)."}

  """
  @spec validate_version(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_version(nil) do
    {:error, "version is required. Use an explicit semver version (e.g., 1.0.0)."}
  end

  def validate_version(version) do
    if Regex.match?(@version_regex, version) do
      :ok
    else
      {:error, "version must be valid semver (e.g., 1.0.0)"}
    end
  end

  defimpl String.Chars do
    def to_string(ref), do: Sanctum.ComponentRef.to_string(ref)
  end
end
