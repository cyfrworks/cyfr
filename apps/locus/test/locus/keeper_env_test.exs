# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperEnvTest do
  @moduledoc """
  The cases of `Locus.Keeper`'s client that change this VM's environment,
  apart from `Locus.KeeperTest`, which runs async: fd 3 is the channel
  only when it links to the socket `KEEPER_CHANNEL` names.
  """

  use ExUnit.Case, async: false

  alias Locus.Keeper

  describe "the inherited channel" do
    test "fd 3 is the channel only when it is the socket cyfr-locus names" do
      env = fn value -> fn "KEEPER_CHANNEL" -> value end end
      link = fn target -> fn "/proc/self/fd/3" -> target end end

      assert Keeper.channel_inherited?(env.("socket:[4242]"), link.({:ok, "socket:[4242]"}))
      refute Keeper.channel_inherited?(env.("socket:[4242]"), link.({:ok, "socket:[1]"}))
      refute Keeper.channel_inherited?(env.("socket:[4242]"), link.({:ok, "/dev/null"}))
      refute Keeper.channel_inherited?(env.("socket:[4242]"), link.({:error, :enoent}))
      refute Keeper.channel_inherited?(env.(nil), link.({:ok, "socket:[4242]"}))
      refute Keeper.channel_inherited?(env.(""), link.({:ok, ""}))

      # This VM was started by no keeper: whatever its fd 3 is, the
      # variable names nothing it links to.
      previous = System.get_env("KEEPER_CHANNEL")

      on_exit(fn ->
        if previous,
          do: System.put_env("KEEPER_CHANNEL", previous),
          else: System.delete_env("KEEPER_CHANNEL")
      end)

      System.delete_env("KEEPER_CHANNEL")
      refute Keeper.channel_inherited?()

      System.put_env("KEEPER_CHANNEL", "socket:[1]")
      refute Keeper.channel_inherited?()
      assert Keeper.channel_env() == "KEEPER_CHANNEL"
    end
  end
end
