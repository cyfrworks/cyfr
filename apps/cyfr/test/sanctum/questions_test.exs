# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.QuestionsTest do
  @moduledoc """
  A component's questions decided and answered, called directly with no
  runner (`Sanctum.Questions`) and through the gate (`question.*`): every
  exit and refusal of an ask, the answer door and who may use it, the
  match of a standing answer, the fresh confirmation the widest answer
  takes, the announcements after each winning write, and a removed
  catalyst's answers.
  """

  use ExUnit.Case, async: false

  alias Prima.Question.Answer
  alias Sanctum.Context
  alias Sanctum.Questions
  alias Sanctum.TestContext
  alias Sanctum.TestContext.Authenticator

  @events [
    [:cyfr, :sanctum, :question, :opened],
    [:cyfr, :sanctum, :question, :answered],
    [:cyfr, :sanctum, :question, :expired],
    [:cyfr, :sanctum, :question, :withdrawn]
  ]
  @component "catalyst:local.tables:1.0.0"
  @asks [
    %{"name" => "delete_table", "title" => "delete a table"},
    %{"name" => "delete_rows", "title" => "delete rows from a table"}
  ]

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    Prima.Test.RateLimiter.reset!()

    base = Path.join(System.tmp_dir!(), "questions_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Arca.StorageReserve.put(:ok)
      Prima.Test.RateLimiter.reset!()
      File.rm_rf!(base)
    end)

    Prima.Test.Env.put_app_env(:arca, :base_path, base)

    Cyfr.Test.SeedBundle.isolate!()
    Sanctum.Test.Newcomers.directory!()

    person = person!("questions")
    component = ship!(person.ctx, "catalyst", "tables", "1.0.0", @asks)
    pid = self()

    :telemetry.attach_many(
      {__MODULE__, pid},
      @events,
      fn event, _measurements, meta, _config ->
        send(pid, {:question, List.last(event), meta, Arca.Repo.in_transaction?()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, pid}) end)

    Map.merge(person, %{release: component.release_digest})
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A person with their own athanor, an account whose passkey answers here,
  # and the context their session establishes there.
  defp person!(tag) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|#{tag}-#{n}",
        provider: "github",
        email: "#{tag}#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)
    _account = TestContext.account!(user.id)
    %{user: user, athanor: athanor, ctx: session_ctx(user, athanor)}
  end

  defp session_ctx(user, athanor) do
    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "passkey",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    ctx
  end

  defp ship!(ctx, type, name, version, asks) do
    manifest =
      %{"name" => name, "type" => type, "version" => version, "publisher" => "local"}
      |> then(&if(type == "catalyst", do: Map.put(&1, "asks", asks), else: &1))

    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, type, "local", name, version,
        manifest: manifest,
        wasm: Cyfr.Test.Guests.wasm(type)
      )

    component
  end

  # A running root of the catalyst in the person's athanor, with its
  # current attempt, as the host hands it to an ask.
  defp run!(%{ctx: ctx, release: release}, opts \\ []) do
    id = Prima.UUID7.execution_id()

    {:ok, grant} =
      Sanctum.ExecutionStanding.capture(
        Context.internal(athanor_id: ctx.athanor_id, scope: :athanor)
      )

    {:ok, %{attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: id,
          root_execution_id: id,
          reference: Keyword.get(opts, :reference, @component),
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
      component_ref: Keyword.get(opts, :reference, @component),
      release_digest: Keyword.get(opts, :release, release),
      caller: Keyword.get(opts, :caller, "person"),
      deadline: Keyword.get(opts, :deadline, DateTime.add(DateTime.utc_now(), 600, :second))
    }
  end

  defp request(attrs \\ %{}) do
    base = %{
      action: "delete_table",
      summary: "Drop the table users in the project acme",
      operation: "DROP TABLE users;\n\t-- whole",
      masked: false
    }

    request = Map.merge(base, attrs)

    Map.put_new(
      request,
      :request_digest,
      Base.encode16(:crypto.hash(:sha256, inspect(request)), case: :lower)
    )
  end

  # The context a run asks under: the person it acts as, its root's origin.
  defp asking(ctx, origin \\ :interactive), do: %{ctx | origin: origin}

  defp end!(ctx, run, status \\ "cancelled") do
    Arca.Execution.record_end(
      Prima.Actor.in_athanor(ctx.athanor_id),
      run.execution_id,
      status,
      %{completed_at: DateTime.utc_now(), duration_ms: 1},
      run.attempt_id,
      grant: :stored,
      verify: fn _grant -> :ok end
    )
  end

  defp call(ctx, action, args),
    do: Sanctum.Gate.call_external("question", ctx, Map.put(args, "action", action))

  defp row(ctx, ref) do
    {:ok, row} = Arca.Questions.get(Context.actor(ctx), ref)
    row
  end

  defp rows(ctx) do
    import Ecto.Query

    Arca.Repo.all(
      from(q in Arca.Schemas.Question, where: q.athanor_id == ^ctx.athanor_id, select: q.ref)
    )
  end

  defp standing(ctx, publisher \\ "local", name \\ "tables") do
    {:ok, rows} = Arca.Questions.standing(Context.actor(ctx), ctx.user_id, publisher, name)
    rows
  end

  defp answer(json), do: elem(Answer.decode(json), 1)
  defp once(effect), do: answer(%{"effect" => effect, "lasts" => "once"})

  defp hour_from_now,
    do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

  defp put!(ctx, attrs) do
    {:ok, row} =
      Arca.Questions.put_standing(
        Context.actor(ctx),
        Map.merge(
          %{
            publisher: "local",
            name: "tables",
            action: "delete_table",
            declaration_digest:
              Prima.Manifest.Asks.digest(%{name: "delete_table", title: "delete a table"}),
            caller: "any",
            effect: "allow",
            until: nil
          },
          attrs
        ),
        verify: fn -> :ok end
      )

    row
  end

  defp open!(person, opts \\ []) do
    run = run!(person, opts)
    assert {:pending, ref} = Questions.ask(asking(person.ctx), run, 1, request())
    assert_receive {:question, :opened, %{ref: ^ref}, false}
    {run, ref}
  end

  # The confirmation's secret, the record proven by the person's passkey.
  defp proven!(ctx, id) do
    ref = Prima.Confirmation.ref(id)

    assert {:ok, %{request: encoded}} =
             Sanctum.Gate.call_external("confirmation", ctx, %{
               "action" => "request",
               "ref" => ref
             })

    {:ok, request} = Prima.SignIn.decode(encoded)
    account = TestContext.account!(ctx.user_id)

    fragment =
      account.authenticator
      |> Authenticator.answer(request, account.identifier)
      |> Prima.SignIn.fragment()

    assert {:ok, %{state: "confirmed"}} =
             Sanctum.Gate.call_external("confirmation", ctx, %{
               "action" => "confirm",
               "ref" => ref,
               "answer" => fragment
             })
  end

  # ---------------------------------------------------------------------------
  # An ask
  # ---------------------------------------------------------------------------

  describe "an ask" do
    test "opens a question for an interactive run, announced once after the commit", person do
      run = run!(person)
      assert {:pending, ref} = Questions.ask(asking(person.ctx), run, 1, request())

      assert_receive {:question, :opened, meta, false}
      assert meta.ref == ref
      assert meta.athanor_id == person.ctx.athanor_id
      assert meta.user_id == person.ctx.user_id
      assert meta.label == "tables wants to delete a table"
      assert %DateTime{} = meta.opened_at
      assert DateTime.compare(meta.expires_at, run.deadline) == :eq
      refute_receive {:question, _, _, _}, 50

      stored = row(person.ctx, ref)
      assert stored.state == "open"
      assert stored.title == "delete a table"
      assert stored.caller == "person"
      assert stored.operation == "DROP TABLE users;\n\t-- whole"
    end

    test "is refused none(invalid), with no row, for each malformed request", person do
      run = run!(person)

      for {label, run, ask_no, request} <- [
            {"ask number", run, 0, request()},
            {"action", run, 1, request(%{action: "Delete"})},
            {"long summary", run, 1, request(%{summary: String.duplicate("a", 201)})},
            {"two-line summary", run, 1, request(%{summary: "one\ntwo"})},
            {"direction override", run, 1, request(%{summary: "x\u202Ey"})},
            {"control in operation", run, 1, request(%{operation: "DROP\a"})},
            {"zero width in operation", run, 1, request(%{operation: "DROP\u200B"})},
            {"digest", run, 1, request(%{request_digest: "nothex"})},
            {"caller", %{run | caller: "any"}, 1, request()},
            {"release digest", %{run | release_digest: "abc"}, 1, request()}
          ] do
        assert Questions.ask(asking(person.ctx), run, ask_no, request) ==
                 {:answer, {:none, :invalid}},
               label
      end

      assert rows(person.ctx) == []
      refute_receive {:question, _, _, _}, 50
    end

    test "a summary of 200 characters and an operation of lines and tabs are asked", person do
      run = run!(person)

      assert {:pending, _ref} =
               Questions.ask(
                 asking(person.ctx),
                 run,
                 1,
                 request(%{summary: String.duplicate("é", 200), operation: "a\r\nb\tc"})
               )
    end

    test "an action the running release does not declare is none(invalid)", person do
      run = run!(person)

      assert {:answer, {:none, :invalid}} =
               Questions.ask(asking(person.ctx), run, 1, request(%{action: "drop_database"}))

      other = "sha256:" <> String.duplicate("0", 64)

      assert {:answer, {:none, :invalid}} =
               Questions.ask(asking(person.ctx), %{run | release_digest: other}, 2, request())

      assert {:answer, {:none, :invalid}} =
               Questions.ask(
                 asking(person.ctx),
                 %{run | component_ref: "reagent:local.tables:1.0.0"},
                 3,
                 request()
               )

      assert rows(person.ctx) == []
    end

    test "a run that acts as no person is none(unattended), with no row", person do
      run = run!(person)
      webhook = %{asking(person.ctx, :webhook) | user_id: "webhook:hook"}
      public = %{asking(person.ctx) | anonymous: true}

      assert {:answer, {:none, :unattended}} = Questions.ask(webhook, run, 1, request())
      assert {:answer, {:none, :unattended}} = Questions.ask(public, run, 2, request())
      assert rows(person.ctx) == []
    end

    test "a root whose origin is not interactive is none(unattended), recorded, unannounced",
         person do
      for {origin, n} <- Enum.with_index([:programmatic, :schedule], 1) do
        run = run!(person)

        assert {:answer, {:none, :unattended}} =
                 Questions.ask(asking(person.ctx, origin), run, n, request())

        assert {:ok, %{state: "none", none_reason: "unattended"}} =
                 Arca.Questions.by_key(Context.actor(person.ctx), run.attempt_id, n)
      end

      refute_receive {:question, _, _, _}, 50
    end

    test "a retry is given its first decision; another request under its number is invalid",
         person do
      run = run!(person)
      asked = request()

      assert :none = Questions.find(person.ctx, run.attempt_id, 1, asked.request_digest)
      assert {:pending, ref} = Questions.ask(asking(person.ctx), run, 1, asked)
      assert {:pending, ^ref} = Questions.ask(asking(person.ctx), run, 1, asked)

      assert {:pending, ^ref} =
               Questions.find(person.ctx, run.attempt_id, 1, asked.request_digest)

      assert {:answer, {:none, :invalid}} =
               Questions.ask(asking(person.ctx), run, 1, request(%{summary: "Something else"}))

      assert {:error, :changed} =
               Questions.find(person.ctx, run.attempt_id, 1, "0" <> String.duplicate("a", 63))

      assert {:ok, _} = Questions.answer(person.ctx, ref, once("allow"))
      assert {:answer, :allowed} = Questions.ask(asking(person.ctx), run, 1, asked)

      assert {:answer, :allowed} =
               Questions.find(person.ctx, run.attempt_id, 1, asked.request_digest)

      assert [^ref] = rows(person.ctx)
    end

    test "a retry is given its row even after the component left the athanor", person do
      run = run!(person)
      asked = request()
      assert {:pending, ref} = Questions.ask(asking(person.ctx), run, 1, asked)

      :ok =
        Arca.ComponentStorage.delete_component(
          Context.actor(person.ctx),
          "tables",
          "1.0.0",
          "local",
          "catalyst"
        )

      assert {:pending, ^ref} = Questions.ask(asking(person.ctx), run, 1, asked)
      assert {:answer, {:none, :invalid}} = Questions.ask(asking(person.ctx), run, 2, request())
    end

    test "a run that ended leaves no row and is not allowed", person do
      run = run!(person)
      {:ok, _} = end!(person.ctx, run)

      assert {:answer, {:none, :unavailable}} =
               Questions.ask(asking(person.ctx), run, 1, request())

      assert rows(person.ctx) == []
      refute_receive {:question, _, _, _}, 50
    end

    test "an ask is found only in its own athanor, by its own person", person do
      run = run!(person)
      asked = request()
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), run, 1, asked)
      other = person!("questions-find")
      assert :none = Questions.find(other.ctx, run.attempt_id, 1, asked.request_digest)
      assert {:answer, {:none, :invalid}} = Questions.wait(other.ctx, run.attempt_id, 1, 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Standing answers
  # ---------------------------------------------------------------------------

  describe "a standing answer that covers an ask" do
    test "answers it with no card and names itself; an allow and a deny alike", person do
      allow = put!(person.ctx, %{})
      run = run!(person)
      assert {:answer, :allowed} = Questions.ask(asking(person.ctx), run, 1, request())

      assert {:ok, %{state: "allowed", standing_answer_id: id, decided_by: nil}} =
               Arca.Questions.by_key(Context.actor(person.ctx), run.attempt_id, 1)

      assert id == allow.id

      put!(person.ctx, %{effect: "deny"})
      assert {:answer, :denied} = Questions.ask(asking(person.ctx), run, 2, request())
      refute_receive {:question, _, _, _}, 50
    end

    test "covers an unattended run of the same person", person do
      put!(person.ctx, %{})
      run = run!(person)

      assert {:answer, :allowed} =
               Questions.ask(asking(person.ctx, :programmatic), run, 1, request())
    end

    test "this caller's beats any caller's, both ways", person do
      put!(person.ctx, %{effect: "deny"})
      put!(person.ctx, %{caller: "agent:helper", effect: "allow"})

      agent = run!(person, caller: "agent:helper")
      page = run!(person)
      assert {:answer, :allowed} = Questions.ask(asking(person.ctx), agent, 1, request())
      assert {:answer, :denied} = Questions.ask(asking(person.ctx), page, 1, request())

      put!(person.ctx, %{effect: "allow"})
      put!(person.ctx, %{caller: "person", effect: "deny"})
      assert {:answer, :denied} = Questions.ask(asking(person.ctx), page, 2, request())
      assert {:answer, :allowed} = Questions.ask(asking(person.ctx), agent, 2, request())
    end

    test "an unknown caller is covered only by an answer for any caller", person do
      put!(person.ctx, %{caller: "unknown"})
      unknown = run!(person, caller: "unknown")
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), unknown, 1, request())

      put!(person.ctx, %{caller: "any", effect: "deny"})
      assert {:answer, :denied} = Questions.ask(asking(person.ctx), unknown, 2, request())
    end

    test "an allow given under other words is stale and asks again; a deny stays", person do
      reworded = Prima.Manifest.Asks.digest(%{name: "delete_table", title: "remove a table"})
      put!(person.ctx, %{declaration_digest: reworded})
      run = run!(person)
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), run, 1, request())

      put!(person.ctx, %{declaration_digest: reworded, effect: "deny"})
      assert {:answer, :denied} = Questions.ask(asking(person.ctx), run, 2, request())
    end

    test "one whose deadline passed covers nothing", person do
      put!(person.ctx, %{until: DateTime.add(DateTime.utc_now(), -1, :second)})
      run = run!(person)
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), run, 1, request())
    end

    test "another action's, component's or person's covers nothing", person do
      put!(person.ctx, %{action: "delete_rows"})
      put!(person.ctx, %{name: "other"})
      other = person!("questions-other")
      put!(other.ctx, %{})

      run = run!(person)
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), run, 1, request())
    end
  end

  # ---------------------------------------------------------------------------
  # The answer door
  # ---------------------------------------------------------------------------

  describe "the answer door" do
    test "pending lists the person's open questions with their previews", person do
      {run, ref} = open!(person)

      assert {:ok, %{questions: [%{ref: ^ref, preview: preview}]}} =
               call(person.ctx, "pending", %{})

      assert preview == %{
               "publisher" => "local",
               "name" => "tables",
               "release_digest" => person.release,
               "action" => "delete_table",
               "title" => "delete a table",
               "summary" => "Drop the table users in the project acme",
               "operation" => "DROP TABLE users;\n\t-- whole",
               "caller" => "person",
               "deadline" => DateTime.to_iso8601(row(person.ctx, ref).deadline),
               "masked" => false
             }

      assert {:ok, %{questions: [%{ref: ^ref}]}} = call(person.ctx, "pending", %{"ref" => ref})
      assert {:ok, %{questions: []}} = call(person.ctx, "pending", %{"ref" => "q_other"})
      _ = run
    end

    test "allow once decides the question, writes no permission, announces once", person do
      {run, ref} = open!(person)

      assert {:ok, %{ref: ^ref, state: "allowed"}} =
               call(person.ctx, "answer", %{
                 "ref" => ref,
                 "answer" => %{"effect" => "allow", "lasts" => "once"}
               })

      assert_receive {:question, :answered, %{ref: ^ref, expires_at: _}, false}
      refute_receive {:question, _, _, _}, 50
      assert row(person.ctx, ref).decided_by == person.ctx.user_id
      assert standing(person.ctx) == []
      assert {:answer, :allowed} = Questions.wait(person.ctx, run.attempt_id, 1, 0)
    end

    test "a dismissed card is don't allow, once", person do
      {run, ref} = open!(person)
      assert {:ok, %{state: "denied"}} = Questions.answer(person.ctx, ref, once("deny"))
      assert standing(person.ctx) == []
      assert {:answer, :denied} = Questions.wait(person.ctx, run.attempt_id, 1, 0)
    end

    test "an answer that lasts stands, for this caller or any, on the session", person do
      {_run, ref} = open!(person, caller: "device:pcl_1")
      until = hour_from_now()

      assert {:ok, %{state: "allowed"}} =
               call(person.ctx, "answer", %{
                 "ref" => ref,
                 "answer" => %{
                   "effect" => "allow",
                   "lasts" => %{"until" => DateTime.to_iso8601(until)},
                   "covers" => "this_caller"
                 }
               })

      assert [%{caller: "device:pcl_1", effect: "allow", until: stored, question_ref: ^ref}] =
               standing(person.ctx)

      assert DateTime.compare(stored, until) == :eq

      {_run, second} = open!(person)

      assert {:ok, %{state: "denied"}} =
               Questions.answer(
                 person.ctx,
                 second,
                 answer(%{"effect" => "deny", "lasts" => "always", "covers" => "any_caller"})
               )

      assert [%{caller: "any", effect: "deny", until: nil}] = standing(person.ctx)
    end

    test "an allow for this caller, always, needs the session alone", person do
      {_run, ref} = open!(person)

      assert {:ok, %{state: "allowed"}} =
               Questions.answer(
                 person.ctx,
                 ref,
                 answer(%{"effect" => "allow", "lasts" => "always", "covers" => "this_caller"})
               )

      assert [%{caller: "person", until: nil}] = standing(person.ctx)
    end

    test "of two answers at once one wins and one is announced", person do
      {_run, ref} = open!(person)

      results =
        [once("allow"), once("deny")]
        |> Enum.map(fn choice ->
          Task.async(fn -> Questions.answer(person.ctx, ref, choice) end)
        end)
        |> Enum.map(&Task.await/1)

      assert [{:ok, %{state: won}}] = Enum.filter(results, &match?({:ok, _}, &1))

      assert [{:error, %Prima.Refusal{class: :conflict}}] =
               Enum.filter(results, &match?({:error, _}, &1))

      assert row(person.ctx, ref).state == won
      assert_receive {:question, :answered, %{ref: ^ref}, false}
      refute_receive {:question, :answered, _, _}, 100
    end

    test "an answer after the run ended, or past its deadline, is refused", person do
      {run, ref} = open!(person)
      {:ok, %{closed_questions: [%{ref: ^ref}]}} = end!(person.ctx, run)

      assert {:error, %Prima.Refusal{class: :conflict, reason: :not_pending}} =
               Questions.answer(person.ctx, ref, once("allow"))

      {_run, late} = open!(person, deadline: DateTime.add(DateTime.utc_now(), 1, :second))
      Process.sleep(1100)

      assert {:error, %Prima.Refusal{class: :conflict}} =
               Questions.answer(person.ctx, late, once("allow"))

      refute_receive {:question, :answered, _, _}, 50
    end

    test "another person, or another athanor, finds no question", person do
      {_run, ref} = open!(person)
      other = person!("questions-stranger")

      assert {:error, {:not_found, "question", ^ref}} =
               Questions.answer(other.ctx, ref, once("allow"))

      assert {:ok, %{questions: []}} = call(other.ctx, "pending", %{})
      assert row(person.ctx, ref).state == "open"
    end

    test "a key, a frame and a chain are refused", person do
      {_run, ref} = open!(person)

      key =
        Context.build(
          user_id: person.ctx.user_id,
          athanor_id: person.ctx.athanor_id,
          scope: :athanor,
          permissions: [:*],
          auth_method: :api_key,
          api_key_id: "key_questions",
          authenticated: true
        )

      chain = Context.enter_guest(person.ctx)
      frame = %{person.ctx | auth_method: :tincture}

      operations = [
        {"pending", %{}},
        {"answer", %{"ref" => ref, "answer" => %{"effect" => "allow", "lasts" => "once"}}},
        {"answers", %{"publisher" => "local", "name" => "tables"}},
        {"set",
         %{
           "publisher" => "local",
           "name" => "tables",
           "action_name" => "delete_table",
           "standing" => %{"effect" => "allow", "caller" => "person"}
         }},
        {"forget", %{"id" => "qan_x"}}
      ]

      for {action, args} <- operations do
        assert {:error, _} = call(key, action, args), "key reached question.#{action}"
      end

      assert {:error, %Prima.Refusal{class: :unauthenticated}} =
               Questions.answer(key, ref, once("allow"))

      assert {:error, %Prima.Refusal{class: :unauthenticated}} =
               Questions.answer(chain, ref, once("allow"))

      assert {:error, %Prima.Refusal{class: :unauthenticated}} = Questions.pending(chain)
      assert {:error, %Prima.Refusal{class: :unauthenticated}} = Questions.pending(frame)

      assert {:error, %Prima.Refusal{class: :unauthenticated}} =
               Questions.answer(frame, ref, once("deny"))

      assert {:error, %Prima.Refusal{class: :unauthenticated}} =
               Questions.set(chain, "local", "tables", "delete_table", %Prima.Question.Standing{
                 effect: :allow,
                 caller: :person
               })

      assert {:error, %Prima.Refusal{class: :unauthenticated}} = Questions.forget(chain, "qan_x")

      for %{action: action} = op <- Sanctum.Providers.Question.definition().operations do
        assert op.planes == [:external], action
        assert op.consent == :interactive, action
      end

      assert row(person.ctx, ref).state == "open"
    end

    test "a paired device's answer counts", person do
      {_run, ref} = open!(person)
      %{ctx: device} = Sanctum.Test.Devices.paired!(person.ctx.user_id)

      assert {:ok, %{questions: [%{ref: ^ref}]}} = call(device, "pending", %{})

      assert {:ok, %{state: "denied"}} =
               call(device, "answer", %{
                 "ref" => ref,
                 "answer" => %{"effect" => "deny", "lasts" => "once"}
               })
    end

    test "this caller is refused for a run whose caller is unknown; a passed time too", person do
      {_run, ref} = open!(person, caller: "unknown")

      assert {:error, %Prima.Refusal{reason: :unknown_caller}} =
               Questions.answer(
                 person.ctx,
                 ref,
                 answer(%{"effect" => "allow", "lasts" => "always", "covers" => "this_caller"})
               )

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      assert {:error, %Prima.Refusal{reason: :until_passed}} =
               Questions.answer(
                 person.ctx,
                 ref,
                 answer(%{
                   "effect" => "deny",
                   "lasts" => %{"until" => past},
                   "covers" => "any_caller"
                 })
               )

      assert {:error, {:invalid_argument, _}} =
               call(person.ctx, "answer", %{"ref" => ref, "answer" => %{"effect" => "maybe"}})

      assert row(person.ctx, ref).state == "open"
    end

    test "a waiting ask sees an answer given meanwhile", person do
      {run, ref} = open!(person)
      waiter = Task.async(fn -> Questions.wait(person.ctx, run.attempt_id, 1, 5_000) end)
      Process.sleep(100)
      {:ok, _} = Questions.answer(person.ctx, ref, once("allow"))
      assert {:answer, :allowed} = Task.await(waiter)
      assert :pending != Questions.wait(person.ctx, run.attempt_id, 1, 0)
      assert {:answer, {:none, :invalid}} = Questions.wait(person.ctx, run.attempt_id, 9, 0)
    end

    test "a wait that times out answers pending", person do
      {run, _ref} = open!(person)
      assert :pending = Questions.wait(person.ctx, run.attempt_id, 1, 600)
    end
  end

  # ---------------------------------------------------------------------------
  # The fresh confirmation
  # ---------------------------------------------------------------------------

  describe "always allow, for any caller" do
    @widest %{"effect" => "allow", "lasts" => "always", "covers" => "any_caller"}

    test "on the card, is written only after its confirmation", person do
      {run, ref} = open!(person)
      args = %{"ref" => ref, "answer" => @widest}

      assert {:error, {:confirmation_required, %{id: id, operation: "question.answer"}}} =
               call(person.ctx, "answer", args)

      assert row(person.ctx, ref).state == "open"
      assert standing(person.ctx) == []
      refute_receive {:question, :answered, _, _}, 50

      proven!(person.ctx, id)
      repeat = %{person.ctx | confirmation_id: id}
      assert {:ok, %{state: "allowed"}} = call(repeat, "answer", args)
      assert [%{caller: "any", effect: "allow", until: nil}] = standing(person.ctx)
      assert_receive {:question, :answered, %{ref: ^ref}, false}

      assert {:ok, %{state: "consumed"}} =
               Arca.PendingConfirmations.get(
                 Context.actor(person.ctx),
                 Prima.Confirmation.ref(id)
               )

      assert {:answer, :allowed} = Questions.wait(person.ctx, run.attempt_id, 1, 0)
    end

    test "a proof for another answer, or already spent, does not write it", person do
      {_run, ref} = open!(person)
      {_run, other} = open!(person)
      {_run, third} = open!(person)

      {:error, {:confirmation_required, %{id: id}}} =
        call(person.ctx, "answer", %{"ref" => other, "answer" => @widest})

      proven!(person.ctx, id)
      repeat = %{person.ctx | confirmation_id: id}

      assert {:error, {:confirmation_required, %{id: fresh}}} =
               call(repeat, "answer", %{"ref" => ref, "answer" => @widest})

      assert fresh != id
      assert row(person.ctx, ref).state == "open"

      assert {:ok, %{state: "allowed"}} =
               call(repeat, "answer", %{"ref" => other, "answer" => @widest})

      assert {:error, {:confirmation_required, _}} =
               call(repeat, "answer", %{"ref" => third, "answer" => @widest})

      assert row(person.ctx, third).state == "open"
    end

    test "a proof for an answer whose question ended writes nothing", person do
      {run, ref} = open!(person)

      {:error, {:confirmation_required, %{id: id}}} =
        call(person.ctx, "answer", %{"ref" => ref, "answer" => @widest})

      proven!(person.ctx, id)
      {:ok, _} = end!(person.ctx, run)

      assert {:error, %Prima.Refusal{reason: :not_pending}} =
               call(%{person.ctx | confirmation_id: id}, "answer", %{
                 "ref" => ref,
                 "answer" => @widest
               })

      assert standing(person.ctx) == []
    end

    test "on question.set, is written only after its confirmation; a reworded title asks again",
         person do
      args = %{
        "publisher" => "local",
        "name" => "tables",
        "action_name" => "delete_table",
        "standing" => %{"effect" => "allow", "until" => nil, "caller" => "any"}
      }

      assert {:error, {:confirmation_required, %{id: id, operation: "question.set"}}} =
               call(person.ctx, "set", args)

      assert standing(person.ctx) == []
      proven!(person.ctx, id)

      # A newer version rewords the action: the proof names the old words.
      ship!(person.ctx, "catalyst", "tables", "1.1.0", [
        %{"name" => "delete_table", "title" => "remove a table"}
      ])

      repeat = %{person.ctx | confirmation_id: id}
      assert {:error, {:confirmation_required, %{id: fresh}}} = call(repeat, "set", args)
      assert standing(person.ctx) == []

      proven!(person.ctx, fresh)

      assert {:ok, %{caller: "any", effect: "allow", declaration_digest: digest}} =
               call(%{person.ctx | confirmation_id: fresh}, "set", args)

      assert digest ==
               Prima.Manifest.Asks.digest(%{name: "delete_table", title: "remove a table"})
    end

    test "every other answer set beforehand needs the session alone", person do
      for standing <- [
            %{"effect" => "allow", "until" => nil, "caller" => "person"},
            %{
              "effect" => "allow",
              "until" => DateTime.to_iso8601(hour_from_now()),
              "caller" => "any"
            },
            %{"effect" => "deny", "until" => nil, "caller" => "any"}
          ] do
        assert {:ok, %{effect: _}} =
                 call(person.ctx, "set", %{
                   "publisher" => "local",
                   "name" => "tables",
                   "action_name" => "delete_rows",
                   "standing" => standing
                 })
      end

      # The deny for any caller removed the allow for one caller.
      assert [%{caller: "any", effect: "deny"}] = standing(person.ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Setting, listing and forgetting
  # ---------------------------------------------------------------------------

  describe "permissions set beforehand" do
    defp set(ctx, action, standing),
      do:
        call(ctx, "set", %{
          "publisher" => "local",
          "name" => "tables",
          "action_name" => action,
          "standing" => standing
        })

    test "cover a later run; answers lists them with the callers asked before", person do
      {_run, ref} = open!(person, caller: "agent:helper")
      {:ok, _} = Questions.answer(person.ctx, ref, once("deny"))

      assert {:ok, %{id: id}} =
               set(person.ctx, "delete_table", %{"effect" => "deny", "caller" => "agent:helper"})

      run = run!(person, caller: "agent:helper")
      assert {:answer, :denied} = Questions.ask(asking(person.ctx), run, 1, request())

      assert {:ok, %{answers: [%{id: ^id, caller: "agent:helper"}], callers: ["agent:helper"]}} =
               call(person.ctx, "answers", %{"publisher" => "local", "name" => "tables"})

      assert {:ok, %{}} = call(person.ctx, "forget", %{"id" => id})
      assert standing(person.ctx) == []
      assert {:error, {:not_found, "permission", ^id}} = Questions.forget(person.ctx, id)
    end

    test "are refused for an undeclared action, an unknown caller or a passed time", person do
      assert {:error, %Prima.Refusal{reason: :undeclared}} =
               set(person.ctx, "drop_database", %{"effect" => "deny", "caller" => "any"})

      assert {:error, %Prima.Refusal{reason: :unknown_caller}} =
               set(person.ctx, "delete_table", %{"effect" => "deny", "caller" => "unknown"})

      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

      assert {:error, %Prima.Refusal{reason: :until_passed}} =
               set(person.ctx, "delete_table", %{
                 "effect" => "allow",
                 "until" => past,
                 "caller" => "person"
               })

      assert {:error, {:invalid_argument, _}} =
               set(person.ctx, "delete_table", %{"effect" => "allow", "caller" => "nobody"})

      assert {:error, {:not_found, "component", _}} =
               call(person.ctx, "set", %{
                 "publisher" => "local",
                 "name" => "absent",
                 "action_name" => "delete_table",
                 "standing" => %{"effect" => "deny", "caller" => "any"}
               })

      assert standing(person.ctx) == []
    end

    test "another person's permission cannot be listed or forgotten", person do
      {:ok, %{id: id}} = set(person.ctx, "delete_table", %{"effect" => "deny", "caller" => "any"})
      other = person!("questions-forget")

      assert {:error, {:not_found, "permission", ^id}} =
               call(other.ctx, "forget", %{"id" => id})

      assert {:ok, %{answers: [], callers: []}} =
               call(other.ctx, "answers", %{"publisher" => "local", "name" => "tables"})

      assert [%{id: ^id}] = standing(person.ctx)
    end

    test "a declared restore's effect: questions ended, allows gone, denies kept", person do
      {_run, _ref} = open!(person)
      set(person.ctx, "delete_table", %{"effect" => "allow", "caller" => "person"})
      set(person.ctx, "delete_rows", %{"effect" => "deny", "caller" => "any"})

      {:ok, _} = Arca.SecurityTransitions.mark_restore(Prima.Actor.system())
      {:ok, _} = Arca.SecurityTransitions.restore(slot: :none)
      ctx = session_ctx(person.user, person.athanor)

      assert {:ok, %{questions: []}} = call(ctx, "pending", %{})

      assert {:ok, %{answers: [%{action: "delete_rows", effect: "deny"}]}} =
               call(ctx, "answers", %{"publisher" => "local", "name" => "tables"})
    end
  end

  # ---------------------------------------------------------------------------
  # While the storage reserve is spent
  # ---------------------------------------------------------------------------

  describe "below the storage reserve's mark" do
    test "the reads are admitted and the writes refused by the gate", person do
      {_run, ref} = open!(person)
      Arca.StorageReserve.put(:depleted)

      assert {:ok, %{questions: [%{ref: ^ref}]}} = call(person.ctx, "pending", %{})

      assert {:ok, %{answers: []}} =
               call(person.ctx, "answers", %{"publisher" => "local", "name" => "tables"})

      reserve = Arca.StorageReserve.refusal()

      for {action, args} <- [
            {"answer", %{"ref" => ref, "answer" => %{"effect" => "deny", "lasts" => "once"}}},
            {"set",
             %{
               "publisher" => "local",
               "name" => "tables",
               "action_name" => "delete_table",
               "standing" => %{"effect" => "deny", "caller" => "any"}
             }},
            {"forget", %{"id" => "qan_x"}}
          ] do
        assert {:error, %Prima.Refusal{class: :unavailable, reason: ^reserve}} =
                 call(person.ctx, action, args),
               action
      end

      Arca.StorageReserve.put(:ok)
      assert row(person.ctx, ref).state == "open"
    end
  end

  # ---------------------------------------------------------------------------
  # Run ends and removals
  # ---------------------------------------------------------------------------

  describe "a run's end" do
    test "is announced for each question its write closed, by how it ended", person do
      {run, ref} = open!(person)
      {:ok, %{closed_questions: closed}} = end!(person.ctx, run)
      assert [%{ref: ^ref}] = closed

      :ok = Questions.ended(person.ctx.athanor_id, closed, :withdrawn)
      assert_receive {:question, :withdrawn, %{ref: ^ref, user_id: user_id}, false}
      assert user_id == person.ctx.user_id

      :ok = Questions.ended(person.ctx.athanor_id, closed, :expired)
      assert_receive {:question, :expired, %{ref: ^ref}, false}
      assert {:ok, %{questions: []}} = call(person.ctx, "pending", %{})
    end

    test "waiting lists the open questions for a person's attention", person do
      {_run, ref} = open!(person)

      assert {:ok,
              [%{ref: ^ref, label: "tables wants to delete a table", opened_at: %DateTime{}}]} =
               Questions.waiting(person.ctx)
    end
  end

  describe "a removal" do
    defp removed!(ctx, type, version) do
      :ok =
        Arca.ComponentStorage.delete_component(
          Context.actor(ctx),
          "tables",
          version,
          "local",
          type
        )

      Compendium.Cascade.name_removed(ctx, %{
        name: "tables",
        publisher: "local",
        version: version,
        component_type: type
      })
    end

    test "of the last catalyst deletes its answers, though a reagent of its name remains",
         person do
      ship!(person.ctx, "reagent", "tables", "1.0.0", [])
      put!(person.ctx, %{})
      put!(person.ctx, %{action: "delete_rows", effect: "deny"})

      :ok = removed!(person.ctx, "catalyst", "1.0.0")
      assert standing(person.ctx) == []
    end

    test "of a catalyst version while another remains deletes nothing", person do
      ship!(person.ctx, "catalyst", "tables", "1.1.0", @asks)
      put!(person.ctx, %{})

      :ok = removed!(person.ctx, "catalyst", "1.0.0")
      assert [_kept] = standing(person.ctx)
    end

    test "of a reagent version while another remains revokes nothing, as before", person do
      ship!(person.ctx, "reagent", "tables", "1.0.0", [])
      ship!(person.ctx, "reagent", "tables", "1.1.0", [])
      put!(person.ctx, %{})
      events = [[:cyfr, :sanctum, :consent, :changed]]
      pid = self()

      :telemetry.attach_many(
        {__MODULE__, :consent},
        events,
        fn _event, _m, meta, _c -> send(pid, {:consent, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :consent}) end)

      :ok = removed!(person.ctx, "reagent", "1.0.0")
      assert [_kept] = standing(person.ctx)
      refute_receive {:consent, _}, 50
    end
  end
end
