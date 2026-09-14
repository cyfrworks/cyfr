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
  which is validated at runtime by Cyfr.Ops.Catalog.
  """

  @behaviour Cyfr.Ops.Provider

  def service, do: "locus"

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
  # 64 MiB — the shared memory ceiling's spelling
  # (`Sanctum.Limits.default_max_memory_bytes/0`), reused as the base64
  # input bound so the two cannot drift apart.
  @max_base64_size Sanctum.Limits.default_max_memory_bytes()

  # Validate stays deliberately public, but decoding and walking up to
  # 48 MiB of WASM is real CPU with no build-slot accounting — so each
  # caller identity gets a bucket, and the anonymous public shares one.
  @validate_per_minute 10

  def handle("build", %Context{} = ctx, %{"action" => "validate", "wasm_base64" => wasm_base64})
      when is_binary(wasm_base64) do
    with :ok <- check_validate_rate(ctx) do
      do_validate(wasm_base64)
    end
  end

  def handle("build", _ctx, %{"action" => "validate"}) do
    {:error, {:invalid_argument, "Missing required argument: wasm_base64"}}
  end

  def handle("build", %Context{} = ctx, %{"action" => "compile", "reference" => reference} = args)
      when is_binary(reference) do
    with :ok <- builds_enabled(),
         {:ok, build_id} <- settle_build_id(ctx, args["build_id"]) do
      if args["async"] == true do
        start_async_compile(ctx, reference, build_id)
      else
        run_compile(ctx, reference, build_id)
      end
    end
  end

  def handle("build", %Context{} = ctx, %{"action" => "status", "build_id" => build_id})
      when is_binary(build_id) do
    case Cyfr.BuildRecords.get(ctx, build_id) do
      {:ok, record} -> {:ok, record}
      _ -> {:error, {:not_found, "Build", build_id}}
    end
  end

  def handle("build", _ctx, %{"action" => "status"}) do
    {:error, {:invalid_argument, "Missing required argument: build_id"}}
  end

  def handle("build", _ctx, %{"action" => "compile"}) do
    {:error, {:invalid_argument, "Missing required argument: reference"}}
  end

  def handle("build", _ctx, %{"action" => action}) do
    {:error,
     {:invalid_argument,
      "Invalid build action: #{action}. Use: compile, validate, toolchains, or status"}}
  end

  def handle("build", _ctx, _args) do
    {:error, {:invalid_argument, "Missing required argument: action"}}
  end

  def handle(tool, _ctx, _args) do
    {:error, "Unknown tool: #{tool}"}
  end

  # `CYFR_BUILDS=false`: this server does not build. Refused in the one
  # handler every surface reaches — wire, console and in-chain — so a
  # toggle meant for an appliance cannot be walked around through a door.
  defp builds_enabled do
    if Cyfr.RuntimeConfig.builds_enabled?(),
      do: :ok,
      else: {:error, "builds are disabled on this server (CYFR_BUILDS=false)"}
  end

  defp do_validate(wasm_base64) do
    if byte_size(wasm_base64) > @max_base64_size do
      {:error,
       {:invalid_argument,
        "Input too large: #{byte_size(wasm_base64)} bytes exceeds #{@max_base64_size} byte limit"}}
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
          {:error, {:invalid_argument, "Invalid base64 encoding"}}
      end
    end
  end

  defp check_validate_rate(ctx) do
    who = ctx.user_id || ctx.athanor_id || "public"

    case Cyfr.RateLimiter.check("build:validate:#{who}", @validate_per_minute, 60_000) do
      :ok -> :ok
      {:deny, retry_s} -> {:error, "Validation rate limit reached — retry in #{retry_s}s"}
    end
  end

  # The caller may mint the id — both consoles subscribe to the progress
  # topic before starting — but it lands in topic names and rows, so its
  # shape is bounded, and an id naming a build still in flight is refused
  # rather than silently refreshing that build's row out from under its
  # subscriber (`record_started/3` is an upsert by design).
  defp settle_build_id(_ctx, nil), do: {:ok, Cyfr.UUID7.generate_id("build")}

  defp settle_build_id(ctx, id) when is_binary(id) do
    cond do
      not Regex.match?(~r/^[A-Za-z0-9_-]{1,64}$/, id) ->
        {:error, {:invalid_argument, "build_id must be 1-64 characters of [A-Za-z0-9_-]"}}

      match?({:ok, %{"status" => "started"}}, Cyfr.BuildRecords.get(ctx, id)) ->
        {:error, {:invalid_argument, "build_id names a build still in flight"}}

      true ->
        {:ok, id}
    end
  end

  defp settle_build_id(_ctx, _other),
    do: {:error, {:invalid_argument, "build_id must be a string"}}

  defp run_compile(ctx, reference, build_id) do
    case Locus.BuildLimiter.acquire(Locus.BuildLimiter, ctx.athanor_id) do
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

        start =
          Task.Supervisor.start_child(Locus.TaskSupervisor, fn ->
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

        # Whether the task STARTED is the difference between "started" and a
        # row that reads "started" forever: the result was discarded, so a
        # supervisor at its ceiling left the caller polling a build nothing
        # was running. Every sibling call site handles this.
        case start do
          {:ok, _pid} ->
            {:ok, %{status: "started", build_id: build_id, reference: reference}}

          {:error, reason} ->
            Logger.error("[Locus.MCP] could not start build #{build_id}: #{inspect(reason)}")

            Cyfr.BuildRecords.record_finished(
              ctx,
              build_id,
              "failed",
              "the build could not be started"
            )

            {:error, "Could not start build #{build_id} — retry shortly"}
        end

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

            # Apply the tenant storage cap to bounded build output.
            Arca.put(ctx, wasm_path, result.wasm_bytes)
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

            registration_start =
              Task.Supervisor.start_child(Locus.TaskSupervisor, fn ->
                Cyfr.LoggerContext.restore(logger_metadata)

                outcome =
                  case Cyfr.Ops.Catalog.call_external("component", ctx, %{
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

            # Same rule the async-compile site above spells out: a spawn the
            # supervisor refused left the row reading `registration:
            # "pending"` permanently, with nothing logged.
            case registration_start do
              {:ok, _pid} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[Locus.MCP] could not start post-compile registration for " <>
                    "#{build_id}: #{inspect(reason)}"
                )

                Cyfr.BuildRecords.record_registration(ctx, build_id, "failed")
            end

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
            Logger.error("[Locus.MCP] compiled artifact save failed: #{inspect(reason)}")
            {:error, {:unavailable, "The build store"}}
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
    # ComponentRef.parse/1 already gates the type against the canonical
    # list, and the shared namespace policy gates the namespace — both
    # checks live with their owners so a second spelling here could only
    # drift. Every later step (source read, version resolution's target,
    # artifact store) uses the local publisher, so a non-local reference
    # must be refused here rather than silently renamespaced.
    case Sanctum.ComponentRef.parse(reference) do
      {:ok, ref} ->
        case Compendium.NamespacePolicy.require_local_build(ref.namespace) do
          :ok -> {:ok, ref.type, ref.name, ref.version}
          {:error, _} = refusal -> refusal
        end

      {:error, reason} ->
        {:error, {:invalid_argument, "Invalid reference: #{reason}"}}
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
  # contents — one subtree read, no per-entry probing. Excludes the shared
  # build droppings (target/, node_modules/, .git/ — the same predicate
  # every tree copy applies) and keeps only .rs/.wit files and Cargo.toml.
  defp collect_source_files(ctx, src_base) do
    case Arca.read_subtree(ctx, src_base) do
      {:ok, pairs} ->
        for {rel, content} <- pairs,
            not Arca.Storage.build_dropping?(rel),
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

    build_opts = [target_type: target_type, on_progress: on_progress]

    # The build-isolation seam: CYFR_BUILDER_URL set → the builder
    # container compiles; unset → in-process, with Locus.Builder's honest
    # threat model. Same result shape either way.
    result =
      if Locus.BuilderClient.enabled?() do
        Locus.BuilderClient.compile(source_files, language, build_opts)
      else
        Locus.Builder.compile(source_files, language, build_opts)
      end

    case result do
      {:ok, result} ->
        {:ok, result}

      {:error, {:compilation_failed, exit_code, output}} ->
        {:error, "Compilation failed (exit #{exit_code}): #{output}"}

      {:error, :compilation_timeout} ->
        {:error, {:timeout, "Compilation timed out"}}

      {:error, {:toolchain_not_found, lang}} ->
        {:error,
         "Toolchain not found: #{lang}. Install cargo-component (cargo install cargo-component)."}

      {:error, {:builder_failed, message}} ->
        {:error, "Builder: #{message}"}

      {:error, :builder_unreachable} ->
        Logger.warning(
          "[Locus.MCP] builder unreachable — check CYFR_BUILDER_URL and the container"
        )

        {:error, {:unavailable, "The builder service"}}

      {:error, :builder_unauthorized} ->
        {:error,
         "The builder refused this server's token — check CYFR_BUILDER_TOKEN on both ends"}

      {:error, :builder_response_too_large} ->
        {:error, "The builder's response exceeded the size ceiling — the build was aborted"}

      {:error, reason} ->
        Logger.error("[Locus.MCP] compilation failed unexpectedly: #{inspect(reason)}")
        {:error, "Compilation failed for an unexpected reason — see the server log"}
    end
  end

  # Exclude tincture dist/ and data.db in addition to shared build artifacts.
  @tincture_excluded ~w(dist data.db)

  defp collect_tincture_source(ctx, base) do
    case Arca.read_subtree(ctx, base) do
      {:ok, pairs} ->
        for {rel, content} <- pairs,
            not Arca.Storage.build_dropping?(rel),
            not Enum.any?(rel, &(&1 in @tincture_excluded)),
            into: %{} do
          {Path.join(rel), content}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Save a tincture build into its version directory: the unit as it stands
  with the build laid over it, the manifest riding as the sentinel.

  Public because the toolchain half and the storage half fail
  independently. A test that drives `npm` proves the build; this proves the
  save, which is where every JS tincture used to stop.
  """
  @spec store_tincture_output(
          Sanctum.Context.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => binary()} | [{String.t(), binary()}]
        ) :: :ok | {:error, term()}
  def store_tincture_output(ctx, type, publisher, name, version, output_files) do
    base = Compendium.ComponentPath.version_dir(type, publisher, name, version)
    sentinel = Compendium.ComponentPath.manifest_name()

    # One unit commit, like every other writer of this unit shape
    # (Registry, Fork): sentinel-last, rollback on failure — a file-by-file
    # loop once halted mid-way and left a partially-written version
    # directory behind. Cap-CHECKED like the WASM save above — the old
    # blanket exemption let repeated tincture builds walk an athanor past
    # its storage quota 64 MiB at a time (only the builder's per-build
    # ceilings applied).
    #
    # The build answers with `dist/`-relative paths, and the unit's
    # completion file is its `cyfr-manifest.json`, which no `dist/` holds —
    # so committing the build alone resolved no sentinel and saved nothing.
    # Committing it alone would also have been wrong the moment it worked:
    # `commit_unit` clears the unit first, and the unit is where the SOURCE
    # lives — `package.json`, `vite.config.ts`, `src/`, `public/`, the
    # tincture's own `data.db`. The commit is therefore the unit as it
    # stands with the build laid over it, and the manifest rides as the
    # sentinel rather than as a file the build was expected to produce.
    with {:ok, manifest} <- Arca.get(ctx, base ++ [sentinel]),
         {:ok, kept} <- unit_files(ctx, base, sentinel) do
      built = Map.new(output_files, fn {rel, content} -> {Path.split(rel), content} end)
      files = kept |> Map.merge(built) |> Enum.to_list()

      total_bytes =
        Enum.reduce(files, 0, fn {_segs, content}, acc -> acc + byte_size(content) end)

      case Arca.Overlay.commit_unit(ctx, base, {:files, files},
             cap: {:checked, total_bytes},
             sentinel: manifest
           ) do
        {:ok, _written} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # What the unit already holds, keyed by segments relative to the version
  # directory, as `commit_unit`'s `{:files, …}` wants them. The manifest is
  # excluded: it rides as the sentinel, which the commit writes last and by
  # itself.
  #
  # This reads the whole unit — a tincture's own `data.db` included — because
  # the commit clears the unit before it writes, so anything not handed back
  # is lost. Phase 5's draft-and-revision model is what removes the read.
  defp unit_files(ctx, base, sentinel) do
    case Arca.read_subtree(ctx, base) do
      {:ok, entries} ->
        {:ok, entries |> Enum.reject(fn {segs, _} -> segs == [sentinel] end) |> Map.new()}

      {:error, reason} ->
        {:error, reason}
    end
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
          Cyfr.Bus.build(build_id, ctx),
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
