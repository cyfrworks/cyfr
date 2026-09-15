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

  test "a node that is not the builder serves nothing, and the builder refuses to serve without the spawner" do
    assert Locus.Application.builder_endpoint(false, false) == []
    assert Locus.Application.builder_endpoint(false, true) == []

    assert_raise RuntimeError,
                 ~r/runs builds only through cyfr-spawn.*fd 3 is not that channel/,
                 fn ->
                   Locus.Application.builder_endpoint(true, false)
                 end

    assert [{Bandit, opts}] = Locus.Application.builder_endpoint(true, true)
    assert opts[:plug] == Locus.BuilderService
  end
end
