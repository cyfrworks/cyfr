# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prism.CanvasValidation do
  @moduledoc """
  A candidate canvas version trialled on the glass that is to show it,
  before anything of it opens live. Functions over the frames the shell
  holds (`Prism.Frames`), with no process of its own, so the shell's end
  ends a validation too.

    * **Whether to validate** (`needed?/2`): when a glass is to show a
      canvas, its newest installed version is validated only when it is
      not the working version, not the kept one and not the recorded
      failure. A restore therefore holds until a newer version is written.
    * **The trial** (`open/4`): the version opens in a hidden, inert frame
      under a validation credential
      (`Sanctum.TinctureAuth.mint_validation_credential/5`) and the
      version's asset credential, keyed `{:validation, canvas_id}`, through
      the frames' one canvas builder, whose handshake names the mode
      `validation`. Its deadline, 10 seconds, is armed as it opens, as
      `{:validation_deadline, frame_id}` to the shell, and covers the
      page's load until it reports `ready`.
    * **The outcome** (`conclude/5`): the page's `ready` is `ready`; the
      deadline is `not_ready`; a failure at any stage, or the frame's
      death as its bridge reports it, is `died`. Every outcome first
      forgets the frame, so the shell attributes nothing more to it and
      the next render removes it, then calls `canvas.activate` once,
      through the shell's tool call under the shell's context, whose
      consume spends the credential, and then revokes the credential.
      Revocation is idempotent, so the credential ends revoked on every
      path, a refused activation included. Only `ready` activates; the
      gate's control-plane fence refuses a member that lost its slot
      (`not_owner`), which activates and records nothing.
    * **A teardown with no call** (`cancel/3`): a switch, a layout change
      that drops the canvas, or safe mode while it is trialled revokes the
      credential, then forgets the frame; nothing is activated or
      recorded, and the next show validates again.

  What the shell does next is the answer's (`next/1`).
  """

  alias Prism.Frames
  alias Sanctum.Context

  @deadline_ms 10_000

  @typedoc "What ended a validation."
  @type event :: :ready | :deadline | :failed | :gone

  @typedoc """
  What the shell does once activation answered:

    * `{:show_working, :else_safe_mode}` — read the listing and the
      versions again and validate a newer version written meanwhile that
      needs validating, once per version; otherwise open the working
      version live, or enter safe mode `not_validated` when there is none;
    * `{:show_working, {:else_refuse, refusal}}` — the same, with the
      canvas's refusal, as a refused frame shows it, in place of safe mode;
    * `:ask_grant` — the grant prompt for the canvas's tincture, and a
      new validation once it is confirmed;
    * `{:refuse, refusal}` — nothing more: the canvas shows its refusal,
      never safe mode, since the version did not fail.
  """
  @type next ::
          {:show_working, :else_safe_mode | {:else_refuse, Frames.refusal()}}
          | :ask_grant
          | {:refuse, Frames.refusal()}

  @typedoc "The shell's tool call: a `tool/action` name and its arguments, under its context."
  @type call :: (String.t(), map() -> {:ok, term()} | {:error, term()})

  @doc """
  Whether `newest`, a canvas's newest installed version, is validated
  before the canvas opens: it is not `document`'s working version, not its
  kept version and not its recorded failure.
  """
  @spec needed?(Arca.CanvasVersions.document(), String.t()) :: boolean()
  def needed?(%{working: working, kept: kept, failed: failed}, newest) when is_binary(newest),
    do: newest not in [working, kept, failed_version(failed)]

  defp failed_version(%{version: version}), do: version
  defp failed_version(nil), do: nil

  @doc """
  Open canvas `canvas_id`'s validation frame for `card`, the candidate
  version, and arm its deadline. A frame refused at its open holds no
  credential and arms nothing.
  """
  @spec open(Context.t(), Frames.t(), String.t(), Frames.card()) :: Frames.t()
  def open(%Context{} = ctx, %Frames{} = frames, canvas_id, card) do
    frames =
      Frames.open_validation(
        ctx,
        frames,
        canvas_id,
        card,
        &Sanctum.TinctureAuth.mint_validation_credential/5
      )

    case Frames.get(frames, {:validation, canvas_id}) do
      %{state: :live, id: frame_id} ->
        Process.send_after(self(), {:validation_deadline, frame_id}, @deadline_ms)

      _refused ->
        :ok
    end

    frames
  end

  @doc "The outcome `event` reports to `canvas.activate`."
  @spec outcome(event()) :: String.t()
  def outcome(:ready), do: "ready"
  def outcome(:deadline), do: "not_ready"
  def outcome(event) when event in [:failed, :gone], do: "died"

  @doc """
  The canvas whose validation frame `frame_id` is, while `frames` holds
  it: a deadline or a death for a frame no longer held names none.
  """
  @spec canvas_of(Frames.t(), String.t()) :: {:ok, String.t()} | :none
  def canvas_of(%Frames{} = frames, frame_id) do
    case Enum.find(Frames.list(frames), &match?(%{key: {:validation, _}, id: ^frame_id}, &1)) do
      %{key: {:validation, canvas_id}} -> {:ok, canvas_id}
      nil -> :none
    end
  end

  @doc """
  End canvas `canvas_id`'s validation for `event`: forget its frame, call
  `canvas.activate` once through `call` with the version, the frame and
  the outcome, then revoke the frame's credential. Answers the frames
  without it and what the shell does next (`next/1`), or `:none` with the
  frames as they are when no validation of it is held.
  """
  @spec conclude(Context.t(), Frames.t(), String.t(), event(), call()) ::
          {Frames.t(), next() | :none}
  def conclude(%Context{} = ctx, %Frames{} = frames, canvas_id, event, call)
      when is_function(call, 2) do
    case Frames.get(frames, {:validation, canvas_id}) do
      nil ->
        {frames, :none}

      %{id: frame_id, credential_id: credential, reference: %{name: name, version: version}} ->
        # Forgotten first, so nothing more of it is attributed and the next
        # render removes it; its credential stays live for the activation's
        # consume, and is revoked whatever the activation answered.
        frames = frames |> Frames.forget({:validation, canvas_id}) |> Frames.visibility()

        answer =
          call.("canvas/activate", %{
            "canvas" => name,
            "version" => version,
            "frame" => frame_id,
            "outcome" => outcome(event)
          })

        {Frames.revoke(ctx, frames, credential), next(answer)}
    end
  end

  @doc """
  Tear canvas `canvas_id`'s validation frame down, its credential
  revoked, and call nothing: nothing is activated or recorded.
  """
  @spec cancel(Context.t(), Frames.t(), String.t()) :: Frames.t()
  def cancel(%Context{} = ctx, %Frames{} = frames, canvas_id) do
    case Frames.get(frames, {:validation, canvas_id}) do
      nil -> frames
      _held -> Frames.discard(ctx, frames, {:validation, canvas_id})
    end
  end

  @doc """
  What the shell does once `canvas.activate` answered `answer`: an
  activation, or the success for the version already working, a recorded
  `not_ready` or `died`, and a conflict read the listing and the versions
  again and open the working version, unless a newer version written
  meanwhile needs validating, which the shell validates in its turn, once
  per version and never the one just tried; any of them is safe mode
  `not_validated` without a working version. `consent_required` asks for
  the grant. `not_owner` is the canvas's refusal and nothing more.
  Anything else is the same, with the canvas's refusal in place of safe
  mode.
  """
  @spec next({:ok, term()} | {:error, term()}) :: next()
  def next({:ok, _activation}), do: {:show_working, :else_safe_mode}

  def next({:error, reason}) do
    case Prima.Refusal.classify(reason).class do
      :conflict -> {:show_working, :else_safe_mode}
      :consent_required -> :ask_grant
      :not_owner -> {:refuse, Frames.refusal(:not_owner)}
      :unavailable -> {:show_working, {:else_refuse, Frames.refusal(:unavailable)}}
      :not_found -> {:show_working, {:else_refuse, Frames.refusal(:unregistered)}}
      _forbidden -> {:show_working, {:else_refuse, Frames.refusal(reason)}}
    end
  end
end
