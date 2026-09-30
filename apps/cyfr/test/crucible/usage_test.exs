# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.UsageTest do
  @moduledoc """
  `execution.usage`: the runs one profile admitted, each with its origin,
  root and time, read actor first. A profile of another athanor reads as
  one that does not exist, and a profile of this athanor with no runs
  answers an empty list, never a refusal.
  """

  use ExUnit.Case, async: false

  alias Crucible.Provider
  alias Sanctum.Test.ConsentFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    {mine, theirs} = Sanctum.TestContext.two_contexts()
    {:ok, mine: mine, theirs: theirs}
  end

  defp profile!(ctx, name) do
    ConsentFixtures.bindable_profile(ctx, "catalyst:local.#{name}:1.0.0",
      profile_id: "prof_#{name}_#{System.unique_integer([:positive])}"
    )
  end

  defp run!(ctx, attrs) do
    id = "exec_usage_#{System.unique_integer([:positive])}"

    {:ok, row} =
      Arca.Execution.record_start(
        Map.merge(
          %{
            id: id,
            root_execution_id: id,
            reference: "catalyst:local.usage:1.0.0",
            user_id: ctx.user_id,
            athanor_id: ctx.athanor_id,
            started_at: DateTime.utc_now(),
            status: "running",
            component_type: "catalyst"
          },
          attrs
        )
      )

    row
  end

  defp usage(ctx, args),
    do: Grimoire.call_external("execution", ctx, Map.put(args, "action", "usage"))

  test "a profile's runs answer with their origin, root and time, newest first",
       %{mine: ctx} do
    profile_id = profile!(ctx, "usage-runs")
    earlier = DateTime.add(DateTime.utc_now(), -60, :second)

    scheduled =
      run!(ctx, %{
        profile_id: profile_id,
        origin: "schedule",
        schedule_id: "sch_usage",
        started_at: earlier
      })

    programmatic = run!(ctx, %{profile_id: profile_id, origin: "programmatic"})

    # A child of the scheduled root carries no profile: it walks its
    # root's authority, and the root is the run the grant admitted.
    _child =
      run!(ctx, %{
        parent_execution_id: scheduled.id,
        root_execution_id: scheduled.id,
        origin: "schedule"
      })

    # Another profile's run of this athanor is not this profile's.
    _other = run!(ctx, %{profile_id: profile!(ctx, "usage-other"), origin: "interactive"})

    assert {:ok, %{profile_id: ^profile_id, count: 2, runs: [newest, oldest]}} =
             usage(ctx, %{"profile_id" => profile_id})

    assert newest == %{
             execution_id: programmatic.id,
             root_execution_id: programmatic.id,
             origin: "programmatic",
             kind: "component",
             status: "running",
             reference: "catalyst:local.usage:1.0.0",
             turn_id: nil,
             schedule_id: nil,
             started_at: DateTime.to_iso8601(programmatic.started_at),
             completed_at: nil
           }

    assert %{
             execution_id: id,
             root_execution_id: id,
             origin: "schedule",
             schedule_id: "sch_usage",
             started_at: started_at
           } = oldest

    assert id == scheduled.id
    assert {:ok, ^earlier, 0} = DateTime.from_iso8601(started_at)
  end

  test "another athanor's profile is refused, and its runs never answer",
       %{mine: ctx, theirs: other} do
    theirs = profile!(other, "usage-theirs")
    _their_run = run!(other, %{profile_id: theirs, origin: "webhook"})

    # A row of this athanor naming their profile id is still not theirs to
    # show: the profile is read first, in the caller's athanor.
    _planted = run!(ctx, %{profile_id: theirs, origin: "interactive"})

    assert {:error, reason} = usage(ctx, %{"profile_id" => theirs})
    assert reason == {:not_found, "Profile", theirs}
    assert Prima.Refusal.classify(reason).class == :not_found

    # The same answer as a profile that exists nowhere.
    assert usage(ctx, %{"profile_id" => "prof_nowhere"}) ==
             {:error, {:not_found, "Profile", "prof_nowhere"}}

    # Its own athanor reads its run.
    assert {:ok, %{count: 1, runs: [%{origin: "webhook"}]}} =
             usage(other, %{"profile_id" => theirs})
  end

  test "a profile with no runs answers an empty list, not a refusal", %{mine: ctx} do
    profile_id = profile!(ctx, "usage-idle")

    assert usage(ctx, %{"profile_id" => profile_id}) ==
             {:ok, %{profile_id: profile_id, runs: [], count: 0}}
  end

  test "a revoked profile's runs still answer: they are the rows' own history",
       %{mine: ctx} do
    profile_id = profile!(ctx, "usage-revoked")
    run = run!(ctx, %{profile_id: profile_id, origin: "interactive"})

    assert {:ok, %{status: "revoked"}} =
             Grimoire.call_external("profile", ctx, %{
               "action" => "revoke",
               "profile_id" => profile_id
             })

    assert {:ok, %{count: 1, runs: [%{execution_id: id}]}} =
             usage(ctx, %{"profile_id" => profile_id})

    assert id == run.id
  end

  test "the page is bounded, newest first, and a limit that bounds nothing is refused",
       %{mine: ctx} do
    profile_id = profile!(ctx, "usage-page")

    _older =
      run!(ctx, %{
        profile_id: profile_id,
        origin: "interactive",
        started_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    newer = run!(ctx, %{profile_id: profile_id, origin: "interactive"})

    assert {:ok, %{count: 1, runs: [%{execution_id: id}]}} =
             usage(ctx, %{"profile_id" => profile_id, "limit" => 1})

    assert id == newer.id

    for limit <- [0, -1] do
      assert Provider.handle("execution", ctx, %{
               "action" => "usage",
               "profile_id" => profile_id,
               "limit" => limit
             }) == {:error, {:invalid_argument, "limit must be a positive integer"}}
    end
  end

  test "a call naming no profile is refused before any read", %{mine: ctx} do
    for args <- [%{}, %{"profile_id" => ""}, %{"profile_id" => 7}] do
      assert Provider.handle("execution", ctx, Map.put(args, "action", "usage")) ==
               {:error, {:invalid_argument, "Missing required argument: profile_id"}}
    end
  end

  test "the read needs the execute permission, as the declaration says" do
    no_execute = %Sanctum.Context{
      user_id: "usage_no_exec",
      athanor_id: Sanctum.TestContext.athanor_id(),
      permissions: MapSet.new([:component_read]),
      scope: :athanor,
      auth_method: :api_key,
      api_key_type: :application,
      authenticated: true
    }

    assert {:error, %Prima.Refusal{stage: :admission, reason: {:missing_permission, :execute}}} =
             usage(no_execute, %{"profile_id" => "prof_any"})
  end
end
