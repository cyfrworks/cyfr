# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SharedThreads do
  @moduledoc """
  The rules of shared threads: places people talk in, which no athanor
  holds (`Arca.SharedThreads`, `Arca.SharedThreadMembers`,
  `Arca.SharedMessages`). A thread has a title and its people, every one
  of them equal; a pair is a thread of two with no title, made once for
  them.

  ## Who may do what

  A person makes a thread with a title and is its first member. A pair is
  found or made for two people who already sit together in an active
  thread (`pair/2`), so a user id nobody shares a thread with reaches no
  one; its two people are written at its birth and it never gains or
  loses one before it ends. Any member renames a thread, adds someone by
  user id, person identifier or handle, removes a member, withdraws an
  invitation, archives it, or leaves it; the last leave archives the
  thread, and a pair ends when either of its two leaves. A member
  reopens an archived thread, never a pair. Adding an identifier no
  person here holds leaves an invitation that becomes their seat at
  their sign-in here (`activate_invited/1`) and, when the door would not
  admit that identifier, a request for the platform administrator; a
  stranger's identifier and a known one answer alike. The platform
  administrator holds no seat by their capability and reads a thread
  only where they sit.

  A thread one of whose people still recovers from a declared restore
  admits no one new by any path, an addition, an invitation's activation
  or an invitation's redemption, until each has recovered; removal and
  leave stay admitted. That, the caps `max_shared_threads_per_person`,
  `max_people_per_thread` and `max_pairs_per_person` (each absent for no
  limit), the acting person's own seat for every change of a thread, and
  a pair's two people still sitting together are decided by the store, in
  the transaction that writes, under the thread's lock or the two
  people's, so no read here can be raced past them: the seat this module
  reads first only picks the sentence a caller with none hears.

  ## What is said

  A member posts and reads; nothing runs in a thread, so nothing claims
  one. A message's files are stored under
  `shared/{thread}/{message}/{n}-{name}` in the server's `:global` class
  before its row lands, and removed again if it does not; every read and
  write of one goes through here, after the caller's seat is read, and
  that seat is the whole policy for a shared blob. A file is bounded by
  `max_file_bytes` alone, and a message carries any number of them.

  ## Answers

  To anyone not seated in it a thread answers as a missing one does,
  `{:not_found, "Thread", id}`, archived or not. Every other refusal is a
  reason `Prima.Refusal` reads as a sentence: `{:shared_thread, reason}`
  for the rules above, `{:invalid_argument, sentence}`, a cap's
  `{:limit_reached, key, cap}` or `{:cap_unverifiable, key}`, the
  registry's refusals of a handle, `:not_owner` and
  `{:unavailable, "Storage"}`.

  Every change is told to each person it names, its people and anyone it
  took from the thread (`Sanctum.Telemetry.shared_thread/3`).
  """

  require Logger

  alias Sanctum.Door
  alias Sanctum.Tenancy.Users

  @max_file_bytes 20_000_000
  @name_max 120

  @typedoc "A thread as a person seated in it reads it."
  @type thread :: %{
          required(:id) => String.t(),
          required(:kind) => String.t(),
          required(:title) => String.t() | nil,
          required(:status) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "Who a person adds, removes or withdraws."
  @type target :: [user_id: String.t()] | [identifier: String.t()] | [handle: String.t()]

  @typedoc "A file a message carries, as a poster gives it."
  @type file :: %{filename: String.t(), media_type: String.t() | nil, bytes: binary()}

  @doc "Per-message bounds: files and bytes per file."
  @spec limits() :: %{max_file_bytes: pos_integer()}
  def limits, do: %{max_file_bytes: @max_file_bytes}

  # ---- reading ---------------------------------------------------------------

  @doc """
  The threads `user_id` sits in, active and archived, the latest message
  first; a pair names the other person (`with`).
  """
  @spec list(String.t()) :: {:ok, [thread()]} | {:error, term()}
  def list(user_id) when is_binary(user_id) do
    case Arca.SharedThreads.list_for(server(), user_id) do
      {:ok, rows} -> {:ok, Enum.map(rows, &view(&1, user_id))}
      {:error, reason} -> unavailable(reason)
    end
  end

  @doc "The thread `thread_id`, for a person seated in it."
  @spec get(String.t(), String.t()) :: {:ok, thread()} | {:error, term()}
  def get(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, thread} <- seated(user_id, thread_id), do: {:ok, view(thread, user_id)}
  end

  @doc """
  The thread's people and invitations, oldest first, for a person seated
  in it: `%{user_id, name, handle, status: "active", since}` for a person
  and `%{identifier, status: "invited", since}` for an invitation.
  """
  @spec people(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def people(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, _thread} <- seated(user_id, thread_id),
         {:ok, rows} <- rows(thread_id) do
      {:ok, Enum.map(rows, &person/1)}
    end
  end

  @doc """
  The thread's messages, oldest first, for a person seated in it: those
  after `after_seq:` (default 0), at most `limit:` (default and ceiling
  `Arca.SharedMessages.max_page/0`).
  """
  @spec messages(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def messages(user_id, thread_id, opts \\ []) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, _thread} <- seated(user_id, thread_id) do
      case Arca.SharedMessages.list(server(), thread_id, opts) do
        {:ok, rows} -> {:ok, Enum.map(rows, &message/1)}
        {:error, reason} -> unavailable(reason)
      end
    end
  end

  @doc """
  The thread's newest `count` messages, oldest first, for a person seated
  in it: what their own AQUA reads of the thread they have open
  (`Aqua.RoomExcerpt`).
  """
  @spec tail(String.t(), String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def tail(user_id, thread_id, count)
      when is_binary(user_id) and is_binary(thread_id) and is_integer(count) and count > 0 do
    with {:ok, _thread} <- seated(user_id, thread_id) do
      case Arca.SharedMessages.latest(server(), thread_id, count) do
        {:ok, rows} -> {:ok, Enum.map(rows, &message/1)}
        {:error, reason} -> unavailable(reason)
      end
    end
  end

  @doc """
  The people `user_id` sits with in an active thread, as `%{user_id,
  display_name, email}`, each once and never `user_id` themself, ordered
  by name: whom a person may pair with or offer a copy of a file to. An
  invitation is no seat and an archived thread is no place to share. A
  read the store cannot answer is `{:error, :database_error}`, never a
  shorter list.
  """
  @spec people_in_threads_with(String.t()) ::
          {:ok, [%{user_id: String.t(), display_name: String.t() | nil, email: String.t() | nil}]}
          | {:error, :database_error}
  def people_in_threads_with(user_id) when is_binary(user_id) and user_id != "" do
    case Arca.SharedThreadMembers.people_with(server(), user_id) do
      {:ok, people} ->
        {:ok, Enum.sort_by(people, &{&1.display_name || &1.email || "", &1.user_id})}

      {:error, reason} ->
        Logger.error("[Sanctum.SharedThreads] the store did not answer: #{inspect(reason)}")
        {:error, :database_error}
    end
  end

  @doc """
  The bytes of the file `stored_name` that message `message_id` of the
  thread carries, with its name and type, for a person seated in the
  thread: what a download serves.
  """
  @spec attachment(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{filename: String.t(), media_type: String.t(), bytes: binary()}}
          | {:error, term()}
  def attachment(user_id, thread_id, message_id, stored_name)
      when is_binary(user_id) and is_binary(thread_id) and is_binary(message_id) and
             is_binary(stored_name) do
    missing = {:error, {:not_found, "Attachment", stored_name}}

    with {:ok, _thread} <- seated(user_id, thread_id),
         {:ok, message} <- message(thread_id, message_id, missing),
         %{} = ref <- carried(message, stored_name) || missing,
         {:ok, bytes} <- read_blob(thread_id, message_id, stored_name, missing) do
      {:ok, %{filename: ref["filename"], media_type: ref["media_type"], bytes: bytes}}
    end
  end

  # ---- making and changing ----------------------------------------------------

  @doc "Make a thread titled `title`, with `user_id` its first member."
  @spec create(String.t(), String.t()) :: {:ok, thread()} | {:error, term()}
  def create(user_id, title) when is_binary(user_id) do
    with {:ok, title} <- title(title) do
      case Arca.SharedThreads.create(server(), %{title: title, created_by: user_id}) do
        {:ok, thread} ->
          announce(:changed, thread.id)
          {:ok, view(thread, user_id)}

        {:error, reason} ->
          refused(reason, nil)
      end
    end
  end

  def create(_user_id, _title), do: {:error, {:invalid_argument, "A thread needs a title"}}

  @doc """
  The active pair of `user_id` and `other`, made when there is none, for
  two people who already sit together in an active thread. To anyone
  else `other` answers as a stranger does.
  """
  @spec pair(String.t(), String.t()) :: {:ok, thread()} | {:error, term()}
  def pair(user_id, other) when is_binary(user_id) and is_binary(other) do
    cond do
      user_id == other ->
        {:error, {:shared_thread, :self}}

      not together?(user_id, other) ->
        {:error, {:shared_thread, :not_together}}

      true ->
        case Arca.SharedThreads.pair(server(), user_id, other) do
          {:ok, thread} ->
            announce(:changed, thread.id)
            {:ok, view(thread, user_id)}

          {:error, reason} ->
            refused(reason, nil)
        end
    end
  end

  @doc "Give the thread a new title; a pair has none."
  @spec rename(String.t(), String.t(), String.t()) :: {:ok, thread()} | {:error, term()}
  def rename(user_id, thread_id, title) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, _thread} <- seated(user_id, thread_id),
         {:ok, title} <- title(title) do
      changed(Arca.SharedThreads.rename(server(), thread_id, user_id, title), user_id, thread_id)
    end
  end

  @doc "Archive the thread; archiving a pair ends it."
  @spec archive(String.t(), String.t()) :: {:ok, thread()} | {:error, term()}
  def archive(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, _thread} <- seated(user_id, thread_id) do
      changed(Arca.SharedThreads.archive(server(), thread_id, user_id), user_id, thread_id)
    end
  end

  @doc "Reopen an archived thread; a pair, once ended, stays ended."
  @spec unarchive(String.t(), String.t()) :: {:ok, thread()} | {:error, term()}
  def unarchive(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, _thread} <- seated(user_id, thread_id) do
      changed(Arca.SharedThreads.unarchive(server(), thread_id, user_id), user_id, thread_id)
    end
  end

  @doc """
  `user_id` leaves the thread: their seat, nothing else. The last leave
  archives the thread, and a pair ends when either leaves. Answers
  whether the thread ended.
  """
  @spec leave(String.t(), String.t()) :: {:ok, %{ended: boolean()}} | {:error, term()}
  def leave(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    case Arca.SharedThreadMembers.leave(server(), thread_id, user_id) do
      {:ok, %{ended: ended}} ->
        announce(:changed, thread_id, [user_id])
        {:ok, %{ended: ended}}

      {:error, :not_found} ->
        missing(thread_id)

      {:error, reason} ->
        refused(reason, thread_id)
    end
  end

  @doc """
  Add someone to the thread: a person here (`user_id:`) is seated; an
  `identifier:` (`per_…`) seats the person here who holds it, else leaves
  an invitation, with the door's request when the door would not admit
  it; a `handle:` is asked of the registry first and its identifier added.
  Answers `:added` either way, so an identifier tells the caller nothing
  of who is here. A person seated already, or an identifier invited
  already, is answered `:added` too.
  """
  @spec add(String.t(), String.t(), target()) :: {:ok, :added} | {:error, term()}
  def add(user_id, thread_id, target) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, thread} <- seated(user_id, thread_id),
         :ok <- not_pair(thread) do
      added(user_id, thread, target)
    end
  end

  defp added(by, thread, user_id: user_id) when is_binary(user_id) do
    with {:ok, %{status: "active", id: person_id}} <- find_person(user_id) do
      case Arca.SharedThreadMembers.seat(server(), thread.id, person_id, by) do
        {:ok, _seat} ->
          announce(:changed, thread.id)
          {:ok, :added}

        {:error, :conflict} ->
          {:ok, :added}

        {:error, :denied} ->
          {:error, {:not_found, "Person", user_id}}

        {:error, reason} ->
          refused(reason, thread.id)
      end
    else
      {:ok, %{}} -> {:error, {:not_found, "Person", user_id}}
      {:error, :not_found} -> {:error, {:not_found, "Person", user_id}}
      {:error, reason} -> unavailable(reason)
    end
  end

  defp added(by, thread, identifier: identifier) when is_binary(identifier) do
    if Prima.Identity.Encoding.identifier?(identifier) do
      case Users.get_by_identifier(identifier) do
        {:ok, %{status: "active", id: user_id}} -> added(by, thread, user_id: user_id)
        {:ok, %{}} -> invited(by, thread, identifier)
        {:error, :not_found} -> invited(by, thread, identifier)
        {:error, reason} -> unavailable(reason)
      end
    else
      {:error, {:invalid_argument, "That is not a person identifier (per_ and 64 hex digits)"}}
    end
  end

  # The registry is asked only once the thread would take a seat, and
  # nothing is written until it has answered.
  defp added(by, thread, handle: handle) when is_binary(handle) do
    with {:ok, identifier} <- Sanctum.Handle.identifier(handle),
         do: added(by, thread, identifier: identifier)
  end

  defp added(_by, _thread, _target),
    do: {:error, {:invalid_argument, "Name one of user_id, identifier or handle"}}

  # The invitation an identifier holds, and the administrator's request
  # when the door would not admit it: only a request actually written puts
  # someone at the door.
  defp invited(by, thread, identifier) do
    case Arca.SharedThreadMembers.invite(server(), thread.id, identifier, by) do
      {:ok, _invitation} -> at_the_door(by, thread, identifier)
      {:error, :conflict} -> at_the_door(by, thread, identifier)
      {:error, reason} -> refused(reason, thread.id)
    end
  end

  defp at_the_door(by, thread, identifier) do
    unless Door.identifier_admitted?(identifier) do
      case Door.Store.request("identifier", identifier, by) do
        {:ok, :created, _} -> Sanctum.Notify.allowlist_request(identifier)
        _ -> :ok
      end
    end

    announce(:changed, thread.id)
    {:ok, :added}
  end

  @doc """
  Remove a member (`user_id:`) from the thread, or the person who holds an
  identifier (`identifier:`) once their invitation is no longer there to
  withdraw; a person removing themselves leaves. A pair loses no one.
  """
  @spec remove(String.t(), String.t(), [user_id: String.t()] | [identifier: String.t()]) ::
          :ok | {:error, term()}
  def remove(user_id, thread_id, user_id: user_id), do: left(leave(user_id, thread_id))

  def remove(user_id, thread_id, target) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, thread} <- seated(user_id, thread_id),
         :ok <- not_pair(thread) do
      removed(user_id, thread, target)
    end
  end

  defp removed(by, thread, user_id: member) when is_binary(member) do
    case Arca.SharedThreadMembers.remove(server(), thread.id, member, by) do
      {:ok, _seat} ->
        announce(:changed, thread.id, [member])
        :ok

      {:error, :not_found} ->
        {:error, {:not_found, "Member", member}}

      {:error, reason} ->
        refused(reason, thread.id)
    end
  end

  defp removed(by, thread, identifier: identifier) when is_binary(identifier) do
    case withdrawn(by, thread, identifier) do
      {:error, {:not_found, "Invitation", _}} ->
        case Users.get_by_identifier(identifier) do
          {:ok, %{id: ^by}} -> left(leave(by, thread.id))
          {:ok, %{id: member}} -> removed(by, thread, user_id: member)
          {:error, :not_found} -> {:error, {:not_found, "Member", identifier}}
          {:error, reason} -> unavailable(reason)
        end

      other ->
        other
    end
  end

  defp removed(_by, _thread, _target),
    do: {:error, {:invalid_argument, "Name one of user_id or identifier"}}

  defp left({:ok, _ended}), do: :ok
  defp left(error), do: error

  @doc """
  Withdraw the invitation `identifier` holds in the thread, and nothing
  else: `{:not_found, "Invitation", identifier}` once a sign-in made it a
  seat, even between the read and the delete.
  """
  @spec withdraw(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def withdraw(user_id, thread_id, identifier)
      when is_binary(user_id) and is_binary(thread_id) and is_binary(identifier) do
    with {:ok, thread} <- seated(user_id, thread_id), do: withdrawn(user_id, thread, identifier)
  end

  @doc """
  Withdraw every invitation a person identifier holds, in every thread —
  what the door's deny of that identifier owes the threads holding a seat
  for it, since a seat must not outlive the eject — and answer how many
  threads held one. Each thread's people are told.
  """
  @spec withdraw_identifier(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def withdraw_identifier(identifier) when is_binary(identifier) and identifier != "" do
    with {:ok, thread_ids} <- Arca.SharedThreadMembers.withdraw_identifier(server(), identifier) do
      Enum.each(thread_ids, &announce(:changed, &1))
      {:ok, length(thread_ids)}
    end
  end

  defp withdrawn(by, thread, identifier) do
    case Arca.SharedThreadMembers.withdraw(server(), thread.id, identifier, by) do
      {:ok, _row} ->
        announce(:changed, thread.id)
        :ok

      {:error, :not_found} ->
        {:error, {:not_found, "Invitation", identifier}}

      {:error, reason} ->
        refused(reason, thread.id)
    end
  end

  # ---- what is said -------------------------------------------------------------

  @doc """
  Post `content` with `files` in the thread as `user_id`, a member: the
  files are stored first, under the message's own id, and the message
  lands after them; a message that does not land leaves none of its files.
  `aloud`, given by `Aqua.Aloud` alone, is the provenance of a line said
  aloud from the person's own thread (`"aloud_from"`, and `"shared_agent"`
  when the words were their assistant's), kept in the message's payload.
  """
  @spec post(String.t(), String.t(), String.t() | nil, [file()], map()) ::
          {:ok, map()} | {:error, term()}
  def post(user_id, thread_id, content, files \\ [], aloud \\ %{})
      when is_binary(user_id) and is_binary(thread_id) and is_list(files) and is_map(aloud) do
    message_id = Prima.UUID7.generate_id("shm")

    with :ok <- said(content, files),
         :ok <- bounded(files),
         {:ok, _thread} <- seated(user_id, thread_id),
         {:ok, refs} <- store(thread_id, message_id, files) do
      payload =
        aloud
        |> Map.take(["aloud_from", "shared_agent"])
        |> then(&if(refs == [], do: &1, else: Map.put(&1, "attachments", refs)))
        |> then(&if(&1 == %{}, do: nil, else: &1))

      case Arca.SharedMessages.append(server(), thread_id, %{
             id: message_id,
             author: user_id,
             content: content || "",
             payload: payload
           }) do
        {:ok, row} ->
          announce(:posted, thread_id)
          {:ok, message(row)}

        {:error, reason} ->
          discard(thread_id, message_id, refs)
          refused(reason, thread_id)
      end
    end
  end

  defp said(content, []) when not is_binary(content) or content == "",
    do: {:error, {:invalid_argument, "A message needs words or a file"}}

  defp said(content, _files) when is_nil(content) or is_binary(content), do: :ok
  defp said(_content, _files), do: {:error, {:invalid_argument, "A message's words are text"}}

  defp bounded(files) do
    cond do
      Enum.any?(files, &(not is_binary(&1[:bytes]))) ->
        {:error, {:invalid_argument, "A file's content is its bytes"}}

      Enum.any?(files, &(byte_size(&1.bytes) > @max_file_bytes)) ->
        {:error, {:invalid_argument, "A file is at most #{div(@max_file_bytes, 1_000_000)} MB"}}

      true ->
        :ok
    end
  end

  # Each file created only where nothing is, under the message's own id;
  # a write that fails removes the files already written.
  defp store(thread_id, message_id, files) do
    files
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {file, index}, {:ok, refs} ->
      filename = display_name(file[:filename])
      stored = "#{index}-#{stored_name(filename)}"

      case Arca.put_if_none_match(server(), blob(thread_id, message_id, stored), file.bytes) do
        :ok ->
          ref = %{
            "filename" => filename,
            "stored_name" => stored,
            "media_type" => file[:media_type] || Prima.MediaType.binary(),
            "size" => byte_size(file.bytes)
          }

          {:cont, {:ok, [ref | refs]}}

        {:error, reason} ->
          Logger.warning("[Sanctum.SharedThreads] storing a file failed: #{inspect(reason)}")
          discard(thread_id, message_id, refs)
          {:halt, {:error, {:unavailable, "Storage"}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  defp discard(thread_id, message_id, refs) do
    for %{"stored_name" => stored} <- refs,
        do: Arca.delete(server(), blob(thread_id, message_id, stored))

    :ok
  end

  defp read_blob(thread_id, message_id, stored, missing) do
    case Arca.get(server(), blob(thread_id, message_id, stored)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :not_found} -> missing
      {:error, _unread} -> {:error, {:unavailable, "Storage"}}
    end
  end

  # A shared blob's path, rebuilt from the message's identity: no path is
  # ever stored, so a ref cannot point outside its message's files.
  defp blob(thread_id, message_id, stored), do: ["shared", thread_id, message_id, stored]

  # The name a person reads: theirs, without a path, controls or excess.
  defp display_name(name) when is_binary(name) do
    name
    |> String.normalize(:nfc)
    |> String.replace(~r/[\/\\[:cntrl:]]/u, "_")
    |> String.trim()
    |> String.slice(0, @name_max)
    |> case do
      "" -> "file"
      name -> name
    end
  end

  defp display_name(_name), do: "file"

  # The name the blob is stored under: the display name in plain
  # characters, never Arca's in-flight `<name>.tmp.<n>` marker.
  defp stored_name(name) do
    {base, ext} =
      case Path.extname(name) do
        "" -> {name, ""}
        ext -> {Path.rootname(name), ext}
      end

    plain = fn text -> String.replace(text, ~r/[^A-Za-z0-9_-]/, "_") end

    case plain.(base) <> String.replace(plain.(ext), ~r/\A_/, ".") do
      "" -> "file"
      stored -> stored
    end
  end

  # The message by its own id, never by a page of the thread's.
  defp message(thread_id, message_id, missing) do
    case Arca.SharedMessages.get(server(), thread_id, message_id) do
      {:ok, message} -> {:ok, message}
      {:error, :not_found} -> missing
      {:error, reason} -> unavailable(reason)
    end
  end

  defp carried(%{payload: %{"attachments" => refs}}, stored) when is_list(refs),
    do: Enum.find(refs, &match?(%{"stored_name" => ^stored}, &1))

  defp carried(_message, _stored), do: nil

  # ---- sign-in, invitations and the denial ------------------------------------

  @doc """
  Turn every invitation held for the person's identifier into their seat,
  at each admitted sign-in: an invitation to a thread they sit in already
  is dropped, and one a thread's archive or a declared restore's hold
  keeps stays for a later sign-in. Answers how many seats it made.
  """
  @spec activate_invited(map()) ::
          {:ok, non_neg_integer()} | {:error, :database_error | :not_owner}
  def activate_invited(%{id: user_id}) when is_binary(user_id) do
    case Users.identifier(user_id) do
      {:ok, identifier} when is_binary(identifier) ->
        case Arca.SharedThreadMembers.activate(server(), user_id, identifier) do
          {:ok, thread_ids} ->
            Enum.each(thread_ids, &announce(:changed, &1))
            {:ok, length(thread_ids)}

          {:error, :not_owner} ->
            {:error, :not_owner}

          {:error, _unanswered} ->
            {:error, :database_error}
        end

      {:ok, nil} ->
        {:ok, 0}

      {:error, :not_found} ->
        {:ok, 0}

      {:error, _unanswered} ->
        {:error, :database_error}
    end
  end

  def activate_invited(_user), do: {:ok, 0}

  @doc """
  Seat `user_id` in the thread an invitation names, added by its issuer,
  who must still sit there, under the thread's lock; `verify` is asked
  there too (`Arca.SharedThreadMembers.seat/5`). A person seated already
  keeps the seat they hold.
  """
  @spec seat_invited(String.t(), String.t(), String.t(), (-> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def seat_invited(thread_id, user_id, issuer, verify) when is_function(verify, 0) do
    case Arca.SharedThreadMembers.seat(server(), thread_id, user_id, issuer, verify: verify) do
      {:ok, _seat} -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Tell a thread's people, once an invitation's seat in it committed."
  @spec joined(String.t()) :: :ok
  def joined(thread_id) when is_binary(thread_id), do: announce(:changed, thread_id)

  @doc """
  The title of the thread `thread_id` names, read by the server for the
  invitation and sign-in pages before anyone is seated: a pair has none.
  """
  @spec title_of(String.t()) :: {:ok, String.t() | nil} | {:error, :not_found | :unavailable}
  def title_of(thread_id) when is_binary(thread_id) do
    case Arca.SharedThreads.get(server(), thread_id) do
      {:ok, %{title: title}} -> {:ok, title}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Whether the thread `thread_id` is active and `user_id` sits in it, read
  by the server: an invitation's issuer check.
  """
  @spec active_seat?(String.t(), String.t()) :: {:ok, boolean()} | {:error, :unavailable}
  def active_seat?(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    with {:ok, %{status: "active"}} <- Arca.SharedThreads.get(server(), thread_id),
         {:ok, _seat} <- Arca.SharedThreadMembers.find(server(), thread_id, user_id) do
      {:ok, true}
    else
      {:ok, %{}} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  Tell everyone a committed denial changed a thread for, from what it
  returned (`Arca.SecurityTransitions.deny_user/3`): the denied person
  and the people of each thread they left.
  """
  @spec announce_denied(String.t(), map()) :: :ok
  def announce_denied(user_id, %{left_shared_thread_ids: thread_ids}) do
    Enum.each(thread_ids, &announce(:changed, &1, [user_id]))
  end

  # ---- internals --------------------------------------------------------------

  # The thread, for a person seated in it; to anyone else a missing one.
  defp seated(user_id, thread_id) do
    with {:ok, thread} <- Arca.SharedThreads.get(server(), thread_id),
         {:ok, _seat} <- Arca.SharedThreadMembers.find(server(), thread_id, user_id) do
      {:ok, thread}
    else
      {:error, :not_found} -> missing(thread_id)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp together?(user_a, user_b),
    do: match?({:ok, true}, Arca.SharedThreadMembers.together?(server(), user_a, user_b))

  defp not_pair(%{kind: "pair"}), do: {:error, {:shared_thread, :pair}}
  defp not_pair(_thread), do: :ok

  defp title(title) when is_binary(title) do
    case String.trim(title) do
      "" ->
        {:error, {:invalid_argument, "A thread needs a title"}}

      trimmed when byte_size(trimmed) > 200 ->
        {:error, {:invalid_argument, "A title is at most 200 bytes"}}

      trimmed ->
        {:ok, trimmed}
    end
  end

  defp title(_title), do: {:error, {:invalid_argument, "A thread needs a title"}}

  defp find_person(id) do
    if Sanctum.Auth.Identity.key?(id), do: Users.get_by_identity(id), else: Users.get(id)
  end

  defp changed({:ok, thread}, user_id, thread_id) do
    announce(:changed, thread_id)
    {:ok, view(thread, user_id)}
  end

  defp changed({:error, reason}, _user_id, thread_id), do: refused(reason, thread_id)

  defp rows(thread_id) do
    case Arca.SharedThreadMembers.list(server(), thread_id) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> unavailable(reason)
    end
  end

  # Each person the thread names now, and `also`, told the change once it
  # committed. An unanswered read tells only `also`.
  defp announce(kind, thread_id, also \\ []) do
    people =
      case Arca.SharedThreadMembers.list(server(), thread_id) do
        {:ok, rows} -> for %{status: "active", user_id: id} <- rows, do: id
        {:error, _unanswered} -> []
      end

    Sanctum.Telemetry.shared_thread(kind, thread_id, people ++ also)
  end

  defp view(thread, user_id) do
    base = %{
      id: thread.id,
      kind: thread.kind,
      title: thread.title,
      status: thread.status,
      created_by: thread.created_by,
      created_at: thread.created_at,
      archived_at: thread.archived_at,
      last_message_at: thread.last_message_at
    }

    case thread do
      %{kind: "pair", pair_of: pair_of} when is_binary(pair_of) ->
        other = pair_of |> String.split(":") |> Enum.find(&(&1 != user_id))
        Map.put(base, :with, %{user_id: other, name: Users.display_name(other)})

      _shared ->
        base
    end
  end

  defp person(%{status: "active", user_id: user_id} = row) do
    handle =
      case Users.get(user_id) do
        {:ok, %{namespace: handle}} when is_binary(handle) and handle != "" -> handle
        _none -> nil
      end

    %{
      user_id: user_id,
      name: Users.display_name(user_id),
      handle: handle,
      status: "active",
      since: row.created_at
    }
  end

  defp person(%{status: "invited", person_identifier: identifier} = row),
    do: %{identifier: identifier, status: "invited", since: row.created_at}

  defp message(row) do
    %{
      id: row.id,
      seq: row.seq,
      author: row.author,
      content: row.content,
      attachments: Map.get(row.payload || %{}, "attachments", []),
      inserted_at: row.inserted_at
    }
  end

  defp missing(thread_id), do: {:error, {:not_found, "Thread", thread_id}}

  # The store's refusals as the reasons `Prima.Refusal` reads.
  defp refused(:not_found, thread_id) when is_binary(thread_id), do: missing(thread_id)
  defp refused(:not_member, thread_id) when is_binary(thread_id), do: missing(thread_id)

  defp refused(reason, _thread_id)
       when reason in [:archived, :pair, :not_together, :recovering_from_restore],
       do: {:error, {:shared_thread, reason}}

  defp refused({:limit_reached, _key, _cap} = reason, _thread_id), do: {:error, reason}
  defp refused({:cap_unverifiable, _key} = reason, _thread_id), do: {:error, reason}
  defp refused(:not_owner, _thread_id), do: {:error, :not_owner}

  defp refused({:invalid, _errors}, _thread_id),
    do: {:error, {:invalid_argument, "That is not a thread or a person"}}

  defp refused(reason, _thread_id), do: unavailable(reason)

  defp unavailable(reason) do
    Logger.error("[Sanctum.SharedThreads] the store did not answer: #{inspect(reason)}")
    {:error, {:unavailable, "Storage"}}
  end

  defp server, do: Prima.Actor.system()
end
