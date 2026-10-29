# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.Test.EnvTest do
  use ExUnit.Case, async: false

  alias Prima.Test.Env

  @operations [
    :app_put,
    :app_delete,
    :system_put,
    :system_delete,
    :term_put,
    :term_erase,
    :logger
  ]
  @system_key "PRIMA_TEST_ENV_VALUE"
  @term_key {__MODULE__, :value}

  for operation <- @operations do
    test "#{operation} restores at the test's exit" do
      operation = unquote(operation)
      seed(operation)
      previous = read(operation)
      on_exit(fn -> assert read(operation) == previous end)
      mutate(operation)
      assert read(operation) == changed(operation)
    end

    test "#{operation} restores before a call returns" do
      operation = unquote(operation)
      seed(operation)
      previous = read(operation)

      assert within(operation, fn ->
               assert read(operation) == changed(operation)
               :returned
             end) == :returned

      assert read(operation) == previous
    end

    test "#{operation} restores when a call raises" do
      operation = unquote(operation)
      seed(operation)
      previous = read(operation)

      assert_raise RuntimeError, "inside", fn ->
        within(operation, fn ->
          assert read(operation) == changed(operation)
          raise "inside"
        end)
      end

      assert read(operation) == previous
    end

    for scope <- [:test, :call] do
      test "#{operation} #{scope} scope refuses mutation when restoration cannot be registered" do
        operation = unquote(operation)
        seed(operation)
        previous = read(operation)
        parent = self()

        {pid, monitor} =
          spawn_monitor(fn ->
            result =
              try do
                case unquote(scope) do
                  :test -> mutate(operation)
                  :call -> within(operation, fn -> send(parent, :entered) end)
                end

                :accepted
              rescue
                error in ArgumentError -> {:refused, error}
              end

            send(parent, {self(), result})
          end)

        assert_receive {^pid, {:refused, %ArgumentError{}}}, 2_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
        refute_received :entered
        assert read(operation) == previous
      end
    end
  end

  for operation <- [:app_put, :system_put, :term_put] do
    test "#{operation} deletes an absent previous value at exit and after a call" do
      operation = unquote(operation)
      clear(operation)
      on_exit(fn -> assert read(operation) == :error end)

      within(operation, fn -> assert read(operation) == changed(operation) end)
      assert read(operation) == :error
      mutate(operation)
    end
  end

  for operation <- [:app_put, :term_put] do
    test "#{operation} preserves a present nil" do
      operation = unquote(operation)
      mutate(operation)
      assert read(operation) == {:ok, nil}
      on_exit(fn -> assert read(operation) == {:ok, nil} end)
      within(delete_operation(operation), fn -> assert read(operation) == :error end)
      assert read(operation) == {:ok, nil}
      mutate(delete_operation(operation))
    end
  end

  test "the explicit unset baseline replaces a captured foreign value" do
    Env.put_app_env(:prima, __MODULE__, :foreign)
    on_exit(fn -> assert Application.fetch_env(:prima, __MODULE__) == :error end)
    Env.put_app_env(:prima, __MODULE__, :temporary, restore: :unset)
  end

  test "the call-scoped unset baseline is restored before return" do
    Env.put_app_env(:prima, __MODULE__, :foreign)

    Env.with_app_env(
      :prima,
      __MODULE__,
      :temporary,
      fn ->
        assert Application.fetch_env(:prima, __MODULE__) == {:ok, :temporary}
      end,
      restore: :unset
    )

    assert Application.fetch_env(:prima, __MODULE__) == :error
  end

  test "logger restoration keeps an absent application setting absent" do
    Env.delete_app_env(:logger, :level)
    level = Logger.level()

    on_exit(fn ->
      assert Application.fetch_env(:logger, :level) == :error
      assert Logger.level() == level
    end)

    Env.with_logger([level: :debug], fn -> assert Logger.level() == :debug end)
    assert Application.fetch_env(:logger, :level) == :error
    Env.configure_logger(level: :debug)
  end

  test "logger restoration preserves a distinct application setting" do
    level = Logger.level()
    Env.put_app_env(:logger, :level, :warning)
    Env.with_logger([level: :debug], fn -> assert Logger.level() == :debug end)
    assert Logger.level() == level
    assert Application.fetch_env(:logger, :level) == {:ok, :warning}
  end

  test "call scope has its restore registered when the mutation raises" do
    previous = Logger.level()
    previous_setting = Application.fetch_env(:logger, :level)
    changed = if previous == :debug, do: :info, else: :debug
    registered = Map.new(:ets.lookup_element(ExUnit.Server, self(), 3))

    # A mutation that raises never reaches a registration placed after it.
    # The immediate restore repairs the level either way; inspect the pending
    # callback so that repair cannot hide the order.
    assert_raise MatchError, fn ->
      Env.with_logger([level: :invalid_test_level], fn ->
        flunk("the invalid level must fail inside the mutation")
      end)
    end

    assert Logger.level() == previous
    assert Application.fetch_env(:logger, :level) == previous_setting

    assert [{_name, restore}] =
             Enum.reject(:ets.lookup_element(ExUnit.Server, self(), 3), fn {name, _} ->
               Map.has_key?(registered, name)
             end)

    Env.configure_logger(level: changed)
    restore.()
    assert Logger.level() == previous
    assert Application.fetch_env(:logger, :level) == previous_setting
  end

  @tag timeout: 120_000
  test "a test killed inside each call restores its settings through on_exit" do
    probe = ~S"""
    ExUnit.start(autorun: false, exclude: [:test], include: [env_death: true])
    Code.require_file(System.fetch_env!("PRIMA_TEST_ENV_TEST"))
    operations = [:app_put, :app_delete, :system_put, :system_delete, :term_put, :term_erase, :logger]
    Application.put_env(:prima, Prima.Test.EnvTest, :before)
    System.put_env("PRIMA_TEST_ENV_VALUE", "before")
    :persistent_term.put({Prima.Test.EnvTest, :value}, :before)
    Logger.configure(level: :warning)
    before = Map.new(operations, &{&1, Prima.Test.EnvTest.read(&1)})
    Process.register(self(), Prima.Test.EnvProbe)

    defmodule Prima.Test.EnvDeathProbe do
      use ExUnit.Case, async: false

      for operation <- [:app_put, :app_delete, :system_put, :system_delete, :term_put, :term_erase, :logger] do
        @tag :env_death
        test "#{operation} killed inside its call" do
          operation = unquote(operation)
          Prima.Test.EnvTest.within(operation, fn ->
            assert Prima.Test.EnvTest.read(operation) == Prima.Test.EnvTest.changed(operation)
            send(Process.whereis(Prima.Test.EnvProbe), {:entered, operation})
            Process.exit(self(), :kill)
          end)
        end
      end
    end

    result = ExUnit.run()
    entered = for _ <- operations do
      receive do
        {:entered, operation} -> operation
      after
        0 -> :missing
      end
    end
    restored = Map.new(operations, &{&1, Prima.Test.EnvTest.read(&1)}) == before
    witnessed = Enum.sort(entered) == Enum.sort(operations)
    IO.puts("env-death ran=#{result.total-result.excluded} failures=#{result.failures} entered=#{witnessed} restored=#{restored}")
    """

    {output, status} =
      System.cmd("mix", ["run", "--no-start", "-e", probe],
        cd: Path.expand("../../../..", __DIR__),
        env: [{"MIX_ENV", "test"}, {"PRIMA_TEST_ENV_TEST", __ENV__.file}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "env-death ran=7 failures=7 entered=true restored=true", output
  end

  def read(operation) when operation in [:app_put, :app_delete],
    do: Application.fetch_env(:prima, __MODULE__)

  def read(operation) when operation in [:system_put, :system_delete],
    do: System.fetch_env(@system_key)

  def read(operation) when operation in [:term_put, :term_erase] do
    case :persistent_term.get(@term_key, :absent) do
      :absent -> :error
      value -> {:ok, value}
    end
  end

  def read(:logger), do: {:ok, Logger.level()}

  def changed(operation) when operation in [:app_put, :term_put], do: {:ok, nil}
  def changed(:system_put), do: {:ok, "changed"}
  def changed(:logger), do: {:ok, :debug}
  def changed(_delete), do: :error

  def within(:app_put, fun), do: Env.with_app_env(:prima, __MODULE__, nil, fun)
  def within(:app_delete, fun), do: Env.without_app_env(:prima, __MODULE__, fun)
  def within(:system_put, fun), do: Env.with_system_env(@system_key, "changed", fun)
  def within(:system_delete, fun), do: Env.without_system_env(@system_key, fun)
  def within(:term_put, fun), do: Env.with_persistent_term(@term_key, nil, fun)
  def within(:term_erase, fun), do: Env.without_persistent_term(@term_key, fun)
  def within(:logger, fun), do: Env.with_logger([level: :debug], fun)

  defp mutate(:app_put), do: Env.put_app_env(:prima, __MODULE__, nil)
  defp mutate(:app_delete), do: Env.delete_app_env(:prima, __MODULE__)
  defp mutate(:system_put), do: Env.put_system_env(@system_key, "changed")
  defp mutate(:system_delete), do: Env.delete_system_env(@system_key)
  defp mutate(:term_put), do: Env.put_persistent_term(@term_key, nil)
  defp mutate(:term_erase), do: Env.erase_persistent_term(@term_key)
  defp mutate(:logger), do: Env.configure_logger(level: :debug)

  defp seed(operation) when operation in [:app_put, :app_delete],
    do: Env.put_app_env(:prima, __MODULE__, :before)

  defp seed(operation) when operation in [:system_put, :system_delete],
    do: Env.put_system_env(@system_key, "before")

  defp seed(operation) when operation in [:term_put, :term_erase],
    do: Env.put_persistent_term(@term_key, :before)

  defp seed(:logger), do: Env.configure_logger(level: :warning)

  defp clear(:app_put), do: Env.delete_app_env(:prima, __MODULE__)
  defp clear(:system_put), do: Env.delete_system_env(@system_key)
  defp clear(:term_put), do: Env.erase_persistent_term(@term_key)
  defp delete_operation(:app_put), do: :app_delete
  defp delete_operation(:term_put), do: :term_erase
end
