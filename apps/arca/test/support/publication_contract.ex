# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PublicationContract.Double do
  @moduledoc false
  # The adapter the contract is first proven on: Local's bytes, the
  # conditional writes, the versioned read and the prefix listing with
  # real preconditions, and no tree swap — an object store's shape.
  use Arca.Storage.TestDouble
end

defmodule Arca.PublicationContract.Faults do
  @moduledoc false
  # The tenant adapter under test, with a fault between the overlay and
  # it. `inject/1` takes a function of the operation and its path, run in
  # the calling process, answering:
  #
  #   * `:pass` — the operation reaches the adapter;
  #   * `{:error, reason}` — it fails and nothing reaches the adapter;
  #   * `:lose` — a write answers `:ok` and stores nothing;
  #   * `{:store, bytes}` — a write answers `:ok` and stores other bytes.
  #
  # The function may also park (wait for the test) or `exit/1` — a writer
  # that died at exactly that operation.
  @behaviour Arca.Storage

  @base {__MODULE__, :base}
  @fault {__MODULE__, :fault}

  def wrap(adapter), do: :persistent_term.put(@base, adapter)
  def inject(fun) when is_function(fun, 2), do: :persistent_term.put(@fault, fun)
  def clear, do: :persistent_term.erase(@fault)

  def unwrap do
    :persistent_term.erase(@base)
    clear()
  end

  defp base, do: :persistent_term.get(@base)

  defp fault(op, path) do
    case :persistent_term.get(@fault, nil) do
      nil -> :pass
      fun -> fun.(op, path)
    end
  end

  defp through(op, path, fun) do
    case fault(op, path) do
      {:error, _} = error -> error
      _pass -> fun.()
    end
  end

  @impl true
  def get(actor, path), do: through(:get, path, fn -> base().get(actor, path) end)

  @impl true
  def put(actor, path, content) do
    case fault(:put, path) do
      :pass -> base().put(actor, path, content)
      :lose -> :ok
      {:store, bytes} -> base().put(actor, path, bytes)
      {:error, _} = error -> error
    end
  end

  @impl true
  def append(actor, path, content),
    do: through(:append, path, fn -> base().append(actor, path, content) end)

  @impl true
  def delete(actor, path), do: through(:delete, path, fn -> base().delete(actor, path) end)

  @impl true
  def delete_tree(actor, path),
    do: through(:delete_tree, path, fn -> base().delete_tree(actor, path) end)

  @impl true
  def list_typed(actor, path), do: base().list_typed(actor, path)

  @impl true
  def exists?(actor, path), do: base().exists?(actor, path)

  @impl true
  def list_recursive(actor, path), do: base().list_recursive(actor, path)

  @impl true
  def usage(actor, path), do: base().usage(actor, path)

  @impl true
  def ensure_dir(actor, path), do: base().ensure_dir(actor, path)

  @impl true
  def serve_to_conn(conn, actor, path, opts), do: base().serve_to_conn(conn, actor, path, opts)

  # The one callback under test an adapter may not export: an object
  # store has no rename, and the contract must hold either way.
  @impl true
  def replace_tree(actor, path, files) do
    through(:replace_tree, path, fn ->
      adapter = base()

      # `Code.ensure_loaded?/1` first, as `Arca.Overlay` asks it: on a
      # module the VM has not loaded yet, `function_exported?/3` answers
      # false and an adapter that CAN swap a tree would be taken for one
      # that cannot.
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :replace_tree, 3),
        do: adapter.replace_tree(actor, path, files),
        else: {:error, :atomic_replace_unsupported}
    end)
  end

  @impl true
  def put_if_none_match(actor, path, content),
    do:
      through(:put_if_none_match, path, fn -> base().put_if_none_match(actor, path, content) end)

  @impl true
  def put_if_match(actor, path, content, precondition),
    do: base().put_if_match(actor, path, content, precondition)

  @impl true
  def get_for_update(actor, path),
    do: through(:get_for_update, path, fn -> base().get_for_update(actor, path) end)

  @impl true
  def list_prefix(actor, prefix), do: base().list_prefix(actor, prefix)
end

