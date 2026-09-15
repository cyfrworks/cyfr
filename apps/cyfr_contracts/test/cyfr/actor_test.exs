# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.ActorTest do
  @moduledoc """
  An actor's wire map round-trips through JSON, omits unset members, and
  decodes fail-closed: an unknown, missing or mistyped member, or a string
  member over 256 bytes, is refused.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Actor

  @full %Actor{
    user_id: "usr_01a09fee-045b-770b-b745-a62792bb8798",
    request_id: "req_7d3e9a",
    authenticated: true,
    client_ip: "203.0.113.7"
  }

  defp json_round_trip(wire), do: wire |> Jason.encode!() |> Jason.decode!()

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

  test "decoding refuses an unknown, missing or mistyped member" do
    wire = Actor.to_wire(@full)

    refused = [
      Map.put(wire, "anonymous", false),
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
