# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NotSetUpNoticeTest do
  @moduledoc """
  The boot's notice for a CYFR with no person yet, after the marker
  `cyfr up` looks for: how its first person sets it up, the setup link
  every CYFR serves, and what `cyfr init` writes when no setup token is
  set. It never carries the token.
  """

  # The setup token is process-wide configuration.
  use ExUnit.Case, async: false

  @token String.duplicate("5e", 32)

  test "the marker is the one `cyfr` reads" do
    assert Cyfr.Application.not_set_up_marker() == "[Cyfr] Not set up:"
  end

  test "the notice names the setup link, never its token" do
    Prima.Test.Env.put_app_env(:sanctum, :setup_token, @token)

    assert Cyfr.Application.not_set_up_notice() ==
             "no one is set up on this CYFR yet. Its first person, who administers it, opens " <>
               "the setup link `cyfr init` or `cyfr setup` printed (#{Sanctum.origin()}/setup#…)."
  end

  test "with no setup token, the notice says no one can set it up and what writes one" do
    Prima.Test.Env.delete_app_env(:sanctum, :setup_token)
    assert Cyfr.Application.not_set_up_notice() =~ "CYFR_SETUP_TOKEN is unset"
  end
end
