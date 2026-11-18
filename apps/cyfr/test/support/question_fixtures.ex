# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.QuestionFixtures do
  @moduledoc """
  A component's questions opened with no runner: a catalyst that declares
  actions shipped into a person's athanor, a running root of it with its
  current attempt, and an ask decided by `Sanctum.Questions.ask/4` as the
  host would hand it on; and the run's end closing its questions and
  announcing them (`Sanctum.Questions.ended/3`).
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Sanctum.Context

  @asks [
    %{"name" => "delete_table", "title" => "delete a table"},
    %{"name" => "delete_rows", "title" => "delete rows from a table"}
  ]

  @doc "The actions the fixture's catalyst declares."
  def asks, do: @asks

  @doc """
  A private store and seed tree for the test, and an emptied allowance,
  each restored when it ends.
  """
  def isolate! do
    Arca.Cache.init()
    Prima.Test.RateLimiter.reset!()
    base = Path.join(System.tmp_dir!(), "questions_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Prima.Test.RateLimiter.reset!()
      File.rm_rf!(base)
    end)

    Prima.Test.Env.put_app_env(:arca, :base_path, base)
    Cyfr.Test.SeedBundle.isolate!()
    :ok
  end

  @doc """
  The catalyst `local.<name>` at `version`, declaring `asks`, shipped and
  registered in `ctx`'s athanor: its registry row.
  """
  def catalyst!(ctx, name \\ "tables", version \\ "1.0.0", asks \\ @asks) do
    manifest = %{
      "name" => name,
      "type" => "catalyst",
      "version" => version,
      "publisher" => "local",
      "asks" => asks
    }

    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", name, version,
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm("catalyst")
      )

    component
  end

  @doc """
  A running root of `component` in `ctx`'s athanor, as the host hands it
  to an ask: `opts` may name its `caller` (a caller's text) and `deadline`.
  """
  def run!(ctx, component, opts \\ []) do
    id = Prima.UUID7.execution_id()
    reference = "catalyst:local.#{component.name}:#{component.version}"

    {:ok, grant} =
      Sanctum.ExecutionStanding.capture(
        Context.internal(athanor_id: ctx.athanor_id, scope: :athanor)
      )

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: id,
          root_execution_id: id,
          reference: reference,
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "catalyst",
          origin: :interactive
        },
        boot_id: "node@test",
        lease_until: DateTime.add(DateTime.utc_now(), 120, :second),
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    %{
      execution_id: id,
      attempt_id: attempt.attempt,
      root_execution_id: id,
      component_ref: reference,
      release_digest: component.release_digest,
      caller: Keyword.get(opts, :caller, "person"),
      deadline: Keyword.get(opts, :deadline, DateTime.add(DateTime.utc_now(), 600, :second))
    }
  end

  @doc "An ask's request: the fixture's own, with `attrs` over it."
  def request(attrs \\ %{}) do
    request =
      Map.merge(
        %{
          action: "delete_table",
          summary: "Drop the table users in the project acme",
          operation: "DROP TABLE users;",
          masked: false
        },
        Map.new(attrs)
      )

    Map.put_new(
      request,
      :request_digest,
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(request)), case: :lower)
    )
  end

  @doc """
  A question opened by a run of `component` under `ctx`, an interactive
  root: `{run, ref}`. `opts` names the run's `caller` and `deadline` and
  the request's fields (`request`).
  """
  def open!(ctx, component, opts \\ []) do
    run = run!(ctx, component, opts)

    assert {:pending, ref} =
             Sanctum.Questions.ask(
               %{ctx | origin: :interactive},
               run,
               1,
               request(Keyword.get(opts, :request, %{}))
             )

    {run, ref}
  end

  @doc """
  The run ended (`status`), its questions closed by the write that ended
  it and announced as `stage` (`:expired` or `:withdrawn`).
  """
  def end!(ctx, run, stage, status \\ "cancelled") do
    {:ok, %{closed_questions: closed}} =
      Arca.Execution.record_end(
        Prima.Actor.in_athanor(ctx.athanor_id),
        run.execution_id,
        status,
        %{completed_at: DateTime.utc_now(), duration_ms: 1},
        run.attempt_id,
        grant: :stored,
        verify: fn _grant -> :ok end
      )

    :ok = Sanctum.Questions.ended(ctx.athanor_id, closed, stage)
    closed
  end

  @doc "The question `ref` as its row holds it."
  def row(ctx, ref) do
    {:ok, row} = Arca.Questions.get(Context.actor(ctx), ref)
    row
  end

  @doc "The person's standing answers for the catalyst `local.<name>`."
  def standing(ctx, name \\ "tables") do
    {:ok, rows} = Arca.Questions.standing(Context.actor(ctx), ctx.user_id, "local", name)
    rows
  end
end
