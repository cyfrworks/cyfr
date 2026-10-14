# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.HttpHandlerRunnerNameTest do
  @moduledoc """
  The one case of `Locus.Runtime.HttpHandler`'s attached requests that
  registers the node's global name `Locus.Runtime.Runner`, apart from
  `Locus.Runtime.HttpHandlerTest`, which runs async: a lost answer leaves
  the runner unclean.
  """

  use ExUnit.Case, async: false

  alias Locus.Runtime.HttpHandler
  alias Locus.Runtime.Test.EdgeFixtures
  alias Locus.Runtime.Test.{ScriptedHost, ScriptedKeeper}

  describe "a request naming a connection" do
    setup do
      edge = EdgeFixtures.edge(domains: ["api.test"], methods: ["GET", "POST"])
      host = ScriptedHost.start!()

      attempt =
        ScriptedKeeper.relayed!(
          ScriptedHost.attempt!(host,
            component_ref: "catalyst:local.attached:1.0.0",
            authority: ScriptedKeeper.authority(edge, EdgeFixtures.limits())
          )
        )

      {:ok, edge: edge, host: host, attempt: attempt}
    end

    defp attached(attempt, edge, request) do
      Map.merge(%{"connection" => "api_key", "method" => "GET"}, request)
      |> Jason.encode!()
      |> HttpHandler.execute(edge, EdgeFixtures.limits(), attempt.client, attempt.component_ref)
      |> Jason.decode!()
    end

    test "a lost answer leaves the runner unclean, never reused, and the guest a plain error", %{
      edge: edge,
      host: host,
      attempt: attempt
    } do
      # The runner owning this VM's attempts hears the subtree is unclean.
      test = self()

      owner =
        spawn_link(fn ->
          Process.register(self(), Locus.Runtime.Runner)
          send(test, :registered)

          receive do
            {:"$gen_cast", {:unclean, ^test, reason}} -> send(test, {:unclean, reason})
          end
        end)

      assert_receive :registered
      on_exit(fn -> Process.exit(owner, :kill) end)

      ScriptedHost.script(host, "attached_fetch", :drop)

      assert %{"error" => %{"type" => "http_error"}} =
               attached(attempt, edge, %{"url" => "https://api.test/x"})

      assert_receive {:unclean, {:attached_fetch, :lost}}, 5_000
      assert [_one] = ScriptedHost.requests(host, "attached_fetch")
    end
  end
end
