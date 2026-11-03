# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.DevicePinEvaluatorsTest do
  @moduledoc """
  The PIN evaluators' rows: enrolled only for an active software client
  of the person, a replacement beside the confirmed evaluator until its
  first reset; every charge committed with its revision and reset nonce
  before it is answered, a wait writing nothing and allowed again at its
  instant; a reset only under the verifier, for the evaluation whose
  nonce it names, clearing the count and taking every other evaluator of
  the client with it; a suspended client's evaluator locating nothing
  until it is active again, a revoked client's gone; a member that lost
  its slot writing nothing. Members charging one evaluator at once, each
  on a connection of its own, are answered one charge between them.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.{DevicePinEvaluators, PairedClients}
  alias Arca.Schemas.{DevicePinEvaluator, PairedClient}
  alias Ecto.Adapters.SQL.Sandbox

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    athanor = "ath_dpe_#{System.unique_integer([:positive])}"
    {:ok, actor: Prima.Actor.in_athanor(athanor), user: "usr_dpe"}
  end

  defp client!(actor, user, holder \\ "software") do
    key = :crypto.strong_rand_bytes(32)

    {:ok, client} =
      PairedClients.record(actor, %{
        user_id: user,
        source_kind: "device_cert",
        source_id: "enroll_#{System.unique_integer([:positive])}",
        device_public_key: key,
        holder_kind: holder,
        display_name: "Pi"
      })

    client
  end

  defp attrs(client, identifier) do
    %{
      id: Prima.UUID7.generate_id("dpe"),
      user_id: client.user_id,
      paired_client_id: client.id,
      identifier_digest: :crypto.hash(:sha256, identifier),
      sealed_key: "sealed:" <> identifier
    }
  end

  defp enrolled!(actor, client, identifier \\ nil) do
    identifier = identifier || "pev_#{System.unique_integer([:positive])}"
    {:ok, row} = DevicePinEvaluators.enroll(actor, attrs(client, identifier), fn -> :ok end)
    Map.put(row, :identifier, identifier)
  end

  defp digest(%{identifier: identifier}), do: :crypto.hash(:sha256, identifier)
  defp nonce, do: :crypto.strong_rand_bytes(32)
  defp stored(id), do: Arca.Repo.get(DevicePinEvaluator, id)

  defp reset(evaluator, nonce, verify \\ fn _e, _c, _now -> :ok end),
    do:
      DevicePinEvaluators.reset(
        Prima.Actor.in_athanor(evaluator.athanor_id),
        evaluator.paired_client_id,
        nonce,
        verify
      )

  # The next evaluation allowed now: the stored wait moved into the past,
  # as the clock reaching it would.
  defp waited!(id) do
    {1, _} =
      Arca.Repo.update_all(from(e in DevicePinEvaluator, where: e.id == ^id),
        set: [next_allowed_at: 0]
      )
  end

  describe "enroll" do
    test "only an active software client of the person enrolls, under the verifier",
         %{actor: actor, user: user} do
      software = client!(actor, user)
      chip = client!(actor, user, "chip")

      assert {:error, :not_found} =
               DevicePinEvaluators.enroll(actor, attrs(chip, "pev_chip"), fn -> :ok end)

      assert {:error, :not_found} =
               DevicePinEvaluators.enroll(
                 actor,
                 %{attrs(software, "pev_other") | user_id: "usr_other"},
                 fn -> :ok end
               )

      other = Prima.Actor.in_athanor(actor.athanor_id <> "_other")

      assert {:error, :not_found} =
               DevicePinEvaluators.enroll(other, attrs(software, "pev_elsewhere"), fn -> :ok end)

      assert {:error, :refused_by_test} =
               DevicePinEvaluators.enroll(actor, attrs(software, "pev_refused"), fn ->
                 {:error, :refused_by_test}
               end)

      assert Arca.Repo.all(DevicePinEvaluator) == []

      row = enrolled!(actor, software)
      assert %{attempts: 0, revision: 0, next_allowed_at: nil, confirmed_at: nil} = row
      assert row.athanor_id == actor.athanor_id

      {1, _} =
        Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^software.id),
          set: [standing: "suspended"]
        )

      assert {:error, :not_found} =
               DevicePinEvaluators.enroll(actor, attrs(software, "pev_suspended"), fn -> :ok end)
    end

    test "a replacement stands beside the confirmed evaluator, and replaces one never reset",
         %{actor: actor, user: user} do
      client = client!(actor, user)
      old = enrolled!(actor, client)
      {:ok, %{evaluator: charged}} = DevicePinEvaluators.charge(digest(old), n = nonce())
      {:ok, _} = reset(charged, n)

      lost = enrolled!(actor, client)
      new = enrolled!(actor, client)

      ids = Arca.Repo.all(from(e in DevicePinEvaluator, select: e.id)) |> Enum.sort()
      assert ids == Enum.sort([old.id, new.id])
      refute stored(lost.id)

      assert {:error, :not_found} = DevicePinEvaluators.charge(digest(lost), nonce())
      assert {:ok, _} = DevicePinEvaluators.charge(digest(old), nonce())
      assert {:ok, %{evaluator: charged}} = DevicePinEvaluators.charge(digest(new), n = nonce())

      assert {:ok, %{confirmed_at: %DateTime{}}} = reset(charged, n)
      refute stored(old.id)
      assert {:error, :not_found} = DevicePinEvaluators.charge(digest(old), nonce())
    end
  end

  describe "charge" do
    test "charges with the revision and the reset nonce, and a wait writes nothing",
         %{actor: actor, user: user} do
      evaluator = enrolled!(actor, client!(actor, user))
      n = nonce()

      assert {:ok, %{evaluator: charged, client: client, now: now}} =
               DevicePinEvaluators.charge(digest(evaluator), n)

      assert client.id == evaluator.paired_client_id
      assert %{attempts: 1, revision: 1, reset_nonce: ^n} = charged
      assert charged.next_allowed_at == now + 1_000
      assert charged.reset_expires_at == now + 60_000
      assert stored(evaluator.id).attempts == 1

      before = stored(evaluator.id)

      assert {:error, {:pin_wait, next}} = DevicePinEvaluators.charge(digest(evaluator), nonce())
      assert next == charged.next_allowed_at
      assert stored(evaluator.id) == before

      waited!(evaluator.id)

      assert {:ok, %{evaluator: %{attempts: 2, revision: 2}}} =
               DevicePinEvaluators.charge(digest(evaluator), nonce())
    end

    test "an unknown identifier, a suspended client's and a revoked client's locate nothing",
         %{actor: actor, user: user} do
      client = client!(actor, user)
      evaluator = enrolled!(actor, client)

      assert {:error, :not_found} =
               DevicePinEvaluators.charge(:crypto.hash(:sha256, "x"), nonce())

      {1, _} =
        Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^client.id),
          set: [standing: "suspended"]
        )

      assert {:error, :not_found} = DevicePinEvaluators.charge(digest(evaluator), nonce())
      assert stored(evaluator.id).attempts == 0

      {1, _} =
        Arca.Repo.update_all(from(p in PairedClient, where: p.id == ^client.id),
          set: [standing: "active"]
        )

      assert {:ok, _} = DevicePinEvaluators.charge(digest(evaluator), nonce())

      assert {:ok, %{standing: "revoked"}} = PairedClients.revoke(actor, client.id)
      refute stored(evaluator.id)
      assert {:error, :not_found} = DevicePinEvaluators.charge(digest(evaluator), nonce())
    end

    test "a member that lost its slot charges nothing", %{actor: actor, user: user} do
      evaluator = enrolled!(actor, client!(actor, user))

      # A claimant runs and this member holds no slot.
      Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
      assert {:error, :not_owner} = DevicePinEvaluators.charge(digest(evaluator), nonce())
      assert stored(evaluator.id).attempts == 0
    end
  end

  describe "reset" do
    test "only the last evaluation's nonce under the verifier clears the count",
         %{actor: actor, user: user} do
      evaluator = enrolled!(actor, client!(actor, user))
      {:ok, %{evaluator: first}} = DevicePinEvaluators.charge(digest(evaluator), a = nonce())
      waited!(evaluator.id)
      {:ok, %{evaluator: second}} = DevicePinEvaluators.charge(digest(evaluator), b = nonce())

      # The earlier evaluation's success arrives after the later charge.
      assert {:error, :not_found} = reset(first, a)
      assert stored(evaluator.id).attempts == 2

      assert {:error, :proof_refused} =
               reset(second, b, fn _e, _c, _now -> {:error, :proof_refused} end)

      assert %{attempts: 2, reset_nonce: ^b} = stored(evaluator.id)

      parent = self()

      assert {:ok, %{attempts: 0, revision: 3, next_allowed_at: nil, reset_nonce: nil}} =
               reset(second, b, fn e, c, now ->
                 send(parent, {:verified, e, c, now})
                 :ok
               end)

      assert_received {:verified, %{revision: 2, reset_nonce: ^b}, %{id: client_id}, now}
      assert client_id == evaluator.paired_client_id and is_integer(now)

      # Spent: a replay finds no evaluation.
      assert {:error, :not_found} = reset(second, b)
      assert stored(evaluator.id).revision == 3
    end
  end

  describe "two members" do
    # Each racer stands for a member of the home: a process with a
    # connection of its own outside the sandbox, so its transaction is its
    # own and the evaluator's row is all that stands between them.
    test "charging one evaluator at once, one charge is answered and the rest wait" do
      actor = Prima.Actor.in_athanor("ath_dpe_race_#{System.unique_integer([:positive])}")

      on_exit(fn ->
        Sandbox.unboxed_run(Arca.Repo, fn ->
          Arca.Repo.delete_all(
            from(e in DevicePinEvaluator, where: e.athanor_id == ^actor.athanor_id)
          )

          Arca.Repo.delete_all(from(p in PairedClient, where: p.athanor_id == ^actor.athanor_id))
        end)
      end)

      evaluator =
        Sandbox.unboxed_run(Arca.Repo, fn -> enrolled!(actor, client!(actor, "usr_dpe")) end)

      results =
        race(8, fn _member ->
          Sandbox.unboxed_run(Arca.Repo, fn ->
            DevicePinEvaluators.charge(digest(evaluator), nonce())
          end)
        end)

      charged = for {:ok, %{evaluator: e}} <- results, do: e
      waited = for {:error, {:pin_wait, _}} <- results, do: :wait

      assert length(charged) == 1, inspect(results)
      assert length(waited) == 7, inspect(results)

      row = Sandbox.unboxed_run(Arca.Repo, fn -> stored(evaluator.id) end)
      assert %{attempts: 1, revision: 1} = row
      assert row.reset_nonce == hd(charged).reset_nonce
    end
  end

  defp race(n, fun) do
    parent = self()
    gate = :atomics.new(1, [])

    tasks =
      for i <- 1..n do
        Task.async(fn ->
          send(parent, {:ready, self()})
          spin_until_open(gate)
          fun.(i)
        end)
      end

    for _ <- 1..n do
      receive do
        {:ready, _pid} -> :ok
      after
        5_000 -> flunk("a racing member never became ready")
      end
    end

    :atomics.put(gate, 1, 1)
    Task.await_many(tasks, 30_000)
  end

  defp spin_until_open(gate) do
    if :atomics.get(gate, 1) == 0, do: spin_until_open(gate)
  end
end
