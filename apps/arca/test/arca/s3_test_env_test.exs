# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.S3EnvTest do
  @moduledoc """
  `Arca.Test.S3Env`'s run identity and cleanup, without a store: the
  prefixes it mints, the prefixes `delete_prefix!/1` refuses before any
  request, a listing that follows its continuation tokens, and a guard
  that fails when a run touched keys it does not own or left its own
  behind. Requests go to an in-process store through `Req.Test`.
  """

  # Sets process environment and Req's default options, which every test
  # in the VM reads.
  use ExUnit.Case, async: false

  alias Arca.Test.S3Env

  @bucket "cyfr-test"

  describe "run_prefix" do
    test "two run roots give two prefixes, each the suite's name over a digest" do
      a = S3Env.run_prefix("minio", "/tmp/cyfr-t.aaaaaa/p1")
      b = S3Env.run_prefix("minio", "/tmp/cyfr-t.bbbbbb/p1")

      assert a != b
      assert String.starts_with?(a, "minio/")
      assert String.starts_with?(b, "minio/")
      assert a =~ ~r"\A[a-z]+/[0-9a-f]{16}\z"
      assert b =~ ~r"\A[a-z]+/[0-9a-f]{16}\z"
      assert S3Env.run_prefix("minio", "/tmp/cyfr-t.aaaaaa/p2") != a
    end

    test "the runner's root names the run, and a direct run mints one token per VM" do
      previous = System.get_env("CYFR_TEST_RUN_ROOT")
      on_exit(fn -> restore_env("CYFR_TEST_RUN_ROOT", previous) end)

      System.put_env("CYFR_TEST_RUN_ROOT", "/tmp/cyfr-t.cccccc/p3")
      assert S3Env.run_prefix("parity") == S3Env.run_prefix("parity", "/tmp/cyfr-t.cccccc/p3")

      System.delete_env("CYFR_TEST_RUN_ROOT")
      direct = S3Env.run_prefix("parity")
      assert direct =~ ~r"\A[a-z]+/[0-9a-f]{16}\z"
      assert direct != S3Env.run_prefix("parity", "/tmp/cyfr-t.cccccc/p3")

      answers =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> S3Env.run_prefix("parity") end) end)
        |> Task.await_many()

      assert Enum.uniq(answers) == [direct]
    end

    test "a suite name outside the shape is refused" do
      for suite <- ["", "Minio", "s3", "a/b", "minio\n"] do
        assert_raise ArgumentError, fn -> S3Env.run_prefix(suite, "/tmp/root") end
      end
    end
  end

  describe "against an in-process store" do
    setup do
      store = start_supervised!({Agent, fn -> %{keys: MapSet.new(), drop: true} end})
      test_pid = self()

      Req.Test.stub(:s3_env, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path, conn.query_string})
        serve(conn, store)
      end)

      Req.default_options(plug: {Req.Test, :s3_env})

      env =
        for {name, value} <- [
              {"CYFR_TEST_S3_BUCKET", @bucket},
              {"CYFR_TEST_S3_PATH_STYLE", "true"}
            ] do
          previous = System.get_env(name)
          System.put_env(name, value)
          {name, previous}
        end

      on_exit(fn ->
        Req.default_options([])
        Enum.each(env, fn {name, previous} -> restore_env(name, previous) end)
      end)

      {:ok, store: store}
    end

    test "a blank prefix or one without a digest is refused before any request" do
      for prefix <- [
            "",
            "   ",
            "minio",
            "minio/",
            "minio/not-a-digest",
            "/0123456789abcdef",
            "minio/0123456789abcdef\n"
          ] do
        assert_raise ArgumentError, fn -> S3Env.delete_prefix!(prefix) end
      end

      refute_received {:request, _, _, _}

      # The probe sees a request when one is made.
      assert :ok = S3Env.delete_prefix!("minio/0123456789abcdef")
      assert_received {:request, "GET", "/cyfr-test/", _}
    end

    test "a listing follows NextContinuationToken through every page", %{store: store} do
      put_keys(store, ["a/1", "b/2", "c/3", "c/4 &<x>"])

      assert S3Env.keys("") == ["a/1", "b/2", "c/3", "c/4 &<x>"]
      assert S3Env.keys("", max_keys: 1) == ["a/1", "b/2", "c/3", "c/4 &<x>"]
      assert S3Env.keys("c", max_keys: 1) == ["c/3", "c/4 &<x>"]

      # Four pages for the root at one key each, and the prefix sent with its slash.
      requests = drain()
      assert Enum.count(requests, &(&1 =~ "max-keys=1" and not (&1 =~ "prefix="))) == 4
      assert Enum.any?(requests, &(&1 =~ "prefix=c%2F"))
    end

    test "a listing that repeats its continuation token is refused", %{store: store} do
      put_keys(store, ["a/1", "a/2"])
      Agent.update(store, &Map.put(&1, :token, "same"))

      assert_raise RuntimeError, ~r/repeated its continuation token/, fn ->
        S3Env.keys("", max_keys: 1)
      end
    end

    test "the guard deletes its prefix and passes when only its own keys changed",
         %{store: store} do
      prefix = "minio/0123456789abcdef"
      peer = "parity/fedcba9876543210"
      put_keys(store, ["cluster-1/old", "#{peer}/x"])

      guard = S3Env.guard!(prefix, &hold/1)

      assert Enum.sort(keys(store)) == [
               "cluster-1/old",
               "#{prefix}/guard/1",
               "#{prefix}/guard/2",
               "#{peer}/x"
             ]

      # The run writes under its prefix; a concurrent run writes under its own.
      put_keys(store, ["#{prefix}/athanors/a", "#{peer}/y"])
      Agent.update(store, &%{&1 | keys: MapSet.delete(&1.keys, "#{peer}/x")})

      assert :ok = S3Env.clean!(guard)
      assert Enum.sort(keys(store)) == ["cluster-1/old", "#{peer}/y"]
    end

    test "the guard fails when a key outside every run prefix changed", %{store: store} do
      prefix = "minio/0123456789abcdef"
      put_keys(store, ["cluster-1/old"])
      guard = S3Env.guard!(prefix, &hold/1)

      put_keys(store, ["data/sig/plain.txt"])

      error = assert_raise ExUnit.AssertionError, fn -> S3Env.clean!(guard) end
      assert error.message =~ ~s(added ["data/sig/plain.txt"])

      # The cleanup ran before the check failed.
      refute Enum.any?(keys(store), &String.starts_with?(&1, prefix <> "/"))
    end

    test "the guard fails when a key outside every run prefix was deleted", %{store: store} do
      prefix = "minio/0123456789abcdef"
      put_keys(store, ["cluster-1/old", "publication/1790362542/x"])
      guard = S3Env.guard!(prefix, &hold/1)

      Agent.update(store, &%{&1 | keys: MapSet.delete(&1.keys, "cluster-1/old")})

      error = assert_raise ExUnit.AssertionError, fn -> S3Env.clean!(guard) end
      assert error.message =~ ~s(removed ["cluster-1/old"])
    end

    test "the guard fails when a key under its prefix survives the cleanup", %{store: store} do
      prefix = "minio/0123456789abcdef"
      guard = S3Env.guard!(prefix, &hold/1)
      Agent.update(store, &%{&1 | drop: false})

      error = assert_raise ExUnit.AssertionError, fn -> S3Env.clean!(guard) end
      assert error.message =~ "keys remain under #{prefix}"
    end

    test "the guard fails when its markers are gone", %{store: store} do
      prefix = "minio/0123456789abcdef"
      guard = S3Env.guard!(prefix, &hold/1)
      Agent.update(store, &%{&1 | keys: MapSet.delete(&1.keys, "#{prefix}/guard/2")})

      error = assert_raise ExUnit.AssertionError, fn -> S3Env.clean!(guard) end
      assert error.message =~ "markers are missing under #{prefix}"
    end

    test "the cleanup deletes only under its prefix when the store ignores the prefix",
         %{store: store} do
      prefix = "minio/0123456789abcdef"
      put_keys(store, ["cluster-1/old", "#{prefix}/a", "#{prefix}-other/x"])
      Agent.update(store, &Map.put(&1, :ignore_prefix, true))

      assert :ok = S3Env.delete_prefix!(prefix)

      assert Enum.sort(keys(store)) == ["cluster-1/old", "#{prefix}-other/x"]

      assert Enum.filter(drain(), &String.starts_with?(&1, "DELETE")) == [
               "DELETE /cyfr-test/#{prefix}/a?"
             ]
    end

    test "the guard registers its cleanup before it writes a marker", %{store: store} do
      prefix = "minio/0123456789abcdef"
      Agent.update(store, &Map.put(&1, :refuse, "#{prefix}/guard/2"))

      assert_raise RuntimeError, ~r/could not put a marker/, fn ->
        S3Env.guard!(prefix, &hold/1)
      end

      assert [{:cleanup, cleanup} | after_cleanup] =
               Enum.drop_while(mailbox(), &(elem(&1, 0) == :request))

      assert {:request, "PUT", "/cyfr-test/#{prefix}/guard/1", ""} in after_cleanup
      assert Enum.sort(keys(store)) == ["#{prefix}/guard/1"]

      # The marker that landed is deleted by the cleanup the failed guard left.
      assert_raise ExUnit.AssertionError, ~r/markers are missing/, cleanup
      assert keys(store) == []
    end
  end

  defp hold(cleanup), do: send(self(), {:cleanup, cleanup})

  defp mailbox do
    receive do
      message -> [message | mailbox()]
    after
      0 -> []
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp put_keys(store, keys),
    do: Agent.update(store, &%{&1 | keys: MapSet.union(&1.keys, MapSet.new(keys))})

  defp keys(store), do: Agent.get(store, &MapSet.to_list(&1.keys))

  defp drain do
    receive do
      {:request, method, path, query} -> ["#{method} #{path}?#{query}" | drain()]
    after
      0 -> []
    end
  end

  # ListObjectsV2 with `max-keys` paging, where the token is the last key
  # read, and which lists the whole bucket when `ignore_prefix` is set; PUT,
  # which answers 500 for the key `refuse` names; and DELETE, which keeps
  # the key when `drop` is false. Path-style only.
  defp serve(conn, store) do
    "/" <> path = conn.request_path
    key = path |> String.replace_prefix(@bucket, "") |> String.trim_leading("/") |> URI.decode()

    case {conn.method, key} do
      {"GET", ""} ->
        list(conn, store)

      {"PUT", key} ->
        if Agent.get(store, &Map.get(&1, :refuse)) == key do
          Plug.Conn.send_resp(conn, 500, "refused")
        else
          Agent.update(store, &%{&1 | keys: MapSet.put(&1.keys, key)})
          Plug.Conn.send_resp(conn, 200, "")
        end

      {"DELETE", key} ->
        Agent.update(store, fn
          %{drop: true} = state -> %{state | keys: MapSet.delete(state.keys, key)}
          state -> state
        end)

        Plug.Conn.send_resp(conn, 204, "")
    end
  end

  defp list(conn, store) do
    params = URI.decode_query(conn.query_string)
    state = Agent.get(store, & &1)
    prefix = if state[:ignore_prefix], do: "", else: Map.get(params, "prefix", "")
    max = params |> Map.get("max-keys", "1000") |> String.to_integer()
    # A fixed token answers the first page again, as a broken store would.
    after_key = if Map.has_key?(state, :token), do: nil, else: params["continuation-token"]

    matching =
      state.keys
      |> Enum.sort()
      |> Enum.filter(&(String.starts_with?(&1, prefix) and (after_key == nil or &1 > after_key)))

    {page, rest} = Enum.split(matching, max)
    token = Map.get(state, :token) || List.last(page)
    truncated = rest != []

    body =
      ~s(<?xml version="1.0" encoding="UTF-8"?><ListBucketResult>) <>
        Enum.map_join(page, &"<Contents><Key>#{escape(&1)}</Key></Contents>") <>
        "<IsTruncated>#{truncated}</IsTruncated>" <>
        if(truncated, do: "<NextContinuationToken>#{token}</NextContinuationToken>", else: "") <>
        "</ListBucketResult>"

    Plug.Conn.send_resp(conn, 200, body)
  end

  defp escape(key),
    do:
      key
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&#62;")
end
