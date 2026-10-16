# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.NotesTest do
  # The notes domain owns the text rendered for each write outcome.
  use ExUnit.Case, async: true

  alias Aqua.Notes

  test "describe/1 has one sentence per outcome the writes can answer with" do
    assert Notes.describe(%{kept: "flight", athanor_id: "ath_1", replaced: false}) ==
             "📝 Kept a note: flight"

    assert Notes.describe(%{kept: "flight", athanor_id: "ath_1", replaced: true}) ==
             "📝 Replaced the note: flight"

    assert Notes.describe(%{pinned: "about-us", athanor_id: "ath_1"}) == "📝 Pinned about-us"
    assert Notes.describe(%{cleared: "about-us", athanor_id: "ath_1"}) == "📝 Cleared about-us"
    assert Notes.describe(%{forgot: "flight", athanor_id: "ath_1"}) == "📝 Forgot the note: flight"
  end

  test "describe/1 reads either key spelling — an answer may have crossed the wire" do
    assert Notes.describe(%{"kept" => "flight", "replaced" => true}) ==
             "📝 Replaced the note: flight"

    assert Notes.describe(%{"forgot" => "flight"}) == "📝 Forgot the note: flight"
  end

  test "describe/1 is nil for anything that is not a write's answer" do
    assert is_nil(Notes.describe(%{name: "flight", content: "BA117"}))
    assert is_nil(Notes.describe(%{"status" => "ok"}))
    assert is_nil(Notes.describe(:ok))
    assert is_nil(Notes.describe(nil))
  end
end

defmodule Aqua.NotesTest.Interleave do
  @moduledoc false
  # A storage cap that runs, once, what the test planted in the asking
  # process before it answers. `Arca.Storage.stage/3` asks it between a
  # note's read and its publication, so what is planted lands exactly in
  # that window.
  @behaviour Prima.Caps

  @impl Prima.Caps
  def check_counted(%Prima.Actor{}, _key, _count), do: :ok

  @impl Prima.Caps
  def check_storage(%Prima.Actor{}, _incoming) do
    case Process.delete(__MODULE__) do
      nil -> :ok
      between -> between.()
    end

    :ok
  end

  @doc false
  def plant(between) when is_function(between, 0), do: Process.put(__MODULE__, between)
end

