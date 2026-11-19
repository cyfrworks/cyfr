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
    {ctx, token} = session!(user, athanor)
    %{user: user, athanor: athanor, ctx: ctx, token: token}
  end

  defp session_ctx(user, athanor), do: elem(session!(user, athanor), 0)

  # A session of the person in their athanor: its context, as a page's
  # sign-in establishes it, and its token, which the HTTP API is called
  # with.
  defp session!(user, athanor) do
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
    {ctx, session.token}
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

  # The digest of an action's words as the fixture's catalyst declares
  # them: what a page that rendered them sends.
  defp shown(action) do
    title = Enum.find_value(@asks, "drop a database", &(&1["name"] == action && &1["title"]))
    Prima.Manifest.Asks.digest(%{name: action, title: title})
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
            {"line separator in summary", run, 1, request(%{summary: "one\u2028two"})},
            {"paragraph separator in summary", run, 1, request(%{summary: "one\u2029two"})},
            {"next line in summary", run, 1, request(%{summary: "one\u0085two"})},
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
      operation = "a\r\nb\tc\u2028d\u2029e"

      assert {:pending, ref} =
               Questions.ask(
                 asking(person.ctx),
                 run,
                 1,
                 request(%{summary: String.duplicate("é", 200), operation: operation})
               )

      assert row(person.ctx, ref).operation == operation
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
           "declaration_digest" => shown("delete_table"),
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
               Questions.set(
                 chain,
                 "local",
                 "tables",
                 "delete_table",
                 shown("delete_table"),
                 %Prima.Question.Standing{effect: :allow, caller: :person}
               )

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

    test "on question.set, is written only after its confirmation, under the words shown",
         person do
      args = %{
        "publisher" => "local",
        "name" => "tables",
        "action_name" => "delete_table",
        "declaration_digest" => shown("delete_table"),
        "standing" => %{"effect" => "allow", "until" => nil, "caller" => "any"}
      }

      assert {:error, {:confirmation_required, %{id: id, operation: "question.set"}}} =
               call(person.ctx, "set", args)

      assert standing(person.ctx) == []
      proven!(person.ctx, id)

      # A newer version rewords the action meanwhile: the words shown are
      # still an installed version's, and they are what is kept.
      ship!(person.ctx, "catalyst", "tables", "1.1.0", [
        %{"name" => "delete_table", "title" => "remove a table"}
      ])

      assert {:ok, %{caller: "any", effect: "allow", declaration_digest: digest}} =
               call(%{person.ctx | confirmation_id: id}, "set", args)

      assert digest == shown("delete_table")

      # The newer words are another answer, with a confirmation of their own.
      reworded = %{
        args
        | "declaration_digest" =>
            Prima.Manifest.Asks.digest(%{name: "delete_table", title: "remove a table"})
      }

      assert {:error, {:confirmation_required, %{id: fresh}}} = call(person.ctx, "set", reworded)
      refute fresh == id
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
                   "declaration_digest" => shown("delete_rows"),
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
          "declaration_digest" => shown(action),
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

    test "bind the words the person was shown, never another version's", person do
      v2 =
        ship!(person.ctx, "catalyst", "tables", "2.0.0", [
          %{"name" => "delete_table", "title" => "delete every table"}
        ])

      until = DateTime.to_iso8601(hour_from_now())

      assert {:ok, %{declaration_digest: digest}} =
               set(person.ctx, "delete_table", %{
                 "effect" => "allow",
                 "until" => until,
                 "caller" => "any"
               })

      assert digest == shown("delete_table")

      # It covers a run of the version whose words were shown, and asks
      # again in a run of the version that reworded them.
      assert {:answer, :allowed} = Questions.ask(asking(person.ctx), run!(person), 1, request())

      v2_run =
        run!(person, reference: "catalyst:local.tables:2.0.0", release: v2.release_digest)

      assert {:pending, _ref} = Questions.ask(asking(person.ctx), v2_run, 1, request())
    end

    test "are refused for another action's words, or the same words of another component",
         person do
      title = "delete the warehouse"

      ship!(person.ctx, "catalyst", "warehouse", "1.0.0", [
        %{"name" => "delete_table", "title" => title}
      ])

      for digest <- [
            shown("delete_rows"),
            Prima.Manifest.Asks.digest(%{name: "delete_table", title: title})
          ] do
        assert {:error, %Prima.Refusal{reason: :undeclared}} =
                 call(person.ctx, "set", %{
                   "publisher" => "local",
                   "name" => "tables",
                   "action_name" => "delete_table",
                   "declaration_digest" => digest,
                   "standing" => %{"effect" => "deny", "caller" => "any"}
                 })
      end

      assert standing(person.ctx) == []
    end

    test "are refused while the component facts cannot be read", person do
      port = Sanctum.Consent.Components

      # The port with nothing installed, as before boot installs it, for
      # this one call; restored as it was however the test ends.
      Prima.Test.Env.without_persistent_term({port, :impl}, fn ->
        assert {:error, :component_facts_unavailable} =
                 port.get_latest(person.ctx, "tables", "local", "catalyst")

        assert {:error, :unavailable} =
                 set(person.ctx, "delete_table", %{
                   "effect" => "allow",
                   "caller" => "any",
                   "until" => DateTime.to_iso8601(hour_from_now())
                 })
      end)

      assert standing(person.ctx) == []
    end

    test "are refused when the version shown is removed after its words were read", person do
      handler = {__MODULE__, :removed_after_read}
      on_exit(fn -> :telemetry.detach(handler) end)
      test = self()

      # The first read of the registry that the set makes is followed at
      # once by the version's removal, which finds no answer yet to delete.
      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] == "components" do
              :telemetry.detach(handler)

              :ok =
                Arca.ComponentStorage.delete_component(
                  Context.actor(person.ctx),
                  "tables",
                  "1.0.0",
                  "local",
                  "catalyst"
                )

              send(test, :removed)
            end
          end,
          nil
        )

      {:ok, until_hour} =
        Prima.Question.Standing.decode(%{
          "effect" => "allow",
          "caller" => "any",
          "until" => DateTime.to_iso8601(hour_from_now())
        })

      result =
        Questions.set(
          person.ctx,
          "local",
          "tables",
          "delete_table",
          shown("delete_table"),
          until_hour
        )

      assert_received :removed
      assert {:error, %Prima.Refusal{reason: :undeclared}} = result
      assert standing(person.ctx) == []
    end

    test "are refused when the words shown are no installed version's", person do
      # A digest no version declares.
      assert {:error, %Prima.Refusal{reason: :undeclared}} =
               call(person.ctx, "set", %{
                 "publisher" => "local",
                 "name" => "tables",
                 "action_name" => "delete_table",
                 "declaration_digest" => String.duplicate("0", 64),
                 "standing" => %{"effect" => "deny", "caller" => "any"}
               })

      # The version that was shown is replaced by one that rewords the
      # action between the page's rendering and its submitting.
      ship!(person.ctx, "catalyst", "tables", "2.0.0", [
        %{"name" => "delete_table", "title" => "delete every table"}
      ])

      :ok =
        Arca.ComponentStorage.delete_component(
          Context.actor(person.ctx),
          "tables",
          "1.0.0",
          "local",
          "catalyst"
        )

      assert {:error, %Prima.Refusal{reason: :undeclared}} =
               set(person.ctx, "delete_table", %{"effect" => "deny", "caller" => "any"})

      assert standing(person.ctx) == []
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
                 "declaration_digest" => shown("delete_table"),
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

  describe "the declaration a permission rests on" do
    # A catalyst `local.archive` at 1.0.0 declaring `delete_table` titled
    # `title`, published through the registry: its row as the port reads it.
    defp publish_archive!(ctx, title) do
      manifest = %{
        "name" => "archive",
        "publisher" => "local",
        "version" => "1.0.0",
        "type" => "catalyst",
        "asks" => [%{"name" => "delete_table", "title" => title}]
      }

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm("catalyst"), %{
          type: "catalyst",
          name: "archive",
          publisher: "local",
          version: "1.0.0",
          manifest: Jason.encode!(manifest)
        })

      {:ok, row} = Sanctum.Consent.Components.get_latest(ctx, "archive", "local", "catalyst")
      row
    end

    defp archive_run!(person, release),
      do:
        run!(person,
          reference: "catalyst:local.archive:1.0.0",
          release: release.release_digest
        )

    defp for_an_hour(effect),
      do: %{
        "effect" => effect,
        "lasts" => %{"until" => DateTime.to_iso8601(hour_from_now())},
        "covers" => "any_caller"
      }

    test "a waiting card's lasting answer is refused once the component has left, and a reinstall asks again",
         person do
      release = publish_archive!(person.ctx, "delete a table")

      assert {:pending, ref} =
               Questions.ask(asking(person.ctx), archive_run!(person, release), 1, request())

      assert_receive {:question, :opened, %{ref: ^ref}, false}

      assert {:ok, :deleted} = Compendium.Registry.delete(person.ctx, "archive", "1.0.0", "local")

      assert {:error, %Prima.Refusal{reason: :removed, message: message}} =
               call(person.ctx, "answer", %{"ref" => ref, "answer" => for_an_hour("allow")})

      assert message =~ "No installed version asks for this permission in these words"
      assert standing(person.ctx, "local", "archive") == []
      assert row(person.ctx, ref).state == "open"
      refute_received {:question, :answered, _meta, _in_transaction}

      # Installed again, its next run is asked: nothing stood in between.
      release = publish_archive!(person.ctx, "delete a table")

      assert {:pending, _ref} =
               Questions.ask(asking(person.ctx), archive_run!(person, release), 1, request())
    end

    test "a release deleted and published again before anything after the removal asks starts again",
         person do
      release = publish_archive!(person.ctx, "delete a table")

      assert {:pending, ref} =
               Questions.ask(asking(person.ctx), archive_run!(person, release), 1, request())

      assert {:ok, _} =
               call(person.ctx, "answer", %{"ref" => ref, "answer" => for_an_hour("allow")})

      assert [_allow] = standing(person.ctx, "local", "archive")
      handler = {__MODULE__, :reinstalled}
      on_exit(fn -> :telemetry.detach(handler) end)
      test = self()

      # The removal's row is deleted; at the first read after it outside
      # any transaction, before the registry's delete answers, the release
      # is published again.
      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            cond do
              self() != test ->
                :ok

              String.starts_with?(meta.query, ~s(DELETE FROM "components")) ->
                Process.put(handler, :deleted)

              Process.get(handler) == :deleted and not Arca.Repo.in_transaction?() ->
                :telemetry.detach(handler)
                send(test, {:reinstalled, publish_archive!(person.ctx, "delete a table")})

              true ->
                :ok
            end
          end,
          nil
        )

      assert {:ok, :deleted} = Compendium.Registry.delete(person.ctx, "archive", "1.0.0", "local")
      assert_received {:reinstalled, release}
      assert standing(person.ctx, "local", "archive") == []

      assert {:pending, _ref} =
               Questions.ask(asking(person.ctx), archive_run!(person, release), 1, request())
    end

    test "a card whose component has left is still answered once, and leaves nothing standing",
         person do
      release = publish_archive!(person.ctx, "delete a table")

      assert {:pending, ref} =
               Questions.ask(asking(person.ctx), archive_run!(person, release), 1, request())

      assert {:ok, :deleted} = Compendium.Registry.delete(person.ctx, "archive", "1.0.0", "local")

      assert {:ok, %{state: "allowed"}} =
               call(person.ctx, "answer", %{
                 "ref" => ref,
                 "answer" => %{"effect" => "allow", "lasts" => "once"}
               })

      assert standing(person.ctx, "local", "archive") == []
    end

    test "a release published again under the same version in other words refuses the words shown",
         person do
      publish_archive!(person.ctx, "delete a table")
      handler = {__MODULE__, :republished}
      on_exit(fn -> :telemetry.detach(handler) end)
      test = self()

      # Right after the set reads the release, it is removed and published
      # again under the same version, in other words.
      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, meta, _config ->
            if self() == test and meta[:source] == "components" do
              :telemetry.detach(handler)

              {:ok, :deleted} =
                Compendium.Registry.delete(person.ctx, "archive", "1.0.0", "local")

              send(test, {:republished, publish_archive!(person.ctx, "delete every table")})
            end
          end,
          nil
        )

      result =
        call(person.ctx, "set", %{
          "publisher" => "local",
          "name" => "archive",
          "action_name" => "delete_table",
          "declaration_digest" => shown("delete_table"),
          "standing" => %{"effect" => "deny", "caller" => "any"}
        })

      assert_received {:republished, %{manifest: manifest}}
      assert inspect(manifest) =~ "delete every table"
      assert {:error, %Prima.Refusal{reason: :undeclared}} = result
      assert standing(person.ctx, "local", "archive") == []
    end
  end

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
               "declaration_digest" => shown("delete_table"),
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
    # `local.archive` of `type` at `version`, published through the
    # registry into `ctx`'s athanor; a catalyst declares the fixture's
    # actions.
    defp publish!(ctx, type, version) do
      manifest =
        %{"name" => "archive", "publisher" => "local", "version" => version, "type" => type}
        |> then(&if(type == "catalyst", do: Map.put(&1, "asks", @asks), else: &1))

      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(type), %{
          type: type,
          name: "archive",
          publisher: "local",
          version: version,
          manifest: Jason.encode!(manifest)
        })

      :ok
    end

    defp delete!(ctx, version),
      do: assert({:ok, :deleted} = Compendium.Registry.delete(ctx, "archive", version, "local"))

    defp answers(ctx), do: standing(ctx, "local", "archive")

    defp archive_answer!(ctx, attrs \\ %{}), do: put!(ctx, Map.put(attrs, :name, "archive"))

    defp unit(type, version),
      do: Compendium.ComponentPath.version_dir(type, "local", "archive", version)

    # The catalyst `local.archive` at `version` committed into the tree as
    # a unit lands, with `description`; the registry derives its row.
    defp lay!(actor, version, description) do
      manifest = %{
        "name" => "archive",
        "publisher" => "local",
        "version" => version,
        "type" => "catalyst",
        "description" => description,
        "asks" => @asks
      }

      files = [
        {[Compendium.ComponentPath.wasm_name("catalyst")], Cyfr.Test.Guests.wasm("catalyst")},
        {[Compendium.ComponentPath.manifest_name()], Jason.encode!(manifest)}
      ]

      {:ok, _written} =
        Arca.Overlay.commit_unit(actor, unit("catalyst", version), {:files, files}, cap: :exempt)

      :ok
    end

    test "of the last catalyst release deletes its answers, though a reagent of its name remains",
         person do
      publish!(person.ctx, "reagent", "2.0.0")
      publish!(person.ctx, "catalyst", "1.0.0")
      archive_answer!(person.ctx)
      archive_answer!(person.ctx, %{action: "delete_rows", effect: "deny"})

      delete!(person.ctx, "1.0.0")
      assert answers(person.ctx) == []

      assert {:ok, _reagent} =
               Arca.ComponentStorage.get_component(
                 Context.actor(person.ctx),
                 "archive",
                 "2.0.0",
                 "local",
                 "reagent"
               )
    end

    test "of one of two catalyst releases keeps them, and of the second deletes them", person do
      publish!(person.ctx, "catalyst", "1.0.0")
      publish!(person.ctx, "catalyst", "1.1.0")
      archive_answer!(person.ctx)

      delete!(person.ctx, "1.0.0")
      assert [_kept] = answers(person.ctx)

      delete!(person.ctx, "1.1.0")
      assert answers(person.ctx) == []
    end

    test "of a reagent version while another remains revokes nothing, as before", person do
      publish!(person.ctx, "reagent", "1.0.0")
      publish!(person.ctx, "reagent", "1.1.0")
      publish!(person.ctx, "catalyst", "2.0.0")
      archive_answer!(person.ctx)
      events = [[:cyfr, :sanctum, :consent, :changed]]
      pid = self()

      :telemetry.attach_many(
        {__MODULE__, :consent},
        events,
        fn _event, _m, meta, _c -> send(pid, {:consent, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :consent}) end)

      delete!(person.ctx, "1.0.0")
      assert [_kept] = answers(person.ctx)
      refute_receive {:consent, _}, 50
    end

    test "of the last release by the projection's reconcile deletes its answers", person do
      publish!(person.ctx, "catalyst", "1.0.0")
      archive_answer!(person.ctx)

      :ok = Arca.delete_tree(Context.actor(person.ctx), unit("catalyst", "1.0.0"))

      assert {:error, :not_found} =
               Compendium.Registry.get(person.ctx, "archive", "1.0.0", "local")

      assert answers(person.ctx) == []
    end

    test "of a release the reconcile replaces in the same transaction keeps its answers",
         person do
      actor = Context.actor(person.ctx)
      laid = fn description -> lay!(actor, "1.0.0", description) end

      # A unit the tree derives its row from, laid as a unit lands.
      laid.("first")

      assert {:ok, %{description: "first"}} =
               Compendium.Registry.get(person.ctx, "archive", "1.0.0", "local")

      archive_answer!(person.ctx)

      # The same version's manifest rewritten in the tree: its row is
      # removed and written again by one replacement.
      laid.("rewritten")

      assert {:ok, %{description: "rewritten"}} =
               Compendium.Registry.get(person.ctx, "archive", "1.0.0", "local")

      assert [_kept] = answers(person.ctx)
    end

    test "rolled back keeps the answers it deleted", person do
      publish!(person.ctx, "catalyst", "1.0.0")
      archive_answer!(person.ctx)
      actor = Context.actor(person.ctx)

      assert {:error, :undone} =
               Arca.Repo.transaction(fn ->
                 :ok =
                   Arca.ComponentStorage.delete_component(
                     actor,
                     "archive",
                     "1.0.0",
                     "local",
                     "catalyst"
                   )

                 assert answers(person.ctx) == []
                 Arca.Repo.rollback(:undone)
               end)

      assert [_kept] = answers(person.ctx)

      assert {:ok, _release} =
               Arca.ComponentStorage.get_component(actor, "archive", "1.0.0", "local", "catalyst")
    end

    test "in one athanor leaves another's answers for the same component", person do
      other = person!("other-athanor")
      publish!(person.ctx, "catalyst", "1.0.0")
      publish!(other.ctx, "catalyst", "1.0.0")
      archive_answer!(person.ctx)
      archive_answer!(other.ctx)

      delete!(person.ctx, "1.0.0")
      assert answers(person.ctx) == []
      assert [_kept] = answers(other.ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # Who may use the door, through the gate
  # ---------------------------------------------------------------------------

  describe "every caller, through the gate, on all five operations" do
    # An open question to answer once and a permission to forget, both the
    # person's own.
    defp fixture!(person) do
      {_run, ref} = open!(person)
      %{id: id} = put!(person.ctx, %{action: "delete_table", caller: "agent:fixture"})
      %{ref: ref, id: id}
    end

    defp operations(fixture) do
      [
        {"pending", %{}},
        {"answer", %{"ref" => fixture.ref, "answer" => %{"effect" => "deny", "lasts" => "once"}}},
        {"answers", %{"publisher" => "local", "name" => "tables"}},
        {"set",
         %{
           "publisher" => "local",
           "name" => "tables",
           "action_name" => "delete_rows",
           "declaration_digest" => shown("delete_rows"),
           "standing" => %{"effect" => "deny", "caller" => "person"}
         }},
        {"forget", %{"id" => fixture.id}}
      ]
    end

    # Nothing a refused call could have changed has changed.
    defp untouched!(person, fixture) do
      assert row(person.ctx, fixture.ref).state == "open"
      assert [%{id: id, action: "delete_table"}] = standing(person.ctx)
      assert id == fixture.id
    end

    defp granting_authority do
      node = "formula:local.question-matrix"

      tools =
        Enum.map(Sanctum.Providers.Question.definition().operations, &"question.#{&1.action}")

      {:ok, blob} =
        Prima.Authority.Blob.parse(%{
          "canonical" => "jcs-1",
          "nodes" => %{
            node => %{
              "limits" => %{
                "timeout" => "1m",
                "max_memory_bytes" => 67_108_864,
                "max_request_size" => 1_048_576,
                "max_response_size" => 5_242_880,
                "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
                "max_concurrent_tasks" => 10,
                "batch_timeout" => "1m"
              },
              "edges" => %{"@ingress" => %{"tools" => tools}}
            }
          }
        })

      {:ok, auth} =
        Prima.Authority.root(
          %{
            profile_id: "prof-question-matrix",
            consent_id: "consent-question-matrix",
            source_ref: node,
            kind: :owner,
            invoke_mode: :open_inert,
            activation: %{node => "sha256:question-matrix"}
          },
          blob,
          ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
        )

      auth
    end

    # One `tools/call` to `/mcp` under the session's token, as a person's
    # own client calls the HTTP API: its decoded result, or its error.
    defp over_http(token, args) do
      body = %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{
          "name" => "question",
          "arguments" => args,
          "_meta" => %{
            Prima.MCP.Protocol.meta_protocol_version_key() => Prima.MCP.Protocol.version(),
            Prima.MCP.Protocol.meta_client_info_key() => %{"name" => "cyfr", "version" => "test"},
            Prima.MCP.Protocol.meta_client_capabilities_key() => %{}
          }
        }
      }

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
        |> Plug.Conn.put_req_header("mcp-protocol-version", Prima.MCP.Protocol.version())
        |> Plug.Conn.put_req_header("mcp-method", "tools/call")
        |> Plug.Conn.put_req_header("mcp-name", "question")
        |> Phoenix.ConnTest.dispatch(CyfrWeb.Endpoint, :post, "/mcp", Jason.encode!(body))

      case Jason.decode!(conn.resp_body) do
        %{"result" => %{"isError" => true} = result} -> {:error, result}
        %{"result" => %{"content" => [%{"text" => text}]}} -> {:ok, Jason.decode!(text)}
        other -> {:error, other}
      end
    end

    test "an API key is refused by the gate's consent class", person do
      fixture = fixture!(person)

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

      for {action, args} <- operations(fixture) do
        assert {:error,
                %Prima.Refusal{
                  class: :forbidden,
                  reason: {:consent_class_required, {:surface_not_permitted, :api_key}},
                  stage: :admission
                }} = call(key, action, args),
               action
      end

      untouched!(person, fixture)
    end

    # A frame's context is the person's, under the frame credential's
    # surface (`Sanctum.Caller`'s frame clause sets `auth_method:
    # :tincture` and `frame`); it is assembled here as that clause leaves it.
    test "a frame's credential is refused by the gate's consent class", person do
      fixture = fixture!(person)

      frame = %{
        person.ctx
        | auth_method: :tincture,
          session_token_hash: nil,
          frame: %{id: "fcr_questions", tincture: "tincture:local.board:1.0.0"}
      }

      for {action, args} <- operations(fixture) do
        assert {:error,
                %Prima.Refusal{
                  class: :forbidden,
                  reason: {:consent_class_required, {:surface_not_permitted, :tincture}},
                  stage: :admission
                }} = call(frame, action, args),
               action
      end

      untouched!(person, fixture)
    end

    test "a running chain a signed-in person started is refused: no action is in-chain", person do
      fixture = fixture!(person)
      chain = Context.enter_guest(%{person.ctx | origin: :interactive})
      auth = granting_authority()

      for {action, args} <- operations(fixture) do
        assert {:error, refusal} =
                 Sanctum.Gate.call_in_chain(
                   "question",
                   chain,
                   Map.put(args, "action", action),
                   auth,
                   lineage: Cyfr.Test.AttemptFixtures.lineage!(chain)
                 ),
               action

        sentence = "Tool action 'question.#{action}' is not reachable from a running chain"

        assert %Prima.Refusal{class: :internal, reason: ^sentence, stage: :admission} = refusal
      end

      untouched!(person, fixture)
    end

    test "an anonymous caller is refused before any consent is asked", person do
      fixture = fixture!(person)

      anonymous =
        Context.build(
          athanor_id: person.ctx.athanor_id,
          scope: :athanor,
          permissions: [],
          authenticated: false,
          anonymous: true
        )

      for {action, args} <- operations(fixture) do
        assert {:error,
                %Prima.Refusal{
                  class: :unauthenticated,
                  reason: {:tool_auth_required, "question"},
                  stage: :admission
                }} = call(anonymous, action, args),
               action
      end

      untouched!(person, fixture)
    end

    test "a signed-in page, a session on the HTTP API and a paired device are admitted",
         person do
      %{ctx: device} = Sanctum.Test.Devices.paired!(person.ctx.user_id)

      callers = [
        {"page", &PrismWeb.Ops.call_tool(person.ctx, "question", Map.put(&2, "action", &1))},
        {"http", &over_http(person.token, Map.put(&2, "action", &1))},
        {"device", &call(device, &1, &2)}
      ]

      for {surface, call} <- callers do
        fixture = fixture!(person)

        results =
          Map.new(operations(fixture), fn {action, args} -> {action, call.(action, args)} end)

        json = fn {:ok, result} -> result |> Jason.encode!() |> Jason.decode!() end

        assert %{"questions" => pending} = json.(results["pending"]), surface
        assert fixture.ref in Enum.map(pending, & &1["ref"]), surface
        assert %{"state" => "denied"} = json.(results["answer"]), surface
        assert %{"answers" => listed} = json.(results["answers"]), surface
        assert fixture.id in Enum.map(listed, & &1["id"]), surface

        assert %{"action" => "delete_rows", "effect" => "deny", "caller" => "person"} =
                 json.(results["set"]),
               surface

        assert {:ok, _empty} = results["forget"], surface
        refute fixture.id in Enum.map(standing(person.ctx), & &1.id), surface
        assert row(person.ctx, fixture.ref).state == "denied"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Ownership, one dimension at a time
  # ---------------------------------------------------------------------------

  # A person has one athanor and a session is focused on a seat of its
  # person alone, so no credential names another person in this athanor,
  # or this person in another athanor. Each case is the owner's boundary
  # (`Sanctum.Questions`) asked with the context assembled by hand: a real
  # session of one, refocused on the other's athanor.
  describe "ownership" do
    defp each_door(ctx, fixture) do
      %{
        pending: Questions.pending(ctx),
        one: Questions.pending(ctx, fixture.ref),
        answer: Questions.answer(ctx, fixture.ref, once("allow")),
        answers: Questions.answers(ctx, "local", "tables"),
        forget: Questions.forget(ctx, fixture.id)
      }
    end

    defp refused_every_door!(person, ctx) do
      {_run, ref} = open!(person)
      %{id: id} = put!(person.ctx, %{caller: "agent:owner"})
      fixture = %{ref: ref, id: id}
      doors = each_door(ctx, fixture)

      assert {:ok, []} = doors.pending
      assert {:ok, []} = doors.one
      assert {:error, {:not_found, "question", ^ref}} = doors.answer
      assert {:ok, %{answers: [], callers: []}} = doors.answers
      assert {:error, {:not_found, "permission", ^id}} = doors.forget

      assert row(person.ctx, ref).state == "open"
      assert [%{id: ^id}] = standing(person.ctx)
      refute_receive {:question, :answered, _, _}, 50
      fixture
    end

    test "another person in the same athanor reaches none of the person's rows", person do
      other = person!("questions-same-athanor")
      in_mine = %{other.ctx | athanor_id: person.ctx.athanor_id}
      refused_every_door!(person, in_mine)

      # What they set is theirs: it covers no ask of the person's, and the
      # person's list does not show it.
      assert {:ok, %{user_id: user_id}} =
               Questions.set(
                 in_mine,
                 "local",
                 "tables",
                 "delete_table",
                 shown("delete_table"),
                 %Prima.Question.Standing{effect: :allow, caller: :person, until: nil}
               )

      assert user_id == other.ctx.user_id
      run = run!(person)
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), run, 1, request())
      assert [%{caller: "agent:owner"}] = standing(person.ctx)
    end

    test "the same person in another athanor reaches none of their rows here", person do
      other = person!("questions-other-athanor")
      ship!(other.ctx, "catalyst", "tables", "1.0.0", @asks)
      elsewhere = %{person.ctx | athanor_id: other.ctx.athanor_id}
      refused_every_door!(person, elsewhere)

      assert {:ok, %{athanor_id: athanor_id}} =
               Questions.set(
                 elsewhere,
                 "local",
                 "tables",
                 "delete_table",
                 shown("delete_table"),
                 %Prima.Question.Standing{effect: :allow, caller: :person, until: nil}
               )

      assert athanor_id == other.ctx.athanor_id
      run = run!(person)
      assert {:pending, _ref} = Questions.ask(asking(person.ctx), run, 1, request())
      assert [%{caller: "agent:owner"}] = standing(person.ctx)
    end
  end

  # ---------------------------------------------------------------------------
  # The fresh confirmation, further
  # ---------------------------------------------------------------------------

  describe "the widest answer's confirmation" do
    @widest_answer %{"effect" => "allow", "lasts" => "always", "covers" => "any_caller"}
    @widest_set %{
      "publisher" => "local",
      "name" => "tables",
      "action_name" => "delete_table",
      "declaration_digest" =>
        Prima.Manifest.Asks.digest(%{name: "delete_table", title: "delete a table"}),
      "standing" => %{"effect" => "allow", "until" => nil, "caller" => "any"}
    }

    # A person whose account lists a device key, and that device paired
    # here and connected over its channel: its proof is its own.
    defp device_person! do
      {pub, _priv} = key = :crypto.generate_key(:eddsa, :ed25519)
      n = System.unique_integer([:positive])

      {:ok, user} =
        Sanctum.Test.People.linked(%{
          id: "github|https://github.com|questions-device-#{n}",
          provider: "github",
          email: "questions-device#{n}@example.com",
          verified: true
        })

      athanor = Sanctum.Test.People.athanor!(user)
      account = TestContext.account!(user.id, device: pub)
      {ctx, token} = session!(user, athanor)
      component = ship!(ctx, "catalyst", "tables", "1.0.0", @asks)

      {:ok, device_key} = Prima.Identity.Key.new(alg: :ed25519, kind: :device, pub: pub)
      client_id = Prima.UUID7.generate_id("pcl")
      holder = Map.put(Sanctum.Test.Devices.holder(), :client_id, client_id)
      :ok = Sanctum.DeviceUnlock.pair(%{id: user.id}, holder, device_key, account.head)

      {:ok, %{certificate: bytes}} =
        Arca.DeviceCertificates.current(Prima.Actor.in_athanor(athanor.id), client_id)

      {:ok, certificate} = bytes |> Jason.decode!() |> Prima.DeviceCert.decode()

      device =
        Sanctum.Test.Devices.connected!(%{
          client_id: client_id,
          certificate: certificate,
          key: key
        })

      %{
        user: user,
        athanor: athanor,
        ctx: ctx,
        token: token,
        release: component.release_digest,
        device: device,
        key: key
      }
    end

    test "is given from a paired device with the device's own proof" do
      %{device: device, key: key} = person = device_person!()
      {_run, ref} = open!(person)
      args = %{"ref" => ref, "answer" => @widest_answer}

      assert {:error, {:confirmation_required, %{id: id}}} = call(device, "answer", args)
      assert row(person.ctx, ref).state == "open"

      cref = Prima.Confirmation.ref(id)

      assert {:ok, %{request: encoded}} =
               Sanctum.Gate.call_external("confirmation", device, %{
                 "action" => "request",
                 "ref" => cref
               })

      {:ok, request} = Prima.SignIn.decode(encoded)

      answer =
        request
        |> Sanctum.Test.Devices.answer(key)
        |> Prima.SignIn.DeviceAnswer.encode()

      assert {:ok, %{state: "confirmed"}} =
               Sanctum.Gate.call_external("confirmation", device, %{
                 "action" => "confirm",
                 "ref" => cref,
                 "answer" => answer
               })

      assert {:ok, %{state: "allowed"}} = call(%{device | confirmation_id: id}, "answer", args)
      assert [%{caller: "any", effect: "allow", until: nil}] = standing(person.ctx)
    end

    test "a proof one person made is no proof for another", person do
      other = person!("questions-other-proof")
      ship!(other.ctx, "catalyst", "tables", "1.0.0", @asks)

      assert {:error, {:confirmation_required, %{id: id}}} = call(person.ctx, "set", @widest_set)
      proven!(person.ctx, id)

      # The very same arguments, repeated by the other person under the
      # first person's proof: asked again, nothing written, the proof unspent.
      assert {:error, {:confirmation_required, %{id: fresh}}} =
               call(%{other.ctx | confirmation_id: id}, "set", @widest_set)

      assert fresh != id
      assert standing(other.ctx) == []

      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.get(
                 Context.actor(person.ctx),
                 Prima.Confirmation.ref(id)
               )

      assert {:ok, %{caller: "any"}} =
               call(%{person.ctx | confirmation_id: id}, "set", @widest_set)
    end

    test "a deadline that passes between the proof and the repeat writes nothing", person do
      {_run, ref} = open!(person, deadline: DateTime.add(DateTime.utc_now(), 3, :second))
      args = %{"ref" => ref, "answer" => @widest_answer}

      assert {:error, {:confirmation_required, %{id: id}}} = call(person.ctx, "answer", args)
      proven!(person.ctx, id)

      deadline = row(person.ctx, ref).deadline
      Process.sleep(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 200)

      assert {:error, %Prima.Refusal{reason: :not_pending}} =
               call(%{person.ctx | confirmation_id: id}, "answer", args)

      assert row(person.ctx, ref).state == "open"
      assert standing(person.ctx) == []

      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.get(
                 Context.actor(person.ctx),
                 Prima.Confirmation.ref(id)
               )

      refute_receive {:question, :answered, _, _}, 50
    end
  end

  # ---------------------------------------------------------------------------
  # The proof is used with the write
  # ---------------------------------------------------------------------------

  # The write is rolled back after its verification ran: a handler of the
  # repository's own query event (`[:arca, :repo, :query]`, emitted in the
  # querying process), attached by the test alone, watches this process's
  # statements. Once the write has begun (an UPDATE of `questions` or an
  # INSERT into `question_answers`), once the proof was consumed (an
  # UPDATE of `pending_confirmations`), it rolls the write's transaction
  # back to its savepoint, so the write's commit then commits nothing. The
  # test runs in the sandbox's transaction, so the write's transaction is
  # that savepoint, named by the adapter; the consumption's own transaction
  # runs inside it and opens none. A proof used outside the write's
  # transaction never arms it, and the write commits.
  describe "the proof's use and the write commit together" do
    defp roll_back_after_consumption! do
      test = self()
      handler = {__MODULE__, :rollback, make_ref()}

      savepoint =
        Map.fetch!(
          %{
            Ecto.Adapters.Postgres => "postgrex_savepoint",
            Ecto.Adapters.SQLite3 => "exqlite_savepoint"
          },
          Arca.Repo.__adapter__()
        )

      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measurements, %{query: query, source: source}, _config ->
            if self() == test, do: watch(query, source, savepoint, test)
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      handler
    end

    defp watch(query, source, savepoint, test) do
      step = Process.get({__MODULE__, :rollback}, :idle)
      verb = query |> String.split(" ", parts: 2) |> hd() |> String.upcase()

      cond do
        step == :idle and
            {verb, source} in [{"UPDATE", "questions"}, {"INSERT", "question_answers"}] ->
          Process.put({__MODULE__, :rollback}, :writing)

        step == :writing and {verb, source} == {"UPDATE", "pending_confirmations"} ->
          Process.put({__MODULE__, :rollback}, :done)
          Arca.Repo.query!("ROLLBACK TO SAVEPOINT #{savepoint}")
          send(test, :write_rolled_back)

        true ->
          :ok
      end
    end

    defp still_unanswered!(person, ref, id) do
      if ref, do: assert(row(person.ctx, ref).state == "open")
      assert standing(person.ctx) == []

      assert {:ok, %{state: "confirmed"}} =
               Arca.PendingConfirmations.get(
                 Context.actor(person.ctx),
                 Prima.Confirmation.ref(id)
               )

      assert_received :write_rolled_back
    end

    test "on the card: rolled back, the question stays open and the proof unspent", person do
      {_run, ref} = open!(person)
      args = %{"ref" => ref, "answer" => @widest_answer}
      assert {:error, {:confirmation_required, %{id: id}}} = call(person.ctx, "answer", args)
      proven!(person.ctx, id)
      repeat = %{person.ctx | confirmation_id: id}

      handler = roll_back_after_consumption!()
      _rolled_back = call(repeat, "answer", args)
      :telemetry.detach(handler)
      still_unanswered!(person, ref, id)

      # The person repeats it, and it is written with the proof spent.
      assert {:ok, %{state: "allowed"}} = call(repeat, "answer", args)
      assert [%{caller: "any", effect: "allow"}] = standing(person.ctx)

      assert {:ok, %{state: "consumed"}} =
               Arca.PendingConfirmations.get(
                 Context.actor(person.ctx),
                 Prima.Confirmation.ref(id)
               )
    end

    test "on question.set: rolled back, no permission and the proof unspent", person do
      assert {:error, {:confirmation_required, %{id: id}}} = call(person.ctx, "set", @widest_set)
      proven!(person.ctx, id)
      repeat = %{person.ctx | confirmation_id: id}

      handler = roll_back_after_consumption!()
      _rolled_back = call(repeat, "set", @widest_set)
      :telemetry.detach(handler)
      still_unanswered!(person, nil, id)

      assert {:ok, %{caller: "any", effect: "allow"}} = call(repeat, "set", @widest_set)

      assert {:ok, %{state: "consumed"}} =
               Arca.PendingConfirmations.get(
                 Context.actor(person.ctx),
                 Prima.Confirmation.ref(id)
               )
    end
  end
end
