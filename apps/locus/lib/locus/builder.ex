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

  ## Security Properties

  - Temp directory per compilation, cleaned up immediately
  - Source size validated before writing to disk
  - Compiled WASM validated before returning
  - No network access from compiler beyond crates.io / npm registry
  - WASM output goes through Opus WASM sandbox when executed

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

  @max_source_size Application.compile_env(:cyfr, :max_source_size, 1_024 * 1_024)
  @default_timeout_ms Application.compile_env(:cyfr, :compile_timeout_ms, 300_000)

  @doc """
  Compile source code using the appropriate toolchain.

  ## Parameters

  - `source_files` - A map of `%{relative_path => content}` for the project.
    For `:rust`: must contain `"src/lib.rs"`. Optional `"Cargo.toml"` is merged.
    For `:javascript`: must contain `"package.json"`.
  - `language` - `:rust` or `:javascript`
  - `opts` - Keyword options:
    - `:target_type` - Component type (`:reagent`, `:catalyst`, `:formula`, `:tincture`)
    - `:timeout_ms` - Compilation timeout (default: 300s)

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
    with :ok <- validate_source_files(source_files, language),
         :ok <- check_toolchain(language) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      target_type = Keyword.get(opts, :target_type, :reagent)
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
      :ok
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

  defp do_compile(source_files, :rust, target_type, timeout_ms, on_progress) do
    with {:ok, tmp_dir} <- create_temp_dir() do
      try do
        on_progress.(:preparing, "Preparing source files...")

        with :ok <- write_source(tmp_dir, :rust, target_type, source_files),
             :ok <- on_progress.(:compiling, "Compiling #{target_type} (rust)..."),
             {:ok, wasm_path} <- run_compiler(tmp_dir, :rust, timeout_ms, on_progress),
             :ok <- on_progress.(:validating, "Validating WASM binary..."),
             {:ok, wasm_bytes} <- File.read(wasm_path),
             {:ok, validation} <- Locus.Validator.validate(wasm_bytes) do
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
          {digest, size} = compute_output_digest(output_files)

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

  defp write_source(tmp_dir, :javascript, _target_type, source_files) do
    write_source_files(tmp_dir, source_files)
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

  Delegates to `Compendium.Scaffold.cargo_toml_for/2` — the canonical
  template — omitting the `cyfr:oauth` WIT dep: the build sandbox
  materializes only the WIT worlds every component type needs, and a user
  project that uses oauth carries its own Cargo.toml, which
  `merge_cargo_toml/2` treats as authoritative for WIT deps.
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
      ["-c", "npm install --no-audit --no-fund 2>&1 && npm run build 2>&1"],
      tmp_dir,
      nil,
      timeout_ms,
      on_progress
    )
  end

  defp collect_dist_files(tmp_dir) do
    dist_dir = Path.join(tmp_dir, "dist")

    if File.dir?(dist_dir) do
      files =
        dist_dir
        |> list_files_recursive()
        |> Enum.reduce(%{}, fn file_path, acc ->
          rel = Path.relative_to(file_path, dist_dir)
          {:ok, content} = File.read(file_path)
          Map.put(acc, rel, content)
        end)

      if map_size(files) == 0 do
        {:error, {:compilation_failed, 0, "Build produced no output files in dist/"}}
      else
        {:ok, files}
      end
    else
      {:error, {:compilation_failed, 0, "Build did not produce a dist/ directory"}}
    end
  end

  defp list_files_recursive(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)
          if File.dir?(full), do: list_files_recursive(full), else: [full]
        end)

      {:error, _} ->
        []
    end
  end

  defp compute_output_digest(output_files) do
    {hash_state, total_size} =
      output_files
      |> Enum.sort_by(fn {path, _} -> path end)
      |> Enum.reduce({:crypto.hash_init(:sha256), 0}, fn {path, content}, {state, size} ->
        new_state =
          state
          |> :crypto.hash_update(path)
          |> :crypto.hash_update(content)

        {new_state, size + byte_size(content)}
      end)

    digest = "sha256:" <> (:crypto.hash_final(hash_state) |> Base.encode16(case: :lower))
    {digest, total_size}
  end

  defp run_with_timeout(command, args, cwd, output_path, timeout_ms, on_progress) do
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
    e ->
      Logger.warning("[Builder] Failed to kill OS process #{os_pid}: #{inspect(e)}")
      :ok
  end

  defp collect_port_output(port, acc, on_progress) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.each(&on_progress.(:output, &1))

        collect_port_output(port, [data | acc], on_progress)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> Enum.reverse() |> Enum.join()}
    end
  end
end
