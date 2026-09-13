# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.WirePropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Authority.Transition
  alias Sanctum.Test.AuthorityGen, as: Gen

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})
    :ok
  end

  defp reserve!(auth), do: Sanctum.Test.AuthorityFixtures.reserve!(auth)

  # An Authority is plain data end to end: to_wire/from_wire round-trips
  # any authority the relation can produce — rooted, walked bound and
  # unbound, at any depth — and the wire map holds nothing process-bound.

  property "to_wire |> from_wire is the identity over rooted authorities and their walks" do
    check all({graph, meta} <- Gen.graph(), program <- Gen.walk(meta), max_runs: 40) do
      auth = reserve!(Gen.rooted({graph, meta}))

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
    zero = reserve!(Authority.zero())
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

  test "the budget crosses as identity: the read-back authority charges the same counter, with the row's cap" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    auth = reserve!(Gen.rooted({graph, meta}))

    # The wire carries the id alone; the cap comes back from the row.
    assert %{"budget" => %{"id" => id}} = wire = Authority.to_wire(auth)
    assert id == auth.budget.id
    {:ok, twin} = Authority.from_wire(wire)
    assert twin.budget == auth.budget

    assert :ok = Authority.try_acquire_invoke(auth)
    assert Authority.budget(twin).in_flight == 1
    :ok = Authority.release_invoke(twin)
    assert Authority.budget(auth).in_flight == 0
  end

  test "a reservation the store does not know, or one released, does not cross" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    auth = Gen.rooted({graph, meta})

    assert {:error, {:unknown_reservation, _}} = Authority.from_wire(Authority.to_wire(auth))

    reserve!(auth)
    {:ok, _} = Authority.from_wire(Authority.to_wire(auth))

    {1, _} =
      Arca.Repo.update_all(Arca.Schemas.BudgetReservation, set: [released_at: DateTime.utc_now()])

    assert {:error, {:released_reservation, _}} = Authority.from_wire(Authority.to_wire(auth))
  end

  test "from_wire fails closed on a malformed map" do
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    wire = Authority.to_wire(reserve!(Gen.rooted({graph, meta})))

    assert {:error, {:invalid_wire_keys, _}} = Authority.from_wire(Map.delete(wire, "budget"))
    assert {:error, {:invalid_wire_keys, _}} = Authority.from_wire(Map.put(wire, "extra", 1))

    assert {:error, {:invalid_wire_cursor, _}} =
             Authority.from_wire(%{wire | "cursor" => "bound"})

    assert {:error, {:invalid_wire_budget, _}} =
             Authority.from_wire(%{wire | "budget" => %{"id" => "x", "cap" => 1}})

    assert {:error, {:invalid_wire_value, _}} =
             Authority.from_wire(%{wire | "invoke_mode" => "anything"})

    bad_policy = put_in(wire, ["policy", "canonical"], "jcs-9")
    assert {:error, {:invalid_wire_policy, _}} = Authority.from_wire(bad_policy)
    assert {:error, {:invalid_wire, _}} = Authority.from_wire("not a map")
  end

  test "the wire cannot raise its own ceiling or restart its own depth" do
    # `root/3` clamps the blob to the platform ceiling and starts at depth 0;
    # everything downstream trusts those two facts. A wire map is the one way
    # into an Authority that does not go through `root/3`, so it has to
    # re-establish them itself — otherwise the first non-test caller (a remote
    # worker) is a worker that writes its own ceiling and its own depth.
    {graph, meta} = Gen.graph() |> Enum.take(1) |> hd()
    wire = Authority.to_wire(reserve!(Gen.rooted({graph, meta})))

    ceiling = Sanctum.Policy.Ceiling.platform_ceiling()

    over =
      update_in(wire["policy"]["nodes"], fn nodes ->
        Map.new(nodes, fn {ref, node} ->
          {ref, put_in(node["limits"]["max_memory_bytes"], ceiling.max_memory_bytes * 4)}
        end)
      end)

    assert {:ok, back} = Authority.from_wire(over)

    for {_ref, node} <- back.policy.nodes do
      assert node.limits.max_memory_bytes <= ceiling.max_memory_bytes
    end

    # Depth is bounded by the same cap `Transition` checks against, so a wire
    # map cannot hand back an authority already past it.
    assert {:error, {:invalid_wire_depth, _}} =
             Authority.from_wire(%{wire | "depth" => Authority.depth_cap() + 1})

    assert {:ok, _} = Authority.from_wire(%{wire | "depth" => Authority.depth_cap()})
  end

  test "Blob.to_map is the inverse of Blob.parse" do
    {graph, _meta} = Gen.graph() |> Enum.take(1) |> hd()
    {:ok, blob} = Blob.parse(graph)
    assert {:ok, ^blob} = Blob.parse(Blob.to_map(blob))
  end
end
