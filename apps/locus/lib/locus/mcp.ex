# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
        description: "Compile components by reference and manage build toolchains",
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          actions: %{
            "compile" => %{kind: :execute},
            "validate" => %{kind: :read},
            "toolchains" => %{kind: :read}
          }
        },
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

  # Intentionally public (no auth check): read-only introspection of available
  # build toolchains. No user data or side effects.
  def handle("build", %Context{} = _ctx, %{"action" => "toolchains"}) do
    {:ok, %{toolchains: Locus.Builder.available_toolchains()}}
  end

  # Intentionally public (no auth check): stateless WASM binary validation.
  # Caller supplies the bytes; no server-side data is exposed.
  # Max base64 input size: 50MB binary ≈ 67MB base64
  @max_base64_size 67_108_864

  def handle("build", %Context{} = _ctx, %{"action" => "validate", "wasm_base64" => wasm_base64})
      when is_binary(wasm_base64) do
    if byte_size(wasm_base64) > @max_base64_size do
      {:error,
       "Input too large: #{byte_size(wasm_base64)} bytes exceeds #{@max_base64_size} byte limit"}
    else
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
  end

  def handle("build", _ctx, %{"action" => "validate"}) do
    {:error, "Missing required argument: wasm_base64"}
  end

  def handle("build", %Context{} = ctx, %{"action" => "compile", "reference" => reference} = args)
      when is_binary(reference) do
    with :ok <- Context.require_permission(ctx, :execute) do
      build_id = args["build_id"]
      session_id = ctx.session_id

      build_meta = %{
        build_id: build_id,
        reference: reference,
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        user_id: ctx.user_id
      }

      on_progress = build_progress_callback(build_id, session_id, ctx, build_meta)

      :telemetry.execute(
        [:cyfr, :locus, :build, :start],
        %{system_time: System.system_time()},
        build_meta
      )

      start_native = System.monotonic_time()

      outcome =
        with {:ok, type, name, version} <- parse_reference(reference),
             {:ok, version} <- resolve_version(ctx, reference, type, name, version),
             {:ok, source_files} <- read_source_tree(ctx, type, name, version),
             {:ok, result} <- do_compile(source_files, type, on_progress) do
          # Save compiled artifacts — WASM binary or tincture output files
          store_result =
            if Map.has_key?(result, :output_files) do
              store_tincture_output(ctx, type, "local", name, version, result.output_files)
            else
              wasm_path =
                Compendium.ComponentPath.wasm_path(type, "local", name, version, ctx)

              Arca.put(ctx, wasm_path, result.wasm_bytes)
            end

          case store_result do
            :ok ->
              # Fire-and-forget registration — Locus compiles, CYFR registers
              Task.start(fn ->
                case Compendium.MCP.handle("component", ctx, %{"action" => "register"}) do
                  {:ok, _} ->
                    :ok

                  {:error, reason} ->
                    Logger.warning(
                      "[Locus.MCP] Post-compile registration failed: #{inspect(reason)}"
                    )

                    Compendium.AutoIndexer.scan(ctx: ctx)
                end
              end)

              {:ok,
               %{
                 status: "compiled",
                 reference: reference,
                 digest: result.digest,
                 size: result.size,
                 files: result |> Map.get(:output_files, %{}) |> Map.keys(),
                 exports: Map.get(result, :exports, []),
                 language: result.language,
                 target_type: result.target_type,
                 registration: "pending"
               }}

            {:error, reason} ->
              {:error, "Compiled successfully but save failed: #{inspect(reason)}"}
          end
        end

      duration_ms =
        System.convert_time_unit(
          System.monotonic_time() - start_native,
          :native,
          :millisecond
        )

      :telemetry.execute(
        [:cyfr, :locus, :build, :stop],
        %{duration_ms: duration_ms},
        Map.merge(build_meta, %{
          status: if(match?({:ok, _}, outcome), do: :ok, else: :error),
          error: if(match?({:error, _}, outcome), do: elem(outcome, 1), else: nil)
        })
      )

      outcome
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

  @valid_types ~w(reagent catalyst formula tincture)

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

  defp resolve_version(_ctx, _reference, _type, _name, version) when is_binary(version),
    do: {:ok, version}

  defp resolve_version(ctx, reference, _type, _name, nil) do
    case Compendium.Resolver.resolve(ctx, reference) do
      {:ok, resolved_ref, _metadata} ->
        {:ok, parsed} = Sanctum.ComponentRef.parse(resolved_ref)
        {:ok, parsed.version}

      {:error, reason} ->
        {:error, "Cannot resolve version for #{reference}: #{reason}"}
    end
  end

  defp read_source_tree(ctx, "tincture", name, version) do
    base =
      Compendium.ComponentPath.version_dir("tincture", "local", name, version, ctx)

    pkg_path = base ++ ["package.json"]

    case Arca.get(ctx, pkg_path) do
      {:ok, _} ->
        source_files = collect_tincture_source(ctx, base, base)
        {:ok, source_files}

      {:error, _} ->
        {:error,
         "No package.json found at #{Enum.join(pkg_path, "/")}. " <>
           "Vanilla tinctures don't need compilation — use component.register instead."}
    end
  end

  defp read_source_tree(ctx, type, name, version) do
    src_base =
      Compendium.ComponentPath.version_dir(type, "local", name, version, ctx) ++ ["src"]

    # Check that lib.rs exists
    lib_rs_path = src_base ++ ["src", "lib.rs"]

    case Arca.get(ctx, lib_rs_path) do
      {:ok, _} ->
        source_files = collect_source_files(ctx, src_base, src_base)
        {:ok, source_files}

      {:error, _} ->
        {:error,
         "Source not found at #{Enum.join(src_base ++ ["src", "lib.rs"], "/")}. " <>
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

              if String.ends_with?(entry, ".rs") or String.ends_with?(entry, ".wit") or
                   entry == "Cargo.toml" do
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

  defp language_for_type("tincture"), do: :javascript
  defp language_for_type(_), do: :rust

  defp do_compile(source_files, type, on_progress) do
    target_type = String.to_existing_atom(type)
    language = language_for_type(type)

    case Locus.Builder.compile(source_files, language,
           target_type: target_type,
           on_progress: on_progress
         ) do
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

  @tincture_exclude_dirs ~w(node_modules dist .git)
  @tincture_exclude_files ~w(data.db)

  defp collect_tincture_source(ctx, base_path, current_path) do
    case Arca.list(ctx, current_path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 in @tincture_exclude_dirs))
        |> Enum.reject(&(&1 in @tincture_exclude_files))
        |> Enum.reduce(%{}, fn entry, acc ->
          entry_path = current_path ++ [entry]
          rel_path = entry_path -- base_path

          case Arca.get(ctx, entry_path) do
            {:ok, content} ->
              Map.put(acc, Path.join(rel_path), content)

            {:error, _} ->
              # Directory — recurse
              Map.merge(acc, collect_tincture_source(ctx, base_path, entry_path))
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  defp store_tincture_output(ctx, type, publisher, name, version, output_files) do
    base = Compendium.ComponentPath.version_dir(type, publisher, name, version, ctx)

    Enum.reduce_while(output_files, :ok, fn {rel_path, content}, :ok ->
      path = base ++ Path.split(rel_path)

      case Arca.put(ctx, path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_progress_callback(build_id, session_id, ctx, build_meta) do
    fn phase, message ->
      :telemetry.execute(
        [:cyfr, :locus, :build, :progress],
        %{system_time: System.system_time()},
        Map.merge(build_meta, %{phase: phase, message: message})
      )

      if build_id do
        Phoenix.PubSub.broadcast(
          Emissary.PubSub,
          Sanctum.PubSub.topic("build:#{build_id}", ctx),
          {:build_progress,
           %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}}
        )

        if session_id do
          notification =
            Emissary.MCP.Message.encode_notification("notifications/progress", %{
              build_id: build_id,
              phase: phase,
              message: message
            })

          Emissary.MCP.SSEBuffer.push(session_id, notification)
        end
      end

      :ok
    end
  end
end