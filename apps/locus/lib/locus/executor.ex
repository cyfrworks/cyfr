# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Executor do
  @moduledoc """
  Runs one build command: an argv and an environment, bytes on its stdin,
  its stdout collected and its stderr delivered line by line as the build
  log.

  The executor supplies `HOME` (a directory of the build's own), `TMPDIR`
  inside it, `USER`, `LOGNAME` and `PATH`; `env` is everything else the
  command sees. `Locus.Spawner` runs the command through cyfr-spawn: under
  a pooled uid, inside the memory bound the builder runs every build under
  (`Locus.Config.memory_bytes/0`). `Locus.DirectLauncher` runs it as this
  node's own user with no bound at all, so it is an executor of the test
  build alone (`executors/0`): no release and no development node knows
  it, whatever its configuration says, and a node that holds no cyfr-spawn
  channel there runs no build (`executor/0`).

  A run ends on every path with everything the command started gone: at
  its exit, at its deadline, when `cancel/1` reaches the process running
  it, and when that process dies.
  """

  @typedoc "The command: argv, the environment beyond the executor's own variables, and stdin."
  @type command :: %{argv: [String.t(), ...], env: %{String.t() => String.t()}, stdin: iodata()}

  @typedoc "How the command ended (`{:status, code}` or `{:signal, name}`) and its stdout."
  @type outcome :: %{exit: {:status, integer()} | {:signal, String.t()}, stdout: binary()}

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
  - `:cancelled` — `cancel/1` ended the run
  - `:capacity` — no pooled uid is free
  - `{:memory, limit_bytes}` — the command reached its memory bound and the
    kernel ended it there (the build wire's `memory` refusal)
  - `{:unavailable, sentence}` — the bound cannot be enforced here, so the
    command was not run (the build wire's `unavailable` refusal)
  - `{:output_too_large, max}` — stdout passed its bound
  - `{:spawn_failed, reason}` — the command could not be started or followed
  """
  @type error ::
          :timeout
          | :cancelled
          | :capacity
          | {:memory, pos_integer()}
          | {:unavailable, String.t()}
          | {:output_too_large, pos_integer()}
          | {:spawn_failed, term()}

  @callback run(command(), opts()) :: {:ok, outcome()} | {:error, error()}

  # The direct launcher isolates and bounds nothing, so the choice exists
  # where the suites run and nowhere else: a release is compiled without it
  # and no setting brings it back.
  @executors if Mix.env() == :test,
               do: [Locus.Spawner, Locus.DirectLauncher],
               else: [Locus.Spawner]

  @doc "The executors this build knows: the spawner, and the direct launcher under the test environment alone."
  @spec executors() :: [module()]
  def executors, do: @executors

  @doc """
  The executor builds run with: the spawner when its client is running,
  the direct launcher otherwise where this build knows it, and
  `{:error, :no_keeper}` everywhere else. A build is never run outside
  cyfr-spawn by a release.
  """
  @spec executor() :: {:ok, module()} | {:error, :no_keeper}
  def executor do
    executor = if Locus.Spawner.running?(), do: Locus.Spawner, else: Locus.DirectLauncher
    if executor in @executors, do: {:ok, executor}, else: {:error, :no_keeper}
  end

  @doc """
  End the run `pid` is in the middle of, or starts next: everything the
  command started is killed, and `run/2` answers `{:error, :cancelled}`
  once it is gone.
  """
  @spec cancel(pid()) :: :ok
  def cancel(pid) when is_pid(pid) do
    send(pid, {__MODULE__, :cancel})
    :ok
  end

  defmodule Log do
    @moduledoc false
    # A build log as it arrives: complete lines go to the callback as they
    # form, and an unterminated line longer than @max_line_bytes goes out in
    # pieces. Nothing is kept here: what a build's answer carries of its log
    # is bounded where it is collected (`Locus.Diagnostics`).

    @max_line_bytes 65_536

    defstruct partial: ""

    def new, do: %__MODULE__{}

    def add(%__MODULE__{} = log, chunk, on_output) do
      {lines, partial} = split(log.partial <> chunk)
      Enum.each(lines, &emit(&1, on_output))
      %{log | partial: partial}
    end

    def finish(%__MODULE__{} = log, on_output) do
      emit(log.partial, on_output)
      :ok
    end

    defp split(data) do
      [partial | lines] = data |> String.split("\n") |> Enum.reverse()

      if byte_size(partial) > @max_line_bytes,
        do: {Enum.reverse([partial | lines]), ""},
        else: {Enum.reverse(lines), partial}
    end

    defp emit("", _on_output), do: :ok
    defp emit(line, on_output), do: on_output.(line)
  end
end
