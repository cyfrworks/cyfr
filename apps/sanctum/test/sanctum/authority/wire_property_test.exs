# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.WirePropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Test.AuthorityGen, as: Gen

  # The budget crosses as its id alone.
  defp decoded(auth), do: %{auth | budget: %{auth.budget | cap: 0}}

  # An Authority is plain data end to end: to_wire/from_wire round-trips
  # any authority the relation can produce — rooted, walked bound and
  # unbound, at any depth — and the wire map holds nothing process-bound.

  property "to_wire |> from_wire is the identity over rooted authorities and their walks, but the budget's cap" do
    check all({graph, meta} <- Gen.graph(), program <- Gen.walk(meta), max_runs: 40) do
      auth = Gen.rooted({graph, meta})

      auths =
        Enum.scan(program, auth, fn {fun, target, need}, acc ->
          case Authority.Transition.step(acc, fun, Gen.invoke_at(acc, meta, target, need)) do
            {:child, child} -> child
            {:child_zero, child} -> child
            _ -> acc
          end
        end)

      for a <- [auth | auths] do
        wire = Authority.to_wire(a)
        assert {:ok, back} = Authority.from_wire(wire)
        assert back == decoded(a)

        # JSON-safe: encodes, and decodes to the same wire map.
        assert {:ok, json} = Jason.encode(wire)
        assert Jason.decode!(json) == wire
        assert {:ok, ^back} = Authority.from_wire(Jason.decode!(json))
      end
    end
  end

  test "the wire map carries no refs, pids or functions" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    wire = Authority.to_wire(Gen.rooted({graph, meta}))

    walk = fn
      walk, %{} = m ->
        Enum.each(m, fn {k, v} ->
          assert is_binary(k)
          walk.(walk, v)
        end)

      walk, l when is_list(l) ->
        Enum.each(l, &walk.(walk, &1))

      _walk, v ->
        refute is_reference(v) or is_pid(v) or is_function(v)
        refute is_atom(v) and v not in [nil, true, false]
    end

    walk.(walk, wire)
  end

  test "the budget crosses as identity: a decoded copy counts against the same id and charges nothing" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    auth = Gen.rooted({graph, meta})

    assert %{"budget" => %{"id" => id}} = wire = Authority.to_wire(auth)
    assert id == auth.budget.id
    {:ok, twin} = Authority.from_wire(wire)
    assert twin.budget.id == auth.budget.id

    assert :ok = Sanctum.Authority.try_acquire_invoke(auth)
    assert Sanctum.Authority.budget(twin).in_flight == 1
    assert {:error, :invoke_budget_exhausted} = Sanctum.Authority.try_acquire_invoke(twin)
    :ok = Sanctum.Authority.release_invoke(twin)
    assert Sanctum.Authority.budget(auth).in_flight == 0
  end

  test "Blob.to_map is the inverse of Blob.parse" do
    {graph, _meta} = Gen.graph() |> Enum.take(1) |> hd()
    {:ok, blob} = Blob.parse(graph)
    assert {:ok, ^blob} = Blob.parse(Blob.to_map(blob))
  end
end
