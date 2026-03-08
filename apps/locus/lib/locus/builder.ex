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

  @max_source_size 1_024 * 1_024
  @default_timeout_ms Application.compile_env(:locus, :compile_timeout_ms, 300_000)

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

  def compile(source_files, _language, _opts) when source_files == %{}, do: {:error, :empty_source}

  def compile(%{} = source_files, language, opts) when is_atom(language) do
    with :ok <- validate_source_files(source_files),
         :ok <- check_toolchain(language) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      target_type = Keyword.get(opts, :target_type, :reagent)
      build_id = Keyword.get(opts, :build_id)
      session_id = Keyword.get(opts, :session_id)

      do_compile(source_files, language, target_type, timeout_ms, build_id, session_id)
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

  defp do_compile(source_files, language, target_type, timeout_ms, build_id, session_id) do
    tmp_dir = create_temp_dir()

    try do
      broadcast_progress(build_id, session_id, :preparing, "Preparing source files...")

      with :ok <- write_source(tmp_dir, language, target_type, source_files),
           :ok <- broadcast_progress(build_id, session_id, :compiling, "Compiling #{target_type} (#{language})..."),
           {:ok, wasm_path} <- run_compiler(tmp_dir, language, timeout_ms, build_id, session_id),
           :ok <- broadcast_progress(build_id, session_id, :validating, "Validating WASM binary..."),
           {:ok, wasm_bytes} <- File.read(wasm_path),
           {:ok, validation} <- Locus.Validator.validate(wasm_bytes) do
        broadcast_progress(build_id, session_id, :complete, "Build complete — #{validation.size} bytes, #{length(validation.exports)} export(s)")

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
          broadcast_progress(build_id, session_id, :error, "Build failed")
          error
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp create_temp_dir do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    dir = Path.join(System.tmp_dir!(), "locus_build_#{id}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_source(tmp_dir, :rust, target_type, source_files) do
    # Write Cargo.toml — merge user dependencies if a user Cargo.toml is provided
    cargo_toml =
      case Map.get(source_files, "Cargo.toml") do
        nil -> cargo_toml_for(target_type)
        user_cargo -> merge_cargo_toml(cargo_toml_for(target_type), user_cargo)
      end

    File.write!(Path.join(tmp_dir, "Cargo.toml"), cargo_toml)

    # Write all source files preserving directory structure
    source_files
    |> Enum.reject(fn {path, _} -> path == "Cargo.toml" end)
    |> Enum.each(fn {rel_path, content} ->
      dest = Path.join(tmp_dir, rel_path)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end)

    # Use source-local WIT files if present, otherwise copy from canonical location
    has_wit = Enum.any?(source_files, fn {path, _} -> String.starts_with?(path, "wit/") end)
    if has_wit, do: :ok, else: copy_wit_files(tmp_dir, target_type)
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

  defp broadcast_progress(nil, _session_id, _phase, _message), do: :ok

  defp broadcast_progress(build_id, session_id, phase, message) do
    Phoenix.PubSub.broadcast(
      Emissary.PubSub,
      "build:#{build_id}",
      {:build_progress, %{phase: phase, message: message, timestamp: System.monotonic_time(:millisecond)}}
    )

    if session_id do
      notification = Emissary.MCP.Message.encode_notification("notifications/progress", %{
        build_id: build_id, phase: phase, message: message
      })
      Emissary.MCP.SSEBuffer.push(session_id, notification)
    end

    :ok
  end

  defp copy_wit_files(tmp_dir, target_type) do
    wit_source = wit_source_path(target_type)
    wit_dest = Path.join(tmp_dir, "wit")

    if File.dir?(wit_source) do
      File.cp_r!(wit_source, wit_dest)
      :ok
    else
      {:error, {:wit_not_found, wit_source}}
    end
  end

  defp wit_source_path(target_type) do
    wit_base = Application.get_env(:locus, :wit_path, "./wit") |> Path.expand()
    Path.join(wit_base, to_string(target_type))
  end

  defp run_compiler(tmp_dir, :rust, timeout_ms, build_id, session_id) do
    output_dir = Path.join(tmp_dir, "target/wasm32-wasip2/release")
    crate_name = extract_crate_name(tmp_dir)
    output = Path.join(output_dir, "#{crate_name}.wasm")
    args = ["component", "build", "--release", "--target", "wasm32-wasip2"]

    run_with_timeout("cargo", args, tmp_dir, output, timeout_ms, build_id, session_id)
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

  defp run_with_timeout(command, args, cwd, output_path, timeout_ms, build_id, session_id) do
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

        collect_port_output(port, [], build_id, session_id)
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
        Task.shutdown(task, :brutal_kill)
        {:error, :compilation_timeout}
    end
  end

  defp collect_port_output(port, acc, build_id, session_id) do
    receive do
      {^port, {:data, data}} ->
        data
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.each(&broadcast_progress(build_id, session_id, :output, &1))

        collect_port_output(port, [data | acc], build_id, session_id)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc |> Enum.reverse() |> Enum.join()}
    end
  end
end
