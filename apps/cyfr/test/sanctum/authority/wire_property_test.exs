# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.WirePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  # An Authority is plain data end to end: to_wire/from_wire round-trips
  # any authority the relation can produce — rooted, walked bound and
  # unbound, at any depth — and the wire map holds nothing process-bound.

  property "to_wire |> from_wire is the identity over rooted authorities and their walks" do
    check all({graph, meta} <- Gen.graph(), program <- Gen.walk(meta), max_runs: 40) do
      auth = Gen.rooted({graph, meta})

      auths =
        Enum.scan(program, auth, fn {fun, target, need}, acc ->
          case Transition.step(acc, fun, Gen.invoke_at(acc, meta, target, need)) do
            {:child, child} -> child
            {:child_zero, child} -> child
            _ -> acc
          end
        end)

      for a <- [auth | auths] do
        wire = Authority.to_wire(a)
        assert {:ok, back} = Authority.from_wire(wire)
        assert back == a

        # JSON-safe: encodes, and decodes to the same wire map.
        assert {:ok, json} = Jason.encode(wire)
        assert Jason.decode!(json) == wire
        assert {:ok, ^a} = Authority.from_wire(Jason.decode!(json))
      end
    end
  end

  test "the zero authority round-trips" do
    zero = Authority.zero()
    assert {:ok, ^zero} = Authority.from_wire(Authority.to_wire(zero))
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

  test "the budget crosses as identity: the read-back authority charges the same counter" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    auth = Gen.rooted({graph, meta})
    {:ok, twin} = Authority.from_wire(Authority.to_wire(auth))

    assert :ok = Authority.try_acquire_invoke(auth)
    assert Authority.budget(twin).in_flight == 1
    :ok = Authority.release_invoke(twin)
    assert Authority.budget(auth).in_flight == 0
  end

  test "from_wire fails closed on a malformed map" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    wire = Authority.to_wire(Gen.rooted({graph, meta}))

    assert {:error, {:invalid_wire_keys, _}} = Authority.from_wire(Map.delete(wire, "budget"))
    assert {:error, {:invalid_wire_keys, _}} = Authority.from_wire(Map.put(wire, "extra", 1))

    assert {:error, {:invalid_wire_cursor, _}} =
             Authority.from_wire(%{wire | "cursor" => "bound"})

    assert {:error, {:invalid_wire_budget, _}} =
             Authority.from_wire(%{wire | "budget" => %{"id" => "x"}})

    assert {:error, {:invalid_wire_value, _}} =
             Authority.from_wire(%{wire | "invoke_mode" => "anything"})

    bad_policy = put_in(wire, ["policy", "canonical"], "jcs-9")
    assert {:error, {:invalid_wire_policy, _}} = Authority.from_wire(bad_policy)
    assert {:error, {:invalid_wire, _}} = Authority.from_wire("not a map")
  end

  test "Blob.to_map is the inverse of Blob.parse" do
    {graph, _meta} = Gen.graph() |> Enum.take(1) |> hd()
    {:ok, blob} = Blob.parse(graph)
    assert {:ok, ^blob} = Blob.parse(Blob.to_map(blob))
  end
end
