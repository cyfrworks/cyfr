# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AppendParityTest do
  @moduledoc """
  Append and conditional-write semantics are the same on both adapters,
  asserted with one body per case:

  - an append past `Prima.Limits.default_max_response_size/0` is
    `{:error, :object_too_large}`;
  - concurrent appends to one path serialize into a total order: every
    append that answered `:ok` is in the object once, whole, and one
    writer's appends keep their order;
  - an append moves the precondition a conditional replace needs;
  - the conditional writes answer the one result vocabulary: `:exists`,
    `:precondition_failed`, `:missing`, and exactly one winner of a race.

  S3 runs against an in-process store that honours `If-None-Match: *` and
  `If-Match` in one step, and again against MinIO under `:s3_integration`.
  """
  use ExUnit.Case, async: false

  alias Arca.Adapters.Local
  alias Arca.Adapters.S3

  # ---------------------------------------------------------------------------
  # The shared parity cases
  # ---------------------------------------------------------------------------

  defp parity_append_ceiling(adapter, actor, dir) do
    ceiling = Prima.Limits.default_max_response_size()
    path = dir ++ ["ceiling.log"]

    :ok = adapter.put(actor, path, :binary.copy(<<0>>, ceiling))
    assert {:error, :object_too_large} = adapter.append(actor, path, "x")

    # Refused whole: the object is as it was, and nothing sits beside it.
    assert {:ok, %{files: 1, bytes: ^ceiling}} = adapter.usage(actor, dir)
  end

  # As many one-shot writers as the S3 adapter has attempts: a writer
  # loses a round only to one that has finished, so every one lands.
  defp parity_concurrent_appends_all_land(adapter, actor, dir) do
    path = dir ++ ["race.jsonl"]
    lines = for n <- 1..5, do: String.duplicate("writer-#{n};", 200) <> "\n"

    answers =
      lines
      |> Task.async_stream(&adapter.append(actor, path, &1),
        max_concurrency: 5,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    assert answers == List.duplicate(:ok, 5)

    # Whole lines, each once: the appends serialized, none interleaved
    # with or overwrote another.
    assert {:ok, content} = adapter.get(actor, path)
    assert content |> String.split("\n", trim: true) |> Enum.sort() == lines_sorted(lines)
  end

  defp lines_sorted(lines), do: lines |> Enum.map(&String.trim_trailing(&1, "\n")) |> Enum.sort()

  # Writers that keep appending can starve one another past the S3
  # adapter's bound, so the invariant is on the accounting: what answered
  # `:ok` is there once, in its writer's order; what did not answered the
  # definite conflict and is absent.
  defp parity_sustained_appends_lose_nothing(adapter, actor, dir) do
    path = dir ++ ["sustained.jsonl"]

    answers =
      1..3
      |> Task.async_stream(
        fn writer ->
          for seq <- 1..4 do
            line = "#{writer}:#{seq}"
            {line, adapter.append(actor, path, line <> "\n")}
          end
        end,
        max_concurrency: 3,
        ordered: false,
        timeout: 60_000
      )
      |> Enum.flat_map(fn {:ok, per_writer} -> per_writer end)

    assert {:ok, content} = adapter.get(actor, path)
    stored = String.split(content, "\n", trim: true)

    landed = for {line, :ok} <- answers, do: line
    refused = for {line, answer} <- answers, answer != :ok, do: {line, answer}

    assert Enum.sort(stored) == Enum.sort(landed)
    assert Enum.all?(refused, fn {_line, answer} -> answer == {:error, :precondition_failed} end)

    for writer <- 1..3 do
      own = Enum.filter(stored, &String.starts_with?(&1, "#{writer}:"))

      assert own ==
               Enum.sort_by(own, &(&1 |> String.split(":") |> List.last() |> String.to_integer()))
    end
  end

  defp parity_append_moves_the_precondition(adapter, actor, dir) do
    path = dir ++ ["moved.jsonl"]

    assert {:ok, seen} = adapter.put_if_none_match(actor, path, "one\n")
    assert :ok = adapter.append(actor, path, "two\n")

    assert {:error, :precondition_failed} = adapter.put_if_match(actor, path, "rewrite", seen)
    assert {:ok, "one\ntwo\n"} = adapter.get(actor, path)
  end

  defp parity_conditional_vocabulary(adapter, actor, dir) do
    key = dir ++ ["registry", "unit"]

    # Create over an existing key.
    assert {:ok, first} = adapter.put_if_none_match(actor, key, "v1")
    assert {:error, :exists} = adapter.put_if_none_match(actor, key, "other")
    assert {:ok, "v1"} = adapter.get(actor, key)

    # A stale precondition, and one the adapter never minted.
    assert {:ok, second} = adapter.put_if_match(actor, key, "v2", first)
    assert {:error, :precondition_failed} = adapter.put_if_match(actor, key, "v3", first)
    assert {:error, :precondition_failed} = adapter.put_if_match(actor, key, "v3", :never_minted)
    assert {:ok, "v2"} = adapter.get(actor, key)
    assert {:ok, _third} = adapter.put_if_match(actor, key, "v3", second)

    # A missing key, whatever the precondition claims.
    absent = dir ++ ["registry", "absent"]
    assert {:error, :missing} = adapter.put_if_match(actor, absent, "x", second)
    assert {:error, :missing} = adapter.put_if_match(actor, absent, "x", :never_minted)
    refute adapter.exists?(actor, absent)
  end

  defp parity_racing_creates(adapter, actor, dir) do
    key = dir ++ ["registry", "raced"]

    answers =
      1..8
      |> Task.async_stream(fn n -> adapter.put_if_none_match(actor, key, "writer-#{n}") end,
        max_concurrency: 8,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    assert [{:ok, winner}] = Enum.filter(answers, &match?({:ok, _}, &1))
    assert Enum.count(answers, &(&1 == {:error, :exists})) == 7

    # The winner's precondition is the stored object's: it replaces it.
    assert {:ok, "writer-" <> _} = adapter.get(actor, key)
    assert {:ok, _next} = adapter.put_if_match(actor, key, "settled", winner)
  end

  defp parity_racing_replaces(adapter, actor, dir) do
    key = dir ++ ["registry", "replaced"]
    assert {:ok, seen} = adapter.put_if_none_match(actor, key, "v0")

    answers =
      1..8
      |> Task.async_stream(fn n -> adapter.put_if_match(actor, key, "writer-#{n}", seen) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    assert [{:ok, _winner}] = Enum.filter(answers, &match?({:ok, _}, &1))
    assert Enum.count(answers, &(&1 == {:error, :precondition_failed})) == 7
    assert {:ok, "writer-" <> _} = adapter.get(actor, key)
  end

  # ---------------------------------------------------------------------------
  # Local
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.Local" do
    setup do
      test_dir = Path.join(System.tmp_dir!(), "append_parity_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(test_dir)
      prev_base = Application.fetch_env!(:arca, :base_path)
      Application.put_env(:arca, :base_path, test_dir)

      on_exit(fn ->
        Application.put_env(:arca, :base_path, prev_base)
        File.rm_rf!(test_dir)
      end)

      {:ok, actor: Arca.Test.Actor.local(), dir: ["data", "parity"]}
    end

    test "the facade refuses an append past the shared ceiling, like S3 does", %{actor: actor} do
      ceiling = Prima.Limits.default_max_response_size()
      path = ["data", "parity.log"]

      # A file already at the ceiling: the cheapest way is to write it whole
      # (cap-exempt — this test measures the append bound, not the quota).
      :ok = Arca.put(actor, path, :binary.copy(<<0>>, ceiling), cap: :exempt)

      assert {:error, :object_too_large} =
               Arca.append(actor, path, "x", cap: :exempt)

      # Under the ceiling still appends.
      :ok = Arca.delete(actor, path)
      :ok = Arca.put(actor, path, "hello ", cap: :exempt)
      assert :ok = Arca.append(actor, path, "world", cap: :exempt)
      assert {:ok, "hello world"} = Arca.get(actor, path)
    end

    test("an append past the ceiling is refused whole", %{actor: actor, dir: dir},
      do: parity_append_ceiling(Local, actor, dir)
    )

    test("concurrent one-shot appends all land, whole", %{actor: actor, dir: dir},
      do: parity_concurrent_appends_all_land(Local, actor, dir)
    )

    test(
      "sustained concurrent appends lose nothing and keep each writer's order",
      %{actor: actor, dir: dir},
      do: parity_sustained_appends_lose_nothing(Local, actor, dir)
    )

    test("an append moves the precondition", %{actor: actor, dir: dir},
      do: parity_append_moves_the_precondition(Local, actor, dir)
    )

    test("the conditional writes answer the one vocabulary", %{actor: actor, dir: dir},
      do: parity_conditional_vocabulary(Local, actor, dir)
    )

    test("racing creates land exactly one", %{actor: actor, dir: dir},
      do: parity_racing_creates(Local, actor, dir)
    )

    test("racing replaces from one precondition land exactly one", %{actor: actor, dir: dir},
      do: parity_racing_replaces(Local, actor, dir)
    )
  end

  # ---------------------------------------------------------------------------
  # S3, over an in-process store
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.S3 (in-process store)" do
    setup do
      Application.put_env(:arca, :s3,
        bucket: "test-bucket",
        region: "us-east-1",
        endpoint: "http://localhost:9000",
        access_key_id: "AKIATEST",
        secret_access_key: "secret/test+key",
        prefix: nil,
        path_style: true
      )

      store = start_supervised!({Agent, fn -> %{} end})
      Req.Test.stub(:s3_parity, &serve(&1, store))
      Req.default_options(plug: {Req.Test, :s3_parity})

      on_exit(fn ->
        Req.default_options([])
        Application.delete_env(:arca, :s3)
      end)

      {:ok, actor: Arca.Test.Actor.local(), dir: ["data", "parity"]}
    end

    test("an append past the ceiling is refused whole", %{actor: actor, dir: dir},
      do: parity_append_ceiling(S3, actor, dir)
    )

    test("concurrent one-shot appends all land, whole", %{actor: actor, dir: dir},
      do: parity_concurrent_appends_all_land(S3, actor, dir)
    )

    test(
      "sustained concurrent appends lose nothing and keep each writer's order",
      %{actor: actor, dir: dir},
      do: parity_sustained_appends_lose_nothing(S3, actor, dir)
    )

    test("an append moves the precondition", %{actor: actor, dir: dir},
      do: parity_append_moves_the_precondition(S3, actor, dir)
    )

    test("the conditional writes answer the one vocabulary", %{actor: actor, dir: dir},
      do: parity_conditional_vocabulary(S3, actor, dir)
    )

    test("racing creates land exactly one", %{actor: actor, dir: dir},
      do: parity_racing_creates(S3, actor, dir)
    )

    test("racing replaces from one precondition land exactly one", %{actor: actor, dir: dir},
      do: parity_racing_replaces(S3, actor, dir)
    )
  end

  # An object store's side of the requests the parity cases make: objects
  # with the quoted MD5 of their bytes as the ETag, a conditional PUT whose
  # check and write are one step, and a listing with sizes for `usage/2`.
  defp serve(conn, store) do
    conn = Plug.Conn.fetch_query_params(conn)

    case {conn.method, conn.query_params} do
      {"GET", %{"prefix" => prefix}} ->
        contents =
          store
          |> Agent.get(& &1)
          |> Enum.filter(fn {path, _} -> String.starts_with?(path, "/test-bucket/" <> prefix) end)
          |> Enum.map_join(fn {path, body} ->
            key = String.replace_prefix(path, "/test-bucket/", "")
            "<Contents><Key>#{key}</Key><Size>#{byte_size(body)}</Size></Contents>"
          end)

        listing =
          "<ListBucketResult><IsTruncated>false</IsTruncated>#{contents}</ListBucketResult>"

        Plug.Conn.send_resp(conn, 200, listing)

      {"PUT", _} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 16_000_000)

        case conditional_put(conn, store, body) do
          200 ->
            conn |> Plug.Conn.put_resp_header("etag", etag(body)) |> Plug.Conn.send_resp(200, "")

          refused ->
            Plug.Conn.send_resp(conn, refused, "")
        end

      {method, _} when method in ["GET", "HEAD"] ->
        case Agent.get(store, &Map.get(&1, conn.request_path)) do
          nil ->
            Plug.Conn.send_resp(conn, 404, "")

          body ->
            conn
            |> Plug.Conn.put_resp_header("etag", etag(body))
            |> Plug.Conn.send_resp(200, body)
        end
    end
  end

  defp conditional_put(conn, store, body) do
    if_none_match = Plug.Conn.get_req_header(conn, "if-none-match")
    if_match = Plug.Conn.get_req_header(conn, "if-match")

    Agent.get_and_update(store, fn objects ->
      current = Map.get(objects, conn.request_path)

      cond do
        if_none_match == ["*"] and current != nil -> {412, objects}
        if_match != [] and current == nil -> {404, objects}
        if_match != [] and if_match != [etag(current)] -> {412, objects}
        true -> {200, Map.put(objects, conn.request_path, body)}
      end
    end)
  end

  defp etag(body), do: ~s("#{Base.encode16(:crypto.hash(:md5, body), case: :lower)}")

  # ---------------------------------------------------------------------------
  # S3, on MinIO
  # ---------------------------------------------------------------------------

  describe "Arca.Adapters.S3 (MinIO)" do
    @describetag :s3_integration

    setup do
      # Non-secret CI fixtures, mirrored in .github/workflows/test.yml and
      # `Arca.Adapters.S3MinioTest`, whose bucket this shares.
      prev = Application.get_env(:arca, :s3)
      endpoint = System.get_env("CYFR_TEST_MINIO_ENDPOINT") || "http://127.0.0.1:9000"

      Application.put_env(:arca, :s3,
        bucket: "cyfr-test",
        region: "us-east-1",
        endpoint: endpoint,
        access_key_id: "cyfrtest",
        secret_access_key: "cyfrtest123",
        prefix: nil,
        path_style: true
      )

      actor = Arca.Test.Actor.local()
      dir = ["data", "parity"]
      create_bucket!(endpoint)
      :ok = S3.delete_tree(actor, dir)

      on_exit(fn ->
        S3.delete_tree(actor, dir)

        if prev,
          do: Application.put_env(:arca, :s3, prev),
          else: Application.delete_env(:arca, :s3)
      end)

      {:ok, actor: actor, dir: dir}
    end

    test("an append past the ceiling is refused whole", %{actor: actor, dir: dir},
      do: parity_append_ceiling(S3, actor, dir)
    )

    test("concurrent one-shot appends all land, whole", %{actor: actor, dir: dir},
      do: parity_concurrent_appends_all_land(S3, actor, dir)
    )

    test(
      "sustained concurrent appends lose nothing and keep each writer's order",
      %{actor: actor, dir: dir},
      do: parity_sustained_appends_lose_nothing(S3, actor, dir)
    )

    test("an append moves the precondition", %{actor: actor, dir: dir},
      do: parity_append_moves_the_precondition(S3, actor, dir)
    )

    test("the conditional writes answer the one vocabulary", %{actor: actor, dir: dir},
      do: parity_conditional_vocabulary(S3, actor, dir)
    )

    test("racing creates land exactly one", %{actor: actor, dir: dir},
      do: parity_racing_creates(S3, actor, dir)
    )

    test("racing replaces from one precondition land exactly one", %{actor: actor, dir: dir},
      do: parity_racing_replaces(S3, actor, dir)
    )
  end

  # This file runs on its own too, so it makes the bucket it needs; MinIO
  # answers 409 when the bucket is already there, which is as usable.
  defp create_bucket!(endpoint) do
    url = "#{endpoint}/cyfr-test"

    signed =
      :aws_signature.sign_v4(
        "cyfrtest",
        "cyfrtest123",
        "us-east-1",
        "s3",
        :calendar.universal_time(),
        "PUT",
        url,
        [{"host", URI.parse(url).authority}],
        "",
        [{:uri_encode_path, false}]
      )

    {:ok, %{status: status, body: body}} =
      Req.request(
        method: :put,
        url: url,
        headers: Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end),
        body: "",
        decode_body: false
      )

    unless status in [200, 409] do
      raise "could not create MinIO bucket cyfr-test: HTTP #{status} #{inspect(body)}"
    end
  end
end
