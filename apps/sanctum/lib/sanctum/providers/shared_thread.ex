# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.SharedThread do
  @moduledoc """
  The `shared_thread` tool: threads people talk in, which no athanor
  holds — make one or a pair, read and list them, rename, archive,
  reopen and leave one, see, add, remove and withdraw its people, and
  post, read and attach to what is said there. The rules are
  `Sanctum.SharedThreads`'; this module reads the call and answers.

  Every action is a person's: a shared thread is no athanor's, and an
  API key belongs to one athanor and is nobody's identity, so a key is
  refused. A pair is made by a person with a person, so `pair` is
  interactive on its annotation: no standing credential makes one. To anyone not
  seated in it a thread answers as a missing one does.
  """

  alias Prima.{Arg, Operation}
  alias Sanctum.Context
  alias Sanctum.SharedThreads

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    Operation.tool(
      [
        op("create", "Create shared thread", [title(true)], :write),
        op(
          "pair",
          "Pair shared thread",
          [
            Arg.new("user", :string,
              required: true,
              description:
                "pair: the other person's user id — someone you already share a thread with"
            )
          ],
          :write,
          consent: :interactive
        ),
        op("get", "Get shared thread", [thread()], :read),
        op("list", "List shared thread", [], :read),
        op("rename", "Rename shared thread", [thread(), title(true)], :write),
        op("archive", "Archive shared thread", [thread()], :destructive, reduces_authority: true),
        op("unarchive", "Unarchive shared thread", [thread()], :write),
        op("leave", "Leave shared thread", [thread()], :write, reduces_authority: true),
        op("people", "People of shared thread", [thread()], :read),
        op(
          "add",
          "Add to shared thread",
          [
            thread(),
            Arg.new("user_id", :string,
              description: "The person's user id, when already on this CYFR (add, remove)"
            ),
            Arg.new("identifier", :string,
              description: "The person's identifier (per_…), in place of a user id (add, remove)"
            ),
            Arg.new("handle", :string,
              description:
                "The person's handle at the registry (@name or name), in place of a user id or identifier (add)"
            )
          ],
          :write
        ),
        op(
          "remove",
          "Remove from shared thread",
          [
            thread(),
            Arg.new("user_id", :string,
              description: "The person's user id, when already on this CYFR (add, remove)"
            ),
            Arg.new("identifier", :string,
              description: "The person's identifier (per_…), in place of a user id (add, remove)"
            )
          ],
          :destructive,
          reduces_authority: true
        ),
        op(
          "withdraw",
          "Withdraw invitation from shared thread",
          [
            thread(),
            Arg.new("identifier", :string,
              required: true,
              description: "withdraw: the identifier (per_…) whose invitation goes"
            )
          ],
          :write,
          reduces_authority: true
        ),
        op(
          "post",
          "Post to shared thread",
          [thread(), Arg.new("content", :string, required: true, description: "post: the words")],
          :write
        ),
        op(
          "messages",
          "Messages of shared thread",
          [
            thread(),
            Arg.new("after_seq", :integer,
              min: 0,
              description: "messages: only those after this seq (default 0)"
            ),
            Arg.new("limit", :integer,
              min: 1,
              max: Arca.SharedMessages.max_page(),
              description: "messages: page size (default and ceiling 500)"
            )
          ],
          :read
        ),
        op(
          "attach",
          "Attach to shared thread",
          [
            thread(),
            Arg.new("content", :string, description: "attach: words to go with the files"),
            Arg.new(
              "files",
              {:array,
               Arg.new(
                 nil,
                 {:record,
                  [
                    Arg.new("filename", :string, required: true),
                    Arg.new("media_type", :string, required: true),
                    Arg.new("data", :string, required: true, bulk: true)
                  ]}
               )},
              required: true,
              description:
                "attach: the files as {filename, media_type, data} with base64 data, posted as one message"
            )
          ],
          :write
        )
      ],
      description:
        "Threads people talk in, which no athanor holds. Every person in one is equal: any of them may rename it, add someone by user id, identifier or handle, remove someone, archive it or leave it. A pair is a thread of two, made with someone you already share a thread with; it never gains or loses anyone.",
      title: "Shared threads"
    )
  end

  defp op(action, title, args, kind, opts \\ []),
    do:
      Operation.new(
        "shared_thread",
        action,
        title,
        args,
        [kind: kind, planes: [:external]] ++ opts
      )

  defp thread,
    do:
      Arg.new("thread", :string,
        required: true,
        description: "The shared thread's id (sth_…)"
      )

  defp title(required),
    do:
      Arg.new("title", :string,
        required: required,
        description: "The thread's title (create, rename)"
      )

  def handle(%Context{auth_method: :api_key}, %{"action" => action}) when is_binary(action) do
    {:error,
     {:invalid_argument,
      "shared_thread.#{action} is a person's act — sign in; an API key cannot do it"}}
  end

  def handle(%Context{user_id: user_id} = ctx, args) when is_binary(user_id),
    do: act(ctx, args)

  def handle(_ctx, %{"action" => _action}),
    do: {:error, {:invalid_argument, "A shared thread is a person's: sign in"}}

  def handle(_ctx, _args), do: {:error, :action_missing}

  defp act(ctx, %{"action" => "create", "title" => title}),
    do: SharedThreads.create(ctx.user_id, title)

  defp act(ctx, %{"action" => "pair", "user" => other}) when is_binary(other),
    do: SharedThreads.pair(ctx.user_id, other)

  defp act(ctx, %{"action" => "get", "thread" => id}), do: SharedThreads.get(ctx.user_id, id)

  defp act(ctx, %{"action" => "list"}) do
    with {:ok, threads} <- SharedThreads.list(ctx.user_id),
         do: {:ok, %{threads: threads, count: length(threads)}}
  end

  defp act(ctx, %{"action" => "rename", "thread" => id, "title" => title}),
    do: SharedThreads.rename(ctx.user_id, id, title)

  defp act(ctx, %{"action" => "archive", "thread" => id}),
    do: SharedThreads.archive(ctx.user_id, id)

  defp act(ctx, %{"action" => "unarchive", "thread" => id}),
    do: SharedThreads.unarchive(ctx.user_id, id)

  defp act(ctx, %{"action" => "leave", "thread" => id}) do
    with {:ok, %{ended: ended}} <- SharedThreads.leave(ctx.user_id, id),
         do: {:ok, %{thread: id, state: "left", ended: ended}}
  end

  defp act(ctx, %{"action" => "people", "thread" => id}) do
    with {:ok, people} <- SharedThreads.people(ctx.user_id, id),
         do: {:ok, %{thread: id, people: people, count: length(people)}}
  end

  defp act(ctx, %{"action" => "add", "thread" => id} = args) do
    with {:ok, target} <- add_target(args),
         {:ok, :added} <- SharedThreads.add(ctx.user_id, id, target),
         do: {:ok, %{thread: id, person: Map.new(target), state: "added"}}
  end

  defp act(ctx, %{"action" => "remove", "thread" => id} = args) do
    with {:ok, target} <- target(args, "user_id or identifier"),
         :ok <- SharedThreads.remove(ctx.user_id, id, target),
         do: {:ok, %{thread: id, person: Map.new(target), state: "removed"}}
  end

  defp act(ctx, %{"action" => "withdraw", "thread" => id, "identifier" => identifier}) do
    with :ok <- SharedThreads.withdraw(ctx.user_id, id, String.trim(identifier)),
         do: {:ok, %{thread: id, identifier: identifier, state: "withdrawn"}}
  end

  defp act(ctx, %{"action" => "post", "thread" => id, "content" => content}),
    do: SharedThreads.post(ctx.user_id, id, content)

  defp act(ctx, %{"action" => "messages", "thread" => id} = args) do
    opts = [after_seq: Map.get(args, "after_seq", 0), limit: Map.get(args, "limit", 500)]

    with {:ok, messages} <- SharedThreads.messages(ctx.user_id, id, opts),
         do: {:ok, %{thread: id, messages: messages, count: length(messages)}}
  end

  defp act(ctx, %{"action" => "attach", "thread" => id, "files" => files} = args) do
    with {:ok, files} <- decode_files(files),
         do: SharedThreads.post(ctx.user_id, id, Map.get(args, "content"), files)
  end

  defp act(_ctx, %{"action" => action})
       when action in ~w(create pair get rename archive unarchive leave people add remove withdraw post messages attach),
       do: {:error, {:invalid_argument, "shared_thread.#{action} is missing a required argument"}}

  defp act(_ctx, %{"action" => action}),
    do: {:error, {:unknown_action, "shared_thread.#{action}"}}

  defp act(_ctx, _args), do: {:error, :action_missing}

  # A handle names a person through the registry, and stands alone like an
  # identifier. It is the add's alone: a removal names someone this CYFR
  # already holds a row for.
  defp add_target(%{"handle" => handle} = args) when is_binary(handle) and handle != "" do
    if Map.has_key?(args, "user_id") or Map.has_key?(args, "identifier"),
      do: {:error, {:invalid_argument, "Name one of user_id, identifier or handle, not two"}},
      else: {:ok, [handle: handle |> String.trim() |> String.trim_leading("@")]}
  end

  defp add_target(args), do: target(args, "user_id, identifier or handle")

  defp target(%{"identifier" => identifier} = args, _missing)
       when is_binary(identifier) and identifier != "" do
    if Map.has_key?(args, "user_id"),
      do: {:error, {:invalid_argument, "Name one of user_id or identifier, not both"}},
      else: {:ok, [identifier: String.trim(identifier)]}
  end

  defp target(%{"user_id" => user_id}, _missing) when is_binary(user_id) and user_id != "",
    do: {:ok, [user_id: user_id]}

  defp target(_args, missing),
    do: {:error, {:invalid_argument, "Missing required argument: " <> missing}}

  defp decode_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn
      %{"filename" => name, "media_type" => media, "data" => data}, {:ok, acc}
      when is_binary(name) and is_binary(media) and is_binary(data) ->
        case Base.decode64(data) do
          {:ok, bytes} ->
            {:cont, {:ok, acc ++ [%{filename: name, media_type: media, bytes: bytes}]}}

          :error ->
            {:halt, {:error, {:invalid_argument, "attach: '#{name}' is not base64"}}}
        end

      _, _ ->
        {:halt,
         {:error, {:invalid_argument, "attach: each file needs filename, media_type and data"}}}
    end)
  end
end
