# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LogFilterTest do
  @moduledoc """
  No log event carries a call's arguments (`Prima.LogFilter`): a crashed
  server, a logged exception, a crashed task, a crashed plain process, a
  server and a task that crashed on a call they made, and a server that
  applied a function to too many arguments each name their frames and
  calls by arity, through Logger's own translator; every crash report
  shape OTP writes is reduced the same way, and an event with nothing to
  reduce passes as it came. The text the formatters write of an
  exception, an exit, a stacktrace or a caught reason carries no argument
  either.

  The filter is a primary filter, so this module runs alone and leaves it
  installed only if a node's boot had installed it already.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Prima.LogFilter

  @state_secret "state-secret-5e1d0c"
  @message_secret "message-secret-90ab4f"

  defmodule Holder do
    @moduledoc false
    # A server holding a secret that keeps it, and every message it is
    # handed, out of its own report, as a secret-holding server does.
    use GenServer

    require Logger

    @impl true
    def init(state), do: {:ok, state}

    # A request it outlives: the failure is logged with its stacktrace.
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

    # A function it applies to two arguments: one of arity 1 ends it.
    def handle_cast({:apply, fun, value}, state) do
      fun.(value, :extra)
      {:noreply, state}
    end

    # A call it makes on a cast: a target that never answers ends it.
    def handle_cast({:relay, target, value}, state) do
      GenServer.call(target, {:put, value}, 50)
      {:noreply, state}
    end

    @impl true
    def format_status(status),
      do: status |> Map.replace(:message, :redacted) |> Map.replace(:state, :redacted)
  end

  setup_all do
    installed? = :prima_log_filter in primary_filters()
    :ok = LogFilter.install()

    on_exit(fn ->
      if not installed?, do: :logger.remove_primary_filter(:prima_log_filter)
    end)
  end

  describe "through Logger's translator" do
    test "a server's function-clause crash names its callback by arity, never its message or state" do
      {pid, events, log} = logged(fn -> crash(Holder, {:unexpected, @message_secret}) end)

      assert log =~ "no function clause matching in Prima.LogFilterTest.Holder.handle_cast/2"
      assert log =~ ~r"log_filter_test\.exs:\d+: Prima\.LogFilterTest\.Holder\.handle_cast/2\n"

      assert [{:function_clause, [{Holder, :handle_cast, 2, [_ | _]} | _]}] =
               for(
                 %{msg: {:report, %{label: {:gen_server, :terminate}, name: ^pid} = report}} <-
                   events,
                 do: report.reason
               )

      refute_secrets(events, log)
    end

    test "a logged exception's crash_reason names its frames by arity" do
      {:ok, pid} = GenServer.start(Holder, %{token: @state_secret})
      on_exit(fn -> Process.exit(pid, :kill) end)

      {:failed, events, log} =
        logged(fn -> GenServer.call(pid, {:attempt, {:unexpected, @message_secret}}) end)

      assert log =~ "the attempt failed"

      assert [{%FunctionClauseError{}, stacktrace}] =
               for(%{meta: %{pid: ^pid, crash_reason: reason}} <- events, do: reason)

      assert [{Holder, :handle_cast, 2, [_ | _]}, {Holder, :handle_call, 3, _} | _] = stacktrace
      refute_secrets(events, log)
    end

    test "a crashed task's start arguments are counted" do
      {task, events, log} =
        logged(fn ->
          {:ok, task} = Task.start(__MODULE__, :fail, [@message_secret])
          ref = Process.monitor(task)
          assert_receive {:DOWN, ^ref, :process, ^task, _reason}
          task
        end)

      assert log =~ "Function: &Prima.LogFilterTest.fail/1\n    Args: 1"

      assert [1] =
               for(%{msg: {:report, %{report: %{name: ^task, args: args}}}} <- events, do: args)

      refute_secrets(events, log)
    end

    test "a plain process's argument error names the call by arity" do
      record!()
      {pid, ref} = spawn_monitor(fn -> String.to_existing_atom(@message_secret) end)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # The VM reports a plain process's error through Logger's proxy once
      # the process is gone, so the event is awaited. Logger's translator
      # has made it text, and the reason it read is its crash_reason.
      event = await_event(&raised?(&1, pid))
      assert {:string, text} = event.msg
      assert IO.chardata_to_string(text) =~ ~r":erlang\.binary_to_existing_atom/\d"

      assert {%ArgumentError{}, [{:erlang, :binary_to_existing_atom, arity, _location} | _]} =
               event.meta.crash_reason

      assert is_integer(arity)

      refute_secrets([event | drain()], IO.chardata_to_string(text))
    end

    test "a server that crashed on a call it made names the call by arity" do
      target = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(target, :kill) end)

      {pid, events, log} = logged(fn -> crash(Holder, {:relay, target, @message_secret}) end)

      assert [{{:timeout, {GenServer, :call, 3}}, [_ | _]}] =
               for(
                 %{msg: {:report, %{label: {:gen_server, :terminate}, name: ^pid} = report}} <-
                   events,
                 do: report.reason
               )

      refute_secrets(events, log)
    end

    test "a server that applied a function to too many arguments names them by count" do
      {pid, events, log} =
        logged(fn -> crash(Holder, {:apply, fn value -> value end, @message_secret}) end)

      assert log =~ "called with 2 arguments (:redacted, :redacted)"

      assert [{{:badarity, {_fun, [:redacted, :redacted]}}, [_ | _]}] =
               for(
                 %{msg: {:report, %{label: {:gen_server, :terminate}, name: ^pid} = report}} <-
                   events,
                 do: report.reason
               )

      refute_secrets(events, log)
    end

    test "a task that crashed on a call it made names the call by arity" do
      target = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(target, :kill) end)

      {task, events, log} =
        logged(fn ->
          {:ok, task} = Task.start(fn -> GenServer.call(target, {:put, @message_secret}, 50) end)
          ref = Process.monitor(task)
          assert_receive {:DOWN, ^ref, :process, ^task, _reason}
          task
        end)

      assert [{{:timeout, {GenServer, :call, 3}}, [_ | _]}] =
               for(
                 %{msg: {:report, %{report: %{name: ^task} = report}}} <- events,
                 do: report.reason
               )

      refute_secrets(events, log)
    end
  end

  describe "every report shape" do
    @frame {Holder, :handle_cast, [{:unexpected, @message_secret}, %{token: @state_secret}],
            [file: ~c"lib/holder.ex", line: 7]}
    @reduced {Holder, :handle_cast, 2, [file: ~c"lib/holder.ex", line: 7]}
    @outer {:gen_server, :try_handle_cast, 3, [file: ~c"gen_server.erl", line: 2460]}

    test "a gen_server's terminate reason and its client's stacktrace" do
      report = %{
        label: {:gen_server, :terminate},
        name: self(),
        last_message: :redacted,
        state: :redacted,
        log: [],
        reason: {:function_clause, [@frame, @outer]},
        client_info: {self(), {self(), [@frame]}},
        process_label: :undefined
      }

      assert %{msg: {:report, reduced}} = filter(report)
      assert reduced.reason == {:function_clause, [@reduced, @outer]}
      assert reduced.client_info == {self(), {self(), [@reduced]}}
    end

    test "a gen_statem's terminate reason" do
      report = %{label: {:gen_statem, :terminate}, reason: {:error, :function_clause, [@frame]}}

      assert %{msg: {:report, %{reason: {:error, :function_clause, [@reduced]}}}} = filter(report)
    end

    test "a proc_lib crash report's error and initial call" do
      crashed = [
        initial_call: {Holder, :init, [:Argument__1]},
        pid: self(),
        registered_name: [],
        error_info: {:error, :function_clause, [@frame]},
        dictionary: []
      ]

      assert %{msg: {:report, %{report: [reduced, []]}}} =
               filter(%{label: {:proc_lib, :crash}, report: [crashed, []]})

      assert reduced[:initial_call] == {Holder, :init, 1}
      assert reduced[:error_info] == {:error, :function_clause, [@reduced]}
    end

    test "a supervisor report's child start call and exit reason" do
      report = [
        supervisor: {:local, Holder.Supervisor},
        errorContext: :child_terminated,
        reason: {:function_clause, [@frame]},
        offender: [pid: self(), id: Holder, mfargs: {Holder, :start_link, [@state_secret]}]
      ]

      assert %{msg: {:report, %{report: reduced}}} =
               filter(%{label: {:supervisor, :child_terminated}, report: report})

      assert reduced[:reason] == {:function_clause, [@reduced]}
      assert reduced[:offender][:mfargs] == {Holder, :start_link, 1}
    end

    test "a class, a reason and a stacktrace are no call" do
      crashed = [error_info: {:error, :function_clause, [@frame]}, exited: {:exit, :killed, []}]

      assert %{msg: {:report, %{report: reduced}}} = filter(%{report: crashed})

      assert reduced == [
               error_info: {:error, :function_clause, [@reduced]},
               exited: {:exit, :killed, []}
             ]
    end

    test "the call an exit names" do
      reason =
        {{:timeout, {GenServer, :call, [self(), {:put, @message_secret}, 5_000]}}, [@frame]}

      assert %{msg: {:report, %{reason: {{:timeout, {GenServer, :call, 3}}, [@reduced]}}}} =
               filter(%{reason: reason})
    end

    test "a bad arity's arguments, raw or in its exception" do
      fun = fn _value -> :ok end
      error = %BadArityError{function: fun, args: [@message_secret, :extra]}

      event = %{
        level: :error,
        msg: {:report, %{reason: {{:badarity, {fun, [@message_secret, :extra]}}, [@frame]}}},
        meta: %{crash_reason: {error, [@frame]}}
      }

      assert %{msg: {:report, %{reason: reason}}, meta: %{crash_reason: crash_reason}} =
               LogFilter.filter(event, [])

      assert reason == {{:badarity, {fun, [:redacted, :redacted]}}, [@reduced]}
      assert crash_reason == {%{error | args: [:redacted, :redacted]}, [@reduced]}
    end

    test "a frame of an anonymous function" do
      fun = fn _value -> :ok end
      reason = {:badarity, [{fun, [@message_secret], []}]}

      assert %{msg: {:report, %{reason: {:badarity, [{^fun, 1, []}]}}}} =
               filter(%{reason: reason})
    end

    test "format arguments and every metadata value" do
      event = %{
        level: :error,
        msg: {~c"Error in process ~p with exit value:~n~p~n", [self(), {:badarg, [@frame]}]},
        meta: %{crash_reason: {:function_clause, [@frame]}, stack: [@frame], pid: self()}
      }

      assert %{msg: {_format, [_pid, {:badarg, [@reduced]}]}, meta: meta} =
               LogFilter.filter(event, [])

      assert meta == %{
               crash_reason: {:function_clause, [@reduced]},
               stack: [@reduced],
               pid: self()
             }
    end

    test "text, a list that is not a stacktrace and an improper list pass whole" do
      text = %{level: :error, msg: {:string, ["formatted ", "text"]}, meta: %{}}
      assert LogFilter.filter(text, []) == text

      frame = {Holder, :handle_cast, [:value], []}

      lists = %{
        not_frames: [frame, :not_a_frame],
        improper: [frame | frame],
        struct: %URI{host: "example.test", path: "/"}
      }

      assert %{msg: {:report, ^lists}} = filter(lists)
    end

    test "an event with nothing to reduce passes as it came" do
      event = %{
        level: :error,
        msg:
          {:report,
           %{
             label: {:gen_server, :terminate},
             reason: {:shutdown, [{:a, :b, 1, []}]},
             state: %{set: MapSet.new([1, 2]), range: 1..3, uri: %URI{host: "example.test"}},
             log: [{:in, :tick} | :tail]
           }},
        meta: %{pid: self(), mfa: {__MODULE__, :test, 1}, crash_reason: {:normal, []}}
      }

      assert :erts_debug.same(LogFilter.filter(event, []), event)

      text = %{level: :error, msg: {~c"~p", [{:ok, 1}]}, meta: %{}}
      assert :erts_debug.same(LogFilter.filter(text, []), text)
    end

    test "an event it cannot read is dropped" do
      assert LogFilter.filter(%{msg: {:report, %{}}}, []) == :stop
      assert LogFilter.filter(:not_an_event, []) == :stop
    end
  end

  describe "the formatters" do
    test "an exception's text names its frames by arity, never their arguments" do
      {error, stacktrace} =
        try do
          apply(Holder, :handle_cast, [{:unexpected, @message_secret}, %{token: @state_secret}])
        rescue
          error -> {error, __STACKTRACE__}
        end

      # What Exception.format/3 writes of the same failure.
      assert Exception.format(:error, error, stacktrace) =~ @message_secret

      text = LogFilter.format_exception(:error, error, stacktrace)

      assert text =~
               "** (FunctionClauseError) no function clause matching in " <>
                 "Prima.LogFilterTest.Holder.handle_cast/2"

      assert text =~ ~r"log_filter_test\.exs:\d+: Prima\.LogFilterTest\.Holder\.handle_cast/2\n"
      refute_secrets([], text)
    end

    test "an exit's text names its call by arity" do
      reason = {:timeout, {GenServer, :call, [self(), {:put, @message_secret}, 5_000]}}
      assert Exception.format(:exit, reason) =~ @message_secret

      text = LogFilter.format_exception(:exit, reason)
      assert text =~ "{GenServer, :call, 3}"
      refute_secrets([], text)
    end

    test "a caught reason's text names its frames and calls by arity" do
      exit = {:timeout, {GenServer, :call, [self(), {:put, @message_secret}, 5_000]}}
      crash = {:function_clause, [@frame, @outer]}

      for reason <- [exit, crash] do
        assert inspect(reason) =~ @message_secret
        refute_secrets([], LogFilter.inspect_reason(reason))
      end

      assert LogFilter.inspect_reason(exit) =~ "{GenServer, :call, 3}"
      assert LogFilter.inspect_reason(crash) =~ "Prima.LogFilterTest.Holder, :handle_cast, 2,"
      assert LogFilter.inspect_reason(crash, limit: 1) == inspect(crash, limit: 1)
    end

    test "a bad arity's text counts its arguments" do
      error = %BadArityError{function: fn _value -> :ok end, args: [@message_secret, :extra]}
      assert Exception.message(error) =~ @message_secret

      text = LogFilter.format_exception(:error, error)
      assert text =~ "called with 2 arguments (:redacted, :redacted)"
      refute_secrets([], text)
      refute_secrets([], LogFilter.inspect_reason(error))

      message = LogFilter.exception_message(error)
      assert message =~ "called with 2 arguments (:redacted, :redacted)"
      refute_secrets([], message)

      other = %ArgumentError{message: "an argument was refused"}
      assert LogFilter.exception_message(other) == Exception.message(other)
    end

    test "with no stacktrace the text is the banner" do
      error = %RuntimeError{message: "the task failed"}
      assert LogFilter.format_exception(:error, error) == Exception.format_banner(:error, error)

      assert LogFilter.format_exception(:throw, :thrown) ==
               Exception.format_banner(:throw, :thrown)
    end

    test "a stacktrace's text names each frame by arity" do
      assert Exception.format_stacktrace([@frame, @outer]) =~ @message_secret

      text = LogFilter.format_stacktrace([@frame, @outer])
      assert text =~ "lib/holder.ex:7: Prima.LogFilterTest.Holder.handle_cast/2\n"
      assert text =~ ":gen_server.try_handle_cast/3"
      refute_secrets([], text)
    end
  end

  test "the filter runs first, ahead of Logger's translator, installed once" do
    filters = primary_filters()
    assert hd(filters) == :prima_log_filter
    assert index(filters, :prima_log_filter) < index(filters, :logger_translator)

    assert :ok = LogFilter.install()
    assert primary_filters() == filters
  end

  @doc false
  def fail(_value), do: raise(ArgumentError, "the task failed")

  # A Logger handler: every event a handler receives, sent to the test.
  @doc false
  def log(event, %{config: %{test: test}}), do: send(test, {:logged, event})

  # Every event a handler receives at error level, from here to the end
  # of the test, is sent to the test.
  defp record! do
    id = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, __MODULE__, %{level: :error, config: %{test: self()}})
    on_exit(fn -> :logger.remove_handler(id) end)
  end

  # What `fun` returns, the events every handler receives while it runs,
  # at error level, and the text Logger's default formatter makes of them.
  defp logged(fun) do
    record!()
    {result, log} = with_log(fun)
    {result, drain(), log}
  end

  defp await_event(match?) do
    receive do
      {:logged, event} -> if match?.(event), do: event, else: await_event(match?)
    after
      5_000 -> flunk("no such event was logged")
    end
  end

  defp drain do
    receive do
      {:logged, event} -> [event | drain()]
    after
      0 -> []
    end
  end

  # The server's pid, once it has crashed on `message`.
  defp crash(server, message) do
    {:ok, pid} = GenServer.start(server, %{token: @state_secret})
    ref = Process.monitor(pid)
    GenServer.cast(pid, message)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  # Whether the event is the VM's report of `pid`'s error, by the text
  # Logger's translator made of it.
  defp raised?(%{msg: {:string, text}}, pid),
    do: IO.chardata_to_string(text) =~ "Process #{inspect(pid)} raised an exception"

  defp raised?(_event, _pid), do: false

  defp refute_secrets(events, log) do
    texts = [log | Enum.map(events, &inspect(&1, limit: :infinity, printable_limit: :infinity))]

    for text <- texts, secret <- [@state_secret, @message_secret] do
      refute text =~ secret
    end
  end

  defp filter(report),
    do: LogFilter.filter(%{level: :error, msg: {:report, report}, meta: %{}}, [])

  defp primary_filters, do: Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))

  defp index(filters, id), do: Enum.find_index(filters, &(&1 == id))
end
