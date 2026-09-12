# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.ApplicationTest do
  use ExUnit.Case, async: true

  test "the builder's bind address parses, or the boot refuses" do
    assert Locus.Application.bind_address!("0.0.0.0") == {0, 0, 0, 0}
    assert Locus.Application.bind_address!("127.0.0.1") == {127, 0, 0, 1}
    assert Locus.Application.bind_address!("::1") == {0, 0, 0, 0, 0, 0, 0, 1}

    assert_raise RuntimeError, ~r/CYFR_BUILDER_BIND.*not an IP address/, fn ->
      Locus.Application.bind_address!("builder")
    end
  end
end
