# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.LogFilter do
  @moduledoc """
  The primary Logger filter every node installs, and the formatter every
  caller that writes an exception into text uses, so that no stack frame
  or call in a log carries the argument values of its call.

  A function-clause, argument or undefined-function error records the
  failed call's arguments in the top frame of its stacktrace. OTP attaches
  that stacktrace to a process's crash report outside its
  `format_status/1`, so a GenServer's frame holds the message it was
  handed and its whole state, and Elixir's translator prints both. An
  exit out of a call names the call, `{reason, {module, function, args}}`,
  so a process that crashed on a `GenServer.call/3` it made carries the
  request it sent, and a task has no `format_status/1` at all. A call of a
  function with the wrong number of arguments raises with them,
  `{:badarity, {fun, args}}`.

  The filter reduces every frame whose arguments are a list,
  `{module, function, args, location}` or `{fun, args, location}`, to its
  arity, and every pair whose second element is a call with arguments,
  `{term, {module, function, args}}` with `args` no stacktrace, to
  `{term, {module, function, arity}}`, which also covers an
  `:initial_call` or `:mfargs` entry; a crashed task's `args` become their
  count, and a bad arity's arguments, raw or in a `BadArityError`, become
  as many `:redacted`, so its message still reads. Module, function, arity
  and location stay. It does so wherever the event holds a term: in the
  report, in the format arguments, and in every metadata value,
  `:crash_reason` among them. An event with nothing to reduce passes as it
  came.

  `format_exception/3`, `format_stacktrace/1`, `exception_message/1` and
  `inspect_reason/2` apply the same rule before formatting, so text a
  caller logs, records or answers of an exception, its message, a
  stacktrace or a caught exit or crash reason carries no argument either.
  `Cyfr.LoggerRosterTest` holds every other `Exception` formatter out of
  the applications' code, every `inspect/1,2` of a reason a clause binds
  as caught, rescued, exited or terminated, there or in a function of the
  same file it is handed to, and every `Exception.message/1` of an
  exception a clause rescues whatever its kind.

  The filter must see the event before Elixir's translator formats the
  report into text. Logger installs its translator as a primary filter
  when its application starts, and a primary filter added later runs
  earlier, so each node installs this one from its first application
  start, before any process of the node holds a secret: `Arca.Supervisor`
  on the control plane, `Opus.Application` in either role, and
  `Locus.Application`. A `Cyfr.Release` task, which runs where no
  application starts, installs it too.

  None of them reaches a value an exception's reason carries outside a
  frame or a call (a `MatchError`'s term), nor text formatted any other
  way.
  """

  @id :prima_log_filter

  @doc """
  Install the filter ahead of every primary filter installed before it.
  Installed already, it stays where it is.
  """
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @id}} -> :ok
    end
  end

  @doc """
  The filter: `event` with every frame's and every call's arguments
  reduced to their arity, or `event` itself when it holds none.

  Logger removes a filter that raises and then passes every event whole,
  so an event this filter cannot read is dropped instead.
  """
  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(event, _extra) do
    %{msg: msg, meta: meta} = event
    reduced = message(msg)
    reduced_meta = redact(meta)

    if reduced === msg and reduced_meta === meta,
      do: event,
      else: %{event | msg: reduced, meta: reduced_meta}
  catch
    _kind, _reason -> :stop
  end

  @doc """
  `kind`, `reason` and `stacktrace` as `Exception.format/3` writes them,
  every frame and every call reduced to its arity first. With no
  stacktrace it is `Exception.format_banner/2`'s text.
  """
  @spec format_exception(Exception.kind(), term(), Exception.stacktrace()) :: String.t()
  def format_exception(kind, reason, stacktrace \\ []),
    do: Exception.format(kind, redact(reason), redact(stacktrace))

  @doc """
  `stacktrace` as `Exception.format_stacktrace/1` writes it, every frame
  reduced to its arity first.
  """
  @spec format_stacktrace(Exception.stacktrace()) :: String.t()
  def format_stacktrace(stacktrace), do: Exception.format_stacktrace(redact(stacktrace))

  @doc """
  A rescued exception's message as `Exception.message/1` writes it, a bad
  arity's arguments counted first.
  """
  @spec exception_message(Exception.t()) :: String.t()
  def exception_message(exception), do: Exception.message(redact(exception))

  @doc """
  A caught exit, crash or `:DOWN` reason, or a rescued exception, as
  `inspect/2` writes it, every frame and every call reduced to its arity
  first.
  """
  @spec inspect_reason(term(), keyword()) :: String.t()
  def inspect_reason(reason, opts \\ []), do: inspect(redact(reason), opts)

  defp message({:string, _chardata} = string), do: string
  defp message({:report, report} = msg), do: kept(msg, 2, report)
  defp message({_format, args} = msg) when is_list(args), do: kept(msg, 2, args)

  # Each walk below returns the term it was given when nothing in it was
  # reduced, so an event with no frame is neither copied nor rebuilt; `===`
  # on the same term answers at once.
  defp redact([_ | _] = list) do
    if frames?(list), do: frames(list), else: elements(list)
  end

  # A call's arguments are never a stacktrace: `{class, reason, stacktrace}`
  # has a call's shape, and its frames are reduced as frames.
  defp redact({term, {module, function, [_ | _] = args}} = pair)
       when is_atom(module) and is_atom(function) do
    if frames?(args),
      do: elements_of(pair, 2),
      else: {redact(term), {module, function, arity(args)}}
  end

  defp redact({:badarity, {fun, args}}) when is_function(fun) and is_list(args),
    do: {:badarity, {fun, placeholders(args)}}

  defp redact(tuple) when is_tuple(tuple), do: elements_of(tuple, tuple_size(tuple))

  defp redact(%BadArityError{args: args} = error) when is_list(args),
    do: %{error | args: placeholders(args)}

  defp redact(%{label: {Task.Supervisor, :terminating}, report: %{args: args} = report} = task)
       when is_list(args),
       do: %{task | report: redact(%{report | args: arity(args)})}

  # Any map, a struct's fields included, whatever it would enumerate as.
  defp redact(map) when is_map(map) do
    :maps.fold(
      fn key, value, acc ->
        reduced = redact(value)
        if reduced === value, do: acc, else: Map.put(acc, key, reduced)
      end,
      map,
      map
    )
  end

  defp redact(other), do: other

  # The tuple with its elements from the `index`th (1-based) down reduced.
  defp elements_of(tuple, 0), do: tuple

  defp elements_of(tuple, index),
    do: tuple |> kept(index, elem(tuple, index - 1)) |> elements_of(index - 1)

  defp kept(tuple, index, element), do: kept(tuple, index, element, redact(element))
  defp kept(tuple, _index, element, element), do: tuple
  defp kept(tuple, index, _element, reduced), do: put_elem(tuple, index - 1, reduced)

  # A list's elements, its improper tail included; a sublist is checked
  # for frames once, as the list it is, never again as a tail.
  defp elements([head | tail] = list), do: cons(list, redact(head), elements(tail))
  defp elements([]), do: []
  defp elements(tail), do: redact(tail)

  defp frames([head | tail] = list), do: cons(list, frame(head), frames(tail))
  defp frames([]), do: []

  defp cons([head | tail] = list, head, tail), do: list
  defp cons(_list, head, tail), do: [head | tail]

  # A stacktrace: a proper list of frames and nothing else.
  defp frames?([frame]), do: frame?(frame)
  defp frames?([frame | rest]), do: frame?(frame) and frames?(rest)
  defp frames?(_other), do: false

  defp frame?({module, function, args_or_arity, location})
       when is_atom(module) and is_atom(function) and
              (is_list(args_or_arity) or is_integer(args_or_arity)) and is_list(location),
       do: true

  defp frame?({fun, args_or_arity, location})
       when is_function(fun) and (is_list(args_or_arity) or is_integer(args_or_arity)) and
              is_list(location),
       do: true

  defp frame?(_other), do: false

  defp frame({module, function, args, location}) when is_list(args),
    do: {module, function, arity(args), location}

  defp frame({fun, args, location}) when is_list(args), do: {fun, arity(args), location}
  defp frame(frame), do: frame

  # As many `:redacted` as `args` has cells, for a message that lists them.
  defp placeholders(args), do: List.duplicate(:redacted, arity(args))

  # Counted by its cells, so an improper list is counted, never raised on.
  defp arity(args), do: arity(args, 0)
  defp arity([_ | rest], count), do: arity(rest, count + 1)
  defp arity(_tail, count), do: count
end
