# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Question do
  @moduledoc """
  A component's question as its card draws it, which only the system
  layer does: a frame of CYFR's own around the component's words.

  The frame is fixed in place: the component's publisher and name, "wants
  to" and the action's title its manifest declares, who started the run
  (`caller_words/1`), until when it waits, and the choices. The
  component's block sits inside the frame: its summary and its operation,
  marked as its own words, as plain escaped text with its line breaks
  kept. The one-line summary stays in view; the operation is in a region
  of a fixed height that scrolls on its own and breaks any line, so no
  length of text moves the frame, the summary or the choices, and text
  that reads like a button stays text inside the block. Masking is said.

  The choices (`offered/1`, each named for the answer it sends,
  `answer/1`): a row for the caller that started the run, headed with who
  that is, of Never allow, Allow once, Allow for an hour and Always allow,
  the three that last covering that caller alone; and below it Always
  allow whoever starts it, which covers every caller and needs a fresh
  confirmation, drawn inside the card. A caller CYFR does not know cannot
  be named in an answer that lasts, so its row offers Allow once alone.
  Once an answer that lasts is refused because no installed version asks
  for the permission in these words, the card offers only Allow once
  (`once_only`, kept on the shown prompt by the layer, so it ends with
  the prompt). Closing the card without choosing is "Don't allow", once
  (`dismissal/0`).
  """

  use Phoenix.Component

  alias Prima.Question.Caller

  # How long "Allow for an hour" lasts.
  @hour_s 3600

  @caller_row ~w(deny_always_this_caller allow_once allow_hour_this_caller allow_always_this_caller)
  @any_caller "allow_always_any_caller"

  @doc """
  The card's kept choice as it starts: every choice offered.
  """
  @spec choice(map()) :: %{once_only: boolean()}
  def choice(prompt), do: Map.get(prompt, :choice, %{once_only: false})

  @doc """
  The choices the card offers, in their order, by the names its buttons
  carry: the caller's row, then the answer for any caller. The layer
  sends no other.
  """
  @spec offered(map()) :: [String.t()]
  def offered(prompt) do
    cond do
      choice(prompt).once_only -> ["allow_once"]
      known_caller?(prompt) -> @caller_row ++ [@any_caller]
      true -> ["allow_once", @any_caller]
    end
  end

  @doc """
  The `question.answer` JSON a choice `offered/1` names
  (`Prima.Question.Answer`): `_this_caller` covers the asking run's caller
  alone, `_any_caller` every caller.
  """
  @spec answer(String.t()) :: map()
  def answer("allow_once"), do: %{"effect" => "allow", "lasts" => "once"}
  def answer("deny_always_this_caller"), do: lasting("deny", "always", "this_caller")
  def answer("allow_always_this_caller"), do: lasting("allow", "always", "this_caller")
  def answer("allow_always_any_caller"), do: lasting("allow", "always", "any_caller")

  def answer("allow_hour_this_caller") do
    until =
      DateTime.utc_now()
      |> DateTime.add(@hour_s, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    lasting("allow", %{"until" => until}, "this_caller")
  end

  defp lasting(effect, lasts, covers),
    do: %{"effect" => effect, "lasts" => lasts, "covers" => covers}

  @doc "The answer a card closed without a choice gives: Don't allow, once."
  @spec dismissal() :: map()
  def dismissal, do: %{"effect" => "deny", "lasts" => "once"}

  @doc """
  Who started a run, from its caller's text (`Prima.Question.Caller`), as
  a person reads it: "you", the assistant's name, the app's publisher and
  name, or for a device, a key, a schedule and a webhook the kind and the
  end of its id. `any`, a standing answer's caller, is anyone.
  """
  @spec caller_words(String.t()) :: String.t()
  def caller_words(text) do
    if text == Caller.any() do
      "anyone"
    else
      case Caller.decode(text) do
        {:ok, caller} -> words(caller)
        {:error, _unread} -> "someone CYFR does not know"
      end
    end
  end

  defp words(:person), do: "you"
  defp words(:unknown), do: "someone CYFR does not know"
  defp words({:agent, name}), do: "the assistant #{name}"
  defp words({:tincture, name}), do: "the app #{name}"
  defp words({:device, id}), do: "a paired device (#{short(id)})"
  defp words({:key, id}), do: "an API key (#{short(id)})"
  defp words({:schedule, id}), do: "a schedule (#{short(id)})"
  defp words({:webhook, id}), do: "a webhook (#{short(id)})"

  # The end of an id, enough to tell two apart.
  defp short(id) do
    if String.length(id) > 8, do: "…" <> String.slice(id, -6, 6), else: id
  end

  defp known_caller?(%{subject: %{caller: caller}}), do: caller != Caller.encode(:unknown)

  attr :id, :string, required: true
  attr :prompt, :map, required: true

  @doc "The frame's rows and the component's block inside it."
  def card(assigns) do
    assigns = assign(assigns, :subject, assigns.prompt.subject)

    ~H"""
    <section class="space-y-3" data-test="question" data-ref={@subject.ref}>
      <dl class="grid grid-cols-3 gap-1 text-sm" data-test="question-frame">
        <dt class="text-gray-400">Component</dt>
        <dd class="col-span-2 break-all" data-test="question-component">
          {@subject.name}, published by {@subject.publisher}
        </dd>
        <dt class="text-gray-400">Started by</dt>
        <dd class="col-span-2 break-all" data-test="question-caller">
          {caller_words(@subject.caller)}
        </dd>
        <dt class="text-gray-400">Waits until</dt>
        <dd class="col-span-2" data-test="question-deadline">
          <time datetime={DateTime.to_iso8601(@subject.deadline)} data-local>
            {DateTime.to_iso8601(@subject.deadline)}
          </time>
        </dd>
      </dl>

      <figure
        class="rounded-md border border-dashed border-gray-600 bg-gray-950 p-3"
        aria-labelledby={"#{@id}-question-words"}
        data-test="question-words"
      >
        <figcaption id={"#{@id}-question-words"} class="mb-2 text-xs text-gray-400">
          In the component's own words. CYFR does not check them.
        </figcaption>
        <p class="text-sm text-gray-100 [overflow-wrap:anywhere]" data-test="question-summary">
          {@subject.summary}
        </p>
        <div
          class="mt-2 max-h-56 overflow-auto [overflow-wrap:anywhere] [contain:paint]"
          tabindex="0"
          data-test="question-block"
        >
          <pre
            class="whitespace-pre-wrap font-mono text-xs text-gray-200"
            data-test="question-operation"
          >{@subject.operation}</pre>
        </div>
        <p :if={@subject.masked} class="mt-2 text-xs text-gray-400" data-test="question-masked">
          CYFR hid credentials it gave this run from these words.
        </p>
      </figure>
    </section>
    """
  end

  attr :prompt, :map, required: true
  attr :myself, :any, required: true
  attr :button_class, :any, required: true

  @doc """
  The choices `offered/1` lists, each sending `question_answer` with its
  name: the caller's row under its heading, and the answer for any caller
  below it.
  """
  def choices(assigns) do
    offered = offered(assigns.prompt)

    assigns =
      assign(assigns,
        row: Enum.filter(offered, &(&1 != @any_caller)),
        any_caller: @any_caller in offered
      )

    ~H"""
    <div class="space-y-3" data-test="question-choices">
      <div class="space-y-2" data-test="question-caller-row">
        <p class="text-sm text-gray-300 [overflow-wrap:anywhere]">
          For {caller_words(@prompt.subject.caller)}:
        </p>
        <div class="flex flex-wrap justify-end gap-2">
          <.option
            :for={name <- @row}
            prompt={@prompt}
            myself={@myself}
            name={name}
            class={@button_class.(name == "allow_always_this_caller")}
          >
            {label(name)}
          </.option>
        </div>
      </div>

      <div
        :if={@any_caller}
        class="flex justify-end border-t border-gray-700 pt-3"
        data-test="question-any-caller"
      >
        <.option
          prompt={@prompt}
          myself={@myself}
          name="allow_always_any_caller"
          class={@button_class.(false)}
        >
          Always allow, whoever starts it
          <span class="block text-xs font-normal text-gray-400">Needs a fresh confirmation</span>
        </.option>
      </div>
    </div>
    """
  end

  defp label("deny_always_this_caller"), do: "Never allow"
  defp label("allow_once"), do: "Allow once"
  defp label("allow_hour_this_caller"), do: "Allow for an hour"
  defp label("allow_always_this_caller"), do: "Always allow"

  attr :prompt, :map, required: true
  attr :myself, :any, required: true
  attr :name, :string, required: true
  attr :class, :any, required: true
  slot :inner_block, required: true

  defp option(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="question_answer"
      phx-target={@myself}
      phx-value-id={@prompt.id}
      phx-value-choice={@name}
      data-test="question-choice"
      data-choice={@name}
      class={@class}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
