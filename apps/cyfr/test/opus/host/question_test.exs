# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Host.QuestionTest do
  @moduledoc """
  The host's side of an ask, as `Opus.Host` reads and answers it: the
  request's digest reproduces `tests/fixtures/host_api.json`'s
  `question_cases` vectors; an ask or a wait whose args do not read, or a
  wait asking past `Prima.HostAPI.max_question_wait_ms/0`, is lost; and a
  run whose attempt is no longer live is answered lost, ask and wait
  alike, with nothing recorded. The decision itself is
  `Sanctum.Questions`'; the runner's loop and the run's ends are proved end
  to end (`Locus.Runtime.QuestionTest`).
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyfr.Test.AttemptFixtures
  alias Opus.Host.Question
  alias Prima.Authority.Blob

  @repo Path.expand("../../../../..", __DIR__)

  @vectors Path.expand("../../../../../tests/fixtures/host_api.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @ask %{
    "ask_no" => 1,
    "action" => "delete_table",
    "summary" => "Drop the table users",
    "operation" => "DROP TABLE users"
  }

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)
    {ctx, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))
    Sanctum.TestContext.ready!(ctx.athanor_id)
    {:ok, ctx: ctx}
  end

  test "a request's digest reproduces every vector" do
    vectors = @vectors["question_cases"]["request_digests"]
    assert length(vectors) >= 3

    for %{"action" => action, "summary" => summary, "operation" => operation, "digest" => digest} <-
          vectors do
      assert Question.request_digest(action, summary, operation) == digest
    end

    # Each field is framed by its length: moving a byte between fields
    # changes the digest.
    refute Question.request_digest("ab", "c", "") == Question.request_digest("a", "bc", "")
  end

  test "the component guide shows the interface and the worked example as they are built" do
    guide = File.read!(Path.join(@repo, "component-guide.md"))

    [section] =
      Regex.run(~r/### `cyfr:question\/ask`.*?(?=\n### )/s, guide)

    [shown_wit] = Regex.run(~r/```wit\n(.*?)```/s, section, capture: :all_but_first)
    [shown_rust] = Regex.run(~r/```rust\n(.*?)```/s, section, capture: :all_but_first)

    wit = File.read!(Path.join(@repo, "wit/catalyst/deps/cyfr-question/ask.wit"))

    assert shown_wit ==
             wit |> String.split("\n", parts: 4) |> List.last() |> String.trim_leading()

    source =
      File.read!(Path.join(@repo, "apps/cyfr/test/support/test_wasm/question_probe/src/lib.rs"))

    assert shown_rust == source
    assert section =~ "import cyfr:question/ask@0.1.0;"
    assert section =~ ~s("cyfr:question" = { path = "wit/deps/cyfr-question" })
  end

  test "only the catalyst world imports the package" do
    worlds =
      Map.new(~w(catalyst reagent formula), fn type ->
        {type, File.read!(Path.join(@repo, "wit/#{type}/world.wit"))}
      end)

    assert worlds["catalyst"] =~ "import cyfr:question/ask@0.1.0;"
    refute worlds["reagent"] =~ "cyfr:question"
    refute worlds["formula"] =~ "cyfr:question"

    assert Prima.CargoToml.template(:catalyst) =~
             ~s("cyfr:question" = { path = "wit/deps/cyfr-question" })

    refute Prima.CargoToml.template(:reagent) =~ "cyfr:question"
  end

  test "args that do not read are lost, and a wait past the longest one is lost", %{ctx: ctx} do
    fixture = AttemptFixtures.attached!(ctx: ctx)

    for args <- [
          Map.put(@ask, "ask_no", 0),
          Map.put(@ask, "ask_no", "1"),
          Map.delete(@ask, "operation"),
          Map.put(@ask, "summary", 7)
        ] do
      assert %{"error" => "lost"} = AttemptFixtures.call(fixture, "question_ask", args),
             inspect(args)
    end

    max = Prima.HostAPI.max_question_wait_ms()

    for args <- [
          %{"ask_no" => 1, "max_wait_ms" => max + 1},
          %{"ask_no" => 1, "max_wait_ms" => -1},
          %{"ask_no" => 0, "max_wait_ms" => 10}
        ] do
      assert %{"error" => "lost"} = AttemptFixtures.call(fixture, "question_wait", args),
             inspect(args)
    end

    assert no_questions?(ctx)
  end

  test "an attempt no longer live is answered lost, its ask and its wait, and nothing is recorded",
       %{ctx: ctx} do
    fixture = AttemptFixtures.attached!(ctx: ctx)
    assert {:ok, _} = Opus.cancel(ctx, fixture.execution_id)

    assert %{"error" => "lost"} = AttemptFixtures.call(fixture, "question_ask", @ask)

    assert %{"error" => "lost"} =
             AttemptFixtures.call(fixture, "question_wait", %{"ask_no" => 1, "max_wait_ms" => 0})

    assert no_questions?(ctx)
  end

  # ---------------------------------------------------------------------------
  # A live attempt of a catalyst that declares its actions
  # ---------------------------------------------------------------------------

  @node "catalyst:local.tables"
  @asks [%{"name" => "delete_table", "title" => "delete a table"}]

  # The catalyst shipped in the person's athanor, and an attached attempt
  # of it whose authority pins its release, as a consented root's does.
  defp asking!(ctx) do
    component = ship!(ctx)

    {pinned, _entry} =
      AttemptFixtures.vault_authority!(ctx, %{kind: "api_key", fields: %{"KEY" => "k"}})

    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @node => %{
            "limits" => Prima.Test.AuthorityFixtures.limits_map(),
            "edges" => %{"@ingress" => %{}}
          }
        }
      })

    {:ok, authority} =
      Prima.Authority.root(
        %{
          profile_id: pinned.profile_id,
          consent_id: pinned.consent_id,
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => component.release_digest}
        },
        blob,
        ceiling: Prima.Test.AuthorityFixtures.ceiling()
      )

    AttemptFixtures.attached!(ctx: ctx, authority: authority, component_ref: @node <> ":1.0.0")
  end

  # The catalyst, shipped in the person's athanor with its declared actions.
  defp ship!(ctx) do
    manifest = %{
      "name" => "tables",
      "type" => "catalyst",
      "version" => "1.0.0",
      "publisher" => "local",
      "asks" => @asks
    }

    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, "catalyst", "local", "tables", "1.0.0",
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm("catalyst")
      )

    component
  end

  defp spent(ctx, fixture) do
    case :ets.lookup(:cyfr_rate_limiter, {:question, ctx.athanor_id, fixture.execution_id}) do
      [{_key, count, _started}] -> count
      [] -> 0
    end
  end

  # Until `pid` waits inside `fun` of `module` (any of its functions for
  # `:any`), or ten seconds have passed.
  defp parked!(pid, module, fun, tries \\ 200) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)

    cond do
      Enum.any?(stack, fn {m, f, _arity, _location} -> m == module and fun in [f, :any] end) ->
        :ok

      tries == 0 ->
        flunk("#{inspect(pid)} never waited in #{inspect(module)}.#{fun}")

      true ->
        Process.sleep(50)
        parked!(pid, module, fun, tries - 1)
    end
  end

  test "a wait whose attempt ends while it waits is handed lost, never the allow written meanwhile",
       %{ctx: ctx} do
    fixture = asking!(ctx)
    caller = AttemptFixtures.caller(fixture)
    assert {:ok, :pending} = Opus.Host.question_ask(caller, 1, atoms(@ask))

    [question] =
      Arca.Repo.all(from(q in Arca.Schemas.Question, where: q.attempt_id == ^fixture.attempt))

    waiting =
      Task.async(fn -> Opus.Host.question_wait(AttemptFixtures.caller(fixture), 1, 10_000) end)

    parked!(waiting.pid, Sanctum.Questions, :poll)

    # The attempt's process is held, so the wait's second look at it comes
    # only after both writes: the person's allow, then the run's end.
    :sys.suspend(fixture.pid)
    actor = Sanctum.Context.actor(ctx)

    assert {:ok, %{state: "allowed"}} =
             Arca.Questions.answer(actor, question.ref, "allowed", nil, verify: fn -> :ok end)

    assert {:ok, _ended} =
             Arca.Execution.record_end(
               Prima.Actor.in_athanor(ctx.athanor_id),
               fixture.execution_id,
               "cancelled",
               %{completed_at: DateTime.utc_now(), duration_ms: 1},
               fixture.attempt,
               grant: :stored,
               verify: fn _grant -> :ok end
             )

    :sys.resume(fixture.pid)
    assert Task.await(waiting, 15_000) == {:error, :lost}
  end

  test "two admissions of one key at once take the allowance once and open one question", %{
    ctx: ctx
  } do
    fixture = asking!(ctx)

    # Both calls are held at the attempt's process and let go together, so
    # each reads the key before the other has admitted it.
    :sys.suspend(fixture.pid)

    asks =
      for _ <- 1..2 do
        Task.async(fn ->
          Opus.Host.question_ask(AttemptFixtures.caller(fixture), 1, atoms(@ask))
        end)
      end

    for task <- asks, do: parked!(task.pid, :gen, :do_call)
    :sys.resume(fixture.pid)

    assert Task.await_many(asks, 15_000) == [{:ok, :pending}, {:ok, :pending}]
    assert spent(ctx, fixture) == 1

    assert [_one] =
             Arca.Repo.all(
               from(q in Arca.Schemas.Question, where: q.attempt_id == ^fixture.attempt)
             )
  end

  for decision <- ~w(allowed denied) do
    test "a retry that waited for its key while the run ended is handed lost, never the #{decision} its row holds",
         %{ctx: ctx} do
      fixture = asking!(ctx)

      assert {:ok, :pending} =
               Opus.Host.question_ask(AttemptFixtures.caller(fixture), 1, atoms(@ask))

      [question] =
        Arca.Repo.all(from(q in Arca.Schemas.Question, where: q.attempt_id == ^fixture.attempt))

      assert {:ok, %{state: unquote(decision)}} =
               Arca.Questions.answer(
                 Sanctum.Context.actor(ctx),
                 question.ref,
                 unquote(decision),
                 nil,
                 verify: fn -> :ok end
               )

      # The key is held, as an admission of it still deciding holds it: the
      # retry passes its first look at the attempt and waits for the key.
      lock = {{Opus.Host.Question, fixture.attempt, 1}, self()}
      true = :global.set_lock(lock, [node()])

      retry =
        Task.async(fn ->
          Opus.Host.question_ask(AttemptFixtures.caller(fixture), 1, atoms(@ask))
        end)

      parked!(retry.pid, :global, :any)

      # The run ends while the retry waits; then the key is let go, and the
      # row's decision is found.
      assert {:ok, _ended} = end!(ctx, fixture)
      true = :global.del_lock(lock, [node()])
      assert Task.await(retry, 15_000) == {:error, :lost}
    end
  end

  test "a child's question that the cascade ends is closed and announced withdrawn, once", %{
    ctx: ctx
  } do
    component = ship!(ctx)
    test = self()
    events = for stage <- [:opened, :withdrawn, :expired], do: [:cyfr, :sanctum, :question, stage]

    :telemetry.attach_many(
      {__MODULE__, test},
      events,
      fn event, _measurements, meta, _config ->
        send(test, {:question, List.last(event), meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, test}) end)

    # A formula's root, and a catalyst child of it running and asking.
    %{parent_execution_id: parent} = AttemptFixtures.lineage!(ctx)
    child = Prima.UUID7.execution_id()
    {:ok, grant} = Sanctum.ExecutionStanding.capture(ctx)

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: child,
          root_execution_id: parent,
          parent_execution_id: parent,
          reference: @node <> ":1.0.0",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "catalyst",
          origin: :interactive
        },
        boot_id: Opus.Record.boot_id(),
        lease_until: DateTime.add(DateTime.utc_now(), 120, :second),
        grant: grant,
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    run = %{
      execution_id: child,
      attempt_id: attempt.attempt,
      root_execution_id: parent,
      component_ref: @node <> ":1.0.0",
      release_digest: component.release_digest,
      caller: "person",
      deadline: DateTime.add(DateTime.utc_now(), 600, :second)
    }

    request = %{
      action: "delete_table",
      summary: "Drop the table users",
      operation: "DROP TABLE users",
      masked: false,
      request_digest:
        Question.request_digest("delete_table", "Drop the table users", "DROP TABLE users")
    }

    assert {:pending, ref} = Sanctum.Questions.ask(ctx, run, 1, request)
    assert_receive {:question, :opened, %{ref: ^ref}}

    assert :ok = Opus.Cascade.fail_children_of(parent)

    assert %{state: "ended"} = Arca.Repo.get!(Arca.Schemas.Question, ref)
    assert_receive {:question, :withdrawn, %{ref: ^ref}}
    refute_receive {:question, _stage, %{ref: ^ref}}, 200
  end

  defp end!(ctx, fixture) do
    Arca.Execution.record_end(
      Prima.Actor.in_athanor(ctx.athanor_id),
      fixture.execution_id,
      "cancelled",
      %{completed_at: DateTime.utc_now(), duration_ms: 1},
      fixture.attempt,
      grant: :stored,
      verify: fn _grant -> :ok end
    )
  end

  defp atoms(ask),
    do: %{action: ask["action"], summary: ask["summary"], operation: ask["operation"]}

  defp no_questions?(ctx) do
    Arca.Repo.all(from(q in Arca.Schemas.Question, where: q.athanor_id == ^ctx.athanor_id)) == []
  end
end
