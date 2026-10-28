# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NotSetUpNoticeTest do
  @moduledoc """
  The boot's notice for a CYFR with no person yet, after the marker
  `cyfr up` looks for: how its first person sets it up, the setup link on
  a CYFR with pages, `cyfr login --setup` on a headless one, and what
  `cyfr init` writes when no setup token is set. It never carries the
  token.
  """

  # The setup token and headlessness are process-wide configuration.
  use ExUnit.Case, async: false

  @token String.duplicate("5e", 32)

  setup do
    previous =
      {Application.fetch_env(:sanctum, :setup_token), Application.fetch_env(:cyfr, :headless)}

    on_exit(fn ->
      {token, headless} = previous
      restore(:sanctum, :setup_token, token)
      restore(:cyfr, :headless, headless)
    end)

    :ok
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  test "the marker is the one `cyfr up` reads" do
    assert Cyfr.Application.not_set_up_marker() == "[Cyfr] Not set up:"
  end

  test "a CYFR with pages names the setup link, never its token" do
    Application.put_env(:sanctum, :setup_token, @token)
    Application.put_env(:cyfr, :headless, false)

    notice = Cyfr.Application.not_set_up_notice()
    assert notice =~ "/setup#"
    assert notice =~ "`cyfr init` or `cyfr setup` printed"
    refute notice =~ @token
  end

  test "a headless CYFR names `cyfr login --setup`" do
    Application.put_env(:sanctum, :setup_token, @token)
    Application.put_env(:cyfr, :headless, true)

    notice = Cyfr.Application.not_set_up_notice()
    assert notice =~ "`cyfr login --setup`"
    refute notice =~ "/setup#"
    refute notice =~ @token
  end

  test "with no setup token, the notice says no one can set it up and what writes one" do
    Application.delete_env(:sanctum, :setup_token)
    assert Cyfr.Application.not_set_up_notice() =~ "CYFR_SETUP_TOKEN is unset"
  end
end
