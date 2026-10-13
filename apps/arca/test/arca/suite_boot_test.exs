# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.SuiteBootTest do
  @moduledoc """
  `Arca.Test.SuiteBoot.boot!/1` registers its storage cleanup once per VM:
  every database app's helper boots, and `ExUnit.after_suite/1` callbacks
  accumulate across the apps of one VM, so a cleanup registered per boot
  would run once per app already booted after every later suite.
  """

  # It boots the suite again and reads the VM's after-suite callbacks.
  use ExUnit.Case, async: false

  alias Arca.Test.SuiteBoot

  test "a second boot in this VM registers no second cleanup" do
    # This app's helper booted once before the suite started.
    assert SuiteBoot.cleanups() == 1
    callbacks = Application.fetch_env!(:ex_unit, :after_suite)

    # The fixtures' athanors were committed by that boot; this one seeds
    # nothing more.
    assert :ok = SuiteBoot.boot!(seed: fn -> :ok end)

    assert SuiteBoot.cleanups() == 1
    assert Application.fetch_env!(:ex_unit, :after_suite) == callbacks
  end
end
