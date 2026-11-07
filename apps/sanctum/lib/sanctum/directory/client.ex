# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Directory.Client do
  @moduledoc """
  This home's client for any directory, `cyfr-directory/v2`
  (`ARCHITECTURE.md` §9.1): registering a genesis, appending an entry, and
  reading an account's log, from its genesis or after an entry's hash.
  `tests/fixtures/directory_wire.json` holds the wire it speaks.

  ## Which directory

  A genesis names its own directory, and `register/2` posts it there. Every
  other call takes the identifier and the directory URL the caller holds
  for it: the one a cached head's genesis named, a handle's answer named
  or a genesis the caller holds names. A directory URL names the node
  serving it, with any path its proxy adds; the protocol's paths,
  `/directory/v1/…`, follow it. A CYFR serving one serves it at its origin
  alone (`Sanctum.Directory`).

  A log whose directory is this node's own, where this node serves the
  account service (`directory_serve` `writer`, `Sanctum.Directory.writer?/0`),
  is read where it is kept (`Sanctum.Directory.read/2`), never over HTTP to
  this node: its listener need not answer on the address its origin names,
  as in the shipped stack, where it binds the edge network's address. The
  directory URL and this node's origin are compared in the one spelling a
  genesis names its directory in (`Sanctum.Directory.served/0`). The pages
  are the ones `GET /directory/v1/…` answers, `:gone` and every other
  refusal as the wire would carry it, so a caller reads the same answers
  either way; the per-source windows that bound callers over the network
  are not spent. Every other directory, a node that serves none, or one
  that mirrors, is read over the wire. Writes always go over the wire.

  The client verifies no chain: its reads answer the entries, each page
  linked to the one before it (its first position, its `next`, its size),
  with the head and length the last page named, and the caller verifies
  them (`Sanctum.IdentityFreshness`). A write answers the directory's
  `result` for exactly the entry sent.

  ## Transport

  HTTPS, or plain HTTP to a loopback host (`localhost`, `127.0.0.0/8` or
  `::1`, `Sanctum.loopback_host?/1`), and nothing else
  (`:insecure_directory`, before any request): TLS protects a network
  path, loopback has none, and a directory is trusted only for ordering,
  since its writes carry signatures and its reads are verified chains
  (`Sanctum.directory_transport?/1`). Every request goes over
  `Sanctum.Egress.pinned_request/5` under `private_policy: :operator`: a
  loopback or private address is refused unless the operator lists it in
  `CYFR_PRIVATE_EGRESS_TARGETS`, a metadata address always, and a redirect
  is never followed (`:redirected`). No credential or cookie is sent. Each
  request is bounded to 10 seconds and 64 KiB, an operation to 30 seconds,
  and a read to 1,000 pages. This member sheds its own requests to one
  directory origin past 300 a minute, locally and retryably.

  The trailing `opts` take only `:resolver` (a module answering
  `getaddr/2` as `:inet` does) and `:cacerts` (DER certificates to trust):
  the address policy and peer verification are not options. The suite
  sets the same two through the test seam `:sanctum, :directory_client`,
  which no configuration file or variable sets, so the paths that read a
  directory without options reach its scripted one; a caller's options
  win over it.

  ## Answers

  A write answers `%{identifier, seq, entry_hash, result}`, `result`
  `:created` or `:accepted`, or `:exists` with `head`, the current head,
  for an entry already written. A read answers `%{entries, head, length}`:
  the entries as the directory sent them, in log order, and the head and
  length its last page named.

  ## Refusals

  Before any request: `:invalid_entry` (bytes that are no signed entry of
  the kind the call takes, or a genesis naming no directory this home
  speaks to), `:invalid_locator` (an identifier, directory or hash out of
  its grammar) and `:insecure_directory`. The transport's:
  `:egress_refused`, `:unreachable`, `:timeout`, `:redirected`,
  `:response_too_large`, `:invalid_response`, and `{:rate_limited,
  seconds}` from this member's shed. The directory's
  (`Emissary.Web.DirectoryController`'s codes): `:not_served`,
  `:not_found` (no such identifier, or a hash the log does not hold),
  `:read_only`, `:body_too_large`, `{:stale_head, head}`,
  `:duplicate_key`, `:conflict`, `:gone` (410, the account tombstoned),
  `{:refused, :invalid | :unverified | :wrong_directory, reason | nil}`,
  `:corrupt`, and the retryable `{:rate_limited, seconds}`, `{:capacity,
  seconds}` (a quota, or an identifier's day of writes, up to a day) and
  `{:unavailable, seconds}`. A read's own: `:invalid_page` and
  `:too_many_pages`.
  """

  require Logger

  alias Prima.Identity
  alias Prima.Identity.{Encoding, Entry}

  @path "/directory/v1"
  # Compiled in: `config/test.exs` shortens it so the suite's unanswered
  # requests do not wait out a production bound. Never read at runtime.
  @request_ms Application.compile_env(:sanctum, :directory_request_ms, 10_000)
  @operation_ms 30_000
  @max_pages 1_000
  @page_entries 100
  @response_bytes 65_536
  @origin_cap 300
  @window_ms 60_000
  # A directory's longest honest wait is its day's write window.
  @max_retry_after 86_400

  @typedoc "An entry as a caller holds it: the struct, its JSON map, or its JSON bytes."
  @type entry :: Entry.t() | map() | binary()

  @typedoc "The only options: a resolver and the certificates to trust."
  @type opts :: [resolver: module(), cacerts: [binary()]]

  @typedoc "Why an operation did not complete; the moduledoc groups them."
  @type reason :: atom() | {atom(), term()} | {:refused, atom(), String.t() | nil}

  @typedoc "A write's answer: `head` is present for `:exists` alone."
  @type written :: %{
          required(:identifier) => String.t(),
          required(:seq) => non_neg_integer(),
          required(:entry_hash) => String.t(),
          required(:result) => :created | :accepted | :exists,
          optional(:head) => String.t()
        }

  @typedoc "A read's answer: the entries' JSON maps, in log order."
  @type log :: %{entries: [map()], head: String.t(), length: pos_integer()}

  # ---- the writes --------------------------------------------------------------

  @doc """
  Register `genesis` at the directory it names: `:created`, or `:exists`
  for the same genesis registered before.
  """
  @spec register(entry(), opts()) :: {:ok, written()} | {:error, reason()}
  def register(genesis, opts \\ []) do
    with {:ok, %Entry{kind: :genesis} = entry} <- entry(genesis),
         {:ok, ctx} <- context(Identity.identifier(entry), entry.directory, opts),
         {:ok, body} <- call(ctx, :post, "/register", Identity.canonical(entry)) do
      written(body, ctx.identifier, Identity.hash(entry), [:created, :exists])
    else
      {:ok, %Entry{}} -> {:error, :invalid_entry}
      {:error, _reason} = refusal -> refusal
    end
  end

  @doc """
  Append one signed `entry` to `identifier`'s log at `directory`, naming in
  its `prev` the head it extends: `:accepted`, or `:exists` for the entry
  already the one after its `prev`. A genesis is `:invalid_entry`.
  """
  @spec append(String.t(), String.t(), entry(), opts()) :: {:ok, written()} | {:error, reason()}
  def append(identifier, directory, entry, opts \\ []) do
    with {:ok, %Entry{kind: kind} = entry} when kind != :genesis <- entry(entry),
         {:ok, ctx} <- context(identifier, directory, opts),
         {:ok, body} <-
           call(ctx, :post, "/" <> identifier <> "/append", Identity.canonical(entry)) do
      written(body, identifier, Identity.hash(entry), [:accepted, :exists])
    else
      {:ok, %Entry{kind: :genesis}} -> {:error, :invalid_entry}
      {:error, _reason} = refusal -> refusal
    end
  end

  # ---- the reads ---------------------------------------------------------------

  @doc "Every entry of `identifier`'s log at `directory`, from its genesis."
  @spec log(String.t(), String.t(), opts()) :: {:ok, log()} | {:error, reason()}
  def log(identifier, directory, opts \\ []) do
    with {:ok, ctx} <- read_context(identifier, directory, opts),
         {:ok, body} <- fetch(ctx, {:after, -1}),
         {:ok, page} <- page(body, identifier, -1) do
      read_on(ctx, page, [page.entries], 1)
    end
  end

  @doc """
  The entries of `identifier`'s log at `directory` after the entry hashing
  to `hash`, which sits at position `seq`: none at the head. A hash the log
  does not hold is `:not_found`.
  """
  @spec entries_after(String.t(), String.t(), String.t(), non_neg_integer(), opts()) ::
          {:ok, log()} | {:error, reason()}
  def entries_after(identifier, directory, hash, seq, opts \\ [])

  def entries_after(identifier, directory, hash, seq, opts)
      when is_binary(hash) and is_integer(seq) and seq >= 0 do
    with :ok <- locator(Encoding.digest?(hash)),
         {:ok, ctx} <- read_context(identifier, directory, opts),
         {:ok, body} <- fetch(ctx, {:from, hash}),
         {:ok, page} <- page(body, identifier, seq) do
      read_on(ctx, page, [page.entries], 1)
    end
  end

  def entries_after(_identifier, _directory, _hash, _seq, _opts),
    do: {:error, :invalid_locator}

  # ---- before any request ------------------------------------------------------

  defp entry(%Entry{} = entry), do: entry |> Entry.encode() |> entry()

  defp entry(bytes) when is_binary(bytes) do
    case Prima.Json.decode(bytes) do
      {:ok, %{} = map} -> entry(map)
      _other -> {:error, :invalid_entry}
    end
  end

  defp entry(%{} = map) do
    case Entry.decode(map) do
      {:ok, entry} -> {:ok, entry}
      {:error, _reason} -> {:error, :invalid_entry}
    end
  end

  defp entry(_value), do: {:error, :invalid_entry}

  defp locator(true), do: :ok
  defp locator(false), do: {:error, :invalid_locator}

  # A read of a log this node serves as its account service's is made where
  # it is kept (the module doc); any other, over the wire.
  defp read_context(identifier, directory, opts) do
    options!(opts)

    with :ok <- locator(Encoding.identifier?(identifier) and Encoding.directory_url?(directory)) do
      if served_here?(directory),
        do: {:ok, %{identifier: identifier, local: true}},
        else: context(identifier, directory, opts)
    end
  end

  defp served_here?(directory) do
    with {:ok, spelled} <- Encoding.canonical_home(directory),
         {:ok, ^spelled} <- Sanctum.Directory.served() do
      Sanctum.Directory.writer?()
    else
      _elsewhere -> false
    end
  end

  defp context(identifier, directory, opts) do
    opts = options!(opts)

    with :ok <- locator(Encoding.identifier?(identifier) and Encoding.directory_url?(directory)),
         {:ok, base, origin} <- target(directory) do
      {:ok,
       %{
         identifier: identifier,
         local: false,
         base: base,
         origin: origin,
         transport: transport(opts),
         deadline: now() + @operation_ms
       }}
    end
  end

  # A caller's options over the suite's (`:sanctum, :directory_client`, a
  # test seam no configuration file or variable sets), each validated the
  # same way: so a suite reaches its scripted directory through paths that
  # pass no options, and a release, which never sets the key, uses the
  # system's resolver and certificate store.
  defp options!(opts) when is_list(opts) do
    seam = Application.get_env(:sanctum, :directory_client, [])
    Keyword.merge(validated!(seam), validated!(opts))
  end

  defp validated!(opts) when is_list(opts) do
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

  # A directory URL is already a validated spelling
  # (`Prima.Identity.Encoding.directory_url?/1`); HTTPS is spoken, or
  # plain HTTP to a loopback host (`Sanctum.directory_transport?/1`).
  defp target(directory) do
    with true <- Sanctum.directory_transport?(directory),
         %URI{scheme: scheme, host: host, port: port} <- URI.parse(directory) do
      origin =
        if port == URI.default_port(scheme),
          do: "#{scheme}://#{host}",
          else: "#{scheme}://#{host}:#{port}"

      {:ok, directory <> @path, origin}
    else
      _insecure -> {:error, :insecure_directory}
    end
  end

  defp transport(opts) do
    base = [private_policy: :operator, max_response_bytes: @response_bytes]
    base = if opts[:resolver], do: Keyword.put(base, :resolver, opts[:resolver]), else: base

    if opts[:cacerts],
      do: Keyword.put(base, :transport_opts, cacerts: opts[:cacerts]),
      else: base
  end

  # ---- one page ----------------------------------------------------------------

  # One page of a log, from this node's own directory where it is kept, or
  # over the wire.
  defp fetch(%{local: true, identifier: identifier}, at) do
    case Sanctum.Directory.read(identifier, at) do
      {:ok, page} -> served_page(page)
      {:error, reason} -> {:error, served_refusal(reason)}
    end
  end

  defp fetch(ctx, {:after, after_seq}),
    do: call(ctx, :get, "/#{ctx.identifier}?after=#{after_seq}", nil)

  defp fetch(ctx, {:from, hash}), do: call(ctx, :get, "/#{ctx.identifier}/from/#{hash}", nil)

  # The page as the directory's route sends it, its stored entries decoded
  # as a response body's are, so the reader checks it as it checks one
  # that came over the wire.
  defp served_page(page) do
    decoded = Enum.map(page.entries, &Jason.decode/1)

    if Enum.all?(decoded, &match?({:ok, %{}}, &1)) do
      {:ok,
       %{
         "identifier" => page.identifier,
         "from" => page.from,
         "entries" => Enum.map(decoded, &elem(&1, 1)),
         "next" => page.next,
         "head" => page.head,
         "length" => page.length
       }}
    else
      {:error, :invalid_response}
    end
  end

  # A refusal as the directory's route would carry it and `refusal/3` read
  # it back (`Emissary.Web.DirectoryController`'s codes).
  defp served_refusal(reason) when reason in [:not_served, :not_found, :gone, :corrupt],
    do: reason

  defp served_refusal({:invalid, {tag, _field}}) when is_atom(tag),
    do: {:refused, :invalid, Atom.to_string(tag)}

  defp served_refusal({:invalid, reason}) when is_atom(reason),
    do: {:refused, :invalid, Atom.to_string(reason)}

  defp served_refusal({:capacity, _which}), do: {:capacity, 60}
  defp served_refusal(_unavailable), do: {:unavailable, 1}

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

  # A refusal the pinned transport made before connecting carries its type:
  # a host that does not resolve is the network's, and retryable; every
  # other refusal is the address policy's.
  defp answer({:error, {:refused, type, message}}) do
    Logger.warning("[Sanctum.Directory.Client] a directory request was refused: #{message}")

    if type == :dns_error,
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
  defp refusal(410, %{"error" => "gone"}, _headers), do: :gone
  defp refusal(413, _body, _headers), do: :body_too_large

  defp refusal(409, %{"error" => "stale_head", "head" => head}, _headers) when is_binary(head) do
    if Encoding.digest?(head), do: {:stale_head, head}, else: :invalid_response
  end

  defp refusal(409, %{"error" => "duplicate_key"}, _headers), do: :duplicate_key
  defp refusal(409, _body, _headers), do: :conflict

  defp refusal(422, %{"error" => "unverified"} = body, _headers),
    do: {:refused, :unverified, reason_text(body)}

  defp refusal(422, %{"error" => "wrong_directory"}, _headers),
    do: {:refused, :wrong_directory, nil}

  defp refusal(422, body, _headers), do: {:refused, :invalid, reason_text(body)}
  defp refusal(429, _body, headers), do: {:rate_limited, retry_after(headers)}
  defp refusal(503, %{"error" => "capacity"}, headers), do: {:capacity, retry_after(headers)}
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

  # The write's answer for exactly the entry sent: its identifier, its hash,
  # a result the call takes, and for `exists` the head it names.
  defp written(body, identifier, hash, results) do
    with %{"identifier" => ^identifier, "seq" => seq, "entry_hash" => ^hash, "result" => word}
         when is_integer(seq) and seq >= 0 <- body,
         {:ok, result} <- result(word, results),
         {:ok, head} <- exists_head(result, body) do
      answer = %{identifier: identifier, seq: seq, entry_hash: hash, result: result}
      {:ok, if(head, do: Map.put(answer, :head, head), else: answer)}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp result(word, results) do
    case Enum.find(results, &(Atom.to_string(&1) == word)) do
      nil -> :error
      result -> {:ok, result}
    end
  end

  defp exists_head(:exists, %{"head" => head}) when is_binary(head) do
    if Encoding.digest?(head), do: {:ok, head}, else: :error
  end

  defp exists_head(:exists, _body), do: :error
  defp exists_head(_result, _body), do: {:ok, nil}

  # Every page after the first, from its `next`, until one names none.
  defp read_on(_ctx, _page, _pages, @max_pages), do: {:error, :too_many_pages}

  defp read_on(_ctx, %{next: nil} = page, pages, _count) do
    entries = pages |> Enum.reverse() |> Enum.concat()
    {:ok, %{entries: entries, head: page.head, length: page.length}}
  end

  defp read_on(ctx, %{next: next}, pages, count) do
    with {:ok, body} <- fetch(ctx, {:after, next}),
         {:ok, page} <- page(body, ctx.identifier, next) do
      read_on(ctx, page, [page.entries | pages], count + 1)
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

  defp now, do: System.monotonic_time(:millisecond)
end
