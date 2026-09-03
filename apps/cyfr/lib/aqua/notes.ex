# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Notes do
  @moduledoc """
  What somebody chose to keep out of a conversation.

  A tape is a record of what was said in a room — shared, erasable, and
  nobody's memory. A note is what was kept from it, and it survives the
  tape being erased, exactly as your notes survive the whiteboard. That is
  why `notes/` is its own storage root rather than a compaction of
  `conversations/`, and why retention on a thread can be honest: erase the
  whiteboard, everyone keeps their notes.

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

  A note carries who kept it, when, and — when known — the conversation and
  execution it came from, as frontmatter above the body. The reader is the
  one the agent files share, `Compendium.AquaAgent.parse_frontmatter/1`.

  This module is the domain. `Emissary.MCP.NotesTool` is the door people
  and agents come through; the host reads and writes here directly where
  no person is at the keyboard.
  """

  alias Sanctum.Context

  @root "notes"
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9 _.-]{0,80}\z/
  @pinned_names ~w(about-you about-us)
  @pin_max_bytes 2048
  @scopes ~w(estate mine everywhere)
  @snippet_chars 160

  @type scope :: String.t()
  @type provenance :: [kept_by: String.t(), conversation: String.t(), execution: String.t()]
  @type note :: %{
          name: String.t(),
          content: String.t(),
          athanor_id: String.t(),
          kept_by: String.t() | nil,
          kept_at: String.t() | nil,
          conversation: String.t() | nil,
          execution: String.t() | nil
        }
  @type refusal ::
          {:invalid_argument, String.t()} | {:not_found, String.t(), String.t()} | term()

  @doc "The storage root, as `Arca.Storage`'s layout names it."
  @spec root() :: String.t()
  def root, do: @root

  @doc "The pinned names: `about-you` in a person's athanor, `about-us` in an estate."
  @spec pinned_names() :: [String.t()]
  def pinned_names, do: @pinned_names

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
  chain may read across estates only from there — see `list/2`.
  """
  @spec at_home?(Context.t()) :: boolean()
  def at_home?(%Context{user_id: user_id, athanor_id: focus})
      when is_binary(user_id) and is_binary(focus) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{personal_athanor_id: ^focus}} -> true
      _ -> false
    end
  end

  def at_home?(_ctx), do: false

  @spec pinned?(String.t()) :: boolean()
  def pinned?(name), do: name in @pinned_names

  @doc "The byte cap on a pinned page — it is read into every turn."
  @spec pin_max_bytes() :: pos_integer()
  def pin_max_bytes, do: @pin_max_bytes

  @doc "The read scopes."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

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
          {:ok, %{kept: String.t(), athanor_id: String.t()}} | {:error, refusal()}
  def keep(%Context{} = ctx, name, content, provenance \\ []) when is_binary(content) do
    with :ok <- check_name(name),
         :ok <- refuse_pinned(name, "keep", "pin"),
         :ok <- Arca.put(ctx, path(name), encode(ctx, content, provenance)) do
      {:ok, %{kept: name, athanor_id: Context.athanor!(ctx)}}
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
      case Arca.delete(ctx, path(name)) do
        :ok -> {:ok, %{forgot: name, athanor_id: Context.athanor!(ctx)}}
        {:error, :not_found} -> {:error, {:not_found, "note", name}}
        other -> other
      end
    end
  end

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

  @doc """
  The filed notes of the focused estate as name and first line, sorted by
  name — what a turn is shown so it can read one on demand. No timestamps
  and no sizes, so the same pile renders the same bytes.
  """
  @spec index(Context.t()) :: {:ok, [%{name: String.t(), line: String.t()}]} | {:error, refusal()}
  def index(%Context{} = ctx) do
    with {:ok, names} <- names(ctx) do
      {:ok,
       for name <- names, not pinned?(name) do
         line =
           case Arca.get(ctx, path(name)) do
             {:ok, binary} -> ctx |> decode(name, binary) |> Map.fetch!(:content) |> first_line()
             _ -> ""
           end

         %{name: name, line: line}
       end}
    end
  end

  defp first_line(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
    |> String.slice(0, 120)
  end

  @doc "Every note name in the scope, with the estate each lives in."
  @spec list(Context.t(), scope()) ::
          {:ok, [%{name: String.t(), athanor_id: String.t()}]} | {:error, refusal()}
  def list(%Context{} = ctx, scope \\ "estate") do
    with {:ok, contexts} <- contexts(ctx, scope) do
      Enum.reduce_while(contexts, {:ok, []}, fn c, {:ok, acc} ->
        case names(c) do
          {:ok, names} ->
            {:cont, {:ok, acc ++ Enum.map(names, &%{name: &1, athanor_id: c.athanor_id})}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)
    end
  end

  @doc """
  One note with its provenance. `everywhere` is not a read scope — search
  it, then read where the note was found.
  """
  @spec read(Context.t(), String.t(), scope()) :: {:ok, note()} | {:error, refusal()}
  def read(ctx, name, scope \\ "estate")

  def read(%Context{}, _name, "everywhere") do
    {:error,
     {:invalid_argument,
      "read takes a scope of estate or mine — search everywhere, then read where the note was found"}}
  end

  def read(%Context{} = ctx, name, scope) do
    with :ok <- check_name(name),
         {:ok, [read_ctx]} <- contexts(ctx, scope) do
      fetch(read_ctx, name)
    end
  end

  @doc """
  Notes whose name or body contains `query` (case-insensitive), each with
  the first matching line as a snippet.
  """
  @spec search(Context.t(), String.t(), scope()) ::
          {:ok, [%{name: String.t(), athanor_id: String.t(), snippet: String.t()}]}
          | {:error, refusal()}
  def search(ctx, query, scope \\ "estate")

  def search(%Context{} = ctx, query, scope) when is_binary(query) do
    case query |> String.trim() |> String.downcase() do
      "" ->
        {:error, {:invalid_argument, "search needs a query"}}

      needle ->
        with {:ok, contexts} <- contexts(ctx, scope) do
          Enum.reduce_while(contexts, {:ok, []}, fn c, {:ok, acc} ->
            case matches(c, needle) do
              {:ok, hits} -> {:cont, {:ok, acc ++ hits}}
              {:error, _} = err -> {:halt, err}
            end
          end)
        end
    end
  end

  def search(%Context{}, _query, _scope),
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
      with :ok <- Arca.put(ctx, path(name), encode(ctx, body, provenance)) do
        {:ok, %{pinned: name, athanor_id: Context.athanor!(ctx)}}
      end
    end
  end

  # Clearing a page nobody set is already clear.
  defp clear(ctx, name) do
    case Arca.delete(ctx, path(name)) do
      :ok -> {:ok, %{cleared: name, athanor_id: Context.athanor!(ctx)}}
      {:error, :not_found} -> {:ok, %{cleared: name, athanor_id: Context.athanor!(ctx)}}
      other -> other
    end
  end

  defp fetch(ctx, name) do
    case Arca.get(ctx, path(name)) do
      {:ok, binary} -> {:ok, decode(ctx, name, binary)}
      _ -> {:error, {:not_found, "note", name}}
    end
  end

  # Only names the grammar admits are notes; anything else under the root
  # is not this module's to report.
  defp names(ctx) do
    case Arca.list_typed(ctx, [@root]) do
      {:ok, entries} ->
        {:ok, for({name, :file} <- entries, name =~ @name_format, do: name) |> Enum.sort()}

      {:error, reason} ->
        {:error, {:unavailable, "notes: #{inspect(reason)}"}}
    end
  end

  defp matches(ctx, needle) do
    with {:ok, names} <- names(ctx) do
      {:ok,
       Enum.flat_map(names, fn name ->
         case Arca.get(ctx, path(name)) do
           {:ok, binary} ->
             %{content: body} = decode(ctx, name, binary)

             case snippet(name, body, needle) do
               {:ok, snippet} -> [%{name: name, athanor_id: ctx.athanor_id, snippet: snippet}]
               :none -> []
             end

           _ ->
             []
         end
       end)}
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

  defp contexts(ctx, "estate"), do: {:ok, [ctx]}

  defp contexts(ctx, "mine") do
    with :ok <- guest_may_cross(ctx),
         {:ok, mine} <- personal(ctx),
         do: {:ok, [mine]}
  end

  # Every seat the person holds, the focus first. An estate the focus can
  # no longer open (archived between the listing and the read) is skipped,
  # not an error — the answer is what can be read now.
  defp contexts(%Context{} = ctx, "everywhere") do
    with :ok <- guest_may_cross(ctx) do
      others =
        for athanor <- Sanctum.Tenancy.list_athanors(ctx),
            athanor.id != ctx.athanor_id,
            {:ok, focused} <- [Context.focus(ctx, athanor)],
            do: focused

      {:ok, [ctx | others]}
    end
  end

  defp contexts(_ctx, other) do
    {:error,
     {:invalid_argument,
      "scope must be one of #{Enum.join(@scopes, ", ")}, got #{inspect(other)}"}}
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
  defp personal(%Context{user_id: user_id} = ctx) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{personal_athanor_id: id}} when is_binary(id) ->
        case Context.focus(ctx, id) do
          {:ok, focused} ->
            {:ok, focused}

          {:error, reason} ->
            {:error, {:invalid_argument, "your personal athanor cannot be opened (#{reason})"}}
        end

      _ ->
        {:error, {:invalid_argument, "you have no personal athanor"}}
    end
  end

  defp personal(_ctx), do: {:error, {:invalid_argument, "you have no personal athanor"}}

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
        {"conversation", Keyword.get(provenance, :conversation)},
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
      conversation: meta["conversation"],
      execution: meta["execution"]
    }
  end
end
