# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.FileOffersTest.Store do
  @moduledoc false
  # The Local adapter, with the steps a file transfer takes held where a
  # case says: a policy answers a kind of call the same way every time
  # (`policy/1`), and an armed kind asks the test process what to do with
  # each call and waits for its answer (`arm/2`). Kinds: `:list` (a
  # folder probe under `data/`), `:get` (a read under `data/`), `:custody`
  # (a write of a custody copy), `:release` (a delete of one), `:snapshot`
  # (a write of an offer's snapshot) and `:create` (a conditional create).
  # Modes: `:proceed`, `:fail` (`{:error, :eio}`, nothing written),
  # `:unknown` (written, answered `{:error, :unknown}`), `:write_hold`
  # and `:unknown_hold` (written, then held until `{:release}`).
  use Arca.Storage.TestDouble

  @policy {__MODULE__, :policy}
  @armed {__MODULE__, :armed}

  def policy(map) when is_map(map), do: :persistent_term.put(@policy, map)

  def arm(pid, kinds) when is_pid(pid) and is_list(kinds),
    do: :persistent_term.put(@armed, {pid, kinds})

  def reset do
    :persistent_term.erase(@policy)
    :persistent_term.erase(@armed)
    :ok
  end

  def last_modified(actor, path), do: Arca.Adapters.Local.last_modified(actor, path)

  def list_typed(actor, ["data" | _] = path) do
    case ask(:list, path) do
      {:fail, _} -> {:error, :eio}
      _ -> super(actor, path)
    end
  end

  def list_typed(actor, path), do: super(actor, path)

  def get(actor, ["data" | _] = path) do
    case ask(:get, path) do
      {:fail, _} -> {:error, :eio}
      _ -> super(actor, path)
    end
  end

  def get(actor, path), do: super(actor, path)

  def put(actor, ["payloads", "receipts" | _] = path, content) do
    case ask(:custody, path) do
      {:fail, _} -> {:error, :eio}
      _ -> super(actor, path, content)
    end
  end

  def put(actor, ["payloads", "offers" | _] = path, content) do
    case ask(:snapshot, path) do
      {:fail, _} -> {:error, :eio}
      _ -> super(actor, path, content)
    end
  end

  def put(actor, path, content), do: super(actor, path, content)

  def delete(actor, ["payloads", "receipts" | _] = path) do
    case ask(:release, path) do
      {:fail, _} -> {:error, :eio}
      _ -> super(actor, path)
    end
  end

  def delete(actor, path), do: super(actor, path)

  def put_if_none_match(actor, path, content) do
    case ask(:create, path) do
      {:fail, _} ->
        {:error, :eio}

      {:unknown, _} ->
        with {:ok, _} <- super(actor, path, content), do: {:error, :unknown}

      {:unknown_hold, pid} ->
        with {:ok, _} <- super(actor, path, content) do
          hold(pid, path)
          {:error, :unknown}
        end

      {:write_hold, pid} ->
        result = super(actor, path, content)
        hold(pid, path)
        result

      _proceed ->
        super(actor, path, content)
    end
  end

  defp ask(kind, path) do
    policy = :persistent_term.get(@policy, %{})

    case {Map.fetch(policy, kind), :persistent_term.get(@armed, nil)} do
      {{:ok, mode}, _} ->
        {mode, nil}

      {:error, {pid, kinds}} ->
        if kind in kinds do
          send(pid, {kind, self(), path})

          receive do
            {:reply, mode} -> {mode, pid}
          end
        else
          {:proceed, nil}
        end

      _ ->
        {:proceed, nil}
    end
  end

  defp hold(pid, path) do
    send(pid, {:held, self(), path})

    receive do
      :release -> :ok
    end
  end
end

defmodule Arca.FileOffersTest.Caps do
  @moduledoc false
  # The storage cap of the athanors a case names, by bytes: the walk the
  # tenancy domain's cap makes, against a ceiling the case sets. Every
  # other athanor, and every count, is admitted.
  @behaviour Prima.Caps

  def ceiling(athanor_id, bytes), do: :persistent_term.put({__MODULE__, athanor_id}, bytes)
  def clear(athanor_id), do: :persistent_term.erase({__MODULE__, athanor_id})

  @impl Prima.Caps
  def check_counted(%Prima.Actor{}, _key, count) when is_function(count, 0), do: :ok

  @impl Prima.Caps
  def check_storage(%Prima.Actor{athanor_id: id} = actor, incoming) do
    case :persistent_term.get({__MODULE__, id}, nil) do
      nil ->
        :ok

      cap ->
        case Arca.Usage.athanor_bytes(actor) do
          {:ok, used} when used + incoming > cap ->
            {:error, {:limit_reached, :athanor_storage_bytes, cap}}

          {:ok, _used} ->
            :ok

          {:error, _} ->
            {:error, :storage_unverifiable}
        end
    end
  end
end

