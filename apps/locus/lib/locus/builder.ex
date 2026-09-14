# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Builder do
  @moduledoc """
  Compilation service that takes source code and produces build artifacts.

  Supports:
  - Rust -> WASM Component Model via `cargo-component`
  - JavaScript/React -> static bundle via npm + Vite

  ## arca:bypass-ok=D — entire module

  Cargo / npm shell out to OS toolchains that require a real local
  filesystem. The compile sandbox is Group D by definition: every `File.*`
  call here operates on a per-build tmp dir that is created, written to,
  read from, and deleted entirely within `compile/3`. No Arca-tracked
  content ever sits on disk outside the function call.

  ## Security Properties (what is actually enforced here)

  - Temp directory per compilation, cleaned up immediately
  - Source size and path traversal validated before writing to disk
  - Compiled WASM validated (`Compendium.WasmValidator`) before returning
  - Output bounded: dist file count/bytes capped, compiler chatter capped
  - npm runs with `--ignore-scripts`: a dependency's lifecycle script
    never executes on this host
  - WASM output executes only inside the Opus sandbox

  What is NOT enforced here and is honest to say: the compilers
  themselves (`cargo`, `npm run build`) run as this OS user with the
  network reachable — crates.io/npm access is how builds work, and a
  malicious build script in the USER'S OWN sources runs with this
  process's ambient authority. Deployments that need a harder wall run
  builds in the separate builder container (`CYFR_BUILDER_URL`), which
  carries the toolchains so the app image does not.

  ## Usage

      {:ok, result} = Locus.Builder.compile(%{"src/lib.rs" => source}, :rust, target_type: :reagent)
      # => {:ok, %{wasm_bytes: <<...>>, digest: "sha256:...", size: 1234,
      #           exports: [...], language: "rust", target_type: "reagent"}}

      {:ok, result} = Locus.Builder.compile(%{"package.json" => pkg}, :javascript, target_type: :tincture)
      # => {:ok, %{output_files: %{"index.html" => ..., "assets/..." => ...},
      #           digest: "sha256:...", size: 5678, exports: [],
      #           language: "javascript", target_type: "tincture"}}

      Locus.Builder.toolchain_available?(:rust)        # => true/false
      Locus.Builder.toolchain_available?(:javascript)  # => true/false
  """

  require Logger

  # Compile-time build limits.
  @max_source_size 1_024 * 1_024
  # 30s under the MCP tool layer's 5-minute brutal-kill deadline, so a build
  # that exhausts its budget dies here — a graceful {:error, :compilation_timeout}
  # with the slot released — instead of losing the race to the caller's kill.
  # The margin also has to absorb the work outside the timed command: source
  # collection from Arca, WASM validation, and the artifact store.
  @default_timeout_ms 270_000

  @doc """
  The toolchain languages this builder speaks — the roster, where the
  implementation lives. `Locus.BuilderService` validates request input
  against it rather than hand-copying the list.
  """
  @spec languages() :: [atom()]
  def languages, do: [:rust, :javascript]

  @doc """
  The language a component type is built from: Rust for a reagent, a
  catalyst or a formula, JavaScript for a tincture. A compile that pairs
  them otherwise is refused as `{:language_mismatch, language, type}`.
  """
  @spec language_for(atom()) :: :rust | :javascript
  def language_for(:tincture), do: :javascript
  def language_for(type) when type in [:reagent, :catalyst, :formula], do: :rust

  @doc """
  The total-source ceiling one compile may carry — the one bound the
  service's pre-decode check and the client's pre-ship check both derive
  from, so neither can admit what the compile itself will refuse.
  """
  @spec max_source_bytes() :: pos_integer()
  def max_source_bytes, do: @max_source_size

  @doc """
  Compile source code using the appropriate toolchain.

  ## Parameters

  - `source_files` - A map of `%{relative_path => content}` for the project.
    For `:rust`: must contain `"src/lib.rs"`. Optional `"Cargo.toml"` is merged.
    For `:javascript`: must contain `"package.json"`.
  - `language` - `:rust` or `:javascript`
  - `opts` - Keyword options:
    - `:target_type` - Component type (`:reagent`, `:catalyst`, `:formula`, `:tincture`)
    - `:timeout_ms` - Compilation timeout, in milliseconds. Defaults to
      `#{@default_timeout_ms}` — 30s under the MCP tool layer's five-minute
      brutal kill, so an over-budget build ends here as
      `{:error, :compilation_timeout}` with its slot released rather than
      losing the race to the caller's kill. Raising it past that deadline
      gives back the graceful failure. (This line said "300s", which is the
      deadline itself.)

  ## Returns

  For `:rust`: `{:ok, %{wasm_bytes, digest, size, exports, language, target_type}}`
  For `:javascript`: `{:ok, %{output_files, digest, size, exports, language, target_type}}`
  On failure: `{:error, reason}`
  """
  @spec compile(map(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile(source_files, language, opts \\ [])

  def compile(source_files, _language, _opts) when source_files == %{},
    do: {:error, :empty_source}

  def compile(%{} = source_files, language, opts) when is_atom(language) do
    target_type = Keyword.get(opts, :target_type, :reagent)

    with :ok <- paired(language, target_type),
         :ok <- validate_source_files(source_files, language),
         :ok <- check_toolchain(language) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      on_progress = Keyword.get(opts, :on_progress, fn _phase, _message -> :ok end)

      do_compile(source_files, language, target_type, timeout_ms, on_progress)
    end
  end

  @doc """
  Check if a compilation toolchain is available on the system.
  """
  @spec toolchain_available?(atom()) :: boolean()
  def toolchain_available?(:rust) do
    System.find_executable("cargo-component") != nil and
      System.find_executable("cargo") != nil
  end

  def toolchain_available?(:javascript) do
    System.find_executable("node") != nil and
      System.find_executable("npm") != nil
  end

  def toolchain_available?(_), do: false

  @doc """
  Return information about all supported toolchains.
  """
  @spec available_toolchains() :: map()
  def available_toolchains do
    %{
      rust: %{
        available: toolchain_available?(:rust),
        command: "cargo-component",
        description: "Rust -> WASM Component Model (cargo-component)"
      },
      javascript: %{
        available: toolchain_available?(:javascript),
        command: "npm",
        description: "JavaScript/React -> static bundle (npm + Vite)"
      }
    }
  end

  # ============================================================================
  # Private: Source Validation
  # ============================================================================

  # A language this builder does not speak is the toolchain check's to refuse.
  defp paired(language, target_type) do
    expected =
      if target_type in [:reagent, :catalyst, :formula, :tincture], do: language_for(target_type)

    if language in languages() and expected != language,
      do: {:error, {:language_mismatch, language, target_type}},
      else: :ok
  end

  defp validate_source_files(source_files, :rust) do
    unless Map.has_key?(source_files, "src/lib.rs") do
      {:error, :missing_lib_rs}
    else
      validate_source_size(source_files)
    end
  end

  defp validate_source_files(source_files, :javascript) do
    unless Map.has_key?(source_files, "package.json") do
      {:error, :missing_package_json}
    else
      validate_source_size(source_files)
    end
  end

  defp validate_source_files(source_files, _language) do
    validate_source_size(source_files)
  end

  defp validate_source_size(source_files) do
    total_size = source_files |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))

    if total_size > @max_source_size do
      {:error, {:source_too_large, total_size, @max_source_size}}
    else
      validate_source_paths(source_files)
    end
  end

  # Every key lands under the build tmp dir via Path.join, which neutralizes
  # a leading `/` but not `..` — so keys are held to PathSafety's relative-
  # path rules before any directory exists. write_source_files/2 keeps an
  # expand-prefix backstop at the actual write.
  defp validate_source_paths(source_files) do
    source_files
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Cyfr.PathSafety.validate_relative_path(path) do
        :ok -> {:cont, :ok}
        {:error, {_reason, message}} -> {:halt, {:error, {:invalid_source_path, path, message}}}
      end
    end)
  end

  defp check_toolchain(language) do
    if toolchain_available?(language) do
      :ok
    else
      {:error, {:toolchain_not_found, language}}
    end
  end

  # ============================================================================
  # Private: Compilation
  # ============================================================================

  defp do_compile(source_files, :rust, target_type, timeout_ms, on_progress) do
    with {:ok, tmp_dir} <- create_temp_dir() do
      try do
        on_progress.(:preparing, "Preparing source files...")

        with :ok <- write_source(tmp_dir, :rust, target_type, source_files),
             :ok <- on_progress.(:compiling, "Compiling #{target_type} (rust)..."),
             {:ok, wasm_path} <- run_compiler(tmp_dir, :rust, timeout_ms, on_progress),
             :ok <- on_progress.(:validating, "Validating WASM binary..."),
             {:ok, wasm_bytes} <- File.read(wasm_path),
             {:ok, validation} <- Compendium.WasmValidator.validate(wasm_bytes) do
          on_progress.(
            :complete,
            "Build complete — #{validation.size} bytes, #{length(validation.exports)} export(s)"
          )

          {:ok,
           %{
             wasm_bytes: wasm_bytes,
             digest: validation.digest,
             size: validation.size,
             exports: validation.exports,
             language: "rust",
             target_type: to_string(target_type)
           }}
        else
          error ->
            on_progress.(:error, "Build failed")
            error
        end
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  defp do_compile(source_files, :javascript, target_type, timeout_ms, on_progress) do
    with {:ok, tmp_dir} <- create_temp_dir() do
      try do
        on_progress.(:preparing, "Preparing source files...")

        with :ok <- write_source(tmp_dir, :javascript, target_type, source_files),
             :ok <-
               on_progress.(:compiling, "Building tincture (npm install && npm run build)..."),
             {:ok, _exit_code, _output} <- run_js_build(tmp_dir, timeout_ms, on_progress),
             {:ok, output_files} <- collect_dist_files(tmp_dir) do
          {digest, size} = Cyfr.Digest.file_set(output_files)

          on_progress.(
            :complete,
            "Build complete — #{size} bytes, #{map_size(output_files)} file(s)"
          )

          {:ok,
           %{
             output_files: output_files,
             digest: digest,
             size: size,
             exports: [],
             language: to_string(:javascript),
             target_type: to_string(target_type)
           }}
        else
          error ->
            on_progress.(:error, "Build failed")
            error
        end
      after
        File.rm_rf(tmp_dir)
      end
    end
  end

  defp create_temp_dir do
    case System.tmp_dir() do
      nil ->
        {:error, :no_tmp_dir}

      tmp ->
        id = Cyfr.Hex.short()
        dir = Path.join(tmp, "locus_build_#{id}")

        case File.mkdir_p(dir) do
          :ok ->
            watch_tmp_dir(self(), dir)
            {:ok, dir}

          {:error, reason} ->
            {:error, {:mkdir_failed, reason}}
        end
    end
  end

  # An unlinked janitor removes the build tree when its owner exits,
  # including kills that skip do_compile/5’s after block.
  defp watch_tmp_dir(owner, dir) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> File.rm_rf(dir)
      end
    end)
  end

  defp write_source(tmp_dir, :rust, target_type, source_files) do
    # Write Cargo.toml — merge user dependencies if a user Cargo.toml is provided
    cargo_toml =
      case Map.get(source_files, "Cargo.toml") do
        nil -> cargo_toml_for(target_type)
        user_cargo -> merge_cargo_toml(cargo_toml_for(target_type), user_cargo)
      end

    with :ok <- File.write(Path.join(tmp_dir, "Cargo.toml"), cargo_toml),
         :ok <- write_source_files(tmp_dir, source_files) do
      # Use source-local WIT files if present, otherwise copy from canonical location
      has_wit = Enum.any?(source_files, fn {path, _} -> String.starts_with?(path, "wit/") end)
      if has_wit, do: :ok, else: copy_wit_files(tmp_dir, target_type)
    end
  end

  defp write_source(tmp_dir, :javascript, _target_type, source_files) do
    write_source_files(tmp_dir, source_files)
  end

  defp write_source_files(tmp_dir, source_files) do
    source_files
    |> Enum.reject(fn {path, _} -> path == "Cargo.toml" end)
    |> Enum.reduce_while(:ok, fn {rel_path, content}, :ok ->
      dest = Path.join(tmp_dir, rel_path)

      # compile/3 is a public API taking an arbitrary path=>content map; the
      # shipped callers derive keys from Arca basenames, but this is the
      # filesystem boundary and it holds its own line: PathSafety refuses
      # `..` (the live escape — Path.join neutralizes a leading `/`, not a
      # traversal), and the expand-prefix check backstops anything the
      # segment rules miss.
      with :ok <- Cyfr.PathSafety.validate_relative_path(rel_path),
           :ok <- contained_in(tmp_dir, dest),
           :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, content) do
        {:cont, :ok}
      else
        {:error, {_reason, message}} -> {:halt, {:error, {:write_failed, rel_path, message}}}
        {:error, reason} -> {:halt, {:error, {:write_failed, rel_path, reason}}}
      end
    end)
  end

  defp contained_in(tmp_dir, dest) do
    root = Path.expand(tmp_dir)

    if String.starts_with?(Path.expand(dest), root <> "/") do
      :ok
    else
      {:error, "path escapes the build directory"}
    end
  end

  @doc """
  Return the Cargo.toml content for a given component type.

  Delegates to `Compendium.Scaffold.cargo_toml_for/2` — the canonical
  template — omitting the `cyfr:oauth` WIT dep from the GENERATED
  Cargo.toml. The sandbox still materializes the full catalyst WIT tree
  (`copy_wit_files/2` copies everything `Compendium.WITSource.files/1`
  returns, oauth included — the world imports it, so the files must
  exist); what this omission controls is only which packages the
  generated manifest binds. A user project that uses oauth carries its
  own Cargo.toml, which `merge_cargo_toml/2` treats as authoritative for
  WIT deps.
  """
  def cargo_toml_for(type) do
    Compendium.Scaffold.cargo_toml_for(type, include_oauth_wit: false)
  end

  # Merge user Cargo.toml with the template.
  # The user's Cargo.toml is authoritative for [package.metadata.component.target.dependencies]
  # (WIT deps) since it must match the actual WIT files present. We use the user's file as the
  # base and only ensure required crate dependencies (wit-bindgen-rt) are present.
  defp merge_cargo_toml(_template, user_cargo) do
    ensure_required_deps(user_cargo)
  end

  @required_deps %{
    "wit-bindgen-rt" => ~s(wit-bindgen-rt = "0.25")
  }

  # Ensure required crate dependencies are present in the user's Cargo.toml.
  defp ensure_required_deps(cargo_toml) do
    Enum.reduce(@required_deps, cargo_toml, fn {dep_name, dep_line}, acc ->
      if String.contains?(acc, dep_name) do
        acc
      else
        String.replace(acc, "[dependencies]\n", "[dependencies]\n#{dep_line}\n", global: false)
      end
    end)
  end

  # The WIT definitions are the host ABI, release-embedded
  # (`Compendium.WITSource`) — written into the sandbox rather than copied
  # from a disk directory, so a build compiles against exactly what the
  # running host implements, on any storage adapter.
  defp copy_wit_files(tmp_dir, target_type) do
    case Compendium.WITSource.files(target_type) do
      [] ->
        {:error, {:wit_not_found, target_type}}

      files ->
        Enum.reduce_while(files, :ok, fn {rel_segments, content}, :ok ->
          dest = Path.join([tmp_dir, "wit" | rel_segments])
          File.mkdir_p!(Path.dirname(dest))

          case File.write(dest, content) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:wit_copy_failed, dest, reason}}}
          end
        end)
    end
  end

  defp run_compiler(tmp_dir, :rust, timeout_ms, on_progress) do
    output_dir = Path.join(tmp_dir, "target/wasm32-wasip2/release")
    crate_name = extract_crate_name(tmp_dir)
    output = Path.join(output_dir, "#{crate_name}.wasm")
    args = ["component", "build", "--release", "--target", "wasm32-wasip2"]

    run_with_timeout("cargo", args, tmp_dir, output, timeout_ms, on_progress)
  end

  # Extract the crate name from Cargo.toml to determine the output .wasm filename.
  # Cargo converts hyphens to underscores in output filenames.
  defp extract_crate_name(tmp_dir) do
    cargo_path = Path.join(tmp_dir, "Cargo.toml")

    case File.read(cargo_path) do
      {:ok, content} ->
        case Regex.run(~r/^\s*name\s*=\s*"([^"]+)"/m, content) do
          [_, name] -> String.replace(name, "-", "_")
          _ -> "cyfr_component"
        end

      _ ->
        "cyfr_component"
    end
  end

  defp run_js_build(tmp_dir, timeout_ms, on_progress) do
    sh = System.find_executable("sh") || "sh"

    run_with_timeout(
      sh,
      # --ignore-scripts: a dependency's postinstall never runs on this
      # host. Modern esbuild/Vite ship platform binaries as optional
      # dependencies, so tincture builds do not need lifecycle scripts.
      ["-c", "npm install --no-audit --no-fund --ignore-scripts 2>&1 && npm run build 2>&1"],
      tmp_dir,
      nil,
      timeout_ms,
      on_progress
    )
  end

  defp collect_dist_files(tmp_dir) do
    dist_dir = Path.join(tmp_dir, "dist")

    if File.dir?(dist_dir) do
      paths = list_files_recursive(dist_dir)

      with :ok <- check_output_count(paths),
           {:ok, files} <- read_dist_files(dist_dir, paths) do
        if map_size(files) == 0 do
          {:error, {:compilation_failed, 0, "Build produced no output files in dist/"}}
        else
          {:ok, files}
        end
      end
    else
      {:error, {:compilation_failed, 0, "Build did not produce a dist/ directory"}}
    end
  end

  @max_output_files 500
  # The shared 64 MiB ceiling — the same bound the base64 ingress uses.
  @max_output_total_bytes Cyfr.Limits.default_max_memory_bytes()

  defp check_output_count(paths) when length(paths) > @max_output_files,
    do:
      {:error,
       {:compilation_failed, 0,
        "Build produced #{length(paths)} files in dist/ (max #{@max_output_files})"}}

  defp check_output_count(_paths), do: :ok

  # Reads answer with a refusal, never a raise, and the running byte total
  # is bounded — a build's output cannot balloon this process.
  defp read_dist_files(dist_dir, paths) do
    Enum.reduce_while(paths, {:ok, {%{}, 0}}, fn file_path, {:ok, {acc, bytes}} ->
      rel = Path.relative_to(file_path, dist_dir)

      case File.read(file_path) do
        {:ok, content} when bytes + byte_size(content) > @max_output_total_bytes ->
          {:halt,
           {:error,
            {:compilation_failed, 0,
             "Build output exceeds #{@max_output_total_bytes} bytes in dist/"}}}

        {:ok, content} ->
          {:cont, {:ok, {Map.put(acc, rel, content), bytes + byte_size(content)}}}

        {:error, reason} ->
          {:halt, {:error, {:compilation_failed, 0, "Cannot read dist/#{rel}: #{reason}"}}}
      end
    end)
    |> case do
      {:ok, {files, _bytes}} -> {:ok, files}
      {:error, _} = error -> error
    end
  end

  # The walk out of `dist/` refuses symlinks, the way `Arca.Adapters.Local`
  # refuses them on the way in. `File.dir?/1` and `File.read/1` both FOLLOW
  # them, and this output is written into the athanor's version directory —
  # so a `dist/` entry pointing anywhere on the box would have been read and
  # persisted as build output. Sources are already held to `Cyfr.PathSafety`
  # on the way in; this is the same boundary on the way out.
  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          case File.lstat(full) do
            {:ok, %File.Stat{type: :directory}} ->
              list_files_recursive(full)

            {:ok, %File.Stat{type: :regular}} ->
              [full]

            {:ok, %File.Stat{type: other}} ->
              Logger.warning("[Locus.Builder] skipping #{other} in build output: #{full}")
              []

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp run_with_timeout(command, args, cwd, output_path, timeout_ms, on_progress) do
    logger_metadata = Cyfr.LoggerContext.capture()
    caller = self()

    # Run unlinked so spawn failures do not kill the caller or skip
    # its build-tree cleanup.
    task =
      Task.Supervisor.async_nolink(Locus.TaskSupervisor, fn ->
        Cyfr.LoggerContext.restore(logger_metadata)
        executable = System.find_executable(command) || command

        # Run the toolchain in its own process group so a timeout can take
        # its descendants with it.
        #
        # `setsid` only execs in place when it is not already a process
        # group leader; when it is, it forks and the parent returns 0 at
        # once. A port's child is a group leader on Linux, so without
        # `--wait` the build detached into its own session, every exit
        # status read as 0, and a compile that failed came back as a
        # missing artifact. `--wait` keeps setsid between us and the
        # program for as long as it runs, and hands back its status.
        {spawn_exec, spawn_args} =
          case System.find_executable("setsid") do
            nil -> {executable, args}
            setsid -> {setsid, ["--wait", executable | args]}
          end

        port =
          Port.open({:spawn_executable, spawn_exec}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, spawn_args},
            {:cd, cwd},
            # User-supplied code runs during a build (the project's own
            # `npm run build` script, its build.rs) — and a port child
            # inherits the BEAM's entire environment: database URL, keyring
            # material, provider keys. Everything not on the allowlist is
            # explicitly unset ({Name, false}); the toolchain needs only
            # its own homes, locale, and the proxy knobs.
            {:env, scrubbed_build_env()}
          ])

        # Store OS PID so the parent can kill the process tree on timeout
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} ->
            Process.put(:builder_os_pid, os_pid)
            watch_for_orphans(self(), caller, os_pid)

          _ ->
            :ok
        end

        collect_port_output(port, [], on_progress)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, 0, output}} ->
        cond do
          is_nil(output_path) ->
            {:ok, 0, output}

          File.exists?(output_path) ->
            {:ok, output_path}

          true ->
            # The command believed it succeeded and left nothing at the path
            # the build expects. Its own output is the only evidence of why,
            # and discarding it made this indistinguishable from a silent
            # toolchain difference between one machine and another.
            trimmed = String.trim(output)

            Logger.error(
              "[Locus.Builder] #{command} exited 0 without producing " <>
                "#{output_path}; its output was:\n#{trimmed}"
            )

            {:error, {:output_not_found, trimmed}}
        end

      {:ok, {:ok, exit_code, output}} ->
        {:error, {:compilation_failed, exit_code, String.trim(output)}}

      nil ->
        # Retrieve the OS PID before killing the task so we can clean up
        # the spawned process tree that Task.shutdown won't reach
        os_pid = get_task_os_pid(task)
        Task.shutdown(task, :brutal_kill)
        kill_os_process(os_pid)
        {:error, :compilation_timeout}

      # `Task.yield/2` also answers `{:exit, reason}` — the task died rather
      # than returning — which had no clause and became a CaseClauseError.
      # With `async_nolink` above, that is now the ordinary way a failed
      # `Port.open/2` arrives, and it is a failed compile, not a crash.
      {:exit, reason} ->
        Logger.error("[Locus.Builder] #{command} task exited: #{inspect(reason)}")
        kill_os_process(get_task_os_pid(task))
        {:error, {:compilation_failed, :task_exited}}
    end
  end

  # Two processes can strand a build, and neither death closes the toolchain
  # by itself: closing the port signals only the direct child, never the
  # cargo/npm process GROUP.
  #
  # The task owns the port. The caller owns the deadline — it is the one
  # inside `Task.yield/2` — and the task is deliberately UNLINKED from it,
  # so killing the caller (the MCP tool layer brutal-kills its provider task
  # on its own deadline) leaves the task running with nothing left to time
  # it out. An earlier comment here claimed that kill arrived "through the
  # link"; `async_nolink` never made one.
  #
  # So the watcher outlives both and reaps the group when either dies
  # abnormally. A double kill against the builder's own timeout path is a
  # harmless ESRCH.
  @doc false
  # Public for its own test: the behaviour is a race between three
  # processes and an OS one, which nothing reachable from `compile/3` can
  # arrange without a real toolchain and a slow build.
  def watch_for_orphans(task, caller, os_pid) do
    armed = self()

    watcher =
      spawn(fn ->
        task_ref = Process.monitor(task)
        caller_ref = Process.monitor(caller)
        send(armed, {:watching, self()})

        receive do
          {:DOWN, ref, :process, _pid, reason} when ref in [task_ref, caller_ref] ->
            unless reason == :normal do
              kill_os_process(os_pid)

              # Only ever the task. When the caller is the one that died, the
              # task is left holding a port onto a process that is now gone and
              # a deadline nobody is enforcing; when the task died, this is
              # already false. The caller is never killed from here.
              if Process.alive?(task), do: Process.exit(task, :kill)
            end
        end
      end)

    # Return only once the monitors exist. `Process.monitor/1` on a process
    # that has already gone reports :noproc, which reads here as an abnormal
    # death, so a watcher that armed late would reap a build whose task had
    # merely finished.
    receive do
      {:watching, ^watcher} -> :ok
    after
      1_000 -> :ok
    end

    watcher
  end

  defp get_task_os_pid(task) do
    case Process.info(task.pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :builder_os_pid)
      _ -> nil
    end
  end

  # Allowlist the environment exposed to build scripts; exclude server secrets.
  @build_env_allowlist ~w(
    PATH HOME LANG LC_ALL LC_CTYPE TMPDIR TERM
    CARGO_HOME RUSTUP_HOME CARGO_TARGET_DIR
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
  )

  defp scrubbed_build_env do
    # A port's :env option MODIFIES the inherited environment rather than
    # replacing it, so the scrub is spelled as explicit removals.
    for {key, _} <- System.get_env(), key not in @build_env_allowlist do
      {String.to_charlist(key), false}
    end
  end

  @doc false
  # Public alongside `watch_for_orphans/3`, so a test can tell a cleanup
  # that does not work from a watcher that never called it.
  def kill_os_process(nil), do: {:killed, []}

  def kill_os_process(os_pid) do
    # Under `setsid --wait` the new session belongs to setsid's child, not
    # to setsid, so the group to kill is the child's — reached through it
    # rather than through os_pid. Killing setsid alone would leave the
    # toolchain running.
    for child <- child_pids(os_pid) do
      System.cmd("kill", ["-9", "-#{child}"], stderr_to_stdout: true)
    end

    # Then the direct child. Without setsid (a macOS dev host) there is no
    # separate group and this is the only kill there is; the group attempt
    # is ESRCH and falls through. Any other failure means a toolchain tree
    # may have leaked, and that must not be silent — this is the one
    # zombie-process risk in the tree.
    case System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} = group ->
        {:killed, group: group}

      {out, code} ->
        {direct_out, direct_code} =
          System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)

        already_gone? =
          out =~ "No such process" and
            (direct_code == 0 or direct_out =~ "No such process")

        unless already_gone? or direct_code == 0 do
          Logger.warning(
            "[Locus.Builder] process-group kill of #{os_pid} exited #{code} " <>
              "(#{String.trim(out)}) and direct kill exited #{direct_code} " <>
              "(#{String.trim(direct_out)}) — a build toolchain process may have leaked"
          )
        end

        {:killed, group: {out, code}, direct: {direct_out, direct_code}}
    end
  rescue
    e ->
      Logger.warning("[Locus.Builder] Failed to kill OS process #{os_pid}: #{inspect(e)}")
      {:error, Exception.message(e)}
  end

  # setsid's own child, the process that leads the build's session. `pgrep`
  # is absent on some minimal images, and a build that cannot be enumerated
  # is still killed directly below.
  defp child_pids(os_pid) do
    case System.cmd("pgrep", ["-P", "#{os_pid}"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ ~r/^\d+$/))
      _ -> []
    end
  rescue
    _ -> []
  end

  # Compiler chatter kept for the error report is bounded; past the cap
  # the tail is dropped (the progress stream already delivered every line)
  # so a runaway build cannot balloon this process's heap.
  @max_port_output_bytes 2_000_000

  @doc false
  # Exposed so Locus.BuilderService bounds its replay log with the same
  # budget this module bounds its retained output with.
  def max_port_output_bytes, do: @max_port_output_bytes

  defp collect_port_output(port, acc, on_progress),
    do: collect_port_output(port, acc, 0, on_progress)

  defp collect_port_output(port, acc, acc_bytes, on_progress) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.each(&on_progress.(:output, &1))

        if acc_bytes < @max_port_output_bytes do
          collect_port_output(port, [data | acc], acc_bytes + byte_size(data), on_progress)
        else
          collect_port_output(port, acc, acc_bytes, on_progress)
        end

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> Enum.reverse() |> Enum.join()}
    after
      # The Task.yield deadline outside is the real bound; this is the
      # belt for a port that dies without ever sending an exit_status.
      :timer.minutes(15) ->
        {:ok, -1, acc |> Enum.reverse() |> Enum.join()}
    end
  end
end
