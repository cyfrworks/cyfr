# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Notes do
  @moduledoc """
  What somebody chose to keep out of a thread.

  Notes use their own storage root and survive deletion or retention
  cleanup of the threads they came from.

  ## One pile, two temperatures

  An estate has one flat pile. Two names in it are **pinned** — `about-you`
  in a person's own athanor, `about-us` in a shared one — and a pinned page
  is read into every turn, so it is held short (`pin_max_bytes/0`, refused
  rather than truncated). Everything else is **filed**: listed by name,
  read on demand. Pinning an empty page clears it; that is unpin.

  ## A note lands where you are

  Writes take no scope. `keep/4`, `pin/4` and `forget/2` act on the estate
  the context is focused on: your own when you are talking to your own
  assistant, the room's when you are in a room. A room's assistant cannot
  file into your private pile and nothing you keep at home reaches a room —
  the tenant boundary is the whole rule, and there is no argument to get it
  wrong with.

  Reads take a scope: `"estate"` (where you are; the default), `"mine"`
  (your own athanor, reached through `Sanctum.Context.focus/2` so
  membership and archival are checked, never by a raw swap), or
  `"everywhere"` (every estate you hold a seat in).

  ## Provenance

  A note carries who kept it, when, and — when known — the thread and
  execution it came from, as frontmatter above the body. The reader is the
  one the agent files share, `Compendium.AquaAgent.parse_frontmatter/1`.

  This module is the domain. Four callers read or write here:
  `Emissary.MCP.NotesTool`, the door people and agents come through;
  `Aqua.Prompt`, which reads the pinned page and the index into every
  turn; `Cyfr.ScheduleNotes`, which keeps a schedule's outcome where no
  person is at the keyboard; and `PrismWeb.AquaLive`, which edits the
  pinned page on the AQUA page.
  """

  require Logger

  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  # The layout (`Arca.Storage`) is where the root is declared — host-only,
  # by having no guest name; this module reads it and pins that it is a
  # tenant root of that layout, so the two cannot drift.
  @root "notes"
  true = @root in Arca.Storage.tenant_roots()
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9 _.-]{0,80}\z/
  @pinned_names ~w(about-you about-us)
  @pin_max_bytes 2048
  @scopes ~w(estate mine everywhere)
  @snippet_chars 160
  @index_limit 40

  @type scope :: String.t()
  @type provenance :: [kept_by: String.t(), thread: String.t(), execution: String.t()]
  @type note :: %{
          name: String.t(),
          content: String.t(),
          athanor_id: String.t(),
          kept_by: String.t() | nil,
          kept_at: String.t() | nil,
          thread: String.t() | nil,
          execution: String.t() | nil
        }
  @typedoc """
  What a call can refuse with — `Cyfr.Ops.Error`'s vocabulary, so
  every surface renders it as a sentence. A storage fault is folded in at
  this boundary (`storage_refusal/1`): the adapter's term goes to the log, the wire
  gets the one word every storage-backed tool answers with, and the
  estate's cap gets its own sentence because a retry will not lift it.
  """
  @type refusal ::
          {:invalid_argument, String.t()}
          | {:not_found, String.t(), String.t()}
          | {:unavailable, String.t()}

  @doc """
  The one pinned page this estate has: `about-you` in a person's own
  athanor, `about-us` in a shared one. The other name is refused at
  `pin/4` — an estate has one page, and which one is a fact about the
  estate, not a choice per call.
  """
  @spec pinned_page(Context.t()) :: {:ok, String.t()} | {:error, :not_found}
  def pinned_page(%Context{} = ctx) do
    case Sanctum.Tenancy.Athanors.get(Context.athanor!(ctx)) do
      {:ok, %{kind: "person"}} -> {:ok, "about-you"}
      {:ok, _} -> {:ok, "about-us"}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Whether the context is focused on the person's own athanor. A running
  chain may read across estates only from there — see `list/2`. The
  predicate itself is tenancy's (`Sanctum.Tenancy.Users.own_athanor?/2`);
  this is its spelling over a context.
  """
  @spec at_home?(Context.t()) :: boolean()
  def at_home?(%Context{user_id: user_id, athanor_id: focus}),
    do: Users.own_athanor?(user_id, focus)

  @spec pinned?(String.t()) :: boolean()
  def pinned?(name), do: name in @pinned_names

  @doc "The byte cap on a pinned page — it is read into every turn."
  @spec pin_max_bytes() :: pos_integer()
  def pin_max_bytes, do: @pin_max_bytes

  @doc """
  A note name is a filename under the estate's tree, so it is held to a
  grammar rather than trusted — letters, digits, spaces, `.`, `_` and `-`.
  """
  @spec check_name(term()) :: :ok | {:error, {:invalid_argument, String.t()}}
  def check_name(name) when is_binary(name) do
    if name =~ @name_format,
      do: :ok,
      else: {:error, {:invalid_argument, "a note name must be letters, digits, spaces, . _ or -"}}
  end

  def check_name(_), do: {:error, {:invalid_argument, "a note needs a name"}}

  # ---------------------------------------------------------------------------
  # Writes — the focused estate, no scope
  # ---------------------------------------------------------------------------

  @doc """
  File a note in the focused estate. A pinned name is refused — `pin/4` is
  the verb for those, and the difference (short, read every turn) is the
  point of having two.
  """
  @spec keep(Context.t(), String.t(), String.t(), provenance()) ::
          {:ok, %{kept: String.t(), athanor_id: String.t(), replaced: boolean()}}
          | {:error, refusal()}
  def keep(%Context{} = ctx, name, content, provenance \\ []) when is_binary(content) do
    with :ok <- check_name(name),
         :ok <- refuse_pinned(name, "keep", "pin"),
         # Keeping under a name that exists replaces what was there — said
         # so in the answer, so the tape can say so too, never silently.
         replaced? = Arca.exists?(Sanctum.Context.actor(ctx), path(name)),
         :ok <-
           written(
             Arca.put(Sanctum.Context.actor(ctx), path(name), encode(ctx, content, provenance))
           ) do
      {:ok, %{kept: name, athanor_id: Context.athanor!(ctx), replaced: replaced?}}
    end
  end

  @doc """
  Set a pinned page in the focused estate. Only the pinned names are
  accepted; a page over the cap is refused, not truncated — the person trims
  it or keeps the detail as a note. Empty content clears the page.
  """
  @spec pin(Context.t(), String.t(), String.t(), provenance()) ::
          {:ok, %{pinned: String.t(), athanor_id: String.t()}}
          | {:ok, %{cleared: String.t(), athanor_id: String.t()}}
          | {:error, refusal()}
  def pin(%Context{} = ctx, name, content, provenance \\ []) when is_binary(content) do
    with :ok <- check_name(name),
         :ok <- require_pinned(ctx, name) do
      case String.trim(content) do
        "" -> clear(ctx, name)
        body -> write_pinned(ctx, name, body, provenance)
      end
    end
  end

  @doc """
  Remove a filed note from the focused estate. A pinned page is cleared by
  pinning nothing, not forgotten — the two names always exist as slots.
  """
  @spec forget(Context.t(), String.t()) ::
          {:ok, %{forgot: String.t(), athanor_id: String.t()}} | {:error, refusal()}
  def forget(%Context{} = ctx, name) do
    with :ok <- check_name(name),
         :ok <- refuse_pinned(name, "forget", "pin with empty content to clear it") do
      case Arca.delete(Sanctum.Context.actor(ctx), path(name)) do
        :ok -> {:ok, %{forgot: name, athanor_id: Context.athanor!(ctx)}}
        {:error, :not_found} -> {:error, {:not_found, "note", name}}
        {:error, reason} -> {:error, storage_refusal(reason)}
      end
    end
  end

  @doc """
  One sentence for what a write answered — the line a tape shows when an
  approved card kept something, in the runner's voice. One per outcome
  this module mints (`keep/4` new or replacing, `pin/4` setting or
  clearing, `forget/2`), read from either key spelling since an answer
  may have crossed the wire; `nil` for anything that is not a write's
  answer, so a caller can post nothing rather than guess.
  """
  @spec describe(term()) :: String.t() | nil
  def describe(%{} = result) do
    field = fn key -> Map.get(result, key) || Map.get(result, Atom.to_string(key)) end

    cond do
      name = field.(:kept) ->
        if field.(:replaced), do: "📝 Replaced the note: #{name}", else: "📝 Kept a note: #{name}"

      name = field.(:pinned) ->
        "📝 Pinned #{name}"

      name = field.(:cleared) ->
        "📝 Cleared #{name}"

      name = field.(:forgot) ->
        "📝 Forgot the note: #{name}"

      true ->
        nil
    end
  end

  def describe(_result), do: nil

  # ---------------------------------------------------------------------------
  # Reads — scoped
  # ---------------------------------------------------------------------------

  @doc "The estate's pinned page with its provenance, or `:none` when nothing is pinned."
  @spec pinned(Context.t()) :: {:ok, note()} | :none
  def pinned(%Context{} = ctx) do
    with {:ok, name} <- pinned_page(ctx),
         {:ok, note} <- fetch(ctx, name) do
      {:ok, note}
    else
      _ -> :none
    end
  end

  @doc "How many filed notes the index shows a turn; the rest are found with `search/3`."
  @spec index_limit() :: pos_integer()
  def index_limit, do: @index_limit

  @doc """
  The filed notes of the focused estate as name and first line, sorted by
  name — what a turn is shown so it can read one on demand. No timestamps
  and no sizes, so the same pile renders the same bytes. Bounded to
  `index_limit/0` entries, with a count of what lies beyond: a pile an
  agent can grow must not grow every prompt with it.
  """
  @spec index(Context.t()) ::
          {:ok, %{entries: [%{name: String.t(), line: String.t()}], more: non_neg_integer()}}
          | {:error, refusal()}
  def index(%Context{} = ctx) do
    with {:ok, names} <- names(ctx) do
      {shown, beyond} =
        names
        |> Enum.reject(&pinned?/1)
        |> Enum.split(@index_limit)

      entries =
        for name <- shown do
          line =
            case Arca.get(Sanctum.Context.actor(ctx), path(name)) do
              {:ok, binary} -> ctx |> decode(name, binary) |> Map.fetch!(:content) |> first_line()
              _ -> ""
            end

          %{name: name, line: line}
        end

      {:ok, %{entries: entries, more: length(beyond)}}
    end
  end

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.slice(0, 120)
  end

  # A page: how many a read answers at most, whatever it was asked for.
  @page_limit 100
  @page_max 500

  @typedoc """
  A page of notes — `notes`, whether `more` lie beyond it, and the `next`
  cursor to continue from (`"<athanor_id>/<name>"`, the last one shown).
  One budget across every estate a scope names, in a fixed order — the
  focus first, then the person's other estates by id, names sorted — so a
  page and its successor never overlap or skip.
  """
  @type page(entry) :: %{notes: [entry], more: boolean(), next: String.t() | nil}

  @doc "The largest page a read answers."
  @spec page_max() :: pos_integer()
  def page_max, do: @page_max

  @doc """
  The note names in the scope, with the estate each lives in — a page of
  them (`t:page/1`). `opts`: `:limit` (default #{@page_limit}, at most
  #{@page_max}), `:after` (a cursor from a previous page).
  """
  @spec list(Context.t(), scope(), keyword()) ::
          {:ok, page(%{name: String.t(), athanor_id: String.t()})} | {:error, refusal()}
  def list(%Context{} = ctx, scope \\ "estate", opts \\ []) do
    walk(ctx, scope, opts, fn c, name -> [%{name: name, athanor_id: c.athanor_id}] end)
  end

  # One walk for `list/3` and `search/4`: the scope's estates in their
  # fixed order, each estate's names sorted, resumed after the cursor, and
  # `visit` asked about each name until the page is full. The work is
  # bounded by the page, not by the pile: a name past the page is never
  # visited (for a search, never read). A visit answers the hits a name
  # yields — none, for a search that misses or a note that cannot be read.
  defp walk(ctx, scope, opts, visit) do
    limit = opts |> Keyword.get(:limit) |> page_limit()

    with {:ok, contexts} <- contexts(ctx, scope),
         {:ok, cursor} <- cursor(Keyword.get(opts, :after)),
         {:ok, contexts} <- from_cursor(contexts, cursor) do
      contexts
      |> Enum.reduce_while({:ok, [], nil}, fn c, {:ok, acc, next} ->
        if length(acc) > limit do
          {:halt, {:ok, acc, next}}
        else
          case names(c) do
            {:ok, names} ->
              names
              |> after_cursor(c.athanor_id, cursor)
              |> Enum.reduce_while({:ok, acc, next}, fn name, {:ok, acc, next} ->
                if length(acc) > limit do
                  {:halt, {:ok, acc, next}}
                else
                  case visit.(c, name) do
                    [] -> {:cont, {:ok, acc, next}}
                    hits -> {:cont, {:ok, acc ++ hits, {c.athanor_id, name}}}
                  end
                end
              end)
              |> then(&{:cont, &1})

            {:error, _} = err ->
              {:halt, err}
          end
        end
      end)
      |> case do
        {:ok, hits, _next} when length(hits) > limit ->
          shown = Enum.take(hits, limit)
          last = List.last(shown)
          {:ok, %{notes: shown, more: true, next: encode_cursor({last.athanor_id, last.name})}}

        {:ok, hits, _next} ->
          {:ok, %{notes: hits, more: false, next: nil}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp page_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @page_max)
  defp page_limit(_), do: @page_limit

  defp cursor(nil), do: {:ok, nil}

  defp cursor(after_) when is_binary(after_) do
    case String.split(after_, "/", parts: 2) do
      [athanor_id, name] when athanor_id != "" and name != "" -> {:ok, {athanor_id, name}}
      _ -> {:error, {:invalid_argument, "after must be a cursor a previous page answered"}}
    end
  end

  defp cursor(_),
    do: {:error, {:invalid_argument, "after must be a cursor a previous page answered"}}

  defp encode_cursor({athanor_id, name}), do: athanor_id <> "/" <> name

  # Resume after the cursor. Estates are visited in the scope's fixed
  # order: those before the cursor's were shown whole and are dropped, the
  # cursor's continues past the name, later ones start at their
  # beginning. A cursor naming an estate the scope does not hold — a
  # different scope, a seat since lost — is not a place to resume from.
  defp from_cursor(contexts, nil), do: {:ok, contexts}

  defp from_cursor(contexts, {cursor_athanor, _name}) do
    case Enum.drop_while(contexts, &(&1.athanor_id != cursor_athanor)) do
      [] -> {:error, {:invalid_argument, "after names an estate this scope does not hold"}}
      rest -> {:ok, rest}
    end
  end

  defp after_cursor(names, _athanor_id, nil), do: names

  defp after_cursor(names, athanor_id, {cursor_athanor, cursor_name}) do
    if athanor_id == cursor_athanor, do: Enum.filter(names, &(&1 > cursor_name)), else: names
  end

  @doc """
  One note with its provenance. `everywhere` is not a read scope: a
  search answers the estate each match lives in, and a read follows it
  with the `:athanor_id` locator — the one estate, opened under the
  reader's own seat (`Sanctum.Context.focus/2`: membership and archive
  checked), and never from a room's chain, which reads its own pile alone.
  """
  @spec read(Context.t(), String.t(), scope(), keyword()) :: {:ok, note()} | {:error, refusal()}
  def read(ctx, name, scope \\ "estate", opts \\ [])

  def read(%Context{}, _name, "everywhere", _opts) do
    {:error,
     {:invalid_argument,
      "read takes a scope of estate or mine, or the athanor_id a search answered — " <>
        "search everywhere, then read where the note was found"}}
  end

  def read(%Context{} = ctx, name, scope, opts) do
    with :ok <- check_name(name),
         {:ok, read_ctx} <- read_context(ctx, scope, Keyword.get(opts, :athanor_id)) do
      fetch(read_ctx, name)
    end
  end

  @doc """
  Notes whose name or body contains `query` (case-insensitive), each with
  the first matching line as a snippet — a page of them (`t:page/1`), the
  same `:limit`/`:after` as `list/3`. Only the notes a page can show are
  read.
  """
  @spec search(Context.t(), String.t(), scope(), keyword()) ::
          {:ok, page(%{name: String.t(), athanor_id: String.t(), snippet: String.t()})}
          | {:error, refusal()}
  def search(ctx, query, scope \\ "estate", opts \\ [])

  def search(%Context{} = ctx, query, scope, opts) when is_binary(query) do
    case query |> String.trim() |> String.downcase() do
      "" -> {:error, {:invalid_argument, "search needs a query"}}
      needle -> walk(ctx, scope, opts, &match(&1, &2, needle))
    end
  end

  def search(%Context{}, _query, _scope, _opts),
    do: {:error, {:invalid_argument, "search needs a query"}}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp path(name), do: [@root, name]

  defp refuse_pinned(name, verb, instead) do
    if pinned?(name),
      do: {:error, {:invalid_argument, "'#{name}' is a pinned page — #{instead}, not #{verb}"}},
      else: :ok
  end

  defp require_pinned(ctx, name) do
    cond do
      not pinned?(name) ->
        {:error,
         {:invalid_argument,
          "pin takes one of #{Enum.join(@pinned_names, ", ")} — keep files everything else"}}

      true ->
        case pinned_page(ctx) do
          {:ok, ^name} ->
            :ok

          {:ok, other} ->
            {:error, {:invalid_argument, "this estate's pinned page is #{other}, not #{name}"}}

          {:error, :not_found} ->
            {:error, {:invalid_argument, "the estate in focus could not be read"}}
        end
    end
  end

  defp write_pinned(ctx, name, body, provenance) do
    size = byte_size(body)

    if size > @pin_max_bytes do
      {:error,
       {:invalid_argument,
        "a pinned page holds at most #{@pin_max_bytes} bytes and this one is #{size} — " <>
          "trim it, or keep the detail as a note"}}
    else
      with :ok <-
             written(
               Arca.put(Sanctum.Context.actor(ctx), path(name), encode(ctx, body, provenance))
             ) do
        {:ok, %{pinned: name, athanor_id: Context.athanor!(ctx)}}
      end
    end
  end

  # Clearing a page nobody set is already clear.
  defp clear(ctx, name) do
    case Arca.delete(Sanctum.Context.actor(ctx), path(name)) do
      :ok -> {:ok, %{cleared: name, athanor_id: Context.athanor!(ctx)}}
      {:error, :not_found} -> {:ok, %{cleared: name, athanor_id: Context.athanor!(ctx)}}
      {:error, reason} -> {:error, storage_refusal(reason)}
    end
  end

  # A write's answer at this module's boundary — the same line `names/1`
  # holds for reads.
  @spec written(:ok | {:error, term()}) :: :ok | {:error, refusal()}
  defp written(:ok), do: :ok
  defp written({:error, reason}), do: {:error, storage_refusal(reason)}

  # The estate's cap is the one storage refusal a person can act on, so it
  # keeps a sentence of its own; everything else (a plane that may not
  # write here, an adapter fault, a cap that could not be measured) is
  # logged with the adapter's term and answered with the one word every
  # storage-backed tool gives, which is the honest one: retry.
  @spec storage_refusal(term()) :: refusal()
  defp storage_refusal({:limit_reached, :athanor_storage_bytes, cap}) do
    {:invalid_argument,
     "the estate's storage cap of #{cap} bytes is reached — forget a note, or keep less"}
  end

  defp storage_refusal(reason) do
    Logger.error("[Aqua.Notes] storage refused a write: #{inspect(reason)}")
    {:unavailable, "Notes"}
  end

  defp fetch(ctx, name) do
    case Arca.get(Sanctum.Context.actor(ctx), path(name)) do
      {:ok, binary} -> {:ok, decode(ctx, name, binary)}
      _ -> {:error, {:not_found, "note", name}}
    end
  end

  # Only names the grammar admits are notes; anything else under the root
  # is not this module's to report.
  defp names(ctx) do
    case Arca.list_typed(Sanctum.Context.actor(ctx), [@root]) do
      {:ok, entries} ->
        {:ok, for({name, :file} <- entries, name =~ @name_format, do: name) |> Enum.sort()}

      {:error, reason} ->
        # The adapter's term is for the log; the wire gets the one word
        # every storage-backed tool answers with.
        Logger.error("[Aqua.Notes] the notes root could not be listed: #{inspect(reason)}")
        {:error, {:unavailable, "Notes"}}
    end
  end

  defp match(ctx, name, needle) do
    case Arca.get(Sanctum.Context.actor(ctx), path(name)) do
      {:ok, binary} ->
        %{content: body} = decode(ctx, name, binary)

        case snippet(name, body, needle) do
          {:ok, snippet} -> [%{name: name, athanor_id: ctx.athanor_id, snippet: snippet}]
          :none -> []
        end

      _ ->
        []
    end
  end

  defp snippet(name, body, needle) do
    lines = String.split(body, "\n")

    case Enum.find(lines, &String.contains?(String.downcase(&1), needle)) do
      nil ->
        if String.contains?(String.downcase(name), needle),
          do: {:ok, lines |> List.first("") |> String.trim() |> String.slice(0, @snippet_chars)},
          else: :none

      line ->
        {:ok, line |> String.trim() |> String.slice(0, @snippet_chars)}
    end
  end

  # ---------------------------------------------------------------------------
  # Scope → contexts
  # ---------------------------------------------------------------------------

  # The one estate a read names: the locator a search answered, else
  # `estate` (the focus) or `mine` (the person's own). `everywhere` is not
  # one estate, so it is not a read scope. A locator for the focus is the
  # focus; any other estate is opened under the reader's seat, and never
  # from a room's chain.
  defp read_context(ctx, _scope, athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    cond do
      athanor_id == ctx.athanor_id -> {:ok, ctx}
      true -> with :ok <- guest_may_cross(ctx), do: locate(ctx, athanor_id)
    end
  end

  defp read_context(ctx, "estate", _none), do: {:ok, ctx}

  defp read_context(ctx, "mine", _none) do
    with :ok <- guest_may_cross(ctx), do: personal(ctx)
  end

  defp read_context(_ctx, other, _none) do
    {:error,
     {:invalid_argument,
      "scope must be one of #{Enum.join(@scopes, ", ")}, got #{inspect(other)}"}}
  end

  # The estate a locator names, as the reader may open it: a seat they do
  # not hold, or an archived estate, reads as no such note — the locator
  # is not a way to learn which estates exist.
  defp locate(ctx, athanor_id) do
    case Context.focus(ctx, athanor_id) do
      {:ok, focused} -> {:ok, focused}
      {:error, _} -> {:error, {:not_found, "estate", athanor_id}}
    end
  end

  # Every seat the person holds, the focus first. An estate the focus can
  # no longer open (archived between the listing and the read) is skipped,
  # not an error — the answer is what can be read now.
  defp contexts(%Context{} = ctx, "everywhere") do
    with :ok <- guest_may_cross(ctx) do
      others =
        for athanor <- Enum.sort_by(Sanctum.Tenancy.list_athanors(ctx), & &1.id),
            athanor.id != ctx.athanor_id,
            {:ok, focused} <- [Context.focus(ctx, athanor)],
            do: focused

      {:ok, [ctx | others]}
    end
  end

  defp contexts(ctx, scope) do
    with {:ok, one} <- read_context(ctx, scope, nil), do: {:ok, [one]}
  end

  # A running chain reads across estates only from the person's own
  # athanor. In a room, the room's assistant sees the room's pile and
  # nothing else — a private ledger is not something a shared turn can
  # open, however politely it asks. The person can, from their own
  # assistant or from the door.
  defp guest_may_cross(%Context{plane: :guest} = ctx) do
    if at_home?(ctx),
      do: :ok,
      else:
        {:error,
         {:invalid_argument,
          "a room's assistant reads only the room's notes — look in your own from your own assistant"}}
  end

  defp guest_may_cross(_ctx), do: :ok

  # "Mine" is the person's own athanor, reached through `Context.focus/2` —
  # the audited narrowing entry, not a raw struct update: focus checks
  # membership (production seats the owner in their personal athanor at
  # mint, `Sanctum.Provisioning.ensure_personal_athanor/1`) and refuses an
  # archived athanor, both of which a bare `%{ctx | athanor_id: id}` would
  # skip.
  defp personal(%Context{user_id: user_id} = ctx) do
    with {:ok, id} <- Users.personal_athanor_id(user_id),
         {:ok, focused} <- Context.focus(ctx, id) do
      {:ok, focused}
    else
      :none ->
        {:error, {:invalid_argument, "you have no personal athanor"}}

      {:error, reason} ->
        {:error, {:invalid_argument, "your personal athanor cannot be opened (#{reason})"}}
    end
  end

  # ---------------------------------------------------------------------------
  # On disk: provenance frontmatter over the body
  # ---------------------------------------------------------------------------

  # Values are JSON-encoded strings, which is the one YAML scalar spelling
  # that cannot be misread whatever the id or timestamp contains.
  defp encode(ctx, content, provenance) do
    meta =
      [
        {"kept_by", Keyword.get(provenance, :kept_by) || ctx.user_id || "system"},
        {"kept_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()},
        {"thread", Keyword.get(provenance, :thread)},
        {"execution", Keyword.get(provenance, :execution)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    IO.iodata_to_binary([
      "---\n",
      Enum.map(meta, fn {key, value} -> [key, ": ", Jason.encode!(to_string(value)), "\n"] end),
      "---\n\n",
      String.trim_trailing(content),
      "\n"
    ])
  end

  defp decode(ctx, name, binary) do
    {meta, body} =
      case Compendium.AquaAgent.parse_frontmatter(binary) do
        {:ok, meta, body} -> {meta, body}
        {:error, _} -> {%{}, binary}
      end

    %{
      name: name,
      content: body,
      athanor_id: ctx.athanor_id,
      kept_by: meta["kept_by"],
      kept_at: meta["kept_at"],
      thread: meta["thread"],
      execution: meta["execution"]
    }
  end
end