defmodule Arca.FileOffersTest do
  @moduledoc """
  Sending a copy, through `Arca.FileOffers`: the offer and its snapshot,
  the acceptance that moves custody first, and the publication a claim
  owns, at every point a crash, a race or an uncertain storage answer
  can leave it.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.FileOffers
  alias Arca.FileOffersTest.{Caps, Store}
  alias Arca.Schemas.{FileOffer, FileReceipt}

  @events for kind <- ~w(offered accepted declined withdrawn expired)a,
              do: [:cyfr, :arca, :file_offer, kind]

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    no_claimant!()

    previous_adapter = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, Store)
    installed_caps = Prima.Caps.impl!()
    Prima.Caps.install!(Caps)

    n = System.unique_integer([:positive])
    sender = person("usr_fo_s#{n}", "ath_fo_s#{n}")
    recipient = person("usr_fo_r#{n}", "ath_fo_r#{n}")
    stranger = person("usr_fo_x#{n}", "ath_fo_x#{n}")
    group = group!(n)

    for who <- [sender, recipient] do
      {:ok, _} = Arca.Members.seat(seat_actor(group), %{user_id: who.user_id, added_by: "test"})
    end

    test_pid = self()
    handler = "file-offers-#{n}"

    :ok =
      :telemetry.attach_many(
        handler,
        @events,
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:offer_event, event, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      Store.reset()

      if previous_adapter,
        do: Application.put_env(:arca, :storage_adapter, previous_adapter),
        else: Application.delete_env(:arca, :storage_adapter)

      Prima.Caps.install!(installed_caps)

      for who <- [sender, recipient, stranger] do
        Caps.clear(who.athanor_id)
        File.rm_rf(Arca.Adapters.Local.build_path(Prima.Actor.in_athanor(who.athanor_id), []))
      end
    end)

    {:ok, sender: sender, recipient: recipient, stranger: stranger}
  end

  # An acceptance is fenced by this member's slot. No claimant runs in a
  # test, under the umbrella's configuration or this app's alone, so none
  # is held and none is asked for; the switch is restored after each case.
  defp no_claimant! do
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    Application.put_env(:arca, :control_plane_claim_enabled, false)

    on_exit(fn ->
      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)
  end

  # ---------------------------------------------------------------------------
  # The offer
  # ---------------------------------------------------------------------------

  describe "offer/3" do
    test "copies each file into the sender's snapshot, under the sender's cap, until it ends",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "alpha-bytes")
      source!(sender, "b.txt", "beta")
      before = used(sender)

      assert {:ok, %{offer_id: offer_id, files: files, expires_at: %DateTime{}}} =
               FileOffers.offer(sender, recipient.user_id, [
                 "data/docs/a.txt",
                 ["data", "docs", "b.txt"]
               ])

      assert Enum.map(files, &{&1.filename, &1.size, &1.status}) |> Enum.sort() ==
               [{"a.txt", 11, "offered"}, {"b.txt", 4, "offered"}]

      assert used(sender) == before + 15
      assert {:ok, "alpha-bytes"} = Arca.get(sender, ["payloads", "offers", offer_id, "a.txt"])

      for _ <- 1..2 do
        assert_receive {:offer_event, [:cyfr, :arca, :file_offer, :offered], metadata}
        assert metadata.offer_id == offer_id
        assert metadata.kind == :offered
        assert metadata.sender_user_id == sender.user_id
        assert metadata.recipient_user_id == recipient.user_id
        assert metadata.filename in ["a.txt", "b.txt"]
        refute Map.has_key?(metadata, :content)
      end

      assert {:ok, inbox} = FileOffers.inbox(recipient)
      assert Enum.map(inbox, & &1.offer_id) |> Enum.uniq() == [offer_id]
      assert {:ok, outbox} = FileOffers.outbox(sender)
      assert length(outbox) == 2

      # The snapshot counts until the offer ends.
      assert :ok = FileOffers.withdraw(sender, offer_id)
      assert used(sender) == before
      assert {:error, :not_found} = Arca.get(sender, ["payloads", "offers", offer_id, "a.txt"])
    end

    test "an offer whose insert the database answers with no outcome leaves its snapshot to the sweep",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "alpha")
      Store.arm(self(), [:snapshot])

      offer =
        Task.async(fn -> FileOffers.offer(sender, recipient.user_id, ["data/docs/a.txt"]) end)

      offer_pid = offer.pid

      assert_receive {:snapshot, ^offer_pid, ["payloads", "offers", offer_id, "a.txt"] = key},
                     5_000

      # A row of that offer and name lands first, so the offer's insert
      # meets the unique index: the database answers no outcome the call
      # can name (`:database_error`), and rows it landed would name the
      # snapshot, so the snapshot stays.
      offer_row!(sender, recipient, offer_id, "a.txt")
      send(offer_pid, {:reply, :proceed})
      assert {:error, :database_error} = Task.await(offer)
      Store.reset()

      assert {:ok, "alpha"} = Arca.get(sender, key)
      assert {:ok, 0} = FileOffers.sweep_snapshots(sender, false)

      # Once no row names it, the sweep releases it after a day.
      Arca.Repo.delete_all(Ecto.Query.from(o in FileOffer, where: o.offer_id == ^offer_id))
      assert {:ok, 0} = FileOffers.sweep_snapshots(sender, false)
      age_file!(sender, key, 2 * 86_400)
      assert {:ok, 1} = FileOffers.sweep_snapshots(sender, false)
      assert {:error, :not_found} = Arca.get(sender, key)
    end

    test "an offer to a person the sender shares no athanor with is refused",
         %{sender: sender, stranger: stranger} do
      source!(sender, "a.txt", "x")

      assert {:error, :not_shared} =
               FileOffers.offer(sender, stranger.user_id, ["data/docs/a.txt"])

      assert {:ok, []} = FileOffers.outbox(sender)
    end

    test "a path outside data/, a file over max_write and two files of one name are refused",
         %{sender: sender, recipient: recipient} do
      source!(sender, "a.txt", "x")
      Arca.put(sender, ["notes", "n.txt"], "x")
      Arca.put(sender, ["data", "other", "a.txt"], "y")

      for outside <- ["notes/n.txt", "payloads/x", "data", "../data/docs/a.txt", 7] do
        assert {:error, {:outside_data, _}} =
                 FileOffers.offer(sender, recipient.user_id, [outside])
      end

      assert {:error, :no_files} = FileOffers.offer(sender, recipient.user_id, [])

      assert {:error, :duplicate_filename} =
               FileOffers.offer(sender, recipient.user_id, ["data/docs/a.txt", "data/other/a.txt"])

      big = :binary.copy("z", Arca.Files.max_write() + 1)
      :ok = Arca.put(sender, ["data", "docs", "big.bin"], big, cap: :exempt)

      assert {:error, {:too_large, "big.bin"}} =
               FileOffers.offer(sender, recipient.user_id, ["data/docs/big.bin"])

      assert {:ok, []} = FileOffers.outbox(sender)
    end
  end

  # ---------------------------------------------------------------------------
  # Acceptance
  # ---------------------------------------------------------------------------

  describe "accept/3" do
    test "usage at 60 of 100 and a 20-byte file: custody to 80, publication to 100, release to 80",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      filler!(recipient, 60)
      Caps.ceiling(recipient.athanor_id, 100)

      # Held after the custody copy and the commit, before publication.
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      assert used(recipient) == 80
      assert receipt.status == "received"

      # Held after the create, before the release.
      Store.arm(self(), [:create])
      task = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, store, _path}, 5_000
      send(store, {:reply, :write_hold})
      assert_receive {:held, ^store, _path}, 5_000
      # The write has landed and is not yet accounted: walk the tree.
      assert {:ok, %{bytes: 100}} = Arca.usage(recipient, [])
      send(store, :release)

      assert {:ok, %{status: "completed"}} = Task.await(task)
      assert used(recipient) == 80
      assert {:ok, bytes(20)} == Arca.get(recipient, ["data", "inbox", offer_id, "file.txt"])

      assert_receive {:offer_event, [:cyfr, :arca, :file_offer, :accepted],
                      %{offer_id: ^offer_id}}
    end

    test "usage at 70 of 100 and a 20-byte file is refused at acceptance; nothing is copied",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      filler!(recipient, 70)
      Caps.ceiling(recipient.athanor_id, 100)

      assert {:error, {:limit_reached, :athanor_storage_bytes, 100}} =
               FileOffers.accept(recipient, offer_id, "data/inbox")

      assert used(recipient) == 70
      assert custody_keys(recipient, offer_id) == []
      assert {:ok, []} = FileOffers.receipts(recipient)
      assert [%{status: "offered"}] = offer_rows(offer_id)
    end

    test "another person, an ended offer and a folder outside data/ are refused, nothing staged",
         %{sender: sender, recipient: recipient, stranger: stranger} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(5))

      assert {:error, :not_found} = FileOffers.accept(stranger, offer_id, "data/inbox")

      for folder <- ["notes/inbox", "payloads/receipts", "../data", "", ["aqua"]] do
        assert {:error, {:outside_data, _}} = FileOffers.accept(recipient, offer_id, folder)
      end

      assert :ok = FileOffers.decline(recipient, offer_id)

      assert_receive {:offer_event, [:cyfr, :arca, :file_offer, :declined],
                      %{offer_id: ^offer_id}}

      assert {:error, {:not_offered, "declined"}} =
               FileOffers.accept(recipient, offer_id, "data/inbox")

      assert custody_keys(recipient, offer_id) == []
      assert {:ok, []} = FileOffers.receipts(recipient)
      assert {:ok, []} = Arca.list(recipient, ["data"])
    end

    test "an offer past its expiry is not accepted", %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(5))
      age_offer!(offer_id, -60)

      assert {:error, {:not_offered, "expired"}} =
               FileOffers.accept(recipient, offer_id, "data/inbox")
    end

    test "under a stale owner the acceptance is refused :not_owner, nothing copied",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(5))
      previous = Application.get_env(:arca, :control_plane_claim_enabled)
      Application.put_env(:arca, :control_plane_claim_enabled, true)

      try do
        assert {:error, :not_owner} = FileOffers.accept(recipient, offer_id, "data/inbox")
      after
        Application.put_env(:arca, :control_plane_claim_enabled, previous)
      end

      assert custody_keys(recipient, offer_id) == []
      assert [%{status: "offered"}] = offer_rows(offer_id)
    end

    test "an acceptance racing a withdrawal: whichever lands first wins, the other is refused",
         %{sender: sender, recipient: recipient} do
      # The withdrawal lands between the custody copy and the commit.
      first = offered!(sender, recipient, "first.txt", bytes(5))
      Store.arm(self(), [:custody])
      task = Task.async(fn -> FileOffers.accept(recipient, first, "data/inbox") end)
      assert_receive {:custody, store, _path}, 5_000
      assert :ok = FileOffers.withdraw(sender, first)
      send(store, {:reply, :proceed})

      assert {:error, {:not_offered, "withdrawn"}} = Task.await(task)
      assert {:ok, []} = FileOffers.receipts(recipient)
      assert custody_keys(recipient, first) == []
      Store.reset()

      # The acceptance lands first: the withdrawal is refused and the copy stands.
      second = offered!(sender, recipient, "second.txt", bytes(5))

      assert {:ok, %{receipts: [%{status: "completed"}]}} =
               FileOffers.accept(recipient, second, "data/inbox")

      assert {:error, {:not_offered, "accepted"}} = FileOffers.withdraw(sender, second)
      assert {:ok, _} = Arca.get(recipient, ["data", "inbox", second, "second.txt"])
    end

    test "an offer's files land together in one folder the offer names",
         %{sender: sender, recipient: recipient} do
      offer_id = offered_files!(sender, recipient, [{"a.txt", bytes(3)}, {"b.txt", bytes(4)}])

      assert {:ok, %{receipts: receipts}} = FileOffers.accept(recipient, offer_id, "data/inbox")
      assert Enum.map(receipts, & &1.status) == ["completed", "completed"]

      folder = "data/inbox/#{offer_id}"

      assert receipts |> Enum.map(& &1.attempt_path) |> Enum.sort() ==
               ["#{folder}/a.txt", "#{folder}/b.txt"]

      assert {:ok, [^offer_id]} = Arca.list(recipient, ["data", "inbox"])
      assert {:ok, files} = Arca.list(recipient, ["data", "inbox", offer_id])
      assert Enum.sort(files) == ["a.txt", "b.txt"]
    end

    test "a foreign file at one name in the offer's folder moves that file alone to the next index",
         %{sender: sender, recipient: recipient} do
      offer_id = offered_files!(sender, recipient, [{"a.txt", bytes(3)}, {"b.txt", bytes(4)}])

      # Both receipts are committed and neither has chosen a path.
      Store.policy(%{list: :fail})
      {:ok, %{receipts: receipts}} = FileOffers.accept(recipient, offer_id, "data/inbox")
      Store.reset()
      [a, b] = Enum.sort_by(receipts, & &1.filename)

      # The first publishes into the offer's folder; then the recipient
      # writes a file of their own at the second's name there.
      assert {:ok, %{status: "completed"}} = FileOffers.complete(recipient, a.id)
      :ok = Arca.put(recipient, ["data", "inbox", offer_id, "b.txt"], "mine")

      # The second chooses the folder its sibling recorded, its create
      # answers exists with other bytes, and it alone moves on.
      assert {:ok, %{status: "completed", attempt_path: moved}} =
               FileOffers.complete(recipient, b.id)

      assert moved == "data/inbox/#{offer_id}-2/b.txt"

      assert Jason.decode!(row!(b.id).issued_paths) ==
               ["data/inbox/#{offer_id}/b.txt", "data/inbox/#{offer_id}-2/b.txt"]

      assert {:ok, "mine"} = Arca.get(recipient, ["data", "inbox", offer_id, "b.txt"])
      assert {:ok, bytes(3)} == Arca.get(recipient, ["data", "inbox", offer_id, "a.txt"])
      assert {:ok, bytes(4)} == Arca.get(recipient, ["data", "inbox", offer_id <> "-2", "b.txt"])
    end

    test "two acceptances of one offer: a loser failing after the winner commits releases only its own copy",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(12))
      Store.arm(self(), [:custody, :list])

      # Both read the offer and the snapshot, and each is held before its
      # custody copy.
      winner = Task.async(fn -> FileOffers.accept(recipient, offer_id, "data/inbox") end)
      winner_pid = winner.pid
      assert_receive {:custody, ^winner_pid, _path}, 5_000
      loser = Task.async(fn -> FileOffers.accept(recipient, offer_id, "data/again") end)
      loser_pid = loser.pid
      assert_receive {:custody, ^loser_pid, _path}, 5_000

      # The winner copies and commits, so the sender's snapshot is gone;
      # its publication is held at its folder probe.
      send(winner_pid, {:reply, :proceed})
      assert_receive {:list, ^winner_pid, _folder}, 5_000

      # The loser copies after it and its receipt insert meets the
      # winner's: the database answers no outcome it can name
      # (`:database_error`), so the loser leaves its copy to the orphan
      # sweep rather than releasing what a commit might name.
      send(loser_pid, {:reply, :proceed})
      assert {:error, :database_error} = Task.await(loser)

      # The winner publishes from its own custody copy.
      send(winner_pid, {:reply, :proceed})
      assert {:ok, %{receipts: [%{id: id, status: "completed"}]}} = Task.await(winner)
      Store.reset()
      assert {:ok, %{status: "completed"}} = FileOffers.complete(recipient, id)
      assert {:ok, bytes(12)} == Arca.get(recipient, ["data", "inbox", offer_id, "file.txt"])
      assert {:ok, [_one]} = FileOffers.receipts(recipient)
      refute match?({:ok, [_ | _]}, Arca.list(recipient, ["data", "again"]))

      # The loser's copy stands, named by no receipt; under a day old the
      # sweep keeps it, older it goes.
      assert [orphan] = custody_keys(recipient, offer_id)
      assert {:ok, 0} = FileOffers.sweep_custody(recipient, false)
      age_file!(recipient, orphan, 2 * 86_400)
      assert {:ok, 1} = FileOffers.sweep_custody(recipient, false)
      assert custody_keys(recipient, offer_id) == []
    end

    test "two acceptances of one offer: a loser failing before the winner commits releases only its own copy",
         %{sender: sender, recipient: recipient} do
      offer_id = offered_files!(sender, recipient, [{"a.txt", bytes(6)}, {"b.txt", bytes(7)}])
      Store.arm(self(), [:custody])

      # The winner copies its first file and is held before its second,
      # and before its commit.
      winner = Task.async(fn -> FileOffers.accept(recipient, offer_id, "data/inbox") end)
      winner_pid = winner.pid
      assert_receive {:custody, ^winner_pid, _first}, 5_000
      send(winner_pid, {:reply, :proceed})
      assert_receive {:custody, ^winner_pid, _second}, 5_000

      # The loser copies its first file, its second copy fails, and it
      # releases what it wrote.
      loser = Task.async(fn -> FileOffers.accept(recipient, offer_id, "data/again") end)
      loser_pid = loser.pid
      assert_receive {:custody, ^loser_pid, _first}, 5_000
      send(loser_pid, {:reply, :proceed})
      assert_receive {:custody, ^loser_pid, _second}, 5_000
      send(loser_pid, {:reply, :fail})
      assert {:error, :eio} = Task.await(loser)

      # The winner's copies stand: it commits and publishes both.
      send(winner_pid, {:reply, :proceed})
      assert {:ok, %{receipts: receipts}} = Task.await(winner)

      assert receipts |> Enum.map(&{&1.filename, &1.status}) |> Enum.sort() ==
               [{"a.txt", "completed"}, {"b.txt", "completed"}]

      Store.reset()

      for receipt <- receipts,
          do: assert({:ok, %{status: "completed"}} = FileOffers.complete(recipient, receipt.id))

      # Both files land in the one folder the offer names.
      assert {:ok, [^offer_id]} = Arca.list(recipient, ["data", "inbox"])
      assert {:ok, bytes(6)} == Arca.get(recipient, ["data", "inbox", offer_id, "a.txt"])
      assert {:ok, bytes(7)} == Arca.get(recipient, ["data", "inbox", offer_id, "b.txt"])
      assert custody_keys(recipient, offer_id) == []
    end

    # A custody path is 88 characters and the name; a folder may be long.
    # No path column is bounded below what a name and a folder allow, on
    # either adapter.
    test "a long filename is accepted and published", %{sender: sender, recipient: recipient} do
      name = String.duplicate("a", 196) <> ".txt"
      offer_id = offered!(sender, recipient, name, bytes(9))

      assert {:ok, %{receipts: [%{id: id, status: "completed"}]}} =
               FileOffers.accept(recipient, offer_id, "data/inbox")

      assert String.length(row!(id).custody_path) > 255
      assert {:ok, bytes(9)} == Arca.get(recipient, ["data", "inbox", offer_id, name])
    end

    test "a long filename in a long folder completes at the path it records",
         %{sender: sender, recipient: recipient} do
      name = String.duplicate("b", 156) <> ".txt"
      folder = "data/" <> String.duplicate("f", 55)
      offer_id = offered!(sender, recipient, name, bytes(9))

      assert {:ok, %{receipts: [%{id: id, status: "completed"}]}} =
               FileOffers.accept(recipient, offer_id, folder)

      path = row!(id).attempt_path
      assert path == Enum.join([folder, offer_id, name], "/")
      assert String.length(path) > 255
      assert {:ok, bytes(9)} == Arca.get(recipient, String.split(folder, "/") ++ [offer_id, name])
    end

    test "the sender's athanor purged after the commit: the receipt and its custody publish",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(9))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")

      {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(sender.athanor_id))
      :ok = Arca.delete_tree(sender, [])

      assert {:ok, %{status: "completed"}} = FileOffers.complete(recipient, receipt.id)
      assert {:ok, bytes(9)} == Arca.get(recipient, ["data", "inbox", offer_id, "file.txt"])
      assert {:error, :not_found} = Arca.get(recipient, custody_of(receipt))
    end
  end

  # ---------------------------------------------------------------------------
  # Crash points: the sweep's complete/2 finishes each
  # ---------------------------------------------------------------------------

  describe "a crash at each step" do
    test "after the custody copy, before the commit: the offer stays offered, the copy is swept after a day",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(7))

      Store.policy(%{custody: :fail})
      assert {:error, :eio} = FileOffers.accept(recipient, offer_id, "data/inbox")
      Store.reset()

      # What a crash between the copy and the commit leaves: the copy and
      # no receipt.
      :ok =
        Arca.Overlay.with_internal_writes(fn ->
          Arca.put(recipient, custody(offer_id, "att_crashed", "file.txt"), bytes(7))
        end)

      assert [%{status: "offered"}] = offer_rows(offer_id)

      # Under a day old it stands; older, the sweep takes it.
      assert {:ok, 0} = FileOffers.sweep_custody(recipient, false)
      age_file!(recipient, custody(offer_id, "att_crashed", "file.txt"), 2 * 86_400)
      assert {:ok, 1} = FileOffers.sweep_custody(recipient, false)

      assert {:error, :not_found} =
               Arca.get(recipient, custody(offer_id, "att_crashed", "file.txt"))
    end

    test "after the commit, before publication", %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")

      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert_published_once(recipient, receipt, offer_id)
    end

    test "after the create, before published: the retry matches, publishes and releases without the cap",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      filler!(recipient, 60)
      Caps.ceiling(recipient.athanor_id, 100)
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      path = "data/inbox/#{offer_id}/file.txt"

      # The create landed and the row says only that it was sent.
      :ok = Arca.put(recipient, ["data", "inbox", offer_id, "file.txt"], bytes(20))
      issued!(receipt.id, path)
      assert used(recipient) == 100

      # A write of 20 more bytes would be refused at 100 of 100: completing
      # here proves the cap was never asked.
      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert_published_once(recipient, receipt, offer_id)
      assert used(recipient) == 80
    end

    test "after published, before the release", %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      path = "data/inbox/#{offer_id}/file.txt"
      :ok = Arca.put(recipient, ["data", "inbox", offer_id, "file.txt"], bytes(20))
      issued!(receipt.id, path)
      set_receipt!(receipt.id, status: "published")

      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert_published_once(recipient, receipt, offer_id)
    end

    test "after the release, before completed", %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      path = "data/inbox/#{offer_id}/file.txt"
      :ok = Arca.put(recipient, ["data", "inbox", offer_id, "file.txt"], bytes(20))
      issued!(receipt.id, path)
      set_receipt!(receipt.id, status: "published")

      :ok =
        Arca.Overlay.with_internal_writes(fn ->
          Arca.delete(recipient, custody_of(receipt))
        end)

      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert_published_once(recipient, receipt, offer_id)
      assert used(recipient) == 20
    end

    test "an issued attempt whose read answers not_found is re-issued at the same path",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      path = "data/inbox/#{offer_id}/file.txt"
      issued!(receipt.id, path)

      assert {:ok, %{status: "completed", attempt_path: ^path}} =
               FileOffers.complete(recipient, receipt.id)

      # The first write landing late answers exists: one file either way.
      assert {:error, :exists} =
               Arca.put_if_none_match(
                 recipient,
                 ["data", "inbox", offer_id, "file.txt"],
                 bytes(20)
               )

      assert {:ok, [^offer_id]} = Arca.list(recipient, ["data", "inbox"])
    end

    test "a read that cannot answer during reconciliation changes nothing, and the next sweep finishes",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      issued!(receipt.id, "data/inbox/#{offer_id}/file.txt")
      before = row!(receipt.id)

      Store.policy(%{get: :fail})
      assert {:error, {:unavailable, :eio}} = FileOffers.complete(recipient, receipt.id)
      Store.reset()

      after_failure = row!(receipt.id)

      assert Map.take(after_failure, [:status, :attempt_path, :attempt_state, :issued_paths]) ==
               Map.take(before, [:status, :attempt_path, :attempt_state, :issued_paths])

      assert after_failure.completing_by == nil

      assert {:ok, %{status: "completed"}} = FileOffers.complete(recipient, receipt.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Uncertain storage and the paths a transfer may land at
  # ---------------------------------------------------------------------------

  describe "uncertain publication" do
    test "the recipient precreating the offer's folder: the create answers exists, the transfer lands under -2",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")

      Store.arm(self(), [:create])
      task = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, store, ["data", "inbox", ^offer_id, "file.txt"]}, 5_000

      # The recipient's own file lands at the recorded path first.
      :ok = Arca.put(recipient, ["data", "inbox", offer_id, "file.txt"], "mine")
      send(store, {:reply, :proceed})
      assert_receive {:create, store2, ["data", "inbox", second, "file.txt"]}, 5_000
      assert second == offer_id <> "-2"

      # Custody is released only after `published`.
      assert {:ok, _} = Arca.get(recipient, custody_of(receipt))
      send(store2, {:reply, :proceed})

      assert {:ok, %{status: "completed", attempt_path: landed}} = Task.await(task)
      assert landed == "data/inbox/#{second}/file.txt"
      assert {:ok, "mine"} = Arca.get(recipient, ["data", "inbox", offer_id, "file.txt"])
      assert {:ok, bytes(20)} == Arca.get(recipient, ["data", "inbox", second, "file.txt"])
      assert {:error, :not_found} = Arca.get(recipient, custody_of(receipt))
    end

    test "an adapter that creates the object and answers unknown: reconciled by digest, one folder",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")

      Store.arm(self(), [:create])
      task = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, store, _path}, 5_000
      send(store, {:reply, :unknown})

      assert {:ok, %{status: "completed"}} = Task.await(task)
      assert {:ok, [^offer_id]} = Arca.list(recipient, ["data", "inbox"])
      refute_received {:create, _, _}
    end

    test "a recipient who edits the just-landed file before the comparison: a second folder, both kept",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")

      Store.arm(self(), [:create])
      task = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, store, _path}, 5_000
      send(store, {:reply, :unknown_hold})
      assert_receive {:held, ^store, _path}, 5_000
      :ok = Arca.put(recipient, ["data", "inbox", offer_id, "file.txt"], "edited")
      send(store, :release)
      assert_receive {:create, store2, ["data", "inbox", second, "file.txt"]}, 5_000
      send(store2, {:reply, :proceed})

      assert {:ok, %{status: "completed"}} = Task.await(task)
      assert second == offer_id <> "-2"
      assert {:ok, "edited"} = Arca.get(recipient, ["data", "inbox", offer_id, "file.txt"])
      assert {:ok, bytes(20)} == Arca.get(recipient, ["data", "inbox", second, "file.txt"])
    end

    test "the recipient filling the cap between acceptance and publication waits, then publishes",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      Caps.ceiling(recipient.athanor_id, 100)
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      filler!(recipient, 70, "full.bin")

      assert {:error, {:limit_reached, :athanor_storage_bytes, 100}} =
               FileOffers.complete(recipient, receipt.id)

      assert %{status: "received", attempt_state: "chosen", ever_issued: false} = row!(receipt.id)
      assert {:ok, _} = Arca.get(recipient, custody_of(receipt))

      :ok = Arca.delete(recipient, ["data", "full.bin"])
      assert {:ok, %{status: "completed"}} = FileOffers.complete(recipient, receipt.id)
    end

    test "space that never frees: failed after file_receipt_days, the copy released",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      Caps.ceiling(recipient.athanor_id, 100)
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      filler!(recipient, 70, "full.bin")
      age_receipt!(receipt.id, 10 * 86_400)

      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert %{status: "failed", ever_issued: false} = row!(receipt.id)
      assert {:error, :not_found} = Arca.get(recipient, custody_of(receipt))
      assert {:ok, ["full.bin"]} = Arca.list(recipient, ["data"])
    end

    test "a receipt past file_receipt_days with a write ever sent is kept and reconciled, never failed",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      Caps.ceiling(recipient.athanor_id, 100)
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      issued!(receipt.id, "data/inbox/#{offer_id}/file.txt")
      filler!(recipient, 70, "full.bin")
      age_receipt!(receipt.id, 10 * 86_400)

      # The re-issue is refused space: the receipt waits, whatever its age.
      assert {:ok, 0} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert %{status: "received", ever_issued: true} = row!(receipt.id)
      assert {:ok, _} = Arca.get(recipient, custody_of(receipt))
    end

    test "a create sent to path 1 lands late after a takeover chose path 2: never failed, published at path 1",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      Caps.ceiling(recipient.athanor_id, 100)
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      first = ["data", "inbox", offer_id, "file.txt"]

      # The first completer sends its create to path 1 and is left in flight.
      Store.arm(self(), [:create])
      stale = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, in_flight, ^first}, 5_000
      Store.reset()

      # Other content lands at path 1, the claim lapses, and a takeover
      # records path 2 and is refused space.
      :ok = Arca.put(recipient, first, "someone-else")
      expire_claim!(receipt.id)
      filler!(recipient, 50, "full.bin")

      assert {:error, {:limit_reached, _, _}} = FileOffers.complete(recipient, receipt.id)

      assert %{
               attempt_path: chosen,
               attempt_state: "chosen",
               issued_paths: issued,
               ever_issued: true
             } =
               row!(receipt.id)

      assert chosen == "data/inbox/#{offer_id}-2/file.txt"
      assert Jason.decode!(issued) == ["data/inbox/#{offer_id}/file.txt"]

      # The age passes, the intervening file is removed, and the first
      # create lands late at path 1.
      age_receipt!(receipt.id, 10 * 86_400)
      :ok = Arca.delete(recipient, first)
      send(in_flight, {:reply, :proceed})
      assert {:error, :claim_lost} = Task.await(stale)

      assert {:ok, _} = Arca.get(recipient, custody_of(receipt))
      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)

      assert %{status: "completed", attempt_path: landed} = row!(receipt.id)
      assert landed == "data/inbox/#{offer_id}/file.txt"
      assert {:ok, bytes(20)} == Arca.get(recipient, first)
      assert {:ok, []} = Arca.list(recipient, ["data", "inbox", offer_id <> "-2"])
      assert {:error, :not_found} = Arca.get(recipient, custody_of(receipt))
    end
  end

  # ---------------------------------------------------------------------------
  # Ownership of a publication
  # ---------------------------------------------------------------------------

  describe "the claim" do
    test "a stale completer cannot publish or release another claimant's custody",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      path = ["data", "inbox", offer_id, "file.txt"]

      # A live claimant sends its create and is paused past its lease.
      Store.arm(self(), [:create])
      stale = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, first, ^path}, 5_000
      expire_claim!(receipt.id)

      # A successor takes over: the create is not there yet, so it sends
      # the same create, which is held before it lands.
      successor = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, second, ^path}, 5_000

      # The first's write lands, and it is held before it answers.
      send(first, {:reply, :write_hold})
      assert_receive {:held, ^first, ^path}, 5_000

      # The successor's create answers exists, the digest matches: one
      # folder, published once, and the successor releases the custody.
      send(second, {:reply, :proceed})
      assert {:ok, %{status: "completed", attempt_path: landed}} = Task.await(successor)
      assert landed == Enum.join(path, "/")
      assert {:error, :not_found} = Arca.get(recipient, custody_of(receipt))

      # The first resumes: its next row write is refused and it releases
      # nothing.
      send(first, :release)
      assert {:error, :claim_lost} = Task.await(stale)
      assert %{status: "completed"} = row!(receipt.id)
      assert {:ok, [^offer_id]} = Arca.list(recipient, ["data", "inbox"])
      assert {:ok, bytes(20)} == Arca.get(recipient, path)
    end

    # A completer that recorded its receipt published, or claimed one
    # already published, writes `completed` under its claim before it
    # releases anything: held at its release past its lease, it has
    # already finished, so a successor finds nothing to claim and the copy
    # stands until the completer that recorded `completed` releases it.
    for start <- [:received, :published] do
      test "a completer releases the custody copy only after recording completed (#{start})",
           %{sender: sender, recipient: recipient} do
        offer_id = offered!(sender, recipient, "file.txt", bytes(20))
        receipt = stalled_accept!(recipient, offer_id, "data/inbox")
        path = ["data", "inbox", offer_id, "file.txt"]
        custody = custody_of(receipt)

        if unquote(start) == :published do
          :ok = Arca.put(recipient, path, bytes(20))
          issued!(receipt.id, Enum.join(path, "/"))
          set_receipt!(receipt.id, status: "published")
        end

        Store.arm(self(), [:release])
        first = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
        first_pid = first.pid
        assert_receive {:release, ^first_pid, ^custody}, 5_000

        assert %{status: "completed", completing_by: token} = row!(receipt.id)
        assert is_binary(token)
        expire_claim!(receipt.id)

        successor = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
        assert {:ok, %{status: "completed"}} = Task.await(successor)
        assert %{completing_by: ^token} = row!(receipt.id)
        assert {:ok, bytes(20)} == Arca.get(recipient, custody)

        send(first_pid, {:reply, :proceed})
        assert {:ok, %{status: "completed"}} = Task.await(first)
        assert_published_once(recipient, receipt, offer_id)
      end
    end

    test "a claimant dying mid-publication: the claim expires and the sweep resumes at the recorded path",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")

      Store.arm(self(), [:create])
      {pid, ref} = spawn_monitor(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, ^pid, _path}, 5_000
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      Store.reset()

      # Its claim still stands: a completer now is busy.
      assert {:error, :busy} = FileOffers.complete(recipient, receipt.id)

      expire_claim!(receipt.id)
      assert {:ok, 1} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert_published_once(recipient, receipt, offer_id)
    end

    test "expiry cleanup racing an in-flight publication never releases the copy before published",
         %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(20))
      receipt = stalled_accept!(recipient, offer_id, "data/inbox")
      age_receipt!(receipt.id, 10 * 86_400)

      Store.arm(self(), [:create])
      in_flight = Task.async(fn -> FileOffers.complete(recipient, receipt.id) end)
      assert_receive {:create, store, _path}, 5_000

      # The sweep finds the claim live and a write sent: it fails nothing
      # and releases nothing.
      assert {:ok, 0} = Arca.Retention.FileReceipts.prune(sweeper(recipient), 7, false)
      assert {:ok, _} = Arca.get(recipient, custody_of(receipt))

      send(store, {:reply, :proceed})
      assert {:ok, %{status: "completed"}} = Task.await(in_flight)
      assert_published_once(recipient, receipt, offer_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Ending offers
  # ---------------------------------------------------------------------------

  describe "decline, withdraw and expire" do
    test "a withdrawal after acceptance is refused and the copy stands", %{
      sender: sender,
      recipient: recipient
    } do
      offer_id = offered!(sender, recipient, "file.txt", bytes(5))
      assert {:ok, _} = FileOffers.accept(recipient, offer_id, "data/inbox")

      assert {:error, {:not_offered, "accepted"}} = FileOffers.withdraw(sender, offer_id)
      assert {:error, {:not_offered, "accepted"}} = FileOffers.decline(recipient, offer_id)
      assert {:ok, _} = Arca.get(recipient, ["data", "inbox", offer_id, "file.txt"])
    end

    test "only the sender withdraws and only the recipient declines", %{
      sender: sender,
      recipient: recipient,
      stranger: stranger
    } do
      offer_id = offered!(sender, recipient, "file.txt", bytes(5))

      assert {:error, :not_found} = FileOffers.withdraw(recipient, offer_id)
      assert {:error, :not_found} = FileOffers.decline(sender, offer_id)
      assert {:error, :not_found} = FileOffers.decline(stranger, offer_id)
      assert [%{status: "offered"}] = offer_rows(offer_id)
    end

    test "an expired offer's snapshot is released once", %{sender: sender, recipient: recipient} do
      offer_id = offered!(sender, recipient, "file.txt", bytes(5))
      age_offer!(offer_id, -60)

      assert {:ok, 1} = FileOffers.expire(sender)
      assert_receive {:offer_event, [:cyfr, :arca, :file_offer, :expired], %{offer_id: ^offer_id}}
      assert {:error, :not_found} = Arca.get(sender, ["payloads", "offers", offer_id, "file.txt"])

      assert {:ok, 0} = FileOffers.expire(sender)
      refute_receive {:offer_event, [:cyfr, :arca, :file_offer, :expired], _}, 50
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp person(user_id, athanor_id),
    do: %Prima.Actor{athanor_id: athanor_id, user_id: user_id, authenticated: true}

  defp seat_actor(group), do: %{Prima.Actor.system() | athanor_id: group.id, scope: :athanor}

  defp group!(n) do
    {:ok, athanor} =
      Arca.Athanors.insert(Prima.Actor.system(), %{
        kind: "group",
        name: "Offers #{n}",
        slug: "offers-#{n}",
        created_by: "system"
      })

    athanor
  end

  # The retention sweep's actor for the athanor: the server's own, narrowed.
  defp sweeper(who), do: %{Prima.Actor.system() | athanor_id: who.athanor_id, scope: :athanor}

  defp bytes(n), do: :binary.copy("t", n)

  defp source!(who, name, content), do: :ok = Arca.put(who, ["data", "docs", name], content)

  defp filler!(who, size, name \\ "filler.bin"),
    do: :ok = Arca.put(who, ["data", name], :binary.copy("f", size), cap: :exempt)

  defp offered!(sender, recipient, name, content) do
    source!(sender, name, content)

    {:ok, %{offer_id: offer_id}} =
      FileOffers.offer(sender, recipient.user_id, ["data/docs/#{name}"])

    offer_id
  end

  defp offered_files!(sender, recipient, files) do
    for {name, content} <- files, do: source!(sender, name, content)
    paths = Enum.map(files, fn {name, _content} -> "data/docs/#{name}" end)
    {:ok, %{offer_id: offer_id}} = FileOffers.offer(sender, recipient.user_id, paths)
    offer_id
  end

  # An acceptance whose commit landed and whose publication has not
  # started: the folder probe cannot answer, so the completion the
  # acceptance runs stops before choosing a path.
  defp stalled_accept!(recipient, offer_id, folder) do
    Store.policy(%{list: :fail})

    {:ok, %{receipts: [receipt]}} = FileOffers.accept(recipient, offer_id, folder)

    Store.reset()
    assert %{status: "received", attempt_path: nil, completing_by: nil} = row!(receipt.id)
    receipt
  end

  defp used(who) do
    {:ok, bytes} = Arca.Usage.athanor_bytes(who)
    bytes
  end

  defp custody(offer_id, attempt, filename),
    do: ["payloads", "receipts", offer_id, attempt, filename]

  # Where the acceptance put a receipt's custody copy: the path its row
  # records.
  defp custody_of(%{id: id}), do: String.split(row!(id).custody_path, "/")

  # Every custody copy of an offer in the recipient's tree, whichever
  # acceptance wrote it.
  defp custody_keys(who, offer_id) do
    {:ok, keys} = Arca.Storage.list_prefix(who, ["payloads", "receipts", offer_id])
    keys
  end

  defp row!(id), do: Arca.Repo.get!(FileReceipt, id)

  defp set_receipt!(id, set) do
    {1, _} = Arca.Repo.update_all(Ecto.Query.from(r in FileReceipt, where: r.id == ^id), set: set)
    :ok
  end

  # The row as a completer leaves it when its create was sent to `path`.
  defp issued!(id, path) do
    set_receipt!(id,
      attempt_path: path,
      attempt_state: "issued",
      issued_paths: Jason.encode!([path]),
      ever_issued: true
    )
  end

  defp expire_claim!(id),
    do: set_receipt!(id, completing_until: DateTime.add(DateTime.utc_now(), -60, :second))

  defp age_receipt!(id, seconds),
    do: set_receipt!(id, inserted_at: DateTime.add(DateTime.utc_now(), -seconds, :second))

  defp age_offer!(offer_id, seconds_from_now) do
    {_, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(o in FileOffer, where: o.offer_id == ^offer_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), seconds_from_now, :second)]
      )

    :ok
  end

  defp age_file!(who, path, seconds) do
    full = Arca.Adapters.Local.build_path(who, path)
    then = System.os_time(:second) - seconds
    :ok = File.touch!(full, then)
  end

  # A row of `offer_id` at `filename`, landed ahead of the offer's own.
  defp offer_row!(sender, recipient, offer_id, filename) do
    now = DateTime.utc_now()

    {1, _} =
      Arca.Repo.insert_all(FileOffer, [
        %{
          id: Prima.UUID7.generate_id("fof"),
          athanor_id: sender.athanor_id,
          offer_id: offer_id,
          sender_user_id: sender.user_id,
          recipient_user_id: recipient.user_id,
          filename: filename,
          digest: Prima.Digest.sha256("ahead"),
          size: 5,
          status: "offered",
          expires_at: DateTime.add(now, 86_400, :second),
          inserted_at: now,
          updated_at: now
        }
      ])

    :ok
  end

  defp offer_rows(offer_id),
    do: Arca.Repo.all(Ecto.Query.from(o in FileOffer, where: o.offer_id == ^offer_id))

  defp assert_published_once(recipient, receipt, offer_id) do
    assert %{status: "completed", completing_by: nil} = row!(receipt.id)
    assert {:ok, [^offer_id]} = Arca.list(recipient, ["data", "inbox"])
    assert {:ok, ["file.txt"]} = Arca.list(recipient, ["data", "inbox", offer_id])
    assert {:error, :not_found} = Arca.get(recipient, custody_of(receipt))
  end
end

defmodule Arca.FileOffersRaceTest do
  @moduledoc """
  Two completers of one receipt on connections of their own: the
  acceptance handler's and the sweep's. Inside the sandbox one shared
  connection would serialize the claims the case is about.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.FileOffers
  alias Arca.FileOffersTest.Store
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    no_claimant!()
    previous_adapter = Application.get_env(:arca, :storage_adapter)
    Application.put_env(:arca, :storage_adapter, Store)

    n = System.unique_integer([:positive])
    sender = %Prima.Actor{athanor_id: "ath_for_s#{n}", user_id: "usr_for_s#{n}"}
    recipient = %Prima.Actor{athanor_id: "ath_for_r#{n}", user_id: "usr_for_r#{n}"}

    group =
      unboxed(fn ->
        {:ok, group} =
          Arca.Athanors.insert(Prima.Actor.system(), %{
            kind: "group",
            name: "Race #{n}",
            slug: "offers-race-#{n}",
            created_by: "system"
          })

        seat = %{Prima.Actor.system() | athanor_id: group.id, scope: :athanor}

        for who <- [sender, recipient] do
          {:ok, _} = Arca.Members.seat(seat, %{user_id: who.user_id, added_by: "test"})
        end

        group
      end)

    on_exit(fn ->
      Store.reset()

      if previous_adapter,
        do: Application.put_env(:arca, :storage_adapter, previous_adapter),
        else: Application.delete_env(:arca, :storage_adapter)

      unboxed(fn ->
        for id <- [sender.athanor_id, recipient.athanor_id, group.id] do
          {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(id))
        end

        Arca.Repo.delete_all(Ecto.Query.from(a in Arca.Schemas.Athanor, where: a.id == ^group.id))
      end)

      for who <- [sender, recipient] do
        File.rm_rf(Arca.Adapters.Local.build_path(Prima.Actor.in_athanor(who.athanor_id), []))
      end
    end)

    {:ok, sender: sender, recipient: recipient}
  end

  # An acceptance is fenced by this member's slot. No claimant runs in a
  # test, under the umbrella's configuration or this app's alone, so none
  # is held and none is asked for; the switch is restored after each case.
  defp no_claimant! do
    claim = Application.get_env(:arca, :control_plane_claim_enabled)
    Application.put_env(:arca, :control_plane_claim_enabled, false)

    on_exit(fn ->
      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)
  end

  test "the acceptance handler's complete racing the sweep's: one publishes, the other is busy",
       %{sender: sender, recipient: recipient} do
    receipt =
      unboxed(fn ->
        :ok = Arca.put(sender, ["data", "docs", "file.txt"], "racing-bytes")

        {:ok, %{offer_id: offer_id}} =
          FileOffers.offer(sender, recipient.user_id, ["data/docs/file.txt"])

        Store.policy(%{list: :fail})
        {:ok, %{receipts: [receipt]}} = FileOffers.accept(recipient, offer_id, "data/inbox")
        Store.reset()
        receipt
      end)

    sweeper = %{Prima.Actor.system() | athanor_id: recipient.athanor_id, scope: :athanor}

    # Whichever claims first is held at its create; the other meets the
    # claim.
    Store.arm(self(), [:create])

    tasks =
      for actor <- [recipient, sweeper] do
        Task.async(fn -> unboxed(fn -> FileOffers.complete(actor, receipt.id) end) end)
      end

    assert_receive {:create, held, _path}, 10_000
    [other] = Enum.reject(tasks, &(&1.pid == held))
    [holder] = Enum.filter(tasks, &(&1.pid == held))

    assert {:error, :busy} = Task.await(other, 10_000)

    send(held, {:reply, :proceed})
    assert {:ok, %{status: "completed"}} = Task.await(holder, 10_000)

    unboxed(fn ->
      assert {:ok, [folder]} = Arca.list(recipient, ["data", "inbox"])
      assert folder == receipt.offer_id
      assert {:ok, "racing-bytes"} = Arca.get(recipient, ["data", "inbox", folder, "file.txt"])
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Arca.Repo, fun)
end
