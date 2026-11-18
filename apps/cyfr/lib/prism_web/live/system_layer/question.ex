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
  kept, in a region of a fixed height that scrolls on its own and breaks
  any line, so no length of text moves the frame or the choices, and text
  that reads like a button stays text inside the block. Masking is said.

  The choices are a phone's (`answer/2`): Don't allow; Allow once; Allow
  for an hour; Always allow; and, under a second press ("More choices"),
  Never allow and the switch "only when this caller starts it", offered
  only when the caller is known. An answer that lasts covers every caller
  unless the switch is on. Closing the card without choosing is "Don't
  allow", once. The choice the card shows (`choice/1`: the second press
  and the switch) is kept on the shown prompt by the layer, so it ends
  with the prompt.
  """

  use Phoenix.Component

  alias Prima.Question.Caller

  # How long "Allow for an hour" lasts.
  @hour_s 3600

  @choices ~w(deny_once allow_once allow_hour allow_always deny_always)

  @doc "The choices a card sends, by the names its buttons carry."
  @spec choices() :: [String.t()]
  def choices, do: @choices

  @doc "The card's choice as it starts: the second press not made, the switch off."
  @spec choice(map()) :: %{more: boolean(), this_caller: boolean()}
  def choice(prompt), do: Map.get(prompt, :choice, %{more: false, this_caller: false})

  @doc """
  The `question.answer` JSON a choice names (`Prima.Question.Answer`),
  covering the asking run's caller alone when `this_caller` is true, and
  every caller otherwise. `:error` for a name `choices/0` does not list.
  """
  @spec answer(String.t(), boolean()) :: {:ok, map()} | :error
  def answer("deny_once", _this_caller), do: {:ok, %{"effect" => "deny", "lasts" => "once"}}
  def answer("allow_once", _this_caller), do: {:ok, %{"effect" => "allow", "lasts" => "once"}}

  def answer("allow_hour", this_caller) do
    until =
      DateTime.utc_now()
      |> DateTime.add(@hour_s, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    {:ok, lasting("allow", %{"until" => until}, this_caller)}
  end

  def answer("allow_always", this_caller), do: {:ok, lasting("allow", "always", this_caller)}
  def answer("deny_always", this_caller), do: {:ok, lasting("deny", "always", this_caller)}
  def answer(_choice, _this_caller), do: :error

  defp lasting(effect, lasts, this_caller),
    do: %{
      "effect" => effect,
      "lasts" => lasts,
      "covers" => if(this_caller, do: "this_caller", else: "any_caller")
    }

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

  @doc "Whether the card offers its switch: only for a caller it knows."
  @spec switchable?(map()) :: boolean()
  def switchable?(%{subject: %{caller: caller}}), do: caller != Caller.encode(:unknown)

  @doc "When a question waits until, as the card says it."
  @spec until(DateTime.t()) :: String.t()
  def until(%DateTime{} = deadline), do: Calendar.strftime(deadline, "%Y-%m-%d %H:%M UTC")

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
        <dd class="col-span-2" data-test="question-deadline">{until(@subject.deadline)}</dd>
      </dl>

      <figure
        class="rounded-md border border-dashed border-gray-600 bg-gray-950 p-3"
        aria-labelledby={"#{@id}-question-words"}
        data-test="question-words"
      >
        <figcaption id={"#{@id}-question-words"} class="mb-2 text-xs text-gray-400">
          In the component's own words. CYFR does not check them.
        </figcaption>
        <div
          class="max-h-56 overflow-auto [overflow-wrap:anywhere] [contain:paint]"
          tabindex="0"
          data-test="question-block"
        >
          <p class="text-sm text-gray-100" data-test="question-summary">
            {@subject.summary}
          </p>
          <pre
            class="mt-2 whitespace-pre-wrap font-mono text-xs text-gray-200"
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
  The choices, each sending `question_answer` with its name; the second
  press shows Never allow and, for a caller the card knows, the switch.
  """
  def choices(assigns) do
    assigns =
      assign(assigns,
        choice: choice(assigns.prompt),
        switchable: switchable?(assigns.prompt)
      )

    ~H"""
    <div class="space-y-3" data-test="question-choices">
      <div class="flex flex-wrap justify-end gap-2">
        <.option prompt={@prompt} myself={@myself} name="deny_once" class={@button_class.(false)}>
          Don't allow
        </.option>
        <.option prompt={@prompt} myself={@myself} name="allow_once" class={@button_class.(false)}>
          Allow once
        </.option>
        <.option prompt={@prompt} myself={@myself} name="allow_hour" class={@button_class.(false)}>
          Allow for an hour
        </.option>
        <.option prompt={@prompt} myself={@myself} name="allow_always" class={@button_class.(true)}>
          Always allow
        </.option>
      </div>

      <div class="flex flex-wrap items-center justify-end gap-2">
        <button
          :if={not @choice.more}
          type="button"
          phx-click="question_more"
          phx-target={@myself}
          phx-value-id={@prompt.id}
          data-test="question-more"
          class="text-sm text-blue-300 underline underline-offset-2 hover:text-blue-200"
        >
          More choices
        </button>
        <button
          :if={@choice.more and @switchable}
          type="button"
          role="switch"
          aria-checked={to_string(@choice.this_caller)}
          phx-click="question_switch"
          phx-target={@myself}
          phx-value-id={@prompt.id}
          data-test="question-switch"
          class="flex items-center gap-2 text-sm"
        >
          <span class={[
            "inline-block h-4 w-7 rounded-full border border-gray-500",
            if(@choice.this_caller, do: "bg-blue-600", else: "bg-gray-800")
          ]}></span>
          Only when this caller starts it
        </button>
        <.option
          :if={@choice.more}
          prompt={@prompt}
          myself={@myself}
          name="deny_always"
          class={@button_class.(false)}
        >
          Never allow
        </.option>
      </div>
    </div>
    """
  end

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
