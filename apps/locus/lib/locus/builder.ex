# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Builder do
  @moduledoc """
  Builds a component from its sources: Rust to a WASM component with
  `cargo-component`, a tincture's JavaScript to a static bundle with npm
  and Vite. It takes a build request as the build wire reads it
  (`Prima.BuilderProtocol`) and answers output files, or the wire's refusal
  for why there are none.

  ## arca:bypass-ok=D — entire module

  Sources arrive as a map and reach the build only inside its input
  archive; the one filesystem read is the check that the configured Cargo
  seed exists.

  ## How a build runs

  `prepare/1` checks the request and packs it, running nothing: the
  sources a language needs, their total size and every path
  (`Prima.PathSafety`), the toolchain, an executor to run under, the Cargo
  seed. `run/2` runs what it prepared.

  A build is one POSIX shell script run by an executor
  (`Locus.Executor.executor/0`). Its sources — with the generated
  `Cargo.toml` and the host's WIT files for a Rust component — reach it as
  a tar archive on stdin, extracted into `$HOME/src`. The toolchain runs
  there with `CARGO_HOME` and the npm cache under `$HOME`, writing to
  stderr, which is the build log. Its products leave as a ustar archive
  (names of at most 255 bytes, no extended headers) on stdout: the
  component and the `Cargo.lock` it used, or a tincture's
  `dist/`. That archive is untrusted: only its regular files are read, each
  name must be a safe relative path, and its files and bytes are held to
  the wire's output bounds; output past a bound is refused as `failed`,
  never truncated.

  Each build runs through cyfr-spawn under a pooled uid of its own
  (`Locus.Spawner`): a 0700 home neither another build nor this node's user
  can enter, an environment built from nothing, resource limits, a memory
  bound, and at its end every process of the uid killed and everything it
  left removed before the uid serves another build. A node without
  cyfr-spawn builds nothing, the test environment excepted
  (`Locus.Executor`).

  ## What a build sees

  - the executor's `HOME`, `TMPDIR`, `USER`, `LOGNAME` and `PATH`, and of
    this node's environment only the toolchain settings `RUSTUP_HOME`,
    `LANG`, `LC_ALL`, `LC_CTYPE` and the proxy variables
  - the Cargo seed (`Locus.Config.cargo_seed/0`): a read-only Cargo home
    whose registry cache is copied into the build's own
  - the network: crates.io and the npm registry are how builds resolve
    dependencies

  A Rust build carrying a `Cargo.lock` builds `--locked` to it — a
  dependency the lock does not cover fails with cargo's own message — and
  one carrying none, or asked to `resolve`, resolves one. npm runs with
  `--ignore-scripts`, so a dependency's lifecycle script never executes.
  The compiled WASM is validated (`Prima.Wasm`) before it is
  answered; it executes only inside the Opus sandbox.

  ## What a build answers

  `{:ok, %{language, target_type, outputs}}`, where a component's outputs
  are `Prima.BuilderProtocol.component_wasm/0` and, when the build left
  one, `component_lockfile/0`, and a tincture's are the files of its
  `dist/`; or `{:error, refusal}`, a `t:Prima.BuilderProtocol.refusal/0`:

  | Refusal | When |
  |---|---|
  | `malformed` | the sources do not make a build of that language |
  | `unavailable` | the toolchain, the Cargo seed or cyfr-spawn is missing, or cyfr-spawn cannot bound the build's memory |
  | `capacity` | no pooled uid is free |
  | `timeout` | the build passed `:timeout_ms` and was ended |
  | `memory` | the build reached its memory bound and was ended there |
  | `failed` | the build exited non-zero or by a signal, or its output was refused |

  Why an output was refused is said on the progress callback before the
  refusal is answered, so it is among the answer's diagnostics.
  """

  require Logger

  alias Prima.BuilderProtocol

  # The output archive adds headers, padding and a Cargo.lock to its files.
  @max_output_archive_bytes BuilderProtocol.max_output_bytes() + 4 * 1024 * 1024

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

  @typedoc "What a build is asked for: the fields of a wire request the builder builds from."
  @type request :: %{
          required(:language) => BuilderProtocol.language(),
          required(:target_type) => BuilderProtocol.target_type(),
          required(:resolve) => boolean(),
          required(:sources) => %{String.t() => binary()},
          optional(atom()) => term()
        }

  @typedoc "A checked and packed build, ready to run."
  @opaque plan :: %{
            language: BuilderProtocol.language(),
            target_type: BuilderProtocol.target_type(),
            argv: [String.t(), ...],
            archive: binary(),
            wasm: String.t() | nil,
            announce: String.t()
          }

  @typedoc "A finished build: its output files by path."
  @type built :: %{
          language: BuilderProtocol.language(),
          target_type: BuilderProtocol.target_type(),
          outputs: %{String.t() => binary()}
        }

  @typedoc "Called with each stage the build enters and each line of its log (`:output`)."
  @type on_progress :: (BuilderProtocol.stage(), String.t() -> any())

  @doc """
  Check `request` and pack it, running nothing: `{:ok, plan}` for `run/2`,
  or the refusal a request that cannot be built is answered with.
  """
  @spec prepare(request()) :: {:ok, plan()} | {:error, BuilderProtocol.refusal()}
  def prepare(%{language: language, target_type: target_type, resolve: resolve, sources: sources})
      when is_atom(language) and is_atom(target_type) and is_boolean(resolve) and is_map(sources) do
    with :ok <- paired(language, target_type),
         :ok <- validate_sources(sources, language),
         :ok <- check_toolchain(language),
         {:ok, _executor} <- executor() do
      plan(language, target_type, resolve, sources)
    end
  end

  @doc """
  Run a prepared build.

  ## Options

  - `:timeout_ms` — the build's budget, `Locus.Config.timeout_ms/0` unless
    given. Past it every process the build started is killed and the
    answer is the `timeout` refusal naming it.
  - `:on_progress` — a `t:on_progress/0`.

  `{:error, :cancelled}` answers a run ended by `Locus.Executor.cancel/1`.
  """
  @spec run(plan(), timeout_ms: pos_integer(), on_progress: on_progress()) ::
          {:ok, built()} | {:error, BuilderProtocol.refusal() | :cancelled}
  def run(%{language: language, target_type: target_type} = plan, opts \\ []) do
    timeout_ms = Keyword.get_lazy(opts, :timeout_ms, &Locus.Config.timeout_ms/0)
    on_progress = Keyword.get(opts, :on_progress, fn _stage, _message -> :ok end)

    on_progress.(:preparing, "Preparing source files...")

    with {:ok, executor} <- executor(),
         _ = on_progress.(:compiling, plan.announce),
         {:ok, files} <- execute(executor, plan, timeout_ms, on_progress),
         {:ok, outputs} <- outputs(plan, files, on_progress),
         :ok <- within_bounds(outputs, on_progress) do
      {:ok, %{language: language, target_type: target_type, outputs: outputs}}
    end
  end

  @doc "`prepare/1`, then `run/2`."
  @spec build(request(), timeout_ms: pos_integer(), on_progress: on_progress()) ::
          {:ok, built()} | {:error, BuilderProtocol.refusal() | :cancelled}
  def build(request, opts \\ []) do
    with {:ok, plan} <- prepare(request), do: run(plan, opts)
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

  @doc "What each toolchain of the wire's languages reports on a health answer."
  @spec available_toolchains() :: %{BuilderProtocol.language() => BuilderProtocol.toolchain()}
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

  Delegates to `Prima.CargoToml.template/2` — the canonical
  template — omitting the `cyfr:oauth` WIT dep from the GENERATED
  Cargo.toml. The build still receives the full catalyst WIT tree
  (`wit_files/2` includes everything `Prima.WIT.files/1`
  returns, oauth included — the world imports it, so the files must
  exist); what this omission controls is only which packages the
  generated manifest binds. A user project that uses oauth carries its
  own Cargo.toml, which `merge_cargo_toml/1` treats as authoritative for
  WIT deps.
  """
  def cargo_toml_for(type) do
    Prima.CargoToml.template(type, include_oauth_wit: false)
  end

  # ============================================================================
  # The request
  # ============================================================================

  # A language this builder does not speak is the toolchain check's to refuse.
  defp paired(language, target_type) do
    expected =
      if target_type in [:reagent, :catalyst, :formula, :tincture],
        do: BuilderProtocol.language_for(target_type)

    if language in BuilderProtocol.languages() and expected != language,
      do: malformed({:unpaired, language, target_type}),
      else: :ok
  end

  defp validate_sources(sources, _language) when sources == %{},
    do: {:error, {:malformed, "sources name no files"}}

  defp validate_sources(sources, language) do
    with :ok <- required_source(sources, language),
         :ok <- validate_source_size(sources) do
      validate_source_paths(sources)
    end
  end

  defp required_source(sources, :rust) when not is_map_key(sources, "src/lib.rs"),
    do: {:error, {:malformed, "a rust build needs src/lib.rs among its sources"}}

  defp required_source(sources, :javascript) when not is_map_key(sources, "package.json"),
    do: {:error, {:malformed, "a javascript build needs package.json among its sources"}}

  defp required_source(_sources, _language), do: :ok

  defp validate_source_size(sources) do
    total = sources |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))
    max = BuilderProtocol.max_source_bytes()
    if total > max, do: malformed({:too_large, :sources, total, max}), else: :ok
  end

  # Every key becomes a name in the input archive, extracted under the
  # build's source directory, so each is held to PathSafety's relative-path
  # rules before any build starts, whatever read the request.
  defp validate_source_paths(sources) do
    sources
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Prima.PathSafety.validate_relative_path(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, malformed({:unsafe_path, path})}
      end
    end)
  end

  defp malformed(read_error), do: {:error, {:malformed, BuilderProtocol.describe(read_error)}}

  defp check_toolchain(language) do
    if toolchain_available?(language),
      do: :ok,
      else: {:error, {:unavailable, "the #{language} toolchain is not installed in this image"}}
  end

  defp executor do
    case Locus.Executor.executor() do
      {:ok, executor} ->
        {:ok, executor}

      {:error, :no_keeper} ->
        {:error,
         {:unavailable, "cyfr-spawn is not running, and the builder runs a build only under it"}}
    end
  end

  # ============================================================================
  # The plan
  # ============================================================================

  defp plan(:rust, target_type, resolve?, sources) do
    sources = if resolve?, do: Map.delete(sources, "Cargo.lock"), else: sources

    cargo_toml =
      case Map.get(sources, "Cargo.toml") do
        nil -> cargo_toml_for(target_type)
        user_cargo -> merge_cargo_toml(user_cargo)
      end

    wasm = crate_name(cargo_toml) <> ".wasm"
    locked = if Map.has_key?(sources, "Cargo.lock"), do: "--locked", else: ""

    with {:ok, wit} <- wit_files(sources, target_type),
         {:ok, seed} <- cargo_seed(),
         {:ok, archive} <- pack(sources |> Map.put("Cargo.toml", cargo_toml) |> Map.merge(wit)) do
      {:ok,
       %{
         language: :rust,
         target_type: target_type,
         argv: ["/bin/sh", "-c", @rust_script, "locus-build", wasm, seed, locked],
         archive: archive,
         wasm: wasm,
         announce: "Compiling #{target_type} (rust)..."
       }}
    end
  end

  defp plan(:javascript, target_type, _resolve?, sources) do
    with {:ok, archive} <- pack(sources) do
      {:ok,
       %{
         language: :javascript,
         target_type: target_type,
         argv: ["/bin/sh", "-c", @javascript_script, "locus-build"],
         archive: archive,
         wasm: nil,
         announce: "Building tincture (npm install && npm run build)..."
       }}
    end
  end

  defp pack(files) do
    case Locus.Archive.pack(files) do
      {:ok, archive} ->
        {:ok, archive}

      {:error, {:pack_failed, path, _reason}} ->
        {:error, {:malformed, "#{path} cannot be a file of the build's source archive"}}

      {:error, _reason} ->
        {:error, {:malformed, "the sources do not make a source archive"}}
    end
  end

  # ============================================================================
  # The run
  # ============================================================================

  # Runs the build's script and reads its output archive.
  defp execute(executor, plan, timeout_ms, on_progress) do
    command = %{argv: plan.argv, env: toolchain_env(), stdin: plan.archive}

    opts = [
      timeout_ms: timeout_ms,
      max_stdout_bytes: @max_output_archive_bytes,
      on_output: &on_progress.(:output, &1)
    ]

    case executor.run(command, opts) do
      {:ok, %{exit: {:status, 0}, stdout: stdout}} ->
        output_archive(stdout, on_progress)

      {:ok, %{exit: exit}} ->
        {:error, {:failed, exit}}

      {:error, :timeout} ->
        {:error, {:timeout, timeout_ms}}

      {:error, :cancelled} ->
        {:error, :cancelled}

      {:error, :capacity} ->
        {:error, {:capacity, Locus.Config.max_concurrent()}}

      # The spawner's own reading of the wire: a build ended at its bound,
      # and a bound this deployment cannot enforce.
      {:error, {:memory, _limit_bytes} = refusal} ->
        {:error, refusal}

      {:error, {:unavailable, _sentence} = refusal} ->
        {:error, refusal}

      # The executor ended the build where its stdout passed the bound.
      {:error, {:output_too_large, max}} ->
        on_progress.(:compiling, "the build's output passed #{max} bytes and was refused")
        {:error, {:failed, {:signal, "SIGKILL"}}}

      {:error, {:spawn_failed, reason}} ->
        Logger.error("[Locus.Builder] a build could not be run: #{inspect(reason)}")
        {:error, {:unavailable, "cyfr-spawn could not run the build (#{spawn_failure(reason)})"}}
    end
  end

  defp spawn_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp spawn_failure(reason) when is_binary(reason), do: reason
  defp spawn_failure({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp spawn_failure(_reason), do: "spawn_failed"

  defp output_archive(stdout, on_progress) do
    case Locus.Archive.unpack(stdout, BuilderProtocol.max_output_files()) do
      {:ok, files, skipped} ->
        if skipped != [],
          do:
            Logger.warning(
              "[Locus.Builder] skipped #{length(skipped)} non-regular entries in build output"
            )

        {:ok, files}

      {:error, {:too_many_files, max}} ->
        refused_output(on_progress, :compiling, "the build produced more than #{max} files")

      {:error, {:unsafe_path, _name}} ->
        refused_output(on_progress, :compiling, "the build's output names an unsafe path")

      {:error, {:unreadable, _reason}} ->
        refused_output(on_progress, :compiling, "the build's output archive is unreadable")
    end
  end

  # The command believed it succeeded; what it left is not an output this
  # builder answers. The line is the only evidence of why.
  defp refused_output(on_progress, stage, message) do
    on_progress.(stage, message)
    {:error, {:failed, {:status, 0}}}
  end

  defp outputs(%{language: :rust, wasm: wasm}, files, on_progress) do
    with {:ok, wasm_bytes} <- component(files, wasm, on_progress),
         _ = on_progress.(:validating, "Validating WASM binary..."),
         :ok <- validate(wasm_bytes, on_progress) do
      outputs = %{BuilderProtocol.component_wasm() => wasm_bytes}

      {:ok,
       case Map.fetch(files, "Cargo.lock") do
         {:ok, lockfile} -> Map.put(outputs, BuilderProtocol.component_lockfile(), lockfile)
         :error -> outputs
       end}
    end
  end

  defp outputs(%{language: :javascript}, files, on_progress) do
    outputs = for {"dist/" <> rel, content} <- files, rel != "", into: %{}, do: {rel, content}

    if map_size(outputs) == 0,
      do: refused_output(on_progress, :compiling, "the build produced no output files in dist/"),
      else: {:ok, outputs}
  end

  defp component(files, wasm, on_progress) do
    case Map.fetch(files, wasm) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        refused_output(on_progress, :compiling, "cargo exited 0 without producing #{wasm}")
    end
  end

  defp validate(wasm_bytes, on_progress) do
    case Prima.Wasm.validate(wasm_bytes) do
      {:ok, _validation} ->
        :ok

      {:error, reason} ->
        refused_output(
          on_progress,
          :validating,
          "the component is not valid WASM (#{validation_failure(reason)})"
        )
    end
  end

  defp validation_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp validation_failure(reason) when is_tuple(reason), do: inspect(elem(reason, 0))

  defp within_bounds(outputs, on_progress) do
    total = outputs |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))
    max = BuilderProtocol.max_output_bytes()

    if total > max,
      do:
        refused_output(
          on_progress,
          :validating,
          "the build's outputs total #{total} bytes; at most #{max} are answered"
        ),
      else: :ok
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

  # The crates baked into the builder image (a Cargo home holding a
  # registry cache): the build copies its registry into its own Cargo home,
  # so it starts with them without sharing a cache another build could
  # write. A seed that is configured and absent is a broken image.
  defp cargo_seed do
    case Locus.Config.cargo_seed() do
      nil ->
        {:ok, ""}

      seed ->
        registry = Path.join(seed, "registry")

        if File.dir?(registry),
          do: {:ok, seed},
          else: {:error, {:unavailable, "the Cargo seed #{registry} is missing from this image"}}
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
  # (`Prima.WIT`): a build compiles against exactly what the
  # running host implements. Sources that carry their own `wit/` use it.
  defp wit_files(sources, target_type) do
    if Enum.any?(Map.keys(sources), &String.starts_with?(&1, "wit/")) do
      {:ok, %{}}
    else
      case Prima.WIT.files(target_type) do
        [] ->
          {:error, {:unavailable, "this release embeds no WIT for a #{target_type}"}}

        files ->
          {:ok,
           Map.new(files, fn {segments, content} -> {Path.join(["wit" | segments]), content} end)}
      end
    end
  end
end
