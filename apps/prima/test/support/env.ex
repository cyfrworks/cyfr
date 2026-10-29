# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.Env do
  @moduledoc """
  Global test settings whose restoration is registered before they change.

  These functions run in a synchronous test or its setup. The `with_` and
  `without_` forms also restore before returning or raising. Their registered
  callback covers a killed test, which runs no `after` block.

  Application settings normally restore their captured value. The explicit
  baseline case, `restore: :unset`, deletes the setting instead. ConnCase uses
  that baseline because a captured bearer provider may belong to another test.

  Logger configuration supports `:level`, the key the suite changes, and
  restores both its effective level and whether its application setting existed.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def put_app_env(app, key, value, opts \\ []) do
    change(app_restore(app, key, opts), fn -> Application.put_env(app, key, value) end)
  end

  def with_app_env(app, key, value, fun, opts \\ []) do
    within(app_restore(app, key, opts), fn -> Application.put_env(app, key, value) end, fun)
  end

  def delete_app_env(app, key, opts \\ []) do
    change(app_restore(app, key, opts), fn -> Application.delete_env(app, key) end)
  end

  def without_app_env(app, key, fun, opts \\ []) do
    within(app_restore(app, key, opts), fn -> Application.delete_env(app, key) end, fun)
  end

  def put_system_env(key, value) do
    change(system_restore(key), fn -> System.put_env(key, value) end)
  end

  def with_system_env(key, value, fun) do
    within(system_restore(key), fn -> System.put_env(key, value) end, fun)
  end

  def delete_system_env(key) do
    change(system_restore(key), fn -> System.delete_env(key) end)
  end

  def without_system_env(key, fun) do
    within(system_restore(key), fn -> System.delete_env(key) end, fun)
  end

  def put_persistent_term(key, value) do
    change(term_restore(key), fn -> :persistent_term.put(key, value) end)
  end

  def with_persistent_term(key, value, fun) do
    within(term_restore(key), fn -> :persistent_term.put(key, value) end, fun)
  end

  def erase_persistent_term(key) do
    change(term_restore(key), fn -> :persistent_term.erase(key) end)
  end

  def without_persistent_term(key, fun) do
    within(term_restore(key), fn -> :persistent_term.erase(key) end, fun)
  end

  def configure_logger(options) do
    change(logger_restore(options), fn -> Logger.configure(options) end)
  end

  def with_logger(options, fun) do
    within(logger_restore(options), fn -> Logger.configure(options) end, fun)
  end

  defp app_restore(app, key, opts) do
    previous =
      case Keyword.get(opts, :restore, :previous) do
        :previous -> Application.fetch_env(app, key)
        :unset -> :error
      end

    fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end
  end

  defp system_restore(key) do
    previous = System.fetch_env(key)

    fn ->
      case previous do
        {:ok, value} -> System.put_env(key, value)
        :error -> System.delete_env(key)
      end
    end
  end

  defp term_restore(key) do
    absent = make_ref()
    previous = :persistent_term.get(key, absent)

    fn ->
      case previous do
        ^absent -> :persistent_term.erase(key)
        value -> :persistent_term.put(key, value)
      end
    end
  end

  defp logger_restore(options) do
    unless Keyword.keys(options) -- [:level] == [] do
      raise ArgumentError, "test logger configuration supports only :level"
    end

    level = Logger.level()
    previous = Application.fetch_env(:logger, :level)

    fn ->
      Logger.configure(level: level)

      case previous do
        :error -> Application.delete_env(:logger, :level)
        {:ok, value} -> Application.put_env(:logger, :level, value)
      end
    end
  end

  defp change(restore, mutate) do
    on_exit(restore)
    mutate.()
  end

  defp within(restore, mutate, fun) do
    on_exit(restore)

    try do
      mutate.()
      fun.()
    after
      restore.()
    end
  end
end
