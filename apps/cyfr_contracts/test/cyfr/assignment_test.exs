# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AssignmentTest do
  @moduledoc """
  An assignment signs to one canonical token that verifies back to it under
  the assign key only. A token is refused when its MAC or payload was
  changed, when it was MAC'd with a worker service's dispatch key (a worker
  cannot mint one), when its claim deadline has passed, when its version is unknown,
  and when its payload has an unknown, missing or mistyped member: an
  authority `Cyfr.Authority.from_wire/1` refuses, a component reference
  that is not canonical, of another type or unbounded, a need or an
  intercepted action outside its grammar, or a list or actor member over
  its bound. A worker reads a token without the assign key, and reading
  grants nothing.
  """
  use ExUnit.Case, async: true

  alias Cyfr.Actor
  alias Cyfr.Assignment
  alias Cyfr.Authority
  alias Cyfr.Test.AuthorityFixtures
  alias Cyfr.WorkerAuth

  @root :binary.list_to_bin(Enum.to_list(0..31))
  @now 1_789_305_249_602

  setup_all do
    {:ok,
     assign_key: WorkerAuth.assign_key(@root),
     authority: Authority.to_wire(AuthorityFixtures.root!())}
  end

  defp assignment(authority, overrides \\ %{}) do
    struct!(
      Assignment,
      Map.merge(
        %{
          generation: 7,
          audience: "wrk_1",
          issued_at: @now,
          claim_by: @now + 30_000,
          execution_id: "exec_01a09fee-07cc-791f-a598-e7f90608c9e2",
          attempt: "att_01a09fee-0a31-7a2b-8f0c-3d1e5b7c9a42",
          fence: 1,
          parent_execution_id: "exec_01a09fee-0000-7000-8000-000000000001",
          root_execution_id: "exec_01a09fee-0000-7000-8000-000000000001",
          step: %{id: "stp_01a09fee-0000-7000-8000-000000000002", generation: 0},
          athanor_id: "ath_01a09fee-045b-770b-b745-a62792bb8798",
          actor: %Actor{
            user_id: "usr_01a09fee-0000-7000-8000-000000000003",
            request_id: "req_7d3e9a",
            authenticated: true,
            client_ip: "203.0.113.7"
          },
          authority: authority,
          component: %{
            ref: AuthorityFixtures.catalyst_ref() <> ":0.1.0",
            type: "catalyst",
            digest: Cyfr.Digest.sha256("artifact"),
            declared_needs: ["source"],
            activation_digest: Cyfr.Digest.sha256("activation")
          },
          input_digest: Cyfr.Digest.sha256(~s({"query":"select 1"})),
          timeout_ms: 30_000,
          deadline: @now + 60_000,
          lease_until: @now + 180_000,
          intercepted: ["execution.run", "execution.run_stream"]
        },
        overrides
      )
    )
  end

  defp sign!(assignment, key) do
    {:ok, token} = Assignment.sign(assignment, key)
    token
  end

  defp payload(token) do
    [payload, _mac] = String.split(token, ".")
    Base.url_decode64!(payload, padding: false)
  end

  # A token over any payload bytes, MAC'd with `key`: what only a holder of
  # that key can produce.
  defp token_over(bytes, key) do
    mac = :crypto.mac(:hmac, :sha256, key, bytes)
    Base.url_encode64(bytes, padding: false) <> "." <> Base.url_encode64(mac, padding: false)
  end

  defp resigned(token, key, change) do
    token |> payload() |> Jason.decode!() |> change.() |> Jason.encode!() |> token_over(key)
  end

  describe "sign and verify" do
    test "round-trip an assignment", %{assign_key: key, authority: authority} do
      assignment = assignment(authority)

      assert {:ok, ^assignment} = Assignment.verify(sign!(assignment, key), key, @now)
    end

    test "round-trip a root with an unset actor, no step and the zero authority",
         %{assign_key: key} do
      zero = Authority.to_wire(Authority.zero())

      root =
        assignment(zero, %{
          parent_execution_id: nil,
          step: nil,
          actor: %Actor{},
          component: %{
            ref: "reagent:local.ta:0.1.0",
            type: "reagent",
            digest: Cyfr.Digest.sha256("reagent"),
            declared_needs: [],
            activation_digest: nil
          },
          intercepted: []
        })

      assert {:ok, verified} = Assignment.verify(sign!(root, key), key, @now)
      assert verified == %{root | authority: Map.reject(zero, fn {_k, v} -> is_nil(v) end)}
      refute Map.has_key?(verified.authority, "profile_id")
    end

    test "the encoding is canonical: the same assignment signs to the same token",
         %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)
      bytes = payload(token)

      assert sign!(assignment(authority), key) == token
      assert {:ok, bytes} == Cyfr.JCS.encode(Jason.decode!(bytes))

      {:ok, verified} = Assignment.verify(token, key, @now)
      assert sign!(verified, key) == token
    end

    test "a claim is accepted until claim_by and refused after it",
         %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)

      assert {:ok, _} = Assignment.verify(token, key, @now + 30_000)
      assert {:error, :claim_expired} = Assignment.verify(token, key, @now + 30_001)
    end

    test "sign refuses an assignment verify would refuse", %{
      assign_key: key,
      authority: authority
    } do
      invalid = [
        %{v: 2},
        %{fence: 0},
        %{generation: nil},
        %{audience: ""},
        %{attempt: "att 1"},
        %{input_digest: "sha256:ABC"},
        %{step: %{id: "stp_1"}},
        %{actor: %{user_id: "usr_1"}},
        %{actor: %Actor{user_id: ""}},
        %{
          component: %{
            ref: "catalyst:local.x:0.1.0",
            type: "widget",
            digest: Cyfr.Digest.sha256("x"),
            declared_needs: []
          }
        },
        %{intercepted: ["execution"]},
        %{authority: "unbound"}
      ]

      for overrides <- invalid do
        assert {:error, :invalid_assignment} =
                 Assignment.sign(assignment(authority, overrides), key),
               inspect(overrides)
      end
    end
  end

  describe "a forged token" do
    test "is refused when its MAC was changed", %{assign_key: key, authority: authority} do
      [payload64, _mac] = String.split(sign!(assignment(authority), key), ".")
      forged = payload64 <> "." <> Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)

      assert {:error, :bad_mac} = Assignment.verify(forged, key, @now)
    end

    test "is refused when its payload was changed", %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)
      [_payload64, mac64] = String.split(token, ".")

      {:ok, widened} =
        token |> payload() |> Jason.decode!() |> Map.put("fence", 2) |> Cyfr.JCS.encode()

      forged = Base.url_encode64(widened, padding: false) <> "." <> mac64

      assert {:error, :bad_mac} = Assignment.verify(forged, key, @now)
    end

    test "is refused when MAC'd with a worker service's key: a worker cannot mint one",
         %{assign_key: key, authority: authority} do
      {:ok, worker_key} = WorkerAuth.worker_key(@root, "wrk_1")
      dispatch_key = WorkerAuth.dispatch_key(worker_key)
      assignment = assignment(authority)

      assert {:error, :bad_mac} = Assignment.verify(sign!(assignment, dispatch_key), key, @now)
      assert {:error, :bad_mac} = Assignment.verify(sign!(assignment, key), dispatch_key, @now)
    end

    test "is refused when it is not a token", %{assign_key: key, authority: authority} do
      [payload64, mac64] = String.split(sign!(assignment(authority), key), ".")
      short_mac = Base.url_encode64(:binary.copy(<<7>>, 16), padding: false)

      for token <- [
            nil,
            "",
            payload64,
            payload64 <> "." <> mac64 <> "." <> mac64,
            payload64 <> "." <> short_mac,
            "!!!." <> mac64,
            payload64 <> "=." <> mac64
          ] do
        assert {:error, :malformed} = Assignment.verify(token, key, @now), inspect(token)
      end
    end
  end

  describe "a payload MAC'd with the assign key" do
    test "is refused at an unknown version", %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)

      assert {:error, :unknown_version} =
               Assignment.verify(resigned(token, key, &Map.put(&1, "v", 2)), key, @now)

      assert {:error, :malformed} =
               Assignment.verify(resigned(token, key, &Map.put(&1, "v", "1")), key, @now)

      assert {:error, :malformed} =
               Assignment.verify(resigned(token, key, &Map.delete(&1, "v")), key, @now)
    end

    test "is refused with an unknown, missing or mistyped member",
         %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)

      changes = [
        &Map.put(&1, "priority", 1),
        &Map.delete(&1, "athanor_id"),
        &Map.delete(&1, "claim_by"),
        &Map.delete(&1, "authority"),
        &Map.put(&1, "fence", "1"),
        &Map.put(&1, "timeout_ms", 1.5),
        &Map.put(&1, "parent_execution_id", nil),
        &Map.put(&1, "step", %{"id" => "stp_1", "generation" => 0, "turn" => "t"}),
        &put_in(&1, ["actor", "anonymous"], true),
        &put_in(&1, ["component", "size"], 1),
        &Map.update!(&1, "component", fn c -> Map.delete(c, "digest") end),
        &put_in(&1, ["component", "declared_needs"], [1]),
        &Map.put(&1, "intercepted", "execution.run"),
        &Map.put(&1, "authority", [])
      ]

      for change <- changes do
        assert {:error, :malformed} = Assignment.verify(resigned(token, key, change), key, @now)
      end

      assert {:error, :malformed} = Assignment.verify(token_over("[1]", key), key, @now)
      assert {:error, :malformed} = Assignment.verify(token_over("not json", key), key, @now)
    end

    test "reads without the assign key, and what it reads still does not verify forged",
         %{assign_key: key, authority: authority} do
      assignment = assignment(authority)
      token = sign!(assignment, key)

      assert {:ok, ^assignment} = Assignment.read(token)
      assert {:ok, ^assignment} = Assignment.read(token_over(payload(token), "any key"))
      assert {:ok, _} = Assignment.read(sign!(assignment(authority, %{claim_by: 0}), key))

      widened = resigned(token, "a worker's key", &Map.put(&1, "fence", 2))
      assert {:ok, %Assignment{fence: 2}} = Assignment.read(widened)
      assert {:error, :bad_mac} = Assignment.verify(widened, key, @now)

      assert {:error, :unknown_version} =
               Assignment.read(resigned(token, key, &Map.put(&1, "v", 2)))

      assert {:error, :malformed} = Assignment.read(resigned(token, key, &Map.delete(&1, "v")))
      assert {:error, :malformed} = Assignment.read(token_over("not json", key))
      assert {:error, :malformed} = Assignment.read(nil)
    end

    test "is refused with a member outside its shape or its bound",
         %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)
      long = String.duplicate("a", 257)

      changes = [
        &put_in(&1, ["authority", "invoke_mode"], "everything"),
        &put_in(&1, ["authority", "cursor"], "bound:"),
        &put_in(&1, ["authority", "widened"], true),
        &put_in(&1, ["component", "ref"], "c:local.x:0.1.0"),
        &put_in(&1, ["component", "ref"], "reagent:local.x:0.1.0"),
        &put_in(&1, ["component", "ref"], "catalyst:local." <> long <> ":0.1.0"),
        &put_in(&1, ["component", "ref"], "catalyst:local.x:0.1.0 "),
        &put_in(&1, ["component", "declared_needs"], ["Source"]),
        &put_in(&1, ["component", "declared_needs"], ["src|dest"]),
        &put_in(&1, ["component", "declared_needs"], List.duplicate("source", 257)),
        &Map.put(&1, "intercepted", ["execution." <> long]),
        &Map.put(&1, "intercepted", List.duplicate("execution.run", 257)),
        &put_in(&1, ["actor", "client_ip"], long)
      ]

      for change <- changes do
        changed = resigned(token, key, change)
        assert {:error, :malformed} = Assignment.verify(changed, key, @now)
        assert {:error, :malformed} = Assignment.read(changed)
      end
    end

    test "decodes an absent optional member as nil", %{assign_key: key, authority: authority} do
      token = sign!(assignment(authority), key)
      unparented = resigned(token, key, &Map.drop(&1, ["parent_execution_id", "step"]))

      assert {:ok, %Assignment{parent_execution_id: nil, step: nil}} =
               Assignment.verify(unparented, key, @now)
    end
  end
end
