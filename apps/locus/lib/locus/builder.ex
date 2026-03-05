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

      do_compile(source_files, language, target_type, timeout_ms)
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

  defp do_compile(source_files, language, target_type, timeout_ms) do
    tmp_dir = create_temp_dir()

    try do
      with :ok <- write_source(tmp_dir, language, target_type, source_files),
           {:ok, wasm_path} <- run_compiler(tmp_dir, language, timeout_ms),
           {:ok, wasm_bytes} <- File.read(wasm_path),
           {:ok, validation} <- Locus.Validator.validate(wasm_bytes) do
        {:ok,
         %{
           wasm_bytes: wasm_bytes,
           digest: validation.digest,
           size: validation.size,
           exports: validation.exports,
           language: to_string(language),
           target_type: to_string(target_type)
         }}
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

  # Merge user-supplied [dependencies] into the generated Cargo.toml template.
  # The template controls [package], [lib], [package.metadata.component], and
  # [profile.release] — users can only add extra crate dependencies.
  defp merge_cargo_toml(template, user_cargo) do
    user_deps = extract_user_dependencies(user_cargo)

    if user_deps == "" do
      template
    else
      # Insert user deps after the template's [dependencies] section
      String.replace(
        template,
        ~r/(\[dependencies\]\n(?:.*\n)*?)(\n\[)/,
        "\\1#{user_deps}\n\\2"
      )
    end
  end

  # Extract dependency lines from a user Cargo.toml.
  # Returns only lines that aren't already in our template (wit-bindgen-rt, serde_json).
  defp extract_user_dependencies(user_cargo) do
    template_deps = ~w(wit-bindgen-rt serde_json serde-json)

    user_cargo
    |> String.split("\n")
    |> Enum.reduce({false, []}, fn line, {in_deps, acc} ->
      trimmed = String.trim(line)

      cond do
        trimmed == "[dependencies]" ->
          {true, acc}

        in_deps and String.starts_with?(trimmed, "[") ->
          {false, acc}

        in_deps and trimmed != "" and not String.starts_with?(trimmed, "#") ->
          # Check if this is a template dependency we should skip
          dep_name = trimmed |> String.split(~r/[\s=]/, parts: 2) |> hd()

          if dep_name in template_deps do
            {true, acc}
          else
            {true, [line | acc]}
          end

        true ->
          {in_deps, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join("\n")
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

  defp run_compiler(tmp_dir, :rust, timeout_ms) do
    output_dir = Path.join(tmp_dir, "target/wasm32-wasip2/release")
    output = Path.join(output_dir, "cyfr_component.wasm")
    args = ["component", "build", "--release", "--target", "wasm32-wasip2"]

    run_with_timeout("cargo", args, tmp_dir, output, timeout_ms)
  end

  defp run_with_timeout(command, args, cwd, output_path, timeout_ms) do
    task =
      Task.async(fn ->
        case System.cmd(command, args, cd: cwd, stderr_to_stdout: true) do
          {_output, 0} ->
            if File.exists?(output_path) do
              {:ok, output_path}
            else
              {:error, :output_not_found}
            end

          {error_output, exit_code} ->
            {:error, {:compilation_failed, exit_code, String.trim(error_output)}}
        end
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :compilation_timeout}
    end
  end
end
