defmodule Locus.MCP do
  @moduledoc """
  MCP tool provider for Locus build service.

  Provides a single `build` tool with action-based dispatch:
  - `compile` - Compile a scaffolded component by reference, save binary, register
  - `validate` - Validate existing WASM binary
  - `toolchains` - List available compilation toolchains

  ## Architecture Note

  This module lives in the `locus` app, keeping tool definitions
  close to their implementation. Compilation is handled by `Locus.Builder`.

  Implements the ToolProvider protocol (tools/0 and handle/3)
  which is validated at runtime by Emissary.MCP.ToolRegistry.
  """

  require Logger

  alias Sanctum.Context

  # ============================================================================
  # ToolProvider Protocol
  # ============================================================================

  def tools do
    [
      %{
        name: "build",
        title: "Build",
        description: "Compile WASM components by reference and manage build toolchains",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["compile", "validate", "toolchains"],
              "description" => "Action to perform"
            },
            "reference" => %{
              "type" => "string",
              "description" =>
                "Component reference to compile, e.g. 'catalyst:local.my-api:0.1.0' (compile action)"
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

  def handle("build", %Context{} = ctx, %{"action" => "compile", "reference" => reference})
      when is_binary(reference) do
    with {:ok, type, name, version} <- parse_reference(reference),
         {:ok, source} <- read_source(ctx, type, name, version),
         {:ok, result} <- do_compile(source, type) do
      # Save compiled binary
      wasm_path = ["components", "#{type}s", "local", name, version, "#{type}.wasm"]

      case Arca.put(ctx, wasm_path, result.wasm_bytes) do
        :ok ->
          # Auto-register via AutoIndexer
          scan_result = Compendium.AutoIndexer.scan()

          {:ok,
           %{
             status: "compiled",
             reference: reference,
             digest: result.digest,
             size: result.size,
             exports: result.exports,
             language: result.language,
             target_type: result.target_type,
             registered: scan_result.registered
           }}

        {:error, reason} ->
          {:error, "Compiled successfully but save failed: #{inspect(reason)}"}
      end
    end
  end

  def handle("build", _ctx, %{"action" => "compile"}) do
    {:error, "Missing required argument: reference"}
  end

  def handle("build", _ctx, %{"action" => action}) do
    {:error, "Invalid build action: #{action}. Use: compile, validate, or toolchains"}
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

  @valid_types ~w(reagent catalyst formula)

  defp parse_reference(reference) do
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, ref} ->
        if ref.type in @valid_types do
          {:ok, ref.type, ref.name, ref.version}
        else
          {:error, "Invalid component type in reference: #{ref.type}"}
        end

      {:error, reason} ->
        {:error, "Invalid reference: #{reason}"}
    end
  end

  defp read_source(ctx, type, name, version) do
    source_path = ["components", "#{type}s", "local", name, version, "src", "src", "lib.rs"]

    case Arca.get(ctx, source_path) do
      {:ok, source} ->
        {:ok, source}

      {:error, _} ->
        {:error,
         "Source not found at components/#{type}s/local/#{name}/#{version}/src/src/lib.rs. " <>
           "Use component.new to scaffold the project first."}
    end
  end

  defp do_compile(source, type) do
    target_type = String.to_existing_atom(type)

    case Locus.Builder.compile(source, :rust, target_type: target_type) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:compilation_failed, exit_code, output}} ->
        {:error, "Compilation failed (exit #{exit_code}): #{output}"}

      {:error, :compilation_timeout} ->
        {:error, "Compilation timed out"}

      {:error, {:toolchain_not_found, lang}} ->
        {:error,
         "Toolchain not found: #{lang}. Install cargo-component (cargo install cargo-component)."}

      {:error, reason} ->
        {:error, "Compilation error: #{inspect(reason)}"}
    end
  end
end
