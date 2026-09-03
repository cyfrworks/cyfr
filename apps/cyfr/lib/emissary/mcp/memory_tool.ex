# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.MemoryTool do
  @moduledoc """
  Notes an agent kept for someone: the `memory` tool.

  A transcript and a memory are different objects, and conflating them is
  what made "delete this conversation" a lie. The tape is a record of what
  was said in a room — shared, erasable, and not anybody's memory. A note
  is what somebody chose to keep out of it, and it survives the tape being
  erased, exactly as your notes survive the whiteboard.

  That is why `memory/` is its own storage root rather than a compaction of
  `conversations/`, and why retention on a thread can now be honest: erase
  the whiteboard, everyone keeps their notes.

  ## A person's surface

  Every action declares `consent: :interactive`: notes are kept, read and
  forgotten by a person's own session, never by a standing credential — an
  API key (a `*` key included) is refused at the registry's dispatch gate
  and does not see the tool in `tools/list`. The host-only storage root
  stops the *guest*; this gate stops the credential. Same two axes, same
  reason, as the `conversation` tool.

  ## Whose notes

  Every note lives in an athanor, and which athanor **is** the consent
  question: your own, or the estate you are working in. It is asked of a
  person at the moment they keep something — `"scope" => "mine" | "estate"`
  — never inferred, and never decided by a model mid-turn. That is also why
  the root is host-only at the guest boundary (`Arca.Storage`'s layout
  gives it no guest name): an agent cannot write to memory, so keeping
  something is always an act somebody took.

  ## A group's notes are readable by its members

  There is no private memory in a shared estate. A person's athanor may
  hold whatever it likes — it has one member, and that is what a person's
  own furnace is for — but an estate with several people in it holds
  nothing they cannot enumerate. `list` and `read` are open to any member
  precisely so that invariant is a fact about the system rather than a
  sentence in a docstring.
  """

  @behaviour Emissary.MCP.ToolProvider

  alias Sanctum.Context

  @root "memory"
  @name_format ~r/\A[A-Za-z0-9][A-Za-z0-9 _.-]{0,80}\z/

  @impl true
  def service, do: "memory"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    %{
      name: "memory",
      title: "Memory",
      description:
        "Notes kept out of a conversation. Distinct from the transcript: erasing a " <>
          "thread does not erase what someone kept from it. Every note belongs either " <>
          "to you or to the estate you are working in, and that choice is the point.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: false,
        actions: %{
          # External plane only. Keeping something is a person's act — an
          # agent that could write here would be deciding what to remember
          # about you, and deciding whose notes it went into. Interactive
          # only, for the same sentence with "standing credential" in it.
          "note" => %{kind: :write, planes: [:external], consent: :interactive},
          "list" => %{kind: :read, planes: [:external], consent: :interactive},
          "read" => %{kind: :read, planes: [:external], consent: :interactive},
          "forget" => %{kind: :destructive, planes: [:external], consent: :interactive}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{"type" => "string", "enum" => ["note", "list", "read", "forget"]},
          "scope" => %{
            "type" => "string",
            "enum" => ["mine", "estate"],
            "description" =>
              "Whose notes: your own athanor, or the estate in focus. Required for " <>
                "note and forget; list and read default to the estate."
          },
          "name" => %{"type" => "string", "description" => "What the note is called"},
          "content" => %{"type" => "string", "description" => "note: what to keep"}
        },
        "required" => ["action"]
      }
    }
  end

  @impl true
  def handle("memory", %Context{} = ctx, args), do: dispatch(ctx, args)
  def handle(tool, _ctx, _args), do: {:error, {:not_found, "tool", tool}}

  # ---------------------------------------------------------------------------

  defp dispatch(ctx, %{"action" => action} = args) do
    with {:ok, scope_ctx} <- scoped(ctx, args, action) do
      act(action, scope_ctx, args)
    end
  end

  defp dispatch(_ctx, _args), do: {:error, :action_missing}

  # The consent question, resolved to a context. `"mine"` is the person's
  # own athanor — reached through `Context.focus/2`, the audited narrowing
  # entry, not a raw struct update: focus checks membership (production
  # seats the owner in their personal athanor at mint,
  # `Sanctum.Provisioning.ensure_personal_athanor/1`) and refuses an
  # archived athanor, both of which a bare `%{ctx | athanor_id: id}` would
  # skip.
  defp scoped(ctx, args, action) do
    case Map.get(args, "scope", default_scope(action)) do
      "estate" ->
        {:ok, ctx}

      "mine" ->
        case personal_athanor(ctx) do
          nil -> {:error, {:invalid_argument, "you have no personal athanor to keep notes in"}}
          id -> focus_personal(ctx, id)
        end

      other ->
        {:error,
         {:invalid_argument, "scope must be \"mine\" or \"estate\", got #{inspect(other)}"}}
    end
  end

  defp focus_personal(ctx, id) do
    case Context.focus(ctx, id) do
      {:ok, focused} ->
        {:ok, focused}

      {:error, reason} ->
        {:error, {:invalid_argument, "your personal athanor cannot be opened (#{reason})"}}
    end
  end

  # Reads default to where you are; writes must say. Keeping something in
  # the wrong place is the mistake worth making impossible to make quietly.
  defp default_scope(action) when action in ["list", "read"], do: "estate"
  defp default_scope(_), do: nil

  defp personal_athanor(%Context{user_id: user_id}) when is_binary(user_id) do
    case Sanctum.Tenancy.Users.get(user_id) do
      {:ok, %{personal_athanor_id: id}} -> id
      _ -> nil
    end
  end

  defp personal_athanor(_), do: nil

  defp act("note", ctx, %{"name" => name, "content" => content})
       when is_binary(name) and is_binary(content) do
    with :ok <- check_name(name),
         :ok <- Arca.put(ctx, path(name), content) do
      {:ok, %{kept: name, athanor_id: ctx.athanor_id}}
    end
  end

  defp act("note", _ctx, _args),
    do: {:error, {:invalid_argument, "note requires 'name' and 'content'"}}

  defp act("list", ctx, _args) do
    case Arca.list_recursive(ctx, [@root]) do
      {:ok, entries} -> {:ok, %{notes: Enum.map(entries, &entry/1), athanor_id: ctx.athanor_id}}
      {:error, reason} -> {:error, {:unavailable, "memory: #{inspect(reason)}"}}
    end
  end

  defp act("read", ctx, %{"name" => name}) when is_binary(name) do
    with :ok <- check_name(name) do
      case Arca.get(ctx, path(name)) do
        {:ok, content} -> {:ok, %{name: name, content: content, athanor_id: ctx.athanor_id}}
        _ -> {:error, {:not_found, "note", name}}
      end
    end
  end

  defp act("read", _ctx, _args), do: {:error, {:invalid_argument, "read requires 'name'"}}

  defp act("forget", ctx, %{"name" => name}) when is_binary(name) do
    with :ok <- check_name(name),
         :ok <- Arca.delete(ctx, path(name)) do
      {:ok, %{forgot: name, athanor_id: ctx.athanor_id}}
    else
      {:error, :not_found} -> {:error, {:not_found, "note", name}}
      other -> other
    end
  end

  defp act("forget", _ctx, _args), do: {:error, {:invalid_argument, "forget requires 'name'"}}

  defp act(action, _ctx, _args), do: {:error, {:unknown_action, "memory.#{action}"}}

  # A note name is a filename under the estate's tree, so it is held to a
  # grammar rather than trusted — the same posture `Compendium.AquaPath`
  # takes for an agent name.
  defp check_name(name) do
    if name =~ @name_format,
      do: :ok,
      else: {:error, {:invalid_argument, "a note name must be letters, digits, spaces, . _ or -"}}
  end

  defp path(name), do: [@root, name]

  defp entry(%{path: path} = e), do: %{name: List.last(path), size: Map.get(e, :size)}
  defp entry(path) when is_list(path), do: %{name: List.last(path)}
  defp entry(other), do: %{name: to_string(other)}
end
