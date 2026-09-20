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
  is proven on runs: a database pointer names a committed immutable
  revision and a journal records the same commit; a complete object set
  is not proof of publication; repair promotes neither a losing writer's
  objects nor the remainder of a move that stopped.

  Every case drives `Arca.Overlay` over the adapter under test, with
  faults injected between the two (`Arca.PublicationContract.Faults`), so
  the contract is the same whatever stores the bytes. The fault-injection
  cases are the crash suite the write protocol owes: a writer that dies
  before its upload, during it, before the commit and after it; a move to
  the served location that fails; two writers with one expected revision;
  objects that are not what was written.

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

  `apps/cyfr/test/arca/publication_contract_test.exs` runs it on the
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

      setup %{adapter: adapter} do
        # Shared: the writers a case parks or kills are processes of their own.
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
        Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

        base = Path.join(System.tmp_dir!(), "publication_#{System.unique_integer([:positive])}")
        prev_base = Application.fetch_env!(:cyfr, :base_path)
        prev_seed = Application.fetch_env!(:cyfr, :seed_path)
        prev_adapter = Application.get_env(:cyfr, :storage_adapter)

        File.mkdir_p!(Path.join(base, "seed/components"))
        Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
        Application.put_env(:cyfr, :seed_path, Path.join(base, "seed"))
        Faults.wrap(adapter)
        Application.put_env(:cyfr, :storage_adapter, Faults)

        on_exit(fn ->
          if prev_adapter,
            do: Application.put_env(:cyfr, :storage_adapter, prev_adapter),
            else: Application.delete_env(:cyfr, :storage_adapter)

          Faults.unwrap()
          Application.put_env(:cyfr, :base_path, prev_base)
          Application.put_env(:cyfr, :seed_path, prev_seed)
          File.rm_rf!(base)
        end)

        ctx = Sanctum.TestContext.local()
        name = "contract-#{System.unique_integer([:positive])}"

        {:ok,
         ctx: ctx,
         actor: Sanctum.Context.actor(ctx),
         unit: ["components", "catalysts", "local", name, "1.0.0"]}
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

      defp commit(ctx, unit, tag),
        do:
          Arca.Overlay.commit_unit(Sanctum.Context.actor(ctx), unit, revision(tag), cap: :exempt)

      # What a reader reads: the pointer, resolved once, then the unit's
      # objects where they are served.
      defp read(ctx, actor, unit) do
        {root, key} = UnitLocator.unit_key(unit)

        case StorageUnits.current(actor, root, key) do
          {:ok, pointer} ->
            {:ok, served} =
              Arca.read_subtree(Sanctum.Context.actor(ctx), UnitLocator.served_path(unit))

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

      defp staged(ctx, unit) do
        {:ok, leaves} =
          Arca.list_recursive(Sanctum.Context.actor(ctx), UnitLocator.staging_prefix(unit))

        for leaf <- leaves, do: List.last(leaf)
      end

      defp staging?(path), do: UnitLocator.staging?(path)
      defp marker?(path), do: List.last(path) == UnitLocator.marker_name()
      defp staged_object?(path), do: staging?(path) and not marker?(path)
      defp served?(path, unit), do: List.starts_with?(path, unit)

      # A writer that dies at the operation `fault` exits on.
      defp writer_dies(fun) do
        {pid, ref} = spawn_monitor(fun)
        assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 30_000
        Faults.clear()
        reason
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
             %{ctx: ctx, actor: actor, unit: unit} do
          assert {:ok, written} = commit(ctx, unit, "one")
          assert List.last(written) == [@sentinel]

          assert {revision, served} = read(ctx, actor, unit)
          assert served == whole("one")

          assert [
                   %{
                     prior_revision: nil,
                     new_revision: ^revision,
                     content_identity: "sha256:" <> _
                   }
                 ] =
                   journal(actor, unit)

          assert staged(ctx, unit) == []
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :own}
        end

        test "registers its prefix before any upload", %{ctx: ctx, unit: unit} do
          test_pid = self()

          Faults.inject(fn op, path ->
            if op in [:put, :put_if_none_match] and staging?(path),
              do: send(test_pid, {:staged, List.last(path)})

            :pass
          end)

          assert {:ok, _written} = commit(ctx, unit, "one")

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
             %{ctx: ctx, actor: actor, unit: unit} do
          assert {:ok, _} = commit(ctx, unit, "one")
          assert {first, served} = read(ctx, actor, unit)
          assert served == whole("one")

          # The second commit, parked with its revision half staged.
          test_pid = self()

          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: park(test_pid),
              else: :pass
          end)

          second = Task.async(fn -> commit(ctx, unit, "two") end)
          assert_receive {:parked, writer}, 10_000

          assert {^first, served} = read(ctx, actor, unit)
          assert served == whole("one")

          send(writer, :proceed)
          assert {:ok, _} = Task.await(second, 30_000)
          Faults.clear()

          assert {second_revision, served} = read(ctx, actor, unit)
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

        test "is the athanor's alone", %{ctx: ctx, unit: unit} do
          assert {:ok, _} = commit(ctx, unit, "one")

          {_a, ctx_b} = Arca.TenantTestHelper.two_contexts()
          assert read(ctx_b, Sanctum.Context.actor(ctx_b), unit) == :unpublished
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx_b), unit) == {:ok, :absent}

          assert {:error, :not_found} =
                   Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx_b), unit)
        end

        test "a subtree replacement is a commit like any other", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(ctx, unit, "one")

          assert :ok =
                   Arca.Overlay.replace_subtree(
                     Sanctum.Context.actor(ctx),
                     unit,
                     ["sub"],
                     [{["c.txt"], "c of two"}],
                     cap: :exempt
                   )

          assert {revision, served} = read(ctx, actor, unit)

          assert served == %{
                   [@sentinel] => ~s({"revision":"one"}),
                   ["a.txt"] => "a of one",
                   ["sub", "c.txt"] => "c of two"
                 }

          assert [%{new_revision: first}, %{prior_revision: first, new_revision: ^revision}] =
                   journal(actor, unit)

          assert staged(ctx, unit) == []
        end
      end

      # ---------------------------------------------------------------------------
      # A writer that dies
      # ---------------------------------------------------------------------------

      describe "a writer that dies" do
        test "before upload: a draft, a marker, no object, no commit — the unit reads absent", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path), do: exit(:died_before_upload), else: :pass
          end)

          assert :died_before_upload = writer_dies(fn -> commit(ctx, unit, "one") end)

          assert staged(ctx, unit) == [UnitLocator.marker_name()]
          assert read(ctx, actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :absent}

          # Its draft holds the unit until it has outlived its lifetime; then
          # the next writer lands, and the dead writer's prefix is not its own.
          assert {:error, :stale_writer} = commit(ctx, unit, "two")
          expire_drafts!()
          assert {:ok, _} = commit(ctx, unit, "two")
          assert {_revision, served} = read(ctx, actor, unit)
          assert served == whole("two")
        end

        test "during upload: the previous revision stays published, whole", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(ctx, unit, "one")
          assert {first, _} = read(ctx, actor, unit)

          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: exit(:died_during_upload),
              else: :pass
          end)

          assert :died_during_upload = writer_dies(fn -> commit(ctx, unit, "two") end)

          # Partial objects under the dead writer's prefix; none of them served.
          assert "a.txt" in staged(ctx, unit)
          refute "b.txt" in staged(ctx, unit)
          assert {^first, served} = read(ctx, actor, unit)
          assert served == whole("one")
          assert [_only_the_first] = journal(actor, unit)

          # Nothing for repair to promote: it reads the committed revision's
          # prefix, which is long served and gone.
          assert {:ok, :nothing_pending} =
                   Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)

          assert {^first, served} = read(ctx, actor, unit)
          assert served == whole("one")
        end

        test "before the commit: a complete object set is not a publication", %{
          ctx: ctx,
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

          assert :died_before_commit = writer_dies(fn -> commit(ctx, unit, "one") end)

          assert Enum.sort(staged(ctx, unit)) ==
                   Enum.sort([UnitLocator.marker_name(), @sentinel, "a.txt", "b.txt"])

          assert read(ctx, actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :absent}
          refute Arca.exists?(Sanctum.Context.actor(ctx), unit ++ [@sentinel])

          # And repair promotes none of it: no row names that revision.
          assert {:error, :not_found} = Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)
          assert read(ctx, actor, unit) == :unpublished
        end

        test "after the commit, before its acknowledgement: published, and repairable", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          Faults.inject(fn op, path ->
            if op in [:put, :replace_tree] and served?(path, unit),
              do: exit(:died_after_commit),
              else: :pass
          end)

          assert :died_after_commit = writer_dies(fn -> commit(ctx, unit, "one") end)

          # The commit stands: the pointer, the journal row, the revision's
          # objects intact under its prefix.
          {root, key} = UnitLocator.unit_key(unit)

          assert {:ok, %{state: "committed", current_revision: revision}} =
                   StorageUnits.current(actor, root, key)

          assert [%{new_revision: ^revision}] = journal(actor, unit)
          assert "a.txt" in staged(ctx, unit)

          assert {:ok, :repaired} = Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)

          assert {^revision, served} = read(ctx, actor, unit)
          assert served == whole("one")
          assert staged(ctx, unit) == []
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :own}
          assert [_still_one] = journal(actor, unit)

          assert {:ok, :nothing_pending} =
                   Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)
        end
      end

      # ---------------------------------------------------------------------------
      # A finish that fails, and a repair that fails
      # ---------------------------------------------------------------------------

      describe "a move to the served location that fails" do
        @tag :capture_log
        test "is never a lost commit, and a repair that fails part-way is repaired again", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          fail_serving = fn ->
            Faults.inject(fn op, path ->
              cond do
                op == :replace_tree and served?(path, unit) ->
                  {:error, :enospc}

                op == :put and served?(path, unit) and List.last(path) == "b.txt" ->
                  {:error, :enospc}

                true ->
                  :pass
              end
            end)
          end

          fail_serving.()
          assert {:error, {:finish_failed, :enospc}} = commit(ctx, unit, "one")

          {root, key} = UnitLocator.unit_key(unit)
          assert {:ok, %{current_revision: revision}} = StorageUnits.current(actor, root, key)
          assert [%{new_revision: ^revision}] = journal(actor, unit)

          # The repair fails where the commit's own move did.
          assert {:error, {:finish_failed, :enospc}} =
                   Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)

          assert {:ok, %{current_revision: ^revision}} = StorageUnits.current(actor, root, key)
          assert "b.txt" in staged(ctx, unit)

          Faults.clear()
          assert {:ok, :repaired} = Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)
          assert {^revision, served} = read(ctx, actor, unit)
          assert served == whole("one")
          assert staged(ctx, unit) == []
          assert [_one_commit_throughout] = journal(actor, unit)
        end

        @tag :capture_log
        test "a prefix a failed removal left partial is never served over the complete unit", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          # The move served the whole revision and then failed part-way
          # through removing its prefix: the unit is committed, complete and
          # served, and what is left staged is a subset of it.
          Faults.inject(fn op, path ->
            if op == :delete_tree and staging?(path), do: {:error, :enospc}, else: :pass
          end)

          assert {:error, {:finish_failed, :enospc}} = commit(ctx, unit, "one")
          Faults.clear()

          assert {revision, served} = read(ctx, actor, unit)
          assert served == whole("one")

          # What the removal got through before it failed.
          :ok =
            Arca.delete(
              Sanctum.Context.actor(ctx),
              UnitLocator.staged_object(unit, revision, ["a.txt"])
            )

          refute "a.txt" in staged(ctx, unit)

          # The remainder is not the revision the journal recorded, so it is
          # promoted over nothing: the served unit stands whole.
          assert {:error, :staged_incomplete} =
                   Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)

          assert {^revision, served} = read(ctx, actor, unit)
          assert served == whole("one")
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :own}
          assert [_one_commit_throughout] = journal(actor, unit)

          # A later commit lands over it as any commit does.
          assert {:ok, _} = commit(ctx, unit, "two")
          assert {_next, served} = read(ctx, actor, unit)
          assert served == whole("two")
        end
      end

      # ---------------------------------------------------------------------------
      # Writers that lose
      # ---------------------------------------------------------------------------

      describe "two writers" do
        setup %{ctx: ctx, unit: unit} do
          assert {:ok, _} = commit(ctx, unit, "one")
          test_pid = self()

          # The first writer of each case parks with its revision half staged.
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: park(test_pid),
              else: :pass
          end)

          loser = Task.async(fn -> commit(ctx, unit, "loser") end)
          assert_receive {:parked, writer}, 10_000
          Faults.clear()

          {:ok, loser: loser, writer: writer}
        end

        test "with one expected revision: exactly one commits, the other is a stale revision", %{
          ctx: ctx,
          actor: actor,
          unit: unit,
          loser: loser,
          writer: writer
        } do
          expire_drafts!()
          assert {:ok, _} = commit(ctx, unit, "winner")

          send(writer, :proceed)
          assert {:error, :stale_revision} = Task.await(loser, 30_000)

          assert {revision, served} = read(ctx, actor, unit)
          assert served == whole("winner")
          assert [_one, %{new_revision: ^revision}] = journal(actor, unit)

          # The loser's objects are gone, and repair has nothing of its to find.
          assert staged(ctx, unit) == []

          assert {:ok, :nothing_pending} =
                   Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)

          assert {^revision, served} = read(ctx, actor, unit)
          assert served == whole("winner")
        end

        test "a stale draft token: the writer that lost its draft commits nothing", %{
          ctx: ctx,
          actor: actor,
          unit: unit,
          loser: loser,
          writer: writer
        } do
          {first, _} = read(ctx, actor, unit)
          {root, key} = UnitLocator.unit_key(unit)

          # Another writer takes the expired draft and has not committed: the
          # pointer has not moved, so only the token refuses the first.
          expire_drafts!()
          assert {:ok, _taken} = StorageUnits.register_draft(actor, root, key, "wrt_other")

          send(writer, :proceed)
          assert {:error, :stale_writer} = Task.await(loser, 30_000)

          assert {^first, served} = read(ctx, actor, unit)
          assert served == whole("one")
          assert [_only_the_first] = journal(actor, unit)
          assert staged(ctx, unit) == []

          # The draft it lost is still the other writer's.
          assert {:error, :stale_writer} = commit(ctx, unit, "third")
        end
      end

      # ---------------------------------------------------------------------------
      # Objects that are not what was written
      # ---------------------------------------------------------------------------

      describe "referenced objects" do
        test "a missing one commits nothing", %{ctx: ctx, actor: actor, unit: unit} do
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "a.txt",
              do: :lose,
              else: :pass
          end)

          assert {:error, :invalid_objects} = commit(ctx, unit, "one")
          Faults.clear()

          assert read(ctx, actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert staged(ctx, unit) == []
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :absent}

          # The draft was given back: the next writer lands at once.
          assert {:ok, _} = commit(ctx, unit, "two")
        end

        test "a corrupt one commits nothing, and the previous revision stays", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(ctx, unit, "one")
          {first, _} = read(ctx, actor, unit)

          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: {:store, "not what was written"},
              else: :pass
          end)

          assert {:error, :invalid_objects} = commit(ctx, unit, "two")
          Faults.clear()

          assert {^first, served} = read(ctx, actor, unit)
          assert served == whole("one")
          assert [_only_the_first] = journal(actor, unit)
          assert staged(ctx, unit) == []
        end

        test "an upload that fails is its own error, and commits nothing", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          Faults.inject(fn op, path ->
            if op == :put and staged_object?(path) and List.last(path) == "b.txt",
              do: {:error, :enospc},
              else: :pass
          end)

          assert {:error, :enospc} = commit(ctx, unit, "one")
          Faults.clear()

          assert read(ctx, actor, unit) == :unpublished
          assert journal(actor, unit) == []
          assert staged(ctx, unit) == []
        end
      end

      # ---------------------------------------------------------------------------
      # Objects no row names
      # ---------------------------------------------------------------------------

      describe "a complete object set no row names" do
        test "is not a published unit to any reader", %{ctx: ctx, actor: actor, unit: unit} do
          for {rel, bytes} <- whole("hand-laid"),
              do: :ok = Arca.put(Sanctum.Context.actor(ctx), unit ++ rel, bytes)

          assert read(ctx, actor, unit) == :unpublished
          # Bytes the athanor holds, never a complete copy.
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :own}

          assert {:ok, %{^unit => :own}} =
                   Arca.Overlay.unit_statuses(Sanctum.Context.actor(ctx), "components")

          assert {:error, :not_found} = Arca.Overlay.repair_unit(Sanctum.Context.actor(ctx), unit)

          # A create never replaces what stands there; a commit does, whole.
          assert {:error, :exists} =
                   Arca.Overlay.commit_unit(Sanctum.Context.actor(ctx), unit, revision("one"),
                     cap: :exempt,
                     if_absent: true
                   )

          assert {:ok, _} = commit(ctx, unit, "one")
          assert {_revision, served} = read(ctx, actor, unit)
          assert served == whole("one")
        end

        test "a subtree replacement carries served objects into the unit's first revision", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          for {rel, bytes} <- whole("hand-laid"),
              do: :ok = Arca.put(Sanctum.Context.actor(ctx), unit ++ rel, bytes)

          assert :ok =
                   Arca.Overlay.replace_subtree(
                     Sanctum.Context.actor(ctx),
                     unit,
                     ["sub"],
                     [{["c.txt"], "c"}],
                     cap: :exempt
                   )

          assert {revision, served} = read(ctx, actor, unit)
          assert served[["sub", "c.txt"]] == "c"
          assert served[["a.txt"]] == "a of hand-laid"
          refute Map.has_key?(served, ["sub", "b.txt"])
          assert [%{prior_revision: nil, new_revision: ^revision}] = journal(actor, unit)

          # With no sentinel served there is no unit to carry over.
          bare = List.replace_at(unit, 3, "bare-" <> Enum.at(unit, 3))
          :ok = Arca.put(Sanctum.Context.actor(ctx), bare ++ ["a.txt"], "orphan")

          assert {:error, :not_found} =
                   Arca.Overlay.replace_subtree(
                     Sanctum.Context.actor(ctx),
                     bare,
                     ["sub"],
                     [{["c.txt"], "c"}],
                     cap: :exempt
                   )

          assert journal(actor, bare) == []
        end

        test "a dropped unit is retired before its objects go, and lands again as a new draft", %{
          ctx: ctx,
          actor: actor,
          unit: unit
        } do
          assert {:ok, _} = commit(ctx, unit, "one")
          assert {:ok, :deleted} = Arca.Overlay.drop_unit(Sanctum.Context.actor(ctx), unit)

          assert read(ctx, actor, unit) == :unpublished
          assert Arca.Overlay.unit_status(Sanctum.Context.actor(ctx), unit) == {:ok, :absent}
          refute Arca.exists?(Sanctum.Context.actor(ctx), unit ++ [@sentinel])
          assert {:error, :not_found} = Arca.Overlay.drop_unit(Sanctum.Context.actor(ctx), unit)

          # The journal outlives the drop; the next commit starts from no pointer.
          assert {:ok, _} = commit(ctx, unit, "two")
          assert [%{prior_revision: nil}, %{prior_revision: nil}] = journal(actor, unit)
        end
      end
    end
  end
end
