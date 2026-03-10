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

  @behaviour Emissary.MCP.ToolProvider

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

  def handle("build", %Context{} = ctx, %{"action" => "compile", "reference" => reference} = args)
      when is_binary(reference) do
    with :ok <- Context.require_permission(ctx, :execute) do
      build_id = args["build_id"]
      session_id = ctx.session_id

      with {:ok, type, name, version} <- parse_reference(reference),
           {:ok, source_files} <- read_source_tree(ctx, type, name, version),
           {:ok, result} <- do_compile(source_files, type, build_id, session_id) do
        # Save compiled binary
        wasm_path = ["components", "#{type}s", "local", name, version, "#{type}.wasm"]

        case Arca.put(ctx, wasm_path, result.wasm_bytes) do
          :ok ->
            # Auto-register via AutoIndexer
            scan_result = Compendium.AutoIndexer.scan()

            # Check if this specific component had a registration error
            ref_name = name
            ref_version = version
            component_entry = Enum.find(scan_result.components, fn c ->
              c.name == ref_name and c.version == ref_version
            end)

            reg_error = case component_entry do
              %{status: "error", error: reason} -> reason
              _ -> nil
            end

            response = %{
              status: if(reg_error, do: "compiled_but_not_registered", else: "compiled"),
              reference: reference,
              digest: result.digest,
              size: result.size,
              exports: result.exports,
              language: result.language,
              target_type: result.target_type,
              registered: scan_result.registered
            }

            response = if reg_error do
              Map.put(response, :registration_error, reg_error)
            else
              response
            end

            {:ok, response}

          {:error, reason} ->
            {:error, "Compiled successfully but save failed: #{inspect(reason)}"}
        end
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

  defp read_source_tree(ctx, type, name, version) do
    src_base = ["components", "#{type}s", "local", name, version, "src"]

    # Check that lib.rs exists
    lib_rs_path = src_base ++ ["src", "lib.rs"]

    case Arca.get(ctx, lib_rs_path) do
      {:ok, _} ->
        source_files = collect_source_files(ctx, src_base, src_base)
        {:ok, source_files}

      {:error, _} ->
        {:error,
         "Source not found at components/#{type}s/local/#{name}/#{version}/src/src/lib.rs. " <>
           "Use component.new to scaffold the project first."}
    end
  end

  # Recursively collect all source files under src_base, returning a map
  # of relative paths (relative to src_base) to file contents.
  # Excludes target/ directory.
  defp collect_source_files(ctx, base_path, current_path) do
    case Arca.list(ctx, current_path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in ["target"]))
        |> Enum.reduce(%{}, fn entry, acc ->
          entry_path = current_path ++ [entry]
          rel_path = entry_path -- base_path

          case Arca.get(ctx, entry_path) do
            {:ok, content} ->
              # It's a file — include if it's a .rs file or Cargo.toml
              rel_str = Path.join(rel_path)

              if String.ends_with?(entry, ".rs") or String.ends_with?(entry, ".wit") or entry == "Cargo.toml" do
                Map.put(acc, rel_str, content)
              else
                acc
              end

            {:error, _} ->
              # Likely a directory — recurse into it
              Map.merge(acc, collect_source_files(ctx, base_path, entry_path))
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  defp do_compile(source_files, type, build_id, session_id) do
    target_type = String.to_existing_atom(type)

    case Locus.Builder.compile(source_files, :rust, target_type: target_type, build_id: build_id, session_id: session_id) do
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
