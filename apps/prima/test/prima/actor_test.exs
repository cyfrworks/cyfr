# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ActorTest do
  @moduledoc """
  An actor carries its tenant, plane, anonymous flag, tenancy scope and
  system flag beside its four wire members. The wire map carries exactly
  those four, round-trips through JSON, omits unset members, and decodes
  fail-closed: an unknown, missing or mistyped member, or a string member
  over 256 bytes, is refused. The tenant, the plane, the anonymous flag,
  the scope and the system flag never cross the wire — a worker cannot
  claim platform scope or system authority by sending one back.
  """
  use ExUnit.Case, async: true

  alias Prima.Actor

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

  test "defaults to no tenant, the external plane, a caller that is not anonymous, its own athanor's scope and no system authority" do
    assert %Actor{} == %Actor{
             user_id: nil,
             request_id: nil,
             authenticated: false,
             client_ip: nil,
             athanor_id: nil,
             plane: :external,
             anonymous: false,
             scope: :athanor,
             system: false
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

  describe "system/0" do
    test "is the server acting as itself: no tenant, no credential, both authorities" do
      assert Actor.system() == %Actor{
               user_id: nil,
               request_id: nil,
               authenticated: false,
               client_ip: nil,
               athanor_id: nil,
               plane: :external,
               anonymous: false,
               scope: :platform,
               system: true
             }

      # No tenant resolved, and not the anonymous caller that has one.
      refute tenant_resolved?(Actor.system())
      refute Actor.system().anonymous
    end

    test "an internal task inside one athanor keeps the system authority and gives up the cross-tenant read" do
      scoped = %{Actor.system() | athanor_id: "ath_01a09fee", scope: :athanor}

      assert scoped.system
      assert scoped.scope == :athanor
      assert tenant_resolved?(scoped)
    end
  end

  test "the scope and the system flag are two authorities, not two spellings of one" do
    # Every combination is a real actor: the server (both), an internal
    # task inside one athanor (system only), a record reader crossing
    # tenants (platform only) and an ordinary caller (neither).
    for {scope, system} <- [{:platform, true}, {:athanor, true}, {:platform, false}] do
      actor = %Actor{scope: scope, system: system}
      assert {actor.scope, actor.system} == {scope, system}
    end

    assert {%Actor{}.scope, %Actor{}.system} == {:athanor, false}
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

    assert {:ok, _json} = Prima.JCS.encode(Actor.to_wire(%Actor{user_id: "usr_1"}))
  end

  test "the tenant, the plane, the anonymous flag, the scope and the system flag never cross the wire" do
    host_side = %{
      @full
      | athanor_id: "ath_01a09fee",
        plane: :guest,
        anonymous: true,
        scope: :platform,
        system: true
    }

    wire = Actor.to_wire(host_side)

    assert wire == Actor.to_wire(@full)
    assert Enum.sort(Map.keys(wire)) == @wire_keys

    assert {:ok, decoded} = wire |> json_round_trip() |> Actor.from_wire()
    assert decoded == @full

    assert {decoded.athanor_id, decoded.plane, decoded.anonymous, decoded.scope, decoded.system} ==
             {nil, :external, false, :athanor, false}

    for {key, value} <- [
          {"athanor_id", "ath_01a09fee"},
          {"plane", "guest"},
          {"anonymous", true},
          {"scope", "platform"},
          {"system", true}
        ] do
      assert {:error, :invalid_actor} = Actor.from_wire(Map.put(wire, key, value)), key
    end
  end

  test "the server's own actor comes back from the wire with neither authority" do
    assert {:ok, decoded} =
             Actor.system() |> Actor.to_wire() |> json_round_trip() |> Actor.from_wire()

    assert decoded == %Actor{}
    assert decoded.scope == :athanor
    refute decoded.system
  end

  test "a worker cannot claim platform scope or system authority over the wire" do
    wire = Actor.to_wire(@full)

    claims = [
      %{"authenticated" => true, "scope" => "platform"},
      %{"authenticated" => true, "system" => true},
      # Either one alongside otherwise-valid members, and both together.
      Map.put(wire, "scope", "platform"),
      Map.put(wire, "system", true),
      wire |> Map.put("scope", "platform") |> Map.put("system", true),
      # The values a decoder might be tempted to read as harmless.
      Map.put(wire, "scope", "athanor"),
      Map.put(wire, "system", false)
    ]

    for claim <- claims do
      assert {:error, :invalid_actor} = Actor.from_wire(claim), inspect(claim)
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
