# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Wasm do
  @moduledoc """
  WebAssembly component validation for the Compendium registry.

  Validates pre-built artifacts before publishing. Only component-model
  binaries are admitted: a core WebAssembly module is refused
  (`{:core_module, sentence}`), since registration is where an artifact
  enters and `Locus.Runtime.Engine` executes components only.

  ## Validation Steps

  1. Size limits - Enforce maximum artifact size (50MB)
  2. Magic bytes check - Verify `\\0asm` header
  3. Preamble check - A component's layer preamble; a core module's
     version 1 is refused as a core module, anything else as unsupported
  4. Export extraction - Parse the component's top-level world exports
  5. Content digest - Compute SHA-256 hash for deduplication
  6. Features - The component is valid WebAssembly that uses none of the
     features the runtime refuses (`Prima.ComponentFeatures`), checked
     last, after `validate/2`'s world

  The suggested type is read from the world the binary actually exports
  (`Prima.WIT.type_for_export/1`), and `validate/2` asserts the declared
  type's world outright.

  ## Usage

      {:ok, result} = Prima.Wasm.validate(wasm_bytes)
      # => %{
      #      valid: true,
      #      digest: "sha256:abc123...",
      #      size: 12345,
      #      exports: ["cyfr:reagent/compute@0.1.0"],
      #      exports_complete: true,
      #      suggested_type: :reagent
      #    }

      {:error, reason} = Prima.Wasm.validate(invalid_bytes)
      # => {:error, :invalid_magic_bytes}
  """

  # WASM magic bytes: \0asm
  @wasm_magic <<0x00, 0x61, 0x73, 0x6D>>

  # A core module's version 1 (MVP)
  @wasm_version_1 <<0x01, 0x00, 0x00, 0x00>>

  # Component Model preamble (layer 0)
  @component_preamble <<0x0D, 0x00, 0x01, 0x00>>

  # Maximum artifact size (50MB)
  @max_size 50 * 1024 * 1024

  # Minimum valid WASM size (magic + version or preamble = 8 bytes)
  @min_size 8

  # The sentence a core module is refused with, which `Prima.Refusal`
  # answers as it is.
  @core_module_refusal "The binary is a core WebAssembly module, not a component; " <>
                         "CYFR registers and runs WebAssembly components only."

  @doc """
  Validate a WebAssembly component and extract metadata.

  ## Parameters

  - `bytes` - Raw WASM binary data

  ## Returns

  - `{:ok, metadata}` - Validation successful
  - `{:error, {:core_module, sentence}}` - The binary is a core module
  - `{:error, reason}` - Validation failed otherwise

  ## Metadata Fields

  - `:valid` - Always true on success
  - `:digest` - SHA-256 content hash (hex encoded)
  - `:size` - Binary size in bytes
  - `:exports` - The component's top-level export names
  - `:exports_complete` - Whether every export record was parsed
  - `:suggested_type` - The type whose world the exports match
  """
  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(bytes) when is_binary(bytes) do
    with {:ok, validation} <- inspect_binary(bytes) do
      check_features(validation, bytes)
    end
  end

  def validate(_), do: {:error, :not_binary}

  defp inspect_binary(bytes) do
    with :ok <- check_size(bytes),
         :ok <- check_magic(bytes),
         :ok <- check_preamble(bytes) do
      # The component's top-level export names — parsed from the
      # component-model export sections, so the answer is the world the
      # binary actually implements, not a guess.
      {exports, complete?} = extract_component_exports(bytes)

      {:ok,
       %{
         valid: true,
         digest: Prima.Digest.sha256(bytes),
         size: byte_size(bytes),
         exports: exports,
         suggested_type: component_suggested_type(exports),
         exports_complete: complete?
       }}
    end
  end

  # A component is held to the features the runtime admits
  # (`Prima.ComponentFeatures`) after everything this module parses.
  defp check_features(validation, bytes) do
    with :ok <- Prima.ComponentFeatures.check(bytes), do: {:ok, validation}
  end

  @doc """
  `validate/1`, then assert the component implements the world its
  declared type demands.

  The point of asserting here, at registration, is ordering: the executor
  resolves vault material and builds the full host import surface BEFORE
  the missing export would surface as a generic call failure, so a
  mistyped or hostile-typed artifact must be refused before it ever
  reaches that pipeline.

  Fail-closed on an export section this parser cannot walk: refusing a
  novel encoding with an honest sentence beats registering an artifact
  whose world nothing verified.
  """
  @spec validate(term(), String.t() | atom()) :: {:ok, map()} | {:error, term()}
  def validate(bytes, expected_type) when is_binary(bytes) do
    type = to_string(expected_type)

    with {:ok, validation} <- inspect_binary(bytes),
         {:ok, validation} <- check_declared_world(validation, type) do
      check_features(validation, bytes)
    end
  end

  def validate(_bytes, _expected_type), do: {:error, :not_binary}

  defp check_declared_world(validation, type) do
    case Prima.WIT.expected_exports(type) do
      [] ->
        # Not an executable type (or unknown): nothing to demand.
        {:ok, validation}

      expected ->
        cond do
          not validation.exports_complete ->
            {:error,
             {:unverifiable_exports,
              "the component's export section could not be fully parsed, so the " <>
                "#{type} world (#{Enum.join(expected, ", ")}) cannot be verified"}}

          Enum.all?(expected, &(&1 in validation.exports)) ->
            {:ok, validation}

          true ->
            {:error,
             {:wrong_world,
              "declared type #{type} demands #{Enum.join(expected, ", ")} but the " <>
                "binary exports #{format_exports(validation.exports)}"}}
        end
    end
  end

  defp format_exports([]), do: "nothing"
  defp format_exports(exports), do: Enum.join(exports, ", ")

  # Suggest the component type whose world matches the parsed exports.
  defp component_suggested_type(exports) do
    exports
    |> Enum.find_value(&Prima.WIT.type_for_export/1)
    |> case do
      nil -> :reagent
      type -> String.to_existing_atom(type)
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

  defp check_preamble(<<@wasm_magic, @component_preamble, _rest::binary>>), do: :ok

  defp check_preamble(<<@wasm_magic, @wasm_version_1, _rest::binary>>),
    do: {:error, {:core_module, @core_module_refusal}}

  defp check_preamble(<<@wasm_magic, version::binary-size(4), _rest::binary>>) do
    {:error, {:unsupported_version, version}}
  end

  # ============================================================================
  # Component-Model Export Extraction
  # ============================================================================

  # Component-model export section id (component sections are their own
  # id space, in which 11 is `export`).
  @component_section_export 11

  # Walk the component's top-level sections and collect the export names
  # from every export section. Returns `{names, complete?}` — `complete?`
  # is false when any record used an encoding this parser does not walk
  # (an ascribed extern type, an unknown tag), so a caller asserting a
  # world can fail closed instead of trusting a partial answer.
  #
  # Grammar (confirmed against cargo-component output):
  #   export  ::= tag:byte(0x00|0x01) len:leb name:bytes sort idx:leb opt:byte
  #   sort    ::= 0x00 core-sort:byte | 0x01..0x05
  #   opt     ::= 0x00 (no ascribed type) | 0x01 externdesc (not walked)
  defp extract_component_exports(<<_header::binary-size(8), sections::binary>>) do
    walk_component_sections(sections, [], true)
  end

  defp walk_component_sections(<<>>, names, complete?), do: {Enum.reverse(names), complete?}

  defp walk_component_sections(<<id::8, rest::binary>>, names, complete?) do
    case parse_leb128_u32(rest) do
      {:ok, size, remaining} when byte_size(remaining) >= size ->
        <<content::binary-size(^size), next::binary>> = remaining

        {names, complete?} =
          if id == @component_section_export do
            parse_component_export_section(content, names, complete?)
          else
            {names, complete?}
          end

        walk_component_sections(next, names, complete?)

      _truncated_or_bad_leb ->
        {Enum.reverse(names), false}
    end
  end

  defp walk_component_sections(_invalid, names, _complete?), do: {Enum.reverse(names), false}

  defp parse_component_export_section(content, names, complete?) do
    case parse_leb128_u32(content) do
      {:ok, count, rest} -> parse_component_exports_vec(rest, count, names, complete?)
      {:error, _} -> {names, false}
    end
  end

  defp parse_component_exports_vec(_rest, 0, names, complete?), do: {names, complete?}

  defp parse_component_exports_vec(<<tag::8, rest::binary>>, count, names, complete?)
       when tag in [0x00, 0x01] do
    with {:ok, len, rest} <- parse_leb128_u32(rest),
         true <- byte_size(rest) >= len,
         <<name::binary-size(^len), rest::binary>> <- rest,
         {:ok, rest} <- skip_component_sortidx(rest),
         <<0x00, rest::binary>> <- rest do
      parse_component_exports_vec(rest, count - 1, [name | names], complete?)
    else
      # An ascribed externdesc (opt byte 0x01) or any shape surprise: keep
      # what parsed, mark incomplete — later records cannot be trusted.
      _ -> {names, false}
    end
  end

  defp parse_component_exports_vec(_rest, _count, names, _complete?), do: {names, false}

  defp skip_component_sortidx(<<0x00, _core_sort::8, rest::binary>>) do
    with {:ok, _idx, rest} <- parse_leb128_u32(rest), do: {:ok, rest}
  end

  defp skip_component_sortidx(<<sort::8, rest::binary>>) when sort in 0x01..0x05 do
    with {:ok, _idx, rest} <- parse_leb128_u32(rest), do: {:ok, rest}
  end

  defp skip_component_sortidx(_), do: {:error, :unknown_sort}

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
end
