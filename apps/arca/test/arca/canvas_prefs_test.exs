# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.CanvasPrefsTest do
  @moduledoc """
  The preferences documents: one per person per canvas in the actor's
  athanor, written by merging what a desktop sends over the stored
  document at the revision the writer read, and read back as stored. A
  writer at an older revision, or one that loses to a racing writer,
  merges nothing and is answered the current document projected to its
  schema; an incoming document the schema refuses, a merge over the cap
  and a member that lost its slot write nothing; bytes that no longer
  hold their digest read as corrupt.
  """

  # Takes a slot through `Arca.ControlPlane`, which writes the process-wide
  # standing record, and one case swaps the storage adapter; each value is
  # restored after the case, registered before it changes.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.CanvasPrefs
  alias Arca.ControlPlane
  alias Arca.PublicationContract.Faults
  alias Arca.Schemas.{CellLease, FencedDocument, StorageStaging}

  @slot_keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  @canvas "home"

  @prefs %{
    "widgets" => %{
      "weather" => %{
        "fields" => %{
          "units" => %{"type" => "enum", "values" => ["c", "f"]},
          "city" => %{"type" => "string", "max" => 32}
        }
      },
      "clock" => %{"fields" => %{"seconds" => %{"type" => "boolean"}}}
    },
    "desktop" => %{"fields" => %{"compact" => %{"type" => "boolean"}}}
  }

  setup tags do
    Arca.Test.Sandbox.setup!(tags)
    athanor = "ath_prf_#{System.unique_integer([:positive])}"
    {:ok, actor: Arca.Test.Actor.local(athanor_id: athanor), user: "usr_prf", slot: hold_slot!()}
  end

  # A claimant runs, and this member holds its slot.
  defp hold_slot! do
    for key <- @slot_keys, do: Prima.Test.Env.erase_persistent_term(key)
    Prima.Test.Env.put_app_env(:arca, :control_plane_claim_enabled, true)
    node = "node-prf-#{System.unique_integer([:positive])}"
    {:ok, slot} = ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  defp schema(prefs \\ @prefs) do
    {:ok, declaration} =
      Prima.Manifest.Tincture.from_manifest(%{"tincture" => %{"desktop" => %{"prefs" => prefs}}})

    declaration.desktop.prefs
  end

  defp widget(id, entry), do: %{"widgets" => %{id => entry}}

  defp write(actor, user, incoming, revision_read, schema \\ schema()),
    do: CanvasPrefs.write(actor, user, @canvas, incoming, schema, revision_read)

  defp row_query(actor, user) do
    key = CanvasPrefs.key(user, @canvas)
    from(d in FencedDocument, where: d.athanor_id == ^actor.athanor_id and d.key == ^key)
  end

  # Every attempt a refused write staged has its reservation ended.
  defp assert_no_live_reservation(actor) do
    now = Arca.ServerMetaStorage.now!()

    reserved =
      Arca.Repo.all(
        from(s in StorageStaging,
          where: s.athanor_id == ^actor.athanor_id and s.state == "reserved"
        )
      )

    assert Enum.all?(reserved, &(DateTime.compare(&1.expires_at, now) != :gt))
  end

  test "preferences never written are not found, under a key naming the person and the canvas",
       %{actor: actor, user: user} do
    assert {:error, :not_found} = CanvasPrefs.get(actor, user, @canvas)
    assert CanvasPrefs.key(user, @canvas) == "prefs/usr_prf/home"
  end

  test "a write reads back as the merged document, its revision and its digest", %{
    actor: actor,
    user: user
  } do
    incoming = widget("weather", %{"on" => true, "units" => "f"})

    assert {:ok, %{document: merged, revision: 1}} = write(actor, user, incoming, 0)
    assert merged == %{"widgets" => incoming["widgets"], "desktop" => %{}}

    assert {:ok, %{document: ^merged, revision: 1, digest: digest}} =
             CanvasPrefs.get(actor, user, @canvas)

    assert digest == Prima.CanvasPrefs.digest(merged)
  end

  test "each widget entry a write names replaces the stored one whole, and the rest stay", %{
    actor: actor,
    user: user
  } do
    first = %{
      "widgets" => %{
        "weather" => %{"on" => true, "units" => "c"},
        "clock" => %{"on" => true, "seconds" => true}
      },
      "desktop" => %{"compact" => true}
    }

    {:ok, %{revision: 1}} = write(actor, user, first, 0)
    {:ok, %{revision: 2}} = write(actor, user, widget("weather", %{"city" => "Oslo"}), 1)

    assert {:ok, %{revision: 2, document: document}} = CanvasPrefs.get(actor, user, @canvas)

    assert document == %{
             "widgets" => %{
               "weather" => %{"city" => "Oslo"},
               "clock" => %{"on" => true, "seconds" => true}
             },
             "desktop" => %{"compact" => true}
           }

    {:ok, %{revision: 3, document: cleared}} = write(actor, user, %{"desktop" => %{}}, 2)
    assert cleared == %{document | "desktop" => %{}}
  end

  test "a write at an older revision is answered the current document and merges nothing", %{
    actor: actor,
    user: user
  } do
    {:ok, %{revision: 1, document: current}} =
      write(actor, user, widget("weather", %{"units" => "c"}), 0)

    for revision_read <- [0, 2, 7] do
      assert {:error, {:stale, %{document: ^current, revision: 1}}} =
               write(actor, user, widget("clock", %{"on" => true}), revision_read)
    end

    assert {:ok, %{revision: 1, document: ^current}} = CanvasPrefs.get(actor, user, @canvas)

    # The current document is answered as the writer's schema reads it.
    narrowed = put_in(@prefs, ["widgets", "weather", "fields", "units", "values"], ["f"])

    assert {:error, {:stale, %{document: projected, revision: 1}}} =
             write(actor, user, widget("clock", %{}), 0, schema(narrowed))

    assert projected == %{"widgets" => %{"weather" => %{}}, "desktop" => %{}}
  end

  test "a writer that loses to a racing one merges nothing and is answered the racer's document",
       %{actor: actor, user: user} do
    {:ok, %{revision: 1}} = write(actor, user, widget("weather", %{"units" => "c"}), 0)

    test_pid = self()
    first = :atomics.new(1, [])
    on_exit(fn -> Faults.unwrap() end)
    Faults.wrap(Arca.Storage.configured_adapter())
    Prima.Test.Env.put_app_env(:arca, :storage_adapter, Faults)

    # The first write to stage its bytes parks there, after it read
    # revision 1 and before it publishes.
    Faults.inject(fn op, _path ->
      if op in [:put, :put_if_none_match] and :atomics.compare_exchange(first, 1, 0, 1) == :ok do
        send(test_pid, {:parked, self()})

        receive do
          :proceed -> :pass
        after
          30_000 -> :pass
        end
      else
        :pass
      end
    end)

    slow = Task.async(fn -> write(actor, user, widget("clock", %{"on" => true}), 1) end)
    assert_receive {:parked, writer}, 10_000

    assert {:ok, %{revision: 2, document: racer}} =
             write(actor, user, widget("weather", %{"units" => "f"}), 1)

    send(writer, :proceed)

    assert {:error, {:stale, %{document: ^racer, revision: 2}}} = Task.await(slow, 30_000)
    assert {:ok, %{revision: 2, document: ^racer}} = CanvasPrefs.get(actor, user, @canvas)
    refute Map.has_key?(racer["widgets"], "clock")
    assert_no_live_reservation(actor)
  end

  test "an incoming document the schema refuses writes nothing", %{actor: actor, user: user} do
    {:ok, %{revision: 1, document: stored}} =
      write(actor, user, widget("weather", %{"units" => "c"}), 0)

    for incoming <- [
          widget("weather", %{"units" => "k"}),
          widget("radar", %{}),
          %{"widgets" => %{}, "layout" => %{}},
          %{}
        ] do
      assert {:error, {:invalid, sentence}} = write(actor, user, incoming, 1)
      assert is_binary(sentence)
    end

    assert {:ok, %{revision: 1, document: ^stored}} = CanvasPrefs.get(actor, user, @canvas)
  end

  test "a merge whose bytes exceed the cap writes nothing", %{actor: actor, user: user} do
    fields = Map.new(1..16, &{"f#{&1}", %{"type" => "string", "max" => 256}})
    wide = schema(%{"widgets" => Map.new(1..4, &{"w#{&1}", %{"fields" => fields}})})
    entry = Map.new(1..16, &{"f#{&1}", String.duplicate("a", 256)})

    # Three full widgets fit; a fourth, small enough alone, does not fit
    # beside them.
    three = %{"widgets" => Map.new(1..3, &{"w#{&1}", entry})}
    assert {:ok, %{revision: 1, document: stored}} = write(actor, user, three, 0, wide)
    assert byte_size(Prima.CanvasPrefs.encode(stored)) <= Prima.CanvasPrefs.max_bytes()

    assert {:error, :too_large} = write(actor, user, widget("w4", entry), 1, wide)
    assert {:ok, %{revision: 1, document: ^stored}} = CanvasPrefs.get(actor, user, @canvas)
  end

  test "each person and canvas has its own preferences, and each athanor its own", %{
    actor: actor,
    user: user
  } do
    {:ok, %{revision: 1}} = write(actor, user, widget("clock", %{"on" => true}), 0)

    assert {:error, :not_found} = CanvasPrefs.get(actor, "usr_someone_else", @canvas)
    assert {:error, :not_found} = CanvasPrefs.get(actor, user, "work")

    elsewhere =
      Arca.Test.Actor.local(athanor_id: "ath_prf_other_#{System.unique_integer([:positive])}")

    assert {:error, :not_found} = CanvasPrefs.get(elsewhere, user, @canvas)

    assert {:ok, %{revision: 1, document: %{"widgets" => %{"weather" => _}}}} =
             CanvasPrefs.write(elsewhere, user, @canvas, widget("weather", %{}), schema(), 0)

    assert {:ok, %{document: %{"widgets" => %{"clock" => _}}}} =
             CanvasPrefs.get(actor, user, @canvas)
  end

  test "get answers the document as stored, whatever schema a writer reads it under", %{
    actor: actor,
    user: user
  } do
    {:ok, %{revision: 1, document: stored}} =
      write(actor, user, widget("weather", %{"units" => "c", "city" => "Oslo"}), 0)

    # A later version declares no city: the stored document keeps it until
    # a write under that schema merges over its projection.
    later =
      put_in(@prefs, ["widgets", "weather", "fields"], %{
        "units" => %{"type" => "enum", "values" => ["c"]}
      })

    assert {:ok, %{document: ^stored}} = CanvasPrefs.get(actor, user, @canvas)

    assert {:ok, %{revision: 2, document: merged}} =
             write(actor, user, widget("clock", %{"on" => false}), 1, schema(later))

    assert merged == %{
             "widgets" => %{"weather" => %{"units" => "c"}, "clock" => %{"on" => false}},
             "desktop" => %{}
           }
  end

  test "a member that lost its slot writes nothing", %{actor: actor, user: user, slot: slot} do
    {:ok, %{revision: 1, document: stored}} = write(actor, user, widget("clock", %{}), 0)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: "someone-else", generation: slot.generation + 1]
      )

    assert {:error, :not_owner} = write(actor, user, widget("weather", %{}), 1)
    assert {:ok, %{revision: 1, document: ^stored}} = CanvasPrefs.get(actor, user, @canvas)
    assert_no_live_reservation(actor)
  end

  test "bytes that no longer hold their digest read as corrupt, and no write merges over them",
       %{actor: actor, user: user} do
    {:ok, %{revision: 1}} = write(actor, user, widget("clock", %{}), 0)

    {1, _} =
      Arca.Repo.update_all(row_query(actor, user),
        set: [digest: "sha256:" <> String.duplicate("0", 64)]
      )

    assert {:error, :corrupt} = CanvasPrefs.get(actor, user, @canvas)
    assert {:error, :corrupt} = write(actor, user, widget("weather", %{}), 1)
  end

  test "a person id naming nobody, a canvas id outside its grammar and an actor naming no athanor are refused",
       %{actor: actor, user: user} do
    incoming = widget("clock", %{})

    for bad <- [nil, "", "usr/../x", String.duplicate("u", 200)] do
      assert {:error, :no_person} = CanvasPrefs.get(actor, bad, @canvas)
      assert {:error, :no_person} = CanvasPrefs.write(actor, bad, @canvas, incoming, schema(), 0)
    end

    for bad <- [nil, "", "Home", "a/b", "-home", String.duplicate("h", 33)] do
      assert {:error, :invalid_canvas} = CanvasPrefs.get(actor, user, bad)

      assert {:error, :invalid_canvas} =
               CanvasPrefs.write(actor, user, bad, incoming, schema(), 0)
    end

    assert {:error, :no_athanor} = CanvasPrefs.get(Prima.Actor.system(), user, @canvas)

    assert {:error, :no_athanor} =
             CanvasPrefs.write(Prima.Actor.system(), user, @canvas, incoming, schema(), 0)
  end
end
