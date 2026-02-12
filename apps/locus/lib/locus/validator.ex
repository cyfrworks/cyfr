defmodule Locus.Validator do
  @moduledoc """
  WASM artifact validation for Locus import pipeline.

  Validates pre-built WASM artifacts before publishing.

  ## Validation Steps

  1. Magic bytes check - Verify `\\0asm` header
  2. Size limits - Enforce maximum artifact size (50MB)
  3. Version check - Verify WASM binary version
  4. Export extraction - Parse and extract exported functions
  5. Content digest - Compute SHA-256 hash for deduplication

  ## Component Type Detection

  Based on exports, the validator can suggest a component type:
  - `catalyst` - Has I/O-related exports (http, socket capabilities)
  - `reagent` - Pure compute, no I/O
  - `formula` - Has `execute` export (workflow orchestration)

  ## Usage

      {:ok, result} = Locus.Validator.validate(wasm_bytes)
      # => %{
      #      valid: true,
      #      digest: "sha256:abc123...",
      #      size: 12345,
      #      exports: ["run", "init"],
      #      suggested_type: :reagent
      #    }

      {:error, reason} = Locus.Validator.validate(invalid_bytes)
      # => {:error, :invalid_magic_bytes}
  """

  require Logger

  # WASM magic bytes: \0asm
  @wasm_magic <<0x00, 0x61, 0x73, 0x6D>>

  # WASM version 1 (MVP)
  @wasm_version_1 <<0x01, 0x00, 0x00, 0x00>>

  # Component Model preamble (layer 0)
  @component_preamble <<0x0D, 0x00, 0x01, 0x00>>

  # Maximum artifact size (50MB)
  @max_size 50 * 1024 * 1024

  # Minimum valid WASM size (magic + version = 8 bytes)
  @min_size 8

  # WASM section IDs (only export section is currently used)
  @section_export 7

  # Export kinds
  @export_func 0

  @doc """
  Validate a WASM binary and extract metadata.

  ## Parameters

  - `bytes` - Raw WASM binary data

  ## Returns

  - `{:ok, metadata}` - Validation successful
  - `{:error, reason}` - Validation failed

  ## Metadata Fields

  - `:valid` - Always true on success
  - `:digest` - SHA-256 content hash (hex encoded)
  - `:size` - Binary size in bytes
  - `:exports` - List of exported function names
  - `:suggested_type` - Suggested component type based on exports
  - `:version` - WASM binary version
  """
  def validate(bytes) when is_binary(bytes) do
    with :ok <- check_size(bytes),
         :ok <- check_magic(bytes),
         {:ok, format} <- check_version(bytes) do
      digest = compute_digest(bytes)

      case format do
        :core_module ->
          {:ok, exports} = extract_exports(bytes)
          suggested_type = suggest_type(exports)

          {:ok,
           %{
             valid: true,
             digest: digest,
             size: byte_size(bytes),
             exports: exports,
             suggested_type: suggested_type,
             version: 1,
             format: :core_module
           }}

        :component ->
          # Component Model binaries have a different section layout;
          # skip core module section parsing and return empty exports.
          # The caller specifies type via the `target` parameter.
          {:ok,
           %{
             valid: true,
             digest: digest,
             size: byte_size(bytes),
             exports: [],
             suggested_type: :reagent,
             version: 1,
             format: :component
           }}
      end
    end
  end

  def validate(_), do: {:error, :not_binary}

  @doc """
  Quick validation check - only verifies magic bytes and size.
  Useful for fast rejection of obviously invalid files.
  """
  def quick_check(bytes) when is_binary(bytes) do
    with :ok <- check_size(bytes),
         :ok <- check_magic(bytes) do
      :ok
    end
  end

  def quick_check(_), do: {:error, :not_binary}

  @doc """
  Compute SHA-256 digest of binary content.
  Returns hex-encoded string with sha256: prefix.
  """
  def compute_digest(bytes) when is_binary(bytes) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    "sha256:#{hash}"
  end

  @doc """
  Suggest component type based on exported functions.
  """
  def suggest_type(exports) when is_list(exports) do
    cond do
      # Formula components have an execute function
      "execute" in exports ->
        :formula

      # Catalysts typically have capability-related exports
      has_capability_exports?(exports) ->
        :catalyst

      # Default to reagent (pure compute)
      true ->
        :reagent
    end
  end

  # ============================================================================
  # Validation Steps
  # ============================================================================

  defp check_size(bytes) when byte_size(bytes) < @min_size do
    {:error, :too_small}
  end

  defp check_size(bytes) when byte_size(bytes) > @max_size do
    {:error, {:too_large, byte_size(bytes), @max_size}}
  end

  defp check_size(_bytes), do: :ok

  defp check_magic(<<@wasm_magic, _rest::binary>>), do: :ok
  defp check_magic(_), do: {:error, :invalid_magic_bytes}

  defp check_version(<<@wasm_magic, @wasm_version_1, _rest::binary>>), do: {:ok, :core_module}
  defp check_version(<<@wasm_magic, @component_preamble, _rest::binary>>), do: {:ok, :component}
  defp check_version(<<@wasm_magic, version::binary-size(4), _rest::binary>>) do
    {:error, {:unsupported_version, version}}
  end
  defp check_version(_), do: {:error, :invalid_version}

  # ============================================================================
  # Export Extraction
  # ============================================================================

  @doc """
  Extract exported function names from WASM binary.
  Returns {:ok, [name, ...]} or {:error, reason}.
  """
  def extract_exports(bytes) when is_binary(bytes) do
    # Skip magic (4) + version (4)
    <<_header::binary-size(8), sections::binary>> = bytes

    case parse_sections(sections) do
      {:ok, section_map} ->
        exports =
          section_map
          |> Map.get(@section_export, <<>>)
          |> parse_export_section()
          |> Enum.filter(fn {_name, kind} -> kind == @export_func end)
          |> Enum.map(fn {name, _kind} -> name end)

        {:ok, exports}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # Pattern match errors indicate malformed WASM structure
    MatchError ->
      Logger.warning("Could not parse WASM exports section (pattern match failed)")
      {:error, :wasm_parse_failed}

    FunctionClauseError ->
      Logger.warning("Unexpected section format in WASM (function clause failed)")
      {:error, :wasm_parse_failed}
  end

  # Parse all sections into a map of section_id => content
  defp parse_sections(binary, acc \\ %{})

  defp parse_sections(<<>>, acc), do: {:ok, acc}

  defp parse_sections(<<section_id::8, rest::binary>>, acc) do
    case parse_leb128_u32(rest) do
      {:ok, size, remaining} when byte_size(remaining) >= size ->
        <<content::binary-size(size), next::binary>> = remaining
        # Only store sections we care about (export section)
        new_acc = if section_id == @section_export, do: Map.put(acc, section_id, content), else: acc
        parse_sections(next, new_acc)

      {:ok, size, remaining} ->
        {:error, {:section_truncated, section_id, size, byte_size(remaining)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_sections(_invalid, _acc), do: {:error, :invalid_section_format}

  # Parse export section content
  defp parse_export_section(<<>>) do
    []
  end

  defp parse_export_section(content) do
    case parse_leb128_u32(content) do
      {:ok, count, rest} ->
        parse_exports_vec(rest, count, [])

      {:error, _} ->
        []
    end
  end

  defp parse_exports_vec(_binary, 0, acc), do: Enum.reverse(acc)

  defp parse_exports_vec(binary, count, acc) do
    case parse_export_entry(binary) do
      {:ok, name, kind, rest} ->
        parse_exports_vec(rest, count - 1, [{name, kind} | acc])

      {:error, _} ->
        Enum.reverse(acc)
    end
  end

  # Parse a single export entry: name (string) + kind (byte) + index (u32)
  defp parse_export_entry(binary) do
    with {:ok, name_len, rest1} <- parse_leb128_u32(binary),
         true <- byte_size(rest1) >= name_len,
         <<name::binary-size(name_len), kind::8, rest2::binary>> <- rest1,
         {:ok, _index, rest3} <- parse_leb128_u32(rest2) do
      {:ok, name, kind, rest3}
    else
      _ -> {:error, :invalid_export_entry}
    end
  end

  # Parse unsigned LEB128 encoded 32-bit integer
  defp parse_leb128_u32(binary, result \\ 0, shift \\ 0)

  defp parse_leb128_u32(<<byte::8, rest::binary>>, result, shift) when shift < 35 do
    value = Bitwise.band(byte, 0x7F)
    new_result = Bitwise.bor(result, Bitwise.bsl(value, shift))

    if Bitwise.band(byte, 0x80) == 0 do
      {:ok, new_result, rest}
    else
      parse_leb128_u32(rest, new_result, shift + 7)
    end
  end

  defp parse_leb128_u32(<<>>, _result, _shift), do: {:error, :incomplete_leb128}
  defp parse_leb128_u32(_binary, _result, _shift), do: {:error, :leb128_overflow}

  # ============================================================================
  # Type Detection Helpers
  # ============================================================================

  # Check if exports indicate I/O capabilities
  defp has_capability_exports?(exports) do
    capability_indicators = [
      "http_request",
      "http_get",
      "http_post",
      "socket_connect",
      "socket_send",
      "socket_recv",
      "fs_read",
      "fs_write",
      "env_get"
    ]

    Enum.any?(capability_indicators, &(&1 in exports))
  end
end
