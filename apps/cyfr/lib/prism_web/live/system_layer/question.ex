# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.SystemLayer.Question do
  @moduledoc """
  A component's question as its card draws it, which only the system
  layer does: a frame of CYFR's own around the component's words.

  The frame is fixed in place. Its heading is one sentence of CYFR's
  around the names and the developer's words (`headline/1`): who started
  the run by its short name in italics (`name/1`), "is trying to use"
  the component's name in bold, "to" the
  action's title its manifest declares, the words an answer that lasts is
  kept for, "and it will" this run's summary, and a full stop, so a person
  reads first who asks and for what. The title and the summary are drawn
  apart from CYFR's words, so a summary that reads like CYFR speaking is
  still seen as the component's. Under it, Details, closed as each card
  opens and left as the person sets it while the card is shown, and
  beside it the time the question still waits, which the browser counts
  down each second from the deadline. Opened, Details shows the
  component's block: its exact operation alone, as plain escaped text
  with its line breaks kept, set apart by its own border, in a region of
  a fixed height that scrolls on its own, named for a screen reader as
  what the component says it will run, and breaks any line, so no length
  of text moves the frame or the choices, and text that reads like a
  button stays text inside the block. Masking is said. Then, each with
  its label, the full names the sentence shortens: who started it by its
  kind and publisher (`caller_words/1`), the component with its
  publisher, so a component named like CYFR is seen for what it is, and
  until when it waits, in the person's own time, with the date only when
  it is not today.

  The choices (`offered/1`, each named for the answer it sends,
  `answer/1`), under "Allow this?": a group named for the caller that
  started the run ("For you", "For *q-asker*"), of Never, Just once, For an hour and
  Always, the three that last covering that caller alone; and a group
  "For everyone" of one button, Always, which covers every caller and
  asks for the person's passkey, a fresh confirmation drawn inside the
  card. A caller CYFR does not know cannot be named in an answer that
  lasts, so its group offers Just once alone. Once an answer that lasts
  is refused because no installed version asks for the permission in
  these words, the card offers only Just once (`once_only`, kept on the
  shown prompt by the layer, so it ends with the prompt) and says so
  (`once_only_words/0`). Closing the card without choosing, by its cross
  or Escape, is "Don't allow", once (`dismissal/0`).

  No button is drawn filled, so no answer, the one that lasts longest
  least of all, looks like the card's default. The caller's four stand on
  one line on a screen as wide as a small tablet's, and two by two, each
  a finger's height, on a narrower one, where a group of one button is as
  wide as the group.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Prima.Question.Caller

  # How long "For an hour" lasts.
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
  The card's sentence once an answer that lasts is refused because no
  installed version asks for the permission in these words: what the card
  then offers, by what is on it.
  """
  @spec once_only_words() :: String.t()
  def once_only_words,
    do:
      "No installed version asks for this permission in these words, so this answer " <>
        "cannot be kept: you can still allow it just once, or close this card with × to " <>
        "not allow it."

  # How the developer's words inside CYFR's sentence are drawn.
  @developer "font-normal text-amber-100"

  attr :subject, :map, required: true

  @doc """
  The card's heading, one sentence of CYFR's around the names and the
  developer's words: who started the run by its short name in italics
  (`name/1`), "is trying to use" the component's name in bold, "to" the
  action's declared title, the words an answer that lasts is kept for,
  "and it will" this run's summary, and a full stop when the summary ends
  with none. The person who started it reads "You are trying to use".
  CYFR's own words are plain weight; the title and the summary are drawn
  apart from them, in one way for both, so a summary that reads like
  CYFR speaking is still seen as the component's. Every part is plain
  escaped text: nothing in a component's words is read as markup.
  """
  def headline(assigns) do
    # The summary as drawn: no trailing white space before CYFR's stop.
    summary = String.trim_trailing(assigns.subject.summary)
    {caller, verb} = subject(name(assigns.subject.caller))

    assigns =
      assign(assigns,
        caller: caller,
        verb: verb,
        summary: summary,
        # CYFR's words between the title and the summary, when there is one.
        joined: if(summary != "", do: " and it will "),
        stop: if(ends_unstopped?(summary), do: "."),
        developer: @developer
      )

    ~H"""
    <em :if={@caller} class="italic" data-test="question-caller">{@caller}</em>{@verb} trying to use
    <strong
      class="font-bold"
      data-test="question-component-name"
    >{@subject.name}</strong>
    to <span
      class={@developer}
      data-test="question-title"
    >{@subject.title}</span>{@joined}<span
      :if={@summary != ""}
      class={@developer}
      data-test="question-summary"
    >{@summary}</span>{@stop}
    """
  end

  # The sentence's subject and its verb: "You are", or the caller's name,
  # drawn apart, then " is". The card's own words for a caller start the
  # sentence with a capital; a caller's own name is written as it is.
  defp subject(:you), do: {nil, "You are"}
  defp subject({:named, name}), do: {name, " is"}
  defp subject({:words, words}), do: {capital(words), " is"}

  @doc """
  Who started a run, by the name a person knows it by: `:you`; an app or
  an assistant by its own name alone (`{:named, "q-asker"}`), which
  Details names in full (`caller_words/1`); and a caller with no name of
  its own by the card's words for it (`{:words, "a schedule (…abc123)"}`).
  """
  @spec name(String.t()) :: :you | {:named, String.t()} | {:words, String.t()}
  def name(text) do
    case Caller.decode(text) do
      {:ok, :person} -> :you
      {:ok, {:agent, name}} -> {:named, name}
      {:ok, {:tincture, ref}} -> {:named, app_name(ref)}
      _other -> {:words, caller_words(text)}
    end
  end

  # An app's own name, from its reference (`<publisher>.<name>`) as the
  # reference's owner reads it: a publisher may hold dots, a name none.
  defp app_name(ref) do
    case Prima.ComponentRef.parse("tincture:" <> ref) do
      {:ok, %Prima.ComponentRef{name: name}} -> name
      {:error, _unread} -> ref
    end
  end

  defp capital(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  # The card ends the sentence with a full stop unless the component's last
  # words end it already, past any white space (the summary is drawn with
  # none at its end): after the summary, or after the title when there is
  # no summary.
  defp ends_unstopped?(summary), do: not String.ends_with?(summary, [".", "!", "?"])

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

  attr :prompt, :map, required: true

  @doc """
  Details, holding the component's block, the exact operation of this one
  run, and the frame's line: who published the component and until when
  it waits, in the person's own time, on one line that wraps at a word;
  and beside it the time left.
  """
  def card(assigns) do
    assigns = assign(assigns, :subject, assigns.prompt.subject)

    ~H"""
    <section data-test="question" data-ref={@subject.ref}>
      <div class="relative">
        <%!-- Closed as each card opens: a new question is a new element (its
          ref in its id), and once the person opens or closes it the
          browser's `open` is theirs, kept through every patch of the card. --%>
        <details
          id={"question-details-#{@subject.ref}"}
          phx-mounted={JS.ignore_attributes(["open"])}
          data-test="question-details"
        >
          <summary class="cursor-pointer rounded py-2 pr-24 text-sm text-gray-300 hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-300">
            Details
          </summary>
          <div class="space-y-3 pt-1">
            <%!-- Set apart by its own border, scroll and plain text, so the
              component's words never pass for CYFR's or for a button. --%>
            <div
              class="rounded-md border border-dashed border-gray-600 bg-gray-950 p-3"
              data-test="question-words"
            >
              <div
                class="max-h-56 overflow-auto [overflow-wrap:anywhere] [contain:paint]"
                tabindex="0"
                role="region"
                aria-label={"What #{@subject.name} says it will run"}
                data-test="question-block"
              >
                <pre
                  class="whitespace-pre-wrap font-mono text-xs text-gray-200"
                  data-test="question-operation"
                >{@subject.operation}</pre>
              </div>
              <p
                :if={@subject.masked}
                class="mt-2 text-xs text-gray-400"
                data-test="question-masked"
              >
                CYFR hid credentials it gave this run from these words.
              </p>
            </div>

            <%!-- The full names the sentence shortens: who started it, by its
              kind and publisher, and the component with its publisher, so a
              component named like CYFR is seen for what it is. --%>
            <dl
              class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm text-gray-300"
              data-test="question-frame"
            >
              <dt class="text-gray-400">Started by</dt>
              <dd class="[overflow-wrap:anywhere]" data-test="question-started-by">
                {caller_words(@subject.caller)}
              </dd>
              <dt class="text-gray-400">Component</dt>
              <dd class="[overflow-wrap:anywhere]" data-test="question-component">
                {@subject.publisher}.{@subject.name}
              </dd>
              <dt class="text-gray-400">Waits until</dt>
              <dd>
                <time
                  datetime={DateTime.to_iso8601(@subject.deadline)}
                  data-local="clock"
                  data-test="question-deadline"
                  class="whitespace-nowrap"
                >
                  {DateTime.to_iso8601(@subject.deadline)}
                </time>
              </dd>
            </dl>
          </div>
        </details>
        <%!-- How long it still waits, which the layer's script counts down
          each second; plain text, read once where a screen reader reaches
          it, never announced as it changes. --%>
        <time
          datetime={DateTime.to_iso8601(@subject.deadline)}
          data-countdown
          data-test="question-countdown"
          class="absolute right-0 top-0 py-2 text-xs tabular-nums text-gray-400"
        ></time>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :prompt, :map, required: true
  attr :offered, :list, required: true
  attr :myself, :any, required: true
  attr :button_class, :any, required: true

  @doc """
  The choices `offered` names (`offered/1`, as the layer draws them), each
  sending `question_answer` with its name, under the question "Allow
  this?": the group for the caller that started the run, named for that
  caller, and the group for everyone, each a group named by its heading,
  so the two "Always" are told apart by their group.
  """
  def choices(assigns) do
    assigns =
      assign(assigns,
        row: Enum.filter(assigns.offered, &(&1 != @any_caller)),
        any_caller: @any_caller in assigns.offered
      )

    ~H"""
    <div class="space-y-3" data-test="question-choices">
      <p class="text-sm font-medium text-gray-100" data-test="question-ask">Allow this?</p>

      <fieldset class="min-w-0 border-0 p-0" data-test="question-caller-row">
        <legend class="mb-2 text-sm text-gray-300 [overflow-wrap:anywhere]">
          <.group_name caller={@prompt.subject.caller} />
        </legend>
        <div class="grid grid-cols-2 gap-2 sm:flex sm:flex-nowrap">
          <.option
            :for={name <- @row}
            prompt={@prompt}
            myself={@myself}
            name={name}
            class={[@button_class.(false), "min-h-11 only:col-span-2"]}
          >
            {label(name)}
          </.option>
        </div>
      </fieldset>

      <div :if={@any_caller} class="border-t border-gray-700 pt-3">
        <fieldset class="min-w-0 border-0 p-0" data-test="question-any-caller">
          <legend class="mb-2 text-sm text-gray-300">For everyone</legend>
          <div class="flex flex-wrap items-center gap-3">
            <.option
              prompt={@prompt}
              myself={@myself}
              name="allow_always_any_caller"
              class={[@button_class.(false), "min-h-11"]}
              describedby={"#{@id}-question-passkey"}
            >
              Always
            </.option>
            <span id={"#{@id}-question-passkey"} class="text-xs text-gray-400">
              asks for your passkey
            </span>
          </div>
        </fieldset>
      </div>
    </div>
    """
  end

  attr :caller, :string, required: true

  # The caller's group's name: "For you", or "For" and the caller's name in
  # italics, as the sentence draws it.
  defp group_name(assigns) do
    {name, you} =
      case name(assigns.caller) do
        :you -> {nil, "you"}
        {:named, name} -> {name, nil}
        {:words, words} -> {words, nil}
      end

    assigns = assign(assigns, name: name, you: you)

    ~H"""
    For {@you}<em :if={@name} class="italic" data-test="question-group-caller">{@name}</em>
    """
  end

  defp label("deny_always_this_caller"), do: "Never"
  defp label("allow_once"), do: "Just once"
  defp label("allow_hour_this_caller"), do: "For an hour"
  defp label("allow_always_this_caller"), do: "Always"

  attr :prompt, :map, required: true
  attr :myself, :any, required: true
  attr :name, :string, required: true
  attr :class, :any, required: true
  attr :describedby, :string, default: nil
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
      aria-describedby={@describedby}
      class={@class}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end
end
