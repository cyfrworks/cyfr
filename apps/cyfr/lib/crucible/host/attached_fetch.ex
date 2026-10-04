# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.Host.AttachedFetch do
  @moduledoc """
  The host call a runner makes for its guest's request that names a
  connection: `attached_fetch` (`c:Prima.HostAPI.attached_fetch/3`). The
  guest keeps its request; CYFR attaches the credential the connection's
  need is bound to, makes the request itself and answers a stream of
  sealed frames, so no component, runner or worker service ever holds
  the credential.

  `Crucible.Host` verifies the call and reads its args
  (`Prima.AttachedRequest`, which refuses a credential, routing or
  framing header by shape) before `run/4` acts. The attempt must be held
  by the calling runner and live, as for an `egress_pin` (`:chain`);
  otherwise the call is `lost` or `unavailable` and nothing is resolved.
  What decides is the run's admitted authority and what CYFR holds for the
  attempt, never the request or the runner's copy, in this order:

    1. the connection is granted: the running node's manifest, read
       through `Crucible.Admission.inspect_component/2` at the attempt's
       pinned reference and held to the node's trusted digest (at a root
       the digest its activation graph pins, at a child its component's
       release digest), declares the connection as an `api_key`, `oauth`
       or `bundle` need with an attach rule; that rule is the one the
       edge's default vault resource attaches by; and no other credential
       need of the manifest has the same rule. Anything else, an edge with
       no vault resource or a selection the loader left unresolved
       included, is `connection_not_granted`;
    2. the guest names neither the rule's header (compared
       case-insensitively, `credential_header_refused`) nor, for a query
       rule, its query key (`invalid_request`);
    3. the URL and method are inside the vault resource's destination
       (`destination_mismatch`);
    4. the grant's egress admits the method (case-insensitively), the
       URL's scheme and its host (`method_blocked`, `scheme_blocked`,
       `domain_blocked`), and the request is within the node's
       `max_request_size` (`request_too_large`);
    5. the URL is pinned once, under the attempt's authority, through
       `Crucible.Host.Egress.pin/3` with the purpose `:attached`: the
       decision a guest's own fetch gets, metadata refused and a private
       address only under the grant's `private_ips`
       (`private_ip_blocked`, `dns_error`, `invalid_request`);
    6. the `http:` rate of the node is taken once (`rate_limited`);
    7. `Sanctum.Attach.resolve/5` decides the value (the binding's
       lifetime, the entry, the instance entry's audience, policy and
       caps, or the publisher's provided value).

  Each refusal is a guest error naming the request's call id, answered
  before anything is emitted, and recorded as a denial of the attempt's
  component (`Sanctum.Policy.Enforcement.record/1`), its reason led by
  `attached:` and naming the host, never the URL. A store that cannot
  answer is `unavailable`.

  Admitted, the value is audited as `[:cyfr, :opus, :secret, :dispensed]`
  (the attempt's identity, the connection, the field it fills and the
  request's `scheme://host:port`, never the value), joins the attempt's
  masking set (`Crucible.Attempt.call/3` with `{:attached, value}`), and
  the need's rule is applied: a header, or a query member, rendered by
  `Prima.Manifest.Needs.render_attach/2`. Only a whole answer as the
  upstream wrote it can be masked, so the request asks for
  `accept-encoding: identity` in place of any encoding the guest asked
  for, and a guest's `Range`, `If-Range` and `Request-Range` are not
  sent. It is then made by a process of its own, on a connection of its
  own that Mint opens to exactly the pinned address
  (`Prima.Network.pin/3`'s options: the host kept for SNI, verification
  and the `Host` header, no redirect, no retry, no decoding), so the
  answer's status and every header line arrive unmerged before any body
  byte; its body is streamed back as it arrives, one piece at a time. No
  pool holds the connection: the process closes it before its last word
  to the caller, or, raising, ends right after it, and the process ending
  closes it on every path. The
  request also asks the upstream to close it after the answer
  (`connection: close`), which nothing relies on. The head is the first
  header block after the answer's final status: an informational
  answer's lines are set aside, and a later block is a trailer section,
  and neither is ever relayed. The request's own process decides, as the
  status and the head arrive, the answers that end the stream with an
  `error` before its head or any of its body, and stops reading there and
  closes the connection, even when the answer was complete in its head:
  a status outside 100..599 is "an answer with no valid status", and a
  101, which switches to a protocol nothing in CYFR asks for, is "an
  answer switching protocols". The final answer's head, whatever its
  status code, is refused when the masker
  could not read the answer whole: one in any `content-encoding` but
  `identity`, or in any `transfer-encoding` but a single `chunked`, as
  "an encoded answer", and a 206, or an answer whose head carries a
  `content-range`, as "a partial answer". The caller writes the frames
  (`Prima.WorkerAuth.seal_frame/7`, under the attempt's seal key, for the
  request's call id, numbered from 0, each with a fresh IV): a `head` with
  the status and the headers, every value masked whole, a header whose
  name carries the attached value or is the rule's own header dropped,
  and the headers cut until the frame fits; a `chunk` per piece of body,
  masked with the attached value's tail held back across pieces
  (`Prima.SecretMasker.pending_prefix/2`); then an `end` after the tail
  masked once more, or an `error` with the tail dropped. A redirect is
  answered as a `head` and an `end`, and never followed: the guest's next
  request is a new attached fetch, checked afresh. A body past the node's
  `max_response_size`, a transport failure and the attempt's deadline end
  the stream with an `error` and close the upstream connection. A write
  the runner's connection no longer takes (`{:error, :closed}`) stops the
  request and closes the upstream connection. Anything that raises while
  the answer is relayed ends it as a failure does: the request stopped,
  its connection closed, and one `error` after the last frame written.

  The attempt refuses a nonce it has seen, and the pin makes its own
  attempt call, so the steps after the first call on the attempt present
  nonces derived from the verified header's (`<nonce>/pin`, `/rate`,
  `/attached`): a replayed header is refused at its first step, and no
  step repeats within one request.
  """

  require Logger

  alias Crucible.{Admission, Attempt, Keys}
  alias Crucible.Host.Egress
  alias Prima.{AttachedRequest, Authority, PinnedTarget, Refusal, SecretMasker, WorkerAuth}
  alias Prima.Authority.Blob
  alias Prima.Authority.Blob.Edge
  alias Prima.Manifest.Needs

  @credential_kinds ~w(api_key oauth bundle)
  @ambiguous "This connection's binding holds more than one value, and its attach rule takes one"
  @connect_timeout_ms 5_000
  @no_status "HTTP request failed: an answer with no valid status is not relayed"
  @switching "HTTP request failed: an answer switching protocols is not relayed"
  @encoded "HTTP request failed: an encoded answer is not relayed"
  @partial "HTTP request failed: a partial answer is not relayed"

  # What a caller has written of the answer it is relaying: the next
  # frame's sequence number and whether an `end` or `error` was written.
  @written {__MODULE__, :written}

  @typedoc "What `run/4` answers: `:ok` once the frames were written, or the refusal."
  @type answer ::
          :ok | {:error, :lost | :unavailable | Prima.HostAPI.attached_refusal()}

  @doc """
  Make the attached request `request` for the attempt of `caller` (the
  verified header), writing its answer's frames with `emit`, as the
  module doc orders it. Options: `:resolver`, passed to
  `Crucible.Host.Egress.pin/3` (a module answering `getaddr/2` as
  `:inet` does), which `Crucible.Host` never passes.
  """
  @spec run(Attempt.caller(), AttachedRequest.t(), Prima.HostAPI.emit(), keyword()) :: answer()
  def run(caller, %AttachedRequest{} = request, emit, opts \\ [])
      when is_function(emit, 1) and is_list(opts) do
    with {:ok, chain} <- Attempt.call(caller.execution_id, caller, :chain) do
      case admit(caller, chain, request, opts) do
        {:ok, admitted} ->
          transfer(caller, chain, request, admitted, emit)

        {:refused, type, message, event} ->
          record(chain, event, message)
          {:error, {:guest_error, type, message}}

        {:recorded, type, message} ->
          {:error, {:guest_error, type, message}}

        {:error, reason} when reason in [:lost, :unavailable] ->
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Admission
  # ---------------------------------------------------------------------------

  defp admit(caller, chain, request, opts) do
    {:ok, uri} = Prima.Network.parse_url(request.url)
    vault = default_vault(chain.authority)

    with {:ok, granted} <- granted(caller, chain, request.connection, vault),
         :ok <- no_collision(request, uri, granted.rule),
         :ok <- within_destination(vault, uri, request.method),
         :ok <- egress(chain.authority, uri, request.method),
         :ok <- request_size(chain.limits, request),
         {:ok, pin} <- pin(caller, request, uri, opts),
         :ok <- rate(caller, chain),
         {:ok, attached} <- resolve(chain, vault, request, uri, granted),
         :ok <- audit(caller, chain, vault, request.connection, uri),
         :ok <- masked(caller, attached.value) do
      {:ok, %{pin: pin, uri: uri, attached: attached}}
    end
  end

  # The binding a call through the node's edge uses when it names no
  # account: for a root its `@ingress` edge's default, for a child the
  # one binding its edge carries.
  defp default_vault(%Authority{resources: %Edge{} = edge}) do
    {:ok, vault} = Blob.vault_for(edge, nil)
    vault
  end

  defp default_vault(_authority), do: nil

  # 1. The attach rule identifies the need: the edge carries one need's
  # bindings and records no need name, so the connection is granted only
  # where the node's own manifest declares it with the rule the binding
  # attaches by, and no other credential need shares that rule.
  defp granted(caller, chain, connection, vault) do
    with %{} = rule <- vault_rule(vault),
         {:ok, _ref, _type, component} <-
           Admission.inspect_component(chain.ctx, chain.component_ref),
         digest when is_binary(digest) and digest != "" <-
           trusted_digest(caller, chain, component),
         true <- component["release_digest"] == digest,
         {:ok, manifest} <- Prima.Manifest.decode_strict(component["manifest"]),
         needs when is_list(needs) <- Needs.from_manifest(manifest),
         [%{name: ^connection}] <- Enum.filter(needs, &attaches_by?(&1, rule)) do
      {:ok, %{rule: rule, digest: digest}}
    else
      _not_granted -> refuse(:connection_not_granted, :denied)
    end
  end

  defp vault_rule(%{provided: %{attach: %{} = rule}}), do: rule
  defp vault_rule(%{entry_id: _, attach: %{} = rule}), do: rule
  defp vault_rule(_none_selected_or_disclose_only), do: nil

  defp attaches_by?(%{kind: kind, attach: %{} = attach}, rule) when kind in @credential_kinds,
    do: Needs.attach_to_map(attach) == Needs.attach_to_map(rule)

  defp attaches_by?(_need, _rule), do: false

  # The digest the running node is trusted at: at a root, the one its
  # consent's activation graph pins for it; at a child, its component's
  # release digest, which the child's transition was stepped with.
  defp trusted_digest(caller, %{authority: authority} = chain, component) do
    if caller.execution_id == chain.root_execution_id do
      case Authority.current_node(authority) do
        {:ok, node} -> Map.get(authority.activation, node)
        :unbound -> nil
      end
    else
      component["release_digest"]
    end
  end

  # 2. The rule's own header or query key is CYFR's to set.
  defp no_collision(request, _uri, %{in: "header", name: name}) do
    named = String.downcase(name)

    if Enum.any?(request.headers, fn {header, _value} -> String.downcase(header) == named end),
      do: refuse(:credential_header_refused, :denied),
      else: :ok
  end

  defp no_collision(_request, %URI{query: query}, %{in: "query", name: name}) do
    if query_names?(query, name),
      do:
        refuse(
          "invalid_request",
          "An attached request cannot set the #{name} query parameter its connection attaches.",
          :denied
        ),
      else: :ok
  end

  defp query_names?(nil, _name), do: false

  defp query_names?(query, name) do
    query |> URI.query_decoder() |> Enum.any?(fn {key, _value} -> key == name end)
  rescue
    # A query that does not decode cannot be told apart from one naming
    # the key.
    ArgumentError -> true
  end

  # 3. The destination the binding was consented at.
  defp within_destination(vault, uri, method) do
    destination =
      case vault do
        %{provided: %{destination: destination}} -> destination
        %{destination: destination} -> destination
      end

    if Prima.Destination.matches?(destination, uri, method),
      do: :ok,
      else: refuse(:destination_mismatch, :denied)
  end

  # 4. The grant's egress, as the worker service checks a guest's own
  # fetch, and its request size.
  defp egress(authority, uri, method) do
    edge =
      case authority do
        %Authority{resources: %Edge{} = edge} -> edge
        _none -> nil
      end

    egress = (edge && edge.egress) || %{}
    methods = Map.get(egress, :methods) || []
    schemes = Map.get(egress, :schemes) || []
    scheme = String.downcase(uri.scheme)
    host = host_of(uri)

    cond do
      not Enum.any?(methods, &(String.upcase(&1) == String.upcase(method))) ->
        refuse(
          "method_blocked",
          "HTTP egress refused: the method #{method} is not in the egress methods",
          :method_blocked
        )

      scheme not in schemes ->
        refuse(
          "scheme_blocked",
          "HTTP egress refused: the scheme #{scheme} is not in the egress schemes",
          :scheme_blocked
        )

      not Prima.Network.domain_allowed?(uri.host, Edge.domains(edge)) ->
        refuse(
          "domain_blocked",
          "HTTP egress refused: #{host} is not in the egress domains",
          :domain_blocked
        )

      true ->
        :ok
    end
  end

  # The URL and headers travel with the body and are held the same way, so
  # they count against the same ceiling.
  defp request_size(limits, request) do
    headers =
      Enum.reduce(request.headers, 0, fn {k, v}, acc -> acc + byte_size(k) + byte_size(v) end)

    size = byte_size(request.body) + byte_size(request.url) + headers

    if size > limits.max_request_size,
      do:
        refuse(
          "request_too_large",
          "Request (#{size} bytes incl. URL and headers) exceeds limit " <>
            "(#{limits.max_request_size} bytes)",
          :request_size
        ),
      else: :ok
  end

  # 5. One pin, under the attempt's authority. Its refusals are recorded
  # by the pin itself, as a guest fetch's are.
  defp pin(caller, request, uri, opts) do
    host = host_of(uri)
    pin_opts = Keyword.take(opts, [:resolver])

    case Egress.pin(
           step(caller, "pin"),
           %{url: request.url, purpose: :attached, from: nil},
           pin_opts
         ) do
      {:ok, %PinnedTarget{} = pin} ->
        {:ok, pin}

      {:error, :denied} ->
        {:recorded, "private_ip_blocked",
         "Address of #{host} blocked: the egress policy refuses it"}

      {:error, :metadata} ->
        {:recorded, "private_ip_blocked", "metadata IP blocked (resolved from #{host})"}

      {:error, :resolution} ->
        {:recorded, "dns_error", "DNS resolution failed for #{host}"}

      {:error, reason} when reason in [:lost, :unavailable] ->
        {:error, reason}

      {:error, _malformed} ->
        refuse("invalid_request", "Invalid URL", :denied)
    end
  end

  # 6. The rate, charged once per attached request, here.
  defp rate(caller, chain) do
    case Attempt.call(
           caller.execution_id,
           step(caller, "rate"),
           {:take_rate, "http:" <> chain.component_ref}
         ) do
      :ok ->
        :ok

      {:error, {:guest_error, "rate_limited", message}} ->
        refuse("rate_limited", message, :rate_limit)

      {:error, reason} when reason in [:lost, :unavailable] ->
        {:error, reason}

      {:error, _other} ->
        {:error, :lost}
    end
  end

  # 7. The vault decides, from what the attempt knows of its own run.
  defp resolve(chain, vault, request, uri, granted) do
    facts = %{
      node_ref: chain.component_ref,
      activation_digest: granted.digest,
      root_execution_id: chain.root_execution_id,
      profile_id: chain.authority.profile_id,
      consent_id: chain.authority.consent_id
    }

    case Sanctum.Attach.resolve(
           chain.ctx,
           vault,
           request.connection,
           %{uri: uri, method: request.method},
           facts
         ) do
      {:ok, attached} -> {:ok, attached}
      {:error, reason} -> attach_refusal(reason)
    end
  end

  # What the vault refused, as the guest's error: a credential refusal by
  # its own name and sentence, every other reason by the credential
  # refusal it amounts to. No sentence names an entry's material.
  defp attach_refusal(reason) when reason in [:unavailable, :database_error],
    do: {:error, :unavailable}

  defp attach_refusal({:ambiguous, _keys}), do: refuse("invalid_request", @ambiguous, :denied)

  defp attach_refusal({:connection_cap, _reset_at}), do: refuse(:connection_cap, :denied)
  defp attach_refusal({:provider_mismatch, _hint}), do: refuse(:provider_mismatch, :denied)

  defp attach_refusal(reason) when reason in [:binding_mismatch, :binding_went_stale],
    do: refuse(:grant_expired, :denied)

  defp attach_refusal(:denied), do: refuse(:not_offered, :denied)

  defp attach_refusal(reason) when is_atom(reason) do
    if reason in Refusal.credential_reasons(),
      do: refuse(reason, :denied),
      else: refuse(:connection_not_granted, :denied)
  end

  defp attach_refusal(_reason), do: refuse(:connection_not_granted, :denied)

  # The audit names the field and the request's origin, never the value,
  # its path or its query.
  defp audit(caller, chain, vault, connection, uri) do
    :telemetry.execute(
      [:cyfr, :opus, :secret, :dispensed],
      %{system_time: System.system_time()},
      %{
        athanor_id: caller.athanor_id,
        user_id: chain.ctx.user_id,
        execution_id: caller.execution_id,
        attempt: caller.attempt,
        fence: caller.fence,
        component_ref: chain.component_ref,
        consent_id: chain.authority.consent_id,
        runner: caller.runner,
        service: caller.service,
        connection: connection,
        field: field(vault, connection),
        destination: "#{String.downcase(uri.scheme)}://#{host_of(uri)}:#{uri.port}"
      }
    )

    :ok
  end

  defp field(%{provided: %{values: values}}, _connection), do: values |> Map.keys() |> hd()
  defp field(%{projection: %{scopes: [_ | _]}}, connection), do: connection
  defp field(%{projection: %{fields: [field]}}, _connection), do: field

  # The value joins the attempt's masking set before the request is made,
  # so a failure message is masked against it as well.
  defp masked(caller, value) do
    case Attempt.call(caller.execution_id, step(caller, "attached"), {:attached, value}) do
      :ok -> :ok
      {:error, reason} when reason in [:lost, :unavailable] -> {:error, reason}
      {:error, _other} -> {:error, :lost}
    end
  end

  # A step of one attached request after its first attempt call presents
  # a nonce of its own, derived from the verified header's.
  defp step(caller, name), do: %{caller | nonce: caller.nonce <> "/" <> name}

  defp refuse(reason, event) when is_atom(reason),
    do: refuse(Atom.to_string(reason), Refusal.message(reason), event)

  defp refuse(type, message, event), do: {:refused, type, message, event}

  # The same record the pin writes for its own refusals, attributed to the
  # attempt's component in its guest context.
  defp record(chain, event, message) do
    Sanctum.Policy.Enforcement.record(%{
      ctx: chain.ctx,
      component_ref: chain.component_ref,
      component_type: :catalyst,
      event_type: event,
      decision: :denied,
      decision_reason: "attached: " <> message
    })
  end

  # ---------------------------------------------------------------------------
  # The request and its frames
  # ---------------------------------------------------------------------------

  defp transfer(caller, chain, request, admitted, emit) do
    {:ok, seal} = WorkerAuth.attempt_seal_key(Keys.root(), caller)
    deadline = deadline(chain)

    stream = %{
      emit: emit,
      seal: seal,
      call_id: request.call_id,
      seq: 0,
      set: admitted.attached.masking,
      forms: name_forms(admitted.attached.masking),
      rule_header: rule_header(admitted.attached.attach),
      pending: "",
      bytes: 0,
      max: chain.limits.max_response_size
    }

    case request_options(request, admitted, deadline) do
      {:ok, options} ->
        tag = make_ref()
        parent = self()
        {pid, monitor} = spawn_monitor(fn -> upstream(parent, tag, options) end)
        relayed(stream, %{pid: pid, monitor: monitor, tag: tag, deadline: deadline})

      :error ->
        failed(stream, "http_error", "HTTP request failed")
    end
  end

  defp rule_header(%{in: "header", name: name}), do: String.downcase(name)
  defp rule_header(_query_rule), do: nil

  defp deadline(chain) do
    case chain.deadline do
      deadline when is_integer(deadline) ->
        deadline

      nil ->
        {:ok, timeout} = Prima.Limits.timeout_ms(chain.limits)
        now() + timeout
    end
  end

  # The request as CYFR sends it: the guest's method, headers and body,
  # the rule's header or query member, to the pinned address.
  defp request_options(request, admitted, deadline) do
    %{pin: pin, uri: uri, attached: %{value: value, attach: rule}} = admitted
    rendered = Needs.render_attach(rule, value)

    # The answer reaches the masker as the bytes the upstream wrote: an
    # encoded body would carry the value past it, so CYFR asks for no
    # encoding, in place of whatever the guest asked for; and a range would
    # cut a reflected value into pieces the masker never sees whole, so a
    # guest's range is not sent. The connection is the request's alone.
    identity =
      request.headers
      |> Enum.reject(fn {name, _value} ->
        String.downcase(name) in ["accept-encoding", "range", "if-range", "request-range"]
      end)
      |> Kernel.++([{"accept-encoding", "identity"}, {"connection", "close"}])

    {uri, headers} =
      case rule do
        %{in: "header", name: name} ->
          {uri, identity ++ [{name, rendered}]}

        %{in: "query", name: name} ->
          member = URI.encode_query([{name, rendered}])
          query = if uri.query in [nil, ""], do: member, else: uri.query <> "&" <> member
          {%{uri | query: query}, identity}
      end

    case Prima.Network.pin(
           %{uri | host: unbracket(pin.host)},
           PinnedTarget.address(pin),
           private_policy: :allow_all,
           receive_timeout: max(deadline - now(), 1),
           protocols: [:http1]
         ) do
      {:ok, pinned} ->
        # The pin's own connect options, opened as a pooled client opens
        # them: its connect timeout and `nodelay` unless the pin sets them,
        # TCP keepalive always, read passively, HTTP/1 only. The TLS
        # options are Mint's defaults, the host kept for SNI and the
        # hostname check; no key log is written for this connection.
        connect = Keyword.fetch!(pinned.req_opts, :connect_options)

        transport_opts =
          connect
          |> Keyword.get(:transport_opts, [])
          |> Keyword.put_new(:timeout, @connect_timeout_ms)
          |> Keyword.put_new(:nodelay, true)
          |> Keyword.put(:keepalive, true)

        conn_opts = [
          hostname: Keyword.fetch!(connect, :hostname),
          transport_opts: transport_opts,
          mode: :passive,
          protocols: [:http1]
        ]

        path = if uri.path in [nil, ""], do: "/", else: uri.path

        {:ok,
         %{
           scheme: if(uri.scheme == "https", do: :https, else: :http),
           address: pinned.ip_tuple,
           port: uri.port,
           conn_opts: conn_opts,
           method: request.method,
           path: if(uri.query in [nil, ""], do: path, else: path <> "?" <> uri.query),
           headers: headers,
           body: if(request.body == "", do: nil, else: request.body),
           deadline: deadline
         }}

      {:error, _blocked, _sentence} ->
        :error
    end
  end

  # The request, in a process of its own on a connection of its own: its
  # answer comes back one piece at a time, each waiting until the caller has
  # written it, so a reader that stops reading stops the request. It ends
  # with its caller, whether it is waiting on the caller or on the upstream.
  #
  # Mint connects to exactly the pinned address, under the pin's options,
  # and this process reads it passively, so the connection is this
  # process's alone: no pool holds it, it is closed before the process
  # tells its caller its last word (or, when something raises here, the
  # process ends right after that word), and the process ending closes it
  # on every path, a kill included. Mint hands over the answer as it reads
  # it: the status and every header line, unmerged, before any body byte.
  # A status that follows an informational one starts the answer again.
  # The head is the first header block after its status; a later block is
  # a trailer section, never relayed. A refusal decided on the status or
  # the head is the last thing it tells its caller.
  defp upstream(parent, tag, target) do
    watched(parent)

    last =
      try do
        requested(parent, tag, target)
      rescue
        _exception -> {:failed, :http_error}
      catch
        :exit, _reason -> {:failed, :http_error}
      end

    case last do
      {:refused, refused} -> send(parent, {tag, :refused, refused})
      :done -> send(parent, {tag, :done})
      {:failed, reason} -> send(parent, {tag, :failed, reason})
    end
  end

  defp requested(parent, tag, target) do
    with {:ok, conn} <-
           Mint.HTTP.connect(target.scheme, target.address, target.port, target.conn_opts),
         {:ok, conn, ref} <-
           Mint.HTTP.request(conn, target.method, target.path, target.headers, target.body) do
      read(conn, ref, unread(), parent, tag, target.deadline)
    else
      {:error, %{reason: reason}} -> {:failed, reason}
      {:error, conn, %{reason: reason}} -> closed(conn, {:failed, reason})
    end
  end

  defp read(conn, ref, answer, parent, tag, deadline) do
    case Mint.HTTP.recv(conn, 0, max(deadline - now(), 1)) do
      {:ok, conn, responses} ->
        case answered(responses, ref, answer, parent, tag) do
          {:more, answer} ->
            read(conn, ref, answer, parent, tag, deadline)

          {:halt, answer} ->
            closed(conn, {:refused, answer.refused})

          {:done, answer} ->
            closed(conn, nil)

            case ended(answer) do
              {:refused, refused} ->
                {:refused, refused}

              :relayed ->
                head_once(parent, tag, answer)
                :done
            end

          {:error, reason} ->
            closed(conn, {:failed, reason})
        end

      {:error, conn, error, _responses} ->
        closed(conn, {:failed, reason(error)})
    end
  end

  # The pieces of one read, in order, until the answer ends, fails or is
  # refused.
  defp answered([], _ref, answer, _parent, _tag), do: {:more, answer}
  defp answered([{:done, ref} | _rest], ref, answer, _parent, _tag), do: {:done, answer}

  defp answered([{:error, ref, error} | _rest], ref, _answer, _parent, _tag),
    do: {:error, reason(error)}

  defp answered([{kind, ref, value} | rest], ref, answer, parent, tag)
       when kind in [:status, :headers, :data] do
    case piece(parent, tag, {kind, value}, answer) do
      {:cont, answer} -> answered(rest, ref, answer, parent, tag)
      {:halt, answer} -> {:halt, answer}
    end
  end

  defp answered([_other | rest], ref, answer, parent, tag),
    do: answered(rest, ref, answer, parent, tag)

  defp closed(conn, last) do
    _ = Mint.HTTP.close(conn)
    last
  end

  defp reason(%{reason: reason}) when is_atom(reason), do: reason
  defp reason(_error), do: :http_error

  # A piece is decided before it is relayed, and a refusal halts the stream
  # where it is decided: the request closes its connection there.
  defp piece(parent, tag, piece, answer) do
    case decide(piece, answer) do
      {:cont, answer} -> relay_piece(parent, tag, piece, answer)
      {:halt, answer} -> {:halt, answer}
    end
  end

  defp relay_piece(parent, tag, {:data, data}, answer) do
    answer = head_once(parent, tag, answer)
    send(parent, {tag, :data, data})

    receive do
      {^tag, :more} -> {:cont, answer}
    end
  end

  defp relay_piece(_parent, _tag, _piece, answer), do: {:cont, answer}

  defp unread, do: %{status: nil, headers: nil, headed: false, refused: nil, pending: nil}

  # The decision on each piece. A 101 switches protocols, which nothing in
  # CYFR asks for, and its bytes would be relayed as a body; a status
  # outside 100..599 is no answer. Every header block that follows a status
  # is checked. A refused block whose status is 200 or more is the final
  # answer's head, and halts at once. One whose status is lower is held: a
  # later status shows the client set it aside as informational, and a
  # body after it, or its end, shows it was the final answer's head. So
  # the checks reach whatever block the client takes as the head, whatever
  # its status code.
  defp decide({:status, 101}, answer), do: {:halt, %{answer | refused: @switching}}

  defp decide({:status, status}, answer) when status in 100..599,
    do: {:cont, %{answer | status: status, headers: nil, pending: nil}}

  defp decide({:status, _status}, answer), do: {:halt, %{answer | refused: @no_status}}

  defp decide({:headers, fields}, %{headers: nil} = answer) do
    case {refusal(answer.status, fields), answer.status} do
      {nil, _status} -> {:cont, %{answer | headers: fields}}
      {refused, status} when status >= 200 -> {:halt, %{answer | refused: refused}}
      {refused, _status} -> {:cont, %{answer | headers: fields, pending: refused}}
    end
  end

  defp decide({:headers, _trailers}, answer), do: {:cont, answer}

  defp decide({:data, _data}, %{pending: refused} = answer) when is_binary(refused),
    do: {:halt, %{answer | refused: refused}}

  defp decide({:data, _data}, answer), do: {:cont, answer}
  defp decide({:trailers, _fields}, answer), do: {:cont, answer}

  # How an answer read to its end stands: a held refusal of the final head
  # is a refusal still.
  defp ended(%{refused: refused}) when is_binary(refused), do: {:refused, refused}
  defp ended(%{pending: refused}) when is_binary(refused), do: {:refused, refused}
  defp ended(_answer), do: :relayed

  @doc false
  # What the hook decides for an answer handed over as `pieces`, in order,
  # relaying nothing: `{:refused, sentence}`, or `{:head, status, headers}`
  # for the head it would relay. For the decision's own test.
  @spec decision([term()]) :: {:refused, String.t()} | {:head, integer() | nil, list()}
  def decision(pieces) when is_list(pieces) do
    pieces
    |> Enum.reduce_while(unread(), fn piece, answer ->
      case decide(piece, answer) do
        {:cont, answer} -> {:cont, answer}
        {:halt, answer} -> {:halt, answer}
      end
    end)
    |> then(fn answer ->
      case ended(answer) do
        {:refused, refused} -> {:refused, refused}
        :relayed -> {:head, answer.status, answer.headers || []}
      end
    end)
  end

  # A watcher of its own stops the request when its caller ends, and ends
  # itself when the request does.
  defp watched(parent) do
    request = self()

    spawn(fn ->
      caller = Process.monitor(parent)
      own = Process.monitor(request)

      receive do
        {:DOWN, ^caller, :process, _pid, _reason} -> Process.exit(request, :kill)
        {:DOWN, ^own, :process, _pid, _reason} -> :ok
      end
    end)

    :ok
  end

  defp head_once(_parent, _tag, %{headed: true} = answer), do: answer

  defp head_once(parent, tag, answer) do
    send(parent, {tag, :head, answer.status, answer.headers || []})
    %{answer | headed: true}
  end

  # Whatever raises while the answer is relayed ends it as a failure does:
  # the request stopped, which closes its connection, and one `error` frame
  # after the last frame written, unless an `end` or `error` already was.
  # The log names the kind of failure, never a value.
  defp relayed(stream, upstream) do
    Process.delete(@written)
    await(stream, upstream)
  catch
    kind, reason ->
      stop(upstream)

      Logger.error(
        "[Crucible.Host.AttachedFetch] relaying an answer failed (#{kind}: " <>
          "#{if is_exception(reason), do: inspect(reason.__struct__), else: "a term"}); " <>
          "the request is stopped"
      )

      case Process.get(@written) do
        %{ended: true} -> :ok
        %{seq: seq} -> last_error(%{stream | seq: seq})
        nil -> last_error(stream)
      end
  after
    Process.delete(@written)
  end

  defp last_error(stream) do
    failed(stream, "http_error", "HTTP request failed")
  catch
    _kind, _reason -> :ok
  end

  # The deadline is read before every piece, so an upstream that never
  # pauses cannot carry the stream past it.
  defp await(stream, upstream) do
    if now() >= upstream.deadline do
      stop(upstream)
      failed(stream, "timeout", "HTTP request timed out")
    else
      receive_piece(stream, upstream)
    end
  end

  defp receive_piece(stream, upstream) do
    receive do
      {tag, :head, status, headers} when tag == upstream.tag ->
        relay(stream, upstream, status, headers)

      {tag, :refused, message} when tag == upstream.tag ->
        stop(upstream)
        failed(stream, "http_error", message)

      {tag, :data, data} when tag == upstream.tag ->
        bytes = stream.bytes + byte_size(data)

        if bytes > stream.max do
          stop(upstream)

          failed(
            stream,
            "response_too_large",
            "Response body exceeds limit (#{stream.max} bytes)"
          )
        else
          case body(%{stream | bytes: bytes}, data) do
            {:ok, stream} ->
              send(upstream.pid, {upstream.tag, :more})
              await(stream, upstream)

            :closed ->
              stop(upstream)
          end
        end

      {tag, :done} when tag == upstream.tag ->
        stop(upstream)
        finish(stream)

      {tag, :failed, reason} when tag == upstream.tag ->
        stop(upstream)
        transport_failed(stream, reason)

      {:DOWN, monitor, :process, _pid, _reason} when monitor == upstream.monitor ->
        stop(upstream)
        failed(stream, "http_error", "HTTP request failed")
    after
      max(upstream.deadline - now(), 0) ->
        stop(upstream)
        failed(stream, "timeout", "HTTP request timed out")
    end
  end

  # An answer the masker cannot read as it arrives is not relayed: a part
  # nobody asked for (a 206, or a content-range in the head, since a
  # reflection split into ranges is a copy the masker never sees whole), or
  # one in any content coding but identity or in any transfer coding but a
  # single chunked.
  defp refusal(status, headers) do
    cond do
      status == 206 or ranged?(headers) -> @partial
      encoded?(headers) -> @encoded
      true -> nil
    end
  end

  # A redirect is answered, never followed.
  defp relay(stream, upstream, status, headers) do
    case head(stream, status, headers) do
      {:ok, stream} when status in 300..399 ->
        stop(upstream)
        finish(stream)

      {:ok, stream} ->
        await(stream, upstream)

      :closed ->
        stop(upstream)
    end
  end

  # Every line of each header counts: any content coding but identity, or
  # transfer codings that are anything but one chunked, an unknown or empty
  # token included.
  defp encoded?(headers) do
    Enum.any?(codings(headers, "content-encoding"), &(&1 != "identity")) or
      codings(headers, "transfer-encoding") not in [[], ["chunked"]]
  end

  defp ranged?(headers),
    do:
      Enum.any?(headers, fn {name, _value} ->
        String.downcase(to_string(name)) == "content-range"
      end)

  defp codings(headers, field) do
    for {name, values} <- headers,
        String.downcase(to_string(name)) == field,
        value <- List.wrap(values),
        token <- String.split(value, ","),
        do: token |> String.trim() |> String.downcase()
  end

  # The request's process is stopped, which closes its connection, and
  # nothing it sent is left behind.
  defp stop(upstream) do
    Process.demonitor(upstream.monitor, [:flush])
    Process.exit(upstream.pid, :kill)
    drain(upstream.tag)
    :ok
  end

  defp drain(tag) do
    receive do
      {^tag, _kind} -> drain(tag)
      {^tag, _kind, _value} -> drain(tag)
      {^tag, _kind, _status, _headers} -> drain(tag)
    after
      0 -> :ok
    end
  end

  defp transport_failed(stream, :timeout), do: failed(stream, "timeout", "HTTP request timed out")

  defp transport_failed(stream, reason) when is_atom(reason) do
    code = Atom.to_string(reason)

    if Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, code),
      do: failed(stream, "http_error", "HTTP request failed: " <> code),
      else: failed(stream, "http_error", "HTTP request failed")
  end

  defp transport_failed(stream, _reason), do: failed(stream, "http_error", "HTTP request failed")

  # The head: the status and the answer's headers a frame can carry, each
  # value masked whole, cut from the end until the frame fits.
  defp head(stream, status, headers) do
    headers =
      headers
      |> response_headers()
      |> Enum.reject(fn {name, _value} -> names_attached?(name, stream) end)
      |> Enum.map(fn {name, value} -> {name, SecretMasker.mask(value, stream.set)} end)

    sealed_head(stream, status, headers)
  end

  # A header's name is no place for the attached value, and a name is not
  # masked: one holding any form the masker knows, compared without case
  # since names arrive lowercased, is dropped, and so is the rule's own
  # header reflected back, whatever its value.
  defp names_attached?(name, stream) do
    lower = String.downcase(name)
    lower == stream.rule_header or Enum.any?(stream.forms, &String.contains?(lower, &1))
  end

  defp name_forms(set),
    do: set |> SecretMasker.forms() |> Enum.map(&String.downcase/1) |> Enum.uniq()

  defp sealed_head(stream, status, headers) do
    case seal(stream, :head, WorkerAuth.head_plaintext(status, headers)) do
      {:ok, frame} ->
        write(stream, :head, frame)

      {:error, :frame_too_large} when headers != [] ->
        sealed_head(stream, status, Enum.drop(headers, -1))
    end
  end

  defp response_headers(headers) do
    headers
    |> Enum.flat_map(fn {name, values} -> Enum.map(List.wrap(values), &{name, &1}) end)
    |> Enum.filter(fn {name, value} ->
      is_binary(name) and byte_size(name) in 1..256 and
        Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name) and is_binary(value) and
        byte_size(value) <= 8192 and String.valid?(value) and
        Regex.match?(~r/\A[^\x00-\x08\x0A-\x1F\x7F]*\z/u, value)
    end)
    |> Enum.take(128)
  end

  # A piece of body: masked with what was held back before it, and the tail
  # that could begin the attached value held back again.
  defp body(stream, data) do
    masked = SecretMasker.mask(stream.pending <> data, stream.set)
    hold = SecretMasker.pending_prefix(masked, stream.set)
    kept = byte_size(masked) - hold
    <<out::binary-size(^kept), tail::binary>> = masked

    with {:ok, stream} <- chunks(stream, out), do: {:ok, %{stream | pending: tail}}
  end

  defp chunks(stream, ""), do: {:ok, stream}

  defp chunks(stream, out) do
    size = min(byte_size(out), WorkerAuth.max_chunk_bytes())
    <<piece::binary-size(^size), rest::binary>> = out
    {:ok, frame} = seal(stream, :chunk, piece)

    with {:ok, stream} <- write(stream, :chunk, frame), do: chunks(stream, rest)
  end

  # The end: the tail masked once more, then the `end` frame.
  defp finish(stream) do
    tail = SecretMasker.mask(stream.pending, stream.set)

    with {:ok, stream} <- chunks(%{stream | pending: ""}, tail),
         {:ok, frame} <- seal(stream, :end, ""),
         {:ok, _stream} <- write(stream, :end, frame) do
      :ok
    else
      _closed -> :ok
    end
  end

  # An `error` frame ends the stream; the held tail is dropped.
  defp failed(stream, type, message) do
    plaintext = WorkerAuth.error_plaintext(type, SecretMasker.mask(message, stream.set))
    {:ok, frame} = seal(stream, :error, plaintext)

    case write(stream, :error, frame) do
      {:ok, _stream} -> :ok
      :closed -> :ok
    end
  end

  defp seal(stream, kind, plaintext) do
    WorkerAuth.seal_frame(
      stream.seal,
      :answer,
      stream.call_id,
      stream.seq,
      kind,
      plaintext,
      :crypto.strong_rand_bytes(12)
    )
  end

  defp write(stream, kind, frame) do
    case stream.emit.(frame) do
      :ok ->
        Process.put(@written, %{seq: stream.seq + 1, ended: kind in [:end, :error]})
        {:ok, %{stream | seq: stream.seq + 1}}

      {:error, _closed} ->
        :closed
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # `URI` answers an IPv6 literal without its brackets; it is named in
  # brackets, as a pin names it.
  defp host_of(%URI{host: host}) do
    host = String.downcase(host)

    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, _address} -> "[" <> host <> "]"
      {:error, _not_v6} -> host
    end
  end

  defp unbracket("[" <> rest), do: String.trim_trailing(rest, "]")
  defp unbracket(host), do: host

  defp now, do: System.system_time(:millisecond)
end
