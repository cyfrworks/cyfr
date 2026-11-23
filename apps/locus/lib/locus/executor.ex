# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Executor do
  @moduledoc """
  Runs one build command: an argv and an environment, bytes on its stdin,
  its stdout handed on piece by piece and its stderr line by line as the
  build log, never collected.

  The executor supplies `HOME` (a directory of the build's own), `TMPDIR`
  inside it, `USER`, `LOGNAME` and `PATH`; `env` is everything else the
  command sees. `Locus.Keeper` runs the command through cyfr-locus: under
  a pooled uid, inside the memory bound the builder runs every build under
  (`Locus.Config.memory_bytes/0`), and it is the one executor of every
  build. The suites run a real toolchain on a machine
  without cyfr-locus through a launcher of their own, compiled from the
  test support alone and named by the test build's application
  environment (`direct_launcher/0`): no release and no development node
  compiles it, and a node that holds no cyfr-locus channel there runs no
  build (`executor/0`).

  A run ends on every path with everything the command started gone: at
  its exit, at its deadline, when `cancel/1` reaches the process running
  it, and when that process dies.

  What the command writes reaches the caller's functions in the process
  running it, in order, and the executor reads the next piece only once
  the last call returned: a piece of stdout is at most one relay frame,
  folded into the caller's own state (`:on_stdout`), and nothing of the
  command's output is held but the piece being handed on. A function that
  answers `{:error, reason}` ends the run, as a deadline does, and the run
  answers that error; one returns by the run's deadline, since the reader
  of a command's output takes nothing past its own deadline.

  Every run names its place (`Locus.Launcher`, "Places"), which its
  caller made with `c:place/2` before preparing the build and drops with
  `c:drop/1` however the build ended: a drop frees only a place no run
  named, and the keeper frees one a run named once the run is gone.
  """

  @typedoc "The command: argv, the environment beyond the executor's own variables, and stdin."
  @type command :: %{argv: [String.t(), ...], env: %{String.t() => String.t()}, stdin: iodata()}

  @typedoc "How the command ended (`{:status, code}` or `{:signal, name}`), and the stdout fold's state."
  @type outcome :: %{exit: {:status, integer()} | {:signal, String.t()}, taken: term()}

  @typedoc "What a caller's function answers for what it was handed."
  @type taken :: :ok | {:error, term()}

  @typedoc "The stdout fold: its first state, and how a piece moves it on."
  @type on_stdout :: {term(), (binary(), term() -> {:ok, term()} | {:error, term()})}

  @typedoc """
  - `:timeout_ms` — the deadline for the whole run; past it everything the
    command started is killed and the answer is `{:error, :timeout}`
  - `:max_stdout_bytes` — the most stdout counted; past it everything is
    killed and the answer is `{:error, {:output_too_large, max}}`
  - `:on_stdout` — a fold over the pieces of stdout as they arrive, the
    next read only once it returned; its state is the outcome's `taken`
    (none drops stdout)
  - `:on_output` — called with each log line as it arrives, likewise
  """
  @type opts :: [
          place: String.t(),
          timeout_ms: pos_integer(),
          max_stdout_bytes: pos_integer(),
          on_stdout: on_stdout(),
          on_output: (String.t() -> taken())
        ]

  @typedoc """
  - `:timeout` — the deadline passed
  - `:cancelled` — `cancel/1` ended the run
  - `:capacity` — no pooled uid is free
  - `{:memory, limit_bytes}` — the command reached its memory bound and the
    kernel ended it there
  - `{:memory, :machine}` — the kernel ended it for memory at a limit above
    its bound; `{:memory, :either}` — at one of the two, and it does not
    say which (all three the build wire's `memory` refusal)
  - `{:unavailable, sentence}` — the bound cannot be enforced here, so the
    command was not run (the build wire's `unavailable` refusal)
  - `{:output_too_large, max}` — stdout passed its bound
  - `{:spawn_failed, reason}` — the command could not be started or followed
  - `{:taker, reason}` — a caller's function answered `{:error, reason}`
  """
  @type error ::
          :timeout
          | :cancelled
          | :capacity
          | {:memory, pos_integer() | :machine | :either}
          | {:unavailable, String.t()}
          | {:output_too_large, pos_integer()}
          | {:spawn_failed, term()}
          | {:taker, term()}

  @callback run(command(), opts()) :: {:ok, outcome()} | {:error, error()}

  @doc "A new place `id` of `whose` for the calling process."
  @callback place(String.t(), Locus.Launcher.whose()) :: :ok | {:error, term()}

  @doc "Free the place, unless a run named it."
  @callback drop(String.t()) :: :ok

  @doc """
  The launcher the test build runs builds and long-lived processes through
  when no cyfr-locus channel was inherited, or `nil`.

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
  The executor builds run with, and the `Locus.Launcher` a long-lived
  process is launched with: the keeper's client when it is running, the
  test build's direct launcher otherwise where it has one, and
  `{:error, :no_keeper}` everywhere else. Neither a build nor a long-lived
  process is ever run outside cyfr-locus by a release.
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
    # pieces. Nothing is kept here but the line not yet ended: what a
    # build's answer carries of its log is bounded where it is admitted
    # (`Locus.Diagnostics`). A callback's `{:error, reason}` stops the lines
    # after it, and is answered.

    @max_line_bytes 65_536

    defstruct partial: ""

    def new, do: %__MODULE__{}

    def add(%__MODULE__{} = log, chunk, on_output) do
      {lines, partial} = split(log.partial <> chunk)

      with :ok <- emit_all(lines, on_output), do: {:ok, %{log | partial: partial}}
    end

    def finish(%__MODULE__{} = log, on_output), do: emit(log.partial, on_output)

    defp emit_all([], _on_output), do: :ok

    defp emit_all([line | lines], on_output) do
      case emit(line, on_output) do
        :ok -> emit_all(lines, on_output)
        {:error, _reason} = error -> error
      end
    end

    defp split(data) do
      [partial | lines] = data |> String.split("\n") |> Enum.reverse()

      if byte_size(partial) > @max_line_bytes,
        do: {Enum.reverse([partial | lines]), ""},
        else: {Enum.reverse(lines), partial}
    end

    defp emit("", _on_output), do: :ok

    defp emit(line, on_output) do
      case on_output.(line) do
        {:error, _reason} = error -> error
        _taken -> :ok
      end
    end
  end
end
