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

  Mirrors `Arca.Adapters.Local` — same `Arca.Storage.tenant_segments/1`
  shape feeds both adapters so a path generated against one decodes
  identically against the other:

  - **Component paths** (`["components" | rest]`) → `<prefix>/components/<rest>`
  - **Global paths** (`["cache" | rest]`, `["system" | rest]`) → `<prefix>/cache/<rest>`,
    `<prefix>/system/<rest>` (not tenant-scoped)
  - **Tenant-scoped paths** (everything else) → `<prefix>/data/{athanor_id}/<rest>`

  The `data/` root keeps tenant storage in its own top-level namespace —
  mirroring the Local adapter's `data/` base directory and keeping it disjoint
  from the `components/`/`cache/` roots, so an athanor id that happens
  to equal a reserved root name can never collide with it inside the bucket.
  `namespace` is identity-only and is not part of the path.

  ## Append semantics

  S3 has no atomic append. `append/3` reads the object, extends it and writes
  it back, so one path stays one object and `get/2`, `exists?/2`, `delete/2`
  and `usage/2` all see what was appended — the same shape the Local adapter
  has. Two consequences follow from the read-modify-write, and neither applies
  to Local's `O_APPEND` write: concurrent appends to one path are
  last-writer-wins, and an append is refused once the object would pass 5 MiB
  (the default node `max_response_size`, above which a guest cannot read the
  object back anyway).

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
  @max_append_bytes 5_242_880

  @impl true
  def get(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)

    case request(:get, build_key(ctx, segments)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: 403}} -> {:error, :permission_denied}
      {:ok, %{status: status, body: body}} -> log_and_error("get", status, body)
      {:error, reason} -> log_and_error("get", reason)
    end
  end

  @impl true
  def put(%Context{} = ctx, segments, content) do
    Arca.Storage.validate_path!(segments)

    case request(:put, build_key(ctx, segments), content) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 403}} -> {:error, :permission_denied}
      {:ok, %{status: status, body: body}} -> log_and_error("put", status, body)
      {:error, reason} -> log_and_error("put", reason)
    end
  end

  @impl true
  def append(%Context{} = ctx, segments, content) do
    Arca.Storage.validate_path!(segments)

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
    Arca.Storage.validate_path!(segments)

    case request(:delete, build_key(ctx, segments)) do
      # S3 returns 204 No Content on successful delete; 404 means already gone.
      # Both are :ok here to match the Local adapter's idempotent semantics
      # (Local treats :enoent on delete as `{:error, :not_found}` though, so
      #  preserve that for consistency).
      {:ok, %{status: 204}} -> :ok
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> log_and_error("delete", status, body)
      {:error, reason} -> log_and_error("delete", reason)
    end
  end

  @impl true
  def list(%Context{} = ctx, segments) do
    with {:ok, entries} <- list_typed(ctx, segments) do
      {:ok, Enum.map(entries, fn {name, _kind} -> name end)}
    end
  end

  @impl true
  def list_typed(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)
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
    Arca.Storage.validate_path!(segments)

    case request(:head, build_key(ctx, segments)) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @impl true
  def delete_tree(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)
    prefix = build_key(ctx, segments)

    case list_keys(prefix) do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        # S3 supports DeleteObjects (POST ?delete) for batches of up to 1000.
        # Single-key DELETEs keep the implementation simple; for large trees
        # we'd batch — defer until profiling shows it matters.
        Enum.reduce_while(keys, :ok, fn key, _acc ->
          case request(:delete, key) do
            {:ok, %{status: status}} when status in [200, 204, 404] ->
              {:cont, :ok}

            {:ok, %{status: status, body: body}} ->
              {:halt, log_and_error("delete_tree", status, body)}

            {:error, reason} ->
              {:halt, log_and_error("delete_tree", reason)}
          end
        end)

      {:error, reason} ->
        log_and_error("delete_tree", reason)
    end
  end

  @impl true
  def list_recursive(%Context{} = ctx, segments) do
    Arca.Storage.validate_path!(segments)
    prefix_key = build_key(ctx, segments)
    prefix_with_slash = prefix_key <> "/"

    case list_keys(prefix_key) do
      {:ok, keys} ->
        leaves =
          for key <- keys, String.starts_with?(key, prefix_with_slash) do
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
    Arca.Storage.validate_path!(segments)
    prefix_key = build_key(ctx, segments)
    prefix_with_slash = prefix_key <> "/"

    case list_entries(prefix_key) do
      {:ok, entries} ->
        sizes = for {key, size} <- entries, String.starts_with?(key, prefix_with_slash), do: size
        {:ok, %{files: length(sizes), bytes: Enum.sum(sizes)}}

      {:error, reason} ->
        log_and_error("usage", reason)
    end
  end

  @impl true
  def read_subtree(%Context{} = ctx, segments) do
    with {:ok, leaf_segments} <- list_recursive(ctx, segments) do
      max_concurrency = Application.get_env(:cyfr, :s3_read_subtree_concurrency, 10)

      results =
        leaf_segments
        |> Task.async_stream(
          fn segs ->
            case get(ctx, segs) do
              {:ok, content} ->
                relative = Enum.drop(segs, length(segments))
                {:ok, {relative, content}}

              {:error, :not_found} ->
                :skip

              {:error, reason} ->
                {:error, reason}
            end
          end,
          max_concurrency: max_concurrency,
          timeout: :timer.seconds(30)
        )
        |> Enum.reduce_while([], fn
          {:ok, {:ok, pair}}, acc -> {:cont, [pair | acc]}
          {:ok, :skip}, acc -> {:cont, acc}
          {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
          {:exit, reason}, _acc -> {:halt, {:error, {:task_exit, reason}}}
        end)

      case results do
        {:error, reason} -> {:error, reason}
        list -> {:ok, Enum.reverse(list)}
      end
    end
  end

  @impl true
  def serve_to_conn(conn, %Context{} = ctx, segments, opts) do
    Arca.Storage.validate_path!(segments)
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

  defp build_key(%Context{} = ctx, segments) do
    base =
      case segments do
        ["components" | _rest] ->
          # Component paths flow as-is — like Local, components/ is a separate
          # logical root inside the bucket.
          segments

        [prefix | _rest] ->
          if prefix in Arca.Storage.global_prefixes() do
            segments
          else
            # Tenant storage lives under its own `data/` root, disjoint from the
            # components/cache roots (so an athanor named after a reserved root
            # can't collide) and aligned with the Local adapter's data/ base dir.
            ["data" | Arca.Storage.tenant_segments(ctx) ++ segments]
          end

        _ ->
          ["data" | Arca.Storage.tenant_segments(ctx)]
      end

    case prefix() do
      nil -> Enum.join(base, "/")
      "" -> Enum.join(base, "/")
      pfx -> Enum.join([String.trim(pfx, "/") | base], "/")
    end
  end

  # ============================================================================
  # Private — HTTP / SigV4
  # ============================================================================

  defp request(method, key, body \\ "") do
    url = build_url(key)
    region = config!(:region)
    creds = {config!(:access_key_id), config!(:secret_access_key)}
    {access_key, secret_key} = creds
    datetime = :calendar.universal_time()

    base_headers = [
      {"host", host_for(url)},
      {"x-amz-content-sha256", sha256_hex(body)}
    ]

    signed =
      :aws_signature.sign_v4(
        access_key,
        secret_key,
        region,
        @service,
        datetime,
        method_string(method),
        url,
        base_headers,
        body,
        []
      )

    headers = signed |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    Req.request(method: method, url: url, headers: headers, body: body, decode_body: false)
  end

  # ListObjectsV2 caps each response at 1000 keys, so every enumeration must
  # follow NextContinuationToken until IsTruncated goes false — otherwise
  # component scans and tree deletions silently stop at the first page.
  defp list_keys(prefix) do
    list_keys_pages(prefix, nil, [], MapSet.new())
  end

  defp list_keys_pages(prefix, token, acc, seen_tokens) do
    case request_list_page(prefix, token) do
      {:ok, body} ->
        acc = acc ++ parse_list_keys(body)

        case next_continuation_token(body) do
          nil ->
            {:ok, acc}

          next ->
            if MapSet.member?(seen_tokens, next) do
              # A repeated token would loop forever; treat it as a bad server.
              {:error, {:s3_list_repeated_token, next}}
            else
              list_keys_pages(prefix, next, acc, MapSet.put(seen_tokens, next))
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp request_list_page(prefix, token) do
    region = config!(:region)
    {access_key, secret_key} = {config!(:access_key_id), config!(:secret_access_key)}
    bucket = config!(:bucket)
    base = endpoint_base()

    # Params assembled in canonical (sorted) order for SigV4.
    params =
      if(token, do: [{"continuation-token", token}], else: []) ++
        [{"list-type", "2"}, {"prefix", prefix <> "/"}]

    query =
      Enum.map_join(params, "&", fn {k, v} ->
        "#{k}=#{URI.encode(v, &URI.char_unreserved?/1)}"
      end)

    # Path-style: <endpoint>/<bucket>/?<query>
    # Virtual-host: <bucket>.<endpoint>/?<query>
    url =
      if path_style?() do
        "#{base}/#{bucket}/?#{query}"
      else
        "#{scheme(base)}://#{bucket}.#{host_only(base)}/?#{query}"
      end

    datetime = :calendar.universal_time()

    base_headers = [
      {"host", host_for(url)},
      {"x-amz-content-sha256", sha256_hex("")}
    ]

    signed =
      :aws_signature.sign_v4(
        access_key,
        secret_key,
        region,
        @service,
        datetime,
        "GET",
        url,
        base_headers,
        "",
        []
      )

    headers = signed |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    case Req.request(method: :get, url: url, headers: headers, decode_body: false) do
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

  # Same pagination as list_keys, keeping each object's size. Every
  # <Contents> element carries Key then Size in document order.
  defp list_entries(prefix), do: list_entries_pages(prefix, nil, [], MapSet.new())

  defp list_entries_pages(prefix, token, acc, seen_tokens) do
    case request_list_page(prefix, token) do
      {:ok, body} ->
        acc = acc ++ parse_list_entries(body)

        case next_continuation_token(body) do
          nil ->
            {:ok, acc}

          next ->
            if MapSet.member?(seen_tokens, next) do
              {:error, {:s3_list_repeated_token, next}}
            else
              list_entries_pages(prefix, next, acc, MapSet.put(seen_tokens, next))
            end
        end

      {:error, _} = error ->
        error
    end
  end

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

  defp build_url(key) do
    bucket = config!(:bucket)
    base = endpoint_base()

    if path_style?() do
      "#{base}/#{bucket}/#{encode_key(key)}"
    else
      "#{scheme(base)}://#{bucket}.#{host_only(base)}/#{encode_key(key)}"
    end
  end

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

  defp host_for(url), do: URI.parse(url).host

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
