# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.DecisionTest do
  use ExUnit.Case, async: true

  alias Prima.Decision

  test "a decision carries the time its caller names; the contracts read no clock" do
    at = ~U[2026-09-25 10:00:00.000000Z]

    assert Decision.new(
             call_id: "call_1",
             plane: :external,
             admission: :admitted,
             inserted_at: at
           ).inserted_at ==
             at

    assert_raise ArgumentError, ~r/inserted_at/, fn ->
      Decision.new(call_id: "call_1", plane: :in_chain, admission: :admitted)
    end

    assert_raise ArgumentError, ~r/unknown fields/, fn ->
      Decision.new(
        call_id: "call_1",
        plane: :in_chain,
        admission: :admitted,
        inserted_at: at,
        stage: :admission
      )
    end
  end

  test "the vocabularies are closed" do
    assert Decision.planes() == [:external, :in_chain]
    assert Decision.admissions() == [:admitted, :refused]
    assert Decision.completions() == [:succeeded, :failed, :cancelled, :uncertain]

    refute :stage in Map.keys(%Decision{
             call_id: "c",
             plane: :external,
             admission: :admitted,
             inserted_at: DateTime.utc_now()
           })
  end

  test "a refusal names a class of the refusal table, and an admission none" do
    base = [call_id: "call_1", plane: :external, inserted_at: ~U[2026-09-25 10:00:00Z]]

    assert %Decision{refusal_class: :not_owner} =
             Decision.new(base ++ [admission: :refused, refusal_class: :not_owner])

    for bad <- [
          [admission: :refused],
          [admission: :refused, refusal_class: :nope],
          [admission: :admitted, refusal_class: :forbidden],
          [admission: :maybe],
          [admission: :admitted, plane: :guest],
          [admission: :admitted, call_id: ""]
        ] do
      assert_raise ArgumentError, fn -> Decision.new(Keyword.merge(base, bad)) end
    end
  end

  test "a completion is its outcome, a failure's class and its duration" do
    assert :ok = Decision.validate_completion(%{completion: :succeeded, duration_ms: 0})
    assert :ok = Decision.validate_completion(%{completion: :failed, completion_class: :timeout})

    assert :ok =
             Decision.validate_completion(%{completion: :uncertain, completion_class: :uncertain})

    assert {:error, _} =
             Decision.validate_completion(%{completion: :succeeded, completion_class: :internal})

    assert {:error, _} = Decision.validate_completion(%{completion: :failed})
    assert {:error, _} = Decision.validate_completion(%{completion: :done})
    assert {:error, _} = Decision.validate_completion(%{completion: :cancelled, duration_ms: -1})
    assert {:error, _} = Decision.validate_completion(%{})
  end
end
