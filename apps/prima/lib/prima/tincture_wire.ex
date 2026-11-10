# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TinctureWire do
  @moduledoc """
  The wire between a tincture's frame and the server, and between the
  frame and the shell that holds it.

  ## Frame to endpoint

  Two requests, each an HTTP `POST` of a JSON body to its route
  (`route/1`) carrying the frame credential as a bearer
  (`authorization: Bearer <credential>`, `bearer_header/0`), never in the
  URL or the body:

    * `invoke` — run a component the tincture declares: `ref` (a
      component reference), `operation` (a name) and `args` (an object).
      The component runs with the input
      `{"operation": <operation>, "params": <args>}`;
    * `action` — run a system action the tincture declares: `operation`
      (`tool.action`) and `args`.

  A public tincture's page opened at its address has no frame credential:
  its requests carry no bearer and name the tincture instead, as
  `public: {"athanor", "publisher", "name"}` (the athanor's URL segment,
  the publisher and the name, `public_identity?/1`). The endpoint admits
  such a request only for a tincture that is public, under its public
  profile.

  A body carries `v`, the wire version; one at no version or another is
  refused before anything else is read. An answer is
  `{"v", "ok": true, "result"}`, and for a refusal
  `{"v", "ok": false, "error": {"class", "message", "stage"}}`: the
  projection of a `Prima.Refusal` a frame may read, never its reason
  term, at the HTTP status its class answers with.

  ## The stream connection

  A frame reads every stream it opens over one WebSocket, its stream
  connection: at `socket_path/0` (`/_f/v1/socket`) for an app, and at
  `socket_path/1` (`/_f/v1/o/<frame id>/socket`), on its own data path
  alone, for a canvas. Each message is one JSON text message carrying `v`,
  at most `max_message_bytes/0` payload bytes from the frame, counted
  across every WebSocket frame it arrives in. A public page holds no
  frame credential and opens no stream.

  The frame sends (`decode_message/1`):

    * `subscribe` — exactly `v`, `type`, `sub` (the frame's own number for
      the subscription, `subscription?/1`, never one of its live ones),
      `credential` (the frame credential, the newest the shell handed it),
      `stream` (a provider stream's name) and `subject` (a literal, or
      null for a stream that takes none). The credential travels in the
      message and never in the connection's URL;
    * `unsubscribe` — exactly `v`, `type` and `sub`: the subscription ends
      at once, admitted or still waiting for its answer, and nothing more
      of it is sent.

  The endpoint answers each subscription by its `sub`:

    * `subscribed` (`subscribed/1`) — exactly `v`, `type` and `sub`: the
      stream is open. Its current state follows first, where the stream
      declares one, each item's `data` marked `"refresh": true`;
    * `event` (`event/5`) — exactly `v`, `type`, `sub`, `stream`,
      `subject`, `id` (the payload's sequence number where the topic
      carries one, else null) and `data` (the payload projected to the
      grant's fields);
    * `snapshot` (`snapshot/2`) — exactly `v`, `type`, `sub` and `at`, an
      ISO 8601 time: the items since `subscribed`, or since the last
      `resync`, are the stream's whole picture as its read at `at` found
      it;
    * `resync` (`resync/1`) — exactly `v`, `type` and `sub`: a fresh
      picture follows, its items and then `snapshot`, and replaces the
      one the frame holds;
    * `stale` (`stale/2`) — exactly `v`, `type`, `sub` and `at`, the time
      of the picture the frame holds: it is the stream's bound old and no
      fresh picture came, until the next `resync`;
    * `ended` (`ended/2`) — exactly `v`, `type` and `sub`, and `error`, a
      refusal's projection, when the endpoint ended it for a reason the
      frame should know. One that comes before `subscribed` is the
      subscription's refusal: it never opened. An app's handler hears an
      `error` after `subscribed` as its last event, named
      `refusal_event/0`, as it heard a stream's end before.

  `snapshot`, `resync` and `stale` belong to a canvas-readable stream
  alone, and what they mean, with how a canvas hears an `ended` (its
  `unavailable` and `denied`), is the delivery contract
  (`Compendium.Canvas.catalog/1`).

  One connection carries at most `max_subscriptions/0` subscriptions at
  once, each counted from its `subscribe` until it ends. A frame holds
  one connection: a newer one of the same frame credential closes the
  older. The connection closes (WebSocket close codes, `close_code/1`)
  on a message that does not read as the wire's (`unreadable`, 4400), on
  one over `max_message_bytes/0` (`too_big`, 1009, the protocol's own),
  when replaced (`replaced`, 4409), and when it has held no subscription
  for `idle_ms/0` (`idle`, 1000); every subscription it carried ends
  with it, and a reconnect is a new connection whose subscriptions are
  new opens under the gate.

  The frame's document is sandboxed without `allow-same-origin`, so its
  origin is `null` and every request is cross-origin to the endpoint.

  ## Frame to shell

  Messages over the frame's `MessagePort`, each `{"v", "verb", "frame",
  "args"}`, `frame` the frame id the shell minted:

    * `open` — open a tincture: `args.ref`, a tincture reference, and
      optionally `args.subject`, exactly `kind` (one of
      `Prima.Manifest.Tincture.subject_kinds/0`) and `id` (`subject_id?/1`),
      what the app is opened on;
    * `title` — set the frame's title: `args.title`;
    * `credential` — ask the person for a secret through the shell's own
      prompt: `args.name`, the vault entry name to store it under, a
      non-empty string as the vault takes it. The value is typed into the
      shell and goes to the vault; the frame is told only that the prompt
      closed and whether an entry was saved;
    * `press` — press a feed's action: `args.binding`, a binding id
      (`Prima.Feed.binding_id?/1`), and `args.action`, the action's name
      (`Prima.Feed.name?/1`), exactly those two; or press a control the
      desktop declares: `args.control`, its id (`control?/1`), `args.call`,
      the number the frame gives this press (`call?/1`), which its answer
      carries back, and, for a control with a pick, `args.value`, the
      picked string (`press_value?/1`);
    * `prefs` — write the desktop's preferences: `args.document`, an
      object (what it may hold is `Prima.CanvasPrefs`'), and `args.call`,
      the number its answer carries back;
    * `ask` — ask AQUA about a widget: `args.widget`, a widget id
      (`widget?/1`). The sentence AQUA's panel opens with is Prism's;
    * `settings` — open one of Prism's pages: `args.page`, a page's key
      (`page?/1`), and optionally `args.ref` (`subject_id?/1`), the record
      on that page to open at; which pages exist, and which take a record,
      are Prism's;
    * `grant` — ask for the person's grant to a component: `args.ref`, a
      component reference (`Prima.ComponentRef`) of a catalyst, reagent,
      formula or tincture, at a version or none, and nothing else. Which
      component it names, and whether the person is asked, are the
      shell's; the person confirms in CYFR's own prompt;
    * `request` — ask the person for an act only they may do:
      `args.operation`, `grant` or an operation's name (`tool.action`,
      `request_operation?/1`), `args.args`, its arguments (an object; for
      a grant exactly `ref`, a component reference as `grant` takes one),
      and `args.call`, the number its answers carry back (`call?/1`).
      Which operations a frame may ask for, what the person is shown and
      what runs are the shell's: the frame performs nothing;
    * `failed` — the page failed: `args.stage`, `load` or `runtime`
      (`stages/0`);
    * `ready`, `close` — no arguments.

  No verb places, sizes or raises a frame: which frame is shown is the
  shell's and the person's. Which verbs the shell acts on is the shell's,
  by the frame's kind: `press`, `failed`, `grant`, `prefs`, `ask` and
  `settings` only from a canvas (`canvas_verbs/0`), and `request` from
  any frame.

  The shell answers a frame's `request`, and a canvas's press of a
  control whose operation the person approves first, over the frame's
  port under the call's number: `requested` (`requested/2`), exactly
  `call` and `request`, the request's id (`request_id?/1`), once the
  person is asked; then `decided` (`decided/3`), exactly `call` and
  `outcome` (`request_outcomes/0`), with `reason` exactly when the
  outcome names one: a refused request names `declined` when the person
  refused it, or a refusal's class (`Prima.Refusal.classes/0`) when CYFR
  refused it, before asking or after the person approved; a cancelled
  one may name one of `request_cancel_reasons/0`. A request refused or
  cancelled before the person was asked is answered `decided` alone.

  An app opened with a subject is answered it at its handshake beside its
  credential, `frame_handshake/2`: exactly `credential` and `subject`.

  ## A canvas

  A canvas (a tincture that declares the `tincture.desktop` block) is opened at its page,
  `page_path/2` (`/_c/v1/<asset credential>/<frame id>`, under
  `page_prefix/0`), and reads its streams at its open's data path alone:
  `data_path/1` (`/_f/v1/o/<frame id>/`) and its one route under it,
  `socket_path/1`, its stream connection. The version's own files stay under
  `Prima.TinctureUrl`'s served prefix.

  The shell answers a canvas frame's handshake with
  `canvas_handshake/5`: exactly `credential`, the frame credential, and
  `canvas`, exactly `mode` (`live` or `validation`, `canvas_modes/0`),
  `data_path`, the frame's own, `streams`, the version's declared
  streams, at most `max_canvas_streams/0` distinct objects of exactly
  `name` (a stream name, as `subscribe` holds it) and `subject` (a
  string or null), `prefs`, exactly `document` (an object) and
  `revision` (a whole number from 0), `appearance`, exactly `mode`
  (`appearance_modes/0`), `accent` (`#rrggbb`), `locale` (`locale?/1`),
  `time_zone` (`time_zone?/1`) and `safe_areas` (exactly `top`, `right`,
  `bottom` and `left`, whole CSS pixels to `max_safe_area/0`), and
  `person`, exactly `name`, the person's display name of 1 to
  `max_person_name/0` code points or null, never an identifier. Prism
  builds `streams` from the stored declaration of the version it serves,
  never from anything a frame or a page sends. The
  shell's later messages to a canvas over its port (`canvas`, `posture`,
  `covered`, `installed`, `state`, `pressed` and `prefs`) are JavaScript
  on both ends; `pressed` answers a control's press, exactly `control`,
  the press's `call` and `outcome` (`press_outcomes/0`), with `reason`, a
  refusal's class (`Prima.Refusal.classes/0`), exactly when refused;
  `prefs` answers a `prefs` write, exactly its `call`, `outcome`
  (`prefs_outcomes/0`), `document` and `revision` (the stored document as
  the shell now holds it), with `reason` exactly when refused. Either,
  `cancelled`, may name `too_soon` (`cancel_reasons/0`): the shell's end
  of the port forwards a canvas's verb for the person only while the
  shell's page holds activation that no input in its chrome and no
  earlier verb has spent, and drops one sent within the activation's
  lifespan of the last spend at once, never holding it. A frame
  numbers its presses of a control and its writes upward, one count for
  both, and the shell's end of its port drops one numbered no higher than
  the last, unanswered; the frame matches each answer to the call it is
  still waiting on by `call` and the answer's verb, never by order, and an
  answer to no such call moves nothing;
  `installed` names at most `max_installed/0` tinctures, each exactly the
  keys `installed_keys/0`: its `ref`, a tincture reference; its `name`, 1
  to `max_installed_name/0` code points; its `icon`, an emoji of 1 to
  `max_installed_icon/0` code points or null; and `open`, whether the
  tincture is open over the canvas.

  An app's frame is answered `requested` and `decided` over its port as a
  canvas is, and nothing else of a canvas's messages.

  `tests/fixtures/tincture_wire.json` holds one example of each request,
  one public request, one refusal, the stream connection's messages each
  way and the messages refused, how the SDK rejects a subscription that
  opens no stream, every shell verb's message and the messages refused,
  and a canvas's handshake replies, the shell's messages to a canvas and
  its paths; this module's test and the SDK's and the bridge's JavaScript
  tests read it.
  """

  @version 1
  @bearer_header "authorization"

  @routes %{
    invoke: "/_f/v1/invoke",
    action: "/_f/v1/action"
  }

  @socket_path "/_f/v1/socket"
  @socket_route "socket"
  @max_subscriptions 32
  @max_message_bytes 4_096
  @idle_ms 60_000
  @close_codes %{unreadable: 4400, too_big: 1009, replaced: 4409, idle: 1000}

  @verbs ~w(open close title ready credential press failed grant prefs ask settings request)a
  @canvas_verbs ~w(press failed grant prefs ask settings)a
  @stages ~w(load runtime)

  @refusal_event "refusal"

  @page_prefix "/_c/v1/"
  @data_prefix "/_f/v1/o/"

  @canvas_modes ~w(live validation)
  @max_canvas_streams 64
  @max_installed 512
  @max_installed_name 128
  @max_installed_icon 16
  @installed_keys ~w(icon name open ref)

  @appearance_modes ~w(light dark)
  @max_safe_area 512
  @max_person_name 128
  @max_press_value 256
  @max_call 2_147_483_647
  @press_outcomes ~w(accepted refused cancelled)
  @prefs_outcomes ~w(saved stale refused cancelled)
  @cancel_reasons ~w(too_soon)
  @request_outcomes ~w(approved refused cancelled)
  @request_cancel_reasons ~w(too_soon busy expired dismissed)
  @declined "declined"
  @grant_operation "grant"

  @frame_id ~r/\A[A-Za-z0-9_-]{8,64}\z/
  @athanor_segment ~r/\A@[a-z0-9]+(-[a-z0-9]+)*\z/
  @component_operation ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  # A control's or a widget's id, as the desktop block spells them.
  @desktop_id ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @page ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @subject_id ~r/\A[A-Za-z0-9][A-Za-z0-9_.:@\/-]{0,255}\z/
  @request_id ~r/\Areq_[A-Za-z0-9_-]{16,64}\z/
  @accent ~r/\A#[0-9a-f]{6}\z/
  @locale ~r/\A[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8}){0,7}\z/
  @time_zone ~r/\A[A-Za-z][A-Za-z0-9_+-]{0,31}(\/[A-Za-z0-9][A-Za-z0-9_+-]{0,31}){0,2}\z/
  @control_characters ~r/[\x{0}-\x{1F}\x{7F}-\x{9F}]/u
  @max_title 120

  @typedoc "A request the frame makes of the endpoint."
  @type kind :: :invoke | :action

  @typedoc "A message the frame sends the shell."
  @type verb ::
          :open
          | :close
          | :title
          | :ready
          | :credential
          | :press
          | :failed
          | :grant
          | :prefs
          | :ask
          | :settings
          | :request

  @typedoc "The public tincture a request names in place of a bearer."
  @type public_identity :: %{athanor: String.t(), publisher: String.t(), name: String.t()}

  @typedoc """
  A decoded request: the kind's fields, atom-keyed, with `public` only
  when the body names a public tincture.
  """
  @type request :: %{
          optional(:ref) => String.t(),
          optional(:operation) => String.t(),
          optional(:args) => map(),
          optional(:public) => public_identity()
        }

  @typedoc "What a frame may read of a refusal."
  @type refusal_projection :: %{class: String.t(), message: String.t(), stage: String.t()}

  @typedoc "A decoded shell message."
  @type shell_message :: %{verb: verb(), frame: String.t(), args: map()}

  @doc "The wire version every body, answer and message carries as `v`."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The request header the frame credential travels in, lowercase."
  @spec bearer_header() :: String.t()
  def bearer_header, do: @bearer_header

  @doc "The route of each request kind."
  @spec routes() :: %{kind() => String.t()}
  def routes, do: @routes

  @doc "The route `kind` is posted to."
  @spec route(kind()) :: String.t()
  def route(kind) when is_map_key(@routes, kind), do: Map.fetch!(@routes, kind)

  @doc "The request kinds."
  @spec kinds() :: [kind()]
  def kinds, do: Map.keys(@routes) |> Enum.sort()

  @doc "The shell verbs."
  @spec verbs() :: [verb()]
  def verbs, do: @verbs

  @doc """
  The shell verbs the shell takes from a canvas alone, `press`, `failed`,
  `grant`, `prefs`, `ask` and `settings`: from any other frame it drops
  them.
  """
  @spec canvas_verbs() :: [verb()]
  def canvas_verbs, do: @canvas_verbs

  @doc "The stages a `failed` message names: the page's load, or its run after it."
  @spec stages() :: [String.t()]
  def stages, do: @stages

  @doc "Whether `id` is a desktop control's id, as the desktop block spells one."
  @spec control?(term()) :: boolean()
  def control?(id), do: is_binary(id) and Regex.match?(@desktop_id, id)

  @doc "Whether `id` is a widget's id, as the desktop block's `prefs` spells one."
  @spec widget?(term()) :: boolean()
  def widget?(id), do: control?(id)

  @doc "Whether `page` is a page's key as Prism names its pages: a lowercase name."
  @spec page?(term()) :: boolean()
  def page?(page), do: is_binary(page) and Regex.match?(@page, page)

  @doc """
  Whether `value` is a value a press picks: text of 1 to
  #{@max_press_value} code points with no control character.
  """
  @spec press_value?(term()) :: boolean()
  def press_value?(value), do: bounded_text?(value, @max_press_value)

  @doc """
  Whether `call` numbers a frame's press or write: a whole number from 1
  to #{@max_call}, which the answer to it carries back.
  """
  @spec call?(term()) :: boolean()
  def call?(call), do: is_integer(call) and call >= 1 and call <= @max_call

  @doc """
  Whether `id` names what an app is opened on: 1 to 256 characters of
  letters, digits and `_ . : @ / -`, the first a letter or a digit.
  """
  @spec subject_id?(term()) :: boolean()
  def subject_id?(id), do: is_binary(id) and Regex.match?(@subject_id, id)

  @doc """
  Whether `subject` is what an app is opened on: exactly `kind`, one of
  `Prima.Manifest.Tincture.subject_kinds/0`, and `id` (`subject_id?/1`).
  """
  @spec subject?(term()) :: boolean()
  def subject?(%{"kind" => kind, "id" => id} = subject) when map_size(subject) == 2,
    do: kind in Prima.Manifest.Tincture.subject_kinds() and subject_id?(id)

  def subject?(_subject), do: false

  @doc "Whether `locale` is a language tag: a BCP 47 shape of at most 8 subtags."
  @spec locale?(term()) :: boolean()
  def locale?(locale),
    do: is_binary(locale) and byte_size(locale) <= 64 and Regex.match?(@locale, locale)

  @doc "Whether `zone` is an IANA time zone's name, such as `Europe/Lisbon` or `UTC`."
  @spec time_zone?(term()) :: boolean()
  def time_zone?(zone), do: is_binary(zone) and Regex.match?(@time_zone, zone)

  @doc "The modes a desktop's appearance names."
  @spec appearance_modes() :: [String.t()]
  def appearance_modes, do: @appearance_modes

  @doc "The most CSS pixels a safe-area inset of the appearance names."
  @spec max_safe_area() :: pos_integer()
  def max_safe_area, do: @max_safe_area

  @doc "The most code points the person's name in a canvas's handshake takes."
  @spec max_person_name() :: pos_integer()
  def max_person_name, do: @max_person_name

  @doc "The most code points a pressed value takes."
  @spec max_press_value() :: pos_integer()
  def max_press_value, do: @max_press_value

  @doc """
  What a control's press comes to, as `pressed` tells the canvas: the gate
  ran it (`accepted`), it was refused (`refused`, with the refusal's
  class), or it did not run because no input of the person's carried it,
  it came too soon after the last spend of the activation (`cancelled`
  naming `too_soon`) or the desktop was not shown live (`cancelled`).
  """
  @spec press_outcomes() :: [String.t()]
  def press_outcomes, do: @press_outcomes

  @doc """
  What a `prefs` write comes to, as `prefs` tells the canvas: written
  (`saved`), not written because another write came first (`stale`, with
  the stored document), refused (`refused`, with the refusal's class), or
  not written for want of the person's input (`cancelled`, naming
  `too_soon` when it came too soon after the last spend of the
  activation).
  """
  @spec prefs_outcomes() :: [String.t()]
  def prefs_outcomes, do: @prefs_outcomes

  @doc """
  Why a press or a write was cancelled, when its answer says: `too_soon`,
  sent while the activation its input gave was spent already.
  """
  @spec cancel_reasons() :: [String.t()]
  def cancel_reasons, do: @cancel_reasons

  @doc """
  What a request comes to, as `decided` tells the frame: the person
  approved it and it ran (`approved`); it was refused, by the person
  (`declined`) or by CYFR (a refusal's class), before the person was
  asked or once they approved it (`refused`); or it ended undecided
  (`cancelled`), naming why when the shell knows (`request_cancel_reasons/0`).
  """
  @spec request_outcomes() :: [String.t()]
  def request_outcomes, do: @request_outcomes

  @doc """
  Why a request was cancelled, when `decided` says: sent while the
  activation its input gave was spent already (`too_soon`), sent while
  another request of the same frame waited (`busy`), left undecided until
  it expired (`expired`), or dismissed by the person (`dismissed`).
  """
  @spec request_cancel_reasons() :: [String.t()]
  def request_cancel_reasons, do: @request_cancel_reasons

  @doc "The reason a request the person refused names: `declined`."
  @spec declined() :: String.t()
  def declined, do: @declined

  @doc "The operation a request for a grant names: `grant`."
  @spec grant_operation() :: String.t()
  def grant_operation, do: @grant_operation

  @doc """
  Whether `operation` is one a request may name by its form: `grant`, or
  an operation's name (`tool.action`). Which of them the shell asks the
  person for is the shell's.
  """
  @spec request_operation?(term()) :: boolean()
  def request_operation?(@grant_operation), do: true

  def request_operation?(operation),
    do: is_binary(operation) and Prima.Manifest.Tincture.operation_name?(operation)

  @doc """
  Whether `id` is a request's id: `req_` and 16 to 64 URL-safe characters,
  as `Prima.UUID7.request_id/0` mints one.
  """
  @spec request_id?(term()) :: boolean()
  def request_id?(id), do: is_binary(id) and Regex.match?(@request_id, id)

  @doc "Whether `id` is a frame id: 8 to 64 URL-safe characters."
  @spec frame_id?(term()) :: boolean()
  def frame_id?(id), do: is_binary(id) and Regex.match?(@frame_id, id)

  @doc """
  Whether `identity` names a public tincture: an athanor URL segment
  (`@<namespace>`), a publisher and a name, and nothing else.
  """
  @spec public_identity?(term()) :: boolean()
  def public_identity?(%{athanor: athanor, publisher: publisher, name: name} = identity)
      when map_size(identity) == 3 and is_binary(athanor) do
    Regex.match?(@athanor_segment, athanor) and
      Prima.ComponentRef.validate_ref_parts(publisher, name) == :ok
  end

  def public_identity?(_identity), do: false

  @doc """
  The name of the last event a page's handler hears of a stream the
  endpoint ended with a refusal (`ended` carrying `error`).
  """
  @spec refusal_event() :: String.t()
  def refusal_event, do: @refusal_event

  # ---- the bearer ------------------------------------------------------------

  @doc "The header value that carries `credential`."
  @spec bearer(String.t()) :: String.t()
  def bearer(credential) when is_binary(credential) and credential != "",
    do: "Bearer " <> credential

  @doc """
  The credential a header value carries, or `:error` for a value that is
  not `Bearer <credential>` with a credential free of whitespace.
  """
  @spec read_bearer(term()) :: {:ok, String.t()} | :error
  def read_bearer("Bearer " <> credential) do
    if credential != "" and not String.match?(credential, ~r/\s/),
      do: {:ok, credential},
      else: :error
  end

  def read_bearer(_value), do: :error

  # ---- requests --------------------------------------------------------------

  @doc """
  The JSON body of a `kind` request with `fields` (atom-keyed, as
  `decode_request/2` answers), naming the public tincture when `fields`
  carry `public`.
  """
  @spec request(kind(), map()) :: map()
  def request(kind, %{public: %{athanor: athanor, publisher: publisher, name: name}} = fields) do
    kind
    |> request(Map.delete(fields, :public))
    |> Map.put("public", %{"athanor" => athanor, "publisher" => publisher, "name" => name})
  end

  def request(:invoke, %{ref: ref, operation: operation, args: args}),
    do: %{"v" => @version, "ref" => ref, "operation" => operation, "args" => args}

  def request(:action, %{operation: operation, args: args}),
    do: %{"v" => @version, "operation" => operation, "args" => args}

  @doc """
  A decoded `kind` request body, or `{:error, sentence}`: a body at no
  version or another, a missing or malformed field, a field the kind
  does not carry, or a `public` that names no public tincture.
  """
  @spec decode_request(kind(), term()) :: {:ok, request()} | {:error, String.t()}
  def decode_request(kind, %{"v" => @version} = body) when is_map_key(@routes, kind) do
    with :ok <- only(body, ["public" | fields(kind)]),
         {:ok, fields} <- fields(kind, body) do
      public(fields, body)
    end
  end

  def decode_request(kind, %{}) when is_map_key(@routes, kind),
    do: {:error, "the body carries no wire version #{@version}"}

  def decode_request(kind, _body) when is_map_key(@routes, kind),
    do: {:error, "the body must be an object"}

  defp fields(:invoke), do: ~w(v ref operation args)
  defp fields(:action), do: ~w(v operation args)

  defp fields(:invoke, body) do
    with {:ok, ref} <- component_ref(body["ref"]),
         {:ok, operation} <- component_operation(body["operation"]),
         {:ok, args} <- args(body) do
      {:ok, %{ref: ref, operation: operation, args: args}}
    end
  end

  defp fields(:action, body) do
    with {:ok, operation} <- system_operation(body["operation"]),
         {:ok, args} <- args(body) do
      {:ok, %{operation: operation, args: args}}
    end
  end

  @public_refusal "public must name a public tincture: athanor, publisher and name"

  defp public(fields, %{"public" => %{} = public}) when map_size(public) == 3 do
    identity = %{
      athanor: public["athanor"],
      publisher: public["publisher"],
      name: public["name"]
    }

    if public_identity?(identity),
      do: {:ok, Map.put(fields, :public, identity)},
      else: {:error, @public_refusal}
  end

  defp public(_fields, %{"public" => _other}), do: {:error, @public_refusal}
  defp public(fields, _body), do: {:ok, fields}

  defp component_ref(ref) when is_binary(ref) do
    case Prima.ComponentRef.parse(ref) do
      {:ok, _parsed} -> {:ok, ref}
      {:error, _} -> {:error, "ref must be a component reference"}
    end
  end

  defp component_ref(_ref), do: {:error, "ref must be a component reference"}

  defp component_operation(operation) do
    if is_binary(operation) and Regex.match?(@component_operation, operation),
      do: {:ok, operation},
      else: {:error, "operation must be a name"}
  end

  defp system_operation(operation) do
    if Prima.Manifest.Tincture.operation_name?(operation),
      do: {:ok, operation},
      else: {:error, "operation must be an operation name (tool.action)"}
  end

  defp args(body) do
    case Map.get(body, "args", %{}) do
      %{} = args -> {:ok, args}
      _other -> {:error, "args must be an object"}
    end
  end

  # ---- answers ---------------------------------------------------------------

  @doc "The answer to an `invoke` or `action` request that succeeded."
  @spec result(term()) :: map()
  def result(value), do: %{"v" => @version, "ok" => true, "result" => value}

  @doc "The answer to a request that was refused: the refusal's class, message and stage."
  @spec refusal(Prima.Refusal.t()) :: map()
  def refusal(%Prima.Refusal{} = refusal),
    do: %{"v" => @version, "ok" => false, "error" => projection(refusal)}

  defp projection(%Prima.Refusal{} = refusal) do
    %{
      "class" => Atom.to_string(refusal.class),
      "message" => refusal.message,
      "stage" => Atom.to_string(refusal.stage)
    }
  end

  @doc """
  An answer read back: `{:ok, result}`, `{:refused, projection}` for a
  refusal whose class is one of `Prima.Refusal`'s, and
  `{:error, :invalid_answer}` for anything else.
  """
  @spec decode_answer(kind(), term()) ::
          {:ok, term()} | {:refused, refusal_projection()} | {:error, :invalid_answer}
  def decode_answer(kind, %{"v" => @version, "ok" => true, "result" => value} = answer)
      when is_map_key(@routes, kind) and map_size(answer) == 3,
      do: {:ok, value}

  def decode_answer(kind, %{"v" => @version, "ok" => false, "error" => error} = answer)
      when is_map_key(@routes, kind) and map_size(answer) == 3 do
    case read_projection(error) do
      {:ok, projection} -> {:refused, projection}
      :error -> {:error, :invalid_answer}
    end
  end

  def decode_answer(kind, _answer) when is_map_key(@routes, kind), do: {:error, :invalid_answer}

  defp read_projection(%{"class" => class, "message" => message, "stage" => stage} = error)
       when map_size(error) == 3 and is_binary(message) and stage in ["admission", "execution"] do
    if class in Enum.map(Prima.Refusal.classes(), &Atom.to_string/1),
      do: {:ok, %{class: class, message: message, stage: stage}},
      else: :error
  end

  defp read_projection(_error), do: :error

  # ---- the stream connection -------------------------------------------------

  @doc "An app's stream connection, `/_f/v1/socket`."
  @spec socket_path() :: String.t()
  def socket_path, do: @socket_path

  @doc """
  A canvas open's stream connection: `data_path/1` and `socket`. A frame
  id outside its grammar raises.
  """
  @spec socket_path(String.t()) :: String.t()
  def socket_path(frame_id), do: data_path(frame_id) <> @socket_route

  @doc "The most subscriptions one stream connection carries at once."
  @spec max_subscriptions() :: pos_integer()
  def max_subscriptions, do: @max_subscriptions

  @doc """
  The most payload bytes of one message a frame sends over its stream
  connection, whether it arrives in one WebSocket frame or several.
  """
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @doc "How long a stream connection that holds no subscription stays open, in milliseconds."
  @spec idle_ms() :: pos_integer()
  def idle_ms, do: @idle_ms

  @doc """
  The WebSocket close code a stream connection ends with: `unreadable`
  (a message that does not read as the wire's), `too_big` (a message
  over `max_message_bytes/0`), `replaced` (a newer connection of the same
  frame) or `idle`.
  """
  @spec close_code(:unreadable | :too_big | :replaced | :idle) :: pos_integer()
  def close_code(reason) when is_map_key(@close_codes, reason),
    do: Map.fetch!(@close_codes, reason)

  @doc "Whether `sub` is a subscription's number: a whole number from 1 to 2,147,483,647."
  @spec subscription?(term()) :: boolean()
  def subscription?(sub), do: is_integer(sub) and sub >= 1 and sub <= @max_call

  @doc "A `subscribe` message, as the frame sends it."
  @spec subscribe(pos_integer(), String.t(), String.t(), String.t() | nil) :: map()
  def subscribe(sub, credential, stream, subject) do
    %{
      "v" => @version,
      "type" => "subscribe",
      "sub" => sub,
      "credential" => credential,
      "stream" => stream,
      "subject" => subject
    }
  end

  @doc "An `unsubscribe` message, as the frame sends it."
  @spec unsubscribe(pos_integer()) :: map()
  def unsubscribe(sub), do: %{"v" => @version, "type" => "unsubscribe", "sub" => sub}

  @subscribe_keys ~w(credential stream sub subject type v)

  @doc """
  A message the frame sent, decoded from its JSON: `{:ok, {:subscribe,
  fields}}` (atom-keyed `sub`, `credential`, `stream` and `subject`),
  `{:ok, {:unsubscribe, sub}}`, `{:refused, sub, sentence}` for a
  `subscribe` whose number reads and whose other fields do not, which
  refuses that subscription alone, and `{:error, sentence}` for anything
  else, of which no subscription can be told.
  """
  @spec decode_message(term()) ::
          {:ok, {:subscribe, map()} | {:unsubscribe, pos_integer()}}
          | {:refused, pos_integer(), String.t()}
          | {:error, String.t()}
  def decode_message(%{"v" => @version, "type" => "subscribe", "sub" => sub} = message) do
    if subscription?(sub) do
      case subscription_fields(message) do
        {:ok, fields} -> {:ok, {:subscribe, Map.put(fields, :sub, sub)}}
        {:error, sentence} -> {:refused, sub, sentence}
      end
    else
      {:error, sub_sentence()}
    end
  end

  def decode_message(%{"v" => @version, "type" => "unsubscribe", "sub" => sub} = message)
      when map_size(message) == 3 do
    if subscription?(sub), do: {:ok, {:unsubscribe, sub}}, else: {:error, sub_sentence()}
  end

  def decode_message(%{"v" => @version, "type" => type})
      when type in ["subscribe", "unsubscribe"],
      do: {:error, "#{type} carries exactly v, type, sub and its own fields"}

  def decode_message(%{"v" => @version}),
    do: {:error, "a message is a subscribe or an unsubscribe"}

  def decode_message(%{}), do: {:error, "the message carries no wire version #{@version}"}
  def decode_message(_message), do: {:error, "a message is a JSON object"}

  defp sub_sentence, do: "sub must be a whole number from 1 to #{@max_call}"

  defp subscription_fields(message) do
    credential = Map.get(message, "credential")
    stream = Map.get(message, "stream")
    subject = Map.get(message, "subject")

    cond do
      Enum.sort(Map.keys(message)) != @subscribe_keys ->
        {:error, "subscribe carries exactly v, type, sub, credential, stream and subject"}

      not (is_binary(credential) and credential != "" and
               not String.match?(credential, ~r/\s/)) ->
        {:error, "credential must be the frame credential"}

      not Prima.Manifest.Tincture.stream_name?(stream) ->
        {:error, "stream must be a stream name"}

      not (is_nil(subject) or Prima.Manifest.Tincture.literal_subject?(subject)) ->
        {:error, "subject must be a literal subject or null"}

      true ->
        {:ok, %{credential: credential, stream: stream, subject: subject}}
    end
  end

  @doc "`subscribed`: subscription `sub` is open."
  @spec subscribed(pos_integer()) :: map()
  def subscribed(sub), do: %{"v" => @version, "type" => "subscribed", "sub" => sub}

  @doc """
  One `event` of subscription `sub` to `stream` with `subject`: `id` the
  payload's sequence number (nil for a topic that carries none) and
  `data` the projected payload.
  """
  @spec event(pos_integer(), String.t(), String.t() | nil, non_neg_integer() | nil, term()) ::
          map()
  def event(sub, stream, subject, id, data)
      when (is_nil(id) or (is_integer(id) and id >= 0)) and is_binary(stream) do
    %{
      "v" => @version,
      "type" => "event",
      "sub" => sub,
      "stream" => stream,
      "subject" => subject,
      "id" => id,
      "data" => data
    }
  end

  @doc """
  `snapshot`: the items subscription `sub` was handed since it opened, or
  since its last `resync`, are its stream's whole picture as of `at`.
  """
  @spec snapshot(pos_integer(), DateTime.t()) :: map()
  def snapshot(sub, %DateTime{} = at),
    do: %{"v" => @version, "type" => "snapshot", "sub" => sub, "at" => DateTime.to_iso8601(at)}

  @doc "`resync`: a fresh picture of subscription `sub`'s stream follows and replaces the last."
  @spec resync(pos_integer()) :: map()
  def resync(sub), do: %{"v" => @version, "type" => "resync", "sub" => sub}

  @doc """
  `stale`: subscription `sub`'s picture, taken at `at`, is its stream's
  bound old, and no fresh picture came.
  """
  @spec stale(pos_integer(), DateTime.t()) :: map()
  def stale(sub, %DateTime{} = at),
    do: %{"v" => @version, "type" => "stale", "sub" => sub, "at" => DateTime.to_iso8601(at)}

  @doc """
  `ended`: subscription `sub` ended, with `refusal`'s projection as
  `error` when the endpoint ended it for a reason the frame should know.
  """
  @spec ended(pos_integer(), Prima.Refusal.t() | nil) :: map()
  def ended(sub, nil), do: %{"v" => @version, "type" => "ended", "sub" => sub}

  def ended(sub, %Prima.Refusal{} = refusal),
    do: Map.put(ended(sub, nil), "error", projection(refusal))

  # ---- a canvas --------------------------------------------------------------

  @doc "The modes a canvas frame is opened in: shown live, or trialled in validation."
  @spec canvas_modes() :: [String.t()]
  def canvas_modes, do: @canvas_modes

  @doc "The most streams a canvas's handshake names."
  @spec max_canvas_streams() :: pos_integer()
  def max_canvas_streams, do: @max_canvas_streams

  @doc "The most tinctures the shell's `installed` message to a canvas names."
  @spec max_installed() :: pos_integer()
  def max_installed, do: @max_installed

  @doc "The most code points a tincture's name in `installed` takes."
  @spec max_installed_name() :: pos_integer()
  def max_installed_name, do: @max_installed_name

  @doc "The most code points a tincture's icon in `installed` takes."
  @spec max_installed_icon() :: pos_integer()
  def max_installed_icon, do: @max_installed_icon

  @doc "The keys of one tincture in `installed`, each present, sorted."
  @spec installed_keys() :: [String.t()]
  def installed_keys, do: @installed_keys

  @doc """
  The prefix every canvas page's path begins with, `/_c/v1/`: the segment
  after it is the asset credential, which a log or a telemetry span must
  never carry (`CyfrWeb.Plugs.ScrubTinctureCredentials`).
  """
  @spec page_prefix() :: String.t()
  def page_prefix, do: @page_prefix

  @doc """
  The page of a canvas open: `/_c/v1/<credential>/<frame id>`. A
  credential outside `Prima.TinctureUrl.credential?/1` or a frame id
  outside `frame_id?/1` raises.
  """
  @spec page_path(String.t(), String.t()) :: String.t()
  def page_path(credential, frame_id) do
    unless Prima.TinctureUrl.credential?(credential),
      do: raise(ArgumentError, "an asset credential is opaque, URL-safe and bounded")

    @page_prefix <> credential <> "/" <> frame!(frame_id)
  end

  @doc "The data prefix of a canvas open: `/_f/v1/o/<frame id>/`. A frame id outside its grammar raises."
  @spec data_path(String.t()) :: String.t()
  def data_path(frame_id), do: @data_prefix <> frame!(frame_id) <> "/"

  @doc """
  The shell's answer to canvas frame `frame_id`'s handshake: exactly
  `credential` and `canvas`, which holds exactly `mode`, the frame's own
  `data_path`, `streams`, each stream exactly `name` and `subject`, and
  the desktop's `prefs`, `appearance` and `person` from `desktop`
  (string-keyed, as the module doc spells them).

  Every argument is CYFR's own, so one outside the wire raises an
  `ArgumentError` whose sentence names no value, since the credential is
  one: a credential that is not a non-empty string, a mode that is not
  one of `canvas_modes/0`, a frame id outside `frame_id?/1`, streams
  that are not a list of at most `max_canvas_streams/0` distinct
  `%{"name", "subject"}` objects, each a stream name and a string or nil,
  or a `desktop` whose `prefs`, `appearance` or `person` is not the
  wire's.
  """
  @spec canvas_handshake(String.t(), String.t(), String.t(), [map()], map()) :: map()
  def canvas_handshake(frame_id, credential, mode, streams, desktop) do
    unless is_binary(credential) and credential != "",
      do: raise(ArgumentError, "a canvas's handshake carries the frame credential")

    unless mode in @canvas_modes,
      do: raise(ArgumentError, "a canvas's mode is #{Enum.join(@canvas_modes, " or ")}")

    unless canvas_streams?(streams),
      do:
        raise(
          ArgumentError,
          "a canvas's handshake names at most #{@max_canvas_streams} distinct streams, " <>
            "each exactly a stream name and a subject"
        )

    case desktop do
      %{"prefs" => prefs, "appearance" => appearance, "person" => person}
      when map_size(desktop) == 3 ->
        unless prefs?(prefs),
          do: raise(ArgumentError, "a canvas's prefs are exactly a document and its revision")

        unless appearance?(appearance),
          do:
            raise(
              ArgumentError,
              "a canvas's appearance is exactly mode, accent, locale, time_zone and safe_areas"
            )

        unless person?(person),
          do: raise(ArgumentError, "a canvas's person is exactly a name, or none")

        %{
          "credential" => credential,
          "canvas" => %{
            "mode" => mode,
            "data_path" => data_path(frame_id),
            "streams" => streams,
            "prefs" => prefs,
            "appearance" => appearance,
            "person" => person
          }
        }

      _other ->
        raise ArgumentError, "a canvas's handshake carries exactly prefs, appearance and person"
    end
  end

  @doc """
  The shell's answer to an app frame's handshake: its credential, and the
  subject it was opened on when it was opened on one. A credential that
  is not a non-empty string, or a subject outside `subject?/1`, raises.
  """
  @spec frame_handshake(String.t(), map() | nil) :: map()
  def frame_handshake(credential, subject) do
    unless is_binary(credential) and credential != "",
      do: raise(ArgumentError, "a frame's handshake carries the frame credential")

    cond do
      is_nil(subject) -> %{"credential" => credential}
      subject?(subject) -> %{"credential" => credential, "subject" => subject}
      true -> raise ArgumentError, "a frame's subject is exactly a kind and an id"
    end
  end

  @doc """
  The `pressed` message's arguments: press `call` of control `control`
  came to `outcome`, with the refusal's class `reason` exactly when
  refused, or `too_soon` when cancelled for it. A value outside the wire
  raises.
  """
  @spec pressed(String.t(), pos_integer(), String.t(), String.t() | nil) :: map()
  def pressed(control, call, outcome, reason \\ nil) do
    unless control?(control), do: raise(ArgumentError, "pressed names a control id")
    unless call?(call), do: raise(ArgumentError, "pressed names the press's call")

    %{"control" => control, "call" => call, "outcome" => outcome}
    |> answered(outcome, reason, @press_outcomes)
  end

  @doc """
  The `prefs` message's arguments: write `call` came to `outcome`, and
  the shell now holds `document` at `revision`, with the refusal's class
  `reason` exactly when refused, or `too_soon` when cancelled for it. A
  value outside the wire raises.
  """
  @spec prefs_answer(pos_integer(), String.t(), map(), non_neg_integer(), String.t() | nil) ::
          map()
  def prefs_answer(call, outcome, document, revision, reason \\ nil) do
    unless call?(call), do: raise(ArgumentError, "a prefs answer names the write's call")

    unless prefs?(%{"document" => document, "revision" => revision}),
      do: raise(ArgumentError, "a prefs answer carries a document and its revision")

    %{"call" => call, "outcome" => outcome, "document" => document, "revision" => revision}
    |> answered(outcome, reason, @prefs_outcomes)
  end

  @doc """
  The `requested` message's arguments: request `call` waits for the
  person as the request `request`. A value outside the wire raises.
  """
  @spec requested(pos_integer(), String.t()) :: map()
  def requested(call, request) do
    unless call?(call), do: raise(ArgumentError, "requested names the request's call")
    unless request_id?(request), do: raise(ArgumentError, "requested names a request id")
    %{"call" => call, "request" => request}
  end

  @doc """
  The `decided` message's arguments: request `call` came to `outcome`,
  with `reason`: `declined` or a refusal's class exactly when refused, or
  one of `request_cancel_reasons/0` when cancelled for it. A value outside
  the wire raises.
  """
  @spec decided(pos_integer(), String.t(), String.t() | nil) :: map()
  def decided(call, outcome, reason \\ nil) do
    unless call?(call), do: raise(ArgumentError, "decided names the request's call")
    classes = [@declined | Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)]
    args = %{"call" => call, "outcome" => outcome}

    cond do
      outcome not in @request_outcomes ->
        raise ArgumentError, "an outcome is one of #{Enum.join(@request_outcomes, ", ")}"

      outcome == "refused" and reason in classes ->
        Map.put(args, "reason", reason)

      outcome == "refused" ->
        raise ArgumentError, "a refused request names declined or its refusal's class"

      outcome == "cancelled" and reason in @request_cancel_reasons ->
        Map.put(args, "reason", reason)

      is_nil(reason) ->
        args

      true ->
        raise ArgumentError, "only a refused or a cancelled request names a reason"
    end
  end

  defp answered(args, outcome, reason, outcomes) do
    classes = Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)

    cond do
      outcome not in outcomes ->
        raise ArgumentError, "an outcome is one of #{Enum.join(outcomes, ", ")}"

      outcome == "refused" and reason in classes ->
        Map.put(args, "reason", reason)

      outcome == "refused" ->
        raise ArgumentError, "a refused outcome names its refusal's class"

      outcome == "cancelled" and reason in @cancel_reasons ->
        Map.put(args, "reason", reason)

      is_nil(reason) ->
        args

      true ->
        raise ArgumentError, "only a refused or a cancelled outcome names a reason"
    end
  end

  defp prefs?(%{"document" => document, "revision" => revision} = prefs)
       when map_size(prefs) == 2,
       do: is_map(document) and not is_struct(document) and is_integer(revision) and revision >= 0

  defp prefs?(_prefs), do: false

  defp appearance?(
         %{
           "mode" => mode,
           "accent" => accent,
           "locale" => locale,
           "time_zone" => zone,
           "safe_areas" => areas
         } = appearance
       )
       when map_size(appearance) == 5 do
    mode in @appearance_modes and is_binary(accent) and Regex.match?(@accent, accent) and
      locale?(locale) and time_zone?(zone) and safe_areas?(areas)
  end

  defp appearance?(_appearance), do: false

  defp safe_areas?(%{"top" => _, "right" => _, "bottom" => _, "left" => _} = areas)
       when map_size(areas) == 4,
       do: Enum.all?(Map.values(areas), &(is_integer(&1) and &1 in 0..@max_safe_area))

  defp safe_areas?(_areas), do: false

  defp person?(%{"name" => nil} = person) when map_size(person) == 1, do: true

  defp person?(%{"name" => name} = person) when map_size(person) == 1,
    do: bounded_text?(name, @max_person_name)

  defp person?(_person), do: false

  # Text of 1 to `max` code points with no control character.
  defp bounded_text?(text, max) do
    is_binary(text) and String.valid?(text) and String.length(text) > 0 and
      length(String.codepoints(text)) <= max and not Regex.match?(@control_characters, text)
  end

  defp frame!(frame_id) do
    if frame_id?(frame_id),
      do: frame_id,
      else: raise(ArgumentError, "a frame id is 8 to 64 URL-safe characters")
  end

  # A list's length is counted only once it is known to be proper:
  # `length/1` raises on an improper list, and its report prints the list.
  defp canvas_streams?(streams) do
    case proper_length(streams, 0) do
      count when is_integer(count) and count <= @max_canvas_streams ->
        Enum.all?(streams, &canvas_stream?/1) and Enum.uniq(streams) == streams

      _improper_or_long ->
        false
    end
  end

  defp proper_length([], count), do: count
  defp proper_length([_head | tail], count), do: proper_length(tail, count + 1)
  defp proper_length(_improper_tail, _count), do: nil

  # A stream `subscribe` could name: the stream-name grammar and a
  # subject that is a string or null.
  defp canvas_stream?(%{"name" => name, "subject" => subject} = stream)
       when map_size(stream) == 2 do
    Prima.Manifest.Tincture.stream_name?(name) and
      (is_nil(subject) or (is_binary(subject) and String.valid?(subject)))
  end

  defp canvas_stream?(_stream), do: false

  # ---- shell messages --------------------------------------------------------

  @doc "The message the frame `frame_id` posts for `verb`."
  @spec shell_message(verb(), String.t(), map()) :: map()
  def shell_message(verb, frame_id, args \\ %{}) when verb in @verbs and is_map(args),
    do: %{"v" => @version, "verb" => Atom.to_string(verb), "frame" => frame_id, "args" => args}

  @doc """
  A shell message read back, or `{:error, sentence}`: another version, a
  verb that is none of `verbs/0`, a frame id that is not one, or arguments
  the verb does not take.
  """
  @spec decode_shell_message(term()) :: {:ok, shell_message()} | {:error, String.t()}
  def decode_shell_message(%{"v" => @version} = message) do
    with :ok <- only(message, ~w(v verb frame args)),
         {:ok, verb} <- verb(message["verb"]),
         :ok <- frame(message["frame"]),
         {:ok, args} <- shell_args(verb, Map.get(message, "args", %{})) do
      {:ok, %{verb: verb, frame: message["frame"], args: args}}
    end
  end

  def decode_shell_message(%{}), do: {:error, "the message carries no wire version #{@version}"}
  def decode_shell_message(_message), do: {:error, "the message must be an object"}

  defp verb(name) do
    case Enum.find(@verbs, &(Atom.to_string(&1) == name)) do
      nil -> {:error, "verb must be one of #{Enum.join(@verbs, ", ")}"}
      verb -> {:ok, verb}
    end
  end

  defp frame(id), do: if(frame_id?(id), do: :ok, else: {:error, "frame must be a frame id"})

  defp shell_args(:open, %{"ref" => ref} = args) when map_size(args) in [1, 2] do
    cond do
      not match?({:ok, %{type: "tincture"}}, Prima.ComponentRef.parse(ref)) ->
        {:error, "open names a tincture reference"}

      map_size(args) == 1 ->
        {:ok, args}

      subject?(Map.get(args, "subject")) ->
        {:ok, args}

      true ->
        {:error, "open's subject is exactly a kind the apps accept and an id"}
    end
  end

  defp shell_args(:open, _args), do: {:error, "open names a tincture reference"}

  defp shell_args(:title, %{"title" => title} = args)
       when map_size(args) == 1 and is_binary(title) and title != "" do
    if String.length(title) <= @max_title,
      do: {:ok, args},
      else: {:error, "a title is at most #{@max_title} characters"}
  end

  defp shell_args(:title, _args), do: {:error, "title names a title"}

  defp shell_args(:credential, %{"name" => name} = args)
       when map_size(args) == 1 and is_binary(name) and name != "",
       do: {:ok, args}

  defp shell_args(:credential, _args), do: {:error, "credential names a vault entry"}

  defp shell_args(:press, %{"binding" => binding, "action" => action} = args)
       when map_size(args) == 2 do
    cond do
      not Prima.Feed.binding_id?(binding) -> {:error, "press names a binding id"}
      not Prima.Feed.name?(action) -> {:error, "press names an action by its name"}
      true -> {:ok, args}
    end
  end

  defp shell_args(:press, %{"control" => control, "call" => call} = args)
       when map_size(args) in [2, 3] do
    cond do
      not control?(control) -> {:error, "press names a control by its id"}
      not call?(call) -> {:error, "a press's call is a whole number from 1 to #{@max_call}"}
      map_size(args) == 2 -> {:ok, args}
      press_value?(Map.get(args, "value")) -> {:ok, args}
      true -> {:error, "a press's value is text of 1 to #{@max_press_value} code points"}
    end
  end

  defp shell_args(:press, _args),
    do: {:error, "press names a binding id and an action, or a control and its call"}

  defp shell_args(:prefs, %{"document" => document, "call" => call} = args)
       when map_size(args) == 2 and is_map(document) do
    if call?(call),
      do: {:ok, args},
      else: {:error, "a prefs write's call is a whole number from 1 to #{@max_call}"}
  end

  defp shell_args(:prefs, _args),
    do: {:error, "prefs carries exactly a document, an object, and its call"}

  defp shell_args(:ask, %{"widget" => widget} = args) when map_size(args) == 1 do
    if widget?(widget), do: {:ok, args}, else: {:error, "ask names a widget by its id"}
  end

  defp shell_args(:ask, _args), do: {:error, "ask names a widget by its id"}

  defp shell_args(:settings, %{"page" => page} = args) when map_size(args) in [1, 2] do
    cond do
      not page?(page) -> {:error, "settings names a page by its key"}
      map_size(args) == 1 -> {:ok, args}
      subject_id?(Map.get(args, "ref")) -> {:ok, args}
      true -> {:error, "settings' ref names a record by its id"}
    end
  end

  defp shell_args(:settings, _args), do: {:error, "settings names a page by its key"}

  defp shell_args(
         :request,
         %{"operation" => operation, "args" => request_args, "call" => call} = args
       )
       when map_size(args) == 3 do
    cond do
      not request_operation?(operation) ->
        {:error, "a request names grant or an operation, tool.action"}

      not (is_map(request_args) and not is_struct(request_args)) ->
        {:error, "a request's args are an object"}

      operation == @grant_operation and not grant_args?(request_args) ->
        {:error, "a request for a grant names exactly a component reference"}

      not call?(call) ->
        {:error, "a request's call is a whole number from 1 to #{@max_call}"}

      true ->
        {:ok, args}
    end
  end

  defp shell_args(:request, _args),
    do: {:error, "request carries exactly an operation, its args and its call"}

  defp shell_args(:grant, args) do
    if grant_args?(args), do: {:ok, args}, else: {:error, "grant names a component reference"}
  end

  defp shell_args(:failed, %{"stage" => stage} = args)
       when map_size(args) == 1 and stage in @stages,
       do: {:ok, args}

  defp shell_args(:failed, _args),
    do: {:error, "failed names a stage: #{Enum.join(@stages, " or ")}"}

  defp shell_args(_verb, args) when args == %{}, do: {:ok, args}
  defp shell_args(verb, _args), do: {:error, "#{verb} takes no arguments"}

  # Exactly `ref`, a component reference of a type a grant takes.
  defp grant_args?(%{"ref" => ref} = args) when map_size(args) == 1 do
    case Prima.ComponentRef.parse(ref) do
      {:ok, %{type: type}} -> type in Prima.ComponentRef.valid_types()
      _ -> false
    end
  end

  defp grant_args?(_args), do: false

  defp only(map, keys) do
    case map |> Map.keys() |> Enum.reject(&(&1 in keys)) do
      [] ->
        :ok

      extra ->
        {:error,
         "unknown field(s): #{extra |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}"}
    end
  end
end
