# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Builds do
  @moduledoc """
  Building a component of the local namespace: its sources are read from
  the athanor's components tree, built on the Locus builds service
  (`Compendium.Builds.Client`), and the verified result is published back
  into the unit — a component's WASM beside its sources, with the
  `Cargo.lock` the build used, or a tincture's `dist/` — before the
  component is registered.

  This server runs no toolchain. It builds exactly when a builds service
  is configured (`Cyfr.RuntimeConfig.builds_enabled?/0`); otherwise every
  build is refused before a row is written or a request made. It keeps no
  build slots either: the builds service caps its builds, on the whole and
  per athanor, and refuses one past a cap as `capacity`, which is answered
  here as a refusal to retry, never queued.

  ## A build's life

  `compile/3` runs a build on the caller's process and answers its result.
  `start/3` records the build as started (`Arca.BuildRecords`), runs the
  same build under `Compendium.Builds.TaskSupervisor` and answers its id
  at once; the row then carries the outcome, and a build whose process
  ends before it recorded one is recorded as failed by a second process
  watching it. Nothing is published for a build that did not end in a
  verified result: a refusal, a deadline, a disconnect, a result that does
  not verify, and a caller cancelled or killed while the builder worked
  all leave the unit as it was.

  A build has 270 seconds: the deadline the builder is sent and the client
  holds, inside the five minutes a tool call may take.

  ## Progress

  `:on_progress` is called with `t:progress/0` for each progress line the
  builder writes, in order, from the process that reads them, and then
  once more here: `:complete` when the result is published, `:error` when
  the build or its publication failed. The same events are
  `[:cyfr, :locus, :build, :start | :progress | :stop]` telemetry, with
  the build id, reference, athanor and person in the metadata.
  """

  require Logger

  alias Arca.BuildRecords
  alias Compendium.Builds.Client
  alias Compendium.ComponentPath
  alias Prima.BuilderProtocol
  alias Sanctum.Context

  @supervisor Compendium.Builds.TaskSupervisor
  @budget_ms 270_000
  @build_id ~r/^[A-Za-z0-9_-]{1,64}$/

  # A tincture's build output lands under `dist/` and its `data.db` is data;
  # neither is build input.
  @dist "dist"
  @tincture_excluded [@dist, "data.db"]

  @typedoc """
  One step of a build as its watchers see it: a stage the builder reported
  (`t:Prima.BuilderProtocol.stage/0`), or `:complete` or `:error` at its end.
  """
  @type progress :: %{build_id: String.t(), phase: atom(), message: String.t()}

  @typedoc """
  `:build_id`, the caller's own id for the build (minted when absent);
  `:resolve`, resolve a Rust component's crates afresh and keep the new
  `Cargo.lock`; `:on_progress`, called with each `t:progress/0`;
  `:budget_ms`, the build's budget in place of the default.
  """
  @type option ::
          {:build_id, String.t() | nil}
          | {:resolve, boolean()}
          | {:on_progress, (progress() -> any())}
          | {:budget_ms, pos_integer()}

  @doc """
  Build `reference` (a local component, its version resolved when absent),
  publish its output and start its registration.

  Answers the operation's result — `status`, `reference`, `digest`,
  `size`, `files`, `exports`, `language`, `target_type` and
  `registration: "pending"` — or a refusal `Cyfr.Ops.Error.render/2`
  renders.
  """
  @spec compile(Context.t(), String.t(), [option()]) :: {:ok, map()} | {:error, term()}
  def compile(%Context{} = ctx, reference, opts \\ []) when is_binary(reference) do
    with {:ok, build} <- admit(ctx, reference, opts), do: run(build)
  end

  @doc """
  Start a build of `reference` off the caller's process and answer
  `%{status: "started", build_id:, reference:}`. The build's row
  (`status/2`) reads `"started"` until it carries the outcome.
  """
  @spec start(Context.t(), String.t(), [option()]) :: {:ok, map()} | {:error, term()}
  def start(%Context{} = ctx, reference, opts \\ []) when is_binary(reference) do
    with {:ok, build} <- admit(ctx, reference, opts), do: run_recorded(build)
  end

  @doc "A started build's row, as `build.status` answers it."
  @spec status(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def status(%Context{} = ctx, build_id) when is_binary(build_id) do
    case BuildRecords.get(Context.actor(ctx), build_id) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:error, {:not_found, "Build", build_id}}
      # The store could not say. A build that exists and one that never
      # did both read as this, so neither may be answered as "no such
      # build" — the caller is told to look again, not that it is gone.
      {:error, :database_error} -> {:error, :unavailable}
    end
  end

  @doc """
  The toolchains builds run with, by language: what the builds service
  reports, and every language unavailable on a server that has none.
  """
  @spec toolchains() :: {:ok, %{toolchains: map()}} | {:error, term()}
  def toolchains do
    case Client.toolchains() do
      {:ok, toolchains} ->
        {:ok, %{toolchains: toolchains}}

      {:error, :not_configured} ->
        unavailable = %{available: false, command: nil, description: nil}
        {:ok, %{toolchains: Map.new(BuilderProtocol.languages(), &{&1, unavailable})}}

      {:error, outcome} ->
        {:error, refusal(outcome)}
    end
  end

  # ---------------------------------------------------------------------------
  # Admission
  # ---------------------------------------------------------------------------

  defp admit(ctx, reference, opts) do
    with :ok <- enabled(),
         {:ok, build_id} <- settle_build_id(ctx, Keyword.get(opts, :build_id)) do
      {:ok,
       %{
         ctx: ctx,
         reference: reference,
         build_id: build_id,
         resolve?: Keyword.get(opts, :resolve, false) == true,
         on_progress: Keyword.get(opts, :on_progress, fn _progress -> :ok end),
         budget_ms: Keyword.get(opts, :budget_ms, @budget_ms)
       }}
    end
  end

  # Refused in the one place every surface reaches — wire, console and
  # in-chain — and before anything else, so a server without a builds
  # service writes no row and makes no request.
  defp enabled do
    if Cyfr.RuntimeConfig.builds_enabled?() do
      :ok
    else
      {:error,
       "builds are disabled on this server: no builds service is configured " <>
         "(CYFR_LOCUS_BUILDS_URL and CYFR_LOCUS_BUILDS_KEY)"}
    end
  end

  # A caller may mint the id — a console subscribes to the progress topic
  # before it starts the build — but it lands in topic names and rows, so
  # its shape is bounded, and an id naming a build still in flight is
  # refused rather than refreshing that build's row under its subscriber
  # (`Arca.BuildRecords.record_started/3` overwrites the caller's own row).
  defp settle_build_id(_ctx, nil), do: {:ok, Prima.UUID7.generate_id("build")}

  defp settle_build_id(ctx, id) when is_binary(id) do
    cond do
      not Regex.match?(@build_id, id) ->
        {:error, {:invalid_argument, "build_id must be 1-64 characters of [A-Za-z0-9_-]"}}

      match?({:ok, %{"status" => "started"}}, BuildRecords.get(Context.actor(ctx), id)) ->
        {:error, {:invalid_argument, "build_id names a build still in flight"}}

      true ->
        {:ok, id}
    end
  end

  defp settle_build_id(_ctx, _other),
    do: {:error, {:invalid_argument, "build_id must be a string"}}

  # ---------------------------------------------------------------------------
  # A started build: its row, its process and the process watching it
  # ---------------------------------------------------------------------------

  defp run_recorded(%{ctx: ctx, build_id: build_id, reference: reference} = build) do
    case BuildRecords.record_started(Context.actor(ctx), build_id, reference) do
      :ok ->
        logger_metadata = Prima.LoggerContext.capture()

        started =
          Task.Supervisor.start_child(@supervisor, fn ->
            Prima.LoggerContext.restore(logger_metadata)
            record_outcome(build, run(build))
          end)

        # A task the supervisor refused would leave a row reading "started"
        # with nothing running it.
        case started do
          {:ok, runner} ->
            watch(build, runner)
            {:ok, %{status: "started", build_id: build_id, reference: reference}}

          {:error, reason} ->
            Logger.error(
              "[Compendium.Builds] could not start build #{build_id}: #{inspect(reason)}"
            )

            BuildRecords.record_finished(
              Context.actor(ctx),
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

  defp record_outcome(%{ctx: ctx, build_id: build_id}, {:ok, result}),
    do: BuildRecords.record_finished(Context.actor(ctx), build_id, "compiled", result)

  defp record_outcome(%{ctx: ctx, build_id: build_id}, {:error, reason}) do
    sentence =
      Cyfr.Ops.Error.render(reason) ||
        "The build failed for an unexpected reason — see the server log"

    BuildRecords.record_finished(Context.actor(ctx), build_id, "failed", sentence)
  end

  # A runner that is killed records nothing, and its row would read
  # "started" until retention called it orphaned. The watcher outlives it:
  # whatever ended the runner, a row it left reading "started" is closed
  # as failed. The runner is gone by then and the id cannot be taken by
  # another build while its row reads "started", so nothing else writes
  # the row between the read and the write.
  defp watch(%{ctx: ctx, build_id: build_id}, runner) do
    started =
      Task.Supervisor.start_child(@supervisor, fn ->
        ref = Process.monitor(runner)

        receive do
          {:DOWN, ^ref, :process, ^runner, _reason} -> close_unfinished(ctx, build_id)
        end
      end)

    with {:error, reason} <- started do
      Logger.warning(
        "[Compendium.Builds] build #{build_id} runs unwatched; were its process killed, " <>
          "its row would keep reading started: #{inspect(reason)}"
      )
    end

    :ok
  end

  defp close_unfinished(ctx, build_id) do
    with {:ok, %{"status" => "started"}} <- BuildRecords.get(Context.actor(ctx), build_id) do
      BuildRecords.record_finished(
        Context.actor(ctx),
        build_id,
        "failed",
        "The build's process ended before its outcome was recorded"
      )
    end
  end

  # ---------------------------------------------------------------------------
  # One build
  # ---------------------------------------------------------------------------

  defp run(%{ctx: ctx, build_id: build_id, reference: reference} = build) do
    meta = %{
      build_id: build_id,
      reference: reference,
      athanor_id: ctx.athanor_id,
      user_id: ctx.user_id
    }

    build = Map.put(build, :meta, meta)

    :telemetry.execute(
      [:cyfr, :locus, :build, :start],
      %{system_time: System.system_time()},
      meta
    )

    started = System.monotonic_time()

    outcome = build_and_publish(build)

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    :telemetry.execute(
      [:cyfr, :locus, :build, :stop],
      %{duration_ms: duration_ms},
      Map.merge(meta, %{
        status: if(match?({:ok, _}, outcome), do: :ok, else: :error),
        error: if(match?({:error, _}, outcome), do: elem(outcome, 1), else: nil)
      })
    )

    outcome
  end

  defp build_and_publish(%{ctx: ctx, reference: reference} = build) do
    with {:ok, type, name, version} <- parse_reference(reference),
         {:ok, version} <- resolve_version(ctx, reference, version),
         {:ok, sources} <- read_sources(ctx, type, name, version) do
      unit = %{type: type, name: name, version: version, sources: sources}

      with {:ok, built} <- build(build, unit),
           :ok <- publish(ctx, unit, built) do
        register(build)
        progress(build, :complete, completed(built))
        {:ok, result(build, built)}
      else
        {:error, _reason} = error ->
          progress(build, :error, "Build failed")
          error
      end
    end
  end

  defp result(%{reference: reference}, built) do
    %{
      status: "compiled",
      reference: reference,
      digest: built.digest,
      size: built.size,
      files: built |> Map.get(:output_files, %{}) |> Map.keys(),
      exports: built.exports,
      language: built.language,
      target_type: built.target_type,
      registration: "pending"
    }
  end

  defp completed(%{output_files: files, size: size}),
    do: "Build complete — #{size} bytes, #{map_size(files)} file(s)"

  defp completed(%{size: size, exports: exports}),
    do: "Build complete — #{size} bytes, #{length(exports)} export(s)"

  defp progress(%{build_id: build_id, meta: meta, on_progress: on_progress}, phase, message) do
    :telemetry.execute(
      [:cyfr, :locus, :build, :progress],
      %{system_time: System.system_time()},
      Map.merge(meta, %{phase: phase, message: message})
    )

    on_progress.(%{build_id: build_id, phase: phase, message: message})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Sources
  # ---------------------------------------------------------------------------

  # `Prima.ComponentRef.parse/1` gates the type and the namespace policy the
  # namespace. Sources, version resolution and the published artifact all
  # use the local publisher, so a reference of another namespace is refused
  # rather than renamespaced.
  defp parse_reference(reference) do
    case Prima.ComponentRef.parse(reference) do
      {:ok, ref} ->
        case Compendium.NamespacePolicy.require_local_build(ref.namespace) do
          :ok -> {:ok, ref.type, ref.name, ref.version}
          {:error, _} = refusal -> refusal
        end

      {:error, reason} ->
        {:error, {:invalid_argument, "Invalid reference: #{reason}"}}
    end
  end

  defp resolve_version(_ctx, _reference, version) when is_binary(version), do: {:ok, version}

  defp resolve_version(ctx, reference, nil) do
    case Compendium.Resolver.resolve(ctx, reference) do
      {:ok, resolved_ref, _metadata} ->
        {:ok, parsed} = Prima.ComponentRef.parse(resolved_ref)
        {:ok, parsed.version}

      {:error, reason} ->
        {:error, "Cannot resolve version for #{reference}: #{reason}"}
    end
  end

  # Builds are of the local namespace alone — the tree the scanner indexes
  # and directory registration accepts.
  defp publisher, do: ComponentPath.default_publisher()

  defp read_sources(ctx, "tincture", name, version) do
    base = ComponentPath.version_dir("tincture", publisher(), name, version)
    package = base ++ ["package.json"]

    case Arca.get(Sanctum.Context.actor(ctx), package) do
      {:ok, _} ->
        {:ok, collect(ctx, base, &tincture_source?/1)}

      {:error, _} ->
        {:error,
         "No package.json found at #{Enum.join(package, "/")}. " <>
           "Vanilla tinctures don't need compilation — use component.register instead."}
    end
  end

  defp read_sources(ctx, type, name, version) do
    base = ComponentPath.version_dir(type, publisher(), name, version) ++ ["src"]
    lib_rs = base ++ ["src", "lib.rs"]

    case Arca.get(Sanctum.Context.actor(ctx), lib_rs) do
      {:ok, _} ->
        {:ok, collect(ctx, base, &rust_source?/1)}

      {:error, _} ->
        {:error,
         "Source not found at #{Enum.join(lib_rs, "/")}. " <>
           "Use component.new to scaffold the project first."}
    end
  end

  # One subtree read, without the build droppings every tree copy excludes
  # (`target/`, `node_modules/`, `.git/`).
  defp collect(ctx, base, keep?) do
    case Arca.read_subtree(Sanctum.Context.actor(ctx), base) do
      {:ok, pairs} ->
        for {rel, content} <- pairs,
            not Arca.Storage.build_dropping?(rel),
            keep?.(rel),
            into: %{},
            do: {Path.join(rel), content}

      {:error, _} ->
        %{}
    end
  end

  defp rust_source?(rel) do
    name = List.last(rel)

    String.ends_with?(name, ".rs") or String.ends_with?(name, ".wit") or
      name in ["Cargo.toml", "Cargo.lock"]
  end

  defp tincture_source?(rel), do: not Enum.any?(rel, &(&1 in @tincture_excluded))

  # ---------------------------------------------------------------------------
  # The build, and how each way it ends is answered
  # ---------------------------------------------------------------------------

  defp build(%{ctx: ctx, resolve?: resolve?, budget_ms: budget_ms} = build, unit) do
    request = %{
      athanor_id: ctx.athanor_id,
      target_type: String.to_existing_atom(unit.type),
      resolve: resolve?,
      sources: unit.sources
    }

    opts = [
      deadline: System.system_time(:millisecond) + budget_ms,
      on_progress: &progress(build, &1, &2)
    ]

    case Client.build(request, opts) do
      {:ok, built} -> {:ok, built}
      {:error, outcome} -> {:error, refusal(outcome)}
    end
  end

  defp refusal(:not_configured),
    do: "builds are disabled on this server: no builds service is configured"

  defp refusal({:sources, error}) do
    {:invalid_argument,
     "The component's sources cannot be sent to the builder: " <> BuilderProtocol.describe(error)}
  end

  defp refusal(:unreachable) do
    Logger.warning(
      "[Compendium.Builds] the builds service is unreachable — check CYFR_LOCUS_BUILDS_URL " <>
        "and the locus-builds service"
    )

    {:unavailable, "The builder service"}
  end

  defp refusal(:disconnected) do
    Logger.warning("[Compendium.Builds] the builds service's answer ended before its build did")
    "The builder's answer ended before the build finished, so nothing was saved — retry shortly"
  end

  defp refusal(:deadline),
    do: {:timeout, "The build passed its deadline and was ended; nothing was saved"}

  # The builds service caps its builds, on the whole and per athanor: a
  # refusal to retry, never a queue.
  defp refusal({:refused, {:capacity, max}, _diagnostics}),
    do: "Build capacity is full (#{max} concurrent) — retry shortly"

  defp refusal({:refused, {:timeout, budget_ms}, _diagnostics}),
    do: {:timeout, "Compilation timed out after #{budget_ms} ms"}

  defp refusal({:refused, {:failed, {:status, status}}, diagnostics}),
    do: "Compilation failed (exit #{status}): " <> Enum.join(diagnostics, "\n")

  defp refusal({:refused, {:unauthorized, _why} = refused, _diagnostics}) do
    "Builder: " <>
      BuilderProtocol.describe_refusal(refused) <>
      " (CYFR_LOCUS_BUILDS_KEY here, LOCUS_BUILDS_KEY on the builds service)"
  end

  defp refusal({:refused, {:malformed, _sentence} = refused, _diagnostics}) do
    Logger.error("[Compendium.Builds] " <> BuilderProtocol.describe_refusal(refused))
    "Builder: " <> BuilderProtocol.describe_refusal(refused)
  end

  # `memory` with its bound, `unavailable` naming what is missing, and a
  # build killed by a signal: the builder's own sentence.
  defp refusal({:refused, refused, _diagnostics}),
    do: "Builder: " <> BuilderProtocol.describe_refusal(refused)

  # Both ends' versions and the remedy, for an operator to match the images.
  defp refusal({:protocol_mismatch, builder, client}),
    do: "Builder: " <> BuilderProtocol.describe_refusal({:protocol_mismatch, builder, client})

  # The reason can carry text of the builder's choosing — a path, a field
  # name — so what is logged of it is bounded.
  defp refusal({:malformed, reason}) do
    Logger.error(
      "[Compendium.Builds] the builder's answer was refused: " <>
        inspect(reason, limit: 8, printable_limit: 256)
    )

    "The builder's answer was refused: it is not the builder protocol's, or its result " <>
      "did not verify — see the server log"
  end

  # ---------------------------------------------------------------------------
  # Publication
  # ---------------------------------------------------------------------------

  defp publish(ctx, unit, %{output_files: files}) do
    ctx
    |> store_tincture_output(unit.type, publisher(), unit.name, unit.version, files)
    |> published()
  end

  # The tenant's storage cap applies to the artifact as to any write.
  defp publish(ctx, unit, %{wasm_bytes: wasm_bytes} = built) do
    wasm_path = ComponentPath.wasm_path(unit.type, publisher(), unit.name, unit.version)

    published(
      with :ok <- Arca.put(Sanctum.Context.actor(ctx), wasm_path, wasm_bytes),
           do: keep_lockfile(ctx, unit, built)
    )
  end

  defp published(:ok), do: :ok

  defp published({:error, reason}) do
    Logger.error("[Compendium.Builds] the built artifact was not saved: #{inspect(reason)}")
    {:error, {:unavailable, "The build store"}}
  end

  # The Cargo.lock a Rust build used becomes the unit's, so the next build
  # of the same sources is locked to it.
  defp keep_lockfile(ctx, unit, %{lockfile: lockfile}) when is_binary(lockfile) do
    if Map.get(unit.sources, "Cargo.lock") == lockfile do
      :ok
    else
      path = ComponentPath.version_dir(unit.type, publisher(), unit.name, unit.version)
      Arca.put(Sanctum.Context.actor(ctx), path ++ ["src", "Cargo.lock"], lockfile)
    end
  end

  defp keep_lockfile(_ctx, _unit, _built), do: :ok

  @doc """
  Publish a tincture build into its version directory: the build replaces
  the unit's `dist/` whole, as a new revision of the unit
  (`Arca.Overlay.replace_subtree/5`). The revision's row commit publishes
  it, and the rest of the unit — its manifest, its source and its own
  `data.db` — is carried over as it is. A version with no manifest
  publishes nothing (`{:error, :not_found}`), and a commit that landed on
  the unit meanwhile refuses this one (`{:error, :stale_revision}`).

  What a reader sees while the new revision is moved into place is the
  adapter's (`Arca.Overlay`): on a filesystem, the previous `dist/` whole
  and then the new one; on an object store, which has no rename, some
  files of each until the move finishes.

  Public because the build and the publication fail independently: a
  scripted builder proves the one, this the other.
  """
  @spec store_tincture_output(
          Context.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          %{String.t() => binary()} | [{String.t(), binary()}]
        ) :: :ok | {:error, term()}
  def store_tincture_output(%Context{} = ctx, type, publisher, name, version, output_files) do
    unit = ComponentPath.version_dir(type, publisher, name, version)
    files = Enum.map(output_files, fn {rel, content} -> {Path.split(rel), content} end)
    total_bytes = Enum.reduce(files, 0, fn {_segs, content}, acc -> acc + byte_size(content) end)

    Arca.Overlay.replace_subtree(Sanctum.Context.actor(ctx), unit, [@dist], files,
      cap: {:checked, total_bytes}
    )
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  # Registration goes through the catalog's dispatch, never a provider's
  # handler, so it takes the same authorization, timeout and request-log
  # row as any other call; a registration that fails falls back to a scan.
  # A started build's row carries the outcome; a build with no row told
  # its caller `"pending"` and this is a no-op.
  defp register(%{ctx: ctx, build_id: build_id}) do
    logger_metadata = Prima.LoggerContext.capture()

    started =
      Task.Supervisor.start_child(@supervisor, fn ->
        Prima.LoggerContext.restore(logger_metadata)

        outcome =
          case Cyfr.Ops.Catalog.call_external("component", ctx, %{"action" => "register"}) do
            {:ok, _} ->
              "done"

            {:error, reason} ->
              Logger.warning(
                "[Compendium.Builds] registration after the build failed: #{inspect(reason)}"
              )

              Compendium.AutoIndexer.scan(ctx: ctx)
              "indexed"
          end

        BuildRecords.record_registration(Context.actor(ctx), build_id, outcome)
      end)

    # A task the supervisor refused would leave the row reading
    # `registration: "pending"` with nothing logged.
    with {:error, reason} <- started do
      Logger.warning(
        "[Compendium.Builds] could not start registration for build #{build_id}: " <>
          inspect(reason)
      )

      BuildRecords.record_registration(Context.actor(ctx), build_id, "failed")
    end

    :ok
  end
end
