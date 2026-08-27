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
            "compile" => %{kind: :execute, planes: [:external, :in_chain], permission: :execute},
            "validate" => %{kind: :read, planes: [:external, :in_chain]},
            "toolchains" => %{kind: :read, planes: [:external, :in_chain]},
            "status" => %{kind: :read, planes: [:external, :in_chain], permission: :execute}
          }
        },
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "action" => %{
              "type" => "string",
              "enum" => ["compile", "validate", "toolchains", "status"],
              "description" => "Action to perform"
            },
            "async" => %{
              "type" => "boolean",
              "description" =>
                "compile only: return a build_id immediately and run the build in the background; poll with action=status or subscribe to the build:<id> topic"
            },
            "build_id" => %{
              "type" => "string",
              "description" =>
                "Build identifier — optional for compile (minted when absent), required for status"
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
          case Compendium.WasmValidator.validate(bytes) do
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
    build_id = args["build_id"] || Emissary.UUID7.generate_id("build")

    if args["async"] == true do
      start_async_compile(ctx, reference, build_id)
    else
      run_compile(ctx, reference, build_id)
    end
  end

  def handle("build", %Context{} = ctx, %{"action" => "status", "build_id" => build_id})
      when is_binary(build_id) do
    case Cyfr.BuildRecords.get(ctx, build_id) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, "Unknown build: #{build_id}"}
    end
  end

  def handle("build", _ctx, %{"action" => "status"}) do
    {:error, "Missing required argument: build_id"}
  end

  def handle("build", _ctx, %{"action" => "compile"}) do
    {:error, "Missing required argument: reference"}
  end

  def handle("build", _ctx, %{"action" => action}) do
    {:error, "Invalid build action: #{action}. Use: compile, validate, toolchains, or status"}
  end

  def handle("build", _ctx, _args) do
    {:error, "Missing required argument: action"}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  defp run_compile(ctx, reference, build_id) do
    case Locus.BuildLimiter.acquire() do
      :ok ->
        try do
          do_run_compile(ctx, reference, build_id)
        after
          Locus.BuildLimiter.release()
        end

      {:error, :busy} ->
        {:error,
         "Build capacity is full (#{Locus.BuildLimiter.max_builds()} concurrent) — retry shortly"}
    end
  end

  # Async mode: record "started", run the same pipeline off the request
  # process, record the outcome. Completion also rides the build:<id> topic
  # the progress callback already broadcasts on.
  defp start_async_compile(ctx, reference, build_id) do
    case Cyfr.BuildRecords.record_started(ctx, build_id, reference) do
      :ok ->
        logger_metadata = Cyfr.LoggerContext.capture()

        Task.Supervisor.start_child(Emissary.TaskSupervisor, fn ->
          Cyfr.LoggerContext.restore(logger_metadata)

          case run_compile(ctx, reference, build_id) do
            {:ok, result} ->
              Cyfr.BuildRecords.record_finished(ctx, build_id, "compiled", result)

            {:error, reason} ->
              Cyfr.BuildRecords.record_finished(
                ctx,
                build_id,
                "failed",
                format_async_error(reason)
              )
          end
        end)

        {:ok, %{status: "started", build_id: build_id, reference: reference}}

      {:error, _} ->
        {:error, "Could not record build start for #{build_id}"}
    end
  end

  defp format_async_error(reason),
    do: if(is_binary(reason), do: reason, else: inspect(reason))

  defp do_run_compile(ctx, reference, build_id) do
    build_meta = %{
      build_id: build_id,
      reference: reference,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id
    }

    on_progress = build_progress_callback(build_id, ctx, build_meta)

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
            store_tincture_output(ctx, type, publisher(), name, version, result.output_files)
          else
            wasm_path =
              Compendium.ComponentPath.wasm_path(type, publisher(), name, version)

            # Build artifacts write cap-exempt by design: failing a build
            # half-way through its save is worse than any over-cap state,
            # and the bytes still count against usage accounting.
            Arca.put(ctx, wasm_path, result.wasm_bytes, cap: :exempt)
          end

        case store_result do
          :ok ->
            # Fire-and-forget registration — Locus compiles, CYFR registers.
            # Routed through the dispatch chokepoint (not a direct provider
            # handle/3 call) so this state-changing mutation gets the same
            # auth gate, timeout containment, and request-log audit row as
            # every other dispatch — and supervised, unlike a bare
            # Task.start.
            logger_metadata = Cyfr.LoggerContext.capture()

            Task.Supervisor.start_child(Emissary.TaskSupervisor, fn ->
              Cyfr.LoggerContext.restore(logger_metadata)

              outcome =
                case Emissary.MCP.ToolRegistry.call_external("component", ctx, %{
                       "action" => "register"
                     }) do
                  {:ok, _} ->
                    "done"

                  {:error, reason} ->
                    Logger.warning(
                      "[Locus.MCP] Post-compile registration failed: #{inspect(reason)}"
                    )

                    Compendium.AutoIndexer.scan(ctx: ctx)
                    "indexed"
                end

              # Async builds carry the outcome on their row, so build.status
              # stops answering "pending" forever; sync builds have no row
              # and this is a no-op.
              Cyfr.BuildRecords.record_registration(ctx, build_id, outcome)
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

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp parse_reference(reference) do
    # ComponentRef.parse/1 already gates the type against the canonical list;
    # a second check here could only drift from it.
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, ref} ->
        {:ok, ref.type, ref.name, ref.version}

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

  # Locus builds only the local namespace — the tree the scanner indexes
  # and directory registration accepts.
  defp publisher, do: Compendium.ComponentPath.default_publisher()

  defp read_source_tree(ctx, "tincture", name, version) do
    base =
      Compendium.ComponentPath.version_dir("tincture", publisher(), name, version)

    pkg_path = base ++ ["package.json"]

    case Arca.get(ctx, pkg_path) do
      {:ok, _} ->
        {:ok, collect_tincture_source(ctx, base)}

      {:error, _} ->
        {:error,
         "No package.json found at #{Enum.join(pkg_path, "/")}. " <>
           "Vanilla tinctures don't need compilation — use component.register instead."}
    end
  end

  defp read_source_tree(ctx, type, name, version) do
    src_base =
      Compendium.ComponentPath.version_dir(type, publisher(), name, version) ++ ["src"]

    # Check that lib.rs exists
    lib_rs_path = src_base ++ ["src", "lib.rs"]

    case Arca.get(ctx, lib_rs_path) do
      {:ok, _} ->
        {:ok, collect_source_files(ctx, src_base)}

      {:error, _} ->
        {:error,
         "Source not found at #{Enum.join(src_base ++ ["src", "lib.rs"], "/")}. " <>
           "Use component.new to scaffold the project first."}
    end
  end

  # Collect all source files under src_base as a map of relative paths to
  # contents — one subtree read, no per-entry probing. Excludes anything
  # under target/ and keeps only .rs/.wit files and Cargo.toml.
  defp collect_source_files(ctx, src_base) do
    case Arca.read_subtree(ctx, src_base) do
      {:ok, pairs} ->
        for {rel, content} <- pairs,
            "target" not in rel,
            name = List.last(rel),
            String.ends_with?(name, ".rs") or String.ends_with?(name, ".wit") or
              name == "Cargo.toml",
            into: %{} do
          {Path.join(rel), content}
        end

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

  @tincture_excluded ~w(node_modules dist .git data.db)

  defp collect_tincture_source(ctx, base) do
    case Arca.read_subtree(ctx, base) do
      {:ok, pairs} ->
        for {rel, content} <- pairs,
            not Enum.any?(rel, &(&1 in @tincture_excluded)),
            into: %{} do
          {Path.join(rel), content}
        end

      {:error, _} ->
        %{}
    end
  end

  defp store_tincture_output(ctx, type, publisher, name, version, output_files) do
    base = Compendium.ComponentPath.version_dir(type, publisher, name, version)

    Enum.reduce_while(output_files, :ok, fn {rel_path, content}, :ok ->
      path = base ++ Path.split(rel_path)

      # Cap-exempt like the WASM save above — build outputs, same policy.
      case Arca.put(ctx, path, content, cap: :exempt) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_progress_callback(build_id, ctx, build_meta) do
    fn phase, message ->
      :telemetry.execute(
        [:cyfr, :locus, :build, :progress],
        %{system_time: System.system_time()},
        Map.merge(build_meta, %{phase: phase, message: message})
      )

      if build_id do
        Phoenix.PubSub.broadcast(
          Emissary.PubSub,
          Prism.Topics.build(build_id, ctx),
          {:build_progress,
           %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}}
        )

        Emissary.MCP.Progress.emit(ctx, %{
          "build_id" => build_id,
          "phase" => phase,
          "message" => message
        })
      end

      :ok
    end
  end
end
