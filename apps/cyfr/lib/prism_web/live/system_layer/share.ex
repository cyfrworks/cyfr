# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Share do
  @moduledoc """
  The sharing sheet, which only the system layer draws: one of the
  person's own vault entries offered to everyone on this CYFR or to one
  group they are an active member of, a DM included, with two optional
  daily caps. The groups are the ones the prompt names (`groups`), each
  under the name the person reads; there is no list of people to pick.

  The caps start empty. Empty is no limit, `0` admits no use, and a
  number is the most requests that day, per person or by everyone
  together. The sheet says what a share to everyone with no cap means,
  and to the platform administrator what it means for a newcomer's AQUA.

  `args/2` holds what the sheet sent to `share.create`'s arguments before
  anything is dispatched, through `audience/2` and `caps/1`, which the
  Vault page's audience and caps changes read too; which entry may be
  shared, and to whom, is the operation's to decide. The sheet holds no
  value of the entry and asks for none.
  """

  use Phoenix.Component

  @everyone "everyone"
  @group "group:"

  attr :id, :string, required: true
  attr :prompt, :map, required: true
  attr :administrator, :boolean, required: true
  attr :myself, :any, required: true

  @doc "The sheet's form: the audience, the two caps and what they mean."
  def sheet(assigns) do
    ~H"""
    <form
      id={"#{@id}-share"}
      phx-submit="share_create"
      phx-target={@myself}
      class="space-y-3"
      data-test="share-sheet"
    >
      <input type="hidden" name="prompt_id" value={@prompt.id} />
      <fieldset class="space-y-1" data-test="share-audience">
        <legend class="text-sm font-medium">Share {@prompt.subject.name} with</legend>
        <label class="flex items-center gap-2 text-sm">
          <input type="radio" name="audience" value={everyone()} required />
          <span>Everyone on this CYFR</span>
        </label>
        <label :for={group <- @prompt.subject.groups} class="flex items-center gap-2 text-sm">
          <input type="radio" name="audience" value={group_value(group.id)} data-group={group.id} />
          <span>{group.name}</span>
        </label>
        <p
          :if={@prompt.subject.groups == []}
          class="text-xs text-gray-400"
          data-test="share-no-groups"
        >
          You are in no group, so it can be shared with everyone alone.
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
        <p class="text-xs text-gray-300" data-test="share-uncapped">
          {uncapped(@administrator)}
        </p>
      </fieldset>
      <p class="text-xs text-gray-400">
        No one sees the key: CYFR attaches it to their requests bound for the entry's destination. You can revoke the share at any time.
      </p>
    </form>
    """
  end

  @doc """
  `share.create`'s arguments for what the sheet of `subject` sent: the
  entry the prompt names, the audience chosen, everyone or one of the
  prompt's groups, and each cap typed, a whole number, absent when left
  empty. `{:error, sentence}` for anything else, with nothing dispatched.
  """
  @spec args(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def args(%{entry_id: entry_id, groups: groups}, params) when is_map(params) do
    with {:ok, audience} <- audience(params["audience"], groups),
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
  take it: `"everyone"`, or `"group:<id>"` for one of `groups`, the
  person's own. `{:error, sentence}` for anything else.
  """
  @spec audience(term(), [%{id: String.t()}]) :: {:ok, map()} | {:error, String.t()}
  def audience(@everyone, _groups), do: {:ok, %{"audience" => "everyone"}}

  def audience(@group <> id, groups) do
    if Enum.any?(groups, &(&1.id == id)),
      do: {:ok, %{"audience" => "group", "group_id" => id}},
      else: no_audience()
  end

  def audience(_chosen, _groups), do: no_audience()

  @doc "The choice that names `audience`, as `audience/2` reads it."
  @spec audience_value(map()) :: String.t()
  def audience_value(%{"audience" => "group", "group_id" => id}) when is_binary(id),
    do: @group <> id

  def audience_value(%{"audience" => audience}), do: to_string(audience)

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
    do: {:error, "Choose who it is shared with: everyone, or one of your groups."}

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
  defp group_value(id), do: audience_value(%{"audience" => "group", "group_id" => id})

  defp uncapped(true),
    do:
      "Shared with everyone and no cap, anyone on this CYFR may use it without limit. You " <>
        "administer this CYFR, so a key you share with everyone is also what each new " <>
        "person's AQUA uses when it fits, with no limit unless you set one."

  defp uncapped(false),
    do: "Shared with everyone and no cap, anyone on this CYFR may use it without limit."
end