defmodule Arca.PublicationContract do
  @moduledoc """
  The publication contract of a unit, as one suite body every adapter it
  is proven on runs: a database pointer names a committed revision served
  from the prefix it was staged under, and a journal records the same
  commit; a complete object set is not proof of publication; repair moves
  nothing and invents nothing, and promotes no losing writer's objects.

  Every case drives `Arca.Overlay` over the adapter under test, with
  faults injected between the two (`Arca.PublicationContract.Faults`), so
  the contract is the same whatever stores the bytes. The fault-injection
  cases are the crash suite the write protocol owes: a writer that dies
  before its upload, during it, before the commit and after it; a prefix
  that is not what was committed; a revision served at the unit's own
  path before units were served from their prefixes; two writers with one
  expected revision; objects that are not what was written.

  `use` it with the adapters to parameterize over, and `moduletag:` for a
  run that needs a store this one is excluded without:

      defmodule Arca.PublicationContractTest do
        use Arca.PublicationContract,
          adapters: [%{adapter: Arca.PublicationContract.Double}]
      end

  The tag is an option rather than a `@moduletag` in the using module
  because these tests are defined by this macro: a module attribute set
  after them tags the module and not one test, and every case would run
  where it was meant to be excluded.

  `apps/arca/test/arca/publication_contract_test.exs` runs it on the
  double and on Local in every run, and
  `publication_contract_s3_test.exs` on `Arca.Adapters.S3` under the
  `:s3_integration` tag, which the `s3-minio` job selects.
  """

  defmacro __using__(opts) do
    moduletags =
      for tag <- List.wrap(Keyword.get(opts, :moduletag)), do: quote(do: @moduletag(unquote(tag)))

    quote do
      use ExUnit.Case, async: false, parameterize: unquote(Keyword.fetch!(opts, :adapters))

      unquote_splicing(moduletags)

      alias Arca.PublicationContract.Faults
      alias Arca.Storage.UnitLocator
      alias Arca.StorageUnits

      @sentinel "cyfr-manifest.json"

      setup %{adapter: adapter} = tags do
        # Shared: the writers a case parks or kills are processes of their own.
        Arca.Test.Sandbox.setup!(tags)

        base = Path.join(System.tmp_dir!(), "publication_#{System.unique_integer([:positive])}")
        prev_base = Application.fetch_env!(:arca, :base_path)
        prev_seed = Application.fetch_env!(:arca, :seed_path)
        prev_adapter = Application.get_env(:arca, :storage_adapter)

        File.mkdir_p!(Path.join(base, "seed/components"))
        Application.put_env(:arca, :base_path, Path.join(base, "data"))
        Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
        Faults.wrap(adapter)
        Application.put_env(:arca, :storage_adapter, Faults)

        on_exit(fn ->
          if prev_adapter,
            do: Application.put_env(:arca, :storage_adapter, prev_adapter),
            else: Application.delete_env(:arca, :storage_adapter)

          Faults.unwrap()
          Application.put_env(:arca, :base_path, prev_base)
          Application.put_env(:arca, :seed_path, prev_seed)
          File.rm_rf!(base)
        end)

        actor = Arca.Test.Actor.local()
        name = "contract-#{System.unique_integer([:positive])}"

        {:ok, actor: actor, unit: ["components", "catalysts", "local", name, "1.0.0"]}
      end

      # ---------------------------------------------------------------------------
      # Vocabulary
      # ---------------------------------------------------------------------------

      # A revision whose every object says which revision it is, so a mix of
      # two revisions cannot pass for either.
      defp revision(tag) do
        {:files,
         [
           {[@sentinel], ~s({"revision":"#{tag}"})},
           {["a.txt"], "a of #{tag}"},
           {["sub", "b.txt"], "b of #{tag}"}
         ]}
      end

      defp commit(actor, unit, tag),
        do: Arca.Overlay.commit_unit(actor, unit, revision(tag), cap: :exempt)

      # What a reader reads: the pointer, resolved once, then the unit's
      # objects at the unit's own paths, which the facade resolves to the
      # committed revision's prefix.
      defp read(actor, unit) do
        {root, key} = UnitLocator.unit_key(unit)

        case StorageUnits.current(actor, root, key) do
          {:ok, pointer} ->
            {:ok, served} = Arca.read_subtree(actor, unit)
            {pointer.current_revision, Map.new(served)}

          {:error, :not_found} ->
            :unpublished
        end
      end

      defp whole(tag) do
        %{
          [@sentinel] => ~s({"revision":"#{tag}"}),
          ["a.txt"] => "a of #{tag}",
          ["sub", "b.txt"] => "b of #{tag}"
        }
      end

      defp journal(actor, unit) do
        {root, key} = UnitLocator.unit_key(unit)

        case StorageUnits.journal(actor, root, key) do
          {:ok, commits} -> commits
          {:error, :not_found} -> []
        end
      end

      # The names staged under revisions other than the one the row names
      # — a writer's work in progress, a loser's remains, or a revision the
      # pointer left for the collector. The served revision's own objects
      # are the unit, read through `read/2`.
      defp staged(actor, unit) do
        prefix = UnitLocator.staging_prefix(unit)
        {:ok, leaves} = Arca.list_recursive(actor, prefix)

        current =
          case read(actor, unit) do
            {revision, _served} -> revision
            :unpublished -> nil
          end

        for leaf <- leaves, Enum.at(leaf, length(prefix)) != current, do: List.last(leaf)
      end

      # Every revision with a prefix under the unit's staging, the served
      # one included, sorted.
      defp staged_revisions(actor, unit) do
        prefix = UnitLocator.staging_prefix(unit)
        {:ok, leaves} = Arca.list_recursive(actor, prefix)
        leaves |> Enum.map(&Enum.at(&1, length(prefix))) |> Enum.uniq() |> Enum.sort()
      end

      # A revision's marker and objects laid under its prefix through the
      # facade, as another member's writer stages them.
      defp lay(actor, unit, revision, tag) do
        marker =
          Jason.encode!(%{
            "revision" => revision,
            "started_at" => DateTime.to_iso8601(DateTime.utc_now())
          })

        :ok = Arca.put(actor, UnitLocator.marker_path(unit, revision), marker)

        for {rel, bytes} <- whole(tag),
            do: :ok = Arca.put(actor, UnitLocator.staged_object(unit, revision, rel), bytes)

        revision
      end

      defp staging?(path), do: UnitLocator.staging?(path)
      defp marker?(path), do: List.last(path) == UnitLocator.marker_name()
      defp staged_object?(path), do: staging?(path) and not marker?(path)

      # The unit's change as the root's projection sees it.
      defp change(actor, unit) do
        {root, key} = UnitLocator.unit_key(unit)
        {:ok, token} = Arca.StorageProjectionChanges.snapshot(actor, root, units: [key])
        Enum.find(token.units, &(&1.unit_key == key))
      end

      # A writer that dies at the operation `fault` exits on.
      defp writer_dies(fun) do
        {pid, ref} = spawn_monitor(fun)
        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 30_000
        Faults.clear()
        reason
      end

      # A writer that dies between its commit and its release: the commit's
      # announcement runs in the writer's process, after the pointer moved
      # and before the draft is given back. Killed outright there — an exit
      # raised inside a telemetry handler is caught and detached by
      # telemetry, and the writer would go on.
      defp dies_after_commit(actor, unit, tag) do
        {root, key} = UnitLocator.unit_key(unit)
        handler = {__MODULE__, make_ref()}
        on_exit(fn -> :telemetry.detach(handler) end)
        test_pid = self()

        :ok =
          :telemetry.attach(
            handler,
            Arca.StorageProjectionChanges.event(),
            fn _event, _measurements, metadata, _config ->
              if metadata.athanor_id == actor.athanor_id and metadata.root == root and
                   not metadata.ready and self() != test_pid and
                   match?(
                     {:ok, %{draft_writer_token: token}} when is_binary(token),
                     StorageUnits.current(actor, root, key)
                   ) do
                :telemetry.detach(handler)
                Process.exit(self(), :kill)
              end
            end,
            nil
          )

        writer_dies(fn -> commit(actor, unit, tag) end)
      end

      # A writer parked at the operation `fault` waits on.
      defp park(test_pid) do
        send(test_pid, {:parked, self()})

        receive do
          :proceed -> :pass
        after
          30_000 -> :pass
        end
      end

      # Every registered draft, aged past its lifetime: what a dead writer
      # leaves behind, without the wait.
      defp expire_drafts! do
        long_ago =
          DateTime.add(DateTime.utc_now(), -2 * StorageUnits.draft_ttl_ms(), :millisecond)

        Arca.Repo.update_all(Arca.Schemas.StorageUnit, set: [updated_at: long_ago])
      end

      # ---------------------------------------------------------------------------
      # The protocol, whole
      # ---------------------------------------------------------------------------

      describe "a commit" do
        test "publishes the revision: the pointer, one journal row, the objects served, nothing staged",
             %{actor: actor, unit: unit} do
          assert {:ok, written} = commit(actor, unit, "one")
          assert List.last(written) == [@sentinel]

          assert {revision, served} = read(actor, unit)
          assert served == whole("one")

          assert [
                   %{
                     prior_revision: nil,
                     new_revision: ^revision,
                     content_identity: "sha256:" <> _
                   }
                 ] =
                   journal(actor, unit)

          assert staged(actor, unit) == []
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :own}

          # Stamped for the root's projection by the commit, and ready once
          # the writer released the unit.
          assert %{ready: true, pending: true, source_revision: ^revision, tombstone: false} =
                   change(actor, unit)
        end

        test "registers its prefix before any upload", %{actor: actor, unit: unit} do
          test_pid = self()

          Faults.inject(fn op, path ->
            if op in [:put, :put_if_none_match] and staging?(path),
              do: send(test_pid, {:staged, List.last(path)})

            :pass
          end)

          assert {:ok, _written} = commit(actor, unit, "one")

          # An adapter with no conditional create is asked, refuses, and gets a plain put.
          assert [first | uploads] = Enum.uniq(staged_in_order())
          assert first == UnitLocator.marker_name()
          assert Enum.sort(uploads) == Enum.sort([@sentinel, "a.txt", "b.txt"])
        end

        defp staged_in_order do
          receive do
            {:staged, name} -> [name | staged_in_order()]
          after
            0 -> []
          end
        end

        test "a second commit appends a second journal row, and a reader between sees one revision whole",
             %{actor: actor, unit: unit} do
          assert {:ok, _} = commit(actor, unit, "one")
          assert {first, served} = read(actor, unit)
          assert served == whole("one")

          # The second commit, parked with its revision half staged.
          test_pid = self()

          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: park(test_pid),
              else: :pass
          end)

          second = Task.async(fn -> commit(actor, unit, "two") end)
          assert_receive {:parked, writer}, 10_000

          assert {^first, served} = read(actor, unit)
          assert served == whole("one")

          send(writer, :proceed)
          assert {:ok, _} = Task.await(second, 30_000)
          Faults.clear()

          assert {second_revision, served} = read(actor, unit)
          assert served == whole("two")
          refute second_revision == first

          assert [
                   %{prior_revision: nil, new_revision: ^first},
                   %{prior_revision: ^first, new_revision: ^second_revision}
                 ] = journal(actor, unit)

          # Same content, same identity; other content, another.
          [one, two] = journal(actor, unit)
          refute one.content_identity == two.content_identity
        end

        test "is the athanor's alone", %{actor: actor, unit: unit} do
          assert {:ok, _} = commit(actor, unit, "one")

          actor_b = Arca.Test.Actor.local(athanor_id: "ath_b", user_id: "user_b")
          assert read(actor_b, unit) == :unpublished
          assert Arca.Overlay.unit_status(actor_b, unit) == {:ok, :absent}

          assert {:error, :not_found} = Arca.Overlay.repair_unit(actor_b, unit)
        end

        test "a subtree replacement is a commit like any other", %{actor: actor, unit: unit} do
          assert {:ok, _} = commit(actor, unit, "one")

          assert :ok =
                   Arca.Overlay.replace_subtree(
                     actor,
                     unit,
                     ["sub"],
                     [{["c.txt"], "c of two"}],
                     cap: :exempt
                   )

          assert {revision, served} = read(actor, unit)

          assert served == %{
                   [@sentinel] => ~s({"revision":"one"}),
                   ["a.txt"] => "a of one",
                   ["sub", "c.txt"] => "c of two"
                 }

          assert [%{new_revision: first}, %{prior_revision: first, new_revision: ^revision}] =
                   journal(actor, unit)

          # The replaced revision's prefix stands for the collector; nothing else.
          assert staged_revisions(actor, unit) == Enum.sort([first, revision])
        end
      end

      # ---------------------------------------------------------------------------
      # A writer that dies
      # ---------------------------------------------------------------------------

      describe "a writer that dies" do
        test "before upload: a draft, a marker, no object, no commit — the unit reads absent", %{
          actor: actor,
          unit: unit
        } do
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path), do: exit(:died_before_upload), else: :pass
          end)

          assert :died_before_upload = writer_dies(fn -> commit(actor, unit, "one") end)

          assert staged(actor, unit) == [UnitLocator.marker_name()]
          assert read(actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :absent}

          # Its draft holds the unit until it has outlived its lifetime; then
          # the next writer lands, and the dead writer's prefix is not its own.
          assert {:error, :stale_writer} = commit(actor, unit, "two")
          expire_drafts!()
          assert {:ok, _} = commit(actor, unit, "two")
          assert {_revision, served} = read(actor, unit)
          assert served == whole("two")
        end

        test "during upload: the previous revision stays published, whole", %{
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          assert {first, _} = read(actor, unit)

          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: exit(:died_during_upload),
              else: :pass
          end)

          assert :died_during_upload = writer_dies(fn -> commit(actor, unit, "two") end)

          # Partial objects under the dead writer's prefix; none of them served.
          assert "a.txt" in staged(actor, unit)
          refute "b.txt" in staged(actor, unit)
          assert {^first, served} = read(actor, unit)
          assert served == whole("one")
          assert [_only_the_first] = journal(actor, unit)

          # Repair promotes none of it: the dead writer's draft is its
          # holder's through the lifetime, then given back with the
          # published revision unchanged; the half-staged prefix is the
          # collector's.
          assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, unit)
          expire_drafts!()
          assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, unit)

          assert {^first, served} = read(actor, unit)
          assert served == whole("one")
          assert "a.txt" in staged(actor, unit)
          assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
        end

        test "before the commit: a complete object set is not a publication", %{
          actor: actor,
          unit: unit
        } do
          # The sentinel is the last object validation reads back: everything
          # is staged and verified, and the row has not moved.
          Faults.inject(fn op, path ->
            if op == :get and staged_object?(path) and List.last(path) == @sentinel,
              do: exit(:died_before_commit),
              else: :pass
          end)

          assert :died_before_commit = writer_dies(fn -> commit(actor, unit, "one") end)

          assert Enum.sort(staged(actor, unit)) ==
                   Enum.sort([UnitLocator.marker_name(), @sentinel, "a.txt", "b.txt"])

          assert read(actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :absent}
          refute Arca.exists?(actor, unit ++ [@sentinel])

          # And repair promotes none of it: no row names that revision.
          assert {:error, :not_found} = Arca.Overlay.repair_unit(actor, unit)
          assert read(actor, unit) == :unpublished
        end

        test "after the commit, before its release: published, and released by repair", %{
          actor: actor,
          unit: unit
        } do
          assert :killed = dies_after_commit(actor, unit, "one")

          # The commit stands and the revision is read already: the pointer,
          # the journal row, the revision's objects under its prefix.
          {root, key} = UnitLocator.unit_key(unit)

          assert {:ok, %{state: "committed", current_revision: revision}} =
                   StorageUnits.current(actor, root, key)

          assert [%{new_revision: ^revision}] = journal(actor, unit)
          assert {^revision, served} = read(actor, unit)
          assert served == whole("one")

          # The dead writer's draft holds the unit through its lifetime, so
          # repair waits it out, then takes the draft and releases it.
          assert {:error, :stale_writer} = Arca.Overlay.repair_unit(actor, unit)
          expire_drafts!()
          assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, unit)

          assert {^revision, served} = read(actor, unit)
          assert served == whole("one")
          assert staged(actor, unit) == []
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :own}
          assert [_still_one] = journal(actor, unit)
          assert {:ok, %{draft_writer_token: nil}} = StorageUnits.current(actor, root, key)

          assert {:ok, :nothing_pending} =
                   Arca.Overlay.repair_unit(actor, unit)
        end

        test "a release that never came leaves the generation pending until the repair marks a newer one ready",
             %{actor: actor, unit: unit} do
          assert :killed = dies_after_commit(actor, unit, "one")

          {root, key} = UnitLocator.unit_key(unit)
          assert {:ok, %{current_revision: revision}} = StorageUnits.current(actor, root, key)

          # The commit's generation stands, not ready: the projection must
          # not take the revision as settled before the release it never got.
          committed = change(actor, unit)
          assert %{ready: false, pending: true, source_revision: ^revision} = committed

          # Nor may the dead writer's mark land after a repair took over —
          # once the dead writer's draft has outlived its lifetime.
          expire_drafts!()
          assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, unit)
          repaired = change(actor, unit)
          assert %{ready: true, source_revision: ^revision, tombstone: false} = repaired
          assert repaired.generation > committed.generation

          assert {:error, :stale_generation} =
                   Arca.StorageProjectionChanges.mark_ready(
                     actor,
                     root,
                     key,
                     committed.generation,
                     revision
                   )

          assert change(actor, unit) == repaired
          assert {_revision, served} = read(actor, unit)
          assert served == whole("one")
        end
      end

      # ---------------------------------------------------------------------------
      # A prefix that is not what was committed, and a revision from before
      # units were served from their prefixes
      # ---------------------------------------------------------------------------

      describe "a committed revision whose completion object is gone" do
        test "is reported and left, the row kept, and a later commit lands over it", %{
          actor: actor,
          unit: unit,
          adapter: adapter
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          {revision, _served} = read(actor, unit)

          # Damage beneath the overlay: the sentinel of the pointer's prefix goes.
          :ok = adapter.delete(actor, UnitLocator.staged_object(unit, revision, [@sentinel]))

          # Nothing is moved or invented: the pointer and the journal stand,
          # the remaining objects read, and the unit is no complete copy.
          assert {:error, :staged_incomplete} = Arca.Overlay.repair_unit(actor, unit)
          assert {^revision, served} = read(actor, unit)
          assert served == Map.delete(whole("one"), [@sentinel])
          assert [_one_commit] = journal(actor, unit)
          refute Arca.exists?(actor, unit ++ [@sentinel])

          # A later commit lands over it as any commit does.
          assert {:ok, _} = commit(actor, unit, "two")
          assert {_next, served} = read(actor, unit)
          assert served == whole("two")
          assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
        end
      end

      describe "a revision served at the unit's own path before this shape" do
        # What the earlier finish left: the revision's objects at the unit's
        # own path, its prefix removed — laid beneath the overlay.
        defp serve_at_unit!(actor, unit, adapter) do
          {revision, _served} = read(actor, unit)
          prefix = UnitLocator.revision_prefix(unit, revision)
          {:ok, leaves} = adapter.list_recursive(actor, prefix)

          for leaf <- leaves, List.last(leaf) != UnitLocator.marker_name() do
            {:ok, bytes} = adapter.get(actor, leaf)
            :ok = adapter.put(actor, unit ++ Enum.drop(leaf, length(prefix)), bytes)
          end

          :ok = adapter.delete_tree(actor, prefix)
          revision
        end

        test "is read where it is, and the first edit moves it into its prefix under the lease",
             %{actor: actor, unit: unit, adapter: adapter} do
          assert {:ok, _} = commit(actor, unit, "one")
          revision = serve_at_unit!(actor, unit, adapter)
          assert {:ok, []} = Arca.list_recursive(actor, UnitLocator.staging_prefix(unit))

          # Every reader answers from the unit's own path meanwhile.
          assert {^revision, served} = read(actor, unit)
          assert served == whole("one")
          assert {:ok, "a of one"} = Arca.get(actor, unit ++ ["a.txt"])
          assert Arca.exists?(actor, unit ++ [@sentinel])
          assert {:ok, entries} = Arca.list_typed(actor, unit)
          assert Enum.sort(entries) == [{"a.txt", :file}, {@sentinel, :file}, {"sub", :dir}]
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :own}
          assert {:ok, %{^unit => :own}} = Arca.Overlay.unit_statuses(actor, "components")
          before = change(actor, unit)

          :ok = Arca.put(actor, unit ++ ["a.txt"], "edited")

          # The revision is in its prefix with the edit, nothing stands at
          # the unit's own path, and no commit was made: the pointer and
          # the journal are as they were, the generation newer and ready.
          edited = Map.put(whole("one"), ["a.txt"], "edited")
          assert {^revision, served} = read(actor, unit)
          assert served == edited
          {:ok, moved} = Arca.read_subtree(actor, UnitLocator.revision_prefix(unit, revision))
          assert Map.new(moved) == edited
          assert {:ok, []} = adapter.list_recursive(actor, unit)
          assert [_still_one_commit] = journal(actor, unit)
          assert %{ready: true, source_revision: ^revision} = after_edit = change(actor, unit)
          assert after_edit.generation > before.generation
          assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)
        end

        test "is moved into its prefix by repair, and superseded whole by a commit", %{
          actor: actor,
          unit: unit,
          adapter: adapter
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          revision = serve_at_unit!(actor, unit, adapter)

          assert {:ok, :repaired} = Arca.Overlay.repair_unit(actor, unit)
          assert {^revision, served} = read(actor, unit)
          assert served == whole("one")
          assert {:ok, []} = adapter.list_recursive(actor, unit)
          assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)

          # Served at the unit's own path again, a commit supersedes it
          # whole: the new revision in its prefix, the unit's own path
          # cleared behind it.
          serve_at_unit!(actor, unit, adapter)
          assert {:ok, _} = commit(actor, unit, "two")
          assert {two, served} = read(actor, unit)
          assert served == whole("two")
          refute two == revision
          assert {:ok, []} = adapter.list_recursive(actor, unit)
          assert staged_revisions(actor, unit) == [two]
          assert [_one, %{new_revision: ^two}] = journal(actor, unit)
        end
      end

      # ---------------------------------------------------------------------------
      # Writers that lose
      # ---------------------------------------------------------------------------

      describe "two writers" do
        setup %{actor: actor, unit: unit} do
          assert {:ok, _} = commit(actor, unit, "one")
          test_pid = self()

          # The first writer of each case parks with its revision half staged.
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: park(test_pid),
              else: :pass
          end)

          loser = Task.async(fn -> commit(actor, unit, "loser") end)
          assert_receive {:parked, writer}, 10_000
          Faults.clear()

          {:ok, loser: loser, writer: writer}
        end

        test "with one expected revision: exactly one commits, the other is a stale revision", %{
          actor: actor,
          unit: unit,
          loser: loser,
          writer: writer
        } do
          {root, key} = UnitLocator.unit_key(unit)
          expire_drafts!()

          # On this node the stalled writer keeps the unit however old its
          # token: a taker here is refused at once.
          assert {:error, :stale_writer} = commit(actor, unit, "winner")

          # Another member takes the expired lease through the rows alone,
          # stages its revision under its own prefix and commits against the
          # revision both staged against.
          {first, _} = read(actor, unit)
          {:ok, taken} = StorageUnits.register_draft(actor, root, key, "wrt_member")
          winner = lay(actor, unit, StorageUnits.new_revision(), "winner")

          {:committed, _generation} =
            StorageUnits.stamped_commit(actor, taken, taken.current_revision, "wrt_member", %{
              new_revision: winner,
              content_identity: Prima.Digest.sha256("winner"),
              commit_identity: "member"
            })

          :ok = StorageUnits.release_served(actor, taken, "wrt_member", winner)

          send(writer, :proceed)
          assert {:error, :stale_revision} = Task.await(loser, 30_000)

          assert [_one, %{new_revision: ^winner}] = journal(actor, unit)
          assert {^winner, served} = read(actor, unit)
          assert served == whole("winner")

          # The loser's objects are gone — the staging holds the first
          # revision, the collector's, and the winner's — and repair has
          # nothing of the loser's to find.
          assert staged_revisions(actor, unit) == Enum.sort([first, winner])
          assert {:ok, :nothing_pending} = Arca.Overlay.repair_unit(actor, unit)

          # The unit is free again: this node's writer lands whole.
          assert {:ok, _} = commit(actor, unit, "third")
          assert {revision, served} = read(actor, unit)
          assert served == whole("third")
          assert [_one, _winner, %{new_revision: ^revision}] = journal(actor, unit)
        end

        test "a stale draft token: the writer that lost its draft commits nothing", %{
          actor: actor,
          unit: unit,
          loser: loser,
          writer: writer
        } do
          {first, _} = read(actor, unit)
          {root, key} = UnitLocator.unit_key(unit)

          # Another writer takes the expired draft and has not committed: the
          # pointer has not moved, so only the token refuses the first.
          expire_drafts!()
          assert {:ok, _taken} = StorageUnits.register_draft(actor, root, key, "wrt_other")

          send(writer, :proceed)
          assert {:error, :stale_writer} = Task.await(loser, 30_000)

          assert {^first, served} = read(actor, unit)
          assert served == whole("one")
          assert [_only_the_first] = journal(actor, unit)
          assert staged(actor, unit) == []

          # The draft it lost is still the other writer's.
          assert {:error, :stale_writer} = commit(actor, unit, "third")
        end
      end

      # ---------------------------------------------------------------------------
      # Objects that are not what was written
      # ---------------------------------------------------------------------------

      describe "referenced objects" do
        test "a missing one commits nothing", %{actor: actor, unit: unit} do
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "a.txt",
              do: :lose,
              else: :pass
          end)

          assert {:error, :invalid_objects} = commit(actor, unit, "one")
          Faults.clear()

          assert read(actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert staged(actor, unit) == []
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :absent}

          # The draft was given back: the next writer lands at once.
          assert {:ok, _} = commit(actor, unit, "two")
        end

        test "a corrupt one commits nothing, and the previous revision stays", %{
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          {first, _} = read(actor, unit)

          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: {:store, "not what was written"},
              else: :pass
          end)

          assert {:error, :invalid_objects} = commit(actor, unit, "two")
          Faults.clear()

          assert {^first, served} = read(actor, unit)
          assert served == whole("one")
          assert [_only_the_first] = journal(actor, unit)
          assert staged(actor, unit) == []
        end

        test "an upload that fails is its own error, and commits nothing", %{
          actor: actor,
          unit: unit
        } do
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: {:error, :enospc},
              else: :pass
          end)

          assert {:error, :enospc} = commit(actor, unit, "one")
          Faults.clear()

          assert read(actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert staged(actor, unit) == []
        end
      end

      # ---------------------------------------------------------------------------
      # Edits and deletes
      # ---------------------------------------------------------------------------

      describe "a plain write inside a unit" do
        test "is pending before its write and ready at a newer generation after it", %{
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          published = change(actor, unit)
          test_pid = self()

          # The edit lands in the committed revision's prefix.
          Faults.inject(fn op, path ->
            if op == :put and staging?(path) and List.last(path) == "a.txt",
              do: park(test_pid),
              else: :pass
          end)

          edit = Task.async(fn -> Arca.put(actor, unit ++ ["a.txt"], "edited") end)
          assert_receive {:parked, writer}, 10_000

          # While the bytes move the unit is pending, never ready.
          pending = change(actor, unit)
          assert %{ready: false} = pending
          assert pending.generation > published.generation

          send(writer, :proceed)
          assert :ok = Task.await(edit, 30_000)
          Faults.clear()

          ready = change(actor, unit)
          assert %{ready: true} = ready
          assert ready.generation > pending.generation
        end

        test "a delete at the unit is a tombstone, pending until the tenant delete returns", %{
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          test_pid = self()

          Faults.inject(fn op, path ->
            if op == :delete_tree and path == unit, do: park(test_pid), else: :pass
          end)

          drop = Task.async(fn -> Arca.Overlay.drop_unit(actor, unit) end)
          assert_receive {:parked, writer}, 10_000
          assert %{tombstone: true, ready: false} = change(actor, unit)

          send(writer, :proceed)
          assert {:ok, :deleted} = Task.await(drop, 30_000)
          Faults.clear()

          assert %{tombstone: true, ready: true, source_revision: nil} = change(actor, unit)
        end
      end

      # ---------------------------------------------------------------------------
      # Objects no row names
      # ---------------------------------------------------------------------------

      describe "bytes no committed row names" do
        test "are nothing: a write into a unit no row names is refused, and a complete object set " <>
               "under its staging is no unit to any reader",
             %{actor: actor, unit: unit} do
          # A plain write into a unit that has no committed revision has
          # nothing to land in: a component is made by its own verbs, its
          # sentinel included.
          assert {:error, :no_unit} = Arca.put(actor, unit ++ ["a.txt"], "hand-laid")
          assert {:error, :no_unit} = Arca.append(actor, unit ++ ["a.txt"], "hand-laid")
          assert {:error, :no_unit} = Arca.put(actor, unit ++ [@sentinel], "hand-laid")

          assert {:error, :no_unit} =
                   Arca.put_if_none_match(actor, unit ++ ["a.txt"], "hand-laid")

          assert {:error, :no_unit} =
                   Arca.replace_tree(actor, unit ++ ["sub"], [{["c.txt"], "c"}], cap: :exempt)

          # A complete object set laid under the unit's staging, naming a
          # revision no row names, is at most the collector's.
          orphan = StorageUnits.new_revision()

          for {rel, bytes} <- whole("hand-laid"),
              do: :ok = Arca.put(actor, UnitLocator.staged_object(unit, orphan, rel), bytes)

          assert read(actor, unit) == :unpublished
          assert {:error, :not_found} = Arca.get(actor, unit ++ ["a.txt"])
          refute Arca.exists?(actor, unit ++ [@sentinel])
          assert {:ok, []} = Arca.list_recursive(actor, unit)
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :absent}
          assert {:ok, statuses} = Arca.Overlay.unit_statuses(actor, "components")
          refute Map.has_key?(statuses, unit)
          assert {:error, :not_found} = Arca.Overlay.repair_unit(actor, unit)

          # A create lands — nothing exists — and a commit lands whole; the
          # orphan prefix is not theirs.
          assert {:ok, _} =
                   Arca.Overlay.commit_unit(actor, unit, revision("one"),
                     cap: :exempt,
                     if_absent: true
                   )

          assert {_revision, served} = read(actor, unit)
          assert served == whole("one")
          assert Enum.sort(staged(actor, unit)) == Enum.sort([@sentinel, "a.txt", "b.txt"])
        end

        test "a role is created by writing its own file, which is its one commit; a scroll by " <>
               "its SKILL.md, and nothing lands inside it before that",
             %{actor: actor} do
          n = System.unique_integer([:positive])
          role = ["aqua", "roles", "made-#{n}.md"]
          {root, key} = UnitLocator.unit_key(role)

          assert :ok = Arca.put(actor, role, "# made")

          assert {:ok, %{state: "committed", current_revision: revision, draft_writer_token: nil}} =
                   StorageUnits.current(actor, root, key)

          assert [%{prior_revision: nil, new_revision: ^revision}] = journal(actor, role)
          assert {:ok, "# made"} = Arca.get(actor, role)
          assert Arca.Overlay.unit_status(actor, role) == {:ok, :own}

          # The next write is an edit of the committed revision, not a commit.
          assert :ok = Arca.put(actor, role, "# edited")
          assert {:ok, "# edited"} = Arca.get(actor, role)
          assert [_the_one_commit] = journal(actor, role)

          scroll = ["aqua", "skills", "made-#{n}"]
          assert {:error, :no_unit} = Arca.put(actor, scroll ++ ["reference.md"], "body")
          assert :ok = Arca.put(actor, scroll ++ ["SKILL.md"], "# scroll")
          assert :ok = Arca.put(actor, scroll ++ ["reference.md"], "body")
          assert {:ok, "body"} = Arca.get(actor, scroll ++ ["reference.md"])
          assert [_one_commit] = journal(actor, scroll)
          assert {:ok, :deleted} = Arca.Overlay.drop_unit(actor, scroll)
        end

        test "a subtree replacement needs a committed unit", %{actor: actor, unit: unit} do
          assert {:error, :not_found} =
                   Arca.Overlay.replace_subtree(
                     actor,
                     unit,
                     ["sub"],
                     [{["c.txt"], "c"}],
                     cap: :exempt
                   )

          assert journal(actor, unit) == []

          assert {:ok, _} = commit(actor, unit, "one")

          assert :ok =
                   Arca.Overlay.replace_subtree(
                     actor,
                     unit,
                     ["sub"],
                     [{["c.txt"], "c"}],
                     cap: :exempt
                   )

          assert {revision, served} = read(actor, unit)
          assert served[["sub", "c.txt"]] == "c"
          assert served[["a.txt"]] == "a of one"
          refute Map.has_key?(served, ["sub", "b.txt"])
          assert [%{prior_revision: nil}, %{new_revision: ^revision}] = journal(actor, unit)
        end

        test "a dropped unit is retired before its objects go, and lands again as a new draft", %{
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(actor, unit, "one")
          assert {:ok, :deleted} = Arca.Overlay.drop_unit(actor, unit)

          assert read(actor, unit) == :unpublished
          assert Arca.Overlay.unit_status(actor, unit) == {:ok, :absent}
          refute Arca.exists?(actor, unit ++ [@sentinel])
          assert {:error, :not_found} = Arca.Overlay.drop_unit(actor, unit)

          # The journal outlives the drop; the next commit starts from no pointer.
          assert {:ok, _} = commit(actor, unit, "two")
          assert [%{prior_revision: nil}, %{prior_revision: nil}] = journal(actor, unit)
        end
      end
    end
  end
end
