# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.LoggerLevelTest do
  @moduledoc """
  The logger level a locus test starts at: the umbrella's test level, which
  this project's test configuration sets. A test that restores the level it
  found restores this one, so the level a cyfr test runs at after it in the
  same VM is the umbrella's too.
  """

  # Reads the logger's global level, which a concurrent test could change.
  use ExUnit.Case, async: false

  test "the locus suite starts at the umbrella's test level" do
    assert Application.get_env(:logger, :level) == :warning
    assert Logger.level() == :warning
  end
end
