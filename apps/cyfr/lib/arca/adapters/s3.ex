# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Adapters.S3 do
  @moduledoc """
  S3-compatible object storage adapter for Arca.

  Opt-in via `:cyfr, :storage_adapter, Arca.Adapters.S3` at runtime.
  Implements the `Arca.Storage` behaviour. Routes Arca paths to S3 keys
  under a configurable bucket and prefix. Compatible with AWS S3, MinIO,
  Cloudflare R2, Wasabi, and any S3-API service.

  ## Path Scoping

  Mirrors `Arca.Adapters.Local` exactly: both adapters join
  `Arca.Storage.physical_segments/2` under one root, so a key generated
  against one decodes identically against the other —
  `<prefix>/athanors/{athanor_id}/<scope>/<rest>` for every tenant scope
  in `Arca.Storage.tenant_roots/0` (`components/`, `guest/`, `aqua/`, …)
  and the globals `<prefix>/cache/<rest>`, `<prefix>/system/<rest>`.

  An S3 deployment is not a whole-box backup: the bucket holds Arca
  objects; the volume still holds the database and the sidecars'
  files (`data/cyfr.db`, `data/mcp-bridge/`).

  The `athanors/` root keeps every tenant key disjoint from the global
  roots, so an athanor id that happens to equal a reserved root name can
  never collide with it inside the bucket. Seed media never reaches the
  bucket — `Arca` reads each root from local disk
  (`Arca.Storage.seed_roots/0`). `namespace` is identity-only and is not
  part of the path.

  This adapter never filters the Local adapter's `.tmp.<n>` write-marker
  shape: the facade reserves it on every segment of every write, so the
  bucket never gains one — and any pre-reservation offender stays visible,
  listed and counted (a visible object cannot evade the storage cap) until
  deleted.

  ## Append semantics

  S3 has no atomic append. `append/3` reads the object, extends it and writes
  it back, so one path stays one object and `get/2`, `exists?/2`, `delete/2`
  and `usage/2` all see what was appended — the same shape the Local adapter
  has. Two consequences follow from the read-modify-write, and neither applies
  to Local's `O_APPEND` write: concurrent appends to one path are
  last-writer-wins, and an append is refused once the object would pass 5 MiB
  (the DEFAULT node `max_response_size`, above which a guest cannot read the
  object back anyway — a node whose manifest raises its own response limit
  does not raise this ceiling; the two deliberately track only the default).

  ## Configuration

      config :cyfr,
        storage_adapter: Arca.Adapters.S3

  Runtime env:

  - `CYFR_S3_BUCKET` — required
  - `CYFR_S3_REGION` — required (e.g. `"us-east-1"`)
  - `CYFR_S3_ENDPOINT` — optional (default `https://s3.<region>.amazonaws.com`);
    set to `http://localhost:9000` for MinIO, `https://<account>.r2.cloudflarestorage.com` for R2
  - `CYFR_S3_ACCESS_KEY_ID` / `CYFR_S3_SECRET_ACCESS_KEY` — required
  - `CYFR_S3_PREFIX` — optional key prefix shared across all writes (e.g. `cyfr/prod`)
  - `CYFR_S3_PATH_STYLE` — `"true"` to use path-style URLs (required by MinIO; default `false` for AWS S3)
  """

  @behaviour Arca.Storage

  require Logger
  alias Sanctum.Context

  @service "s3"

  # An append here is a read-modify-write, so repeated appends to one path cost
  # O(size) each. The ceiling is the default node `max_response_size` — the size
  # past which the guest `read` action already declines to return the object —
  # so refusing here takes away nothing a caller could otherwise read back.
  @max_append_bytes Sanctum.Limits.default_max_response_size()

  @impl true
  def get(%Context{} = ctx, segments) do
    case request(:get, build_key(ctx, segments)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> log_and_error("get", status, body)
      {:error, reason} -> log_and_error("get", reason)
    end
  end

  @impl true
  def put(%Context{} = ctx, segments, content) do
    Arca.Storage.refuse_seed_write!(segments)

    case request(:put, build_key(ctx, segments), content) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> log_and_error("put", status, body)
      {:error, reason} -> log_and_error("put", reason)
    end
  end

  @impl true
  def append(%Context{} = ctx, segments, content) do
    Arca.Storage.refuse_seed_write!(segments)

    with {:ok, existing} <- read_for_append(ctx, segments) do
      merged = existing <> content

      if byte_size(merged) > @max_append_bytes do
        {:error, :object_too_large}
      else
        put(ctx, segments, merged)
      end
    end
  end

  # A missing object is an empty one: appending to a path that does not exist
  # yet creates it, matching the local filesystem's `File.write(:append)`.
  defp read_for_append(ctx, segments) do
    case get(ctx, segments) do
      {:ok, body} -> {:ok, body}
      {:error, :not_found} -> {:ok, ""}
      {:error, _reason} = err -> err
    end
  end

  @impl true
  def delete(%Context{} = ctx, segments) do
    Arca.Storage.refuse_seed_write!(segments)
    key = build_key(ctx, segments)

    # Real S3 answers 204 even for a key that never existed, so a bare DELETE
    # cannot tell "deleted" from "was never there" — probe first, and a
    # missing file is `{:error, :not_found}` on both adapters.
    case request(:head, key) do
      {:ok, %{status: 200}} ->
        case request(:delete, key) do
          {:ok, %{status: status}} when status in [200, 204] -> :ok
          {:ok, %{status: 404}} -> {:error, :not_found}
          {:ok, %{status: status, body: body}} -> log_and_error("delete", status, body)
          {:error, reason} -> log_and_error("delete", reason)
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        log_and_error("delete", status, body)

      {:error, reason} ->
        log_and_error("delete", reason)
    end
  end

  @impl true
  def list_typed(%Context{} = ctx, segments) do
    prefix = build_key(ctx, segments)

    case list_keys(prefix) do
      {:ok, []} ->
        # Nothing below the prefix. Either the path does not exist, or it is an
        # object itself — the local adapter's `File.ls` says `:enotdir` for the
        # latter, and one HEAD on an already-empty listing keeps the two
        # adapters answering the same thing.
        if exists?(ctx, segments), do: {:error, :enotdir}, else: {:ok, []}

      {:ok, keys} ->
        {:ok, entries_under(prefix, keys)}

      {:error, reason} ->
        log_and_error("list", reason)
    end
  end

  @impl true
  def exists?(%Context{} = ctx, segments) do
    case request(:head, build_key(ctx, segments)) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @impl true
  def delete_tree(%Context{} = ctx, segments) do
    Arca.Storage.refuse_seed_write!(segments)
    prefix = build_key(ctx, segments)

    # An object can sit AT the tree's own key (Local's rm_rf removes it, and
    # the listing below only sees keys under `prefix/`) — delete it
    # explicitly; missing is the normal case and fine.
    with :ok <- delete_tolerating_missing("delete_tree", prefix) do
      case list_keys(prefix) do
        {:ok, []} ->
          :ok

        {:ok, keys} ->
          # DeleteObjects (POST ?delete) takes up to 1000 keys per request —
          # one round-trip per batch instead of one per key.
          keys
          |> Enum.chunk_every(1000)
          |> Enum.reduce_while(:ok, fn batch, _acc ->
            case delete_objects_batch(batch) do
              :ok -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        {:error, reason} ->
          log_and_error("delete_tree", reason)
      end
    end
  end

  defp delete_objects_batch(keys) do
    body =
      "<Delete><Quiet>true</Quiet>" <>
        Enum.map_join(keys, "", fn key -> "<Object><Key>#{xml_escape(key)}</Key></Object>" end) <>
        "</Delete>"

    case request_bucket_post("delete=", body) do
      {:ok, %{status: 200, body: resp}} ->
        # Quiet mode answers only the failures; any <Error> element means
        # part of the batch survived.
        if resp =~ "<Error>",
          do: log_and_error("delete_tree", {:s3_delete_objects, resp}),
          else: :ok

      {:ok, %{status: status, body: resp}} ->
        log_and_error("delete_tree", status, resp)

      {:error, reason} ->
        log_and_error("delete_tree", reason)
    end
  end

  defp delete_tolerating_missing(op, key) do
    case request(:delete, key) do
      {:ok, %{status: status}} when status in [200, 204, 404] -> :ok
      {:ok, %{status: status, body: body}} -> log_and_error(op, status, body)
      {:error, reason} -> log_and_error(op, reason)
    end
  end

  @impl true
  def list_recursive(%Context{} = ctx, segments) do
    prefix_key = build_key(ctx, segments)
    prefix_with_slash = prefix_key <> "/"

    case list_keys(prefix_key) do
      {:ok, keys} ->
        leaves =
          for key <- keys,
              String.starts_with?(key, prefix_with_slash),
              # A key ending in "/" is a console-written directory marker,
              # not content — the Local adapter has no such object, and a
              # walk that reported one would hand back an unreadable leaf.
              not String.ends_with?(key, "/") do
            relative = String.replace_prefix(key, prefix_with_slash, "")

            case String.split(relative, "/", trim: true) do
              [] -> nil
              rel_segments -> segments ++ rel_segments
            end
          end

        {:ok, Enum.reject(leaves, &is_nil/1)}

      {:error, reason} ->
        log_and_error("list_recursive", reason)
    end
  end

  @impl true
  def usage(%Context{} = ctx, segments) do
    prefix_key = build_key(ctx, segments)
    prefix_with_slash = prefix_key <> "/"

    case list_entries(prefix_key) do
      {:ok, entries} ->
        # Directory markers (keys ending "/") are not files — the Local
        # adapter's walk never counts a directory either.
        sizes =
          for {key, size} <- entries,
              String.starts_with?(key, prefix_with_slash),
              not String.ends_with?(key, "/"),
              do: size

        {:ok, %{files: length(sizes), bytes: Enum.sum(sizes)}}

      {:error, reason} ->
        log_and_error("usage", reason)
    end
  end

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, segments, opts) do
    status = Keyword.get(opts, :status, 200)

    # Buffer-and-send: simple and correct, fits manifests + tincture HTML
    # well. Streaming via `send_chunked` + `Req`'s `:into` callback is the
    # next-step optimization for very large assets — defer until profiling
    # shows the buffered path matters in practice.
    case get(ctx, segments) do
      {:ok, body} -> {:ok, Plug.Conn.send_resp(conn, status, body)}
      {:error, _} = err -> err
    end
  end

  # ============================================================================
  # Private — key construction
  # ============================================================================

  # The adapter's one validation chokepoint: every callback reaches it
  # before any request (append and serve via get), so `validate_path!/1`
  # runs exactly once per operation.
  defp build_key(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)
    base = Arca.Storage.physical_segments(ctx, segments)

    case prefix() do
      nil -> Enum.join(base, "/")
      "" -> Enum.join(base, "/")
      pfx -> Enum.join([String.trim(pfx, "/") | base], "/")
    end
  end

  # ============================================================================
  # Private — HTTP / SigV4
  # ============================================================================

  # Sign and send one request. Everything S3-bound goes through here: one
  # header set, one SigV4 signing, one Req call — an operation contributes
  # only its method, URL, body, and any extra headers the signature must
  # cover. Transport policy is explicit: `retry: false` (callers own retry,
  # same as Cyfr.Network's outbound path — Req's silent :safe_transient
  # default re-sent GETs up to three times) and a configured receive
  # timeout instead of Req's unstated 15s.
  defp signed_request(method, url, body, extra_headers \\ []) do
    base_headers =
      [{"host", host_for(url)}, {"x-amz-content-sha256", sha256_hex(body)}] ++ extra_headers

    signed =
      :aws_signature.sign_v4(
        config!(:access_key_id),
        config!(:secret_access_key),
        config!(:region),
        @service,
        :calendar.universal_time(),
        method_string(method),
        url,
        base_headers,
        body,
        []
      )

    headers = Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end)

    Req.request(
      method: method,
      url: url,
      headers: headers,
      body: body,
      decode_body: false,
      retry: false,
      receive_timeout: Application.get_env(:cyfr, :s3_receive_timeout_ms, 60_000)
    )
  end

  defp request(method, key, body \\ ""), do: signed_request(method, build_url(key), body)

  # A bucket-level POST (DeleteObjects). Content-MD5 is required by S3 for
  # this operation and rides inside the signature.
  defp request_bucket_post(query, body) do
    signed_request(:post, bucket_query_url(query), body, [
      {"content-md5", Base.encode64(:crypto.hash(:md5, body))}
    ])
  end

  # ListObjectsV2 caps each response at 1000 keys, so every enumeration must
  # follow NextContinuationToken until IsTruncated goes false — otherwise
  # component scans and tree deletions silently stop at the first page. The
  # parser is the only thing the two enumerations (bare keys; key+size
  # entries) do differently.
  defp list_keys(prefix), do: list_pages(prefix, &parse_list_keys/1, nil, [], MapSet.new())

  defp list_entries(prefix), do: list_pages(prefix, &parse_list_entries/1, nil, [], MapSet.new())

  defp list_pages(prefix, parser, token, acc, seen_tokens) do
    case request_list_page(prefix, token) do
      {:ok, body} ->
        # Pages accumulate newest-first and flatten once at the end —
        # appending per page would re-copy the whole accumulator each time.
        acc = [parser.(body) | acc]

        case next_continuation_token(body) do
          nil ->
            {:ok, acc |> Enum.reverse() |> List.flatten()}

          next ->
            if MapSet.member?(seen_tokens, next) do
              # A repeated token would loop forever; treat it as a bad server.
              {:error, {:s3_list_repeated_token, next}}
            else
              list_pages(prefix, parser, next, acc, MapSet.put(seen_tokens, next))
            end
        end

      {:error, _} = error ->
        error
    end
  end

  # The inverse of xml_unescape/1, for keys carried inside a request body.
  defp xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp request_list_page(prefix, token) do
    # Params assembled in canonical (sorted) order for SigV4.
    params =
      if(token, do: [{"continuation-token", token}], else: []) ++
        [{"list-type", "2"}, {"prefix", prefix <> "/"}]

    query =
      Enum.map_join(params, "&", fn {k, v} ->
        "#{k}=#{URI.encode(v, &URI.char_unreserved?/1)}"
      end)

    case signed_request(:get, bucket_query_url(query), "") do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_list, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The one level directly under `prefix`, with each name's kind. A key that
  # still has a `/` after the prefix names a directory; one that does not names
  # a file. This is also how the zero-byte `foo/` directory markers some
  # consoles write are read as directories rather than as empty files.
  #
  # A name that is both — an object at `prefix/foo` with objects under
  # `prefix/foo/` — is a directory: it has children, and that is what a caller
  # walking the tree needs to know.
  defp entries_under(prefix, keys) do
    prefix_with_slash = prefix <> "/"

    pairs =
      Enum.flat_map(keys, fn key ->
        case String.split(key, prefix_with_slash, parts: 2) do
          [_, rest] ->
            case String.split(rest, "/", parts: 2) do
              [""] -> []
              [name] -> [{name, :file}]
              [name, _below] -> [{name, :dir}]
            end

          _ ->
            []
        end
      end)

    kinds =
      Enum.reduce(pairs, %{}, fn {name, kind}, acc ->
        Map.update(acc, name, kind, fn
          :dir -> :dir
          _ -> kind
        end)
      end)

    # Keys arrive lexicographically; keep that order rather than a map's.
    pairs
    |> Enum.map(fn {name, _kind} -> name end)
    |> Enum.uniq()
    |> Enum.map(&{&1, Map.fetch!(kinds, &1)})
  end

  # Minimal XML extraction — full XML parsing isn't needed for ListObjectsV2.
  defp parse_list_keys(body) do
    Regex.scan(~r{<Key>([^<]+)</Key>}, body)
    |> Enum.map(fn [_, key] -> xml_unescape(key) end)
  end

  # Every <Contents> element carries Key then Size in document order.
  defp parse_list_entries(body) do
    Regex.scan(~r{<Contents>.*?<Key>([^<]+)</Key>.*?<Size>(\d+)</Size>.*?</Contents>}s, body)
    |> Enum.map(fn [_, key, size] -> {xml_unescape(key), String.to_integer(size)} end)
  end

  defp next_continuation_token(body) do
    with true <- String.contains?(body, "<IsTruncated>true</IsTruncated>"),
         [_, token] <- Regex.run(~r{<NextContinuationToken>([^<]+)</NextContinuationToken>}, body) do
      xml_unescape(token)
    else
      _ -> nil
    end
  end

  # Tokens/keys are XML text nodes; undo the five predefined entities.
  defp xml_unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  # ============================================================================
  # Private — URL / config helpers
  # ============================================================================

  # Path-style: <endpoint>/<bucket>/<suffix> — virtual-host:
  # <bucket>.<endpoint>/<suffix>. The one place the two addressing styles
  # are spelled out.
  defp bucket_url(suffix) do
    bucket = config!(:bucket)
    base = endpoint_base()

    if path_style?() do
      "#{base}/#{bucket}/#{suffix}"
    else
      "#{scheme(base)}://#{bucket}.#{host_only(base)}/#{suffix}"
    end
  end

  defp build_url(key), do: bucket_url(encode_key(key))

  defp bucket_query_url(query), do: bucket_url("?" <> query)

  defp endpoint_base do
    case config(:endpoint) do
      nil ->
        "https://s3.#{config!(:region)}.amazonaws.com"

      endpoint ->
        endpoint |> String.trim_trailing("/")
    end
  end

  defp scheme("https://" <> _), do: "https"
  defp scheme("http://" <> _), do: "http"
  defp scheme(_), do: "https"

  defp host_only("https://" <> rest), do: String.split(rest, "/", parts: 2) |> List.first()
  defp host_only("http://" <> rest), do: String.split(rest, "/", parts: 2) |> List.first()
  defp host_only(other), do: other

  # RFC 9110 §7.2: the Host header carries the port when it is not the
  # scheme default. SigV4 stays valid either way (the signer canonicalizes
  # the header we send, and the server verifies against what arrived), but
  # dropping the port disagreed with `host_only/1`'s virtual-host URLs and
  # broke any vhost-routing proxy in front of a non-default-port endpoint.
  defp host_for(url) do
    case URI.parse(url) do
      %URI{host: host, port: port, scheme: scheme}
      when is_integer(port) and is_binary(scheme) ->
        if URI.default_port(scheme) == port, do: host, else: "#{host}:#{port}"

      %URI{host: host} ->
        host
    end
  end

  defp encode_key(key) do
    key
    |> String.split("/")
    |> Enum.map(fn part -> URI.encode(part, &URI.char_unreserved?/1) end)
    |> Enum.join("/")
  end

  defp path_style?, do: config(:path_style) in [true, "true"]

  defp prefix, do: config(:prefix)

  defp method_string(:get), do: "GET"
  defp method_string(:put), do: "PUT"
  defp method_string(:post), do: "POST"
  defp method_string(:delete), do: "DELETE"
  defp method_string(:head), do: "HEAD"

  defp sha256_hex(""), do: :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
  defp sha256_hex(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp config(key) do
    Application.get_env(:cyfr, :s3, [])[key]
  end

  defp config!(key) do
    case config(key) do
      nil ->
        raise """
        [Arca.S3] Required config :s3, #{inspect(key)} is not set.
        Set CYFR_S3_#{key |> Atom.to_string() |> String.upcase()} in your environment.
        """

      val ->
        val
    end
  end

  defp log_and_error(op, reason) do
    Logger.warning("[Arca.S3.#{op}] error=#{inspect(reason)}")
    {:error, reason}
  end

  defp log_and_error(op, status, body) do
    Logger.warning("[Arca.S3.#{op}] status=#{status} body=#{inspect(body)}")
    {:error, {:s3_error, status}}
  end
end
