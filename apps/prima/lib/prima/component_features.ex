# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ComponentFeatures do
  @moduledoc """
  The WebAssembly features a component may not use, and the check that
  refuses one that does. Every component is validated with them turned
  off before it is stored as runnable (`Prima.Wasm.validate/1,2`, which
  the registry's publish and registration and both builders call) and
  again before it is compiled (`Locus.Runtime.ComponentCache` and the
  engine's uncached compile), by the pinned `wasm-tools`
  (`scripts/wasm-tools.sh`), whose wasmparser decodes the async canonical
  options and builtins as the engine's does.

  ## A security constraint, and its condition

  The refused features are those the engine's Wasmtime (47.0.3, which
  wasmex 0.15.1 runs) cannot run safely, not admission policy of their
  own:

    * the component-model async features (`cm-async` and the four that
      build on it): GHSA-32h6-97mm-8q3c, an async-lifted export's callback
      whose result count Wasmtime never validates, lets a component write
      to the host's native stack, in Wasmtime 39.0.0 through 48.0.3 and
      49.0.0 through 49.0.1;
    * exception handling (`exceptions`, `legacy-exceptions`) and GC
      (`gc`): GHSA-cfhf-m2cr-62wj and GHSA-hw8m-q44c-ggrf corrupt the GC
      heap through mis-typed tags and unrooted references live across a
      `try_call`, in Wasmtime 47.0.0 through 48.0.3 and 49.0.0 through
      49.0.1;
    * GC's reference types (`gc-types`): a core module declaring a table
      of `externref` gets a GC heap at instantiation, a memory the store's
      count of one linear memory does not bound.

  The advisories are fixed in Wasmtime 48.0.4 and 49.0.2. When the wasmex
  this tree pins runs one of those or later, this refusal is re-evaluated
  then: removed, or kept as admission policy on its own merits.

  ## The validator

  `install!/0` reads the validator's absolute path (`config :prima,
  :wasm_tools`), never a PATH lookup, and refuses a path that is not an
  executable file; each application that admits or compiles components
  installs it as it starts. `check/1` hands it the component on its
  standard input, through `/bin/sh` and `head -c` of exactly the
  component's size, so it reads to an end and nothing of the component
  is written anywhere: the validator runs with an empty environment
  (`sh` and `head` named by absolute path) and a deadline at which its
  whole process group is killed. A process of its own, trapping exits,
  owns each run, so a port that fails ends the check and never its
  caller. Nothing the validator prints reaches a refusal or a log line:
  it can quote the component's own names. The check fails closed: a
  validator not installed, not started, killed at its deadline or ending
  other than valid or invalid refuses the component. Calls are bounded by
  their callers alone: one per publish, registration or build, and one
  per compile the runtime's cache misses.
  """

  require Logger

  # wasmparser's names, as the pinned wasm-tools spells them, by the
  # family a refusal's log line names.
  @families [
    async: ~w(cm-async cm-async-stackful cm-more-async-builtins cm-error-context cm-threading),
    gc: ~w(gc gc-types),
    exceptions: ~w(exceptions legacy-exceptions)
  ]

  @refused Enum.flat_map(@families, &elem(&1, 1))

  # How long one run may take before it is killed and the component
  # refused unchecked (`config :prima, :wasm_tools_timeout_ms`).
  @timeout_ms 10_000

  @key {__MODULE__, :validator}

  @typedoc "Why a component was refused, as `Prima.Refusal` classifies it."
  @type refusal ::
          {:component_feature_refused, String.t()}
          | {:component_invalid, String.t()}
          | :component_validator_unavailable

  @doc "The features a component may not use, by wasmparser's names."
  @spec refused() :: [String.t()]
  def refused, do: @refused

  @doc """
  Check the configured validator and hold it for `check/1`. Raises when
  `config :prima, :wasm_tools` is unset or names no executable file by
  an absolute path.
  """
  @spec install!() :: :ok
  def install! do
    path = Application.fetch_env!(:prima, :wasm_tools)

    case executable(path) do
      :ok ->
        :persistent_term.put(@key, path)

      {:error, why} ->
        raise ArgumentError,
              "config :prima, :wasm_tools #{why}; scripts/wasm-tools.sh install DIR " <>
                "installs the pinned wasm-tools"
    end
  end

  defp executable(path) when is_binary(path) do
    # arca:bypass-ok=D — the validator binary, an OS tool of the deployment.
    with :absolute <- Path.type(path),
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) != 0 do
      :ok
    else
      :relative -> {:error, "is not an absolute path"}
      :volumerelative -> {:error, "is not an absolute path"}
      _ -> {:error, "names no executable file (#{path})"}
    end
  end

  defp executable(_path), do: {:error, "is not a path"}

  @doc """
  `:ok` when the component uses none of the refused features and is
  valid WebAssembly; otherwise the refusal, naming the component by its
  digest. The feature a refusal was for is in the log line alone.
  """
  @spec check(binary()) :: :ok | {:error, refusal()}
  def check(bytes) when is_binary(bytes) do
    digest = Prima.Digest.sha256(bytes)

    case :persistent_term.get(@key, nil) do
      nil -> unavailable(digest, "no validator is installed")
      validator -> isolated(fn -> classify(validator, bytes, digest) end, digest)
    end
  end

  # The runs' ports are owned by a process of their own that traps exits:
  # a port closed under a write sends its owner an exit signal, which
  # must end the check, not the caller.
  defp isolated(fun, digest) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {ref, fun.()})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        unavailable(digest, "its check ended without an answer")
    end
  end

  # With every refused feature off first; only a refusal is asked again,
  # with the validator's own defaults, so that a component it refuses
  # either way is invalid rather than a feature's, and then with each
  # family off alone, for the log line.
  defp classify(validator, bytes, digest) do
    case run(validator, bytes, @refused) do
      :valid ->
        :ok

      :invalid ->
        case run(validator, bytes, []) do
          :valid ->
            family =
              Enum.find_value(@families, fn {family, flags} ->
                run(validator, bytes, flags) == :invalid and family
              end)

            Logger.warning(
              "[Prima.ComponentFeatures] #{digest} refused: it uses " <>
                "#{if family, do: "the #{family} feature", else: "a refused feature"}"
            )

            {:error, {:component_feature_refused, digest}}

          :invalid ->
            Logger.warning(
              "[Prima.ComponentFeatures] #{digest} refused: it is not valid WebAssembly"
            )

            {:error, {:component_invalid, digest}}

          {:unavailable, why} ->
            unavailable(digest, why)
        end

      {:unavailable, why} ->
        unavailable(digest, why)
    end
  end

  defp unavailable(digest, why) do
    Logger.error("[Prima.ComponentFeatures] #{digest} refused unchecked: #{why}")
    {:error, :component_validator_unavailable}
  end

  defp timeout_ms do
    case Application.get_env(:prima, :wasm_tools_timeout_ms, @timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @timeout_ms
    end
  end

  # `head -c` ends the validator's input after exactly the component's
  # bytes: a port cannot close the write end of its program's input and
  # still read its exit status.
  @feed ~S(size=$0; validator=$1; shift; /usr/bin/head -c "$size" | "$validator" validate "$@")

  # One run of the validator: valid on exit 0, invalid on exit 1 (what
  # wasm-tools answers a module it refuses), and anything else (a usage
  # error, a signal, its deadline, a closed port) is no answer at all.
  defp run(validator, bytes, flags) do
    features =
      case flags do
        [] -> []
        flags -> ["--features=" <> Enum.map_join(flags, ",", &("-" <> &1))]
      end

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", @feed, Integer.to_string(byte_size(bytes)), validator | features],
        cd: "/",
        env:
          Enum.map(System.get_env(), fn {name, _value} -> {String.to_charlist(name), false} end)
      ])

    # A writer of its own: a busy port suspends the process that writes
    # to it, and the deadline below must not wait on that.
    writer = spawn(fn -> feed(port, bytes) end)
    answer = await(port, System.monotonic_time(:millisecond) + timeout_ms())
    Process.exit(writer, :kill)
    answer
  rescue
    # spawn_executable raises when the shell cannot be executed.
    ErlangError -> {:unavailable, "it could not be started"}
  end

  defp feed(port, bytes) do
    Port.command(port, bytes)
  rescue
    # The port closed first: its run answers for itself.
    ArgumentError -> :ok
  end

  defp await(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _output}} ->
        await(port, deadline)

      {^port, {:exit_status, status}} ->
        flush(port)

        case status do
          0 -> :valid
          1 -> :invalid
          status -> {:unavailable, "it ended with status #{status}"}
        end

      {:EXIT, ^port, _reason} ->
        flush(port)
        {:unavailable, "its port closed before it answered"}
    after
      remaining ->
        kill(port)
        {:unavailable, "it did not answer within #{timeout_ms()} ms and was killed"}
    end
  end

  # The shell leads a process group of its own; closing the port alone
  # leaves the group running, so the group is killed, with the shell's own
  # `kill`: the slim images carry no `kill` executable.
  defp kill(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    if os_pid do
      System.cmd("/bin/sh", ["-c", ~S(kill -9 "-$0"), Integer.to_string(os_pid)],
        env: [],
        stderr_to_stdout: true
      )
    end

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush(port)
  end

  # What the port sent before it closed, and its exit signal, stay out of
  # the checking process's mailbox.
  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
      {:EXIT, ^port, _reason} -> flush(port)
    after
      0 -> :ok
    end
  end
end
