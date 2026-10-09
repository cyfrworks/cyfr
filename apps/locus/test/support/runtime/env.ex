# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Test.Env do
  @moduledoc """
  A test's change to one setting of the runtime role, which lives in one
  keyword, `config :locus, :runtime`: setting the whole keyword would drop
  every other setting the suite runs with (the key, the keeper, the direct
  keeper). Each change answers the keyword as it was, which `restore/2`
  puts back, whole or for the keys the change named: two changes that end
  in either order then each put back only their own keys. A test that
  changes it runs synchronously.
  """

  @doc "Set `key` to `value`, answering the keyword before the change."
  @spec put(atom(), term()) :: keyword()
  def put(key, value) when is_atom(key), do: change(&Keyword.put(&1, key, value))

  @doc "Remove `key`, answering the keyword before the change."
  @spec delete(atom()) :: keyword()
  def delete(key) when is_atom(key), do: change(&Keyword.delete(&1, key))

  @doc "Set every key of `settings`, answering the keyword before the change."
  @spec merge(keyword()) :: keyword()
  def merge(settings) when is_list(settings), do: change(&Keyword.merge(&1, settings))

  @doc """
  Put back a keyword a change answered: whole, or only `keys`, each as it
  was there (set to its value, or removed where it was absent).
  """
  @spec restore(keyword(), :all | [atom()]) :: :ok
  def restore(previous, keys \\ :all)

  def restore(previous, :all) when is_list(previous),
    do: Application.put_env(:locus, :runtime, previous)

  def restore(previous, keys) when is_list(previous) and is_list(keys) do
    _ =
      change(fn current ->
        Enum.reduce(keys, current, fn key, acc ->
          case Keyword.fetch(previous, key) do
            {:ok, value} -> Keyword.put(acc, key, value)
            :error -> Keyword.delete(acc, key)
          end
        end)
      end)

    :ok
  end

  defp change(fun) do
    previous = Locus.Runtime.Settings.env()
    Application.put_env(:locus, :runtime, fun.(previous))
    previous
  end
end
