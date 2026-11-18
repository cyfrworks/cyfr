# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QuestionsTest do
  @moduledoc """
  Component questions and their standing answers in storage: a keyed
  admission that a run's end refuses, an answer under the run's lock and
  the question's, the identity of a standing answer and a deny for any
  caller, every read bound to its athanor and person, and the writes that
  end a run, a declared restore and retention each settling a run's own
  questions.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.{Execution, ExecutionAttempts, Questions, SecurityTransitions}
  alias Arca.Schemas.{Question, QuestionAnswer}

  @athanor Arca.Test.Actor.athanor_id()
  @other "ath_questions_other"
  @person "usr_questions"
  @digest String.duplicate("a", 64)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    Arca.Test.Actor.athanor!(@athanor)
    Arca.Test.Actor.athanor!(@other)
    :ok
  end

  defp actor(athanor \\ @athanor, user \\ @person),
    do: %Prima.Actor{athanor_id: athanor, user_id: user, authenticated: true, scope: :athanor}

  # A running root, or a child of `parent`, with its current attempt.
  defp run!(athanor \\ @athanor, opts \\ []) do
    id = "exec_q_#{System.unique_integer([:positive])}"
    parent = Keyword.get(opts, :parent)

    attrs =
      %{
        id: id,
        root_execution_id: if(parent, do: parent.root, else: id),
        reference: "catalyst:acme.tables:1.0.0",
        user_id: @person,
        athanor_id: athanor,
        component_type: "catalyst",
        origin: :interactive
      }
      |> then(fn attrs ->
        if parent,
          do: Map.merge(attrs, %{parent_execution_id: parent.id, child_key: "ck_#{id}"}),
          else: attrs
      end)

    {:ok, %{attempt: attempt}} =
      Execution.admit(attrs,
        boot_id: "node@test",
        lease_until: DateTime.add(DateTime.utc_now(), 120, :second),
        grant: Arca.Test.Actor.grant(athanor),
        verify: &Arca.Test.Actor.admits/1
      )

    %{id: id, root: attrs.root_execution_id, attempt: attempt.attempt, athanor: athanor}
  end

  defp question(run, attrs \\ %{}) do
    Map.merge(
      %{
        ref: "q_#{System.unique_integer([:positive])}",
        execution_id: run.id,
        attempt_id: run.attempt,
        root_execution_id: run.root,
        ask_no: 1,
        request_digest: @digest,
        component_ref: "catalyst:acme.tables:1.0.0",
        release_digest: Prima.Digest.sha256("release"),
        action: "delete_table",
        title: "delete a table",
        summary: "Drop the table users in the project acme",
        operation: "DROP TABLE users;",
        masked: false,
        caller: "person",
        deadline: DateTime.add(DateTime.utc_now(), 600, :second),
        state: "open"
      },
      attrs
    )
  end

  defp admit!(run, attrs \\ %{}) do
    {:ok, row} = Questions.admit(actor(run.athanor), question(run, attrs))
    row
  end

  defp standing(attrs \\ %{}) do
    Map.merge(
      %{
        publisher: "acme",
        name: "tables",
        action: "delete_table",
        declaration_digest: @digest,
        caller: "any",
        effect: "allow",
        until: nil
      },
      attrs
    )
  end

  defp end!(run, status \\ "cancelled") do
    Execution.record_end(
      actor(run.athanor),
      run.id,
      status,
      %{completed_at: DateTime.utc_now(), duration_ms: 1},
      run.attempt,
      Arca.Test.Actor.stored()
    )
  end

  defp state(ref), do: Arca.Repo.get!(Question, ref).state
  defp ok, do: :ok

  describe "admit/2" do
    test "writes the keyed row with the actor's athanor and person, open" do
      run = run!()
      row = admit!(run)

      assert %{athanor_id: @athanor, user_id: @person, state: "open", decided_at: nil} = row
      assert {:ok, ^row} = Questions.by_key(actor(), run.attempt, 1)
      assert {:ok, ^row} = Questions.get(actor(), row.ref)
      assert {:ok, [^row]} = Questions.list_open(actor(), @person)
    end

    test "a taken key is refused and the first row stands, whatever the second says" do
      run = run!()
      first = admit!(run)

      assert {:error, :exists} = Questions.admit(actor(), question(run))

      assert {:error, :exists} =
               Questions.admit(actor(), question(run, %{summary: "Drop another table"}))

      # A retry reads what the row holds.
      assert {:ok, ^first} = Questions.by_key(actor(), run.attempt, 1)
      assert {:ok, %{ref: ref}} = Questions.admit(actor(), question(run, %{ask_no: 2}))
      refute ref == first.ref
    end

    test "is refused once the run has ended, leaving no row" do
      run = run!()
      assert {:ok, _} = end!(run)

      assert {:error, :closed} = Questions.admit(actor(), question(run))
      assert {:error, :not_found} = Questions.by_key(actor(), run.attempt, 1)
    end

    test "is refused for an attempt that is not the run's current one" do
      run = run!()

      assert {:error, :closed} =
               Questions.admit(actor(), question(run, %{attempt_id: "att_gone"}))
    end

    test "is refused for a run of another athanor" do
      run = run!(@other)
      assert {:error, :closed} = Questions.admit(actor(@athanor), question(run))
    end

    test "a first state decided by a standing answer is stamped decided" do
      run = run!()

      row =
        admit!(run, %{state: "allowed", standing_answer_id: "qan_1"})

      assert %{state: "allowed", standing_answer_id: "qan_1", decided_by: nil} = row
      assert %DateTime{} = row.decided_at

      assert %{state: "none", none_reason: "unattended"} =
               admit!(run, %{ask_no: 2, state: "none", none_reason: "unattended"})
    end

    test "a row outside the table's rules writes nothing" do
      run = run!()

      for attrs <- [
            %{request_digest: "ABC"},
            %{request_digest: Prima.Digest.sha256("request")},
            %{release_digest: String.duplicate("b", 64)},
            %{ask_no: 0},
            %{state: "ended"},
            %{state: "none"},
            %{none_reason: "unattended"},
            %{standing_answer_id: "qan_1"},
            %{caller: "any"},
            %{ref: "has space"},
            %{summary: nil}
          ] do
        assert {:error, {:invalid, _}} = Questions.admit(actor(), question(run, attrs)),
               inspect(attrs)
      end

      assert Arca.Repo.aggregate(Question, :count) == 0
    end

    test "an actor with no person or no athanor is refused" do
      run = run!()

      assert {:error, :no_person} =
               Questions.admit(Prima.Actor.in_athanor(@athanor), question(run))

      assert {:error, :no_athanor} =
               Questions.admit(%Prima.Actor{user_id: @person}, question(run))
    end
  end

  describe "long texts" do
    # A caller names a tincture's reference or an agent's name, and a
    # reference a publisher of up to 253 characters: neither is bounded at
    # 255, on either adapter.
    test "a caller and a component reference past 255 characters are stored whole" do
      publisher = Enum.map_join(~w(a b c d), ".", &String.duplicate(&1, 60))
      ref = "catalyst:#{publisher}.tables:1.0.0"
      caller = "tincture:" <> String.duplicate("t", 300)
      assert {:ok, _} = Prima.ComponentRef.parse(ref)
      assert String.length(ref) > 255

      run = run!()
      row = admit!(run, %{caller: caller, component_ref: ref})
      assert %{caller: ^caller, component_ref: ^ref} = row
      assert {:ok, [^caller]} = Questions.callers(actor(), @person, publisher, "tables")

      assert {:ok, %{caller: ^caller}} =
               Questions.put_standing(actor(), standing(%{caller: caller}), verify: &ok/0)

      id = "exec_q_long_#{System.unique_integer([:positive])}"

      assert {:ok, %{caller: ^caller}} =
               Arca.Test.Writers.record_start(%{
                 id: id,
                 reference: "catalyst:acme.tables:1.0.0",
                 user_id: @person,
                 athanor_id: @athanor,
                 started_at: DateTime.utc_now(),
                 status: "running",
                 component_type: "catalyst",
                 caller: caller
               })
    end
  end

  describe "tenancy" do
    test "another athanor and another person read none of a person's rows" do
      run = run!()
      row = admit!(run)
      {:ok, _} = Questions.put_standing(actor(), standing(), verify: &ok/0)

      for other <- [actor(@other), actor(@athanor, "usr_someone_else")] do
        assert {:error, :not_found} = Questions.get(other, row.ref)
        assert {:error, :not_found} = Questions.by_key(other, run.attempt, 1)
        assert {:ok, []} = Questions.list_open(other, other.user_id)
        assert {:ok, []} = Questions.standing(other, other.user_id, "acme", "tables")
        assert {:ok, []} = Questions.callers(other, other.user_id, "acme", "tables")

        assert {:error, :not_found} =
                 Questions.answer(other, row.ref, "allowed", nil, verify: &ok/0)
      end

      # Another athanor reading the person's id finds nothing there either.
      assert {:ok, []} = Questions.list_open(actor(@other), @person)
      assert state(row.ref) == "open"
    end
  end

  describe "answer/5" do
    test "decides an open question by the actor's person, once" do
      run = run!()
      row = admit!(run)

      assert {:ok, answered} = Questions.answer(actor(), row.ref, "allowed", nil, verify: &ok/0)
      assert %{state: "allowed", decided_by: @person, standing_answer_id: nil} = answered
      assert %DateTime{} = answered.decided_at

      assert {:error, :closed} = Questions.answer(actor(), row.ref, "denied", nil, verify: &ok/0)
      assert state(row.ref) == "allowed"
    end

    test "writes a standing answer naming its question in the same transaction" do
      run = run!()
      row = admit!(run)

      assert {:ok, %{state: "denied"}} =
               Questions.answer(actor(), row.ref, "denied", standing(%{effect: "deny"}),
                 verify: &ok/0
               )

      assert {:ok, [%{effect: "deny", caller: "any", question_ref: ref}]} =
               Questions.standing(actor(), @person, "acme", "tables")

      assert ref == row.ref
    end

    test "the closure's refusal rolls every write back" do
      run = run!()
      row = admit!(run)

      assert {:error, :stale_proof} =
               Questions.answer(actor(), row.ref, "allowed", standing(),
                 verify: fn -> {:error, :stale_proof} end
               )

      assert state(row.ref) == "open"
      assert Arca.Repo.aggregate(QuestionAnswer, :count) == 0
    end

    test "is refused once the run has ended" do
      run = run!()
      row = admit!(run)
      assert {:ok, _} = end!(run)

      assert {:error, :closed} = Questions.answer(actor(), row.ref, "allowed", nil, verify: &ok/0)
      assert state(row.ref) == "ended"
    end

    test "is refused when the asking attempt is no longer the run's" do
      run = run!()
      row = admit!(run)

      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^run.id),
          set: [current_attempt: "att_successor"]
        )

      assert {:error, :closed} = Questions.answer(actor(), row.ref, "allowed", nil, verify: &ok/0)
      assert state(row.ref) == "open"
    end

    test "is refused once the deadline has passed, on the database's clock" do
      run = run!()
      row = admit!(run, %{deadline: DateTime.add(DateTime.utc_now(), -1, :second)})

      assert {:error, :closed} = Questions.answer(actor(), row.ref, "allowed", nil, verify: &ok/0)
      assert state(row.ref) == "open"
    end
  end

  describe "standing answers" do
    test "a new answer replaces its identity, a deny included" do
      assert {:ok, allow} = Questions.put_standing(actor(), standing(), verify: &ok/0)
      assert %{athanor_id: @athanor, user_id: @person, question_ref: nil} = allow

      assert {:ok, deny} =
               Questions.put_standing(actor(), standing(%{effect: "deny"}), verify: &ok/0)

      assert {:ok, [^deny]} = Questions.standing(actor(), @person, "acme", "tables")
      refute deny.id == allow.id
    end

    test "a deny for any caller deletes the action's allows for single callers" do
      for caller <- ["key:key_1", "agent:helper"],
          do:
            {:ok, _} = Questions.put_standing(actor(), standing(%{caller: caller}), verify: &ok/0)

      {:ok, _} =
        Questions.put_standing(actor(), standing(%{action: "delete_rows", caller: "key:key_1"}),
          verify: &ok/0
        )

      {:ok, _} =
        Questions.put_standing(actor(), standing(%{caller: "device:d1", effect: "deny"}),
          verify: &ok/0
        )

      {:ok, _} = Questions.put_standing(actor(), standing(%{effect: "deny"}), verify: &ok/0)

      assert {:ok, rows} = Questions.standing(actor(), @person, "acme", "tables")

      assert Enum.map(rows, &{&1.action, &1.caller, &1.effect}) == [
               {"delete_rows", "key:key_1", "allow"},
               {"delete_table", "any", "deny"},
               {"delete_table", "device:d1", "deny"}
             ]

      # An allow for one caller added after it stands.
      {:ok, _} = Questions.put_standing(actor(), standing(%{caller: "key:key_1"}), verify: &ok/0)
      assert {:ok, after_rows} = Questions.standing(actor(), @person, "acme", "tables")

      assert {"delete_table", "key:key_1", "allow"} in Enum.map(
               after_rows,
               &{&1.action, &1.caller, &1.effect}
             )
    end

    test "the closure's refusal rolls the write back, the replaced answer standing" do
      {:ok, allow} = Questions.put_standing(actor(), standing(), verify: &ok/0)

      assert {:error, :no_proof} =
               Questions.put_standing(actor(), standing(%{effect: "deny"}),
                 verify: fn -> {:error, :no_proof} end
               )

      assert {:ok, [^allow]} = Questions.standing(actor(), @person, "acme", "tables")
    end

    test "a row outside the table's rules is refused" do
      for attrs <- [
            %{caller: nil},
            %{caller: "robot:1"},
            %{effect: "maybe"},
            %{declaration_digest: "x"}
          ] do
        assert {:error, {:invalid, _}} =
                 Questions.put_standing(actor(), standing(attrs), verify: &ok/0)
      end
    end

    test "delete_standing removes the person's own answer only" do
      {:ok, row} = Questions.put_standing(actor(), standing(), verify: &ok/0)

      assert {:error, :not_found} =
               Questions.delete_standing(actor(@athanor, "usr_other"), row.id)

      assert {:error, :not_found} = Questions.delete_standing(actor(@other), row.id)
      assert :ok = Questions.delete_standing(actor(), row.id)
      assert {:error, :not_found} = Questions.delete_standing(actor(), row.id)
    end

    test "delete_component removes the component's answers in the athanor, whoever gave them" do
      {:ok, _} = Questions.put_standing(actor(), standing(), verify: &ok/0)
      {:ok, _} = Questions.put_standing(actor(@athanor, "usr_two"), standing(), verify: &ok/0)
      {:ok, _} = Questions.put_standing(actor(), standing(%{name: "rows"}), verify: &ok/0)
      {:ok, _} = Questions.put_standing(actor(@other), standing(), verify: &ok/0)

      assert {:ok, 2} =
               Questions.delete_component(Prima.Actor.in_athanor(@athanor), "acme", "tables")

      assert {:ok, [%{name: "rows"}]} = Questions.standing(actor(), @person, "acme", "rows")
      assert {:ok, [_]} = Questions.standing(actor(@other), @person, "acme", "tables")
    end

    test "callers answers the distinct callers of the person's questions for a component" do
      run = run!()
      admit!(run, %{ask_no: 1, caller: "key:key_1"})
      admit!(run, %{ask_no: 2, caller: "key:key_1"})
      admit!(run, %{ask_no: 3, caller: "person"})
      admit!(run, %{ask_no: 4, caller: "agent:x", component_ref: "catalyst:acme.rows:1.0.0"})

      assert {:ok, ["key:key_1", "person"]} =
               Questions.callers(actor(), @person, "acme", "tables")
    end
  end

  describe "the writes that end a run" do
    test "an end closes the ending run's open questions and says which, no other run's" do
      run = run!()
      child = run!(@athanor, parent: run)
      other = run!()

      asked = admit!(run)
      answered = admit!(run, %{ask_no: 2})
      {:ok, _} = Questions.answer(actor(), answered.ref, "allowed", nil, verify: &ok/0)
      childs = admit!(child)
      others = admit!(other)

      assert {:ok, ended} = end!(run)

      assert ended.closed_questions == [
               %{ref: asked.ref, user_id: @person, deadline: asked.deadline}
             ]

      assert state(asked.ref) == "ended"
      assert state(answered.ref) == "allowed"
      assert state(childs.ref) == "open"
      assert state(others.ref) == "open"
    end

    test "an end with nothing open says none" do
      assert {:ok, %{closed_questions: []}} = end!(run!(), "completed")
    end

    test "a failure closes the failed run's open questions and says which" do
      run = run!()
      other = run!()
      asked = admit!(run)
      others = admit!(other)

      assert {1, seq, [%{ref: ref, user_id: @person}]} =
               Execution.mark_failed_if_running(
                 run.id,
                 %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "parent"},
                 Arca.Test.Actor.stored() ++ [attempt: run.attempt]
               )

      assert is_integer(seq) and ref == asked.ref
      assert state(asked.ref) == "ended"
      assert state(others.ref) == "open"
    end

    test "a lapse closes the lapsed run's open questions, and a lapse that misses closes none" do
      run = run!()
      asked = admit!(run)
      lease = ExecutionAttempts.get(Prima.Actor.in_athanor(@athanor), run.attempt).lease_until
      failure = %{completed_at: DateTime.utc_now(), duration_ms: 1, error_message: "lapsed"}

      assert {0, nil, []} =
               Execution.mark_failed_if_running(
                 run.id,
                 failure,
                 Arca.Test.Actor.stored() ++
                   [attempt: run.attempt, lease_until: DateTime.add(lease, -5, :second)]
               )

      assert state(asked.ref) == "open"

      assert {1, _seq, [%{ref: ref}]} =
               Execution.mark_failed_if_running(
                 run.id,
                 failure,
                 Arca.Test.Actor.stored() ++ [attempt: run.attempt, lease_until: lease]
               )

      assert ref == asked.ref
      assert state(asked.ref) == "ended"
    end

    test "a declared restore closes open questions, deletes standing allows and keeps denies" do
      run = run!()
      asked = admit!(run)
      {:ok, allow} = Questions.put_standing(actor(), standing(), verify: &ok/0)

      {:ok, deny} =
        Questions.put_standing(actor(), standing(%{action: "delete_rows", effect: "deny"}),
          verify: &ok/0
        )

      {:ok, _} = SecurityTransitions.mark_restore(Prima.Actor.system())

      assert {:ok, change} = SecurityTransitions.restore(slot: :none)
      assert change.dropped_question_answer_ids == [allow.id]
      refute Map.has_key?(change, :closed_questions)

      assert state(asked.ref) == "ended"
      refute Arca.Repo.get(QuestionAnswer, allow.id)
      assert Arca.Repo.get(QuestionAnswer, deny.id)
    end

    test "retention deletes a run's questions with the run" do
      run = run!()
      kept = run!()
      asked = admit!(run)
      others = admit!(kept)
      assert {:ok, _} = end!(run)

      assert {:ok, 1} = Execution.delete_ids([run.id], athanor_id: @athanor)
      refute Arca.Repo.get(Question, asked.ref)
      assert Arca.Repo.get(Question, others.ref)
    end
  end
end
