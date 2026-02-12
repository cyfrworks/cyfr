defmodule Locus.Builder do
  @moduledoc """
  Compilation service that takes source code and produces validated WASM.

  Supports TinyGo (Go → WASI WASM) and Javy (JavaScript → WASM) toolchains.

  ## Security Properties

  - Temp directory per compilation, cleaned up immediately
  - Source size validated before writing to disk
  - Compiled WASM validated before returning
  - No network access from compiler (local tinygo/javy invocation)
  - Output goes through Opus WASM sandbox when executed

  ## Usage

      {:ok, result} = Locus.Builder.compile(source, :go, target_type: :reagent)
      # => {:ok, %{wasm_bytes: <<...>>, digest: "sha256:...", size: 1234,
      #           exports: [...], language: "go", target_type: "reagent"}}

      Locus.Builder.toolchain_available?(:go)  # => true/false
      Locus.Builder.available_toolchains()     # => %{go: %{available: true, ...}, ...}
  """

  require Logger

  @max_source_size 1_024 * 1_024
  @default_timeout_ms Application.compile_env(:locus, :compile_timeout_ms, 60_000)

  @doc """
  Compile source code to WASM using the appropriate toolchain.

  ## Parameters

  - `source` - Source code string
  - `language` - `:go` or `:js`
  - `opts` - Keyword options:
    - `:target_type` - Component type hint (`:reagent`, `:catalyst`, `:formula`)
    - `:timeout_ms` - Compilation timeout (default: 60s)

  ## Returns

  - `{:ok, result}` with `wasm_bytes`, `digest`, `size`, `exports`, `language`, `target_type`
  - `{:error, reason}` on failure
  """
  @spec compile(String.t(), atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def compile(source, language, opts \\ [])

  def compile("", _language, _opts), do: {:error, :empty_source}
  def compile(nil, _language, _opts), do: {:error, :empty_source}

  def compile(source, language, opts) when is_binary(source) and is_atom(language) do
    with :ok <- validate_source_size(source),
         :ok <- check_toolchain(language) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      target_type = Keyword.get(opts, :target_type, :reagent)

      do_compile(source, language, target_type, timeout_ms)
    end
  end

  @doc """
  Check if a compilation toolchain is available on the system.
  """
  @spec toolchain_available?(atom()) :: boolean()
  def toolchain_available?(:go), do: System.find_executable("tinygo") != nil
  def toolchain_available?(:js), do: System.find_executable("javy") != nil
  def toolchain_available?(_), do: false

  @doc """
  Return information about all supported toolchains.
  """
  @spec available_toolchains() :: map()
  def available_toolchains do
    %{
      go: %{
        available: toolchain_available?(:go),
        command: "tinygo",
        description: "TinyGo → WASI P2 WASM"
      },
      js: %{
        available: toolchain_available?(:js),
        command: "javy",
        description: "Javy → WASM"
      }
    }
  end

  # ============================================================================
  # Private: Source Validation
  # ============================================================================

  defp validate_source_size(source) when byte_size(source) > @max_source_size do
    {:error, {:source_too_large, byte_size(source), @max_source_size}}
  end

  defp validate_source_size(_source), do: :ok

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

  defp do_compile(source, language, target_type, timeout_ms) do
    tmp_dir = create_temp_dir()

    try do
      with :ok <- write_source(tmp_dir, language, source),
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

  defp write_source(tmp_dir, :go, source) do
    # Write go.mod for TinyGo
    go_mod = "module build\n\ngo 1.21\n"
    File.write!(Path.join(tmp_dir, "go.mod"), go_mod)
    File.write!(Path.join(tmp_dir, "main.go"), source)
    :ok
  end

  defp write_source(tmp_dir, :js, source) do
    File.write!(Path.join(tmp_dir, "main.js"), source)
    :ok
  end

  defp run_compiler(tmp_dir, :go, timeout_ms) do
    output = Path.join(tmp_dir, "output.wasm")
    args = ["build", "-target=wasip2", "-o", output, "main.go"]

    run_with_timeout("tinygo", args, tmp_dir, output, timeout_ms)
  end

  defp run_compiler(tmp_dir, :js, timeout_ms) do
    output = Path.join(tmp_dir, "output.wasm")
    input = Path.join(tmp_dir, "main.js")
    args = ["compile", input, "-o", output]

    run_with_timeout("javy", args, tmp_dir, output, timeout_ms)
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

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, :compilation_timeout}
    end
  end
end
