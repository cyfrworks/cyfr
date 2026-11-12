# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TestSeamTest do
  # The gate, as a module that calls it is compiled with the test
  # permission and without it, as every release compiles it: the macro
  # reads the permission while its caller compiles, and a caller compiled
  # without it answers the default and never calls the read. Synchronous:
  # each case sets the permission while it compiles its module.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Prima.Test.Env

  # A module whose seam's default and read each say when they run, and
  # whose read closes over a variable nothing else uses.
  @source """
  defmodule NAME do
    require Prima.TestSeam

    def answer(test) do
      closed_over = :read

      Prima.TestSeam.value(
        (send(test, :default_ran); :shipped),
        fn ->
          send(test, :read_ran)
          Application.get_env(:prima, :prima_test_seam_probe_key, closed_over)
        end
      )
    end
  end
  """

  # `name` compiled from the source above with the permission `permitted`,
  # once the compile wrote nothing to stderr.
  defp compile(name, permitted) do
    source = String.replace(@source, "NAME", inspect(name))

    Env.with_app_env(:prima, :test_seams_permitted, permitted, fn ->
      {result, warnings} =
        with_io(:stderr, fn -> Code.compile_string(source, "test_seam_caller.ex") end)

      assert [{^name, _beam}] = result
      assert warnings == ""
      name
    end)
  end

  test "a caller compiled without the permission answers the default and never reads" do
    without = compile(Prima.TestSeamTest.Without, false)

    Env.with_app_env(:prima, :test_seams_permitted, true, fn ->
      assert without.answer(self()) == :shipped
    end)

    assert_received :default_ran
    refute_received :read_ran
  end

  test "a caller compiled with the permission answers the read" do
    with_permission = compile(Prima.TestSeamTest.With, true)

    Env.with_app_env(:prima, :prima_test_seam_probe_key, :set_at_start_up, fn ->
      Env.with_app_env(:prima, :test_seams_permitted, false, fn ->
        assert with_permission.answer(self()) == :set_at_start_up
      end)
    end)

    assert_received :read_ran
    refute_received :read_ran
  end

  test "the decision answers the default without the permission and never runs the read" do
    read = fn -> flunk("a build without the test permission ran the read") end
    assert Prima.TestSeam.value(false, :shipped, read) == :shipped
    assert Prima.TestSeam.value(true, :shipped, fn -> :set_at_start_up end) == :set_at_start_up
  end
end
