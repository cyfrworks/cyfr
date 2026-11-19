# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.QuestionTest do
  @moduledoc """
  A catalyst's ask, end to end: the question probe
  (`test_wasm/question_probe` of the runtime's suite) run by the runtime in a runner
  of its own, over the suite's wire (`Cyfr.Test.TwoServices`), through
  CYFR's host (`Opus.Host.Question`) to `Sanctum.Questions`, and answered
  by its person through `question.answer`.

  The probe asks before each statement it is handed and reports what it
  was told. A person's allow and deny reach it; a run nobody can be asked
  for is told `unattended`, an undeclared action `invalid`, and an ask
  whose answer is lost twice `unavailable`, while its card stays until the
  run ends. A lost opening answer is asked again and opens one question;
  an ask past its root's allowance is admitted once there is room, and a
  retry of an admitted ask spends nothing; two admissions of one key at
  once leave one question and take the allowance once. A stop racing an
  allow hands the ended attempt nothing. A stop, a lapse and the run's
  deadline each end the wait and announce the fact that ended it, and the
  deadline a question carries is never later than the runner's end of the
  run. A dispensed credential is masked in the summary and the operation.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Cyfr.Test.{AttemptFixtures, TwoServices}
  alias Sanctum.Consent.{Commit, Plan}

  @moduletag timeout: 300_000

  @probe Path.expand(
           "../../../../locus/test/support/runtime/test_wasm/question_probe/question_probe.wasm",
           __DIR__
         )

  @asks [
    %{"name" => "delete_table", "title" => "delete a table"},
    %{"name" => "delete_rows", "title" => "delete rows from a table"}
  ]

  @limits %{
    "timeout" => "1m",
    "max_memory_bytes" => 67_108_864,
    "max_request_size" => 1_048_576,
    "max_response_size" => 5_242_880,
    "rate_limit" => %{"requests" => 10_000, "window" => "1m"}
  }

  @events [
    [:cyfr, :sanctum, :question, :opened],
    [:cyfr, :sanctum, :question, :answered],
    [:cyfr, :sanctum, :question, :expired],
    [:cyfr, :sanctum, :question, :withdrawn]
  ]

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()
    Prima.Test.RateLimiter.reset!()
    on_exit(&Prima.Test.RateLimiter.reset!/0)

    %{ctx: ctx} = person = person!()
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id) end)
    Cyfr.Test.Sandbox.stop_work_on_exit()
    Sanctum.TestContext.ready!(ctx.athanor_id)

    test = self()

    :telemetry.attach_many(
      {__MODULE__, test},
      @events,
      fn event, _measurements, meta, _config ->
        send(test, {:question, List.last(event), meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, test}) end)
    Map.put(person, :ref, publish!(ctx, "question-probe"))
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person with their own athanor and a signed-in session there: their
  # page's context, which starts a run and answers its card.
  defp person! do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|asker-#{n}",
        provider: "github",
        email: "asker#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)
    _account = Sanctum.TestContext.account!(user.id)

    built =
      Sanctum.Context.build(
        user_id: user.id,
        email: user.email,
        provider: "passkey",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{ctx: Sanctum.TestContext.via(ctx, :prism)}
  end

  # The probe, published as the person's own catalyst declaring its two
  # actions, and consented; `needs` and `caps` as `opts` name them.
  defp publish!(ctx, name, opts \\ []) do
    name = "#{name}-#{System.unique_integer([:positive])}"

    manifest =
      %{
        "name" => name,
        "version" => "1.0.0",
        "type" => "catalyst",
        "publisher" => "local",
        "asks" => Keyword.get(opts, :asks, @asks),
        "needs" => Keyword.get(opts, :needs, %{}),
        "caps" =>
          Map.merge(
            %{"limits" => Map.merge(@limits, Keyword.get(opts, :limits, %{}))},
            Keyword.get(opts, :caps, %{})
          )
      }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    ref = "catalyst:local." <> name
    if Keyword.get(opts, :consent, true), do: consent!(ctx, ref)
    ref
  end

  defp consent!(ctx, ref) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = %{ref: ref, bindings: []}
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, _committed} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })
  end

  # A root of the probe handed `statements`, run by the runtime in a task:
  # its id and the task, which answers what `Opus.run_root/5` answered.
  defp start!(ctx, ref, statements) when is_list(statements),
    do: start!(ctx, ref, %{"operation" => "run", "params" => %{"statements" => statements}})

  defp start!(ctx, ref, input) when is_map(input) do
    id = Prima.UUID7.execution_id()
    callers = [self() | Process.get(:"$callers", [])]

    task =
      Task.async(fn ->
        Process.put(:"$callers", callers)
        Opus.run_root(ctx, :default, pinned(ref), input, execution_id: id)
      end)

    {id, task}
  end

  # A reference pinned at 1.0.0, unless it names its version.
  defp pinned(ref) do
    if length(String.split(ref, ":")) == 3, do: ref, else: ref <> ":1.0.0"
  end

  # What the probe reported for each statement, once its run completed.
  defp answers!(id, task) do
    Task.await(task, 120_000)
    TwoServices.settled!()

    assert [%{args: %{"outcome" => %{"output" => %{"status" => 200, "data" => data}}}}] =
             TwoServices.calls(:complete, id)

    Enum.map(data["results"], & &1["answer"])
  end

  defp opened! do
    assert_receive {:question, :opened, %{ref: ref}}, 60_000
    ref
  end

  defp answer(ctx, ref, effect) do
    Sanctum.Gate.call_external("question", ctx, %{
      "action" => "answer",
      "ref" => ref,
      "answer" => %{"effect" => effect, "lasts" => "once"}
    })
  end

  defp questions(id) do
    Arca.Repo.all(
      from(q in Arca.Schemas.Question, where: q.execution_id == ^id, order_by: q.ask_no)
    )
  end

  defp question!(ref), do: Arca.Repo.get!(Arca.Schemas.Question, ref)

  # The root's ask allowance on this member as the limiter holds it: its
  # count and how long its window has been open.
  @rate_table :cyfr_rate_limiter
  defp allowance_key(ctx, id), do: {:question, ctx.athanor_id, id}

  defp spent(ctx, id) do
    case :ets.lookup(@rate_table, allowance_key(ctx, id)) do
      [{_key, count, _started}] -> count
      [] -> 0
    end
  end

  # The allowance full, its window closing `closes_in_ms` from now.
  defp fill_allowance!(ctx, id, closes_in_ms) do
    started = System.monotonic_time(:millisecond) - (60_000 - closes_in_ms)
    :ets.insert(@rate_table, {allowance_key(ctx, id), 60, started})
  end

  # The first `n` calls of `callback` the run made, once the wire has
  # recorded them: a wait still on the wire never settles it.
  defp recorded!(callback, id, n, tries \\ 300) do
    case TwoServices.calls(callback, id) do
      calls when length(calls) >= n ->
        Enum.take(calls, n)

      _fewer when tries > 0 ->
        # sleep-ok: poll interval of recorded!'s bounded wait (300 tries) for the wire to record
        # the calls
        Process.sleep(100)
        recorded!(callback, id, n, tries - 1)

      calls ->
        flunk("#{length(calls)} #{callback} calls recorded, #{n} awaited")
    end
  end

  # The wire's answers to the run's waits, as CYFR wrote them.
  defp wait_answers(id), do: for(call <- TwoServices.calls(:question_wait, id), do: call.answer)

  # ---------------------------------------------------------------------------
  # Answers
  # ---------------------------------------------------------------------------

  test "the person's allow and deny reach the component, each on its own card", %{
    ctx: ctx,
    ref: ref
  } do
    {id, task} = start!(ctx, ref, ["DROP TABLE users", "DELETE FROM users WHERE id = 1"])

    first = opened!()
    assert {:ok, %{state: "allowed"}} = answer(ctx, first, "allow")
    second = opened!()
    assert {:ok, %{state: "denied"}} = answer(ctx, second, "deny")

    assert answers!(id, task) == ~w(allowed denied)

    assert [one, two] = questions(id)
    assert {one.ref, one.ask_no, one.action, one.state} == {first, 1, "delete_table", "allowed"}
    assert {two.ref, two.ask_no, two.action, two.state} == {second, 2, "delete_rows", "denied"}
    assert one.summary == "drop the table users"
    assert one.operation == "DROP TABLE users"
    assert one.caller == "person"
    refute one.masked
    assert one.component_ref == ref <> ":1.0.0"
    assert one.release_digest =~ ~r/\Asha256:[0-9a-f]{64}\z/
    assert one.decided_by == ctx.user_id
  end

  test "a run nobody can be asked for is told unattended, and an undeclared action invalid", %{
    ctx: ctx,
    ref: ref
  } do
    unattended = Sanctum.TestContext.via(ctx, :api)
    {id, task} = start!(unattended, ref, ["DROP TABLE users"])
    assert answers!(id, task) == ~w(unattended)

    # The unattended ask was admitted and recorded.
    assert [%{ask_no: 1, state: "none", none_reason: "unattended"}] = questions(id)

    # A release whose manifest leaves delete_rows out is told its ask under
    # that action is invalid, and the ask leaves no row.
    tables_only = publish!(ctx, "question-probe-tables", asks: [hd(@asks)])
    {id, task} = start!(ctx, tables_only, ["DELETE FROM users WHERE id = 1"])
    assert answers!(id, task) == ~w(invalid)
    assert questions(id) == []
    refute_received {:question, :opened, _meta}
  end

  test "a statement of two actions joined is declined, and nobody is asked", %{
    ctx: ctx,
    ref: ref
  } do
    {id, task} = start!(ctx, ref, ["DELETE FROM users WHERE id = 1; DROP TABLE users"])
    assert answers!(id, task) == ~w(declined)
    assert TwoServices.calls(:question_ask, id) == []
    assert questions(id) == []
  end

  test "an ask whose wait is answered lost twice is told unavailable, and its card stays until the run ends",
       %{ctx: ctx, ref: ref} do
    TwoServices.plan!(:question_wait, [:drop, :drop])
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    ref_open = opened!()

    assert answers!(id, task) == ~w(unavailable)
    assert TwoServices.seen(:question_wait) |> Enum.take(2) == [:drop, :drop]

    # The card stood while the run did; the run's end closed it.
    assert %{state: "ended"} = question!(ref_open)
    assert_receive {:question, :withdrawn, %{ref: ^ref_open}}
  end

  # ---------------------------------------------------------------------------
  # Retries and pacing
  # ---------------------------------------------------------------------------

  test "a lost opening answer is asked again as the same body and opens one question", %{
    ctx: ctx,
    ref: ref
  } do
    TwoServices.plan!(:question_ask, [:forward_then_drop])
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    question = opened!()

    # The repeat finds the first's row: pending, nothing opened again.
    assert [first, again] = recorded!(:question_ask, id, 2)
    assert first.args == again.args
    assert again.answer == %{"v" => 1, "ok" => %{"pending" => true}}
    refute_received {:question, :opened, _meta}
    assert spent(ctx, id) == 1

    assert {:ok, _} = answer(ctx, question, "allow")
    assert answers!(id, task) == ~w(allowed)
    assert [_one] = questions(id)
  end

  test "a paced ask is admitted once there is room, and a retry of an admitted ask spends nothing",
       %{ctx: ctx, ref: ref} do
    id = Prima.UUID7.execution_id()
    fill_allowance!(ctx, id, 1_000)
    input = %{"operation" => "run", "params" => %{"statements" => ["DROP TABLE users"]}}
    callers = [self() | Process.get(:"$callers", [])]

    task =
      Task.async(fn ->
        Process.put(:"$callers", callers)
        Opus.run_root(ctx, :default, ref <> ":1.0.0", input, execution_id: id)
      end)

    question = opened!()
    assert [paced, admitted] = recorded!(:question_ask, id, 2)
    assert %{"ok" => %{"retry_after_ms" => ms}} = paced.answer
    assert ms in 1..1_000
    assert admitted.args == paced.args
    assert admitted.answer == %{"v" => 1, "ok" => %{"pending" => true}}
    # The new window holds the one ask admitted.
    assert spent(ctx, id) == 1

    # The allowance full again, the admitted ask asked once more as its
    # runner would: answered from its row, the allowance untouched.
    fill_allowance!(ctx, id, 30_000)
    runner = AttemptFixtures.current!(ctx.athanor_id, id)

    assert %{"ok" => %{"pending" => true}} =
             AttemptFixtures.call(runner, "question_ask", paced.args)

    assert spent(ctx, id) == 60

    assert {:ok, _} = answer(ctx, question, "allow")
    assert answers!(id, task) == ~w(allowed)
  end

  test "two admissions of one key at once leave one question and take the allowance once", %{
    ctx: ctx,
    ref: ref
  } do
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    first = opened!()
    runner = AttemptFixtures.current!(ctx.athanor_id, id)

    args = %{
      "ask_no" => 2,
      "action" => "delete_rows",
      "summary" => "Delete every row of the table users",
      "operation" => "DELETE FROM users"
    }

    answered =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> AttemptFixtures.call(runner, "question_ask", args) end)
      end)
      |> Task.await_many(30_000)

    assert answered == List.duplicate(%{"v" => 1, "ok" => %{"pending" => true}}, 2)
    assert [_one, %{ask_no: 2}] = questions(id)
    assert spent(ctx, id) == 2
    assert_receive {:question, :opened, %{ref: second}}
    refute_received {:question, :opened, _meta}

    for ref <- [first, second], do: assert({:ok, _} = answer(ctx, ref, "allow"))
    assert answers!(id, task) == ~w(allowed)
  end

  # ---------------------------------------------------------------------------
  # Ends
  # ---------------------------------------------------------------------------

  test "a stop racing the delivery of an allow hands the ended attempt nothing", %{
    ctx: ctx,
    ref: ref
  } do
    TwoServices.hold!(:question_wait, fn _row, _call -> true end, once: true)
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    question = opened!()
    assert_receive {:held, ^id, conn}, 30_000
    test = self()
    handler = {__MODULE__, :inside_the_wait}
    on_exit(fn -> :telemetry.detach(handler) end)

    # The person allows and stops the run inside the host's wait: right
    # after the wait's first read of its open question, in the wait's own
    # process, so its next read finds the allow and the stop already
    # made. The wait finds the allow, and is answered lost.
    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() != test and meta[:source] == "questions" and
               meta.query =~ ~s("ask_no") and not Arca.Repo.in_transaction?() do
            :telemetry.detach(handler)
            send(test, {:stopped, answer(ctx, question, "allow"), Opus.cancel(ctx, id)})
          end
        end,
        nil
      )

    TwoServices.release!(conn)
    assert_receive {:stopped, {:ok, %{state: "allowed"}}, {:ok, _cancelled}}, 30_000

    Task.await(task, 120_000)
    TwoServices.settled!()

    answers = wait_answers(id)
    refute Enum.any?(answers, &match?(%{"ok" => %{"answer" => "allowed"}}, &1)), inspect(answers)
    assert %{"error" => "lost"} = List.first(answers)

    # The guest, told it cannot ask, may finish before its runner is
    # killed and its completion be forwarded: none carries an allow.
    completed =
      for %{args: args} <- TwoServices.calls(:complete, id),
          result <- get_in(args, ["outcome", "output", "data", "results"]) || [],
          do: result["answer"]

    refute "allowed" in completed, inspect(completed)

    # The stop leaves the person's answer on its question and the run
    # recorded as stopped.
    assert %{state: "allowed"} = question!(question)
    assert %{status: "cancelled"} = Arca.Repo.get!(Arca.Schemas.Execution, id)
  end

  test "a stop ends the wait and announces it withdrawn", %{ctx: ctx, ref: ref} do
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    question = opened!()
    assert {:ok, _} = Opus.cancel(ctx, id)
    Task.await(task, 120_000)

    assert_receive {:question, :withdrawn, %{ref: ^question}}, 30_000
    refute_received {:question, :expired, _meta}
    assert %{state: "ended"} = question!(question)
    assert {:error, _closed} = answer(ctx, question, "allow")
  end

  test "a lapse ends the wait and announces it withdrawn", %{ctx: ctx, ref: ref} do
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    question = opened!()
    runner = AttemptFixtures.current!(ctx.athanor_id, id)

    # The runner's worker service reports it exited holding the attempt.
    assert :ok =
             Opus.Lapse.dispatched(runner.service, runner.boot, runner.runner, [runner.attempt])

    assert_receive {:question, :withdrawn, %{ref: ^question}}, 30_000
    assert %{state: "ended"} = question!(question)
    Task.await(task, 120_000)
  end

  test "the run's deadline ends the wait and announces it expired; the question's deadline is never later",
       %{ctx: ctx} do
    ref = publish!(ctx, "question-probe-brief", limits: %{"timeout" => "3s"})
    started = DateTime.utc_now()
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    question = opened!()
    deadline = question!(question).deadline

    # The run's own deadline: its whole timeout from its start, no less.
    assert DateTime.diff(deadline, started, :millisecond) >= 3_000
    Task.await(task, 120_000)

    assert_receive {:question, :expired, %{ref: ^question}}, 30_000
    refute_received {:question, :withdrawn, _meta}

    # The runner ended the run at its budget, at or after the deadline the
    # card showed; an answer after it is refused.
    %{completed_at: ended, status: "failed"} = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert DateTime.compare(deadline, ended) != :gt, "#{deadline} shown, #{ended} ended"
    assert {:error, _closed} = answer(ctx, question, "allow")
    assert %{state: "ended"} = question!(question)
  end

  test "an answer past the question's deadline is refused while the runner's end of the run is still on its way",
       %{ctx: ctx} do
    ref = publish!(ctx, "question-probe-held", limits: %{"timeout" => "4s"})
    started = DateTime.utc_now()
    {id, task} = start!(ctx, ref, ["DROP TABLE users"])
    TwoServices.hold!(:fail, id, once: true)
    question = opened!()
    %{deadline: deadline} = question!(question)

    # The run's own deadline: its whole timeout from its start, no less.
    assert DateTime.diff(deadline, started, :millisecond) >= 4_000

    # The runner ended the run at its budget and its failure is held on the
    # wire: the card's deadline has passed, though the run is still open,
    # and the answer is refused all the same.
    assert_receive {:held, ^id, conn}, 30_000
    assert DateTime.compare(DateTime.utc_now(), deadline) == :gt
    assert %{status: "running"} = Arca.Repo.get!(Arca.Schemas.Execution, id)
    assert {:error, _closed} = answer(ctx, question, "allow")
    assert %{state: "open"} = question!(question)

    TwoServices.release!(conn)
    Task.await(task, 120_000)
    assert_receive {:question, :expired, %{ref: ^question}}, 30_000
  end

  # ---------------------------------------------------------------------------
  # Children
  # ---------------------------------------------------------------------------

  @nested Path.expand("support/test_wasm/nested_probe/nested_probe.wasm", __DIR__)

  # The nested probe published as a formula of the person's own under
  # `name` and `version`, naming `static` as its static dependencies, and
  # consented: its reference.
  defp formula!(ctx, name, version, static) do
    manifest =
      %{
        "name" => name,
        "version" => version,
        "type" => "formula",
        "caps" => %{"tools" => ["execution.run"]}
      }
      |> then(fn manifest ->
        if static == [],
          do: manifest,
          else:
            Map.put(manifest, "dependencies", %{"static" => Enum.map(static, &%{"ref" => &1})})
      end)

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@nested), %{
        name: name,
        version: version,
        type: "formula",
        manifest: Jason.encode!(manifest)
      })

    app = "formula:local." <> name
    consent!(ctx, app)
    app
  end

  # The formula's call that runs the probe on one statement.
  defp probe_call(probe) do
    %{
      "tool" => "execution",
      "action" => "run",
      "args" => %{
        "reference" => probe <> ":1.0.0",
        "input" => %{"operation" => "run", "params" => %{"statements" => ["DROP TABLE users"]}}
      }
    }
  end

  # The probe's question, asked `depth` runs below `root`: its row names
  # the probe's own release and the root, it spends the root's allowance
  # alone, and the person's allow reaches the probe.
  defp asked_below!(ctx, probe, root, task, depth) do
    question = opened!()
    row = question!(question)
    {:ok, _ref, _type, component} = Opus.Admission.inspect_component(ctx, probe <> ":1.0.0")

    assert row.root_execution_id == root
    assert row.release_digest == component["release_digest"]
    assert row.component_ref == probe <> ":1.0.0"
    assert row.caller == "person"
    assert ancestors(row.execution_id) |> length() == depth
    assert List.last(ancestors(row.execution_id)) == root
    assert spent(ctx, root) == 1
    assert spent(ctx, row.execution_id) == 0

    assert {:ok, _} = answer(ctx, question, "allow")
    Task.await(task, 120_000)
    TwoServices.settled!()

    assert [%{args: %{"outcome" => %{"output" => %{"data" => data}}}}] =
             TwoServices.calls(:complete, row.execution_id)

    assert [%{"answer" => "allowed"}] = data["results"]
    assert [_completed] = TwoServices.calls(:complete, root)
  end

  # The runs above `id`, nearest first.
  defp ancestors(id) do
    case Arca.Repo.get!(Arca.Schemas.Execution, id).parent_execution_id do
      nil -> []
      parent -> [parent | ancestors(parent)]
    end
  end

  test "a formula's static child asks under its own release, and spends its root's allowance", %{
    ctx: ctx,
    ref: probe
  } do
    app = formula!(ctx, "question-app-#{System.unique_integer([:positive])}", "1.0.0", [probe])
    {root, task} = start!(ctx, app, %{"op" => "call", "request" => probe_call(probe)})
    asked_below!(ctx, probe, root, task, 1)
  end

  test "a catalyst a formula dispatches dynamically asks under its own release", %{
    ctx: ctx,
    ref: probe
  } do
    app = formula!(ctx, "question-app-#{System.unique_integer([:positive])}", "1.0.0", [])
    {root, task} = start!(ctx, app, %{"op" => "call", "request" => probe_call(probe)})
    asked_below!(ctx, probe, root, task, 1)
  end

  test "a child of a child asks under its own release, and spends its root's allowance", %{
    ctx: ctx,
    ref: probe
  } do
    # The nested probe calls itself by this reference, one level down,
    # and that child runs the probe.
    app = formula!(ctx, "nested-probe", "0.1.0", [])

    {root, task} =
      start!(ctx, app <> ":0.1.0", %{"op" => "chain", "depth" => 1, "leaf" => probe_call(probe)})

    asked_below!(ctx, probe, root, task, 2)
  end

  # ---------------------------------------------------------------------------
  # Masking
  # ---------------------------------------------------------------------------

  test "a credential dispensed to the run is masked in the summary and the operation", %{
    ctx: ctx
  } do
    needs = %{
      "api_key" => %{
        "type" => "oauth:step-stub",
        "reason" => "to hold a credential the run is dispensed",
        "required" => true,
        "fields" => ["STUB_API_KEY"],
        "scopes" => TwoServices.stub_scopes(),
        "hosts" => [TwoServices.stub_host()]
      }
    }

    ref =
      publish!(ctx, "question-probe-masked",
        needs: needs,
        caps: %{"egress" => %{"domains" => [TwoServices.stub_host()]}},
        consent: false
      )

    # A token the probe reads as a table's name.
    token = "tok_#{System.unique_integer([:positive])}_question"
    [_key, ^token] = TwoServices.arm!(ctx, ref, key: "key-question-probe", token: token)

    {id, task} = start!(ctx, ref, ["DROP TABLE #{token}"])
    question = opened!()
    row = question!(question)
    assert row.masked
    refute row.summary =~ token
    refute row.operation =~ token
    assert row.summary =~ "[REDACTED]"
    assert row.operation == "DROP TABLE [REDACTED]"

    assert {:ok, _} = answer(ctx, question, "deny")
    assert answers!(id, task) == ~w(denied)
  end
end
