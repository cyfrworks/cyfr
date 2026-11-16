# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.PageCalls do
  @moduledoc """
  A page Aqua put into its browser calls CYFR as a public page calls it
  (`cyfr.invoke`, `cyfr.action`), and each call is Aqua's own call in the
  thread whose window holds the page. `Opus.Browser` announces it on the
  global `Cyfr.Bus.page_calls/0` (`Cyfr.Bus.PageCall`), holds the paused
  request and decides nothing; this process hears it and hands it to that
  thread's runner, and the runner hands the answer back through
  `Opus.Browser.answer/5`.

  ## What a call is held to

  Its body is read by the wire's own decoder
  (`Prima.TinctureWire.decode_request/2`); the thread is the window's,
  and the `public` names the body carries decide nothing. A tincture
  version's page calls only what its manifest declares, as the endpoint
  holds a frame's call in Prism: a component among its static
  dependencies and an action among its actions, anything else refused
  as undeclared (`Prima.Refusal.undeclared/1`) before a step is recorded.
  A plain page has no manifest and so no declaration. Calls are charged
  by the limiter a frame's are, with a frame's two settings, under a key
  of the thread; one over it is refused `rate_limited`.

  ## A call as a step

  A component call is the launch a model's `execution.run` of it is, and
  an action the model's call of that action: the same binding, decided
  by the same policy and dispatched by the same code (`Aqua.Loop`). The
  host proposes it (`proposal/3`) as a step of purpose `page`, with its
  call in a `page_call` row and its answer in a `page_result` row, which
  no model's request or compaction carries. It counts the page as outside
  material, since a page may hold anything it fetched. Its result row is
  the wire's answer (`answer/3`).

  ## Who holds a call

  This process holds it from the moment it is heard until its runner has
  it (`Opus.Browser.held/4`), so a call this process or that runner dies
  holding is answered `unavailable` and never left waiting. The browser's
  holder answers who it is, and the runner monitors it: a call whose
  browser is gone, however it went, ends as one whose request ended. A
  call the browser no longer holds when it is heard is passed over.
  """

  use GenServer

  alias Aqua.Loop.Binding
  alias Cyfr.Bus.PageCall
  alias Prima.TinctureWire

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.page_calls())
    {:ok, %{}}
  end

  @impl true
  def handle_info(%PageCall{kind: :call} = call, state) do
    take(call)
    {:noreply, state}
  end

  def handle_info(%PageCall{kind: :ended} = ended, state) do
    Aqua.Runner.page_call_ended(ended.thread_id, ended.athanor_id, ended.request)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Prima.LoggerContext.unexpected(__MODULE__, message)
    {:noreply, state}
  end

  defp take(%PageCall{} = call) do
    with {:ok, browser} <- Opus.Browser.held(call.athanor_id, call.user_id, call.request, self()),
         {:ok, kind, request} <- decode(call),
         :ok <- declared(call, kind, request),
         :ok <- charge(call) do
      taken = call_of(call, kind, request, browser)

      case Aqua.Runner.page_call(call.thread_id, call.athanor_id, taken) do
        {:ok, runner} -> Opus.Browser.held(call.athanor_id, call.user_id, call.request, runner)
        {:error, reason} -> refuse(call, Sanctum.Refusals.classify(reason))
      end
    else
      :gone -> :gone
      {:error, %Prima.Refusal{} = refusal} -> refuse(call, refusal)
    end
  end

  defp decode(%PageCall{op: op, body: body}) when op in ["invoke", "action"] do
    kind = String.to_existing_atom(op)

    with {:ok, decoded} <- json(body),
         {:ok, request} <- TinctureWire.decode_request(kind, decoded) do
      {:ok, kind, request}
    else
      {:error, sentence} -> {:error, invalid(sentence)}
    end
  end

  defp decode(%PageCall{}), do: {:error, invalid("the call names no request kind")}

  defp json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, "the body is not JSON"}
    end
  end

  defp json(_body), do: {:error, "the body is not JSON"}

  defp invalid(sentence),
    do: %Prima.Refusal{class: :invalid_argument, reason: :invalid_request, message: sentence}

  # A tincture's page is held to the version it put; a plain page to
  # nothing.
  defp declared(%PageCall{put: %{tincture: reference}} = call, kind, request)
       when is_binary(reference) do
    ctx = context(call.athanor_id)

    with {:ok, %{"manifest" => manifest}} <- Compendium.inspect_component(ctx, reference),
         manifest = manifest(manifest),
         {:ok, declaration} <- Compendium.tincture_declaration(manifest) do
      declares(kind, request, manifest, declaration)
    else
      _unread -> {:error, Prima.Refusal.undeclared("its declaration does not read")}
    end
  end

  defp declared(%PageCall{}, _kind, _request), do: :ok

  defp declares(:invoke, %{ref: ref}, manifest, _declaration) do
    if Compendium.tincture_invokes?(manifest, ref),
      do: :ok,
      else: {:error, Prima.Refusal.undeclared(:component)}
  end

  defp declares(:action, %{operation: operation}, _manifest, declaration) do
    if operation in declaration.actions,
      do: :ok,
      else: {:error, Prima.Refusal.undeclared(:action)}
  end

  defp manifest(manifest) when is_map(manifest), do: manifest

  defp manifest(manifest) when is_binary(manifest) do
    case Jason.decode(manifest) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp manifest(_manifest), do: %{}

  defp charge(%PageCall{thread_id: thread_id}) do
    {:ok, max} = Arca.PlatformSettings.effective("frame_invocation_max")
    {:ok, window} = Arca.PlatformSettings.effective("frame_invocation_window_ms")

    case Prima.RateLimiter.check({:page_call, thread_id}, max, window) do
      :ok -> :ok
      {:deny, retry_after} -> {:error, Prima.Refusal.classify({:rate_limited, retry_after})}
    end
  end

  # The call a model would make for it: a component's run, or the action.
  defp call_of(call, :invoke, %{ref: ref, operation: operation, args: args}, browser) do
    named(call, browser, "execution.run", %{
      "reference" => ref,
      "input" => %{"operation" => operation, "params" => args}
    })
  end

  defp call_of(call, :action, %{operation: operation, args: args}, browser),
    do: named(call, browser, operation, args)

  defp named(%PageCall{} = call, browser, name, arguments) do
    %{
      request: call.request,
      name: name,
      arguments: arguments,
      user_id: call.user_id,
      put_turn_id: call.put.turn_id,
      browser: browser
    }
  end

  defp refuse(%PageCall{} = call, %Prima.Refusal{} = refusal) do
    {status, body} = refusal_answer(refusal)
    Opus.Browser.answer(call.athanor_id, call.user_id, call.request, status, body)
  end

  defp context(athanor_id),
    do: Sanctum.Context.internal(user_id: "_threads", athanor_id: athanor_id, scope: :athanor)

  # ---------------------------------------------------------------------------
  # The step and its answer
  # ---------------------------------------------------------------------------

  @doc """
  The row a page's call is carried in: its request, its name and
  arguments as a model's call names them, what they bind to, the
  browser's person, whom its answer goes back to, and the turn that put
  the page.
  """
  @spec row(map()) :: map()
  def row(%{request: request, name: name, arguments: arguments, user_id: user_id} = call) do
    recorded = Aqua.Loop.recorded(name, arguments, bind(request, name, arguments))

    %{
      "tool_call_id" => request,
      "name" => name,
      "arguments" => arguments,
      "tool" => recorded.tool,
      "action" => recorded.action,
      "kind" => recorded.kind,
      "user_id" => user_id,
      "put_turn" => call[:put_turn_id]
    }
  end

  @doc """
  The step a page's call is proposed as in `turn`, from its row's payload
  (`row/1`): with the row to write, or, with `message_id:`, the row the
  turn opened on.
  """
  @spec proposal(map(), map(), keyword()) :: map()
  def proposal(%{id: turn_id}, %{"tool_call_id" => request, "name" => name} = payload, opts \\ []) do
    arguments = payload["arguments"] || %{}
    recorded = Aqua.Loop.recorded(name, arguments, bind(request, name, arguments))

    step = %{
      kind: recorded.step_kind,
      purpose: "page",
      tool: recorded.tool,
      action: recorded.action,
      recovery: recorded.recovery,
      child_execution_id: recorded.child_execution_id,
      proposal_digest: recorded.proposal_digest,
      idempotency_key: "page_call:#{turn_id}:#{request}",
      sources: [Prima.Source.outside("browser")]
    }

    # A turn opened on the call, which asks no model, starts with the
    # sources of the turn that put the page, whose words the page holds.
    case Keyword.get(opts, :message_id) do
      nil ->
        Map.put(step, :call, %{
          kind: "page_call",
          content: name,
          client_id: request,
          payload: payload
        })

      message_id ->
        step
        |> Map.put(:message_id, message_id)
        |> Map.put(:sources_from, List.wrap(payload["put_turn"]))
    end
  end

  defp bind(request, name, arguments), do: Binding.resolve(name, arguments, tool_call_id: request)

  @doc """
  The wire's answer to a page's call, as its step closed: `outcome` and
  what it ran to (`result`), with the sentence the step closed with
  (`text`). Answers the HTTP status and the body.
  """
  @spec answer(String.t(), term(), String.t()) :: {pos_integer(), String.t()}
  def answer("ok", {:ok, value}, text), do: {200, encode(TinctureWire.result(value), text)}
  def answer("ok", _result, text), do: {200, Jason.encode!(TinctureWire.result(text))}

  def answer(outcome, result, text), do: refusal_answer(refusal(outcome, result, text))

  @doc """
  What a hand answered, as a page is handed it: the data of its
  contract's envelope, as the gate hands an endpoint's call of it, where
  the model reads it as text (`Aqua.Loop.Binding.render/2`).
  """
  @spec data(term()) :: term()
  def data(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> data(decoded)
      {:error, _} -> output
    end
  end

  def data(%{"data" => data}), do: data
  def data(output), do: output

  @doc """
  The answer a page's result row holds (`answer/3`), or, for a row a
  call was closed with where no answer was made (a step skipped, or
  withdrawn with its card), the refusal its sentence says.
  """
  @spec answered(map()) :: {pos_integer(), String.t()}
  def answered(%{content: body, payload: %{"status" => status}}) when is_integer(status),
    do: {status, body}

  def answered(%{content: sentence, payload: payload}) do
    class = if payload["skipped"] == true, do: :cancelled, else: :forbidden
    refusal_answer(%Prima.Refusal{class: class, reason: :page_call, message: sentence || ""})
  end

  defp refusal(_outcome, {:error, %Prima.Refusal{} = refusal}, _text), do: refusal

  # A launch that did not run (`Aqua.Loop`'s close of one) answers its own
  # refusal: a component not granted is `consent_required`, as the
  # endpoint answers a frame's call of one.
  defp refusal(_outcome, {:error, {:launch, reason}}, _text),
    do: Sanctum.Refusals.classify(reason)

  defp refusal(outcome, _result, text),
    do: %Prima.Refusal{class: class_of(outcome), reason: :page_call, message: text}

  defp class_of("denied"), do: :forbidden
  defp class_of("skipped"), do: :cancelled
  defp class_of("uncertain"), do: :uncertain
  defp class_of(_error), do: :internal

  defp refusal_answer(%Prima.Refusal{} = refusal),
    do: {Prima.Refusal.http_status(refusal.class), Jason.encode!(TinctureWire.refusal(refusal))}

  # A value the wire cannot carry is answered as the sentence the step
  # closed with.
  defp encode(answer, text) do
    case Jason.encode(answer) do
      {:ok, body} -> body
      {:error, _} -> Jason.encode!(TinctureWire.result(text))
    end
  end
end
