# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.Client do
  @moduledoc """
  This home's client for any identity directory (`ARCHITECTURE.md` §9.1):
  registration, resolution, appends, recoveries and recorded outcomes.

  ## Which directory

  A person's directory is the one their genesis names, never a URL a
  caller supplies and never this home's enrollment setting. Every function
  takes the identifier and its genesis first (the genesis as its JSON text
  or map), and holds one to the other with `Prima.Identity.locate/2` before
  any network use: at most 16 KiB, a genesis by shape and signature, and
  hashing to the identifier. A mismatch makes no request. So two people on
  two directories resolve independently, each at their own.

  A directory URL names the node serving it, with any path its proxy
  adds; the protocol's paths, `/directory/v1/…`, follow it.

  ## Transport

  HTTPS only (`:insecure_directory` otherwise, before any request), over
  `Sanctum.Egress.pinned_request/5` under `private_policy: :operator`: a
  loopback or private address is refused unless the operator lists it in
  `CYFR_PRIVATE_EGRESS_TARGETS`, a metadata address always, and a redirect
  is never followed (`:redirected`). No credential or cookie is sent. Each
  request is bounded to 10 seconds and 64 KiB, an operation to 30 seconds,
  and a resolution to 1,000 pages. This member sheds its own requests to
  one directory origin past 300 a minute, locally and retryably.

  The trailing `opts` take only `:resolver` (a module answering
  `getaddr/2` as `:inet` does) and `:cacerts` (DER certificates to trust):
  the address policy and peer verification are not options.

  ## Resolution and the cache

  `resolve/3` reads every page of the log, checks each links to the one
  before it (its first position, its `next`, its size) and verifies the
  whole chain from the genesis with `Prima.Identity.verify_chain/1`, the
  last page's head and length included. Nothing partially verified is
  cached. It then writes this home's cache (`Arca.DirectoryHeads`) against
  the head it had cached before reading: the first head is put, the same
  head is touched (`verified_at` moves), a head the verified chain descends
  from is advanced (retiring what was bound to an old `key_epoch`, in the
  same transaction). A chain that does not contain the cached head is
  `:not_descendant` and leaves the cache untouched: an honest directory's
  log only grows. The answer carries what an advance retired, for the
  caller to announce. `cached/1` reads the cache back as a
  `Prima.Identity.State`.

  Registration, appends, recoveries and outcomes write no cache: they
  concern a person's own identity, whose head their identity row holds.

  ## Refusals

  Before any request: `Prima.Identity.locate/2`'s refusals,
  `:insecure_directory`, and for a recovery `:wrong_identifier` or
  `:directory_changed`. The transport's: `:egress_refused`, `:unreachable`,
  `:timeout`, `:redirected`, `:response_too_large`, `:invalid_response`,
  and `{:rate_limited, seconds}` from this member's shed. The directory's
  (`Emissary.Web.DirectoryController`'s codes): `:not_served`,
  `:not_found`, `:read_only`, `:body_too_large`, `{:stale_head, head}`,
  `{:stale_policy, recorded}`, `:request_id_reused`, `:conflict`,
  `{:refused, :invalid | :unverified | :wrong_identifier, reason | nil}`,
  `:corrupt`, and the retryable `{:rate_limited, seconds}`,
  `{:capacity, seconds}` (a quota, or an identifier's day of rotations,
  up to a day), `{:busy, seconds}` and `{:unavailable, seconds}`.
  A resolution's own: `{:unverified, reason}`, `:truncated`,
  `:invalid_page`, `:too_many_pages`, `:not_descendant`,
  `:binding_changed`, and from the cache `:busy`, `:not_owner` and
  `:unavailable`. The retryable ones are the transport's, the rate and
  capacity answers, `:busy` and `:unavailable`.
  """

  require Logger

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry, RecoverRequest, State}

  @path "/directory/v1"
  @request_ms 10_000
  @operation_ms 30_000
  @max_pages 1_000
  @page_entries 100
  @response_bytes 65_536
  @origin_cap 300
  @window_ms 60_000
  @cache_rounds 2
  # A directory's longest honest wait is its day's rotation window.
  @max_retry_after 86_400

  @typedoc "A genesis as a relying home was handed it: its JSON text, or the decoded map."
  @type genesis :: binary() | map()

  @typedoc "The only options: a resolver and the certificates to trust."
  @type opts :: [resolver: module(), cacerts: [binary()]]

  @typedoc "What an advance retired (`t:Arca.DirectoryHeads.retired/0`); empty otherwise."
  @type retired :: %{
          session_hashes: [binary()],
          passkey_ids: [String.t()],
          confirmation_ids: [String.t()],
          certificate_ids: [String.t()]
        }

  @typedoc "Why an operation did not complete; the moduledoc groups them."
  @type reason :: atom() | {atom(), term()} | {:refused, atom(), String.t() | nil}

  @typedoc "An accepted write."
  @type accepted :: %{identifier: String.t(), seq: non_neg_integer(), entry_hash: String.t()}

  # ---- the operations ----------------------------------------------------------

  @doc """
  Register `genesis` at the directory it names. Answers the registration,
  the same for a genesis registered before.
  """
  @spec register(String.t(), genesis(), opts()) :: {:ok, accepted()} | {:error, reason()}
  def register(identifier, genesis, opts \\ []) do
    with {:ok, ctx} <- prepare(identifier, genesis, opts),
         {:ok, body} <- call(ctx, :post, "/genesis", Identity.canonical(ctx.genesis)) do
      accepted(body, identifier, Identity.hash(ctx.genesis))
    end
  end

  @doc """
  The genesis of `identifier` at `directory_url`, for a caller that holds
  only the identifier and the directory it was given (a printed kit's two
  lines), never a genesis to locate it by: the log's first entry, read
  from that directory, held to the identifier with
  `Prima.Identity.locate/2` and required to name `directory_url` as its own
  directory (`:directory_mismatch` otherwise). Answers the genesis's JCS
  bytes, the locator every other function here takes. A malformed
  identifier or directory makes no request (`:invalid_locator`).
  """
  @spec genesis(String.t(), String.t(), opts()) :: {:ok, binary()} | {:error, reason()}
  def genesis(identifier, directory_url, opts \\ [])

  def genesis(identifier, directory_url, opts)
      when is_binary(identifier) and is_binary(directory_url) do
    opts = options!(opts)

    with true <- Encoding.identifier?(identifier) and Encoding.directory_url?(directory_url),
         {:ok, base, origin} <- target(directory_url) do
      ctx = %{
        identifier: identifier,
        base: base,
        origin: origin,
        transport: transport(opts),
        deadline: now() + @operation_ms
      }

      with {:ok, body} <- call(ctx, :get, "/#{identifier}?after=-1", nil),
           {:ok, %{entries: [first | _]}} <- page(body, identifier, -1),
           {:ok, located} <- Identity.locate(first, identifier) do
        if located.directory == directory_url,
          do: {:ok, Identity.canonical(located)},
          else: {:error, :directory_mismatch}
      else
        {:ok, %{entries: []}} -> {:error, :invalid_page}
        {:error, _reason} = refusal -> refusal
      end
    else
      false -> {:error, :invalid_locator}
      {:error, _reason} = refusal -> refusal
    end
  end

  def genesis(_identifier, _directory_url, _opts), do: {:error, :invalid_locator}

  @doc """
  Resolve `identifier` at the directory its genesis names, verify the whole
  log, and cache its head. Answers the verified state, the cached head's
  row and what an advance retired.
  """
  @spec resolve(String.t(), genesis(), opts()) ::
          {:ok, %{state: State.t(), head: map(), retired: retired()}} | {:error, reason()}
  def resolve(identifier, genesis, opts \\ []) do
    with {:ok, ctx} <- prepare(identifier, genesis, opts), do: resolve_in(ctx, @cache_rounds)
  end

  @doc """
  Append a signed rotation (its `Prima.Identity.Entry`, JSON map or
  canonical bytes) to `identifier`'s log.
  """
  @spec append(String.t(), genesis(), Entry.t() | map() | binary(), opts()) ::
          {:ok, accepted()} | {:error, reason()}
  def append(identifier, genesis, entry, opts \\ []) do
    with {:ok, ctx} <- prepare(identifier, genesis, opts),
         {:ok, rotation} <- rotation(entry),
         {:ok, body} <-
           call(ctx, :post, "/" <> identifier <> "/entries", Identity.canonical(rotation)) do
      accepted(body, identifier, Identity.hash(rotation))
    end
  end

  @doc """
  Submit a signed recover request (its `Prima.Identity.RecoverRequest` or
  JSON map) for `identifier`. Answers the committed entry, or its recorded
  outcome for a request submitted before.
  """
  @spec recover(String.t(), genesis(), RecoverRequest.t() | map(), opts()) ::
          {:ok,
           %{
             identifier: String.t(),
             seq: non_neg_integer(),
             entry_hash: String.t(),
             entry: Entry.t()
           }}
          | {:error, reason()}
  def recover(identifier, genesis, request, opts \\ []) do
    with {:ok, ctx} <- prepare(identifier, genesis, opts),
         {:ok, request} <- recover_request(request),
         :ok <- for_this(request, identifier, ctx.genesis),
         {:ok, body} <-
           call(ctx, :post, "/" <> identifier <> "/recover", Identity.canonical(request)),
         {:ok, answer} <- accepted(body, identifier, nil),
         {:ok, entry} <- recovery_entry(body["entry"], answer.entry_hash, request) do
      {:ok, Map.put(answer, :entry, entry)}
    end
  end

  @doc """
  The recorded outcome of recovery request `request_id` under
  `identifier`: `%{outcome: :accepted, entry: …}` with its position and
  hash, or `%{outcome: :stale_policy, recorded: …}`, each with the
  request's digest.
  """
  @spec outcome(String.t(), genesis(), String.t(), opts()) :: {:ok, map()} | {:error, reason()}
  def outcome(identifier, genesis, request_id, opts \\ []) do
    with {:ok, ctx} <- prepare(identifier, genesis, opts),
         :ok <- request_id(request_id),
         {:ok, body} <- call(ctx, :get, "/" <> identifier <> "/requests/" <> request_id, nil) do
      recorded(body, identifier, request_id)
    end
  end

  @doc """
  This home's cached head of `identifier`: the verified state it stored,
  decoded, and the row (its genesis, directory and `verified_at`).
  """
  @spec cached(String.t()) ::
          {:ok, %{state: State.t(), head: map()}}
          | {:error, :not_found | :corrupt | :unavailable}
  def cached(identifier) when is_binary(identifier) do
    case Arca.DirectoryHeads.get(system(), identifier) do
      {:ok, row} ->
        case decode_state(row) do
          {:ok, state} -> {:ok, %{state: state, head: row}}
          :error -> {:error, :corrupt}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  # ---- before any request ------------------------------------------------------

  defp prepare(identifier, genesis, opts) when is_binary(identifier) do
    opts = options!(opts)

    with {:ok, located} <- Identity.locate(genesis, identifier),
         {:ok, base, origin} <- target(located.directory) do
      {:ok,
       %{
         identifier: identifier,
         genesis: located,
         base: base,
         origin: origin,
         transport: transport(opts),
         deadline: now() + @operation_ms
       }}
    end
  end

  defp options!(opts) when is_list(opts) do
    case Keyword.validate(opts, [:resolver, :cacerts]) do
      {:ok, opts} ->
        unless is_nil(opts[:resolver]) or is_atom(opts[:resolver]),
          do: raise(ArgumentError, ":resolver is a module")

        unless is_nil(opts[:cacerts]) or
                 (is_list(opts[:cacerts]) and Enum.all?(opts[:cacerts], &is_binary/1)),
               do: raise(ArgumentError, ":cacerts is a list of DER certificates")

        opts

      {:error, unknown} ->
        raise ArgumentError,
              "Sanctum.Directory.Client takes only :resolver and :cacerts, not " <>
                Enum.map_join(unknown, ", ", &Prima.LoggerContext.shape/1)
    end
  end

  # A genesis's directory URL is already a validated spelling
  # (`Prima.Identity.Encoding.directory_url?/1`); only HTTPS is spoken.
  defp target(directory) do
    case URI.parse(directory) do
      %URI{scheme: "https", host: host, port: port} when is_binary(host) ->
        origin = if port == 443, do: "https://" <> host, else: "https://#{host}:#{port}"
        {:ok, directory <> @path, origin}

      %URI{} ->
        {:error, :insecure_directory}
    end
  end

  defp transport(opts) do
    base = [private_policy: :operator, max_response_bytes: @response_bytes]
    base = if opts[:resolver], do: Keyword.put(base, :resolver, opts[:resolver]), else: base

    if opts[:cacerts],
      do: Keyword.put(base, :transport_opts, cacerts: opts[:cacerts]),
      else: base
  end

  defp request_id(request_id) do
    if Encoding.id?(request_id), do: :ok, else: {:error, {:invalid_field, "request_id"}}
  end

  defp rotation(%Entry{} = entry), do: rotation(Entry.encode(entry))

  defp rotation(bytes) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, %{} = map} -> rotation(map)
      _other -> {:error, :invalid_entry}
    end
  end

  defp rotation(map) when is_map(map) do
    case Entry.decode(map) do
      {:ok, %Entry{kind: :rotate, sig: sig} = entry} when is_binary(sig) -> {:ok, entry}
      {:ok, %Entry{}} -> {:error, :not_rotate}
      {:error, _reason} -> {:error, :invalid_entry}
    end
  end

  defp recover_request(%RecoverRequest{} = request),
    do: recover_request(RecoverRequest.encode(request))

  defp recover_request(map) when is_map(map) do
    case RecoverRequest.decode(map) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} -> {:error, :invalid_request}
    end
  end

  # A request for another identifier or directory is refused by the
  # directory; saying so here spends no request on it.
  defp for_this(%RecoverRequest{identifier: identifier} = request, identifier, genesis) do
    if request.directory == genesis.directory, do: :ok, else: {:error, :directory_changed}
  end

  defp for_this(%RecoverRequest{}, _identifier, _genesis), do: {:error, :wrong_identifier}

  # ---- one request -------------------------------------------------------------

  # Shed by this member's count for the origin, then sent from a task the
  # deadline bounds, so a directory that answers slowly, a byte at a time,
  # still cannot hold the caller past the request's bound.
  defp call(ctx, method, path, body) do
    with :ok <- shed(ctx.origin),
         {:ok, timeout} <- remaining(ctx) do
      url = ctx.base <> path
      opts = Keyword.put(ctx.transport, :receive_timeout, timeout)
      headers = headers(body)

      task =
        Task.Supervisor.async_nolink(Sanctum.TaskSupervisor, fn ->
          send_request(method, url, headers, body, opts)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> answer(result)
        {:exit, _reason} -> {:error, :unreachable}
        nil -> {:error, :timeout}
      end
    end
  end

  defp shed(origin) do
    case Prima.RateLimiter.check({__MODULE__, origin}, @origin_cap, @window_ms) do
      :ok -> :ok
      {:deny, seconds} -> {:error, {:rate_limited, seconds}}
    end
  end

  defp remaining(ctx) do
    left = ctx.deadline - now()
    if left > 0, do: {:ok, min(left, @request_ms)}, else: {:error, :timeout}
  end

  defp headers(nil),
    do: [{"accept", "application/json"}, {"user-agent", "CYFR/" <> Prima.Version.current()}]

  defp headers(_body), do: [{"content-type", "application/json"} | headers(nil)]

  defp send_request(method, url, headers, body, opts) do
    Sanctum.Egress.pinned_request(method, url, headers, body, opts)
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  end

  defp answer({:ok, status, _headers, _body}) when status in 300..399, do: {:error, :redirected}

  defp answer({:ok, 200, _headers, body}) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> {:ok, map}
      _other -> {:error, :invalid_response}
    end
  end

  defp answer({:ok, status, headers, body}),
    do: {:error, refusal(status, error_body(body), headers)}

  # The pinned transport answers a refusal it made before connecting as a
  # sentence: a DNS failure is the network's, the rest are the address policy's.
  defp answer({:error, message}) when is_binary(message) do
    Logger.warning("[Sanctum.Directory.Client] a directory request was refused: #{message}")

    if String.starts_with?(message, "DNS resolution failed"),
      do: {:error, :unreachable},
      else: {:error, :egress_refused}
  end

  defp answer({:error, {:response_too_large, _size, _max}}), do: {:error, :response_too_large}
  defp answer({:error, %Req.TransportError{reason: :timeout}}), do: {:error, :timeout}

  defp answer({:error, reason}) do
    Logger.warning("[Sanctum.Directory.Client] a directory request failed: #{inspect(reason)}")
    {:error, :unreachable}
  end

  defp error_body(body) do
    case Jason.decode(body) do
      {:ok, %{} = map} -> map
      _other -> %{}
    end
  end

  defp refusal(404, %{"error" => "not_served"}, _headers), do: :not_served
  defp refusal(404, _body, _headers), do: :not_found
  defp refusal(405, _body, _headers), do: :read_only
  defp refusal(413, _body, _headers), do: :body_too_large

  defp refusal(409, %{"error" => "stale_head", "head" => head}, _headers) when is_binary(head) do
    if Encoding.digest?(head), do: {:stale_head, head}, else: :invalid_response
  end

  defp refusal(409, %{"error" => "stale_policy", "recorded" => %{} = recorded}, _headers),
    do: {:stale_policy, recorded}

  defp refusal(409, %{"error" => "request_id_reused"}, _headers), do: :request_id_reused
  defp refusal(409, _body, _headers), do: :conflict

  defp refusal(422, %{"error" => "unverified"} = body, _headers),
    do: {:refused, :unverified, reason_text(body)}

  defp refusal(422, %{"error" => "wrong_identifier"}, _headers),
    do: {:refused, :wrong_identifier, nil}

  defp refusal(422, body, _headers), do: {:refused, :invalid, reason_text(body)}
  defp refusal(429, _body, headers), do: {:rate_limited, retry_after(headers)}
  defp refusal(503, %{"error" => "capacity"}, headers), do: {:capacity, retry_after(headers)}
  defp refusal(503, %{"error" => "busy"}, headers), do: {:busy, retry_after(headers)}
  defp refusal(503, _body, headers), do: {:unavailable, retry_after(headers)}
  defp refusal(500, %{"error" => "corrupt"}, _headers), do: :corrupt
  defp refusal(status, _body, _headers), do: {:status, status}

  # The directory's reason word, when it is one: never an atom made from
  # what a remote party sent.
  defp reason_text(%{"reason" => reason}) when is_binary(reason) do
    if Regex.match?(~r/\A[a-z_]{1,64}\z/, reason), do: reason, else: nil
  end

  defp reason_text(_body), do: nil

  defp retry_after(headers) do
    with {_name, value} <- List.keyfind(headers, "retry-after", 0),
         {seconds, ""} when seconds > 0 <- Integer.parse(value) do
      min(seconds, @max_retry_after)
    else
      _ -> 1
    end
  end

  # ---- answers -----------------------------------------------------------------

  defp accepted(body, identifier, expected_hash) do
    with %{"identifier" => ^identifier, "seq" => seq, "entry_hash" => hash}
         when is_integer(seq) and seq >= 0 <- body,
         true <- Encoding.digest?(hash),
         true <- is_nil(expected_hash) or hash == expected_hash do
      {:ok, %{identifier: identifier, seq: seq, entry_hash: hash}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  # The committed recovery entry must embed exactly the request sent and
  # hash to the hash the directory names.
  defp recovery_entry(%{} = map, hash, %RecoverRequest{} = request) do
    with {:ok, %Entry{kind: :recover} = entry} <- Entry.decode(map),
         true <- Identity.hash(entry) == hash,
         true <- Identity.request_digest(entry.request) == Identity.request_digest(request) do
      {:ok, entry}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp recovery_entry(_value, _hash, _request), do: {:error, :invalid_response}

  defp recorded(%{"outcome" => "accepted"} = body, identifier, request_id) do
    with %{"identifier" => ^identifier, "request_id" => ^request_id, "request_digest" => digest} <-
           body,
         {:ok, answer} <- accepted(body, identifier, nil),
         {:ok, %Entry{kind: :recover, request: request} = entry} <- Entry.decode(body["entry"]),
         true <- Identity.hash(entry) == answer.entry_hash,
         true <- request.request_id == request_id and Identity.request_digest(request) == digest do
      {:ok,
       Map.merge(answer, %{
         outcome: :accepted,
         request_id: request_id,
         request_digest: digest,
         entry: entry
       })}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp recorded(%{"outcome" => "stale_policy"} = body, identifier, request_id) do
    case body do
      %{
        "identifier" => ^identifier,
        "request_id" => ^request_id,
        "request_digest" => digest,
        "recorded" => %{} = recorded
      } ->
        if Encoding.digest?(digest),
          do:
            {:ok,
             %{
               identifier: identifier,
               outcome: :stale_policy,
               request_id: request_id,
               request_digest: digest,
               recorded: recorded
             }},
          else: {:error, :invalid_response}

      _other ->
        {:error, :invalid_response}
    end
  end

  defp recorded(_body, _identifier, _request_id), do: {:error, :invalid_response}

  # ---- resolution --------------------------------------------------------------

  # The cached head is read before the log, so the log read after it must
  # contain it: a log that does not is not the history this home verified.
  # A cache another resolution moved in between is read again, with the
  # log, at most `@cache_rounds` times in all.
  defp resolve_in(ctx, rounds) do
    with {:ok, baseline} <- baseline(ctx.identifier),
         {:ok, log} <- read_log(ctx, -1, [], 0),
         {:ok, state} <- verified(ctx, log) do
      case settle(ctx, baseline, state, log.entries) do
        :moved when rounds > 1 -> resolve_in(ctx, rounds - 1)
        :moved -> {:error, :busy}
        settled -> settled
      end
    end
  end

  defp baseline(identifier) do
    case Arca.DirectoryHeads.get(system(), identifier) do
      {:ok, row} -> {:ok, row}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp read_log(_ctx, _after, _pages, @max_pages), do: {:error, :too_many_pages}

  defp read_log(ctx, after_seq, pages, count) do
    with {:ok, body} <- call(ctx, :get, "/#{ctx.identifier}?after=#{after_seq}", nil),
         {:ok, page} <- page(body, ctx.identifier, after_seq) do
      pages = [page.entries | pages]

      case page.next do
        nil ->
          entries = pages |> Enum.reverse() |> Enum.concat()
          {:ok, %{entries: entries, head: page.head, length: page.length}}

        next ->
          read_log(ctx, next, pages, count + 1)
      end
    end
  end

  # A page links to the one before it: it starts where it was asked to,
  # holds at most a page of entries, and a `next` that is exactly its
  # last position.
  defp page(body, identifier, after_seq) do
    with %{
           "identifier" => ^identifier,
           "from" => from,
           "entries" => entries,
           "next" => next,
           "head" => head,
           "length" => length
         } <- body,
         true <- from == after_seq + 1,
         true <- is_list(entries) and length(entries) <= @page_entries,
         true <- Enum.all?(entries, &is_map/1),
         true <- Encoding.digest?(head) and is_integer(length) and length > 0,
         true <- next_links?(next, after_seq, entries) do
      {:ok, %{entries: entries, next: next, head: head, length: length}}
    else
      _ -> {:error, :invalid_page}
    end
  end

  defp next_links?(nil, _after_seq, _entries), do: true

  defp next_links?(next, after_seq, entries) when is_integer(next),
    do: entries != [] and next == after_seq + length(entries)

  defp next_links?(_next, _after_seq, _entries), do: false

  # The whole log verified from the genesis, which must be the one this
  # identifier hashes from, and reaching the head and length the last page
  # named: a log that stops short of its own head is truncated.
  defp verified(ctx, log) do
    with {:ok, state} <- chain(log.entries) do
      cond do
        state.identifier != ctx.identifier -> {:error, :identifier_mismatch}
        state.length != log.length or state.head != log.head -> {:error, :truncated}
        true -> {:ok, state}
      end
    end
  end

  defp chain(entries) do
    case Identity.verify_chain(entries) do
      {:ok, state} -> {:ok, state}
      {:error, {_index, reason}} -> {:error, {:unverified, reason}}
    end
  end

  defp settle(ctx, nil, state, _entries) do
    attrs = ctx |> cache_attrs(state) |> Map.put(:identifier, ctx.identifier)

    case Arca.DirectoryHeads.put(system(), attrs) do
      {:ok, row} -> {:ok, %{state: state, head: row, retired: nothing_retired()}}
      {:error, :exists} -> :moved
      {:error, reason} -> cache_refusal(reason)
    end
  end

  defp settle(ctx, cached, state, entries) do
    cond do
      cached.genesis != Identity.canonical(ctx.genesis) or
          cached.directory_url != ctx.genesis.directory ->
        {:error, :binding_changed}

      cached.head_hash == state.head ->
        case Arca.DirectoryHeads.touch(system(), ctx.identifier, state.head) do
          {:ok, row} -> {:ok, %{state: state, head: row, retired: nothing_retired()}}
          {:error, :stale} -> :moved
          {:error, reason} -> cache_refusal(reason)
        end

      descends?(entries, cached.head_hash) ->
        case Arca.DirectoryHeads.advance(
               system(),
               ctx.identifier,
               cached.head_hash,
               cache_attrs(ctx, state)
             ) do
          {:ok, %{head: row, retired: retired}} ->
            {:ok, %{state: state, head: row, retired: retired}}

          {:error, :stale} ->
            :moved

          {:error, :binding_changed} ->
            {:error, :binding_changed}

          {:error, reason} ->
            cache_refusal(reason)
        end

      true ->
        Logger.warning(
          "[Sanctum.Directory.Client] the directory #{ctx.genesis.directory} served a log " <>
            "of #{ctx.identifier} that does not contain the head this home verified; the " <>
            "cache is left as it was"
        )

        {:error, :not_descendant}
    end
  end

  defp descends?(entries, head) do
    Enum.any?(entries, fn map ->
      {:ok, entry} = Entry.decode(map)
      Identity.hash(entry) == head
    end)
  end

  defp cache_attrs(ctx, state) do
    %{
      genesis: Identity.canonical(ctx.genesis),
      directory_url: ctx.genesis.directory,
      head_hash: state.head,
      key_epoch: state.key_epoch,
      state: Jason.encode!(State.encode(state))
    }
  end

  defp cache_refusal(:not_owner), do: {:error, :not_owner}

  defp cache_refusal(reason) do
    Logger.warning("[Sanctum.Directory.Client] the head cache refused: #{inspect(reason)}")
    {:error, :unavailable}
  end

  defp nothing_retired,
    do: %{session_hashes: [], passkey_ids: [], confirmation_ids: [], certificate_ids: []}

  # ---- the cached state --------------------------------------------------------

  # `Prima.Identity.State.encode/1`'s JSON, as `resolve/3` stored it, held
  # to the row it sits on.
  defp decode_state(row) do
    with {:ok, %{} = map} <- Jason.decode(row.state),
         {:ok, identifier} <- Encoding.check(map, "identifier", &Encoding.identifier?/1),
         {:ok, directory} <- Encoding.check(map, "directory", &Encoding.directory_url?/1),
         {:ok, head} <- Encoding.check(map, "head", &Encoding.digest?/1),
         {:ok, epoch} <- Encoding.check(map, "key_epoch", &Encoding.digest?/1),
         {:ok, live} <- Encoding.binary(map, "live_key", Encoding.key_bytes()),
         {:ok, operational} <- Encoding.binary(map, "operational_key", Encoding.key_bytes()),
         {:ok, recovery} <- Encoding.keys(map, "recovery_keys"),
         {:ok, revision} <- Encoding.check(map, "revision", &(is_integer(&1) and &1 >= 0)),
         {:ok, length} <- Encoding.check(map, "length", &(is_integer(&1) and &1 > 0)),
         {:ok, request_ids} <- Encoding.check(map, "request_ids", &request_ids?/1),
         true <- {identifier, head, epoch} == {row.identifier, row.head_hash, row.key_epoch} do
      {:ok,
       %State{
         identifier: identifier,
         directory: directory,
         head: head,
         key_epoch: epoch,
         live_key: live,
         operational_key: operational,
         recovery_keys: recovery,
         revision: revision,
         length: length,
         request_ids: request_ids
       }}
    else
      _ -> :error
    end
  end

  defp request_ids?(ids), do: is_list(ids) and Enum.all?(ids, &Encoding.id?/1)

  defp system, do: Prima.Actor.system()
  defp now, do: System.monotonic_time(:millisecond)
end
