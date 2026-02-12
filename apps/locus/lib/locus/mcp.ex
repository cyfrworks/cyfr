defmodule Locus.MCP do
  @moduledoc """
  MCP tool provider for Locus build service.

  Provides a single `build` tool with action-based dispatch:
  - `compile` - Compile source code to WASM, return bytes as base64
  - `compile_and_save` - Compile and save to local components directory
  - `compile_and_publish` - Compile and register in Compendium registry
  - `validate` - Validate existing WASM binary
  - `toolchains` - List available compilation toolchains

  ## Architecture Note

  This module lives in the `locus` app, keeping tool definitions
  close to their implementation. Compilation is handled by `Locus.Builder`.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  alias Sanctum.Context

  # ============================================================================
  # ToolProvider Protocol
  # ============================================================================

  def tools do
    [
      %{
        name: "build",
        title: "Build",
        description: "Compile source code to WASM components and manage build toolchains",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["compile", "compile_and_save", "compile_and_publish", "validate", "toolchains"],
              "description" => "Action to perform"
            },
            "source" => %{
              "type" => "string",
              "description" => "Source code to compile (compile/compile_and_publish actions)"
            },
            "language" => %{
              "type" => "string",
              "enum" => ["go", "js"],
              "description" => "Source language (compile/compile_and_publish actions)"
            },
            "target_type" => %{
              "type" => "string",
              "enum" => ["reagent", "catalyst", "formula"],
              "default" => "reagent",
              "description" => "Target component type (compile/compile_and_publish actions)"
            },
            "wasm_base64" => %{
              "type" => "string",
              "description" => "Base64-encoded WASM binary (validate action)"
            }
          },
          "required" => ["action"]
        }
      }
    ]
  end

  def resources, do: []

  # ============================================================================
  # Tool Handlers - Action-based dispatch
  # ============================================================================

  def handle("build", %Context{} = _ctx, %{"action" => "toolchains"}) do
    {:ok, %{toolchains: Locus.Builder.available_toolchains()}}
  end

  def handle("build", %Context{} = _ctx, %{"action" => "validate", "wasm_base64" => wasm_base64})
      when is_binary(wasm_base64) do
    case Base.decode64(wasm_base64) do
      {:ok, bytes} ->
        case Locus.Validator.validate(bytes) do
          {:ok, meta} ->
            {:ok,
             %{
               valid: true,
               digest: meta.digest,
               size: meta.size,
               exports: meta.exports,
               suggested_type: to_string(meta.suggested_type)
             }}

          {:error, reason} ->
            {:ok, %{valid: false, reason: to_string(reason)}}
        end

      :error ->
        {:error, "Invalid base64 encoding"}
    end
  end

  def handle("build", _ctx, %{"action" => "validate"}) do
    {:error, "Missing required argument: wasm_base64"}
  end

  def handle("build", %Context{} = _ctx, %{"action" => "compile"} = args) do
    with {:ok, source, language, target_type} <- extract_compile_args(args) do
      case Locus.Builder.compile(source, language, target_type: target_type) do
        {:ok, result} ->
          {:ok,
           %{
             status: "compiled",
             wasm_base64: Base.encode64(result.wasm_bytes),
             digest: result.digest,
             size: result.size,
             exports: result.exports,
             language: result.language,
             target_type: result.target_type
           }}

        {:error, {:compilation_failed, exit_code, output}} ->
          {:error, "Compilation failed (exit #{exit_code}): #{output}"}

        {:error, :compilation_timeout} ->
          {:error, "Compilation timed out"}

        {:error, {:toolchain_not_found, lang}} ->
          {:error, "Toolchain not found: #{lang}. Install tinygo (Go) or javy (JS)."}

        {:error, reason} ->
          {:error, "Compilation error: #{inspect(reason)}"}
      end
    end
  end

  def handle("build", %Context{} = _ctx, %{"action" => "compile_and_save"} = args) do
    with {:ok, source, language, target_type} <- extract_compile_args(args) do
      case Locus.Builder.compile(source, language, target_type: target_type) do
        {:ok, result} ->
          source_hash =
            :crypto.hash(:sha256, source)
            |> Base.encode16(case: :lower)
            |> binary_part(0, 8)

          name = "gen-#{source_hash}"
          type_dir = "#{result.target_type}s"
          relative_path = "components/#{type_dir}/agent/#{name}/0.1.0/#{result.target_type}.wasm"
          absolute_path = Path.join(File.cwd!(), relative_path)

          File.mkdir_p!(Path.dirname(absolute_path))
          File.write!(absolute_path, result.wasm_bytes)

          {:ok,
           %{
             status: "saved",
             reference: %{"local" => relative_path},
             digest: result.digest,
             size: result.size,
             exports: result.exports,
             language: result.language,
             target_type: result.target_type
           }}

        {:error, {:compilation_failed, exit_code, output}} ->
          {:error, "Compilation failed (exit #{exit_code}): #{output}"}

        {:error, {:toolchain_not_found, lang}} ->
          {:error, "Toolchain not found: #{lang}. Install tinygo (Go) or javy (JS)."}

        {:error, reason} ->
          {:error, "Compilation error: #{inspect(reason)}"}
      end
    end
  end

  def handle("build", %Context{} = ctx, %{"action" => "compile_and_publish"} = args) do
    with {:ok, source, language, target_type} <- extract_compile_args(args) do
      case Locus.Builder.compile(source, language, target_type: target_type) do
        {:ok, result} ->
          # Generate deterministic name from source hash
          source_hash =
            :crypto.hash(:sha256, source)
            |> Base.encode16(case: :lower)
            |> binary_part(0, 8)

          name = "gen-#{source_hash}"

          metadata = %{
            name: name,
            version: "0.1.0",
            type: result.target_type,
            description: "Auto-generated #{result.language} component",
            publisher: "agent"
          }

          case Compendium.Registry.publish_bytes(ctx, result.wasm_bytes, metadata) do
            {:ok, _component} ->
              {:ok,
               %{
                 status: "published",
                 reference: %{"registry" => "agent.#{name}:0.1.0"},
                 digest: result.digest,
                 size: result.size,
                 exports: result.exports,
                 language: result.language,
                 target_type: result.target_type
               }}

            {:error, reason} ->
              {:error, "Compiled successfully but publish failed: #{inspect(reason)}"}
          end

        {:error, {:compilation_failed, exit_code, output}} ->
          {:error, "Compilation failed (exit #{exit_code}): #{output}"}

        {:error, {:toolchain_not_found, lang}} ->
          {:error, "Toolchain not found: #{lang}. Install tinygo (Go) or javy (JS)."}

        {:error, reason} ->
          {:error, "Compilation error: #{inspect(reason)}"}
      end
    end
  end

  def handle("build", _ctx, %{"action" => action}) when action in ["compile", "compile_and_save", "compile_and_publish"] do
    {:error, "Missing required arguments: source, language"}
  end

  def handle("build", _ctx, %{"action" => action}) do
    {:error, "Invalid build action: #{action}. Use: compile, compile_and_save, compile_and_publish, validate, or toolchains"}
  end

  def handle("build", _ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp extract_compile_args(args) do
    source = args["source"]
    language_str = args["language"]
    target_type_str = args["target_type"] || "reagent"

    cond do
      is_nil(source) or source == "" ->
        {:error, "Missing required argument: source"}

      is_nil(language_str) ->
        {:error, "Missing required argument: language"}

      true ->
        language = parse_language(language_str)
        target_type = parse_target_type(target_type_str)

        if language == :unknown do
          {:error, "Unsupported language: #{language_str}. Use: go, js"}
        else
          {:ok, source, language, target_type}
        end
    end
  end

  defp parse_language("go"), do: :go
  defp parse_language("js"), do: :js
  defp parse_language(_), do: :unknown

  defp parse_target_type("reagent"), do: :reagent
  defp parse_target_type("catalyst"), do: :catalyst
  defp parse_target_type("formula"), do: :formula
  defp parse_target_type(_), do: :reagent
end
