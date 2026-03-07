defmodule Opus.CronParser do
  @moduledoc """
  Pure functional cron expression parser.

  Supports standard 5-field cron expressions: minute hour dom month dow.
  Fields support: `*`, ranges (`1-5`), steps (`*/15`), lists (`1,3,5`), specific values.
  """

  defstruct [:minute, :hour, :dom, :month, :dow]

  @type t :: %__MODULE__{
          minute: [non_neg_integer()],
          hour: [non_neg_integer()],
          dom: [non_neg_integer()],
          month: [non_neg_integer()],
          dow: [non_neg_integer()]
        }

  @ranges %{
    minute: {0, 59},
    hour: {0, 23},
    dom: {1, 31},
    month: {1, 12},
    dow: {0, 6}
  }

  @doc """
  Parses a cron expression string into a `%CronExpr{}` struct.

  Returns `{:ok, expr}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(expr) when is_binary(expr) do
    case String.split(String.trim(expr)) do
      [min, hour, dom, month, dow] ->
        with {:ok, min_vals} <- parse_field(min, :minute),
             {:ok, hour_vals} <- parse_field(hour, :hour),
             {:ok, dom_vals} <- parse_field(dom, :dom),
             {:ok, month_vals} <- parse_field(month, :month),
             {:ok, dow_vals} <- parse_field(dow, :dow) do
          {:ok,
           %__MODULE__{
             minute: min_vals,
             hour: hour_vals,
             dom: dom_vals,
             month: month_vals,
             dow: dow_vals
           }}
        end

      _ ->
        {:error, "Expected 5 fields (minute hour dom month dow), got: #{expr}"}
    end
  end

  @doc """
  Returns true if the cron expression string is valid.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(expr) do
    match?({:ok, _}, parse(expr))
  end

  @doc """
  Computes the minimum interval in seconds between consecutive runs.

  Returns `{:ok, seconds}` or `{:error, reason}`.
  """
  @spec min_interval_seconds(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def min_interval_seconds(expr) do
    with {:ok, parsed} <- parse(expr) do
      # Use a reference time and compute two consecutive runs
      ref = ~U[2025-01-01 00:00:00Z]

      case next_run(parsed, ref) do
        {:ok, first} ->
          case next_run(parsed, first) do
            {:ok, second} -> {:ok, DateTime.diff(second, first)}
            error -> error
          end

        error ->
          error
      end
    end
  end

  @doc """
  Given a parsed cron expression and a reference DateTime, returns the next fire time.

  Searches up to 4 years ahead before giving up.
  """
  @spec next_run(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, String.t()}
  def next_run(%__MODULE__{} = cron, %DateTime{} = from) do
    # Start from the next minute
    next = DateTime.add(from, 60, :second)
    {:ok, candidate} = DateTime.new(
      Date.new!(next.year, next.month, next.day),
      Time.new!(next.hour, next.minute, 0, {0, 6}),
      "Etc/UTC"
    )

    max_dt = DateTime.add(from, 4 * 365 * 86_400, :second)
    find_next(cron, candidate, max_dt)
  end

  defp find_next(cron, candidate, max_dt) do
    if DateTime.compare(candidate, max_dt) == :gt do
      {:error, "No matching time found within 4 years"}
    else
      do_find_next(cron, candidate, max_dt)
    end
  end

  defp do_find_next(cron, candidate, max_dt) do
    cond do
      candidate.month not in cron.month ->
        # Advance to first valid month
        find_next(cron, advance_month(candidate), max_dt)

      candidate.day not in cron.dom or day_of_week(candidate) not in cron.dow ->
        # Advance to next day
        find_next(cron, advance_day(candidate), max_dt)

      candidate.hour not in cron.hour ->
        # Advance to next valid hour
        find_next(cron, advance_hour(candidate), max_dt)

      candidate.minute not in cron.minute ->
        # Advance to next valid minute
        find_next(cron, advance_minute(candidate), max_dt)

      true ->
        {:ok, candidate}
    end
  end

  defp advance_month(dt) do
    {year, month} = if dt.month == 12, do: {dt.year + 1, 1}, else: {dt.year, dt.month + 1}
    {:ok, new_dt} = DateTime.new(Date.new!(year, month, 1), ~T[00:00:00.000000], "Etc/UTC")
    new_dt
  end

  defp advance_day(dt) do
    date = Date.add(Date.new!(dt.year, dt.month, dt.day), 1)
    {:ok, new_dt} = DateTime.new(date, ~T[00:00:00.000000], "Etc/UTC")
    new_dt
  end

  defp advance_hour(dt) do
    DateTime.add(dt, 3600, :second)
    |> then(fn d ->
      {:ok, new_dt} = DateTime.new(Date.new!(d.year, d.month, d.day), Time.new!(d.hour, 0, 0, {0, 6}), "Etc/UTC")
      new_dt
    end)
  end

  defp advance_minute(dt) do
    DateTime.add(dt, 60, :second)
    |> then(fn d ->
      {:ok, new_dt} = DateTime.new(Date.new!(d.year, d.month, d.day), Time.new!(d.hour, d.minute, 0, {0, 6}), "Etc/UTC")
      new_dt
    end)
  end

  defp day_of_week(dt) do
    Date.day_of_week(dt) |> rem(7)
  end

  # Field parsing

  defp parse_field(field, name) do
    {min, max} = @ranges[name]

    field
    |> String.split(",")
    |> Enum.reduce_while([], fn part, acc ->
      case parse_part(String.trim(part), min, max) do
        {:ok, values} -> {:cont, acc ++ values}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      values when is_list(values) -> {:ok, Enum.sort(Enum.uniq(values))}
    end
  end

  defp parse_part("*", min, max), do: {:ok, Enum.to_list(min..max)}

  defp parse_part("*/" <> step_str, min, max) do
    case Integer.parse(step_str) do
      {step, ""} when step > 0 ->
        {:ok, Enum.take_every(Enum.to_list(min..max), step)}

      _ ->
        {:error, "Invalid step: */#{step_str}"}
    end
  end

  defp parse_part(part, min, max) do
    cond do
      String.contains?(part, "/") ->
        case String.split(part, "/", parts: 2) do
          [range_str, step_str] ->
            with {:ok, range_values} <- parse_range(range_str, min, max),
                 {step, ""} when step > 0 <- Integer.parse(step_str) do
              {:ok, Enum.take_every(range_values, step)}
            else
              _ -> {:error, "Invalid range/step: #{part}"}
            end

          _ ->
            {:error, "Invalid field: #{part}"}
        end

      String.contains?(part, "-") ->
        parse_range(part, min, max)

      true ->
        case Integer.parse(part) do
          {val, ""} when val >= min and val <= max ->
            {:ok, [val]}

          {val, ""} ->
            {:error, "Value #{val} out of range #{min}-#{max}"}

          _ ->
            {:error, "Invalid value: #{part}"}
        end
    end
  end

  defp parse_range(range_str, min, max) do
    case String.split(range_str, "-", parts: 2) do
      [from_str, to_str] ->
        with {from, ""} <- Integer.parse(from_str),
             {to, ""} <- Integer.parse(to_str) do
          if from >= min and to <= max and from <= to do
            {:ok, Enum.to_list(from..to)}
          else
            {:error, "Range #{from}-#{to} out of bounds #{min}-#{max}"}
          end
        else
          _ -> {:error, "Invalid range: #{range_str}"}
        end

      _ ->
        {:error, "Invalid range: #{range_str}"}
    end
  end
end
