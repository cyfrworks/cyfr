# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.RuntimePoolSizeTest do
  @moduledoc """
  The suite's runtime service runs on Locus's default pool whichever app's
  suite ran first in this VM: Locus's own runs on a pool of one, and
  neither its settings nor its running service carry into this suite
  (`Cyfr.Test.RuntimeService.wire!/1`, the Locus helper's restore).
  """

  # Reads the one running service.
  use ExUnit.Case, async: false

  alias Cyfr.Test.RuntimeService

  test "the running runtime service's pool is Locus's default size" do
    default = RuntimeService.default_pool_size()

    # What the running pool holds, not what the configuration says.
    assert RuntimeService.pool_size() == default
    assert Keyword.fetch!(Application.fetch_env!(:locus, :runtime), :pool_size) == default
  end
end
