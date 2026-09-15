# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Executor do
  @moduledoc """
  Runs one build command: an argv and an environment, bytes on its stdin,
  its stdout collected and its stderr streamed as the build log.

  The executor supplies `HOME` (a directory of the build's own), `TMPDIR`
  inside it, `USER`, `LOGNAME` and `PATH`; `env` is everything else the
  command sees. `Locus.Spawner` runs the command under a pooled uid
  through cyfr-spawn; `Locus.DirectLauncher` runs it as this node's user.
  `executor/0` picks the spawner when this node holds its channel.
  """

  @typedoc "The command: argv, the environment beyond the executor's own variables, and stdin."
  @type command :: %{argv: [String.t(), ...], env: %{String.t() => String.t()}, stdin: iodata()}

  @typedoc """
  How the command ended (`{:status, code}` or `{:signal, name}`), its
  stdout, and the head of its log, at most `max_log_bytes/0`.
  """
  @type outcome :: %{
          exit: {:status, integer()} | {:signal, String.t()},
          stdout: binary(),
          log: binary()
        }

  @typedoc """
  - `:timeout_ms` — the deadline for the whole run; past it everything the
    command started is killed and the answer is `{:error, :timeout}`
  - `:max_stdout_bytes` — past it everything is killed and the answer is
    `{:error, {:output_too_large, max}}`
  - `:on_output` — called with each log line as it arrives
  """
  @type opts :: [
          timeout_ms: pos_integer(),
          max_stdout_bytes: pos_integer(),
          on_output: (String.t() -> any())
        ]

  @typedoc """
  - `:timeout` — the deadline passed
  - `:capacity` — no pooled uid is free
  - `{:output_too_large, max}` — stdout passed its bound
  - `{:spawn_failed, reason}` — the command could not be started or followed
  """
  @type error ::
          :timeout | :capacity | {:output_too_large, pos_integer()} | {:spawn_failed, term()}

  @callback run(command(), opts()) :: {:ok, outcome()} | {:error, error()}

  @doc "The executor builds run with: the spawner when its channel is held, the direct launcher otherwise."
  @spec executor() :: module()
  def executor do
    if Locus.Spawner.running?(), do: Locus.Spawner, else: Locus.DirectLauncher
  end

  @max_log_bytes 2_000_000

  @doc "The most log a run retains; every line still reaches `:on_output`."
  @spec max_log_bytes() :: pos_integer()
  def max_log_bytes, do: @max_log_bytes

  defmodule Log do
    @moduledoc false
    # A build log as it arrives: complete lines go to the callback as they
    # form, an unterminated line longer than @max_line_bytes goes out in
    # pieces, and the head of the log is kept up to Locus.Executor's bound.

    @max_line_bytes 65_536

    defstruct partial: "", kept: [], bytes: 0

    def new, do: %__MODULE__{}

    def add(%__MODULE__{} = log, chunk, on_output) do
      {lines, partial} = split(log.partial <> chunk)
      Enum.each(lines, &emit(&1, on_output))
      keep(%{log | partial: partial}, chunk)
    end

    def finish(%__MODULE__{} = log, on_output) do
      emit(log.partial, on_output)
      IO.iodata_to_binary(log.kept)
    end

    defp split(data) do
      [partial | lines] = data |> String.split("\n") |> Enum.reverse()

      if byte_size(partial) > @max_line_bytes,
        do: {Enum.reverse([partial | lines]), ""},
        else: {Enum.reverse(lines), partial}
    end

    defp emit("", _on_output), do: :ok
    defp emit(line, on_output), do: on_output.(line)

    defp keep(%{bytes: bytes} = log, chunk) do
      max = Locus.Executor.max_log_bytes()

      if bytes >= max do
        log
      else
        kept = binary_part(chunk, 0, min(byte_size(chunk), max - bytes))
        %{log | kept: [log.kept, kept], bytes: bytes + byte_size(kept)}
      end
    end
  end
end