defmodule Aqua.NotesStoreTest do
  @moduledoc """
  Every note is a fenced document (`Arca.FencedPublication`) keyed
  `notes/<name>.md`: a write publishes under this member's live ownership
  of its slot and the revision it read, so a slot taken over or run out
  between the read and the publication, or a store that cannot answer at
  the publication, writes nothing and serves nothing new; a note written
  since the read is a conflict, never overwritten.
  """

  # Takes a member slot through `Arca.ControlPlane`, which writes the
  # process-wide standing, and installs a storage cap: both restored.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Notes
  alias Aqua.NotesTest.Interleave
  alias Arca.Schemas.CellLease

  @standing [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    base = Path.join(System.tmp_dir!(), "notes_store_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)
    saved = Map.new(@standing, &{&1, :persistent_term.get(&1, :absent)})
    installed = Prima.Caps.impl!()
    Prima.Caps.install!(Interleave)

    on_exit(fn ->
      Prima.Caps.install!(installed)

      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      File.rm_rf!(base)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    n = System.unique_integer([:positive])
    user = "local|idp|notes-#{n}"
    {:ok, athanor} = Sanctum.Tenancy.Athanors.create_group(user, "Notes #{n}")
    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: athanor.id}
    {:ok, ctx: ctx, actor: Sanctum.Context.actor(ctx)}
  end

  test "a note is a document keyed notes/<name>.md, its bytes staged, read back through it", %{
    ctx: ctx,
    actor: actor
  } do
    member!()
    assert {:ok, %{kept: "flight", replaced: false}} = Notes.keep(ctx, "flight", "BA117")
    assert {:ok, %{kept: "flight", replaced: true}} = Notes.keep(ctx, "flight", "BA118")

    assert %{revision: 2, blob_key: "staging/" <> _} =
             Arca.FencedPublication.document(actor, "notes/flight.md")

    # Nothing lands under the storage root of the same name.
    refute Arca.exists?(actor, ["notes", "flight"])
    assert {:ok, %{content: "BA118"}} = Notes.read(ctx, "flight")
    assert {:ok, %{notes: [%{name: "flight"}]}} = Notes.list(ctx)
    assert {:ok, %{entries: [%{name: "flight", line: "BA118"}]}} = Notes.index(ctx)

    assert {:ok, %{forgot: "flight"}} = Notes.forget(ctx, "flight")
    assert :not_found = Arca.FencedPublication.document(actor, "notes/flight.md")
    assert {:error, {:not_found, "note", "flight"}} = Notes.read(ctx, "flight")
    assert {:error, {:not_found, "note", "flight"}} = Notes.forget(ctx, "flight")
  end

  test "the pinned page is a note too: set, then cleared by pinning nothing", %{
    ctx: ctx,
    actor: actor
  } do
    member!()
    assert {:ok, %{pinned: "about-us"}} = Notes.pin(ctx, "about-us", "We plan a trip.")
    assert {:ok, %{content: "We plan a trip."}} = Notes.pinned(ctx)
    assert %{revision: 1} = Arca.FencedPublication.document(actor, "notes/about-us.md")

    assert {:ok, %{cleared: "about-us"}} = Notes.pin(ctx, "about-us", "")
    assert :none = Notes.pinned(ctx)
    assert {:ok, %{cleared: "about-us"}} = Notes.pin(ctx, "about-us", "")
  end

  describe "the member's ownership" do
    test "a slot taken over between the read and the publication publishes nothing, and nothing new is served",
         %{ctx: ctx, actor: actor} do
      slot = member!()
      assert {:ok, _} = Notes.keep(ctx, "plan", "v1")

      # The lease row is replaced after `keep` read the note's revision and
      # before it publishes.
      Interleave.plant(fn -> take_over!(slot) end)
      assert {:error, {:unavailable, "Notes"}} = Notes.keep(ctx, "plan", "v2")

      assert %{revision: 1} = Arca.FencedPublication.document(actor, "notes/plan.md")
      assert {:ok, %{content: "v1"}} = Notes.read(ctx, "plan")
      assert {:error, {:unavailable, "Notes"}} = Notes.forget(ctx, "plan")
      assert {:ok, %{content: "v1"}} = Notes.read(ctx, "plan")
    end

    test "a new note under a slot taken over is not created", %{ctx: ctx, actor: actor} do
      slot = member!()
      Interleave.plant(fn -> take_over!(slot) end)

      assert {:error, {:unavailable, "Notes"}} = Notes.keep(ctx, "fresh", "v1")
      assert :not_found = Arca.FencedPublication.document(actor, "notes/fresh.md")
      assert {:ok, %{notes: []}} = Notes.list(ctx)
    end

    test "a slot that ran out with no successor publishes nothing", %{ctx: ctx, actor: actor} do
      slot = member!()
      Interleave.plant(fn -> expire!(slot) end)

      assert {:error, {:unavailable, "Notes"}} = Notes.keep(ctx, "plan", "v1")
      assert :not_found = Arca.FencedPublication.document(actor, "notes/plan.md")
    end

    test "a member that holds no slot where a claimant runs stages and publishes nothing", %{
      ctx: ctx
    } do
      Arca.ControlPlane.record(:lost)
      assert {:error, {:unavailable, "Notes"}} = Notes.keep(ctx, "plan", "v1")
      assert {:ok, %{notes: []}} = Notes.list(ctx)
    end

    test "a store that cannot answer at the publication publishes nothing", %{
      ctx: ctx,
      actor: actor
    } do
      member!()
      assert {:ok, _} = Notes.keep(ctx, "plan", "v1")

      # The lease row's table goes after the read: the publication's own
      # ownership check is the statement that cannot be answered.
      Interleave.plant(fn -> Arca.Repo.query!("DROP TABLE cell_leases") end)
      assert {:error, {:unavailable, "Notes"}} = Notes.keep(ctx, "plan", "v2")

      assert %{revision: 1} = Arca.FencedPublication.document(actor, "notes/plan.md")
      assert {:ok, %{content: "v1"}} = Notes.read(ctx, "plan")
    end
  end

  describe "the revision read" do
    test "a note written since the read is a conflict, and is kept as it was written", %{
      ctx: ctx
    } do
      member!()
      assert {:ok, %{revision: 0, note: nil}} = Notes.current(ctx, "plan")
      assert {:ok, _} = Notes.keep(ctx, "plan", "the person's")

      assert {:error, {:conflict, _}} = Notes.keep_over(ctx, "plan", "the background's", 0)
      assert {:ok, %{content: "the person's"}} = Notes.read(ctx, "plan")

      assert {:ok, %{revision: 1, note: %{content: "the person's"}}} =
               Notes.current(ctx, "plan")

      assert {:ok, %{replaced: true}} = Notes.keep_over(ctx, "plan", "read again", 1)
      assert {:ok, %{content: "read again"}} = Notes.read(ctx, "plan")
    end

    test "a revision read from a forgotten note does not publish over the note kept again since",
         %{ctx: ctx} do
      member!()
      assert {:ok, _} = Notes.keep(ctx, "plan", "old")
      assert {:ok, %{revision: 1, note: %{content: "old"}}} = Notes.current(ctx, "plan")
      assert {:ok, %{forgot: "plan"}} = Notes.forget(ctx, "plan")
      assert {:ok, _} = Notes.keep(ctx, "plan", "new")

      # A writer that read revision 1 before the forget publishes now.
      result = Notes.keep_over(ctx, "plan", "stale", 1)
      content = Notes.read(ctx, "plan")

      assert {:error, {:conflict, _}} = result,
             "keep_over answered #{inspect(result)}; the note reads #{inspect(content)}"

      assert {:ok, %{content: "new"}} = content
      assert {:ok, %{revision: revision, note: %{content: "new"}}} = Notes.current(ctx, "plan")
      assert revision > 1
    end

    test "a keep racing another keep of the same name is a conflict, not a silent overwrite", %{
      ctx: ctx
    } do
      member!()
      Interleave.plant(fn -> {:ok, _} = Notes.keep(ctx, "plan", "first") end)

      assert {:error, {:conflict, _}} = Notes.keep(ctx, "plan", "second")
      assert {:ok, %{content: "first"}} = Notes.read(ctx, "plan")
    end
  end

  describe "outside material" do
    test "a note kept with sources answers them on every read until a person endorses it", %{
      ctx: ctx
    } do
      member!()
      host = Prima.Source.outside("news.example")
      assert {:ok, _} = Notes.keep(ctx, "clip", "Fares rise on Monday", sources: [host])

      assert {:ok, %{sources: [^host]}} = read = Notes.read(ctx, "clip")
      assert Notes.sources_of_answer(read) == [host]
      assert {:ok, %{entries: [%{name: "clip", sources: [^host]}]}} = Notes.index(ctx)
      assert {:ok, %{notes: [%{sources: [^host]}]} = found} = Notes.search(ctx, "fares")
      assert Notes.sources_of_answer({:ok, %{matches: found.notes}}) == [host]

      # The card must name exactly what the note carries.
      assert {:error, {:conflict, _}} =
               Notes.endorse(ctx, "clip", [Prima.Source.outside("other.example")])

      assert {:error, {:conflict, _}} = Notes.endorse(ctx, "clip", [])
      assert {:ok, %{sources: [^host]}} = Notes.read(ctx, "clip")

      assert {:ok, %{endorsed: "clip"}} =
               Notes.endorse(ctx, "clip", Prima.Source.to_json_list([host]))

      assert {:ok, %{content: "Fares rise on Monday", sources: [], kept_by: kept_by}} =
               Notes.read(ctx, "clip")

      assert kept_by == ctx.user_id
      assert {:error, {:invalid_argument, _}} = Notes.endorse(ctx, "clip", [host])
      assert {:error, {:invalid_argument, _}} = Notes.endorse(ctx, "about-us", [host])
      assert {:error, {:not_found, "note", "gone"}} = Notes.endorse(ctx, "gone", [host])
    end

    test "an endorsement never writes over a note corrected since its read", %{ctx: ctx} do
      member!()
      host = Prima.Source.outside("news.example")
      assert {:ok, _} = Notes.keep(ctx, "clip", "Fares rise", sources: [host])

      Interleave.plant(fn ->
        {:ok, _} = Notes.keep_over(ctx, "clip", "Fares fall, corrected", 1)
      end)

      assert {:error, {:conflict, _}} = Notes.endorse(ctx, "clip", [host])
      assert {:ok, %{content: "Fares fall, corrected", sources: []}} = Notes.read(ctx, "clip")
    end

    test "a keep in a chain that read outside material is marked, whatever allowed it; a pin is not",
         %{ctx: ctx, actor: actor} do
      member!()
      host = Prima.Source.outside("news.example")
      {thread, root} = chain!(ctx, actor, [Prima.Source.new(:filed), host])

      # A standing allow naming the source covers the keep; it admits the
      # action and endorses nothing.
      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "thread",
          effect: "allow",
          thread_id: thread,
          agent_name: "aqua",
          tool: "notes",
          action: "keep",
          sources: [host]
        })

      guest = Sanctum.Context.enter_guest(ctx)
      lineage = %{"root_execution_id" => root, "thread_id" => thread}

      assert {:ok, %{kept: "clip"}} =
               Aqua.Providers.Notes.handle(
                 "notes",
                 guest,
                 Map.merge(lineage, %{"action" => "keep", "name" => "clip", "content" => "x"})
               )

      assert {:ok, %{sources: [%Prima.Source{class: :filed}, ^host], thread: ^thread}} =
               Notes.read(ctx, "clip")

      assert {:ok, %{pinned: "about-us"}} =
               Aqua.Providers.Notes.handle(
                 "notes",
                 guest,
                 Map.merge(lineage, %{"action" => "pin", "name" => "about-us", "content" => "y"})
               )

      assert {:ok, %{sources: []}} = Notes.pinned(ctx)

      # The same keep at the door, and one from a chain that read only the
      # athanor's own material, carry none.
      assert {:ok, _} =
               Aqua.Providers.Notes.handle("notes", ctx, %{
                 "action" => "keep",
                 "name" => "door",
                 "content" => "z"
               })

      assert {:ok, %{sources: []}} = Notes.read(ctx, "door")
      {_thread, own} = chain!(ctx, actor, [Prima.Source.new(:filed)])

      assert {:ok, _} =
               Aqua.Providers.Notes.handle("notes", guest, %{
                 "action" => "keep",
                 "name" => "own",
                 "content" => "w",
                 "root_execution_id" => own
               })

      assert {:ok, %{sources: []}} = Notes.read(ctx, "own")
    end
  end

  # ---- helpers ---------------------------------------------------------------

  # A turn of a thread of this athanor running on its own root execution,
  # having read `sources`: written straight to its row, as the loop's step
  # writes leave it.
  defp chain!(ctx, actor, sources) do
    actor = Map.put(actor, :user_id, ctx.user_id)
    {:ok, thread} = Arca.ThreadStorage.create(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, content: "go"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    root = "exec_notes_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: root, sources: Prima.Source.encode(sources)]
      )

    {thread.id, root}
  end

  # This member's slot, taken and recorded as the claimant takes it.
  defp member! do
    node = "node-notes-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  defp take_over!(%{node: node, generation: generation, fence: fence}) do
    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
        set: [owner: node <> "#boot_b", generation: generation + 1, fence: fence + 1]
      )

    :ok
  end

  defp expire!(%{node: node}) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^node),
        set: [lease_until: past]
      )

    :ok
  end
end
