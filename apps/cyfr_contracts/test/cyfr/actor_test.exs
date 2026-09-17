# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ActorTest do
  @moduledoc """
  An actor carries its tenant, plane and anonymous flag beside its four wire
  members. The wire map carries exactly those four, round-trips through
  JSON, omits unset members, and decodes fail-closed: an unknown, missing or
  mistyped member, or a string member over 256 bytes, is refused. The
  tenant, the plane and the anonymous flag never cross the wire.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Actor

  @full %Actor{
    user_id: "usr_01a09fee-045b-770b-b745-a62792bb8798",
    request_id: "req_7d3e9a",
    authenticated: true,
    client_ip: "203.0.113.7"
  }

  @wire_keys ["authenticated", "client_ip", "request_id", "user_id"]

  defp json_round_trip(wire), do: wire |> Jason.encode!() |> Jason.decode!()

  # The clause a facade that takes the actor matches: a resolved tenant is a
  # binary, and nothing else is admitted before a query.
  defp tenant_resolved?(%Actor{athanor_id: id}) when is_binary(id), do: true
  defp tenant_resolved?(%Actor{}), do: false

  test "defaults to no tenant, the external plane and a caller that is not anonymous" do
    assert %Actor{} == %Actor{
             user_id: nil,
             request_id: nil,
             authenticated: false,
             client_ip: nil,
             athanor_id: nil,
             plane: :external,
             anonymous: false
           }
  end

  test "carries the tenant, the plane and the anonymous flag beside the wire members" do
    actor = %{@full | athanor_id: "ath_01a09fee", plane: :guest, anonymous: true}

    assert actor.athanor_id == "ath_01a09fee"
    assert actor.plane == :guest
    assert actor.anonymous

    assert {actor.user_id, actor.request_id, actor.authenticated, actor.client_ip} ==
             {@full.user_id, @full.request_id, @full.authenticated, @full.client_ip}
  end

  test "an anonymous caller with a tenant and no tenant at all are different actors" do
    anonymous = %Actor{athanor_id: "ath_01a09fee", anonymous: true}
    untenanted = %Actor{user_id: "usr_1", authenticated: true}

    # A nil athanor is refused before any query, and it is never a sentinel.
    assert tenant_resolved?(anonymous)
    refute tenant_resolved?(untenanted)
    assert untenanted.athanor_id == nil
    refute untenanted.anonymous
  end

  test "round-trips through its wire map and JSON" do
    for actor <- [@full, %Actor{}, %Actor{request_id: "req_1"}] do
      assert {:ok, ^actor} = actor |> Actor.to_wire() |> json_round_trip() |> Actor.from_wire()
    end
  end

  test "the wire map carries authenticated always and every other member only when set" do
    assert Actor.to_wire(%Actor{}) == %{"authenticated" => false}

    assert Actor.to_wire(@full) == %{
             "user_id" => @full.user_id,
             "request_id" => "req_7d3e9a",
             "authenticated" => true,
             "client_ip" => "203.0.113.7"
           }

    assert {:ok, _json} = Cyfr.JCS.encode(Actor.to_wire(%Actor{user_id: "usr_1"}))
  end

  test "the tenant, the plane and the anonymous flag never cross the wire" do
    host_side = %{@full | athanor_id: "ath_01a09fee", plane: :guest, anonymous: true}
    wire = Actor.to_wire(host_side)

    assert wire == Actor.to_wire(@full)
    assert Enum.sort(Map.keys(wire)) == @wire_keys

    assert {:ok, decoded} = wire |> json_round_trip() |> Actor.from_wire()
    assert decoded == @full
    assert {decoded.athanor_id, decoded.plane, decoded.anonymous} == {nil, :external, false}

    for {key, value} <- [{"athanor_id", "ath_01a09fee"}, {"plane", "guest"}, {"anonymous", true}] do
      assert {:error, :invalid_actor} = Actor.from_wire(Map.put(wire, key, value)), key
    end
  end

  test "decoding refuses an unknown, missing or mistyped member" do
    wire = Actor.to_wire(@full)

    refused = [
      Map.put(wire, "anonymous", false),
      Map.put(wire, "athanor_id", "ath_01a09fee"),
      Map.put(wire, "plane", "external"),
      Map.put(wire, "role", "admin"),
      # The flag is the one member that is never optional.
      Map.delete(wire, "authenticated"),
      %{wire | "authenticated" => "true"},
      %{wire | "authenticated" => nil},
      %{wire | "user_id" => 42},
      %{wire | "user_id" => ""},
      %{wire | "request_id" => String.duplicate("r", 257)},
      %{wire | "request_id" => nil},
      %{wire | "client_ip" => ["203.0.113.7"]},
      %{authenticated: true},
      [],
      nil,
      "actor"
    ]

    for value <- refused do
      assert {:error, :invalid_actor} = Actor.from_wire(value), inspect(value)
    end

    assert {:ok, %Actor{}} = Actor.from_wire(%{wire | "request_id" => String.duplicate("r", 256)})
  end
end
