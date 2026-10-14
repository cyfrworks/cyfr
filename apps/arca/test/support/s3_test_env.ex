# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Test.S3Env do
  @moduledoc """
  Where the `:s3_integration` suites get their store.

  Every setting is an environment variable with a default that names the
  MinIO container the `s3-minio` CI job starts, so an ordinary run needs
  no environment at all and a person can point the same suites at a real
  S3 bucket by setting them:

  | Variable | Default |
  |---|---|
  | `CYFR_TEST_S3_ENDPOINT` | `http://127.0.0.1:9000` |
  | `CYFR_TEST_S3_BUCKET` | `cyfr-test` |
  | `CYFR_TEST_S3_REGION` | `us-east-1` |
  | `CYFR_TEST_S3_ACCESS_KEY_ID` | `cyfrtest` |
  | `CYFR_TEST_S3_SECRET_ACCESS_KEY` | `cyfrtest123` |
  | `CYFR_TEST_S3_PATH_STYLE` | `true` (MinIO needs it; AWS S3 does not) |
  | `CYFR_TEST_S3_CREATE_BUCKET` | `true`; `false` where the bucket exists and the keys may not create one |

  The credentials in the defaults are the non-secret CI fixtures the
  workflow passes to its own container, mirrored here so the two cannot
  drift.

  `configure!/1` writes the `:s3` application environment the adapter
  reads and answers the previous value for a caller to restore. `prefix:`
  scopes a suite's keys under one name.

  ## A run's keys

  Every suite writes under `run_prefix/1`, `"<suite>/<digest>"`, whose
  digest is unique to one checkout, run and partition, so two runs against
  one bucket never meet and a suite deletes only what its own run wrote.
  `guard!/2` brackets a suite: it records the keys outside every run
  prefix and registers `clean!/1` in the suite's `on_exit`, which deletes
  the suite's prefix through `delete_prefix!/1` and fails when anything
  outside it changed or anything under it remains. They sign their own
  requests, as `create_bucket!/0` does, because the adapter builds every
  key under an actor's segments and cannot list the bucket root.
  """

  @defaults %{
    endpoint: {"CYFR_TEST_S3_ENDPOINT", "http://127.0.0.1:9000"},
    bucket: {"CYFR_TEST_S3_BUCKET", "cyfr-test"},
    region: {"CYFR_TEST_S3_REGION", "us-east-1"},
    access_key_id: {"CYFR_TEST_S3_ACCESS_KEY_ID", "cyfrtest"},
    secret_access_key: {"CYFR_TEST_S3_SECRET_ACCESS_KEY", "cyfrtest123"}
  }

  @checkout Path.expand("../../../..", __DIR__)

  @doc "The adapter configuration this run's store is reached with."
  @spec config(keyword()) :: keyword()
  def config(opts \\ []) do
    settings =
      for {key, {variable, default}} <- @defaults, do: {key, System.get_env(variable, default)}

    Keyword.merge(settings,
      path_style: env_flag("CYFR_TEST_S3_PATH_STYLE", true),
      prefix: Keyword.get(opts, :prefix)
    )
  end

  @doc """
  This run's key prefix for `suite`: `run_prefix/2` over
  `CYFR_TEST_RUN_ROOT`, which the partition runner sets per checkout, run
  and partition. A direct `mix test` has none, so its root is the checkout,
  the OS pid and a random token minted once per VM.
  """
  @spec run_prefix(String.t()) :: String.t()
  def run_prefix(suite) do
    case System.get_env("CYFR_TEST_RUN_ROOT") do
      root when is_binary(root) and root != "" -> run_prefix(suite, root)
      _ -> run_prefix(suite, direct_root())
    end
  end

  @doc """
  `"<suite>/<digest>"`, where `digest` is the first 16 hex digits of
  SHA-256 over `root`. `suite` is lowercase letters only, so every run
  prefix has the one shape `clean!/1` tells apart from other keys.
  """
  @spec run_prefix(String.t(), String.t()) :: String.t()
  def run_prefix(suite, root) when is_binary(suite) and is_binary(root) do
    unless Regex.match?(~r/\A[a-z]+\z/, suite),
      do: raise(ArgumentError, "a suite name is lowercase letters only, got: #{inspect(suite)}")

    digest = :sha256 |> :crypto.hash(root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "#{suite}/#{digest}"
  end

  # Minted under a lock so two first callers cannot mint two tokens; a VM
  # that answered two prefixes would leave the first one's keys behind.
  defp direct_root do
    with nil <- :persistent_term.get({__MODULE__, :direct_root}, nil) do
      :global.trans(
        {{__MODULE__, :direct_root}, self()},
        fn ->
          with nil <- :persistent_term.get({__MODULE__, :direct_root}, nil) do
            token = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
            minted = Enum.join([@checkout, System.pid(), token], ":")
            :persistent_term.put({__MODULE__, :direct_root}, minted)
            minted
          end
        end,
        [node()]
      )
    end
  end

  @doc """
  Point the adapter at this run's store, answering what `:s3` held before
  so a caller's `on_exit` can put it back.
  """
  @spec configure!(keyword()) :: keyword() | nil
  def configure!(opts \\ []) do
    previous = Application.get_env(:arca, :s3)
    Application.put_env(:arca, :s3, config(opts))
    previous
  end

  @doc "Put `:s3` back to what `configure!/1` answered."
  @spec restore(keyword() | nil) :: :ok
  def restore(nil), do: Application.delete_env(:arca, :s3)
  def restore(previous), do: Application.put_env(:arca, :s3, previous)

  @doc """
  Create the bucket unless `CYFR_TEST_S3_CREATE_BUCKET` says not to — a
  bucket that already exists answers 409, and both outcomes leave a
  usable bucket. A store that refuses raises with its own error code,
  which is the whole diagnosis: `SignatureDoesNotMatch`,
  `InvalidAccessKeyId` and `AccessDenied` are all 403 and have nothing
  to do with each other.
  """
  @spec create_bucket!() :: :ok
  def create_bucket! do
    if env_flag("CYFR_TEST_S3_CREATE_BUCKET", true), do: put_bucket!(), else: :ok
  end

  defp put_bucket! do
    %{status: status, body: body} = signed!(:put, "", "")

    if status in [200, 409],
      do: :ok,
      else: raise("could not create bucket #{config()[:bucket]}: HTTP #{status} #{inspect(body)}")
  end

  @doc """
  Every key under `prefix/`, or every key in the bucket for `""`, following
  `NextContinuationToken` until the listing is no longer truncated.
  `max_keys:` sets the page size the store answers with.
  """
  @spec keys(String.t(), keyword()) :: [String.t()]
  def keys(prefix, opts \\ []) when is_binary(prefix) do
    listed = if prefix == "", do: [], else: [{"prefix", prefix <> "/"}]

    listed =
      case Keyword.get(opts, :max_keys) do
        nil -> listed
        max when is_integer(max) and max > 0 -> [{"max-keys", Integer.to_string(max)} | listed]
      end

    list_pages(listed, nil, [], MapSet.new())
  end

  defp list_pages(params, token, acc, seen) do
    # SigV4 canonicalizes the query in sorted order; send it that way.
    query =
      (if(token, do: [{"continuation-token", token}], else: []) ++
         [{"list-type", "2"} | params])
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode(v, &URI.char_unreserved?/1)}" end)

    body =
      case signed!(:get, "?" <> query, "") do
        %{status: 200, body: body} -> body
        %{status: status, body: body} -> raise "could not list: HTTP #{status} #{inspect(body)}"
      end

    acc = [Enum.map(Regex.scan(~r{<Key>([^<]*)</Key>}, body), &xml_text(Enum.at(&1, 1))) | acc]

    with true <- String.contains?(body, "<IsTruncated>true</IsTruncated>"),
         [_, next] <- Regex.run(~r{<NextContinuationToken>([^<]+)</NextContinuationToken>}, body) do
      next = xml_text(next)

      if MapSet.member?(seen, next),
        do: raise("the listing repeated its continuation token #{inspect(next)}")

      list_pages(params, next, acc, MapSet.put(seen, next))
    else
      _ -> acc |> Enum.reverse() |> List.flatten()
    end
  end

  @doc """
  Delete every key under `prefix/`. Only a run prefix, `"<suite>/<digest>"`,
  is accepted: a blank prefix or one without a digest is refused before any
  request, because it would reach keys another run or another suite owns.
  A listed key outside `prefix/` is not deleted, so a store that ignores
  the listing's `prefix` parameter cannot empty the bucket.
  """
  @spec delete_prefix!(String.t()) :: :ok
  def delete_prefix!(prefix) do
    run_prefix!(prefix)

    for key <- keys(prefix), String.starts_with?(key, prefix <> "/") do
      case signed!(:delete, encode_key(key), "") do
        %{status: status} when status in [200, 204, 404] ->
          :ok

        %{status: status, body: body} ->
          raise "could not delete #{key}: HTTP #{status} #{inspect(body)}"
      end
    end

    :ok
  end

  @doc """
  Watch the bucket for a suite that writes under `prefix`, from its
  `setup_all` or `setup`: record the keys outside every run prefix,
  register `clean!/1` through `register` (the suite's `on_exit` unless a
  caller passes its own), then put two markers under `prefix`, so
  `clean!/1` always has something to delete and more than one page to
  read. The cleanup is registered before the first marker, so a marker
  that fails to land leaves nothing behind. Answers what `clean!/1` takes.
  """
  @spec guard!(String.t(), ((-> term()) -> term())) :: %{
          prefix: String.t(),
          outside: MapSet.t(String.t())
        }
  def guard!(prefix, register \\ &ExUnit.Callbacks.on_exit/1) do
    run_prefix!(prefix)
    guard = %{prefix: prefix, outside: outside(keys(""))}
    register.(fn -> clean!(guard) end)

    for marker <- ["1", "2"] do
      case signed!(:put, encode_key("#{prefix}/guard/#{marker}"), "") do
        %{status: 200} ->
          :ok

        %{status: status, body: body} ->
          raise "could not put a marker: HTTP #{status} #{inspect(body)}"
      end
    end

    guard
  end

  @doc """
  Delete the guarded prefix and check what the run left, from the suite's
  `on_exit` that `guard!/2` registers, which runs whether or not its tests
  passed. It fails when the keys outside every run prefix differ from what
  `guard!/2` recorded, when a key remains under the prefix, or when the prefix read one key per page
  differs from the prefix read whole. Keys under another run's prefix are
  not compared: a concurrent run writes there.
  """
  @spec clean!(%{prefix: String.t(), outside: MapSet.t(String.t())}) :: :ok
  def clean!(%{prefix: prefix, outside: before}) do
    # The one-key-per-page read covers the own prefix, not the root: a
    # shared bucket holds thousands of keys from earlier runs, and paging
    # the root one key at a time would cost a request per key on every
    # guard. The two markers make this read span pages all the same.
    whole = keys(prefix)
    paged = keys(prefix, max_keys: 1)
    :ok = delete_prefix!(prefix)
    remaining = keys("")

    # The markers make the paged read span pages and the cleanup delete
    # something; without them both checks below could pass on nothing.
    ExUnit.Assertions.assert(
      Enum.all?(["1", "2"], &("#{prefix}/guard/#{&1}" in whole)),
      message: "the guard's markers are missing under #{prefix}: #{inspect(whole)}"
    )

    ExUnit.Assertions.assert(Enum.sort(paged) == Enum.sort(whole),
      message:
        "#{prefix} read one key per page is #{inspect(paged)}, read whole #{inspect(whole)}"
    )

    ExUnit.Assertions.assert(outside(remaining) == before,
      message:
        "keys outside every run prefix changed: added " <>
          "#{inspect(MapSet.difference(outside(remaining), before) |> Enum.sort())}, removed " <>
          inspect(MapSet.difference(before, outside(remaining)) |> Enum.sort())
    )

    ExUnit.Assertions.assert(
      Enum.filter(remaining, &String.starts_with?(&1, prefix <> "/")) == [],
      message: "keys remain under #{prefix}"
    )

    :ok
  end

  defp outside(keys),
    do: keys |> Enum.reject(&Regex.match?(~r"^[a-z]+/[0-9a-f]{16}/", &1)) |> MapSet.new()

  defp run_prefix!(prefix) do
    unless is_binary(prefix) and Regex.match?(~r"\A[a-z]+/[0-9a-f]{16}\z", prefix),
      do: raise(ArgumentError, "not a run prefix: #{inspect(prefix)}")

    :ok
  end

  # One signed request to the bucket, addressed as the adapter addresses it
  # (`path_style`). Only the host is passed in: sign_v4 supplies
  # X-Amz-Content-SHA256 for the body it hashes, and a second copy signs the
  # name twice (see Arca.Adapters.S3).
  defp signed!(method, suffix, body) do
    settings = config()
    endpoint = String.trim_trailing(settings[:endpoint], "/")

    url =
      if settings[:path_style] do
        "#{endpoint}/#{settings[:bucket]}" <> if(suffix == "", do: "", else: "/" <> suffix)
      else
        %URI{scheme: scheme, authority: authority} = URI.parse(endpoint)
        "#{scheme}://#{settings[:bucket]}.#{authority}/#{suffix}"
      end

    signed =
      :aws_signature.sign_v4(
        settings[:access_key_id],
        settings[:secret_access_key],
        settings[:region],
        "s3",
        :calendar.universal_time(),
        method |> Atom.to_string() |> String.upcase(),
        url,
        [{"host", URI.parse(url).authority}],
        body,
        # S3 does not re-encode its canonical URI; see Arca.Adapters.S3.
        [{:uri_encode_path, false}]
      )

    {:ok, response} =
      Req.request(
        method: method,
        url: url,
        headers: Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end),
        body: body,
        decode_body: false,
        retry: false
      )

    response
  end

  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  # A key or token is XML text: undo the predefined and numeric entities.
  defp xml_text(text) do
    Regex.replace(~r/&(lt|gt|quot|apos|amp|#x[0-9a-fA-F]+|#[0-9]+);/, text, fn
      _, "lt" -> "<"
      _, "gt" -> ">"
      _, "quot" -> "\""
      _, "apos" -> "'"
      _, "amp" -> "&"
      _, "#x" <> hex -> <<String.to_integer(hex, 16)::utf8>>
      _, "#" <> dec -> <<String.to_integer(dec)::utf8>>
    end)
  end

  defp env_flag(variable, default) do
    case System.get_env(variable) do
      nil -> default
      value -> String.downcase(value) in ["1", "true", "yes"]
    end
  end
end
