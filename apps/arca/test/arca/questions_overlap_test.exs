# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QuestionsOverlapTest do
  @moduledoc """
  Two writes of one standing answer's identity on two connections: the
  second waits for the first, both succeed in order, and the later one
  stands. These run outside the sandbox, on connections of their own, and
  delete the rows they wrote.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.Questions
  alias Arca.Schemas.QuestionAnswer
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :postgres
  @moduletag timeout: 60_000

  @person "usr_questions_overlap"

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)

  defp backend! do
    %{rows: [[backend]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  defp standing(effect) do
    %{
      publisher: "acme",
      name: "tables",
      action: "delete_table",
      declaration_digest: String.duplicate("a", 64),
      caller: "any",
      effect: effect,
      until: nil
    }
  end

  test "a second write of one identity waits for the first and replaces it" do
    athanor = "ath_q_overlap_#{System.unique_integer([:positive])}"
    actor = %Prima.Actor{athanor_id: athanor, user_id: @person, scope: :athanor}
    test = self()

    on_exit(fn ->
      unboxed(fn ->
        Arca.Repo.delete_all(from(a in QuestionAnswer, where: a.athanor_id == ^athanor))
      end)
    end)

    {:ok, _single} =
      unboxed(fn ->
        Questions.put_standing(actor, %{standing("allow") | caller: "key:k1"},
          verify: fn -> :ok end
        )
      end)

    # The first write holds its transaction open inside its closure.
    first =
      Task.async(fn ->
        unboxed(fn ->
          Questions.put_standing(actor, standing("allow"),
            verify: fn ->
              send(test, :held)

              receive do
                :release -> :ok
              after
                30_000 -> {:error, :timeout}
              end
            end
          )
        end)
      end)

    assert_receive :held, 5_000

    second =
      Task.async(fn ->
        unboxed(fn ->
          send(test, {:second, backend!()})
          Questions.put_standing(actor, standing("deny"), verify: fn -> :ok end)
        end)
      end)

    assert_receive {:second, backend}, 5_000
    Arca.Test.LockWait.await_lock_wait!(backend, ["question_answers"])

    send(first.pid, :release)
    assert {:ok, %{effect: "allow"}} = Task.await(first, 10_000)
    assert {:ok, %{effect: "deny"} = deny} = Task.await(second, 10_000)

    # The later deny stands alone: it replaced the allow for any caller and
    # deleted the allow for a single caller.
    assert {:ok, [^deny]} =
             unboxed(fn -> Questions.standing(actor, @person, "acme", "tables") end)
  end
end
