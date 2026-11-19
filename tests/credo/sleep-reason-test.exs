# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
#
# The sleep-reason check (tests/credo/sleep_reason.ex) on planted sources,
# run from the umbrella's root (config/runtime.exs reads the umbrella's
# modules, so on a compiled build or with the compile mix run does):
#   mix run --no-start tests/credo/sleep-reason-test.exs

Code.require_file("sleep_reason.ex", __DIR__)
{:ok, _} = Application.ensure_all_started(:credo)
ExUnit.start()

defmodule Cyfr.Credo.SleepReasonTest do
  use Credo.Test.Case, async: true

  alias Cyfr.Credo.SleepReason

  defp check(body) do
    """
    defmodule PlantedTest do
      use ExUnit.Case

      test "planted" do
    #{body}
      end
    end
    """
    |> to_source_file("apps/prima/test/planted_test.exs")
    |> run_check(SleepReason)
  end

  test "a sleep with no reason is refused, on its line" do
    check("    Process.sleep(10)\n    assert true") |> assert_issue(&assert(&1.line_no == 5))
  end

  test ":timer.sleep and a captured sleep are refused alike" do
    check("    :timer.sleep(10)\n    Enum.each([1], &Process.sleep/1)") |> assert_issues(2)
  end

  test "an unrelated comment above is no reason" do
    check("    # wait a little\n    Process.sleep(10)") |> assert_issue()
  end

  test "the marker alone is no reason" do
    check("    # sleep-ok:\n    Process.sleep(10)") |> assert_issue()
    check("    Process.sleep(10) # sleep-ok:   ") |> assert_issue()
  end

  test "a reason on the line above, on the line, or in the comment above passes" do
    check(
      "    # sleep-ok: the one-millisecond lifespan under test has passed\n    Process.sleep(10)"
    )
    |> refute_issues()

    check("    Process.sleep(10) # sleep-ok: the window under test closes") |> refute_issues()

    check("""
        # sleep-ok: the proof's lifespan is one millisecond,
        # and ten outlast it on a loaded machine
        :timer.sleep(10)
    """)
    |> refute_issues()
  end

  test "a reason does not reach past code" do
    check("    # sleep-ok: the window under test closes\n    x = 1\n    Process.sleep(x)")
    |> assert_issue()
  end

  test "a reason may begin with any character, so long as it holds a word" do
    check("    # sleep-ok: `expires_at` has passed\n    Process.sleep(10)") |> refute_issues()
    check("    # sleep-ok: --- ...\n    Process.sleep(10)") |> assert_issue()
  end

  test "only a comment is a reason: a string or heredoc that reads like one is not" do
    check(~S|    Process.sleep(10); "# sleep-ok: this is a string"|) |> assert_issue()

    check(~S|    _ = "# sleep-ok: a string above"
    Process.sleep(10)|)
    |> assert_issue()

    check(~S|    _ = """
    # sleep-ok: a heredoc line above
    """
    Process.sleep(10)|)
    |> assert_issue()
  end

  test "a marker trailing code on the line above is no reason for the sleep" do
    check("    x = 1 # sleep-ok: the window under test closes\n    Process.sleep(x)")
    |> assert_issue()
  end

  test "a sleep of :infinity is exempt, piped or called" do
    check("    spawn(fn -> Process.sleep(:infinity) end)") |> refute_issues()
    check("    spawn(fn -> :infinity |> Process.sleep() end)") |> refute_issues()
    check("    10 |> Process.sleep()") |> assert_issue()
  end

  test "Elixir.Process.sleep is refused as Process.sleep is" do
    check("    Elixir.Process.sleep(10)") |> assert_issue()
  end

  test "a bare sleep/1 is refused where Process or :timer is imported with it" do
    check("    import Process\n    sleep(10)") |> assert_issue(&assert(&1.line_no == 6))
    check("    import :timer, only: [sleep: 1]\n    10 |> sleep()") |> assert_issue()
    check("    import Process, only: [sleep: 1]\n    Enum.each([1], &sleep/1)") |> assert_issue()
    check("    import Process, except: [sleep: 1]\n    sleep(10)") |> refute_issues()
    check("    sleep(10)") |> refute_issues()
  end
end
