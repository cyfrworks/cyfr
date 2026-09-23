# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Data do
  @moduledoc false
  # The one projector every public row facade and every callback Arca
  # hands a row to answers through, so no schema, changeset or Ecto
  # metadata crosses Arca's boundary.
  #
  # A schema struct becomes an atom-keyed plain map of its current fields,
  # values unchanged in convention: `DateTime`s stay `DateTime`s and an
  # encoded JSON column stays its string. `__meta__` and `__struct__` are
  # dropped. An association that was never loaded is omitted — absent, not
  # nil, so a reader cannot mistake "not read" for "no row" — and a loaded
  # one, nil included, is projected in turn.
  #
  # Lists, tuples and plain maps are walked; their keys are projected as
  # values are and never atomized. `Date`, `Time`, `NaiveDateTime`,
  # `DateTime` and `Decimal` pass unchanged. A struct the Prima contracts
  # application defines stays that struct, its fields walked. Any other
  # struct is a value Arca has no business answering, and the whole
  # projection becomes `{:error, {:unsupported_data_struct, module}}`.
  #
  # A changeset anywhere in the value becomes `{:invalid, field_errors}`:
  # field atoms to their messages, with only numeric and atom options
  # interpolated, so neither the changeset, the value it rejected nor an
  # exception leaves. Facades that already answer a conflict atom for a
  # constraint keep answering it before they project.
  #
  # Cache values and streamed `Plug.Conn` handles are opaque pass-through
  # APIs, not rows, and never run through here.

  @scalars [Date, Time, NaiveDateTime, DateTime, Decimal]

  @prima_key {__MODULE__, :prima_structs}

  @type field_errors :: %{atom() => [String.t()] | field_errors()}
  @type unsupported :: {:error, {:unsupported_data_struct, module()}}

  @doc false
  @spec project(term()) :: term() | unsupported()
  def project(value) do
    walk(value)
  catch
    {__MODULE__, :unsupported, module} -> {:error, {:unsupported_data_struct, module}}
  end

  @doc false
  @spec invalid(Ecto.Changeset.t()) :: {:invalid, field_errors()}
  def invalid(%Ecto.Changeset{} = changeset),
    do: {:invalid, Ecto.Changeset.traverse_errors(changeset, &message/1)}

  defp walk(%Ecto.Changeset{} = changeset), do: invalid(changeset)
  defp walk(%module{} = scalar) when module in @scalars, do: scalar

  defp walk(%module{} = struct) do
    cond do
      schema?(module) -> schema(struct)
      prima?(module) -> struct |> Map.to_list() |> Map.new(&contract_field/1)
      true -> throw({__MODULE__, :unsupported, module})
    end
  end

  defp walk(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {walk(key), walk(value)} end)

  defp walk([head | tail]), do: [walk(head) | walk(tail)]

  defp walk(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&walk/1) |> List.to_tuple()

  defp walk(other), do: other

  defp schema(struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Enum.reduce(%{}, fn
      {_field, %Ecto.Association.NotLoaded{}}, acc -> acc
      {field, value}, acc -> Map.put(acc, field, walk(value))
    end)
  end

  defp contract_field({:__struct__, _module} = tag), do: tag
  defp contract_field({field, value}), do: {field, walk(value)}

  defp schema?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)

  # The Prima contract structs are exactly those the contracts application
  # ships; the set is read once and kept.
  defp prima?(module) do
    case :persistent_term.get(@prima_key, nil) do
      nil ->
        set = prima_structs()
        :persistent_term.put(@prima_key, set)
        Map.has_key?(set, module)

      set ->
        Map.has_key?(set, module)
    end
  end

  defp prima_structs do
    _ = Application.load(:cyfr_contracts)

    (Application.spec(:cyfr_contracts, :modules) || [])
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__struct__, 0)))
    |> Map.new(&{&1, true})
  end

  # Only numbers and atoms are interpolated: every other option an Ecto
  # validation records (an enum, a format, a rejected value) stays out of
  # the message, and its placeholder stays literal.
  defp message({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn whole, key ->
      case Enum.find(opts, fn {name, _value} -> Atom.to_string(name) == key end) do
        {_name, value} when is_integer(value) or is_float(value) -> to_string(value)
        {_name, %Decimal{} = value} -> Decimal.to_string(value)
        {_name, value} when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
        _unsafe -> whole
      end
    end)
  end
end
