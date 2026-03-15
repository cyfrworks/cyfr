defmodule Locus.Builder do
  @moduledoc """
  Compilation service that takes source code and produces validated WASM.

  Supports Rust → WASM Component Model via `cargo-component`.

  ## Security Properties

  - Temp directory per compilation, cleaned up immediately
  - Source size validated before writing to disk
  - Compiled WASM validated before returning
  - No network access from compiler beyond crates.io registry
  - Output goes through Opus WASM sandbox when executed

  ## Usage

      {:ok, result} = Locus.Builder.compile(%{"src/lib.rs" => source}, :rust, target_type: :reagent)
      # => {:ok, %{wasm_bytes: <<...>>, digest: "sha256:...", size: 1234,
      #           exports: [...], language: "rust", target_type: "reagent"}}

      Locus.Builder.toolchain_available?(:rust)  # => true/false
      Locus.Builder.available_toolchains()       # => %{rust: %{available: true, ...}}
  """

  require Logger

  @max_source_size Application.compile_env(:cyfr, :max_source_size, 1_024 * 1_024)
  @default_timeout_ms Application.compile_env(:cyfr, :compile_timeout_ms, 300_000)

  @doc """
  Compile source code to WASM using the appropriate toolchain.

  ## Parameters

  - `source_files` - A map of `%{relative_path => content}` for the project.
    Must contain a `"src/lib.rs"` entry. An optional `"Cargo.toml"` entry
    supplies user dependencies that are merged into the generated template.
  - `language` - `:rust`
  - `opts` - Keyword options:
    - `:target_type` - Component type hint (`:reagent`, `:catalyst`, `:formula`)
    - `:timeout_ms` - Compilation timeout (default: 300s)

  ## Returns

  - `{:ok, result}` with `wasm_bytes`, `digest`, `size`, `exports`, `language`, `target_type`
  - `{:error, reason}` on failure
  """
  @spec compile(map(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile(source_files, language, opts \\ [])

  def compile(source_files, _language, _opts) when source_files == %{},
    do: {:error, :empty_source}

  def compile(%{} = source_files, language, opts) when is_atom(language) do
    with :ok <- validate_source_files(source_files),
         :ok <- check_toolchain(language) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      target_type = Keyword.get(opts, :target_type, :reagent)
      build_id = Keyword.get(opts, :build_id)
      session_id = Keyword.get(opts, :session_id)
      ctx = Keyword.get(opts, :ctx)

      do_compile(source_files, language, target_type, timeout_ms, build_id, session_id, ctx)
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
        description: "Rust → WASM Component Model (cargo-component)"
      }
    }
  end

  # ============================================================================
  # Private: Source Validation
  # ============================================================================

  defp validate_source_files(source_files) do
    unless Map.has_key?(source_files, "src/lib.rs") do
      {:error, :missing_lib_rs}
    else
      total_size = source_files |> Map.values() |> Enum.reduce(0, &(byte_size(&1) + &2))

      if total_size > @max_source_size do
        {:error, {:source_too_large, total_size, @max_source_size}}
      else
        :ok
      end
    end
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

  defp do_compile(source_files, language, target_type, timeout_ms, build_id, session_id, ctx) do
    with {:ok, tmp_dir} <- create_temp_dir() do
      try do
        broadcast_progress(ctx, build_id, session_id, :preparing, "Preparing source files...")

        with :ok <- write_source(tmp_dir, language, target_type, source_files),
             :ok <-
               broadcast_progress(
                 ctx,
                 build_id,
                 session_id,
                 :compiling,
                 "Compiling #{target_type} (#{language})..."
               ),
             {:ok, wasm_path} <-
               run_compiler(tmp_dir, language, timeout_ms, build_id, session_id, ctx),
             :ok <-
               broadcast_progress(
                 ctx,
                 build_id,
                 session_id,
                 :validating,
                 "Validating WASM binary..."
               ),
             {:ok, wasm_bytes} <- File.read(wasm_path),
             {:ok, validation} <- Locus.Validator.validate(wasm_bytes) do
          broadcast_progress(
            ctx,
            build_id,
            session_id,
            :complete,
            "Build complete — #{validation.size} bytes, #{length(validation.exports)} export(s)"
          )

          {:ok,
           %{
             wasm_bytes: wasm_bytes,
             digest: validation.digest,
             size: validation.size,
             exports: validation.exports,
             language: to_string(language),
             target_type: to_string(target_type)
           }}
        else
          error ->
            broadcast_progress(ctx, build_id, session_id, :error, "Build failed")
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
        id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        dir = Path.join(tmp, "locus_build_#{id}")

        case File.mkdir_p(dir) do
          :ok -> {:ok, dir}
          {:error, reason} -> {:error, {:mkdir_failed, reason}}
        end
    end
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

  defp write_source_files(tmp_dir, source_files) do
    source_files
    |> Enum.reject(fn {path, _} -> path == "Cargo.toml" end)
    |> Enum.reduce_while(:ok, fn {rel_path, content}, :ok ->
      dest = Path.join(tmp_dir, rel_path)

      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, content) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:write_failed, rel_path, reason}}}
      end
    end)
  end

  @doc """
  Return the Cargo.toml content for a given component type.
  """
  def cargo_toml_for(:reagent) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:reagent"

    [package.metadata.component.target]
    world = "reagent"
    path = "wit"

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  def cargo_toml_for(:catalyst) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:catalyst"

    [package.metadata.component.target]
    world = "catalyst"
    path = "wit"

    [package.metadata.component.target.dependencies]
    "cyfr:secrets" = { path = "wit/deps/cyfr-secrets" }
    "cyfr:http" = { path = "wit/deps/cyfr-http" }
    "cyfr:storage" = { path = "wit/deps/cyfr-storage" }

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
  end

  def cargo_toml_for(:formula) do
    """
    [package]
    name = "cyfr-component"
    version = "0.1.0"
    edition = "2021"

    [lib]
    crate-type = ["cdylib"]

    [dependencies]
    wit-bindgen-rt = "0.25"
    serde_json = "1.0"

    [package.metadata.component]
    package = "cyfr:formula"

    [package.metadata.component.target]
    world = "formula"
    path = "wit"

    [profile.release]
    opt-level = "s"
    lto = true
    codegen-units = 1
    strip = true
    """
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

  # ============================================================================
  # Progress Broadcasting
  # ============================================================================

  defp broadcast_progress(_ctx, nil, _session_id, _phase, _message), do: :ok

  defp broadcast_progress(ctx, build_id, session_id, phase, message) do
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

    :ok
  end

  defp copy_wit_files(tmp_dir, target_type) do
    wit_source = wit_source_path(target_type)
    wit_dest = Path.join(tmp_dir, "wit")

    if File.dir?(wit_source) do
      case File.cp_r(wit_source, wit_dest) do
        {:ok, _} -> :ok
        {:error, reason, file} -> {:error, {:wit_copy_failed, file, reason}}
      end
    else
      {:error, {:wit_not_found, wit_source}}
    end
  end

  defp wit_source_path(target_type) do
    wit_base = Application.get_env(:cyfr, :wit_path, "./wit") |> Path.expand()
    Path.join(wit_base, to_string(target_type))
  end

  defp run_compiler(tmp_dir, :rust, timeout_ms, build_id, session_id, ctx) do
    output_dir = Path.join(tmp_dir, "target/wasm32-wasip2/release")
    crate_name = extract_crate_name(tmp_dir)
    output = Path.join(output_dir, "#{crate_name}.wasm")
    args = ["component", "build", "--release", "--target", "wasm32-wasip2"]

    run_with_timeout("cargo", args, tmp_dir, output, timeout_ms, build_id, session_id, ctx)
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

  defp run_with_timeout(command, args, cwd, output_path, timeout_ms, build_id, session_id, ctx) do
    task =
      Task.async(fn ->
        executable = System.find_executable(command) || command

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args},
            {:cd, cwd}
          ])

        # Store OS PID so the parent can kill the process tree on timeout
        case Port.info(port, :os_pid) do
          {:os_pid, os_pid} -> Process.put(:builder_os_pid, os_pid)
          _ -> :ok
        end

        collect_port_output(port, [], build_id, session_id, ctx)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, {:ok, 0, _output}} ->
        if File.exists?(output_path) do
          {:ok, output_path}
        else
          {:error, :output_not_found}
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
    end
  end

  defp get_task_os_pid(task) do
    case Process.info(task.pid, :dictionary) do
      {:dictionary, dict} -> Keyword.get(dict, :builder_os_pid)
      _ -> nil
    end
  end

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    # Kill the process group to clean up cargo and its children
    System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp collect_port_output(port, acc, build_id, session_id, ctx) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.each(&broadcast_progress(ctx, build_id, session_id, :output, &1))

        collect_port_output(port, [data | acc], build_id, session_id, ctx)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> Enum.reverse() |> Enum.join()}
    end
  end
end
