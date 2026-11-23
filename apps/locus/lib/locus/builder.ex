# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# arca:bypass-ok=D — entire module: sources arrive as a map and reach the
# build only inside its input archive; the one filesystem read is the check
# that the configured Cargo seed exists.
defmodule Locus.Builder do
  @moduledoc """
  Builds a component from its sources: Rust to a WASM component with
  `cargo-component`, a tincture's JavaScript to a static bundle with npm
  and Vite. It takes a build request as the build wire reads it
  (`Prima.BuilderProtocol`) and answers output files, or the wire's refusal
  for why there are none.

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
  `dist/`. That archive is untrusted and is read as it arrives
  (`Locus.Archive`), a relay frame at a time: only its regular files are
  read, each name must be a safe relative path, and its files and bytes
  are held to the wire's output bounds, each file's name, the count and
  the total checked from its header before any of its bytes leave. Each
  piece of an output file leaves at once as an output line
  (`Prima.BuilderProtocol.encode_output/3`), handed to `:on_line` and
  taken before the next piece is read, with the file's running digest
  kept; nothing of a file is held here, and a file of no bytes leaves no
  line, its result naming it alone. Output past a bound is refused as
  `failed` after whatever lines went before it, which the client then
  keeps nothing of, never truncated.

  Each build runs through cyfr-locus under a pooled uid of its own
  (`Locus.Keeper`): a 0700 home neither another build nor this node's user
  can enter, an environment built from nothing, resource limits, a memory
  bound, and at its end every process of the uid killed and everything it
  left removed before the uid serves another build. A node without
  cyfr-locus builds nothing, the test environment excepted
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
  one carrying none, or asked to `resolve`, resolves one. A tincture
  builds only from its lockfile: one without `package-lock.json` beside
  its `package.json` is refused as `malformed` before anything runs, and
  `npm ci` installs exactly what the lockfile pins, refusing one out of
  step with the package manifest. Install scripts run, as the build
  itself does: under the build's uid, in its home, with the environment
  above, which carries no credential — the builds key and anything else
  of this node's environment stay outside. The compiled WASM is the
  client's to validate (`Compendium.Builds.Client`) once a result names
  it; it executes only inside the runtime's sandbox.

  A tincture's bundle keeps the notices of what it ships:
  `dist/third-party-notices.json` lists every runtime package the
  lockfile installed, with its license and the text of its license and
  notice files, unless the build wrote that file itself.

  ## What a build answers

  `{:ok, %{language, target_type, outputs}}` once every output line was
  taken, where `outputs` names each file with its size and digest, in the
  order its archive held them (a component's are
  `Prima.BuilderProtocol.component_wasm/0` and, when the build left one,
  `component_lockfile/0`, a tincture's the files of its `dist/`); or
  `{:error, refusal}`, a `t:Prima.BuilderProtocol.refusal/0`:

  | Refusal | When |
  |---|---|
  | `malformed` | the sources do not make a build of that language |
  | `unavailable` | the toolchain, the Cargo seed or cyfr-locus is missing, or cyfr-locus cannot bound the build's memory |
  | `capacity` | no pooled uid is free |
  | `timeout` | the build passed its `:deadline` and was ended |
  | `memory` | the build was ended for memory: at its bound, at a limit above it, or at one of the two where the kernel does not say which |
  | `failed` | the build exited non-zero or by a signal, or its output was refused |

  Why an output was refused is said on the progress callback before the
  refusal is answered, so it is among the answer's diagnostics.
  """

  require Logger

  alias Prima.BuilderProtocol

  # The output archive adds headers, padding and a Cargo.lock to its files.
  @max_output_archive_bytes BuilderProtocol.max_output_bytes() + 4 * 1024 * 1024

  # What a build holds of its output at most, beside the plan it runs (see
  # `held_bytes/0`): a read of its relay and the frame it may end inside;
  # the log's line not yet ended; the progress lines one log line makes,
  # each piece's message escaped at most six times over; one output line,
  # a frame's bytes in base64 under the longest path escaped; what it keeps
  # of each file sent; and its result line.
  @frame_bytes Prima.KeeperProtocol.max_frame_bytes()
  @read_bytes 2 * (IO.iodata_length(Prima.KeeperProtocol.end_frame(:stdout)) + @frame_bytes)
  @envelope_bytes 256
  @progress_bytes 2 * (6 * BuilderProtocol.max_line_bytes() + @envelope_bytes)
  @output_line_bytes 4 * div(@frame_bytes + 2, 3) + 2 * BuilderProtocol.max_output_path_bytes() +
                       @envelope_bytes
  @sent_bytes BuilderProtocol.max_output_files() *
                (BuilderProtocol.max_output_path_bytes() + @envelope_bytes)
  @held_bytes @read_bytes + BuilderProtocol.max_line_bytes() + @progress_bytes +
                @output_line_bytes + @sent_bytes + BuilderProtocol.max_result_line_bytes()

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

  # $1 the notices script, $2 the notices file's name. `npm ci` installs exactly what the lockfile
  # pins, and refuses a lockfile out of step with package.json; install
  # scripts run, under the build's uid and its environment, which holds no
  # credential.
  @javascript_script """
  set -eu
  export CARGO_HOME="$HOME/cargo" npm_config_cache="$HOME/npm"
  mkdir -p "$HOME/src"
  cd "$HOME/src"
  tar -xf -
  npm ci --no-audit --no-fund --ignore-scripts=false </dev/null >&2
  npm run build </dev/null >&2
  if [ -d dist ]; then
    node -e "$1" "$2" </dev/null >&2
    exec tar --format=ustar -cf - dist
  fi
  """

  # The npm package manifest and the lockfile a tincture build installs
  # from (`Compendium.Tincture.Rules.lockfile/0` names the same file on the
  # control plane, which this island does not read).
  @package_manifest "package.json"
  @lockfile "package-lock.json"

  # The notices the bundle keeps: every package the lockfile installs for
  # runtime (not `dev`), its name, version, declared license and the text
  # of its license and notice files, into `dist/third-party-notices.json`.
  # A build that ships none writes nothing, and one whose own output
  # already carries the file keeps its own.
  @notices "third-party-notices.json"
  @notices_script ~S"""
  const fs = require("fs"), path = require("path");
  const target = path.join("dist", process.argv[1]);
  const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
  const out = [];
  for (const [dir, entry] of Object.entries(lock.packages || {})) {
    if (!dir.startsWith("node_modules/") || entry.dev || entry.link) continue;
    let names;
    try { names = fs.readdirSync(dir); } catch { continue; }
    const notices = names
      .filter((name) => /^(licen[cs]e|notice|copying)/i.test(name))
      .sort()
      .flatMap((name) => {
        const file = path.join(dir, name);
        const stat = fs.lstatSync(file);
        if (!stat.isFile() || stat.size > 65536) return [];
        return [{ file: name, text: fs.readFileSync(file, "utf8") }];
      });
    const name = entry.name || dir.slice(dir.lastIndexOf("node_modules/") + 13);
    out.push({ name, version: entry.version, license: entry.license || null, notices });
  }
  if (out.length > 0 && !fs.existsSync(target)) {
    fs.writeFileSync(target, JSON.stringify(out, null, 2) + "\n");
  }
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

  @typedoc "A finished build: its files by path, size and digest, as its archive held them."
  @type built :: BuilderProtocol.result()

  @typedoc """
  Called with each stage the build enters and each line of its log
  (`:output`); `{:error, reason}` is the taker's word that it takes no
  more, and ends the build.
  """
  @type on_progress :: (BuilderProtocol.stage(), String.t() -> Locus.Executor.taken())

  @typedoc "Called with each output line, the next only once it returned; `{:error, reason}` ends the build."
  @type on_line :: (binary() -> Locus.Executor.taken())

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
  The place a build of `request` runs in (`Locus.Executor`), made before it
  is prepared, for the calling process: a `build` of the request's
  athanor, under an id of its own. `{:error, refusal}` where no executor
  can make one.
  """
  @spec place(%{required(:athanor_id) => String.t(), optional(atom()) => term()}) ::
          {:ok, String.t()} | {:error, BuilderProtocol.refusal()}
  def place(%{athanor_id: athanor_id}) do
    place = "build-" <> Prima.Hex.short()

    with {:ok, executor} <- executor() do
      case executor.place(place, %{kind: "build", athanor: athanor_id}) do
        :ok ->
          {:ok, place}

        {:error, reason} ->
          Logger.error("[Locus.Builder] a build's place was not made: #{inspect(reason)}")

          {:error,
           {:unavailable, "cyfr-locus could not hold the build (#{spawn_failure(reason)})"}}
      end
    end
  end

  @doc "Free the place `place/1` made, unless the build's run named it."
  @spec drop(String.t()) :: :ok
  def drop(place) do
    case Locus.Executor.executor() do
      {:ok, executor} -> executor.drop(place)
      {:error, :no_keeper} -> :ok
    end
  end

  @doc """
  Run a prepared build in its place.

  ## Options

  - `:place` — the place `place/1` made for the build, which its run names.
  - `:budget_ms` — the build's budget, which its `timeout` refusal names:
    `Locus.Config.timeout_ms/0` unless given.
  - `:deadline` — the instant, in monotonic milliseconds, the build ends
    by, which its caller fixed once (the builds service as the request
    arrived), `:budget_ms` from the call unless given. Past it every
    process the build started is killed and the answer is the `timeout`
    refusal.
  - `:on_progress` — a `t:on_progress/0`.
  - `:on_line` — a `t:on_line/0`, handed each output line.

  `{:error, :cancelled}` answers a run ended by `Locus.Executor.cancel/1`,
  or by a taker that takes no more.
  """
  @spec run(plan(),
          place: String.t(),
          deadline: integer(),
          budget_ms: pos_integer(),
          on_progress: on_progress(),
          on_line: on_line()
        ) :: {:ok, built()} | {:error, BuilderProtocol.refusal() | :cancelled}
  def run(%{language: language, target_type: target_type} = plan, opts \\ []) do
    budget_ms = Keyword.get_lazy(opts, :budget_ms, &Locus.Config.timeout_ms/0)

    deadline =
      Keyword.get_lazy(opts, :deadline, fn -> System.monotonic_time(:millisecond) + budget_ms end)

    on_progress = Keyword.get(opts, :on_progress, fn _stage, _message -> :ok end)
    on_line = Keyword.get(opts, :on_line, fn _line -> :ok end)
    place = Keyword.fetch!(opts, :place)

    with :ok <- said(on_progress.(:preparing, "Preparing source files...")),
         {:ok, executor} <- executor(),
         :ok <- said(on_progress.(:compiling, plan.announce)),
         {:ok, stream} <-
           execute(executor, plan, place, {deadline, budget_ms}, on_progress, on_line),
         {:ok, outputs} <- outputs(plan, stream, on_progress) do
      {:ok, %{language: language, target_type: target_type, outputs: outputs}}
    end
  end

  # A taker that takes no more ends the build as a cancel does.
  defp said({:error, _reason}), do: {:error, :cancelled}
  defp said(_taken), do: :ok

  @doc """
  The most a build holds of its output while it runs and answers, which
  the builds role's count grants it whole (`Locus.Output`): a read of its
  relay and the frame it may end inside, the log's line not yet ended, the
  progress lines one log line makes, one output line, what it keeps of each
  file sent, and its result line. Nothing of a file is held.
  """
  @spec held_bytes() :: pos_integer()
  def held_bytes, do: @held_bytes

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

  defp required_source(sources, :javascript) when not is_map_key(sources, @package_manifest),
    do: {:error, {:malformed, "a javascript build needs #{@package_manifest} among its sources"}}

  # A tincture builds only from its lockfile: a build without one would
  # install whatever the registry answers on the day.
  defp required_source(sources, :javascript) when not is_map_key(sources, @lockfile),
    do:
      {:error,
       {:malformed,
        "a javascript build needs #{@lockfile} beside #{@package_manifest}: a tincture " <>
          "builds only from its lockfile"}}

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
         {:unavailable, "cyfr-locus is not running, and the builder runs a build only under it"}}
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
         argv: [
           "/bin/sh",
           "-c",
           @javascript_script,
           "locus-build",
           @notices_script,
           @notices
         ],
         archive: archive,
         wasm: nil,
         announce: "Building tincture (npm ci && npm run build)..."
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

  # Runs the build's script and reads its output archive as it arrives.
  defp execute(executor, plan, place, {deadline, budget_ms}, on_progress, on_line) do
    command = %{argv: plan.argv, env: toolchain_env(), stdin: plan.archive}

    opts = [
      place: place,
      deadline: deadline,
      max_stdout_bytes: @max_output_archive_bytes,
      on_stdout: {stream(plan, on_progress, on_line), &take/2},
      on_output: &on_progress.(:output, &1)
    ]

    case executor.run(command, opts) do
      {:ok, %{exit: {:status, 0}, taken: stream}} ->
        ended(stream, on_progress)

      {:ok, %{exit: exit}} ->
        {:error, {:failed, exit}}

      {:error, :timeout} ->
        {:error, {:timeout, budget_ms}}

      {:error, :cancelled} ->
        {:error, :cancelled}

      {:error, :capacity} ->
        {:error, {:capacity, Locus.Config.max_concurrent()}}

      # The keeper client's own reading of the wire: a build ended for memory,
      # and a bound this deployment cannot enforce.
      {:error, {:memory, _limit_or_cause} = refusal} ->
        {:error, refusal}

      {:error, {:unavailable, _sentence} = refusal} ->
        {:error, refusal}

      # The executor ended the build where its stdout passed the bound.
      {:error, {:output_too_large, max}} ->
        refused_output(
          on_progress,
          :compiling,
          "the build's output passed #{max} bytes and was refused"
        )
        |> killed()

      # The archive was refused as it arrived: what it was is said, and the
      # build was ended there.
      {:error, {:taker, {:refused, stage, message}}} ->
        refused_output(on_progress, stage, message)

      {:error, {:spawn_failed, reason}} ->
        Logger.error("[Locus.Builder] a build could not be run: #{inspect(reason)}")
        {:error, {:unavailable, "cyfr-locus could not run the build (#{spawn_failure(reason)})"}}
    end
  end

  defp killed({:error, _refusal}), do: {:error, {:failed, {:signal, "SIGKILL"}}}

  defp spawn_failure(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp spawn_failure(reason) when is_binary(reason), do: reason
  defp spawn_failure({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp spawn_failure(_reason), do: "spawn_failed"

  # ————— the output archive, as it arrives —————

  # The archive's reader and what was sent of it: the file being sent, if
  # it is an output, every file sent with its size and digest, the lines
  # sent and the bytes.
  defp stream(plan, on_progress, on_line) do
    %{
      plan: plan,
      on_progress: on_progress,
      on_line: on_line,
      archive: Locus.Archive.reader(BuilderProtocol.max_output_files()),
      started: false,
      file: nil,
      sent: [],
      seq: 0,
      bytes: 0,
      skipped: 0
    }
  end

  # One piece of stdout: its events, each output's bytes sent on before
  # the next piece is read.
  defp take(piece, stream) do
    case Locus.Archive.read(stream.archive, piece) do
      {:ok, events, archive} -> events(%{stream | archive: archive}, events)
      {:error, refusal} -> {:error, {:refused, :compiling, archive_refusal(refusal)}}
    end
  end

  defp events(stream, []), do: {:ok, stream}

  defp events(stream, [event | events]) do
    case event(stream, event) do
      {:ok, stream} -> events(stream, events)
      {:error, _reason} = error -> error
    end
  end

  # The archive begins once the build is done compiling: the component's
  # stage is said then.
  defp event(%{started: false, plan: %{language: :rust}} = stream, event) do
    case stream.on_progress.(:validating, "Validating WASM binary...") do
      {:error, _reason} = error -> error
      _taken -> event(%{stream | started: true}, event)
    end
  end

  defp event(%{started: false} = stream, event), do: event(%{stream | started: true}, event)

  defp event(stream, {:file, name, size}) do
    case output_path(stream.plan, name) do
      nil ->
        {:ok, %{stream | file: nil}}

      path ->
        total = stream.bytes + size
        max = BuilderProtocol.max_output_bytes()

        if total > max,
          do:
            {:error,
             {:refused, :validating,
              "the build's outputs total #{total} bytes; at most #{max} are answered"}},
          else:
            {:ok,
             %{
               stream
               | file: %{path: path, size: 0, hash: Prima.Digest.sha256_init()}
             }}
    end
  end

  defp event(%{file: nil} = stream, {:data, _bytes}), do: {:ok, stream}
  defp event(stream, {:data, bytes}), do: send_chunk(stream, bytes)

  defp event(%{file: nil} = stream, :file_end), do: {:ok, stream}

  defp event(%{file: file} = stream, :file_end) do
    sent = %{path: file.path, size: file.size, digest: Prima.Digest.sha256_final(file.hash)}
    {:ok, %{stream | file: nil, sent: [sent | stream.sent]}}
  end

  defp event(stream, {:skipped, _name}), do: {:ok, %{stream | skipped: stream.skipped + 1}}

  defp send_chunk(%{file: file} = stream, bytes) do
    seq = stream.seq + 1

    with {:ok, line} <- encoded(BuilderProtocol.encode_output(file.path, seq, bytes)),
         :ok <- taken(stream.on_line.(line)) do
      file = %{
        file
        | size: file.size + byte_size(bytes),
          hash: Prima.Digest.sha256_update(file.hash, bytes)
      }

      {:ok, %{stream | file: file, seq: seq, bytes: stream.bytes + byte_size(bytes)}}
    end
  end

  # An output whose path the wire does not carry: the archive's names were
  # held to PathSafety, so this is its bound or a control character.
  defp encoded({:ok, line}), do: {:ok, line}

  defp encoded({:error, _error}),
    do:
      {:error, {:refused, :compiling, "the build's output names a path the wire does not carry"}}

  defp taken({:error, reason}), do: {:error, reason}
  defp taken(_taken), do: :ok

  # The path an archive entry is sent under, or nil for one that is no
  # output: a component's WASM and lockfile, a tincture's `dist/` files.
  defp output_path(%{language: :rust, wasm: wasm}, wasm), do: BuilderProtocol.component_wasm()

  defp output_path(%{language: :rust}, "Cargo.lock"), do: BuilderProtocol.component_lockfile()
  defp output_path(%{language: :rust}, _name), do: nil
  defp output_path(%{language: :javascript}, "dist/" <> rel) when rel != "", do: rel
  defp output_path(%{language: :javascript}, _name), do: nil

  defp archive_refusal({:too_many_files, max}), do: "the build produced more than #{max} files"
  defp archive_refusal({:unsafe_path, _name}), do: "the build's output names an unsafe path"
  defp archive_refusal({:unreadable, _reason}), do: "the build's output archive is unreadable"

  # The archive must have ended whole; what it skipped is logged.
  defp ended(stream, on_progress) do
    if stream.skipped > 0,
      do:
        Logger.warning(
          "[Locus.Builder] skipped #{stream.skipped} non-regular entries in build output"
        )

    if Locus.Archive.ended?(stream.archive),
      do: {:ok, stream},
      else: refused_output(on_progress, :compiling, archive_refusal({:unreadable, :truncated}))
  end

  # The command believed it succeeded; what it left is not an output this
  # builder answers. The line is the only evidence of why.
  defp refused_output(on_progress, stage, message) do
    on_progress.(stage, message)
    {:error, {:failed, {:status, 0}}}
  end

  defp outputs(%{language: :rust, wasm: wasm}, stream, on_progress) do
    sent = Enum.reverse(stream.sent)

    if Enum.any?(sent, &(&1.path == BuilderProtocol.component_wasm())),
      do: {:ok, sent},
      else: refused_output(on_progress, :compiling, "cargo exited 0 without producing #{wasm}")
  end

  defp outputs(%{language: :javascript}, stream, on_progress) do
    case Enum.reverse(stream.sent) do
      [] -> refused_output(on_progress, :compiling, "the build produced no output files in dist/")
      sent -> {:ok, sent}
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
