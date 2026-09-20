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
  in `Arca.Storage.tenant_roots/0` (`components/`, `data/`, `aqua/`, …)
  and the globals `<prefix>/cache/<rest>`, `<prefix>/system/<rest>`.

  An S3 deployment is not a whole-box backup: the bucket holds Arca
  objects; the volume still holds the database (`data/cyfr.db`).

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
  has. The write back is conditional: `If-Match` on the ETag the read
  answered, or `If-None-Match: *` when the read found nothing. An append that
  lost to a concurrent writer (a definite conflict: the store wrote nothing)
  reads again and retries, up to five attempts with a doubling, jittered
  backoff, so concurrent appends to one path serialize into a total order and
  none is lost, as under Local's `O_APPEND`. An append still losing after the
  last attempt answers `{:error, :precondition_failed}`, and one whose
  request may have reached the store when the connection failed answers
  `{:error, :unknown}`: the bytes may or may not be there, and the caller
  decides whether appending again is safe. An append is refused once the
  object would pass 5 MiB (the DEFAULT node `max_response_size`, above which
  a guest cannot read the object back anyway — a node whose manifest raises
  its own response limit does not raise this ceiling; the two deliberately
  track only the default).

  ## What a write that did not succeed was

  Every write — `put/3` and `delete/2` as much as the conditional writes —
  is read the same way, so no caller is told a write definitely failed
  when it may be in the bucket. `{:error, :unknown}` is a `5xx` other than
  `501` and `503`, and a transport failure once the request may have been
  sent (a reset, a close, a timeout); a failure that proves the request
  never left (`:econnrefused` and its kin) is answered as the unreachable
  store it is, and every other status is the refusal the store made, where
  nothing was written. A delete's probe is a read: one that cannot answer
  is its own error, since nothing was sent to remove the key.

  A guest's write whose outcome is unknown is never settled `failed`
  (`Arca.ExecutionAttempts.while_held/5`) and never answered as refused:
  the guest is told `storage_uncertain` and reads the path back.

  ## Conditional writes

  The precondition this adapter mints is the ETag the store answered, sent
  back verbatim as `If-Match`; a create sends `If-None-Match: *`. Both
  headers ride inside the SigV4 signature. The store makes the check and
  the write one step, across every node that writes the bucket.

  The one result vocabulary, shared with `Arca.Adapters.Local` for the same
  situations:

  | situation | `put_if_none_match/3` | `put_if_match/4` |
  |---|---|---|
  | nothing at the path | `{:ok, precondition}`, created | `{:error, :missing}`, nothing written (`404`) |
  | an object there, precondition current | `{:error, :exists}`, untouched (`412`) | `{:ok, precondition}`, replaced |
  | an object there, precondition stale | `{:error, :exists}`, untouched (`412`) | `{:error, :precondition_failed}`, untouched (`412`) |
  | the store cannot make the write conditional | `{:error, :unsupported}` (`501`) | `{:error, :unsupported}` (`501`) |
  | the store cannot say whether it applied the write | `{:error, :unknown}` | `{:error, :unknown}` |
  | the store refuses or cannot be reached | `{:error, reason}` | `{:error, reason}` |

  A `409` (the store's answer to a conditional write racing another on the
  key) is the same definite conflict as a `412`: nothing was written.
  `:unknown` is a connection that failed once the request may have been
  sent (a reset, a close, a timeout) or a `5xx` other than `501` and `503`:
  distinct from a refusal, where nothing was written, and from a store that
  could not be reached (`:econnrefused` and its kin), where nothing was
  sent. A precondition that cannot be an ETag (not a binary, or carrying a
  control byte) is never sent: the key is probed and the answer is
  `:missing` or `:precondition_failed`. A store that answers a write with
  no ETag cannot be written conditionally again, and the adapter answers
  `{:error, :unsupported}`. A store that ignores the conditional headers
  and writes anyway cannot be told from one that honoured them, so the
  bucket must be on a service that implements conditional writes (AWS S3,
  MinIO, Cloudflare R2). `list_prefix/2` is the ListObjectsV2 prefix
  listing: every key under `prefix/` as full segments, `[prefix]` for a
  prefix that is one object, `[]` for nothing.

  ## Tree replacement

  This adapter does not export `c:Arca.Storage.replace_tree/3`. An object
  store has no rename, and a reader resolves each key directly, so a
  replacement written key by key would be visible part-way.
  `Arca.replace_tree/4` therefore refuses with
  `{:error, :atomic_replace_unsupported}` and writes nothing.

  A unit commit does not depend on it. Publication is the row
  (`Arca.StorageUnits`), and the move to the served location falls back to
  key-by-key where a tree cannot be swapped
  (`Arca.Overlay`), so a tincture build's `dist/` publishes on this
  adapter as on a filesystem — with the weaker read the moduledoc of
  `Arca.Overlay` states: while the move runs, a reader of the unit's
  objects can see some of the committed revision and some of the one
  before it.

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
  # Read at call time like the Local adapter reads it: a compile-time copy
  # here would silently diverge the moment that function turns config-driven.

  # The bound on an append's conditional write: attempts in all, and the
  # base of the doubling backoff between them.
  @append_attempts 5
  @append_backoff_base_ms 20

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
      answer -> write_outcome("put", answer)
    end
  end

  @impl true
  def append(%Context{} = ctx, segments, content) do
    Arca.Storage.refuse_seed_write!(segments)
    append_attempt(ctx, segments, IO.iodata_to_binary(content), 1)
  end

  # One read-extend-write, conditional on what the read saw. A definite
  # conflict (the store wrote nothing: another writer moved the object
  # first) reads again within the bound; every other answer, the unknown
  # outcome included, is final — an append that may have landed is not
  # sent twice.
  defp append_attempt(ctx, segments, content, attempt) do
    with {:ok, existing, etag} <- read_for_append(ctx, segments),
         :ok <- check_append_ceiling(existing, content) do
      case write_for_append(ctx, segments, existing <> content, etag) do
        {:ok, _precondition} ->
          :ok

        {:error, conflict} when conflict in [:exists, :precondition_failed, :missing] ->
          if attempt < @append_attempts do
            Process.sleep(append_backoff_ms(attempt))
            append_attempt(ctx, segments, content, attempt + 1)
          else
            Logger.warning("[Arca.S3.append] still losing after #{attempt} attempts")
            {:error, :precondition_failed}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp check_append_ceiling(existing, content) do
    if byte_size(existing) + byte_size(content) > Cyfr.Limits.default_max_response_size(),
      do: {:error, :object_too_large},
      else: :ok
  end

  # A missing object is an empty one: appending to a path that does not exist
  # yet creates it, matching the local filesystem's `File.write(:append)`.
  defp read_for_append(ctx, segments) do
    case versioned_read("append", ctx, segments) do
      {:ok, body, etag} -> {:ok, body, etag}
      {:error, :not_found} -> {:ok, "", nil}
      {:error, _} = error -> error
    end
  end

  @doc """
  The object's bytes and the ETag a conditional replace of them must carry
  (`c:Arca.Storage.get_for_update/2`) — the GET's own ETag, so the read
  and the proof of what was read are one round trip.
  """
  @impl true
  def get_for_update(%Context{} = ctx, segments),
    do: versioned_read("get_for_update", ctx, segments)

  # An object read without an ETag cannot be written back conditionally,
  # and an unconditional write back could drop a concurrent writer's
  # bytes: refuse rather than offer a precondition no store minted.
  defp versioned_read(op, ctx, segments) do
    case request(:get, build_key(ctx, segments)) do
      {:ok, %{status: 200, body: body} = response} ->
        case etag(response) do
          nil ->
            Logger.warning("[Arca.S3.#{op}] the store answered a read with no ETag")
            {:error, :unsupported}

          etag ->
            {:ok, body, etag}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        log_and_error(op, status, body)

      {:error, reason} ->
        log_and_error(op, reason)
    end
  end

  defp write_for_append(ctx, segments, merged, nil), do: put_if_none_match(ctx, segments, merged)

  defp write_for_append(ctx, segments, merged, etag),
    do: put_if_match(ctx, segments, merged, etag)

  # Doubling from the base, with jitter so the losers of one round do not
  # collide again in the next.
  defp append_backoff_ms(attempt) do
    ceiling = @append_backoff_base_ms * Integer.pow(2, attempt - 1)
    div(ceiling, 2) + :rand.uniform(div(ceiling, 2))
  end

  @doc """
  Create the object only when the key holds nothing, with
  `If-None-Match: *` (`c:Arca.Storage.put_if_none_match/3`); the moduledoc
  states the result vocabulary.
  """
  @impl true
  def put_if_none_match(%Context{} = ctx, segments, content) do
    Arca.Storage.refuse_seed_write!(segments)
    key = build_key(ctx, segments)

    conditional_put("put_if_none_match", key, content, {"if-none-match", "*"}, :exists)
  end

  @doc """
  Replace the object while its ETag is still `precondition`, with
  `If-Match` (`c:Arca.Storage.put_if_match/4`); the moduledoc states the
  result vocabulary.
  """
  @impl true
  def put_if_match(%Context{} = ctx, segments, content, precondition) do
    Arca.Storage.refuse_seed_write!(segments)
    key = build_key(ctx, segments)

    if etag_shaped?(precondition) do
      conditional_put(
        "put_if_match",
        key,
        content,
        {"if-match", precondition},
        :precondition_failed
      )
    else
      # Not a value this adapter minted, and not one a header can carry:
      # it matches no object, so only the key's presence is in question.
      case request(:head, key) do
        {:ok, %{status: 200}} -> {:error, :precondition_failed}
        {:ok, %{status: 404}} -> {:error, :missing}
        {:ok, %{status: status, body: body}} -> log_and_error("put_if_match", status, body)
        {:error, reason} -> log_and_error("put_if_match", reason)
      end
    end
  end

  defp etag_shaped?(precondition) do
    is_binary(precondition) and precondition != "" and String.printable?(precondition) and
      not String.match?(precondition, ~r/[[:cntrl:]]/)
  end

  defp conditional_put(op, key, content, condition, conflict) do
    body = IO.iodata_to_binary(content)

    case signed_request(:put, build_url(key), body, [condition]) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        case etag(response) do
          nil ->
            Logger.warning("[Arca.S3.#{op}] the store answered a write with no ETag")
            {:error, :unsupported}

          etag ->
            {:ok, etag}
        end

      {:ok, %{status: status}} when status in [409, 412] ->
        {:error, conflict}

      {:ok, %{status: 404, body: body}} ->
        # No such key is the conditional replace's `:missing`; no such
        # bucket is a misconfiguration, reported as the error it is.
        if conflict == :precondition_failed and not (to_string(body) =~ "NoSuchBucket"),
          do: {:error, :missing},
          else: log_and_error(op, 404, body)

      {:ok, %{status: 501}} ->
        {:error, :unsupported}

      answer ->
        write_outcome(op, answer)
    end
  end

  # What a write that did not succeed was: a refusal the store made, where
  # nothing was written, or an outcome it cannot state. Every write this
  # adapter makes — the plain `put/3` and `delete/2` as much as the
  # conditional ones — is read the same way, so no caller is told a write
  # definitely failed when it may be in the bucket.
  #
  # `:unknown` is a `5xx` other than `503` (the store declining the
  # request) and `501` (a method it does not implement), and a transport
  # failure once the request may have been sent. A failure that proves the
  # request never left is the store being unreachable, and is answered as
  # what it is.
  defp write_outcome(op, {:ok, %{status: status, body: body}})
       when status >= 500 and status not in [501, 503] do
    log_and_error(op, status, body)
    {:error, :unknown}
  end

  defp write_outcome(op, {:ok, %{status: status, body: body}}),
    do: log_and_error(op, status, body)

  defp write_outcome(op, {:error, reason}) do
    log_and_error(op, reason)
    {:error, write_failure(reason)}
  end

  @never_sent [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :eaddrnotavail]

  defp write_failure(%Req.TransportError{reason: reason} = error) when reason in @never_sent,
    do: error

  defp write_failure(_may_have_been_sent), do: :unknown

  defp etag(%Req.Response{} = response) do
    case Req.Response.get_header(response, "etag") do
      [etag | _] when etag != "" -> etag
      _ -> nil
    end
  end

  @doc """
  Every object at or below `prefix`, as full segments
  (`c:Arca.Storage.list_prefix/2`): the ListObjectsV2 listing under
  `prefix/`, `[prefix]` for a prefix that is one object, `[]` for nothing.
  """
  @impl true
  def list_prefix(%Context{} = ctx, prefix) do
    with {:ok, []} <- list_recursive(ctx, prefix) do
      if exists?(ctx, prefix), do: {:ok, [prefix]}, else: {:ok, []}
    end
  end

  @impl true
  def delete(%Context{} = ctx, segments) do
    Arca.Storage.refuse_seed_write!(segments)
    key = build_key(ctx, segments)

    # Real S3 answers 204 even for a key that never existed, so a bare DELETE
    # cannot tell "deleted" from "was never there" — probe first, and a
    # missing file is `{:error, :not_found}` on both adapters. The probe is
    # a read: one that cannot answer is its own error and nothing was sent
    # to remove the key. Only the DELETE itself can leave the outcome
    # unknown.
    case request(:head, key) do
      {:ok, %{status: 200}} ->
        case request(:delete, key) do
          {:ok, %{status: status}} when status in [200, 204] -> :ok
          {:ok, %{status: 404}} -> {:error, :not_found}
          answer -> write_outcome("delete", answer)
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        log_and_error("delete", status, body)

      {:error, reason} ->
        log_and_error("delete", reason)
    end
  end

  # An object store has no directories: a prefix exists when a key sits
  # under it, and nothing needs creating for that.
  @impl true
  def ensure_dir(%Context{} = _ctx, segments) do
    Arca.Storage.refuse_seed_write!(segments)
    Arca.Storage.validate_path!(segments)
    :ok
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
        # adapter's walk never counts a directory either. An object AT the
        # key is the file itself, counted like Local's stat of one.
        sizes =
          for {key, size} <- entries,
              key == prefix_key or String.starts_with?(key, prefix_with_slash),
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

  # Sign and send each request with shared headers and SigV4 signing.
  # Retries are disabled; callers own retry policy. The receive timeout
  # comes from the storage configuration.
  defp signed_request(method, url, body, extra_headers \\ []) do
    # `sign_v4` adds X-Amz-Content-SHA256 itself, hashing the body it was
    # given. Passing a second one — the same value under a different case —
    # put the name into SignedHeaders twice and sent two header lines, so
    # every real S3 implementation answered SignatureDoesNotMatch. The stub
    # suite could not see it: it checks request shape, not signatures.
    base_headers = [{"host", host_for(url)}] ++ extra_headers

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
        # `encode_key/1` has already percent-encoded every segment, and
        # S3 is the one service whose canonical URI is not encoded a second
        # time (the library's own words). Left at its default, a key with a
        # space, a plus or any non-ASCII character signed a path the server
        # never saw and came back 403.
        [{:uri_encode_path, false}]
      )

    headers = Enum.map(signed, fn {k, v} -> {to_string(k), to_string(v)} end)

    Req.request(
      method: method,
      url: url,
      headers: headers,
      body: body,
      decode_body: false,
      retry: false,
      receive_timeout: config(:receive_timeout_ms) || 60_000
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

  # Include non-default ports in the Host header, as required by RFC 9110.
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
    # Scrub credentials from the XML error body before truncating it.
    scrubbed =
      body
      |> to_string()
      |> String.replace(
        ~r/(X-Amz-(?:Credential|Signature|Security-Token))=[^&<"\s]*/i,
        "\\1=[REDACTED]"
      )
      |> String.slice(0, 500)

    Logger.warning("[Arca.S3.#{op}] status=#{status} body=#{inspect(scrubbed)}")

    {:error, {:s3_error, status}}
  end
end
