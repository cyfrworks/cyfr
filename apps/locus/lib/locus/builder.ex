# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Builder do
  @moduledoc """
  Compiles a component from its sources: Rust to a WASM component with
  `cargo-component`, a tincture's JavaScript to a static bundle with npm
  and Vite.

  ## arca:bypass-ok=D — entire module

  Sources arrive as a map and reach the build only inside its input
  archive; the one filesystem read is the check that the configured Cargo
  seed exists.

  ## How a build runs

  A build is one POSIX shell script run by an executor
  (`Locus.Executor.executor/0`). Its sources — with the generated
  `Cargo.toml` and the host's WIT files for a Rust component — reach it as
  a tar archive on stdin, extracted into `$HOME/src`. The toolchain runs
  there with `CARGO_HOME` and the npm cache under `$HOME`, writing to
  stderr, which is the build log. Its products leave as a ustar archive
  (names of at most 255 bytes, no extended headers) on stdout: the
  component and the `Cargo.lock` it used, or a tincture's
  `dist/`. That archive is untrusted: only its regular files are read, each
  name must be a safe relative path, and its files and bytes are bounded.

  Where cyfr-spawn runs this node (the builder image), each build runs
  under a pooled uid of its own (`Locus.Spawner`): a 0700 home neither
  another build nor this node's user can enter, an environment built from
  nothing, resource limits, and at its end every process of the uid killed
  and everything it left removed before the uid serves another build.
  Without cyfr-spawn a build runs as this node's user
  (`Locus.DirectLauncher`), which isolates nothing.

  ## What a build sees

  - the executor's `HOME`, `TMPDIR`, `USER`, `LOGNAME` and `PATH`, and of
    this node's environment only the toolchain settings `RUSTUP_HOME`,
    `LANG`, `LC_ALL`, `LC_CTYPE` and the proxy variables
  - the Cargo seed (`:build_cargo_seed`): a read-only Cargo home whose
    registry cache is copied into the build's own
  - the network: crates.io and the npm registry are how builds resolve
    dependencies

  A Rust build carrying a `Cargo.lock` builds `--locked` to it. npm runs
  with `--ignore-scripts`, so a dependency's lifecycle script never
  executes. Sources are bounded and held to `Cyfr.PathSafety` before a
  build starts, and the compiled WASM is validated
  (`Compendium.WasmValidator`) before it is returned; it executes only
  inside the Opus sandbox.

  ## Usage

      {:ok, result} = Locus.Builder.compile(%{"src/lib.rs" => source}, :rust, target_type: :reagent)
      # => {:ok, %{wasm_bytes: <<...>>, digest: "sha256:...", size: 1234,
      #           exports: [...], language: "rust", target_type: "reagent",
      #           lockfile: "..."}}

      {:ok, result} = Locus.Builder.compile(%{"package.json" => pkg}, :javascript, target_type: :tincture)
      # => {:ok, %{output_files: %{"index.html" => ..., "assets/..." => ...},
      #           digest: "sha256:...", size: 5678, exports: [],
      #           language: "javascript", target_type: "tincture"}}
  """

  require Logger

  @max_source_size 1_024 * 1_024
  # 30 s under the MCP tool layer's five-minute brutal kill, so a build that
  # exhausts its budget ends here as {:error, :compilation_timeout} with its
  # slot released. The margin covers the work outside the build: collecting
  # sources from Arca, validating the WASM and storing the artifact.
  @default_timeout_ms 270_000

  @max_output_files 500
  # The shared 64 MiB ceiling, the same bound the base64 ingress uses.
  @max_output_bytes Cyfr.Limits.default_max_memory_bytes()
  # The output archive adds headers, padding and a Cargo.lock to its files.
  @max_output_archive_bytes @max_output_bytes + 4 * 1024 * 1024

  # The toolchain settings a build takes from this node's environment.
  @toolchain_env ~w(RUSTUP_HOME LANG LC_ALL LC_CTYPE HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

  # $1 the component's file name, $2 the Cargo seed ("" for none), $3
  # "--locked" or "".
  @rust_script """
  set -eu
  wasm=$1 seed=$2 locked=$3
  export CARGO_HOME="$HOME/cargo" npm_config_cache="$HOME/npm"
  mkdir -p "$HOME/src" "$CARGO_HOME"
  cd "$HOME/src"
  tar -xf -
  if [ -n "$seed" ]; then cp -R "$seed/registry" "$CARGO_HOME/"; fi
  cargo component build --release --target wasm32-wasip2 $locked </dev/null >&2
  out=target/wasm32-wasip2/release
  set --
  if [ -f "$out/$wasm" ]; then set -- -C "$out" "$wasm"; fi
  if [ -f Cargo.lock ]; then set -- "$@" -C "$HOME/src" Cargo.lock; fi
  if [ "$#" -gt 0 ]; then exec tar --format=ustar -cf - "$@"; fi
  """

  @javascript_script """
  set -eu
  export CARGO_HOME="$HOME/cargo" npm_config_cache="$HOME/npm"
  mkdir -p "$HOME/src"
  cd "$HOME/src"
  tar -xf -
  npm install --no-audit --no-fund --ignore-scripts </dev/null >&2
  npm run build </dev/null >&2
  if [ -d dist ]; then exec tar --format=ustar -cf - dist; fi
  """

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
    - `:timeout_ms` - The build's deadline, in milliseconds. Defaults to
      `:cyfr, :build_timeout_ms` (`CYFR_BUILD_TIMEOUT_MS`), or else
      `#{@default_timeout_ms}`, 30 s under the MCP tool layer's five-minute
      brutal kill, so an over-budget build ends here as
      `{:error, :compilation_timeout}` with its slot released rather than
      losing the race to the caller's kill. Past it every process the build
      started is killed.
    - `:on_progress` - `fun(phase, message)`, called as the build proceeds
      and with each log line as `(:output, line)`
    - `:resolve` - Rust only. `true` resolves the crate graph afresh,
      ignoring a `"Cargo.lock"` among the sources. Otherwise a build that
      carries a `"Cargo.lock"` builds `--locked` to it — a dependency the
      lock does not cover fails with cargo's own message — and a build
      that carries none resolves one.

  ## Returns

  For `:rust`: `{:ok, %{wasm_bytes, digest, size, exports, language, target_type, lockfile}}`,
  where `lockfile` is the `Cargo.lock` the build used, or nil when it left none.
  For `:javascript`: `{:ok, %{output_files, digest, size, exports, language, target_type}}`.
  On failure: `{:error, reason}`, among them `{:compilation_failed, exit, log}`,
  `{:output_not_found, log}`, `:compilation_timeout` and `:builder_at_capacity`.
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
      settings = %{
        timeout_ms:
          Keyword.get_lazy(opts, :timeout_ms, fn ->
            Application.get_env(:cyfr, :build_timeout_ms, @default_timeout_ms)
          end),
        on_progress: Keyword.get(opts, :on_progress, fn _phase, _message -> :ok end),
        resolve?: Keyword.get(opts, :resolve, false) == true
      }

      settings.on_progress.(:preparing, "Preparing source files...")

      case do_compile(source_files, language, target_type, settings) do
        {:ok, _result} = ok ->
          ok

        error ->
          settings.on_progress.(:error, "Build failed")
          error
      end
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

  @doc """
  Return the Cargo.toml content for a given component type.

  Delegates to `Cyfr.CargoToml.template/2` — the canonical
  template — omitting the `cyfr:oauth` WIT dep from the GENERATED
  Cargo.toml. The build still receives the full catalyst WIT tree
  (`wit_files/2` includes everything `Compendium.WITSource.files/1`
  returns, oauth included — the world imports it, so the files must
  exist); what this omission controls is only which packages the
  generated manifest binds. A user project that uses oauth carries its
  own Cargo.toml, which `merge_cargo_toml/1` treats as authoritative for
  WIT deps.
  """
  def cargo_toml_for(type) do
    Cyfr.CargoToml.template(type, include_oauth_wit: false)
  end

  # ============================================================================
  # Source validation
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
    if Map.has_key?(source_files, "src/lib.rs"),
      do: validate_source_size(source_files),
      else: {:error, :missing_lib_rs}
  end

  defp validate_source_files(source_files, :javascript) do
    if Map.has_key?(source_files, "package.json"),
      do: validate_source_size(source_files),
      else: {:error, :missing_package_json}
  end

  defp validate_source_files(source_files, _language), do: validate_source_size(source_files)

  defp validate_source_size(source_files) do
    total_size = source_files |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))

    if total_size > @max_source_size do
      {:error, {:source_too_large, total_size, @max_source_size}}
    else
      validate_source_paths(source_files)
    end
  end

  # Every key becomes a name in the input archive, extracted under the
  # build's source directory, so each is held to PathSafety's relative-path
  # rules before any build starts.
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
    if toolchain_available?(language),
      do: :ok,
      else: {:error, {:toolchain_not_found, language}}
  end

  # ============================================================================
  # Compilation
  # ============================================================================

  defp do_compile(source_files, :rust, target_type, settings) do
    sources = if settings.resolve?, do: Map.delete(source_files, "Cargo.lock"), else: source_files

    cargo_toml =
      case Map.get(sources, "Cargo.toml") do
        nil -> cargo_toml_for(target_type)
        user_cargo -> merge_cargo_toml(user_cargo)
      end

    wasm = crate_name(cargo_toml) <> ".wasm"
    locked = if Map.has_key?(sources, "Cargo.lock"), do: "--locked", else: ""

    with {:ok, wit} <- wit_files(sources, target_type),
         {:ok, seed} <- cargo_seed(),
         {:ok, archive} <-
           Locus.Archive.pack(sources |> Map.put("Cargo.toml", cargo_toml) |> Map.merge(wit)),
         _ = settings.on_progress.(:compiling, "Compiling #{target_type} (rust)..."),
         {:ok, files, log} <- run_build(@rust_script, [wasm, seed, locked], archive, settings),
         {:ok, wasm_bytes} <- component(files, wasm, log),
         _ = settings.on_progress.(:validating, "Validating WASM binary..."),
         {:ok, validation} <- Compendium.WasmValidator.validate(wasm_bytes) do
      settings.on_progress.(
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
         target_type: to_string(target_type),
         lockfile: Map.get(files, "Cargo.lock")
       }}
    end
  end

  defp do_compile(source_files, :javascript, target_type, settings) do
    with {:ok, archive} <- Locus.Archive.pack(source_files),
         _ =
           settings.on_progress.(
             :compiling,
             "Building tincture (npm install && npm run build)..."
           ),
         {:ok, files, _log} <- run_build(@javascript_script, [], archive, settings),
         {:ok, output_files} <- dist_files(files) do
      {digest, size} = Cyfr.Digest.file_set(output_files)

      settings.on_progress.(
        :complete,
        "Build complete — #{size} bytes, #{map_size(output_files)} file(s)"
      )

      {:ok,
       %{
         output_files: output_files,
         digest: digest,
         size: size,
         exports: [],
         language: "javascript",
         target_type: to_string(target_type)
       }}
    end
  end

  # Runs a build script and reads its output archive. A build that exits
  # non-zero fails with its log.
  defp run_build(script, args, archive, settings) do
    command = %{
      argv: ["/bin/sh", "-c", script, "locus-build" | args],
      env: toolchain_env(),
      stdin: archive
    }

    opts = [
      timeout_ms: settings.timeout_ms,
      max_stdout_bytes: @max_output_archive_bytes,
      on_output: &settings.on_progress.(:output, &1)
    ]

    case Locus.Executor.executor().run(command, opts) do
      {:ok, %{exit: {:status, 0}, stdout: stdout, log: log}} ->
        output_archive(stdout, String.trim(log))

      {:ok, %{exit: {:status, code}, log: log}} ->
        {:error, {:compilation_failed, code, String.trim(log)}}

      {:ok, %{exit: {:signal, signal}, log: log}} ->
        {:error, {:compilation_failed, signal, String.trim(log)}}

      {:error, :timeout} ->
        {:error, :compilation_timeout}

      {:error, :capacity} ->
        {:error, :builder_at_capacity}

      {:error, {:output_too_large, max}} ->
        {:error, {:compilation_failed, 0, "Build output exceeds #{max} bytes"}}

      {:error, {:spawn_failed, reason}} ->
        Logger.error("[Locus.Builder] a build could not be run: #{inspect(reason)}")
        {:error, {:build_not_started, reason}}
    end
  end

  defp output_archive(stdout, log) do
    case Locus.Archive.unpack(stdout, @max_output_files) do
      {:ok, files, skipped} ->
        if skipped != [],
          do:
            Logger.warning(
              "[Locus.Builder] skipped #{length(skipped)} non-regular entries in build output"
            )

        {:ok, files, log}

      {:error, {:too_many_files, max}} ->
        {:error, {:compilation_failed, 0, "Build produced more than #{max} files"}}

      {:error, reason} ->
        {:error, {:compilation_failed, 0, "Build output is unreadable: #{inspect(reason)}"}}
    end
  end

  defp toolchain_env do
    env =
      for name <- @toolchain_env,
          value = System.get_env(name),
          value not in [nil, ""],
          into: %{},
          do: {name, value}

    # A build's HOME is its own, so rustup's default location under HOME is
    # stated explicitly.
    Map.put_new_lazy(env, "RUSTUP_HOME", fn -> Path.join(System.user_home() || "/", ".rustup") end)
  end

  # The command believed it succeeded and left no component; its log is the
  # only evidence of why.
  defp component(files, wasm, log) do
    case Map.fetch(files, wasm) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        Logger.error(
          "[Locus.Builder] cargo exited 0 without producing #{wasm}; its output was:\n#{log}"
        )

        {:error, {:output_not_found, log}}
    end
  end

  defp dist_files(files) do
    output =
      for {"dist/" <> rel, content} <- files, rel != "", into: %{}, do: {rel, content}

    cond do
      map_size(output) == 0 ->
        {:error, {:compilation_failed, 0, "Build produced no output files in dist/"}}

      output |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2)) > @max_output_bytes ->
        {:error,
         {:compilation_failed, 0, "Build output exceeds #{@max_output_bytes} bytes in dist/"}}

      true ->
        {:ok, output}
    end
  end

  # The crates baked into the builder image (`:build_cargo_seed`, a Cargo
  # home holding a registry cache): the build copies its registry into its
  # own Cargo home, so it starts with them without sharing a cache another
  # build could write. A seed that is configured and absent is a broken
  # image.
  defp cargo_seed do
    case Application.get_env(:cyfr, :build_cargo_seed) do
      seed when is_binary(seed) and seed != "" ->
        registry = Path.join(seed, "registry")
        if File.dir?(registry), do: {:ok, seed}, else: {:error, {:cargo_seed_missing, registry}}

      _ ->
        {:ok, ""}
    end
  end

  # Merge user Cargo.toml with the template.
  # The user's Cargo.toml is authoritative for [package.metadata.component.target.dependencies]
  # (WIT deps) since it must match the actual WIT files present. We use the user's file as the
  # base and only ensure required crate dependencies (wit-bindgen-rt) are present.
  defp merge_cargo_toml(user_cargo), do: ensure_required_deps(user_cargo)

  @required_deps %{
    "wit-bindgen-rt" => ~s(wit-bindgen-rt = "0.25")
  }

  defp ensure_required_deps(cargo_toml) do
    Enum.reduce(@required_deps, cargo_toml, fn {dep_name, dep_line}, acc ->
      if String.contains?(acc, dep_name) do
        acc
      else
        String.replace(acc, "[dependencies]\n", "[dependencies]\n#{dep_line}\n", global: false)
      end
    end)
  end

  # Cargo names the component after the crate, with hyphens as underscores.
  defp crate_name(cargo_toml) do
    case Regex.run(~r/^\s*name\s*=\s*"([^"]+)"/m, cargo_toml) do
      [_, name] -> String.replace(name, "-", "_")
      _ -> "cyfr_component"
    end
  end

  # The WIT definitions are the host ABI, release-embedded
  # (`Compendium.WITSource`): a build compiles against exactly what the
  # running host implements. Sources that carry their own `wit/` use it.
  defp wit_files(sources, target_type) do
    if Enum.any?(Map.keys(sources), &String.starts_with?(&1, "wit/")) do
      {:ok, %{}}
    else
      case Compendium.WITSource.files(target_type) do
        [] ->
          {:error, {:wit_not_found, target_type}}

        files ->
          {:ok,
           Map.new(files, fn {segments, content} -> {Path.join(["wit" | segments]), content} end)}
      end
    end
  end
end
