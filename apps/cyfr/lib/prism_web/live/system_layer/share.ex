# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Share do
  @moduledoc """
  The sharing sheet, which only the system layer draws: one of the
  person's own vault entries offered to everyone on this CYFR or to one
  shared thread they sit in, a pair included, with two optional daily
  caps. The threads are the ones the prompt names (`threads`), each under
  the name the person reads; there is no list of people to pick.

  The caps start empty. Empty is no limit, `0` admits no use, and a
  number is the most requests that day, per person or by everyone
  together. The sheet says what a share to everyone means while it is
  chosen, each fact while it is true: to anyone, that with no cap anyone on
  this CYFR may use it without limit; to the platform administrator, that
  it is also what each new person's AQUA uses when it fits. It reads the
  choice from the form's last change (`choice`), which the system layer
  keeps on the shown prompt once `choice/2` has held it to the form.

  `args/2` holds what the sheet sent to `share.create`'s arguments before
  anything is dispatched, through `audience/2` and `caps/1`, which the
  Vault page's audience and caps changes read too; which entry may be
  shared, and to whom, is the operation's to decide. The sheet holds no
  value of the entry and asks for none.

  A page opens the sheet with `prompt/3` for an entry `shareable?/1`
  admits, offering the threads `threads/1` reads. The administrator's
  setup opens it with the one preset there is (`:setup`): everyone, with a daily cap per person filled in. A preset only starts the sheet's
  choice, held to the form like any change (`choice/2`), and what is made
  is what the sheet shows when it is confirmed (`args/2`).
  """

  use Phoenix.Component

  require Logger

  @everyone "everyone"
  # A cap is a count: no longer text is one, so none is kept.
  @field_max 32
  @uncapped "Shared with everyone and no cap, anyone on this CYFR may use it without limit."
  @newcomers "You administer this CYFR, so a key you share with everyone is also what each " <>
               "new person's AQUA uses when it fits"
  @thread "shared_thread:"
  # The administrator's setup's daily cap per person, until it is decided.
  @setup_person_daily 50

  attr :id, :string, required: true
  attr :prompt, :map, required: true
  attr :administrator, :boolean, required: true
  attr :myself, :any, required: true
  attr :choice, :map, default: %{}

  @doc "The sheet's form: the audience, the two caps and what they mean."
  def sheet(assigns) do
    ~H"""
    <form
      id={"#{@id}-share"}
      phx-submit="share_create"
      phx-change="share_change"
      phx-target={@myself}
      class="space-y-3"
      data-test="share-sheet"
    >
      <input type="hidden" name="prompt_id" value={@prompt.id} />
      <div class="space-y-1 text-xs text-gray-300" data-test="share-warning">
        <p>You are responsible for following the provider's terms when sharing this entry.</p>
        <p>What recipients send reaches the provider as you.</p>
        <p>
          Recipients use your provider limits up to the caps you set and never see the credential. You can revoke the share at any time.
        </p>
      </div>
      <fieldset class="space-y-1" data-test="share-audience">
        <legend class="text-sm font-medium">Share {@prompt.subject.name} with</legend>
        <label class="flex items-center gap-2 text-sm">
          <input
            type="radio"
            name="audience"
            value={everyone()}
            checked={@choice["audience"] == everyone()}
            required
          />
          <span>Everyone on this CYFR</span>
        </label>
        <label :for={thread <- @prompt.subject.threads} class="flex items-center gap-2 text-sm">
          <input
            type="radio"
            name="audience"
            value={thread_value(thread.id)}
            checked={@choice["audience"] == thread_value(thread.id)}
            data-thread={thread.id}
          />
          <span>{thread.name}</span>
        </label>
        <p
          :if={@prompt.subject.threads == []}
          class="text-xs text-gray-400"
          data-test="share-no-threads"
        >
          You are in no shared thread, so it can be shared with everyone alone.
        </p>
      </fieldset>
      <fieldset class="space-y-2" data-test="share-caps">
        <legend class="text-sm font-medium">Daily caps</legend>
        <div class="grid grid-cols-2 gap-3">
          <label class="block text-xs text-gray-300">
            Each person, per day
            <input
              type="number"
              name="person_daily"
              value={@choice["person_daily"]}
              min="0"
              step="1"
              inputmode="numeric"
              data-test="share-person-daily"
              class="mt-1 w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 text-sm"
            />
          </label>
          <label class="block text-xs text-gray-300">
            Everyone together, per day
            <input
              type="number"
              name="total_daily"
              value={@choice["total_daily"]}
              min="0"
              step="1"
              inputmode="numeric"
              data-test="share-total-daily"
              class="mt-1 w-full rounded-md border border-gray-600 bg-transparent px-2 py-1 text-sm"
            />
          </label>
        </div>
        <p class="text-xs text-gray-300" data-test="share-caps-meaning">
          An empty cap is no limit. 0 admits no use. A number is the most requests that day; a day ends at midnight UTC.
        </p>
        <p
          :if={everyone_words(@administrator, @choice)}
          class="text-xs text-gray-300"
          data-test="share-everyone"
        >
          {everyone_words(@administrator, @choice)}
        </p>
      </fieldset>
    </form>
    """
  end

  @doc """
  `share.create`'s arguments for what the sheet of `subject` sent: the
  entry the prompt names, the audience chosen, everyone or one of the
  prompt's threads, and each cap typed, a whole number, absent when left
  empty. `{:error, sentence}` for anything else, with nothing dispatched.
  """
  @spec args(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def args(%{entry_id: entry_id, threads: threads}, params) when is_map(params) do
    with {:ok, audience} <- audience(params["audience"], threads),
         {:ok, caps} <- caps(params) do
      {:ok,
       %{"entry_id" => entry_id}
       |> Map.merge(audience)
       |> Prima.MapUtil.put_present("person_daily", caps["person_daily"])
       |> Prima.MapUtil.put_present("total_daily", caps["total_daily"])}
    end
  end

  @doc """
  The audience a choice names, as `share.create` and `share.set_audience`
  take it: `"everyone"`, or `"shared_thread:<id>"` for one of `threads`, the
  person's own. `{:error, sentence}` for anything else.
  """
  @spec audience(term(), [%{id: String.t()}]) :: {:ok, map()} | {:error, String.t()}
  def audience(@everyone, _threads), do: {:ok, %{"audience" => "everyone"}}

  def audience(@thread <> id, threads) do
    if Enum.any?(threads, &(&1.id == id)),
      do: {:ok, %{"audience" => "thread", "thread_id" => id}},
      else: no_audience()
  end

  def audience(_chosen, _threads), do: no_audience()

  @doc "The choice that names `audience`, as `audience/2` reads it."
  @spec audience_value(map()) :: String.t()
  def audience_value(%{"audience" => "thread", "thread_id" => id}) when is_binary(id),
    do: @thread <> id

  def audience_value(%{"audience" => audience}), do: to_string(audience)

  @doc """
  The choice a change of the sheet of `subject` sent, held to the form:
  the audience, one the sheet offers, and the two caps, each a string of
  at most #{@field_max} bytes, nothing else. `:error` when any of them is
  not, and nothing of that change is kept: the form never sends one.
  """
  @spec choice(map(), %{threads: [%{id: String.t()}]}) :: {:ok, map()} | :error
  def choice(params, %{threads: threads}) when is_map(params) do
    choice = Map.take(params, ["audience", "person_daily", "total_daily"])
    if Enum.all?(choice, &field?(&1, threads)), do: {:ok, choice}, else: :error
  end

  defp field?({"audience", value}, threads), do: match?({:ok, _}, audience(value, threads))
  defp field?({_cap, value}, _threads), do: is_binary(value) and byte_size(value) <= @field_max

  @doc """
  Both daily caps as typed, `person_daily` and `total_daily`: each a whole
  number, or nil when left empty, which is no limit. `{:error, sentence}`
  for anything else.
  """
  @spec caps(map()) :: {:ok, map()} | {:error, String.t()}
  def caps(params) when is_map(params) do
    with {:ok, person} <- cap(params["person_daily"]),
         {:ok, total} <- cap(params["total_daily"]),
         do: {:ok, %{"person_daily" => person, "total_daily" => total}}
  end

  defp no_audience,
    do: {:error, "Choose who it is shared with: everyone, or one of your threads."}

  defp cap(nil), do: {:ok, nil}

  defp cap(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {number, ""} when number >= 0 -> {:ok, number}
          _not_a_count -> cap_refused()
        end
    end
  end

  defp cap(_other), do: cap_refused()

  defp cap_refused,
    do: {:error, "A cap is a whole number of requests a day, or empty for no limit."}

  defp everyone, do: @everyone
  defp thread_value(id), do: audience_value(%{"audience" => "thread", "thread_id" => id})

  # What a share to everyone means, said only while everyone is chosen and
  # each part only while it is true: no limit while both caps are empty, and
  # to the platform administrator that newcomers' AQUA uses it, capped or
  # not. A cap that is not a count is not empty. Nil when nothing applies.
  defp everyone_words(administrator, %{"audience" => @everyone} = choice) do
    uncapped = caps(choice) == {:ok, %{"person_daily" => nil, "total_daily" => nil}}

    case {administrator, uncapped} do
      {false, false} -> nil
      {false, true} -> @uncapped
      {true, false} -> @newcomers <> "."
      {true, true} -> @uncapped <> " " <> @newcomers <> ", with no limit unless you set one."
    end
  end

  defp everyone_words(_administrator, _choice), do: nil

  @doc """
  Whether the store would share `entry`, as `vault.list` answers it: the
  rule of `Arca.Shares.eligible/1`. The operation decides again.
  """
  @spec shareable?(map()) :: boolean()
  def shareable?(%{status: "active", attach_only: true, kind: kind, destination: %{} = to}),
    do:
      kind in Prima.CredentialKinds.shareable() and Map.get(to, "methods", []) != [] and
        Map.get(to, "paths", []) != []

  def shareable?(_entry), do: false

  @doc """
  The person's active shared threads as the sheet offers them, each
  `%{id, name}`, a pair under the other person's name. A read that fails
  offers none, said in the log.
  """
  @spec threads(Phoenix.LiveView.Socket.t()) :: [%{id: String.t(), name: String.t()}]
  def threads(socket) do
    case PrismWeb.Ops.fetch_list(socket, "shared_thread/list", :threads) do
      {:ok, threads} ->
        for %{status: "active"} = thread <- threads,
            do: %{id: thread.id, name: thread_name(thread)}

      {:error, message} ->
        Logger.warning("[PrismWeb.SystemLayer.Share] shared_thread/list failed: #{message}")
        []
    end
  end

  defp thread_name(%{kind: "pair", with: %{name: name}}), do: name
  defp thread_name(%{title: title}), do: title

  @doc """
  The system layer's prompt for sharing `entry` (its `id` and `name`)
  with everyone or one of `threads`; `preset` `:setup` starts the sheet
  at the administrator's setup's choice.
  """
  @spec prompt(%{id: String.t(), name: String.t()}, [map()], :setup | nil) :: map()
  def prompt(%{id: id, name: name}, threads, preset \\ nil) do
    subject = %{entry_id: id, name: name, threads: threads}

    %{
      id: "share-" <> id,
      kind: :share,
      action: :credential_sharing,
      subject: if(preset, do: Map.put(subject, :preset, preset), else: subject)
    }
  end

  @doc "The presets a share prompt may carry: the administrator's setup's alone."
  @spec presets() :: [:setup]
  def presets, do: [:setup]

  @doc """
  The choice the sheet of the shown `prompt` draws: the form's last change
  the layer kept, else the prompt's preset held to the form, else none.
  """
  @spec drawn(map()) :: map()
  def drawn(%{choice: %{} = choice}), do: choice

  def drawn(%{subject: %{preset: :setup, threads: threads}}) do
    {:ok, choice} =
      choice(
        %{
          "audience" => @everyone,
          "person_daily" => Integer.to_string(@setup_person_daily),
          "total_daily" => ""
        },
        %{threads: threads}
      )

    choice
  end

  def drawn(_prompt), do: %{}
end
