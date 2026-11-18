# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Question do
  @moduledoc """
  The `question` tool: a component's questions to its person before an
  action, and the person's answers that stand, in the athanor in focus
  (`Sanctum.Questions`).

    * `pending` answers the person's open questions, or with a `ref` the
      one it names, each with its preview (`Prima.Question.Preview`): what
      a surface draws, read under the reader's own session.
    * `answer` answers one (`Prima.Question.Answer`'s JSON). An answer
      that lasts stands as a permission, written with it.
    * `answers` lists the person's permissions for one component, and
      the callers its questions to them have had.
    * `set` sets a permission before any question (`Prima.Question.Standing`'s
      JSON), for an action the component's newest installed version
      declares.
    * `forget` removes one.

  Every action is the person's own, on the external plane, through an
  interactive surface (`consent: :interactive`): a session or a paired
  device, never a key, a frame or a running chain, so a component's run
  cannot answer its own question. An allow that is always and for any
  caller needs a fresh confirmation, whose card reads the operation's
  description; every other answer needs the session.

  A person's clients hear each question opened, answered, expired or
  withdrawn on Host's stream `prompt.changes`, as kind `question`, its
  `ref`, the fact and its `expires_at`, never the summary or the
  operation, which they read through `pending`.
  """

  alias Prima.{Arg, Operation}
  alias Prima.Question.{Answer, Preview, Standing}

  @doc false
  def definition do
    Operation.tool(
      [
        Operation.new(
          "question",
          "pending",
          "List the questions components are waiting on you to answer",
          [
            Arg.new("ref", :string,
              description: "pending: one question's ref, to read that question alone"
            )
          ],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "question",
          "answer",
          "Answer a component that asks before an action",
          [
            ref(),
            Arg.new("answer", :json,
              required: true,
              description:
                "answer: {effect: allow or deny, lasts: once, always or {until: a UTC time}, " <>
                  "covers: any_caller or this_caller}"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "question",
          "answers",
          "List your permissions for a component's actions",
          [publisher(), name()],
          kind: :read,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "question",
          "set",
          "Let a component do an action without asking you, or never",
          [
            publisher(),
            name(),
            Arg.new("action_name", :string,
              required: true,
              description: "set: the action, as the component's manifest names it under asks"
            ),
            Arg.new("standing", :json,
              required: true,
              description:
                "set: {effect: allow or deny, until: null or a UTC time, caller: any or a caller}"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "question",
          "forget",
          "Remove a permission you gave a component",
          [
            Arg.new("id", :string,
              required: true,
              description: "forget: the permission's id, as question.answers lists it"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "What components ask you before an action they cannot undo: answer a waiting " <>
          "question, and list, set or remove the permissions your answers leave.",
      title: "Component questions"
    )
  end

  defp ref,
    do:
      Arg.new("ref", :string,
        required: true,
        description:
          "The question's ref, as question.pending and the prompt.changes stream name it"
      )

  defp publisher,
    do: Arg.new("publisher", :string, required: true, description: "The component's publisher")

  defp name,
    do: Arg.new("name", :string, required: true, description: "The component's name")

  def handle(ctx, %{"action" => "pending"} = args) do
    with {:ok, questions} <- Sanctum.Questions.pending(ctx, args["ref"]) do
      {:ok,
       %{
         questions: Enum.map(questions, &%{ref: &1.ref, preview: Preview.to_json(&1.preview)})
       }}
    end
  end

  def handle(ctx, %{"action" => "answer", "ref" => ref, "answer" => answer})
      when is_binary(ref) do
    with {:ok, answer} <- Answer.decode(answer),
         {:ok, row} <- Sanctum.Questions.answer(ctx, ref, answer) do
      {:ok, %{ref: row.ref, state: row.state}}
    end
  end

  def handle(ctx, %{"action" => "answers", "publisher" => publisher, "name" => name})
      when is_binary(publisher) and is_binary(name) do
    with {:ok, %{answers: answers, callers: callers}} <-
           Sanctum.Questions.answers(ctx, publisher, name) do
      {:ok, %{answers: Enum.map(answers, &standing/1), callers: callers}}
    end
  end

  def handle(ctx, %{
        "action" => "set",
        "publisher" => publisher,
        "name" => name,
        "action_name" => action,
        "standing" => standing
      })
      when is_binary(publisher) and is_binary(name) and is_binary(action) do
    with {:ok, standing} <- Standing.decode(standing),
         {:ok, row} <- Sanctum.Questions.set(ctx, publisher, name, action, standing) do
      {:ok, standing(row)}
    end
  end

  def handle(ctx, %{"action" => "forget", "id" => id}) when is_binary(id) do
    with :ok <- Sanctum.Questions.forget(ctx, id), do: {:ok, %{}}
  end

  def handle(_ctx, %{"action" => action}) when action in ~w(answer answers set forget),
    do: {:error, {:invalid_argument, "Missing required argument for question.#{action}"}}

  def handle(_ctx, %{"action" => action}), do: {:error, {:unknown_action, "question.#{action}"}}
  def handle(_ctx, _args), do: {:error, :action_missing}

  # A permission as its person reads it.
  defp standing(row) do
    %{
      id: row.id,
      publisher: row.publisher,
      name: row.name,
      action: row.action,
      declaration_digest: row.declaration_digest,
      caller: row.caller,
      effect: row.effect,
      until: row.until,
      answered_at: row.answered_at,
      question_ref: row.question_ref
    }
  end
end
