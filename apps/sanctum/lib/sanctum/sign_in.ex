# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.SignIn do
  @moduledoc """
  Sign-in, fresh confirmation and registry signatures by a request this
  CYFR mints and an answer a key of the person's account signs
  (`Prima.SignIn`, `ARCHITECTURE.md` §9.2–§9.3). The CYFR decides
  everything: it mints the request, verifies the answer against the
  account's log, asks its own rules and mints its own session.

  ## The request

  `request/3` mints a request for one purpose, `:sign_in`, `:confirm` or
  `:registry`, with this CYFR's origin (`Sanctum.origin/0`, in its one
  spelling) as its audience and the sign-in page on it, `/login`, as its
  return. It is held here, keyed by its challenge, for its lifetime
  (`Prima.SignIn.lifetime_ms/0`, five minutes), bound to what asked for
  it, as its browser's session cookie or its channel holds it: a browser
  not signed in yet, by its session's forgery token (`{:browser, token}`,
  the value the sign-in tickets are bound to); a person's browser, by
  their session's token hash (`{:session, hash}`), so the answer is taken
  only under the session that asked; or a device's channel (`{:channel,
  id}`, its paired client, with the identifier the channel speaks for). A
  browser is sent to the account pages of this deployment's directory
  (`Sanctum.directory_url/0`) with the request in the fragment: the sign
  page (`url`), or for a new account the new page with the name a
  surface offers. What each purpose holds beside its request:

    * `:sign_in` — the admission a new person comes in under, when the
      surface that asked carries one: the setup token (`{:setup, token}`)
      or an invitation's code hash (`{:invitation, hash}`,
      `Sanctum.Invitations.code_hash/1`). Without one a new person is
      admitted only as the door admits their identifier. A channel's
      sign-in is a device's hello (`Sanctum.DeviceUnlock.hello/2`): it
      holds the `kid` the hello named, the one key that may answer it, and
      the holder and name the device is paired with. A browser sent to the
      new page with a name (`{:new, name}`) holds that name.
    * `:confirm` — the pending confirmation `ref` of the asking context's
      own person in its athanor, still pending; the request's `subject` is
      the record's digest, which the system layer previewed before the
      hop, and `back` is where the browser returns to.
    * `:registry` — the `Prima.RegistryRequest` the caller is asked to
      sign, without signer and signature, which this CYFR composes for the
      operation and body asked: this deployment's registry
      (`Sanctum.registry_host/0`), the caller's identifier, a fresh nonce,
      and the request's own expiry, so the registry takes it as long as
      this CYFR takes its answer; and `back`. It is found by its nonce
      too, which a terminal's signed request carries in place of the
      challenge.

  `binding/1` is what a person's own client binds a request to: a
  protected device by its channel, a browser by its session.

  ## The answer

  `answer/3` takes a passkey's answer, as the fragment the account pages
  returned to `/login` or decoded, or a device's
  (`Prima.SignIn.DeviceAnswer`), with the binding of what delivered it,
  and checks it in this order, the first failure refusing:

    1. the answer's challenge names a request held here, which is taken
       and so spent whichever way the rest goes (`:answer_refused`
       otherwise: unknown, spent, or past its lifetime);
    2. the request is bound to what delivered the answer, is for the
       confirmation the caller names when it names one (`:ref`), and is
       unexpired and for this audience (`:answer_refused`): a replayed
       answer meets a spent request, and an answer from another browser
       or channel, or one past the request's expiry, signs no one in;
    3. the answering account's log, read within freshness's policy
       (`Sanctum.IdentityFreshness`): the cached head within its bound, or
       for an account this CYFR never read, its whole log at this
       deployment's directory (`:identity_stale`, `:identity_gone`,
       `:unavailable`);
    4. the signature over the request's digest by a key the log lists
       (`Prima.SignIn.verify/4`, `:answer_refused`); a key the cached log
       does not list yet is looked for once more in the log read now
       (`Sanctum.IdentityFreshness.fresh!/2`), so a passkey or device just
       added to the account answers at once;
    5. what the purpose does:
       * `:sign_in` asks about the identifier's person here. A person this
         CYFR holds is asked about by the door (`Sanctum.Door.sign_in/1`);
         one an invitation came with redeems it first
         (`Sanctum.Invitations.redeem_for/2`), and an invitation that can
         no longer be used grants nothing: a person the door admits anyway
         is signed in, anyone else is refused `:invitation_invalid`. A new
         person is admitted under the request's admission or the door
         (`Sanctum.Newcomer.admit/3`). A browser's answer then records
         the passkey that signed as a paired client of the person's, in
         their own athanor, by its key and the head it was verified under
         (`Arca.PairedClients.record_passkey/2`, the one that stands when
         it signed in here before), and mints a session on that client,
         bound to the same key and head, each under the issuance fence
         (`Sanctum.Session.create/2`, `:stale_head` when the head moved
         meanwhile). A request that offered a name at the new page then
         records it as the person's name, once the registry says the
         answering account holds it (`record_name/2`); a registry that
         does not, or does not answer, records nothing and the sign-in
         stands. A device's answer
         to its hello, by the key the hello named, pairs the device
         instead (`Sanctum.DeviceUnlock.pair/4`): in the new person's
         admission, or right after the door admitted a person this CYFR
         holds, and answers the key that signed.
       * `:confirm` requires the answer's identifier to be the
         confirmation's person's (`Sanctum.Tenancy.Users.identifier/1`, a
         `usr_` id never compared with a `per_` one), then confirms the
         record by that key at that head, under the fence
         (`Arca.PendingConfirmations.confirm/3`), and announces it
         (`Sanctum.Consent.Authz.announce/2`); the asking client repeats
         the change, which consumes it.
       * `:registry` requires the answer's identifier to be the caller's,
         and answers the signed request's bytes
         (`Prima.SignIn.registry_bytes/2`) for the registry client to
         send, with the registry request they sign.

  A terminal signs a `:registry` request's registry request itself, with
  its own key as `signer` (`Prima.RegistryRequest`), and answers with
  that signed request (`answer/3` takes it decoded). Its nonce names the
  request held for it, which is taken and so spent; it must be bound to
  what delivered the answer and unexpired, as above, and be exactly the
  registry request held, every field but `signer` and `sig` equal, so it
  names the caller's identifier, the operation and the body this CYFR
  composed. Whether the signature is a key of that account's is the
  registry's check, which reads the log itself; its bytes are answered as
  a passkey's are.

  Every refusal of steps 1, 2 and 4, and of a terminal's request that is
  not the one held, is `:answer_refused`, with no detail: the precise
  reason is logged by its shape. A request held on another member, or
  after this one restarted, is unknown here.

  ## Registry answers

  `record_namespace/2`: the namespace lands on the `users` row the moment
  the registry's answer to a token mint names it, before, and regardless
  of, the push tokens. That row is what every request reads
  (`Sanctum.Namespace`). `record_name/2` records a name the person says is
  theirs, once the registry's answer for that name names their account.
  """

  require Logger

  alias Prima.Identity.Encoding
  alias Prima.SignIn.{DeviceAnswer, PasskeyAnswer}
  alias Sanctum.Context
  alias Sanctum.Tenancy.Users

  @return_path "/login"

  @typedoc """
  What a request is bound to: a browser not signed in yet, by its
  session's forgery token; a person's browser, by their session's token
  hash; or a device's channel, by its paired client's id.
  """
  @type binding :: {:browser, String.t()} | {:session, binary()} | {:channel, String.t()}

  @typedoc """
  The admission a new person comes in under at a sign-in: the setup token,
  an invitation's code hash, or none (the door's verdict on the
  identifier).
  """
  @type admission :: {:setup, String.t()} | {:invitation, String.t()} | nil

  @typedoc """
  The account page a browser is sent to: the sign page, or the new page
  with the name it offers (nil for none).
  """
  @type page :: :sign | {:new, String.t() | nil}

  @typedoc """
  A minted request, and for a browser the account page it is sent to with
  the request in the fragment.
  """
  @type minted :: %{request: Prima.SignIn.t(), url: String.t() | nil}

  @typedoc "What an accepted answer did, by its purpose."
  @type outcome ::
          %{purpose: :sign_in, user: Users.user(), session_token: String.t()}
          | %{purpose: :sign_in, user: Users.user(), kid: String.t()}
          | %{purpose: :confirm, ref: String.t(), back: String.t() | nil}
          | %{
              purpose: :registry,
              user_id: String.t(),
              signed: binary(),
              back: String.t() | nil,
              registry_request: Prima.RegistryRequest.t()
            }

  # ---- the request -------------------------------------------------------------

  @doc """
  Mint and hold a request for `purpose`, bound to `binding` (the module
  doc). `opts`:

    * `:admission` — `:sign_in`'s `t:admission/0`;
    * `:page` — the account page a browser is sent to (`t:page/0`,
      `:sign` by default);
    * `:ctx` — the asking context, for `:confirm` and `:registry`: a person
      signed in, in an athanor;
    * `:ref` — `:confirm`'s pending confirmation;
    * `:operation` and `:body` — `:registry`'s registry operation and its
      body, which the registry request this CYFR composes carries;
    * `:back` — where a browser returns after a `:confirm` or `:registry`
      answer: a path on this CYFR;
    * `:identifier` — the account a channel speaks for, for a
      `{:channel, id}` binding;
    * `:kid` — the device key a channel's `:sign_in` (a hello) is
      answered by;
    * `:holder_kind`, `:display_name` — what holds that key and the name
      the device shows, as its hello reported them.

  Refusals: `:no_directory` (a browser's request with no directory to
  send it to), `:no_registry` (a registry request where this deployment
  names no registry), `{:not_found, "confirmation", ref}`, `:not_pending`,
  `:unauthenticated`, `{:invalid_argument, sentence}`, `:unavailable`.
  """
  @spec request(Prima.SignIn.purpose(), binding(), keyword()) ::
          {:ok, minted()} | {:error, term()}
  def request(purpose, binding, opts \\ []) when is_list(opts) do
    with :ok <- binding(binding, opts),
         {:ok, home} <- home(),
         {:ok, held} <- held(purpose, opts),
         {:ok, request} <- minted(purpose, home, held),
         {:ok, url} <- url(binding, request, Keyword.get(opts, :page, :sign)),
         :ok <- hold(request, binding, held) do
      {:ok, %{request: request, url: url}}
    end
  end

  defp binding({kind, token}, _opts)
       when kind in [:browser, :session] and is_binary(token) and token != "",
       do: :ok

  defp binding({:channel, id}, opts) when is_binary(id) and id != "" do
    if Encoding.identifier?(opts[:identifier]),
      do: :ok,
      else: {:error, {:invalid_argument, "A channel's request names the account it speaks for"}}
  end

  defp binding(_binding, _opts),
    do: {:error, {:invalid_argument, "A request is bound to a browser or a device's channel"}}

  @doc """
  What a request the caller's own client asks for is bound to, and its
  answer taken under, with the options `request/3` takes for it: a
  protected device's own channel, with the account it speaks for
  (`identifier:`), or the person's browser by their session.
  `:unauthenticated` for any other caller, `:unavailable` when the store
  cannot answer.
  """
  @spec binding(Context.t()) ::
          {:ok, binding(), keyword()} | {:error, :unauthenticated | :unavailable}
  def binding(%Context{auth_method: :device, client_id: client_id, user_id: user_id})
      when is_binary(client_id) and is_binary(user_id) do
    with {:ok, identifier} <- account_of(user_id),
         do: {:ok, {:channel, client_id}, [identifier: identifier]}
  end

  def binding(%Context{session_token_hash: hash}) when is_binary(hash) and hash != "",
    do: {:ok, {:session, hash}, []}

  def binding(%Context{}), do: {:error, :unauthenticated}

  # The account a person here speaks for: none is a caller who cannot.
  defp account_of(user_id) do
    case Users.identifier(user_id) do
      {:ok, identifier} when is_binary(identifier) -> {:ok, identifier}
      {:ok, nil} -> {:error, :unauthenticated}
      {:error, :not_found} -> {:error, :unauthenticated}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  @doc """
  This CYFR's origin in its one spelling (`Sanctum.origin/0`, its scheme
  and host lowercased, a default port and any path dropped): the audience
  of every request it mints and of every device certificate it issues.
  `:unavailable`, logged, for an origin that names no scheme and host.
  """
  @spec audience() :: {:ok, String.t()} | {:error, :unavailable}
  def audience, do: home()

  # An origin served under a path names no audience a request can carry.
  defp home do
    case Encoding.canonical_home(Sanctum.origin()) do
      {:ok, home} ->
        {:ok, home}

      :error ->
        Logger.error(
          "[Sanctum.SignIn] this CYFR's origin is no scheme and host a request can name as its " <>
            "audience; no request is minted"
        )

        {:error, :unavailable}
    end
  end

  # What each purpose holds beside its request.
  defp held(:sign_in, opts) do
    if admission?(opts[:admission]) do
      {:ok,
       %{
         admission: opts[:admission],
         identifier: opts[:identifier],
         kid: opts[:kid],
         holder_kind: opts[:holder_kind],
         display_name: opts[:display_name],
         name: offered(opts[:page])
       }}
    else
      {:error, {:invalid_argument, "A sign-in comes in under the setup token or an invitation"}}
    end
  end

  defp held(:confirm, opts) do
    with {:ok, ctx} <- person(opts[:ctx]),
         {:ok, row} <- pending(ctx, opts[:ref]) do
      {:ok,
       %{
         subject: row.digest,
         ref: row.ref,
         athanor_id: ctx.athanor_id,
         user_id: ctx.user_id,
         identifier: opts[:identifier],
         back: back(opts[:back])
       }}
    end
  end

  defp held(:registry, opts) do
    with {:ok, ctx} <- person(opts[:ctx]),
         {:ok, identifier} <- account_of(ctx.user_id),
         {:ok, registry} <- registry_request(identifier, opts) do
      {:ok,
       %{
         registry_request: registry,
         user_id: ctx.user_id,
         identifier: identifier,
         back: back(opts[:back])
       }}
    end
  end

  defp held(_purpose, _opts),
    do: {:error, {:invalid_argument, "A request is for sign_in, confirm or registry"}}

  # The name the new page was offered, which the answer may record.
  defp offered({:new, name}) when is_binary(name) and name != "", do: name
  defp offered(_page), do: nil

  # The registry request a `:registry` request carries, which expires with
  # it: the registry allows an expiry this far ahead
  # (`Prima.RegistryRequest.max_ahead_ms/0`), and a request this CYFR
  # still takes an answer to is one the registry still takes.
  defp registry_request(identifier, opts) do
    with {:ok, registry} <- Sanctum.registry_host() do
      %{
        "protocol" => Prima.RegistryRequest.protocol(),
        "registry" => registry,
        "operation" => opts[:operation],
        "identifier" => identifier,
        "nonce" => Encoding.b64(:crypto.strong_rand_bytes(Prima.RegistryRequest.nonce_bytes())),
        "expires_at" => System.system_time(:millisecond) + Prima.SignIn.lifetime_ms(),
        "body" => opts[:body]
      }
      |> Prima.RegistryRequest.to_sign()
      |> case do
        {:ok, request} ->
          {:ok, request}

        {:error, :unknown_operation} ->
          {:error, {:invalid_argument, "The registry knows no such operation"}}

        {:error, _malformed} ->
          {:error, {:invalid_argument, "The registry request's arguments are not valid"}}
      end
    end
  end

  defp admission?(nil), do: true
  defp admission?({kind, value}) when kind in [:setup, :invitation], do: is_binary(value)
  defp admission?(_other), do: false

  # A person signed in, in an athanor, off the guest plane.
  defp person(%Context{plane: plane, user_id: user_id, athanor_id: athanor_id} = ctx)
       when plane != :guest and is_binary(user_id) and is_binary(athanor_id) and athanor_id != "" do
    if ctx.authenticated and not ctx.anonymous and Prima.PersonId.person?(user_id),
      do: {:ok, ctx},
      else: {:error, :unauthenticated}
  end

  defp person(_ctx), do: {:error, :unauthenticated}

  # The context's own pending confirmation, by its public ref.
  defp pending(%Context{user_id: user_id} = ctx, ref) when is_binary(ref) do
    case Arca.PendingConfirmations.get(Context.actor(ctx), ref) do
      {:ok, %{user_id: ^user_id, state: "pending"} = row} -> {:ok, row}
      {:ok, %{user_id: ^user_id}} -> {:error, :not_pending}
      {:ok, _another} -> {:error, {:not_found, "confirmation", ref}}
      {:error, :not_found} -> {:error, {:not_found, "confirmation", ref}}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp pending(_ctx, _ref),
    do: {:error, {:invalid_argument, "A confirmation is named by its ref"}}

  # A path on this CYFR, never another origin's.
  defp back("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]) or String.contains?(path, ["#", "\\"]),
      do: nil,
      else: path
  end

  defp back(_path), do: nil

  defp minted(purpose, home, held) do
    Prima.SignIn.new(
      purpose: purpose,
      audience: home,
      challenge: :crypto.strong_rand_bytes(Prima.SignIn.challenge_bytes()),
      expires_at: System.system_time(:millisecond) + Prima.SignIn.lifetime_ms(),
      return: home <> @return_path,
      subject: held[:subject],
      registry_request: held[:registry_request]
    )
    |> case do
      {:ok, request} ->
        {:ok, request}

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] a request could not be minted: " <> Prima.LoggerContext.shape(reason)
        )

        {:error, :unavailable}
    end
  end

  # A browser goes to the account pages of this deployment's directory;
  # a channel's request travels over the channel.
  defp url({:channel, _id}, _request, _page), do: {:ok, nil}

  defp url({_browser, _token}, request, page) do
    with {:ok, directory} <- directory() do
      fragment = Prima.SignIn.fragment(request)

      case page do
        :sign ->
          {:ok, directory <> "/account/sign#" <> fragment}

        {:new, name} ->
          {:ok,
           directory <>
             "/account/new#name=" <> URI.encode_www_form(name || "") <> "&request=" <> fragment}
      end
    end
  end

  # The directory's origin: its account pages are served at its root.
  defp directory do
    case Sanctum.directory_url() do
      url when is_binary(url) ->
        if Encoding.directory_url?(url),
          do: {:ok, url |> Encoding.directory_origin() |> elem(0)},
          else: {:error, :no_directory}

      _none ->
        {:error, :no_directory}
    end
  end

  defp hold(request, binding, held) do
    entry = Map.merge(held, %{request: request, binding: binding})
    lifetime = Prima.SignIn.lifetime_ms()

    with :ok <- Arca.Cache.put(key(request.challenge), entry, lifetime),
         :ok <- by_nonce(request, lifetime) do
      :ok
    else
      {:error, _unavailable} -> {:error, :unavailable}
    end
  end

  # A terminal answers a registry request with the registry request it
  # signed, which names no challenge: its nonce finds the challenge.
  defp by_nonce(
         %Prima.SignIn{purpose: :registry, registry_request: registry} = request,
         lifetime
       ),
       do: Arca.Cache.put(nonce_key(registry.nonce), request.challenge, lifetime)

  defp by_nonce(_request, _lifetime), do: :ok

  defp key(challenge), do: {:sign_in_request, challenge}
  defp nonce_key(nonce), do: {:sign_in_registry_nonce, nonce}

  # ---- the answer --------------------------------------------------------------

  @doc """
  Check an answer against the request held for its challenge, delivered
  by `binding` (or by any binding of a list, as a browser holds its
  forgery token and its session together), and do what its purpose does
  (the module doc). `answer`
  is a passkey's answer as its fragment, or a decoded
  `Prima.SignIn.PasskeyAnswer` or `Prima.SignIn.DeviceAnswer`. `opts`:
  `:ref`, the confirmation the answer must be for, and `:operation` with
  `:body`, the registry operation and body it must be for, so an answer
  to any other request is refused before it does anything; `:now`, the
  clock in milliseconds, the system's by default; `:user_agent`, the
  user agent of the browser a sign-in's session is for, whose browser and
  system the session records (`Sanctum.Session.create/2`). A terminal's answer to
  a `:registry` request is the `Prima.RegistryRequest` it signed (the
  module doc).

  Refusals: `:answer_refused`, `:identity_stale`, `:identity_gone`,
  `:stale_head`, `{:door, reason}`, `:invitation_invalid`,
  `:setup_closed`, `:not_set_up`, `:not_standing`, the newcomer's own
  refusals (`Sanctum.Newcomer.admit/2`), `:unavailable`.
  """
  @spec answer(
          String.t() | PasskeyAnswer.t() | DeviceAnswer.t() | Prima.RegistryRequest.t(),
          binding() | [binding()],
          keyword()
        ) ::
          {:ok, outcome()} | {:error, term()}
  def answer(answer, binding, opts \\ [])

  def answer(fragment, binding, opts) when is_binary(fragment) do
    with {:ok, map} <- Prima.SignIn.parse_fragment(fragment),
         {:ok, answer} <- PasskeyAnswer.decode(map) do
      answer(answer, binding, opts)
    else
      {:error, reason} -> refused(reason)
    end
  end

  def answer(%struct{} = answer, binding, opts)
      when struct in [PasskeyAnswer, DeviceAnswer] and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)

    with {:ok, held} <- spent(answer.challenge),
         :ok <- bound(held.binding, binding),
         :ok <- expected(held, opts),
         :ok <- current(held.request, now),
         {:ok, identifier} <- answering(answer, held),
         {:ok, key, head} <- signed_by(answer, held.request, identifier, now) do
      done(held, answer, identifier, key, head, opts)
    end
  end

  def answer(%Prima.RegistryRequest{} = signed, binding, opts) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:millisecond) end)

    with {:ok, held} <- spent_by_nonce(signed.nonce),
         :ok <- bound(held.binding, binding),
         :ok <- expected(held, opts),
         :ok <- current(held.request, now),
         :ok <- composed(held.request, signed),
         {:ok, bytes} <- sent(signed) do
      {:ok, registry_outcome(held, bytes)}
    end
  end

  def answer(_answer, _binding, _opts), do: refused(:invalid_answer)

  # Taken, so spent on this answer whatever the rest says.
  defp spent(challenge) do
    case Arca.Cache.take(key(challenge)) do
      {:ok, %{request: %Prima.SignIn{}} = held} -> {:ok, held}
      _miss -> refused(:unknown_challenge)
    end
  end

  defp spent_by_nonce(nonce) do
    case Arca.Cache.take(nonce_key(nonce)) do
      {:ok, challenge} when is_binary(challenge) -> spent(challenge)
      _miss -> refused(:unknown_challenge)
    end
  end

  # A terminal's signed request is the registry request held, signed: every
  # field but its signer and signature is the one this CYFR composed.
  defp composed(%Prima.SignIn{purpose: :registry, registry_request: held}, signed) do
    if %{signed | signer: nil, sig: nil} == held, do: :ok, else: refused(:wrong_request)
  end

  defp composed(_request, _signed), do: refused(:wrong_purpose)

  # The bytes the registry is sent, bounded as a signer's are.
  defp sent(signed) do
    bytes = signed |> Prima.RegistryRequest.encode() |> Encoding.jcs!()

    if byte_size(bytes) > Prima.RegistryRequest.max_bytes(),
      do: refused(:request_malformed),
      else: {:ok, bytes}
  end

  # What delivered the answer holds a binding of the held one's kind, and
  # it is the same: a browser hands every binding its session cookie holds.
  defp bound(held, delivered) when is_list(delivered) do
    if Enum.any?(delivered, &(bound(held, &1) == :ok)), do: :ok, else: refused(:wrong_binding)
  end

  defp bound({kind, held}, {kind, delivered}) when is_binary(delivered) do
    if Plug.Crypto.secure_compare(held, delivered), do: :ok, else: refused(:wrong_binding)
  end

  defp bound(_held, _delivered), do: refused(:wrong_binding)

  # The confirmation, or the registry operation and body, the caller names
  # when it names one: an answer to any other request does nothing.
  defp expected(held, opts) do
    cond do
      Keyword.has_key?(opts, :ref) and Map.get(held, :ref) != opts[:ref] ->
        refused(:wrong_record)

      Keyword.has_key?(opts, :operation) and not for_operation?(held.request, opts) ->
        refused(:wrong_request)

      true ->
        :ok
    end
  end

  defp for_operation?(%Prima.SignIn{purpose: :registry, registry_request: registry}, opts),
    do: registry.operation == opts[:operation] and registry.body == opts[:body]

  defp for_operation?(_request, _opts), do: false

  # Unexpired and for this CYFR, before any log is read for it.
  defp current(%Prima.SignIn{expires_at: expires_at, audience: audience}, now) do
    cond do
      now >= expires_at -> refused(:expired)
      home() != {:ok, audience} -> refused(:wrong_audience)
      true -> :ok
    end
  end

  # The account that answers: a passkey's names it; a device answers for
  # the account its channel speaks for.
  defp answering(%PasskeyAnswer{identifier: identifier}, _held), do: {:ok, identifier}

  defp answering(%DeviceAnswer{}, %{binding: {:channel, _id}, identifier: identifier})
       when is_binary(identifier),
       do: {:ok, identifier}

  defp answering(_answer, _held), do: refused(:wrong_answer)

  # The key of the account that signed, read within freshness's policy: the
  # cached head, or for an account never read here, its whole log at this
  # deployment's directory. A key the cached log does not list yet is
  # looked for once more in the log read now, so a passkey or device just
  # added to the account answers at once.
  defp signed_by(answer, request, identifier, now) do
    with {:ok, head, state, read} <- account(identifier) do
      case verify(answer, request, state, now) do
        {:ok, key} -> {:ok, key, head}
        {:error, :unknown_key} when read == :cached -> signed_now(answer, request, head, now)
        {:error, reason} -> refused(reason)
      end
    end
  end

  defp signed_now(answer, request, cached, now) do
    case Sanctum.IdentityFreshness.fresh!(cached.identifier) do
      {:ok, %{head_hash: same}} when same == cached.head_hash ->
        refused(:unknown_key)

      {:ok, head} ->
        with {:ok, state} <- state(head) do
          case verify(answer, request, state, now) do
            {:ok, key} -> {:ok, key, head}
            {:error, reason} -> refused(reason)
          end
        end

      {:refused, reason} ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp account(identifier) do
    fresh =
      case Arca.DirectoryHeads.get(Prima.Actor.system(), identifier) do
        {:error, :not_found} ->
          read(
            Sanctum.IdentityFreshness.fresh!(identifier, directory: Sanctum.directory_url()),
            :read
          )

        {:ok, _cached} ->
          read(Sanctum.IdentityFreshness.fresh?(identifier), :cached)

        {:error, _unanswered} ->
          {:error, :unavailable}
      end

    case fresh do
      {:ok, head, read} ->
        with {:ok, state} <- state(head), do: {:ok, head, state, read}

      {:refused, reason} ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp read({:ok, head}, read), do: {:ok, head, read}
  defp read(other, _read), do: other

  defp state(head) do
    case Sanctum.IdentityFreshness.state(head) do
      {:ok, state} -> {:ok, state}
      {:error, :corrupt} -> {:error, :unavailable}
    end
  end

  defp verify(answer, request, state, now) do
    with {:ok, home} <- home() do
      Prima.SignIn.verify(answer, request, state, home: home, now: now)
    end
  end

  defp refused(reason) do
    Logger.info("[Sanctum.SignIn] an answer was refused: " <> Prima.LoggerContext.shape(reason))
    Sanctum.Telemetry.auth_event(:unknown, :failure, %{reason: :answer_refused})
    {:error, :answer_refused}
  end

  # ---- what each purpose does --------------------------------------------------

  # A device's hello: answered by the key it named, which is paired here
  # with the person's admission.
  defp done(
         %{request: %{purpose: :sign_in}, binding: {:channel, client_id}} = held,
         _answer,
         identifier,
         %Prima.Identity.Key{kind: :device, kid: kid} = key,
         head,
         _opts
       ) do
    if held[:kid] == kid do
      device = %{
        client_id: client_id,
        holder_kind: held[:holder_kind],
        display_name: held[:display_name]
      }

      pair = &Sanctum.DeviceUnlock.pair(&1, device, key, head.head_hash)

      with {:ok, user} <- signed_in(identifier, held.admission, head, pair),
           do: {:ok, %{purpose: :sign_in, user: learned(user), kid: kid}}
    else
      refused(:wrong_key)
    end
  end

  defp done(
         %{request: %{purpose: :sign_in}, binding: {:channel, _id}},
         _answer,
         _id2,
         _k,
         _h,
         _opts
       ),
       do: refused(:wrong_key)

  defp done(%{request: %{purpose: :sign_in}} = held, _answer, identifier, key, head, opts) do
    with {:ok, user} <- signed_in(identifier, held.admission, head, nil),
         {:ok, token} <- session(user, key, head, opts[:user_agent]) do
      {:ok, %{purpose: :sign_in, user: named(user, held[:name]), session_token: token}}
    end
  end

  defp done(%{request: %{purpose: :confirm}} = held, _answer, identifier, key, head, _opts) do
    with :ok <- theirs(held.user_id, identifier) do
      proof =
        %{proof: proof(key), kid: key.kid, head: head.head_hash}
        |> Map.merge(confirming_client(held.binding, key))

      case Arca.PendingConfirmations.confirm(
             Prima.Actor.in_athanor(held.athanor_id),
             held.ref,
             proof
           ) do
        {:ok, row} ->
          Sanctum.Consent.Authz.announce(:confirmed, row)
          {:ok, %{purpose: :confirm, ref: row.ref, back: held.back}}

        {:error, reason}
        when reason in [:not_pending, :expired, :not_found, :revoked, :stale_head] ->
          {:error, reason}

        {:error, reason} ->
          Logger.warning(
            "[Sanctum.SignIn] a confirmation could not be recorded: " <>
              Prima.LoggerContext.shape(reason)
          )

          {:error, :unavailable}
      end
    end
  end

  defp done(
         %{request: %{purpose: :registry} = request} = held,
         answer,
         identifier,
         _key,
         _head,
         _opts
       ) do
    with :ok <- theirs(held.user_id, identifier) do
      case Prima.SignIn.registry_bytes(request, answer) do
        {:ok, signed} -> {:ok, registry_outcome(held, signed)}
        {:error, reason} -> refused(reason)
      end
    end
  end

  # The name the new page was offered, recorded once the registry says the
  # account that answered holds it; with none offered, the name the registry
  # records for the account, asked by its identifier while this CYFR has no
  # name for the person. Nothing either meets refuses the sign-in, which is
  # made already: the person can still name themselves in Settings.
  defp named(user, nil), do: learned(user)

  defp named(user, name) do
    case record_name(user.id, name) do
      {:ok, named} ->
        named

      {:error, reason} ->
        Logger.info(
          "[Sanctum.SignIn] the name offered at sign-in was not recorded: " <>
            Prima.LoggerContext.shape(reason)
        )

        user
    end
  end

  defp learned(%{namespace: nil} = user) do
    with {:ok, identifier} <- account_of(user.id),
         {:ok, %Prima.HandleAnswer{handle: name}} <- Sanctum.Handle.name_of(identifier),
         {:ok, named} <- record_namespace(user.id, name) do
      named
    else
      {:error, reason} ->
        Logger.info(
          "[Sanctum.SignIn] the account's name was not learned at sign-in: " <>
            Prima.LoggerContext.shape(reason)
        )

        user
    end
  end

  defp learned(user), do: user

  defp registry_outcome(held, signed) do
    %{
      purpose: :registry,
      user_id: held.user_id,
      signed: signed,
      back: held.back,
      registry_request: held.request.registry_request
    }
  end

  # The person a confirmation or a registry request is for, as their
  # account: a `usr_` id mapped to its identifier, never compared with one.
  defp theirs(user_id, identifier) do
    case Users.identifier(user_id) do
      {:ok, ^identifier} -> :ok
      {:ok, _another} -> refused(:wrong_person)
      {:error, :not_found} -> refused(:wrong_person)
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp proof(%Prima.Identity.Key{kind: :passkey}), do: "passkey"
  defp proof(%Prima.Identity.Key{kind: :device}), do: "device"

  # A device confirms over its own channel, which names its paired client.
  defp confirming_client({:channel, client_id}, %Prima.Identity.Key{kind: :device}),
    do: %{client_id: client_id}

  defp confirming_client(_binding, _key), do: %{}

  # The person the identifier names here, or a new one, and what `also`
  # writes for them: in a new person's admission, or once the door
  # admitted a person this CYFR holds.
  defp signed_in(identifier, admission, head, also) do
    case Users.get_by_identifier(identifier) do
      {:ok, user} -> with {:ok, user} <- admitted(user, admission), do: also(also, user)
      {:error, :not_found} -> newcomer(identifier, admission, head, also)
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  defp also(nil, user), do: {:ok, user}

  defp also(also, user) do
    with :ok <- also.(user), do: {:ok, user}
  end

  # A person this CYFR holds, with the invitation they came with redeemed
  # first. An invitation that can no longer be used grants nothing: the
  # door decides, and a person it refuses is told the invitation failed.
  defp admitted(user, {:invitation, hash}) do
    case Sanctum.Invitations.redeem_for(hash, user.id) do
      {:ok, _redeemed} ->
        admitted(user, nil)

      {:error, :invitation_invalid} ->
        case admitted(user, nil) do
          {:ok, user} -> {:ok, user}
          {:error, {:door, _reason}} -> {:error, :invitation_invalid}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:door, _reason} = refused} ->
        {:error, refused}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp admitted(%{status: "active"} = user, _admission) do
    with {:ok, :allowed} <- Sanctum.Door.sign_in(user), do: unlocked(user.id)
  end

  defp admitted(_user, _admission), do: {:error, :not_standing}

  # A new person: admitted under the request's admission, or as the door
  # admits their identifier. One another answer made meanwhile is the
  # person this answer signs in.
  defp newcomer(identifier, admission, head, also) do
    account = %{
      identifier: identifier,
      directory_url: head.directory_url,
      head_hash: head.head_hash
    }

    case Sanctum.Newcomer.admit(admission || :open, account, also: also) do
      {:ok, %{person: user}} ->
        {:ok, user}

      {:error, :conflict} ->
        case Users.get_by_identifier(identifier) do
          {:ok, user} -> with {:ok, user} <- admitted(user, nil), do: also(also, user)
          {:error, _unread} -> {:error, :unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Invitations by identifier activate and fills are asked for without
  # refusing the sign-in: a pending invitation activates on the next one,
  # and a fill's failure lands on its athanor's row.
  defp unlocked(user_id) do
    case Sanctum.SharedThreads.activate_invited(%{id: user_id}) do
      {:ok, _n} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[Sanctum.SignIn] an invitation's activation failed for #{user_id}: " <>
            Prima.LoggerContext.shape(reason)
        )
    end

    :ok = Sanctum.Provisioning.after_sign_in(user_id)

    case Users.get(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # The session, on the passkey's client and bound to the key that signed
  # and the head it was verified under: a head that moved since is refused
  # by the fence, the client's and the session's. The client is recorded
  # first, so a revocation of it that commits before the session leaves
  # the session unminted (`Arca.SessionStorage.create_session/3`). It
  # records the browser and system the browser's user agent names.
  defp session(user, key, head, user_agent) do
    ctx =
      Context.build(
        user_id: user.id,
        email: user[:email],
        provider: proof(key),
        athanor_id: nil,
        permissions: Context.person_permissions()
      )

    with {:ok, client} <- passkey_client(user, key, head),
         {:ok, ctx} <-
           Sanctum.Tenancy.resolve_status(%{ctx | namespace: user[:namespace]}, force: true),
         {:ok, session} <-
           Sanctum.Session.create(ctx,
             kid: key.kid,
             head: head.head_hash,
             client_id: client.id,
             user_agent: user_agent
           ) do
      Sanctum.Telemetry.auth_event(key.kind, :success)
      {:ok, session.token}
    else
      {:error, reason} when reason in [:stale_head, :unavailable, :not_owner, :not_standing] ->
        {:error, if(reason == :not_owner, do: :unavailable, else: reason)}

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.SignIn] #{user.id} was admitted and no session minted: " <>
            Prima.LoggerContext.shape(reason)
        )

        {:error, :unavailable}
    end
  end

  # The passkey's client in the person's own athanor: the one that stands,
  # or a new one at the head the answer was verified under.
  defp passkey_client(user, %Prima.Identity.Key{kind: :passkey, kid: kid}, head) do
    with {:ok, athanor_id} <- own_athanor(user.id) do
      Prima.Actor.in_athanor(athanor_id)
      |> Arca.PairedClients.record_passkey(%{user_id: user.id, kid: kid, head: head.head_hash})
      |> case do
        {:ok, client} -> {:ok, client}
        {:error, reason} when reason in [:stale_head, :not_owner] -> {:error, reason}
        {:error, _unrecorded} -> {:error, :unavailable}
      end
    end
  end

  defp own_athanor(user_id) do
    case Arca.Athanors.get_by_owner(Prima.Actor.system(), user_id) do
      {:ok, %{id: athanor_id}} -> {:ok, athanor_id}
      {:error, :not_found} -> {:error, :not_standing}
      {:error, _unanswered} -> {:error, :unavailable}
    end
  end

  # ---- registry answers --------------------------------------------------------

  @doc """
  Record `name` as the person `user_id`'s name here (`record_namespace/2`)
  once the registry says their account holds it: its answer for that name
  (`Sanctum.Handle.resolve/1`, which also reads the account it names at
  its directory) names the person's own identifier. A sign-in asks the
  registry for the account's name by its identifier
  (`Sanctum.Handle.name_of/1`); this is the way the person names
  themselves when that could not be answered, and the registry confirms
  it.

  Refusals: `:invalid_name` (not a name's spelling, before any request),
  `:name_not_theirs` (the registry names another account by it),
  `:name_unheld` (no account holds it, or the one that did is closed),
  `:no_registry`, `:registry_unavailable` (no usable answer),
  `:unauthenticated` (a person here with no account), `:unavailable`, and
  `record_namespace/2`'s own.
  """
  @spec record_name(String.t(), String.t()) ::
          {:ok, Sanctum.Tenancy.Users.user()}
          | {:error,
             :invalid_name
             | :name_not_theirs
             | :name_unheld
             | :no_registry
             | :registry_unavailable
             | :unauthenticated
             | :unavailable
             | term()}
  def record_name(user_id, name) when is_binary(user_id) and is_binary(name) do
    with {:ok, identifier} <- account_of(user_id),
         :ok <- holds(identifier, name),
         do: record_namespace(user_id, name)
  end

  defp holds(identifier, name) do
    case Sanctum.Handle.resolve(name) do
      {:ok, %Prima.HandleAnswer{identifier: ^identifier}} -> :ok
      {:ok, %Prima.HandleAnswer{}} -> {:error, :name_not_theirs}
      {:error, :invalid_handle} -> {:error, :invalid_name}
      {:error, :not_found} -> {:error, :name_unheld}
      {:error, :no_registry} -> {:error, :no_registry}
      {:error, _unanswered} -> {:error, :registry_unavailable}
    end
  end

  @doc """
  Record the person's cyfr.run namespace, as a registry answer names it:
  the durable copy on `users.namespace` that every request reads. Their own athanor was minted at admission; this
  only reruns the provisioning hook so a namespace-holding person's groups
  retry. Refuses a slug another identity on this server already holds; a
  row that already carries a *different* slug keeps it (logged — the
  registry, not this server, would have to say which is right).
  """
  @spec record_namespace(String.t(), String.t()) ::
          {:ok, Sanctum.Tenancy.Users.user()}
          | {:error, :not_found | :invalid_slug | :namespace_owned_by_another_identity | term()}
  def record_namespace(user_id, slug) when is_binary(user_id) and is_binary(slug) do
    with :ok <- personal_slug(slug),
         {:ok, user} <- Users.get(user_id) do
      cond do
        user.namespace == slug ->
          {:ok, user}

        is_binary(user.namespace) ->
          # The namespace is meant to be the same person everywhere. When the
          # registry names another one, this server keeps what it recorded —
          # its athanor slug, its paths and its push attribution are all built
          # on it — and says so loudly enough to be noticed, because the
          # divergence is permanent until someone reconciles it at cyfr.run.
          Logger.warning(
            "[Sanctum.SignIn] cyfr.run names #{user_id} #{inspect(slug)} but this server " <>
              "recorded #{inspect(user.namespace)} — keeping the recorded one; reconcile at " <>
              "cyfr.run if the registry is right"
          )

          :telemetry.execute(
            [:cyfr, :sanctum, :identity, :namespace_divergence],
            %{count: 1},
            %{user_id: user_id, recorded: user.namespace, registry: slug}
          )

          {:ok, user}

        true ->
          case Users.get_by_namespace(slug) do
            {:ok, %{id: other}} when other != user_id ->
              {:error, :namespace_owned_by_another_identity}

            {:error, :database_error} = err ->
              err

            _ ->
              with {:ok, user} <- Users.set_namespace(user, slug) do
                # The athanor exists since admission; the hook retries any
                # provisioning that failed. It never undoes the identity.
                _ = Sanctum.Provisioning.after_sign_in(user_id)
                Users.get(user_id) |> or_user(user)
              end
          end
      end
    end
  end

  # The row as reread after a write, or the row the write returned when
  # the reread fails.
  defp or_user({:ok, user}, _fallback), do: {:ok, user}
  defp or_user(_, fallback), do: {:ok, fallback}

  defp personal_slug(slug) do
    if Prima.ComponentRef.valid_personal_slug?(slug), do: :ok, else: {:error, :invalid_slug}
  end
end
