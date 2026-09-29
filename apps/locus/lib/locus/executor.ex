# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Executor do
  @moduledoc """
  Runs one build command: an argv and an environment, bytes on its stdin,
  its stdout collected and its stderr delivered line by line as the build
  log.

  The executor supplies `HOME` (a directory of the build's own), `TMPDIR`
  inside it, `USER`, `LOGNAME` and `PATH`; `env` is everything else the
  command sees. `Locus.Keeper` runs the command through cyfr-keeper: under
  a pooled uid, inside the memory bound the builder runs every build under
  (`Locus.Config.memory_bytes/0`), and it is the one executor of every
  build (`executors/0`). The suites run a real toolchain on a machine
  without cyfr-keeper through a launcher of their own, compiled from the
  test support alone and named by the test build's application
  environment (`direct_launcher/0`): no release and no development node
  compiles it, and a node that holds no cyfr-keeper channel there runs no
  build (`executor/0`).

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

  @doc "The executors every build knows: the keeper's client alone."
  @spec executors() :: [module()]
  def executors, do: [Locus.Keeper]

  @doc """
  The launcher the test build runs builds and long-lived processes through
  when no cyfr-keeper channel was inherited, or `nil`.

  It isolates and bounds nothing, so it is named by the application
  environment of the test build alone (`apps/locus/mix.exs`) and compiled
  from its test support: every other build compiles no such module, so a
  name that reaches this key from anywhere else resolves to nothing.
  """
  @spec direct_launcher() :: module() | nil
  def direct_launcher do
    case Application.get_env(:locus, :direct_launcher) do
      launcher when is_atom(launcher) and not is_nil(launcher) ->
        if Code.ensure_loaded?(launcher), do: launcher

      _ ->
        nil
    end
  end

  @doc """
  The executor builds run with: the keeper's client when it is running,
  the test build's direct launcher otherwise where it has one, and
  `{:error, :no_keeper}` everywhere else. A build is never run outside
  cyfr-keeper by a release.
  """
  @spec executor() :: {:ok, module()} | {:error, :no_keeper}
  def executor do
    cond do
      Locus.Keeper.running?() -> {:ok, Locus.Keeper}
      launcher = direct_launcher() -> {:ok, launcher}
      true -> {:error, :no_keeper}
    end
  end

  @doc """
  The `Locus.Launcher` a long-lived process is launched with, by the rule
  `executor/0` follows: the keeper's client when it runs, the test
  build's direct launcher otherwise where it has one, and
  `{:error, :no_keeper}` everywhere else.
  """
  @spec launcher() :: {:ok, module()} | {:error, :no_keeper}
  def launcher, do: executor()

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
