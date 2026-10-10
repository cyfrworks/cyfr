# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.LogFilterBootTest do
  @moduledoc """
  The control plane's first application start installs `Prima.LogFilter`
  ahead of Logger's translator. On a `cyfr` node a crashed server's report
  names the failed callback by arity, in the text format and in the JSON
  format a release can be configured with (`CYFR_LOG_FORMAT=json`), and so
  does a logged exception's `:crash_reason`; neither carries the message
  the server was handed nor its state.

  Each test adds a Logger handler of its own, so the module runs alone.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 2]

  @state_secret "arca-state-secret-7c41e8"
  @message_secret "arca-message-secret-2be9d3"

  defmodule Holder do
    @moduledoc false
    # A server that keeps its secret, and every message it is handed, out
    # of its own report, and logs a failed request with its stacktrace.
    use GenServer

    require Logger

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:attempt, message}, _from, state) do
      {:noreply, state} = handle_cast(message, state)
      {:reply, :ok, state}
    rescue
      error ->
        # The key Bandit and DBConnection log an exception under, for a
        # handler to read; the formatter's roster does not print it.
        # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
        Logger.error("the attempt failed", crash_reason: {error, __STACKTRACE__})
        {:reply, :failed, state}
    end

    @impl true
    def handle_cast({:expected, _value}, state), do: {:noreply, state}

    @impl true
    def format_status(status),
      do: status |> Map.replace(:message, :redacted) |> Map.replace(:state, :redacted)
  end

  test "the boot installed the log filter first, ahead of Logger's translator" do
    filters = Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))
    assert hd(filters) == :prima_log_filter
    assert index(filters, :prima_log_filter) < index(filters, :logger_translator)
  end

  for {format, opts} <- [text: [], json: [format: {Prima.JsonFormatter, :format}]] do
    test "a crashed server's report names its callback by arity, never its message or state, as #{format}" do
      {:ok, pid} = GenServer.start(Holder, %{token: @state_secret})
      ref = Process.monitor(pid)

      {events, log} =
        logged(unquote(opts), fn ->
          GenServer.cast(pid, {:unexpected, @message_secret})
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        end)

      refute_secrets(events, log)
      assert log =~ ~r"\.exs:\d+: Arca\.LogFilterBootTest\.Holder\.handle_cast/2"
    end
  end

  test "a logged exception's crash_reason names its frames by arity" do
    {:ok, pid} = GenServer.start(Holder, %{token: @state_secret})
    on_exit(fn -> Process.exit(pid, :kill) end)

    {events, log} =
      logged([], fn ->
        assert GenServer.call(pid, {:attempt, {:unexpected, @message_secret}}) == :failed
      end)

    refute_secrets(events, log)

    assert [{%FunctionClauseError{}, [{Holder, :handle_cast, 2, _} | _]}] =
             for(%{meta: %{pid: ^pid, crash_reason: reason}} <- events, do: reason)
  end

  @doc false
  def log(event, %{config: %{test: test}}), do: send(test, {:logged, event})

  # The events every handler receives at error level while `fun` runs, and
  # the text the default formatter, with `opts` over it, makes of them.
  defp logged(opts, fun) do
    id = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{level: :error, config: %{test: self()}})
    on_exit(fn -> :logger.remove_handler(id) end)

    {_result, log} = with_log(opts, fun)
    {drain(), log}
  end

  defp drain do
    receive do
      {:logged, event} -> [event | drain()]
    after
      0 -> []
    end
  end

  defp refute_secrets(events, log) do
    texts = [log | Enum.map(events, &inspect(&1, limit: :infinity, printable_limit: :infinity))]

    for text <- texts, secret <- [@state_secret, @message_secret] do
      refute text =~ secret
    end
  end

  defp index(filters, id), do: Enum.find_index(filters, &(&1 == id))
end
