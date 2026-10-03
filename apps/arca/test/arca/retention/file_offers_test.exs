# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Retention.FileOffersTest do
  @moduledoc """
  The two retention kinds of sending a copy: `file_offer_days` ends
  offers past their expiry and releases the snapshots they leave, and
  `file_receipt_days` (its recovery is `Arca.FileOffersTest`'s) is on the
  roster beside it. Neither the offers' snapshots nor the receipts'
  custody copies are the staging sweep's.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.FileOffers
  alias Arca.Retention

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    n = System.unique_integer([:positive])
    sender = %Prima.Actor{athanor_id: "ath_rfo_s#{n}", user_id: "usr_rfo_s#{n}"}
    recipient = %Prima.Actor{athanor_id: "ath_rfo_r#{n}", user_id: "usr_rfo_r#{n}"}

    {:ok, group} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        kind: "group",
        name: "Retention #{n}",
        slug: "retention-offers-#{n}",
        created_by: "system"
      })

    seat = %{Prima.Actor.system() | athanor_id: group.id, scope: :athanor}

    for who <- [sender, recipient] do
      {:ok, _} = Arca.Members.seat(seat, %{user_id: who.user_id, added_by: "test"})
    end

    test_pid = self()
    handler = "retention-file-offers-#{n}"

    :ok =
      :telemetry.attach(
        handler,
        [:cyfr, :arca, :file_offer, :expired],
        fn _event, _measurements, metadata, _config -> send(test_pid, {:expired, metadata}) end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      for who <- [sender, recipient] do
        File.rm_rf(Arca.Adapters.Local.build_path(Prima.Actor.in_athanor(who.athanor_id), []))
      end
    end)

    {:ok, sender: sender, recipient: recipient, sweeper: sweeper(sender)}
  end

  test "both kinds are on the roster, in days, a week by default" do
    assert Retention.FileOffers in Retention.kinds()
    assert Retention.FileReceipts in Retention.kinds()
    assert Retention.FileOffers.key() == "file_offer_days"
    assert Retention.FileReceipts.key() == "file_receipt_days"

    for kind <- [Retention.FileOffers, Retention.FileReceipts] do
      assert kind.unit() == :days
      assert kind.default() == 7
    end
  end

  test "an offer is made with its athanor's file_offer_days", %{
    sender: sender,
    recipient: recipient
  } do
    {:ok, _} = Retention.set_settings(sender, %{"file_offer_days" => 2})
    :ok = Arca.put(sender, ["data", "docs", "a.txt"], "aaa")

    {:ok, %{expires_at: expires_at}} =
      FileOffers.offer(sender, recipient.user_id, ["data/docs/a.txt"])

    in_two_days = DateTime.add(DateTime.utc_now(), 2 * 86_400, :second)
    assert abs(DateTime.diff(expires_at, in_two_days, :second)) < 60
  end

  # Five million days names a year past 9999, which SQLite stores and
  # cannot load; two hundred million is one PostgreSQL cannot encode.
  for days <- [5_000_000, 200_000_000] do
    test "an offer under file_offer_days #{days} stands max_days, and its recipient reads it",
         %{sender: sender, recipient: recipient} do
      days = unquote(days)

      assert {:ok, %{"file_offer_days" => ^days}} =
               Retention.set_settings(sender, %{"file_offer_days" => days})

      :ok = Arca.put(sender, ["data", "docs", "a.txt"], "aaa")

      {:ok, %{offer_id: offer_id, expires_at: expires_at}} =
        FileOffers.offer(sender, recipient.user_id, ["data/docs/a.txt"])

      assert {:ok, [%{offer_id: ^offer_id, expires_at: stored}]} = FileOffers.inbox(recipient)

      ceiling =
        DateTime.add(DateTime.utc_now(), Retention.FileOffers.max_days() * 86_400, :second)

      assert abs(DateTime.diff(expires_at, ceiling, :second)) < 60
      assert abs(DateTime.diff(stored, ceiling, :second)) < 60
    end
  end

  test "an expired offer's snapshot is released once", %{
    sender: sender,
    recipient: recipient,
    sweeper: sweeper
  } do
    offer_id = offer!(sender, recipient, "a.txt")
    live = offer!(sender, recipient, "b.txt")
    expire!(offer_id)

    assert {:ok, 1} = Retention.FileOffers.prune(sweeper, 7, true)
    assert {:ok, _} = Arca.get(sender, snapshot(offer_id, "a.txt"))

    assert {:ok, 1} = Retention.FileOffers.prune(sweeper, 7, false)
    assert_receive {:expired, %{offer_id: ^offer_id, kind: :expired, filename: "a.txt"}}
    assert {:error, :not_found} = Arca.get(sender, snapshot(offer_id, "a.txt"))
    assert [%{status: "expired"}] = rows(offer_id)

    # Once: a second sweep ends nothing and announces nothing.
    assert {:ok, 0} = Retention.FileOffers.prune(sweeper, 7, false)
    refute_receive {:expired, _}, 50

    # An offer still inside its expiry is untouched.
    assert [%{status: "offered"}] = rows(live)
    assert {:ok, _} = Arca.get(sender, snapshot(live, "b.txt"))
  end

  test "an ended offer whose snapshot outlived it, and an orphan older than a day, are released",
       %{sender: sender, recipient: recipient, sweeper: sweeper} do
    ended = offer!(sender, recipient, "a.txt")

    # The status write landed and the release did not.
    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(o in Arca.Schemas.FileOffer, where: o.offer_id == ^ended),
        set: [status: "declined"]
      )

    # Bytes no row names: a crash between the copy and the rows.
    orphan = ["payloads", "offers", "ofr_orphan", "x.txt"]
    young = ["payloads", "offers", "ofr_young", "y.txt"]

    for path <- [orphan, young] do
      :ok = Arca.Overlay.with_internal_writes(fn -> Arca.put(sender, path, "orphan") end)
    end

    age!(sender, orphan, 2 * 86_400)

    assert {:ok, 2} = Retention.FileOffers.prune(sweeper, 7, false)
    assert {:error, :not_found} = Arca.get(sender, snapshot(ended, "a.txt"))
    assert {:error, :not_found} = Arca.get(sender, orphan)
    assert {:ok, "orphan"} = Arca.get(sender, young)
  end

  test "a snapshot older than fifteen minutes is untouched by the staging sweep", %{
    sender: sender,
    recipient: recipient,
    sweeper: sweeper
  } do
    offer_id = offer!(sender, recipient, "a.txt")
    age!(sender, snapshot(offer_id, "a.txt"), 3600)

    custody = ["payloads", "receipts", "ofr_elsewhere", "c.txt"]
    :ok = Arca.Overlay.with_internal_writes(fn -> Arca.put(sender, custody, "custody") end)
    age!(sender, custody, 3600)

    assert {:ok, _} = Retention.FencedStaging.prune(sweeper, 1, false)

    assert {:ok, _} = Arca.get(sender, snapshot(offer_id, "a.txt"))
    assert {:ok, "custody"} = Arca.get(sender, custody)
  end

  test "a member's write to the offers or receipts prefix is refused", %{sender: sender} do
    assert {:error, :forbidden} = Arca.put(sender, ["payloads", "offers", "ofr_x", "a.txt"], "x")

    assert {:error, :forbidden} =
             Arca.put(sender, ["payloads", "receipts", "ofr_x", "a.txt"], "x")
  end

  defp sweeper(who), do: %{Prima.Actor.system() | athanor_id: who.athanor_id, scope: :athanor}

  defp offer!(sender, recipient, name) do
    :ok = Arca.put(sender, ["data", "docs", name], "bytes-of-#{name}")
    {:ok, %{offer_id: id}} = FileOffers.offer(sender, recipient.user_id, ["data/docs/#{name}"])
    id
  end

  defp expire!(offer_id) do
    {_, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(o in Arca.Schemas.FileOffer, where: o.offer_id == ^offer_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )

    :ok
  end

  defp rows(offer_id),
    do:
      Arca.Repo.all(Ecto.Query.from(o in Arca.Schemas.FileOffer, where: o.offer_id == ^offer_id))

  defp snapshot(offer_id, name), do: ["payloads", "offers", offer_id, name]

  defp age!(who, path, seconds) do
    full = Arca.Adapters.Local.build_path(who, path)
    :ok = File.touch!(full, System.os_time(:second) - seconds)
  end
end
