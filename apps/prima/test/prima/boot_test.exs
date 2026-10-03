# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.BootTest do
  use ExUnit.Case, async: true

  test "an uninitialized reader refuses and only explicit mint changes the identity" do
    args = [~c"+S", ~c"2:2"] ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: args, wait_boot: 10_000})

    try do
      {result, _} =
        :peer.call(peer, Code, :eval_string, [
          """
          refused =
            try do
              Prima.Boot.id()
              false
            rescue
              Prima.Boot.NotInitializedError -> true
            end

          first = Prima.Boot.mint()
          stable = Prima.Boot.id() == first
          second = Prima.Boot.mint()
          {refused, stable, first != second, Prima.Boot.id() == second}
          """
        ])

      assert result == {true, true, true, true}
    after
      :peer.stop(peer)
    end
  end
end
