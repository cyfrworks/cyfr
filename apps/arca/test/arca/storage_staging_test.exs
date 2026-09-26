# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageStagingTest do
  @moduledoc """
  Content staged for a fenced publication (`Arca.Storage.stage/3`) and its
  sweep (`Arca.Retention.FencedStaging`), on the filesystem adapter and on
  the object-store adapter over an in-process bucket.

  The row is written before the bytes, so bytes a live attempt wrote
  always have one; an expired reservation is claimed `deleting` by
  compare-and-set, its bytes deleted and then its row; a claim that
  stopped short is finished from its row; bytes no row names are an
  orphan only past the reservation window by the store's own clock; and a
  published attempt is never the sweep's.

  Every case stages in an athanor of its own, so the sweep's counts are
  its own.
  """

  # Switches the configured storage adapter and Req's default plug, both
  # process-wide, so it runs alone and restores them.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.FencedPublication
  alias Arca.FencedPublication.Change
  alias Arca.Retention.FencedStaging
  alias Arca.Schemas.{CellLease, StorageStaging}

  @window_s div(Arca.Storage.reservation_ms(), 1_000)

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    {:ok,
     actor: Arca.Test.Actor.local(athanor_id: "ath_stg_#{System.unique_integer([:positive])}")}
  end

  for adapter <- [:local, :s3] do
    describe "on #{adapter}" do
      @describetag adapter: adapter
      setup :use_adapter

      test "a stage writes its row, then its bytes, then their digest", ctx do
        test = self()
        attempt = "attempt-#{System.unique_integer([:positive])}"

        upload =
          Stream.map(["hel", "lo"], fn chunk ->
            send(test, {:row_during_upload, row_by_attempt(attempt)})
            chunk
          end)

        before = Arca.ServerMetaStorage.now!()
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, attempt, upload)

        # The row was there, still without a digest, before any byte was.
        assert_received {:row_during_upload, %StorageStaging{id: ^id, digest: nil}}

        assert id =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/

        assert %StorageStaging{
                 athanor_id: athanor,
                 attempt: ^attempt,
                 key: key,
                 state: "reserved",
                 digest: digest,
                 expires_at: expires_at
               } = row(id)

        assert athanor == ctx.actor.athanor_id
        assert key == "staging/" <> id
        assert digest == Prima.Digest.sha256("hello")
        assert DateTime.diff(expires_at, before, :millisecond) >= Arca.Storage.reservation_ms()
        assert {:ok, "hello"} = Arca.get(ctx.actor, ["staging", id])
      end

      test "two stages of identical content land under two keys", ctx do
        assert {:ok, first} = Arca.Storage.stage(ctx.actor, "same", "bytes")
        assert {:ok, second} = Arca.Storage.stage(ctx.actor, "same", "bytes")

        assert first != second
        assert {:ok, "bytes"} = Arca.get(ctx.actor, ["staging", first])
        assert {:ok, "bytes"} = Arca.get(ctx.actor, ["staging", second])
      end

      test "a member cannot write or delete under the staging root", ctx do
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "bytes")

        assert {:error, :forbidden} = Arca.put(ctx.actor, ["staging", id], "other bytes")
        assert {:error, :forbidden} = Arca.delete(ctx.actor, ["staging", id])
        assert {:ok, "bytes"} = Arca.get(ctx.actor, ["staging", id])
      end

      test "a crash between staging and the reference commit is swept, and nothing is served",
           ctx do
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "never published")
        expire!(id)

        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert nil == Arca.Repo.get(StorageStaging, id)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", id])
        assert :not_found = FencedPublication.document(ctx.actor, "doc")
      end

      test "a reservation still standing is not swept", ctx do
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "in flight")

        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)
        assert %StorageStaging{state: "reserved"} = row(id)
        assert {:ok, "in flight"} = Arca.get(ctx.actor, ["staging", id])
      end

      test "a crash between the deleting claim and the bytes' deletion is retried from the row",
           ctx do
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "claimed")
        assert {:ok, gone} = Arca.Storage.stage(ctx.actor, "a", "claimed, bytes gone")

        # Both claimed by a sweep that stopped: one before its bytes went,
        # one after its bytes went and before its row did.
        claim!(id)
        claim!(gone)
        remove!(ctx.actor, gone)

        assert {:ok, 2} = FencedStaging.prune(ctx.actor, 1, false)
        assert nil == Arca.Repo.get(StorageStaging, id)
        assert nil == Arca.Repo.get(StorageStaging, gone)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", id])
      end

      test "bytes no row names are left inside the reservation window and swept past it", ctx do
        orphan = ["staging", "01ORPHANED0000000000000000"]
        :ok = Arca.Overlay.with_internal_writes(fn -> Arca.put(ctx.actor, orphan, "orphan") end)

        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:ok, "orphan"} = Arca.get(ctx.actor, orphan)

        age!(ctx, orphan, @window_s - 60)
        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:ok, "orphan"} = Arca.get(ctx.actor, orphan)

        age!(ctx, orphan, @window_s + 60)
        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:error, :not_found} = Arca.get(ctx.actor, orphan)
      end

      test "an upload finishing after its reservation ran out is refused :expired and swept",
           ctx do
        attempt = "late-#{System.unique_integer([:positive])}"
        slot = slot!()

        upload =
          Stream.map(["late ", "bytes"], fn chunk ->
            expire_attempt!(attempt)
            chunk
          end)

        assert {:ok, id} = Arca.Storage.stage(ctx.actor, attempt, upload)

        assert {:error, :expired} =
                 FencedPublication.publish(document(ctx.actor, id), 0, slot)

        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", id])
      end

      test "an upload finishing after its reservation was cancelled is refused :expired and swept",
           ctx do
        attempt = "cancelled-#{System.unique_integer([:positive])}"
        slot = slot!()

        upload =
          Stream.map(["cancelled ", "bytes"], fn chunk ->
            %StorageStaging{id: id} = row_by_attempt(attempt)
            _ = Arca.Storage.cancel_stage(ctx.actor, id)
            chunk
          end)

        assert {:ok, id} = Arca.Storage.stage(ctx.actor, attempt, upload)

        assert {:error, :not_found} =
                 Arca.Storage.cancel_stage(ctx.actor, "01NOSUCHATTEMPT00000000000")

        assert {:error, :expired} =
                 FencedPublication.publish(document(ctx.actor, id), 0, slot)

        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", id])
      end

      test "an upload finishing after the sweep reclaimed its row is refused and its bytes are an orphan",
           ctx do
        attempt = "reclaimed-#{System.unique_integer([:positive])}"

        upload =
          Stream.map(["reclaimed"], fn chunk ->
            expire_attempt!(attempt)
            assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
            chunk
          end)

        assert {:error, :expired} = Arca.Storage.stage(ctx.actor, attempt, upload)
        assert nil == row_by_attempt(attempt)

        assert {:ok, [path]} = Arca.Storage.list_prefix(ctx.actor, ["staging"])
        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)

        age!(ctx, path, @window_s + 60)
        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:ok, []} = Arca.Storage.list_prefix(ctx.actor, ["staging"])
      end

      test "published bytes past their staging deadline are never the sweep's", ctx do
        slot = slot!()
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "published")
        assert {:ok, 1} = FencedPublication.publish(document(ctx.actor, id), 0, slot)

        expire!(id)
        age!(ctx, ["staging", id], @window_s + 60)

        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)
        assert %StorageStaging{state: "published"} = row(id)
        assert {:ok, "published"} = Arca.get(ctx.actor, ["staging", id])
      end

      test "reclaiming one attempt leaves another attempt's identical bytes", ctx do
        slot = slot!()
        assert {:ok, expired} = Arca.Storage.stage(ctx.actor, "first", "identical")
        assert {:ok, live} = Arca.Storage.stage(ctx.actor, "second", "identical")
        expire!(expired)

        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", expired])
        assert {:ok, "identical"} = Arca.get(ctx.actor, ["staging", live])

        assert {:ok, 1} = FencedPublication.publish(document(ctx.actor, live), 0, slot)
        assert %{blob_key: blob_key} = FencedPublication.document(ctx.actor, "doc")
        assert {:ok, "identical"} = Arca.get(ctx.actor, String.split(blob_key, "/"))
      end

      test "a publication that replaces a document's bytes hands the old ones to the sweep",
           ctx do
        slot = slot!()
        assert {:ok, first} = Arca.Storage.stage(ctx.actor, "a", "first content")
        assert {:ok, second} = Arca.Storage.stage(ctx.actor, "a", "second content")

        assert {:ok, 1} = FencedPublication.publish(document(ctx.actor, first), 0, slot)
        assert {:ok, 2} = FencedPublication.publish(document(ctx.actor, second), 1, slot)

        # Handed over in the publication's own transaction.
        assert %StorageStaging{state: "deleting"} = row(first)
        assert %StorageStaging{state: "published"} = row(second)

        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert nil == Arca.Repo.get(StorageStaging, first)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", first])
        assert {:ok, "second content"} = Arca.get(ctx.actor, ["staging", second])
        assert %{revision: 2, blob_key: blob_key} = FencedPublication.document(ctx.actor, "doc")
        assert blob_key == "staging/" <> second
      end

      test "an idempotent re-publication marks nothing", ctx do
        slot = slot!()
        assert {:ok, first} = Arca.Storage.stage(ctx.actor, "a", "first content")
        assert {:ok, 1} = FencedPublication.publish(document(ctx.actor, first), 0, slot)
        before = row(first)

        assert {:ok, 1} = FencedPublication.publish(document(ctx.actor, first), 0, slot)
        assert row(first) == before

        assert {:ok, second} = Arca.Storage.stage(ctx.actor, "a", "second content")
        assert {:ok, 2} = FencedPublication.publish(document(ctx.actor, second), 1, slot)
        rows = {row(first), row(second)}

        assert {:ok, 2} = FencedPublication.publish(document(ctx.actor, second), 1, slot)
        assert {row(first), row(second)} == rows
        assert {%StorageStaging{state: "deleting"}, %StorageStaging{state: "published"}} = rows
      end

      test "a deleting row whose bytes will not go is retried, never dropped, and stuck past the value",
           ctx do
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "held fast")
        claim!(id)
        jam!(ctx, id)
        on_exit(fn -> unjam!(ctx, id) end)

        # Marked just now: retried and kept, not yet stuck.
        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)
        assert %StorageStaging{state: "deleting"} = row(id)

        # Marked longer ago than the value: it surfaces, and is still kept.
        age_row!(id, 3 * 86_400)
        assert {:error, {:stuck, 1}} = FencedStaging.prune(ctx.actor, 1, false)
        assert %StorageStaging{state: "deleting"} = row(id)
        assert {:ok, 0} = FencedStaging.prune(ctx.actor, 5, false)

        unjam!(ctx, id)
        assert {:ok, 1} = FencedStaging.prune(ctx.actor, 1, false)
        assert nil == Arca.Repo.get(StorageStaging, id)
        assert {:error, :not_found} = Arca.get(ctx.actor, ["staging", id])
      end

      test "a dry run counts what a sweep would take and takes nothing", ctx do
        assert {:ok, expired} = Arca.Storage.stage(ctx.actor, "a", "expired")
        assert {:ok, claimed} = Arca.Storage.stage(ctx.actor, "a", "claimed")
        expire!(expired)
        claim!(claimed)

        orphan = ["staging", "01ORPHANED0000000000000000"]
        :ok = Arca.Overlay.with_internal_writes(fn -> Arca.put(ctx.actor, orphan, "orphan") end)
        age!(ctx, orphan, @window_s + 60)

        assert {:ok, 3} = FencedStaging.prune(ctx.actor, 1, true)
        assert %StorageStaging{state: "reserved"} = row(expired)
        assert %StorageStaging{state: "deleting"} = row(claimed)
        assert {:ok, "orphan"} = Arca.get(ctx.actor, orphan)

        assert {:ok, 3} = FencedStaging.prune(ctx.actor, 1, false)
        assert {:ok, []} = Arca.Storage.list_prefix(ctx.actor, ["staging"])
      end

      test "last_modified dates an object and answers :not_found for none", ctx do
        assert {:ok, id} = Arca.Storage.stage(ctx.actor, "a", "dated")

        assert {:ok, %DateTime{} = at} = Arca.Storage.last_modified(ctx.actor, ["staging", id])
        assert abs(DateTime.diff(at, DateTime.utc_now(), :second)) < 60

        assert {:error, :not_found} =
                 Arca.Storage.last_modified(ctx.actor, ["staging", "01NOSUCHOBJECT000000000000"])
      end
    end
  end

  describe "refusals" do
    setup :use_adapter

    test "an actor with no athanor stages, cancels and sweeps nothing", ctx do
      nobody = %{ctx.actor | athanor_id: nil}

      assert {:error, :no_athanor} = Arca.Storage.stage(nobody, "a", "bytes")
      assert {:error, :no_athanor} = Arca.Storage.cancel_stage(nobody, "id")
      assert {:error, :no_athanor} = FencedStaging.prune(nobody, 1, false)

      assert {:error, :no_athanor} =
               FencedStaging.prune(%{ctx.actor | athanor_id: "../x"}, 1, false)
    end

    test "the kind is its own, apart from the overlay's staged revisions" do
      assert FencedStaging.key() != Arca.Retention.StagedRevisions.key()
      assert FencedStaging.unit() == :days
      assert FencedStaging.default() > 0
    end
  end

  describe "the object store's Last-Modified" do
    @describetag adapter: :s3
    setup :use_adapter

    test "a header in no HTTP-date form keeps the bytes", ctx do
      orphan = ["staging", "01ORPHANED0000000000000000"]
      :ok = Arca.Overlay.with_internal_writes(fn -> Arca.put(ctx.actor, orphan, "orphan") end)

      Agent.update(
        ctx.bucket,
        &Map.put(&1, {:last_modified, key(ctx.actor, orphan)}, "yesterday")
      )

      assert {:error, :unreadable_last_modified} = Arca.Storage.last_modified(ctx.actor, orphan)
      assert {:ok, 0} = FencedStaging.prune(ctx.actor, 1, false)
      assert {:ok, "orphan"} = Arca.get(ctx.actor, orphan)
    end
  end

  # ---- the adapters ----------------------------------------------------------

  defp use_adapter(%{adapter: :s3}) do
    {:ok, bucket} = Agent.start_link(fn -> %{} end)
    previous_adapter = Application.fetch_env(:arca, :storage_adapter)

    Application.put_env(:arca, :s3,
      bucket: "test-bucket",
      region: "us-east-1",
      endpoint: "http://localhost:9000",
      access_key_id: "AKIATEST",
      secret_access_key: "secret/test+key",
      prefix: nil,
      path_style: true
    )

    Application.put_env(:arca, :storage_adapter, Arca.Adapters.S3)
    Req.Test.stub(:s3_staging, fn conn -> serve(conn, bucket) end)
    Req.default_options(plug: {Req.Test, :s3_staging})

    on_exit(fn ->
      Req.default_options([])
      Application.delete_env(:arca, :s3)

      case previous_adapter do
        {:ok, adapter} -> Application.put_env(:arca, :storage_adapter, adapter)
        :error -> Application.delete_env(:arca, :storage_adapter)
      end
    end)

    {:ok, bucket: bucket}
  end

  defp use_adapter(_ctx), do: :ok

  # A bucket in one process: objects with the instant they were written,
  # and the ListObjectsV2, HEAD, GET, PUT and DELETE the adapter speaks.
  defp serve(conn, bucket) do
    conn = Plug.Conn.fetch_query_params(conn)
    key = conn.request_path |> String.replace_prefix("/test-bucket/", "") |> URI.decode()

    case {conn.method, key} do
      {"GET", ""} ->
        prefix = Map.get(conn.query_params, "prefix", "")
        Plug.Conn.send_resp(conn, 200, listing(bucket, prefix))

      {"PUT", key} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        Agent.update(bucket, &Map.put(&1, key, {body, DateTime.utc_now()}))

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("#{Prima.Digest.sha256_hex(body)}"))
        |> Plug.Conn.send_resp(200, "")

      {"GET", key} ->
        case Agent.get(bucket, &Map.get(&1, key)) do
          {body, _at} -> Plug.Conn.send_resp(conn, 200, body)
          nil -> Plug.Conn.send_resp(conn, 404, "")
        end

      {"HEAD", key} ->
        case Agent.get(bucket, &{Map.get(&1, key), Map.get(&1, {:last_modified, key})}) do
          {{_body, at}, override} ->
            conn
            |> Plug.Conn.put_resp_header("last-modified", override || http_date(at))
            |> Plug.Conn.send_resp(200, "")

          {nil, _override} ->
            Plug.Conn.send_resp(conn, 404, "")
        end

      {"DELETE", key} ->
        if Agent.get(bucket, &Map.get(&1, {:jammed, key})) do
          Plug.Conn.send_resp(conn, 403, "<Error><Code>AccessDenied</Code></Error>")
        else
          Agent.update(bucket, &Map.delete(&1, key))
          Plug.Conn.send_resp(conn, 204, "")
        end
    end
  end

  defp listing(bucket, prefix) do
    contents =
      bucket
      |> Agent.get(& &1)
      |> Enum.filter(fn {key, _} -> is_binary(key) and String.starts_with?(key, prefix) end)
      |> Enum.sort()
      |> Enum.map_join(fn {key, {body, at}} ->
        "<Contents><Key>#{key}</Key><LastModified>#{DateTime.to_iso8601(at)}</LastModified>" <>
          "<Size>#{byte_size(body)}</Size></Contents>"
      end)

    "<ListBucketResult><IsTruncated>false</IsTruncated>#{contents}</ListBucketResult>"
  end

  defp http_date(at), do: Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT")

  defp key(actor, path), do: Enum.join(["athanors", actor.athanor_id | path], "/")

  # The bytes at `path` put `seconds` into the past on the store's own
  # clock: the file's modification time, or the object's Last-Modified.
  defp age!(%{adapter: :local, actor: actor}, path, seconds) do
    full_path = Arca.Adapters.Local.build_path(actor, path)
    File.touch!(full_path, System.os_time(:second) - seconds)
  end

  defp age!(%{adapter: :s3, actor: actor, bucket: bucket}, path, seconds) do
    Agent.update(bucket, fn objects ->
      Map.update!(objects, key(actor, path), fn {body, _at} ->
        {body, DateTime.add(DateTime.utc_now(), -seconds, :second)}
      end)
    end)
  end

  # Make the store refuse to delete the attempt's bytes: a directory that
  # cannot be written on a filesystem, a refused DELETE on an object store.
  defp jam!(%{adapter: :local, actor: actor}, _id),
    do: File.chmod!(Arca.Adapters.Local.build_path(actor, ["staging"]), 0o555)

  defp jam!(%{adapter: :s3, actor: actor, bucket: bucket}, id),
    do: Agent.update(bucket, &Map.put(&1, {:jammed, key(actor, ["staging", id])}, true))

  defp unjam!(%{adapter: :local, actor: actor}, _id),
    do: File.chmod(Arca.Adapters.Local.build_path(actor, ["staging"]), 0o755)

  defp unjam!(%{adapter: :s3, actor: actor, bucket: bucket}, id) do
    if Process.alive?(bucket),
      do: Agent.update(bucket, &Map.delete(&1, {:jammed, key(actor, ["staging", id])})),
      else: :ok
  end

  # ---- rows ------------------------------------------------------------------

  defp row(id), do: Arca.Repo.get!(StorageStaging, id)

  defp row_by_attempt(attempt),
    do: Arca.Repo.one(from(s in StorageStaging, where: s.attempt == ^attempt))

  defp expire!(id) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    {1, _} =
      Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^id), set: [expires_at: past])

    :ok
  end

  defp expire_attempt!(attempt) do
    past = DateTime.add(Arca.ServerMetaStorage.now!(), -1_000, :millisecond)

    Arca.Repo.update_all(from(s in StorageStaging, where: s.attempt == ^attempt),
      set: [expires_at: past]
    )
  end

  defp age_row!(id, seconds) do
    at = DateTime.add(Arca.ServerMetaStorage.now!(), -seconds, :second)

    {1, _} =
      Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^id), set: [updated_at: at])

    :ok
  end

  defp claim!(id) do
    {1, _} =
      Arca.Repo.update_all(from(s in StorageStaging, where: s.id == ^id),
        set: [state: "deleting"]
      )

    :ok
  end

  defp remove!(actor, id),
    do: :ok = Arca.Overlay.with_internal_writes(fn -> Arca.delete(actor, ["staging", id]) end)

  defp document(actor, staged),
    do: %Change{resource: {:document, actor.athanor_id, "doc"}, staged: staged}

  defp slot! do
    node = "node-stg-#{System.unique_integer([:positive])}"
    now = Arca.ServerMetaStorage.now!()

    row = %{
      node: node,
      owner: node <> "#boot",
      generation: 1,
      fence: 1,
      lease_until: DateTime.add(now, 60_000, :millisecond),
      taken_at: now,
      inserted_at: now,
      updated_at: now
    }

    {1, _} = Arca.Repo.insert_all(CellLease, [row])
    %{node: node, owner: row.owner, generation: 1}
  end
end
