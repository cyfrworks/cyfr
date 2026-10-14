# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Mix.Tasks.Cyfr.Locus.RuntimeKeyTest do
  @moduledoc """
  `mix cyfr.locus.runtime_key` prints one worker service's key, derived
  from `CYFR_LOCUS_RUNTIME_ROOT`, as the line its operator configures the
  service with, and refuses a missing or malformed root, a service id that
  is not a key field and a wrong argument count with `Mix.Error`, printing
  nothing. The key is checked against `tests/fixtures/worker_auth.json`,
  the vectors every side of the worker wire derives from.

  The shell and the root variable are node-wide, so this module runs
  alone and restores both.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Cyfr.Locus.RuntimeKey

  @fixture Path.expand("../../../../tests/fixtures/worker_auth.json", __DIR__)
  @external_resource @fixture
  @vectors @fixture |> File.read!() |> Jason.decode!()

  @root_var "CYFR_LOCUS_RUNTIME_ROOT"

  setup do
    shell = Mix.shell()
    root = System.get_env(@root_var)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(shell)
      if root, do: System.put_env(@root_var, root), else: System.delete_env(@root_var)
    end)
  end

  test "prints the service's key, derived from the root, as its operator configures it" do
    System.put_env(@root_var, @vectors["root_hex"])

    RuntimeKey.run([@vectors["service"]])

    assert_received {:mix_shell, :info, [line]}
    assert line == "LOCUS_RUNTIME_KEY=" <> @vectors["keys"]["worker_hex"]
    refute_received {:mix_shell, _, _}
  end

  test "a service id of 256 characters, the longest key field, is accepted" do
    System.put_env(@root_var, @vectors["root_hex"])

    RuntimeKey.run([String.duplicate("w", 256)])

    assert_received {:mix_shell, :info, ["LOCUS_RUNTIME_KEY=" <> hex]}
    assert hex =~ ~r/\A[0-9a-f]{64}\z/
  end

  describe "refuses, printing nothing," do
    test "when the root is unset" do
      System.delete_env(@root_var)

      refused!([@vectors["service"]], "CYFR_LOCUS_RUNTIME_ROOT is not set")
    end

    test "when the root is not 64 hexadecimal digits" do
      invalid = @vectors["root_text"]["invalid"]
      assert invalid != []

      for text <- invalid do
        System.put_env(@root_var, text)
        refused!([@vectors["service"]], "CYFR_LOCUS_RUNTIME_ROOT is not 64 hexadecimal digits")
      end
    end

    test "a service id with a space" do
      System.put_env(@root_var, @vectors["root_hex"])

      refused!(["wrk one"], ~s("wrk one" is not a service id))
    end

    test "a service id of 257 characters" do
      System.put_env(@root_var, @vectors["root_hex"])
      id = String.duplicate("w", 257)

      refused!([id], "#{inspect(id)} is not a service id")
    end

    test "any argument count but one" do
      System.put_env(@root_var, @vectors["root_hex"])

      for args <- [[], [@vectors["service"], "wrk_other"]] do
        refused!(args, "usage: mix cyfr.locus.runtime_key <service_id>")
      end
    end
  end

  # Nothing reaches the shell, standard output or standard error.
  defp refused!(args, message) do
    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn ->
            error = assert_raise Mix.Error, fn -> RuntimeKey.run(args) end
            assert Exception.message(error) == message
          end)

        assert stdout == ""
      end)

    assert stderr == ""
    refute_received {:mix_shell, _, _}
  end
end
