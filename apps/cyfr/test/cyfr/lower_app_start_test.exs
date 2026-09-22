# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LowerAppStartTest do
  use ExUnit.Case, async: false

  test "Arca and Sanctum start cold without Host or a boot identity" do
    args = [~c"+S", ~c"2:2"] ++ Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _} = :peer.start_link(%{connection: :standard_io, args: args, wait_boot: 10_000})

    try do
      config = for app <- [:arca, :sanctum], do: {app, Application.get_all_env(app)}
      :ok = :peer.call(peer, Application, :put_all_env, [config])
      assert {:ok, started} = :peer.call(peer, Application, :ensure_all_started, [:sanctum])
      assert :arca in started
      assert :sanctum in started
      refute :cyfr in started

      {result, _} =
        :peer.call(peer, Code, :eval_string, [
          """
          missing =
            try do
              Cyfr.Boot.id()
              false
            rescue
              Cyfr.Boot.NotInitializedError -> true
            end

          limiter = Process.whereis(Cyfr.RateLimiter)
          owned = Enum.any?(Supervisor.which_children(Sanctum.Supervisor), fn
            {Cyfr.RateLimiter, pid, _, _} -> pid == limiter
            _ -> false
          end)

          {missing, owned, Cyfr.RateLimiter.check(:cold_start, 1, 1_000)}
          """
        ])

      assert result == {true, true, :ok}
    after
      :peer.stop(peer)
    end
  end
end
