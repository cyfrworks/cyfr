# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.KeeperEnvTest do
  @moduledoc """
  The cases of `Locus.Keeper`'s client that change this VM's environment,
  apart from `Locus.KeeperTest`, which runs async: every spawn asks for
  the builder's memory bound, the application's setting when it names
  one, and there is no asking for none; fd 3 is the channel only when it
  links to the socket `KEEPER_CHANNEL` names.
  """

  use ExUnit.Case, async: false

  alias Locus.Keeper
  alias Locus.Test.FakeKeeper

  defp run(name, script, opts \\ []) do
    Keeper.run(
      name,
      %{argv: ["/bin/sh", "-c", script], env: %{}, stdin: ""},
      [timeout_ms: 10_000, max_stdout_bytes: 1_000_000] ++ Keyword.take(opts, [:memory_bytes])
    )
  end

  describe "against the fake keeper" do
    setup do
      {:ok, FakeKeeper.start_client!()}
    end

    test "every spawn asks for the builder's memory bound, and none can ask for no bound", %{
      name: name,
      fake: fake
    } do
      assert {:ok, _} = run(name, "true")
      assert {:ok, _} = run(name, "true", memory_bytes: 33_554_432)

      previous = Application.fetch_env(:locus, :memory_bytes)

      on_exit(fn ->
        case previous do
          {:ok, bytes} -> Application.put_env(:locus, :memory_bytes, bytes)
          :error -> Application.delete_env(:locus, :memory_bytes)
        end
      end)

      Application.put_env(:locus, :memory_bytes, 268_435_456)
      assert {:ok, _} = run(name, "true")

      spawns = fake |> FakeKeeper.requests() |> Enum.filter(&(&1["type"] == "spawn"))
      assert Enum.map(spawns, & &1["memory_bytes"]) == [1_073_741_824, 33_554_432, 268_435_456]

      for none <- [nil, 0, -1, "1G"] do
        assert_raise ArgumentError, ~r/memory bound/, fn ->
          run(name, "true", memory_bytes: none)
        end
      end

      assert length(Enum.filter(FakeKeeper.requests(fake), &(&1["type"] == "spawn"))) == 3
    end
  end

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
