# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ApplicationTest do
  use ExUnit.Case, async: true

  # A wildcard CORS origin once authentication is configured must fail closed
  # at boot in a real release, not merely warn. cors_enforcement/3 is the pure
  # decision seam the boot guard uses (first arg: auth configured?).
  describe "cors_enforcement/3" do
    test "auth configured + wildcard + real release => raise" do
      assert {:raise, msg} = Cyfr.Application.cors_enforcement(true, ["*"], true)
      assert msg =~ "FATAL"
      assert msg =~ "authentication enabled"

      assert {:raise, _} = Cyfr.Application.cors_enforcement(true, ["https://a.example", "*"], true)
    end

    test "auth configured + wildcard outside a release => warn (dev/test not blocked)" do
      assert {:warn, msg} = Cyfr.Application.cors_enforcement(true, ["*"], false)
      assert msg =~ "suppressed outside a release"
    end

    test "auth configured with an explicit allowlist => ok" do
      assert :ok = Cyfr.Application.cors_enforcement(true, ["https://app.example"], true)
      assert :ok = Cyfr.Application.cors_enforcement(true, [], true)
    end

    test "no auth configured is never blocked, even with a wildcard in a release" do
      assert :ok = Cyfr.Application.cors_enforcement(false, ["*"], true)
      assert :ok = Cyfr.Application.cors_enforcement(false, ["*"], false)
    end
  end
end
