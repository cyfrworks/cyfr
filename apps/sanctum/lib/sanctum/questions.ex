# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Questions do
  @moduledoc """
  A component's questions to its person, and the answers that stand.

  A catalyst asks before an action its manifest declares (`asks`,
  `Prima.Manifest.Asks`), and waits. This module decides the ask, owns
  the answer door and the standing answers, and announces what moves; the
  rows are `Arca.Questions`'. The host's side of the call
  (`Opus.Host.Question`) checks the attempt is live and paces the asks;
  nothing here bounds them.

  ## An ask

  `ask/4` decides in this order, and the first that answers ends it:

    1. The request is well formed: a positive ask number, the action a
       name, the summary one line of at most #{200} characters, with no
       control or format character and no line or paragraph separator, so
       nothing in it breaks a line; the operation any text but a control
       or format character, keeping its line feeds, carriage returns and
       tabs and its line and paragraph separators (U+2028, U+2029), since
       it is shown whole with its lines; the run's caller a caller's text.
       Otherwise `none(invalid)`.
    2. The run acts as a person: the one its root acts as, never a
       webhook's identity or a public tincture's anonymous one. Otherwise
       `none(unattended)`: nobody can be asked and no permission is theirs.
    3. The ask was already decided: its row, keyed by the attempt and the
       ask's number, answers what it holds, whatever changed since; the
       same number with other content is `none(invalid)`.
    4. The action is declared by the running release's manifest: the
       component's row at the run's version, with the run's release
       digest. Otherwise `none(invalid)`.

  An ask that passes is admitted: decided by the first of a permission
  that covers it (the row is written answered, naming it), a root whose
  origin is not `interactive` (`none(unattended)`), or else the question
  opens and is announced. The row is inserted with its decision in a
  transaction that checks the attempt is current and the run open
  (`Arca.Questions.admit/2`); a run that ended leaves no row. A refusal at
  1, 2 or 4 leaves none, and a store that cannot answer is
  `none(unavailable)`, with nothing recorded.

  ## Permissions

  A standing answer covers an ask with the same athanor, person,
  component and action, a deadline still to come, a caller that is any or
  the run's own, and, for an allow, the digest of the declaration it was
  given under equal to the running release's: a reworded title asks
  again, and a deny stays. The one for this caller beats the one for any
  caller; an unknown caller is covered only by an answer for any. A
  person removes one (`forget/2`); a removed catalyst's go with it
  (`component_removed/3`).

  ## The answer door

  `answer/3`, `set/5` and `forget/2` are the person's, through their own
  session or a paired device of theirs (`Sanctum.Pairing.can_confirm?/1`),
  never a key, a frame or a running chain, and reach only the context's
  own person's rows in its own athanor. An answer counts only while the
  question is open, its deadline to come, its attempt current and its run
  open, read under the row's lock, so of two at once one wins. An allow
  that lasts always and covers any caller is the widest answer there is:
  its write is decided under `:question_always_any`, which needs a fresh
  confirmation (`Sanctum.Pairing`), binding the answer as written and the
  declaration's digest; the proof is checked first (`Authz.check/3`),
  consumed inside the write's transaction (`Authz.consume/2`) and
  announced after its commit (`Authz.consumed/1`). Every other answer
  needs the session alone.

  ## What is announced

  After the commit, and only for the write that won:
  `Sanctum.Telemetry.question/4`'s `opened` when a question opens,
  `answered` when its person answers, and `expired` or `withdrawn` when
  the write that ended its run closed it (`ended/3`). An ask a permission
  answered, and one nobody could be asked, announce nothing.
  """

  alias Arca.Questions, as: Store
  alias Prima.Manifest.Asks
  alias Prima.Question.{Answer, Caller, Preview, Standing}
  alias Sanctum.Consent.{Authz, Components}
  alias Sanctum.{Context, Pairing, Telemetry}

  require Components

  @summary_max 200
  @wait_ceiling_ms 20_000
  @poll_ms 500
  @digest ~r/\A[0-9a-f]{64}\z/
  @release_digest ~r/\Asha256:[0-9a-f]{64}\z/
  @action ~r/\A[a-z][a-z0-9_]{0,63}\z/
  # A control or format character, or a line or paragraph separator:
  # anything that is not one line of text, which a summary never holds.
  @not_one_line ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u
  # A control or format character but a line feed, a carriage return and a
  # tab; an operation keeps those, and the line and paragraph separators.
  @unprintable_but_lines ~r/[^\P{Cc}\n\r\t]|\p{Cf}/u

  @typedoc "What the asking component is told."
  @type answer :: :allowed | :denied | {:none, :unattended | :invalid | :unavailable}

  @typedoc """
  The run that asks: its execution, attempt and root, its component's
  versioned reference and release digest, its caller's text
  (`Prima.Question.Caller`) and its deadline.
  """
  @type run :: %{
          execution_id: String.t(),
          attempt_id: String.t(),
          root_execution_id: String.t(),
          component_ref: String.t(),
          release_digest: String.t(),
          caller: String.t(),
          deadline: DateTime.t()
        }

  @typedoc """
  The ask: the action, the summary and the operation as masked of the
  run's credentials, whether anything was masked, and the request's
  digest, taken before masking.
  """
  @type request :: %{
          action: String.t(),
          summary: String.t(),
          operation: String.t(),
          masked: boolean(),
          request_digest: String.t()
        }

  # ---------------------------------------------------------------------------
  # The asking run's side
  # ---------------------------------------------------------------------------

  @doc """
  The ask `(attempt_id, ask_no)` already admitted: `{:answer, answer}` for
  a decided one, `{:pending, ref}` for one still open, `{:error,
  :changed}` when its row holds another request's digest, and `:none`
  when it was never admitted. A store that cannot answer is
  `{:answer, {:none, :unavailable}}`.
  """
  @spec find(Context.t(), String.t(), pos_integer(), String.t()) ::
          {:answer, answer()} | {:pending, String.t()} | {:error, :changed} | :none
  def find(%Context{} = ctx, attempt_id, ask_no, request_digest)
      when is_binary(attempt_id) and is_integer(ask_no) and is_binary(request_digest) do
    if person?(ctx) do
      case Store.by_key(Context.actor(ctx), attempt_id, ask_no) do
        {:ok, %{request_digest: ^request_digest} = row} -> held(row)
        {:ok, _another} -> {:error, :changed}
        {:error, :not_found} -> :none
        {:error, _unanswered} -> unavailable()
      end
    else
      :none
    end
  end

  @doc """
  Decide the ask `ask_no` of `run` (`t:run/0`) for `request`
  (`t:request/0`), as the module doc orders it, the person and the root's
  origin being the context's: `{:answer, answer}`, or `{:pending, ref}`
  when the question opened.
  """
  @spec ask(Context.t(), run(), pos_integer(), request()) ::
          {:answer, answer()} | {:pending, String.t()}
  def ask(%Context{} = ctx, run, ask_no, request) do
    with :ok <- well_formed(run, ask_no, request),
         :ok <- if(person?(ctx), do: :ok, else: {:error, :unattended}),
         :none <- find(ctx, run.attempt_id, ask_no, request.request_digest),
         {:ok, component} <- component(run.component_ref),
         {:ok, declaration} <- declared(ctx, component, run, request.action) do
      admit(ctx, run, ask_no, request, component, declaration)
    else
      {:answer, _answer} = held -> held
      {:pending, _ref} = held -> held
      {:error, :changed} -> invalid()
      {:error, :invalid} -> invalid()
      {:error, :unattended} -> {:answer, {:none, :unattended}}
      {:error, :unavailable} -> unavailable()
    end
  end

  @doc """
  Wait up to `max_wait_ms` (at most #{@wait_ceiling_ms}) for the ask
  `(attempt_id, ask_no)` to be decided, reading its row again every
  #{@poll_ms} milliseconds, so an answer given on another member is seen
  without the bus: `{:answer, answer}`, or `:pending` when it still
  waits. An ask never admitted is `none(invalid)`, and a store that
  cannot answer `none(unavailable)`.
  """
  @spec wait(Context.t(), String.t(), pos_integer(), non_neg_integer()) ::
          {:answer, answer()} | :pending
  def wait(%Context{} = ctx, attempt_id, ask_no, max_wait_ms)
      when is_binary(attempt_id) and is_integer(ask_no) and is_integer(max_wait_ms) and
             max_wait_ms >= 0 do
    until = System.monotonic_time(:millisecond) + min(max_wait_ms, @wait_ceiling_ms)
    poll(ctx, attempt_id, ask_no, until)
  end

  defp poll(ctx, attempt_id, ask_no, until) do
    answer =
      if person?(ctx) do
        case Store.by_key(Context.actor(ctx), attempt_id, ask_no) do
          {:ok, row} -> held(row)
          {:error, :not_found} -> invalid()
          {:error, _unanswered} -> unavailable()
        end
      else
        invalid()
      end

    left = until - System.monotonic_time(:millisecond)

    case answer do
      {:pending, _ref} when left > 0 ->
        Process.sleep(min(@poll_ms, left))
        poll(ctx, attempt_id, ask_no, until)

      {:pending, _ref} ->
        :pending

      decided ->
        decided
    end
  end

  @doc """
  Announce the questions a run-ending write closed (`closed`, each its
  `ref`, `user_id` and `deadline`, as `Arca.Questions.close_run!/2`
  answers them), after that write committed: `:expired` when the run's
  deadline ended it, `:withdrawn` when it ended any other way. It takes
  the athanor's id, since a lapse and a cascade hold a row and no
  context.
  """
  @spec ended(String.t(), [Store.closed()], :expired | :withdrawn) :: :ok
  def ended(athanor_id, closed, stage)
      when is_binary(athanor_id) and athanor_id != "" and is_list(closed) and
             stage in [:expired, :withdrawn] do
    for %{ref: ref, user_id: user_id, deadline: deadline} <- closed do
      Telemetry.question(stage, athanor_id, user_id, %{ref: ref, expires_at: deadline})
    end

    :ok
  end

  @doc """
  Delete every standing answer of the catalyst `publisher` and `name` in
  the context's athanor, whoever gave it: its last version left the
  athanor (`Compendium.Cascade`). `{:ok, count}`.
  """
  @spec component_removed(Context.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def component_removed(%Context{} = ctx, publisher, name)
      when is_binary(publisher) and is_binary(name),
      do: Store.delete_component(Context.actor(ctx), publisher, name)

  # ---------------------------------------------------------------------------
  # The person's side
  # ---------------------------------------------------------------------------

  @doc """
  The context's person's open questions in its athanor, soonest deadline
  first, each `%{ref, preview}` (`Prima.Question.Preview`); with `ref`,
  the one it names, if it is theirs and open.
  """
  @spec pending(Context.t(), String.t() | nil) ::
          {:ok, [%{ref: String.t(), preview: Preview.t()}]} | {:error, term()}
  def pending(%Context{} = ctx, ref \\ nil) when is_nil(ref) or is_binary(ref) do
    with :ok <- answerer(ctx),
         {:ok, rows} <- read(Store.list_open(Context.actor(ctx), ctx.user_id)) do
      {:ok,
       for(row <- rows, is_nil(ref) or row.ref == ref, do: %{ref: row.ref, preview: preview(row)})}
    else
      {:error, reason} -> refusal(reason, ref)
    end
  end

  @doc """
  Answer the context's person's open question `ref` with `answer`
  (`Prima.Question.Answer`), writing the standing answer it lasts as in
  the same transaction. `{:ok, row}`, the question as answered;
  `{:error, {:confirmation_required, _}}` when the answer needs a fresh
  confirmation not yet given; or a refusal.
  """
  @spec answer(Context.t(), String.t(), Answer.t()) :: {:ok, map()} | {:error, term()}
  def answer(%Context{} = ctx, ref, %Answer{} = answer) when is_binary(ref) do
    actor = Context.actor(ctx)

    with :ok <- answerer(ctx),
         {:ok, row} <- own(Store.get(actor, ref), ref),
         :ok <- open(row),
         {:ok, component} <- component(row.component_ref),
         {:ok, standing} <- lasting(row, component, answer) do
      change =
        if widest?(standing),
          do:
            change("question.answer", component, row.title, %{
              ref: ref,
              answer: Answer.to_json(answer),
              declaration_digest: standing.declaration_digest
            })

      confirmed(ctx, change, fn verify ->
        Store.answer(actor, ref, decision(answer.effect), standing, verify: verify)
      end)
      |> case do
        {:ok, answered} ->
          Telemetry.question(:answered, ctx.athanor_id, ctx.user_id, %{
            ref: answered.ref,
            expires_at: answered.deadline
          })

          {:ok, answered}

        {:error, reason} ->
          refusal(reason, ref)
      end
    else
      {:error, reason} -> refusal(reason, ref)
    end
  end

  @doc """
  The context's person's standing answers for the component `publisher`
  and `name`, and the callers its questions to them have had:
  `{:ok, %{answers: rows, callers: texts}}`.
  """
  @spec answers(Context.t(), String.t(), String.t()) ::
          {:ok, %{answers: [map()], callers: [String.t()]}} | {:error, term()}
  def answers(%Context{} = ctx, publisher, name) when is_binary(publisher) and is_binary(name) do
    actor = Context.actor(ctx)

    with :ok <- answerer(ctx),
         {:ok, answers} <- read(Store.standing(actor, ctx.user_id, publisher, name)),
         {:ok, callers} <- read(Store.callers(actor, ctx.user_id, publisher, name)) do
      {:ok, %{answers: answers, callers: callers}}
    else
      {:error, reason} -> refusal(reason, nil)
    end
  end

  @doc """
  Set the context's person's standing answer `standing`
  (`Prima.Question.Standing`) for the action `action` of the installed
  catalyst `publisher` and `name`, under the declaration its newest
  installed version makes, replacing the answer of the same caller. A
  caller of `unknown` is refused: it is covered only by an answer for any
  caller. `{:ok, row}`; `{:error, {:confirmation_required, _}}` for an
  allow, always, for any caller not yet confirmed; or a refusal.
  """
  @spec set(Context.t(), String.t(), String.t(), String.t(), Standing.t()) ::
          {:ok, map()} | {:error, term()}
  def set(%Context{} = ctx, publisher, name, action, %Standing{} = standing)
      when is_binary(publisher) and is_binary(name) and is_binary(action) do
    with :ok <- answerer(ctx),
         :ok <- known_caller(standing.caller),
         :ok <- to_come(standing.until),
         {:ok, title} <- installed_title(ctx, publisher, name, action) do
      row = %{
        publisher: publisher,
        name: name,
        action: action,
        declaration_digest: Asks.digest(%{name: action, title: title}),
        caller: Standing.caller_text(standing.caller),
        effect: Atom.to_string(standing.effect),
        until: standing.until
      }

      change =
        if widest?(row),
          do:
            change("question.set", %{namespace: publisher, name: name}, title, %{
              publisher: publisher,
              name: name,
              action_name: action,
              standing: Standing.to_json(standing),
              declaration_digest: row.declaration_digest
            })

      confirmed(ctx, change, &Store.put_standing(Context.actor(ctx), row, verify: &1))
      |> case do
        {:ok, stored} -> {:ok, stored}
        {:error, reason} -> refusal(reason, action)
      end
    else
      {:error, reason} -> refusal(reason, action)
    end
  end

  @doc "Remove the context's person's standing answer `id`: `:ok`, or a refusal."
  @spec forget(Context.t(), String.t()) :: :ok | {:error, term()}
  def forget(%Context{} = ctx, id) when is_binary(id) do
    case answerer(ctx) do
      :ok ->
        case Store.delete_standing(Context.actor(ctx), id) do
          :ok -> :ok
          {:error, :not_found} -> {:error, {:not_found, "permission", id}}
          {:error, _unanswered} -> {:error, :unavailable}
        end

      {:error, reason} ->
        refusal(reason, id)
    end
  end

  @doc """
  The context's person's open questions, for their attention's refresh:
  each its `ref`, `label` and `opened_at`, as the `opened` announcement
  names them.
  """
  @spec waiting(Context.t()) ::
          {:ok, [%{ref: String.t(), label: String.t(), opened_at: DateTime.t()}]}
          | {:error, :unavailable | :no_athanor}
  def waiting(%Context{user_id: user_id} = ctx) when is_binary(user_id) and user_id != "" do
    case Store.list_open(Context.actor(ctx), user_id) do
      {:ok, rows} ->
        {:ok, Enum.map(rows, &%{ref: &1.ref, label: label(&1), opened_at: &1.opened_at})}

      {:error, :no_athanor} ->
        {:error, :no_athanor}

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  def waiting(%Context{}), do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # The decision
  # ---------------------------------------------------------------------------

  defp well_formed(run, ask_no, request) do
    with %{
           execution_id: execution_id,
           attempt_id: attempt_id,
           root_execution_id: root_id,
           component_ref: component_ref,
           release_digest: release_digest,
           caller: caller,
           deadline: %DateTime{}
         } <- run,
         %{
           action: action,
           summary: summary,
           operation: operation,
           masked: masked,
           request_digest: request_digest
         } <- request,
         true <- is_integer(ask_no) and ask_no > 0,
         true <- Enum.all?([execution_id, attempt_id, root_id, component_ref], &text?/1),
         true <- text?(release_digest) and Regex.match?(@release_digest, release_digest),
         true <- text?(request_digest) and Regex.match?(@digest, request_digest),
         true <- is_boolean(masked),
         true <- text?(action) and Regex.match?(@action, action),
         true <- summary?(summary),
         true <- operation?(operation),
         {:ok, _caller} <- Caller.decode(caller) do
      :ok
    else
      _malformed -> {:error, :invalid}
    end
  end

  defp text?(value), do: is_binary(value) and value != "" and String.valid?(value)

  defp summary?(summary) do
    is_binary(summary) and String.valid?(summary) and
      length(String.codepoints(summary)) <= @summary_max and
      not Regex.match?(@not_one_line, summary)
  end

  defp operation?(operation) do
    is_binary(operation) and String.valid?(operation) and
      not Regex.match?(@unprintable_but_lines, operation)
  end

  # The run acts as a person: a person's own id, never a webhook's
  # identity or a public tincture's anonymous one, in an athanor.
  defp person?(%Context{anonymous: true}), do: false

  defp person?(%Context{user_id: user_id, athanor_id: athanor_id}),
    do: Prima.PersonId.person?(user_id) and is_binary(athanor_id) and athanor_id != ""

  defp component(component_ref) do
    case Prima.ComponentRef.parse(component_ref) do
      {:ok, %Prima.ComponentRef{type: "catalyst"} = parsed} -> {:ok, parsed}
      _other -> {:error, :invalid}
    end
  end

  # The action as the running release declares it: the component's row
  # at the run's version, holding the run's release digest.
  defp declared(ctx, component, %{release_digest: running}, action) do
    case Components.get_component(
           ctx,
           component.name,
           component.version,
           component.namespace,
           "catalyst"
         ) do
      {:ok, %{release_digest: ^running, manifest: manifest}} ->
        declaration(manifest, action)

      {:ok, _another_release} ->
        {:error, :invalid}

      {:error, outage} when Components.is_outage(outage) ->
        {:error, :unavailable}

      {:error, _absent} ->
        {:error, :invalid}
    end
  end

  defp declaration(manifest, action) do
    with {:ok, decoded} <- Prima.Manifest.decode_strict(manifest),
         %{} = declaration <- Enum.find(Asks.from_manifest(decoded), &(&1.name == action)) do
      {:ok, declaration}
    else
      _undeclared -> {:error, :invalid}
    end
  end

  defp admit(ctx, run, ask_no, request, component, declaration) do
    actor = Context.actor(ctx)

    with {:ok, first} <- first_state(ctx, run, component, declaration) do
      question =
        Map.merge(first, %{
          ref: mint_ref(),
          execution_id: run.execution_id,
          attempt_id: run.attempt_id,
          root_execution_id: run.root_execution_id,
          ask_no: ask_no,
          request_digest: request.request_digest,
          component_ref: run.component_ref,
          release_digest: run.release_digest,
          action: declaration.name,
          title: declaration.title,
          summary: request.summary,
          operation: request.operation,
          masked: request.masked,
          caller: run.caller,
          deadline: run.deadline
        })

      case Store.admit(actor, question) do
        {:ok, %{state: "open"} = row} ->
          Telemetry.question(:opened, ctx.athanor_id, ctx.user_id, %{
            ref: row.ref,
            expires_at: row.deadline,
            opened_at: row.opened_at,
            label: label(row)
          })

          {:pending, row.ref}

        {:ok, row} ->
          held(row)

        # A racing admission of the same key won: its row answers.
        {:error, :exists} ->
          case find(ctx, run.attempt_id, ask_no, request.request_digest) do
            {:error, :changed} -> invalid()
            :none -> unavailable()
            held -> held
          end

        {:error, _closed_or_unanswered} ->
          unavailable()
      end
    else
      {:error, :unavailable} -> unavailable()
    end
  end

  # The first that applies: a permission that covers the ask, nobody who
  # can be asked, or the question opens.
  defp first_state(ctx, run, component, declaration) do
    case Store.standing(Context.actor(ctx), ctx.user_id, component.namespace, component.name) do
      {:ok, rows} ->
        case covering(rows, declaration, run.caller) do
          %{effect: effect, id: id} ->
            {:ok, %{state: decided_state(effect), standing_answer_id: id}}

          nil ->
            if ctx.origin == :interactive,
              do: {:ok, %{state: "open"}},
              else: {:ok, %{state: "none", none_reason: "unattended"}}
        end

      {:error, _unanswered} ->
        {:error, :unavailable}
    end
  end

  # The standing answer that covers an ask of `declaration` by `caller`:
  # the same action, a deadline to come, for an allow the declaration it
  # was given under; this caller's before any caller's, and an unknown
  # caller only any caller's.
  defp covering(rows, declaration, caller) do
    digest = Asks.digest(declaration)
    now = DateTime.utc_now()

    live =
      Enum.filter(rows, fn row ->
        row.action == declaration.name and
          (is_nil(row.until) or DateTime.compare(row.until, now) == :gt) and
          (row.effect == "deny" or row.declaration_digest == digest)
      end)

    own =
      if caller == Caller.encode(:unknown),
        do: nil,
        else: Enum.find(live, &(&1.caller == caller))

    own || Enum.find(live, &(&1.caller == Caller.any()))
  end

  defp decided_state("allow"), do: "allowed"
  defp decided_state("deny"), do: "denied"

  # What a row answers its asking run.
  defp held(%{state: "open", ref: ref}), do: {:pending, ref}
  defp held(%{state: "allowed"}), do: {:answer, :allowed}
  defp held(%{state: "denied"}), do: {:answer, :denied}
  defp held(%{state: "none", none_reason: "unattended"}), do: {:answer, {:none, :unattended}}
  defp held(%{state: "none", none_reason: "invalid"}), do: invalid()
  # A question its run's end closed: the attempt is no longer current, and
  # the host answers it lost.
  defp held(_none_or_ended), do: unavailable()

  defp invalid, do: {:answer, {:none, :invalid}}
  defp unavailable, do: {:answer, {:none, :unavailable}}

  # 144 random bits, URL-safe: a question's public name.
  defp mint_ref, do: "q_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  # ---------------------------------------------------------------------------
  # The door
  # ---------------------------------------------------------------------------

  # A person who could give a proof, through their own session or a paired
  # device of theirs, in an athanor.
  defp answerer(%Context{} = ctx) do
    if Pairing.can_confirm?(ctx) and Prima.PersonId.person?(ctx.user_id) and
         is_binary(ctx.athanor_id) and ctx.athanor_id != "",
       do: :ok,
       else: {:error, :unauthenticated}
  end

  # Open, and its deadline to come: the store reads both again under its
  # lock, so a confirmation is never asked for a question past answering.
  defp open(%{state: "open", deadline: deadline}) do
    if DateTime.compare(deadline, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :closed}
  end

  defp open(_decided), do: {:error, :closed}

  defp own({:ok, row}, _ref), do: {:ok, row}
  defp own({:error, :not_found}, ref), do: {:error, {:not_found, "question", ref}}
  defp own({:error, _unanswered}, _ref), do: {:error, :unavailable}

  defp read({:ok, rows}), do: {:ok, rows}
  defp read({:error, _unanswered}), do: {:error, :unavailable}

  defp decision(:allow), do: "allowed"
  defp decision(:deny), do: "denied"

  # The standing answer a card's answer writes, or nil for one given once.
  defp lasting(_row, _component, %Answer{lasts: :once}), do: {:ok, nil}

  defp lasting(row, component, %Answer{effect: effect, lasts: lasts, covers: covers}) do
    until = with {:until, time} <- lasts, do: time

    with :ok <- to_come(if lasts == :always, do: nil, else: until),
         {:ok, caller} <- covered(covers, row.caller) do
      {:ok,
       %{
         publisher: component.namespace,
         name: component.name,
         action: row.action,
         declaration_digest: Asks.digest(%{name: row.action, title: row.title}),
         caller: caller,
         effect: Atom.to_string(effect),
         until: if(lasts == :always, do: nil, else: until)
       }}
    end
  end

  defp covered(:any_caller, _caller), do: {:ok, Caller.any()}

  defp covered(:this_caller, caller) do
    if caller == Caller.encode(:unknown),
      do: {:error, :unknown_caller},
      else: {:ok, caller}
  end

  defp known_caller(:unknown), do: {:error, :unknown_caller}
  defp known_caller(_caller), do: :ok

  defp to_come(nil), do: :ok

  defp to_come(%DateTime{} = until) do
    if DateTime.compare(until, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :until_passed}
  end

  # The title the newest installed version of the catalyst declares for
  # `action`.
  defp installed_title(ctx, publisher, name, action) do
    case Components.get_latest(ctx, name, publisher, "catalyst") do
      {:ok, %{manifest: manifest}} ->
        case declaration(manifest, action) do
          {:ok, %{title: title}} -> {:ok, title}
          {:error, :invalid} -> {:error, :undeclared}
        end

      {:error, outage} when Components.is_outage(outage) ->
        {:error, :unavailable}

      {:error, _absent} ->
        {:error, {:not_found, "component", Prima.ComponentRef.build("catalyst", publisher, name)}}
    end
  end

  # The widest answer: an allow, always, for any caller.
  defp widest?(%{effect: "allow", until: nil, caller: caller}), do: caller == Caller.any()
  defp widest?(_answer), do: false

  # The change a fresh confirmation binds: the operation, the answer as
  # written and the declaration's digest, with the component and the
  # action's title for its preview.
  defp change(operation, component, title, arguments) do
    %{
      operation: operation,
      arguments: arguments,
      resource: "#{component.namespace}.#{component.name}",
      details: %{"action" => title, "caller" => "any"}
    }
  end

  # A write with no confirmation to give runs as it is; one under
  # `:question_always_any` checks the proof first, consumes it inside
  # the write's transaction and announces it after the commit.
  defp confirmed(_ctx, nil, write), do: write.(fn -> :ok end)

  defp confirmed(ctx, change, write) do
    with :ok <- Authz.check(ctx, :question_always_any, change),
         {:ok, row} <- write.(fn -> Authz.consume(ctx, {:question_always_any, change}) end) do
      Authz.consumed(ctx)
      {:ok, row}
    end
  end

  # ---------------------------------------------------------------------------
  # Views and refusals
  # ---------------------------------------------------------------------------

  defp preview(row) do
    {:ok, component} = Prima.ComponentRef.parse(row.component_ref)

    %Preview{
      publisher: component.namespace,
      name: component.name,
      release_digest: row.release_digest,
      action: row.action,
      title: row.title,
      summary: row.summary,
      operation: row.operation,
      caller: row.caller,
      deadline: row.deadline,
      masked: row.masked
    }
  end

  defp label(row) do
    {:ok, component} = Prima.ComponentRef.parse(row.component_ref)
    "#{component.name} wants to #{row.title}"
  end

  defp refusal(:closed, _ref),
    do: refused(:conflict, :not_pending, "This question is no longer waiting for an answer")

  defp refusal(:unknown_caller, _ref),
    do:
      refused(
        :invalid_argument,
        :unknown_caller,
        "Who started this run is not known, so an answer can stand only for any caller"
      )

  defp refusal(:until_passed, _ref),
    do: refused(:invalid_argument, :until_passed, "An answer can last only until a time to come")

  defp refusal(:undeclared, action),
    do:
      refused(
        :invalid_argument,
        :undeclared,
        "This component does not say it asks before #{inspect(action)}"
      )

  defp refusal(:unauthenticated, _ref),
    do:
      refused(
        :unauthenticated,
        :unauthenticated,
        "Only a person signed in here, or on a device of theirs, can answer a component"
      )

  defp refusal(:invalid, _ref), do: refusal(:unavailable, nil)
  defp refusal(:unavailable, _ref), do: {:error, :unavailable}
  defp refusal(reason, _ref), do: {:error, reason}

  defp refused(class, reason, message),
    do: {:error, %Prima.Refusal{class: class, reason: reason, message: message}}
end
