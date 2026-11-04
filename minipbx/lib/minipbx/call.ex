defmodule MiniPbx.Call do
  @moduledoc """
  One call = one process: a back-to-back user agent (B2BUA) with two dialogs.

      caller  <--leg a-->  PBX  <--leg b-->  callee

  The PBX answers the caller's INVITE itself, resolves the number (routes, forwards), checks that the target is
  registered and not busy, and sends its own INVITE to the callee's registered address. Provisional and final
  responses are relayed, the SDP is passed through unchanged (media flows phone to phone), BYE/CANCEL/re-INVITE
  are relayed, and a CDR is written when the call ends.

  Leg state is a map: `call_id, local_tag, local_hdr, remote_hdr, remote_uri, dest, cseq_out` (+ transaction
  bookkeeping on leg b). Timers: INVITE retransmission (T1 doubling to T2), ring timeout, retransmission of our
  final response to the caller until its ACK (RFC 3261 17.2.1).
  """
  use GenServer, restart: :temporary

  alias MiniPbx.{Cdr, Dialplan, Events, Message, Store, Transport}

  @t1 500
  @t2 4_000
  @tx_timeout 32_000
  @linger 6_000
  @allow "INVITE, ACK, CANCEL, BYE, OPTIONS, INFO, UPDATE"

  def start_link({req, src, caller}), do: GenServer.start_link(__MODULE__, {req, src, caller})

  @doc "Hang up a call from the web UI."
  def admin_hangup(id) do
    case Registry.lookup(MiniPbx.CallReg, {:id, id}) do
      [{pid, _}] -> GenServer.cast(pid, :admin_hangup)
      [] -> {:error, :not_found}
    end
  end

  ## ------------------------------------------------------------------
  ## Start

  @impl true
  def init({req, src, caller}) do
    call_id = Message.header(req, "call-id")

    case Registry.register(MiniPbx.CallReg, {:call, call_id}, nil) do
      {:ok, _} -> {:ok, setup(req, src, caller, call_id)}
      {:error, _} -> :ignore
    end
  end

  defp setup(req, src, caller, call_id) do
    id = rand(5)
    Registry.register(MiniPbx.CallReg, {:id, id}, nil)

    contact = Message.addr_uri(Message.header(req, "contact")) || Message.addr_uri(Message.header(req, "from")) || ""
    ptag = rand(5)
    caller_ext = Store.extension(caller)

    dialed =
      case Message.parse_uri(req.uri) do
        %{user: u} when is_binary(u) -> u
        _ -> ""
      end

    st = %{
      id: id,
      status: :routing,
      hops: 0,
      trail: [],
      dialed: dialed,
      caller: caller,
      caller_name: (caller_ext && caller_ext["name"]) || "",
      a_req: req,
      a_src: src,
      a: %{
        call_id: call_id,
        local_tag: ptag,
        local_hdr: (Message.header(req, "to") || "") <> ";tag=" <> ptag,
        remote_hdr: Message.header(req, "from") || "",
        remote_uri: contact,
        dest: registrar_dest(contact, src),
        cseq_out: 100
      },
      b: nil,
      txs: %{},
      seen: MapSet.new(),
      claimed: [],
      target: nil,
      target_ext: nil,
      t_start: DateTime.utc_now(),
      answered_at: nil,
      last_resp: nil,
      final_tx: nil
    }

    Registry.register(MiniPbx.CallReg, {:active, id}, active_info(st))
    send(self(), :route)
    st
  end

  defp registrar_dest(contact, src), do: MiniPbx.Registrar.dest_for(contact, src)

  ## ------------------------------------------------------------------
  ## Messages

  @impl true
  def handle_info(:route, st) do
    st = send_a(st, 100, "Trying")
    {_, st} = claim(st, st.caller)
    {:noreply, go_dial(st, st.dialed, [])}
  end

  def handle_info({:sip_request, msg, src}, st) do
    side = if Message.header(msg, "call-id") == st.a.call_id, do: :a, else: :b
    {:noreply, on_request(st, side, msg, src)}
  end

  def handle_info({:sip_response, msg, _}, st) do
    branch = (Message.parse_via(Message.header(msg, "via")) || %{})[:branch]
    {_, method} = Message.parse_cseq(Message.header(msg, "cseq"))

    st =
      case Map.get(st.txs, branch) do
        %{kind: :invite_b} when method == "INVITE" ->
          if st.b != nil and st.b.branch == branch, do: on_invite_resp(st, msg), else: st

        %{kind: :relay} = tx ->
          on_relay_resp(st, tx, msg)

        _ ->
          st
      end

    {:noreply, st}
  end

  def handle_info({:ring_timeout, branch}, st) do
    b = st.b

    st =
      if b != nil and b.branch == branch and not b.final and b.cancelling == nil,
        do: cancel_b(st, :noanswer),
        else: st

    {:noreply, st}
  end

  def handle_info({:cancel_guard, branch}, st) do
    b = st.b

    st =
      if b != nil and b.branch == branch and not b.final do
        st = %{st | b: %{b | final: true}}
        if b.cancelling == :noanswer, do: after_noanswer(st), else: st
      else
        st
      end

    {:noreply, st}
  end

  def handle_info({:inv_retx, branch, interval, elapsed}, st) do
    b = st.b
    now = elapsed + interval

    st =
      cond do
        b == nil or b.branch != branch or b.prov or b.final ->
          st

        now >= @tx_timeout ->
          st = %{st | b: %{b | final: true}}
          forward_or_fail(st, st.target_ext, "unreachable", 480, "Temporarily Unavailable", "FAILED", "phone did not respond")

        true ->
          Transport.send_raw(b.bin, b.dest)
          next = min(interval * 2, @t2)
          Process.send_after(self(), {:inv_retx, branch, next, now}, next)
          st
      end

    {:noreply, st}
  end

  def handle_info({:final_retx, interval, elapsed}, st) do
    now = elapsed + interval

    st =
      case st.final_tx do
        nil ->
          st

        tx when now >= @tx_timeout ->
          st = %{st | final_tx: nil}

          if tx.code in 200..299 and st.status == :answered do
            st = st |> bye(:a) |> bye(:b)
            finish(st, "FAILED", "no ACK for the 200 OK")
          else
            st
          end

        tx ->
          Transport.send_raw(tx.bin, st.a_src)
          next = min(interval * 2, @t2)
          Process.send_after(self(), {:final_retx, next, now}, next)
          st
      end

    {:noreply, st}
  end

  def handle_info(:stop, st), do: {:stop, :normal, st}
  def handle_info(_, st), do: {:noreply, st}

  @impl true
  def handle_cast(:admin_hangup, st) do
    st =
      case st.status do
        :answered ->
          st |> bye(:a) |> bye(:b) |> finish("ANSWERED", "hung up from the web UI")

        s when s in [:routing, :calling, :ringing] ->
          st = cancel_b(st, :admin)
          st = final_a(st, 487, "Request Terminated", [], "")
          finish(st, "NO ANSWER", "hung up from the web UI")

        _ ->
          st
      end

    {:noreply, st}
  end

  ## ------------------------------------------------------------------
  ## Routing

  defp go_dial(st, number, trail) do
    st = %{st | hops: st.hops + 1, trail: trail}

    if st.hops > Dialplan.max_hops() do
      fail(st, 482, "Loop Detected", "FAILED", "routing loop")
    else
      case resolve_target(number, trail, 0) do
        {:ok, ext, trail} -> dial_ext(%{st | trail: trail}, ext)
        {:error, :loop, trail} -> fail(%{st | trail: trail}, 482, "Loop Detected", "FAILED", "routing loop")
        {:error, :not_found, trail} -> fail(%{st | trail: trail}, 404, "Not Found", "FAILED", "no such number")
      end
    end
  end

  # Routes first, then the extension's unconditional forward; repeated until nothing changes.
  defp resolve_target(number, trail, depth) do
    case Dialplan.resolve(number, Store.routes()) do
      {:error, :loop, t} ->
        {:error, :loop, trail ++ Enum.map(t, &"route:#{&1}")}

      {:ok, n, t} ->
        trail = trail ++ Enum.map(t, &"route:#{&1}")

        case Store.extension(n) do
          nil ->
            {:error, :not_found, trail}

          ext ->
            fwd = ext["forward_always"] || ""

            cond do
              fwd == "" -> {:ok, ext, trail}
              depth >= Dialplan.max_hops() -> {:error, :loop, trail}
              true -> resolve_target(fwd, trail ++ ["forward-always:#{fwd}"], depth + 1)
            end
        end
    end
  end

  defp dial_ext(st, ext) do
    num = ext["number"]

    case claim(st, num) do
      {:busy, st} ->
        forward_or_fail(st, ext, "busy", 486, "Busy Here", "BUSY", "busy")

      {:ok, st} ->
        case MiniPbx.Registrar.lookup(num) do
          nil ->
            forward_or_fail(st, ext, "unreachable", 480, "Temporarily Unavailable", "FAILED", "not registered")

          reg ->
            send_invite(st, ext, reg)
        end
    end
  end

  defp forward_or_fail(st, ext, kind, code, reason, disp, why) do
    fwd = ext["forward_" <> kind] || ""
    st = release(st, ext["number"])

    if fwd != "",
      do: go_dial(st, fwd, st.trail ++ ["forward-#{kind}:#{fwd}"]),
      else: fail(st, code, reason, disp, why)
  end

  defp after_noanswer(st),
    do: forward_or_fail(st, st.target_ext, "noanswer", 480, "Temporarily Unavailable", "NO ANSWER", "no answer")

  defp fail(st, code, reason, disp, why) do
    st = final_a(st, code, reason, [], "")
    finish(st, disp, why)
  end

  # "Busy" = the extension is in a call or being rung. Registry keys are unique, so the claim is atomic.
  defp claim(st, num) do
    case Registry.register(MiniPbx.CallReg, {:busy, num}, nil) do
      {:ok, _} ->
        {:ok, %{st | claimed: [num | st.claimed]}}

      {:error, {:already_registered, pid}} ->
        if pid == self(), do: {:ok, st}, else: {:busy, st}
    end
  end

  defp release(st, num) do
    if num in st.claimed and num != st.caller do
      Registry.unregister(MiniPbx.CallReg, {:busy, num})
      %{st | claimed: List.delete(st.claimed, num)}
    else
      st
    end
  end

  ## ------------------------------------------------------------------
  ## Leg b (towards the callee)

  defp send_invite(st, ext, reg) do
    num = ext["number"]
    {dip, _} = reg.dest
    host = Transport.host_for(dip)
    branch = new_branch()
    ftag = rand(5)
    call_id = rand(12) <> "@minipbx"
    name = if st.caller_name != "", do: ~s("#{st.caller_name}" ), else: ""
    from = "#{name}<sip:#{st.caller}@#{host}>;tag=#{ftag}"
    to = "<sip:#{num}@#{host}>"

    headers =
      [
        {"via", via(host, branch)},
        {"max-forwards", "70"},
        {"from", from},
        {"to", to},
        {"call-id", call_id},
        {"cseq", "1 INVITE"},
        {"contact", contact(host)},
        {"allow", @allow},
        {"user-agent", "MiniPbx"}
      ] ++ ct_headers(st.a_req)

    invite = Message.request("INVITE", reg.contact, headers, st.a_req.body)
    bin = Message.serialize(invite)
    Transport.send_raw(bin, reg.dest)

    Registry.register(MiniPbx.CallReg, {:call, call_id}, nil)
    Registry.register(MiniPbx.CallReg, {:branch, branch}, nil)
    Process.send_after(self(), {:ring_timeout, branch}, Store.settings()["ring_timeout"] * 1000)
    Process.send_after(self(), {:inv_retx, branch, @t1, 0}, @t1)

    b = %{
      call_id: call_id,
      local_tag: ftag,
      local_hdr: from,
      remote_hdr: to,
      remote_uri: reg.contact,
      dest: reg.dest,
      cseq_out: 1,
      branch: branch,
      invite: invite,
      bin: bin,
      prov: false,
      final: false,
      cancelling: nil
    }

    publish(%{st | b: b, target: num, target_ext: ext, status: :calling, txs: Map.put(st.txs, branch, %{kind: :invite_b})})
  end

  defp on_invite_resp(st, msg) do
    code = msg.status

    cond do
      code == 100 -> %{st | b: %{st.b | prov: true}}
      code < 200 -> provisional(st, msg)
      code < 300 -> answered(st, msg)
      true -> rejected(st, msg)
    end
  end

  defp provisional(st, msg) do
    b = %{st.b | prov: true, remote_hdr: tagged(msg, st.b.remote_hdr)}
    st = %{st | b: b}

    if st.status in [:calling, :ringing] and b.cancelling == nil do
      st = send_a(st, msg.status, msg.reason, contact_a(st) ++ ct_headers(msg), msg.body)
      publish(%{st | status: :ringing})
    else
      st
    end
  end

  defp answered(st, msg) do
    b = st.b

    if b.final do
      # Retransmitted 200: our ACK was lost.
      ack_2xx(b)
      st
    else
      b = %{
        b
        | final: true,
          prov: true,
          remote_hdr: tagged(msg, b.remote_hdr),
          remote_uri: Message.addr_uri(Message.header(msg, "contact")) || b.remote_uri
      }

      st = %{st | b: b}
      ack_2xx(b)

      cond do
        b.cancelling != nil ->
          # We already gave up on this phone (or the caller hung up): end the late dialog.
          st = bye(st, :b)
          if b.cancelling == :noanswer, do: after_noanswer(st), else: st

        st.status == :ended ->
          bye(st, :b)

        true ->
          st = final_a(st, 200, "OK", contact_a(st) ++ ct_headers(msg), msg.body)
          publish(%{st | status: :answered, answered_at: DateTime.utc_now()})
      end
    end
  end

  defp rejected(st, msg) do
    b = st.b
    ack_non2xx(b, msg)

    if b.final do
      st
    else
      st = %{st | b: %{b | final: true}}
      code = msg.status
      ext = st.target_ext

      cond do
        b.cancelling == :noanswer ->
          after_noanswer(st)

        b.cancelling != nil ->
          st

        code in [486, 600, 603] ->
          forward_or_fail(st, ext, "busy", code, msg.reason, "BUSY", "busy (#{code})")

        code in [404, 408, 480, 503] ->
          forward_or_fail(st, ext, "unreachable", code, msg.reason, "FAILED", "phone answered #{code} #{msg.reason}")

        true ->
          fail(st, code, msg.reason, "FAILED", "phone answered #{code} #{msg.reason}")
      end
    end
  end

  defp cancel_b(st, who) do
    b = st.b

    if b != nil and not b.final and b.cancelling == nil do
      inv = b.invite

      cancel =
        Message.request(
          "CANCEL",
          inv.uri,
          [
            {"via", Message.header(inv, "via")},
            {"max-forwards", "70"},
            {"from", Message.header(inv, "from")},
            {"to", Message.header(inv, "to")},
            {"call-id", b.call_id},
            {"cseq", "1 CANCEL"}
          ],
          ""
        )

      Transport.send_raw(Message.serialize(cancel), b.dest)
      Process.send_after(self(), {:cancel_guard, b.branch}, 4_000)
      %{st | b: %{b | cancelling: who}}
    else
      st
    end
  end

  defp ack_2xx(b) do
    ack = build_request(b, "ACK", 1, [], "", new_branch())
    Transport.send_raw(Message.serialize(ack), b.dest)
  end

  defp ack_non2xx(b, msg) do
    inv = b.invite

    ack =
      Message.request(
        "ACK",
        inv.uri,
        [
          {"via", Message.header(inv, "via")},
          {"max-forwards", "70"},
          {"from", Message.header(inv, "from")},
          {"to", Message.header(msg, "to")},
          {"call-id", b.call_id},
          {"cseq", "1 ACK"}
        ],
        ""
      )

    Transport.send_raw(Message.serialize(ack), b.dest)
  end

  ## ------------------------------------------------------------------
  ## Requests from either phone

  defp on_request(%{status: :ended} = st, side, msg, src) do
    cond do
      msg.method == "ACK" ->
        if side == :a, do: %{st | final_tx: nil}, else: st

      msg.method == "INVITE" and side == :a and Message.to_tag(msg) == nil ->
        if st.last_resp, do: Transport.send_raw(st.last_resp, src)
        st

      msg.method in ["BYE", "CANCEL"] ->
        reply(st, side, msg, src, 200, "OK")
        st

      true ->
        reply(st, side, msg, src, 481, "Call/Transaction Does Not Exist")
        st
    end
  end

  defp on_request(st, side, %{method: "ACK"}, _src), do: if(side == :a, do: %{st | final_tx: nil}, else: st)

  defp on_request(st, side, %{method: "INVITE"} = msg, src) do
    cond do
      side == :a and Message.to_tag(msg) == nil ->
        # Retransmission of the original INVITE: repeat our latest response.
        if st.last_resp, do: Transport.send_raw(st.last_resp, src)
        st

      st.status == :answered ->
        relay(st, side, msg, src)

      true ->
        reply(st, side, msg, src, 491, "Request Pending")
        st
    end
  end

  defp on_request(st, :a, %{method: "CANCEL"} = msg, src) do
    reply(st, :a, msg, src, 200, "OK")

    if st.status in [:routing, :calling, :ringing] do
      st = cancel_b(st, :caller)
      st = final_a(st, 487, "Request Terminated", [], "")
      finish(st, "NO ANSWER", "cancelled by caller")
    else
      st
    end
  end

  defp on_request(st, side, %{method: "BYE"} = msg, src) do
    if st.status == :answered do
      reply(st, side, msg, src, 200, "OK")
      st = bye(st, other(side))
      finish(st, "ANSWERED", if(side == :a, do: "caller hung up", else: "callee hung up"))
    else
      reply(st, side, msg, src, 481, "Call/Transaction Does Not Exist")
      st
    end
  end

  defp on_request(st, side, %{method: "UPDATE"} = msg, src) do
    if st.status == :answered do
      relay(st, side, msg, src)
    else
      reply(st, side, msg, src, 481, "Call/Transaction Does Not Exist")
      st
    end
  end

  defp on_request(st, side, %{method: m} = msg, src) when m in ["INFO", "OPTIONS"] do
    reply(st, side, msg, src, 200, "OK")
    st
  end

  defp on_request(st, side, msg, src) do
    reply(st, side, msg, src, 501, "Not Implemented")
    st
  end

  defp reply(st, side, msg, src, code, reason) do
    tag = if side == :b and st.b != nil, do: st.b.local_tag, else: st.a.local_tag
    Transport.reply(msg, src, code, reason, to_tag: tag)
  end

  # Relay a mid-dialog request (re-INVITE for hold/resume, UPDATE) to the other phone.
  defp relay(st, from, msg, src) do
    key = {from, Message.header(msg, "cseq"), Message.header(msg, "via")}

    if MapSet.member?(st.seen, key) do
      st
    else
      to = other(from)
      l = Map.fetch!(st, to)
      n = l.cseq_out + 1
      branch = new_branch()
      extra = [{"contact", contact(Transport.host_for(elem(l.dest, 0)))}] ++ ct_headers(msg)
      req = build_request(l, msg.method, n, extra, msg.body, branch)
      Transport.send_raw(Message.serialize(req), l.dest)
      Registry.register(MiniPbx.CallReg, {:branch, branch}, nil)

      tx = %{kind: :relay, from: from, to: to, orig: msg, src: src, cseq: n, method: msg.method, branch: branch}

      st
      |> Map.put(to, %{l | cseq_out: n})
      |> Map.put(:txs, Map.put(st.txs, branch, tx))
      |> Map.put(:seen, MapSet.put(st.seen, key))
    end
  end

  defp on_relay_resp(st, _tx, %{status: 100}), do: st

  defp on_relay_resp(st, tx, msg) do
    code = msg.status
    lf = Map.fetch!(st, tx.from)
    extra = [{"contact", contact(Transport.host_for(elem(lf.dest, 0)))}] ++ ct_headers(msg)

    resp =
      Message.response(tx.orig, code, msg.reason, to_tag: lf.local_tag, src: tx.src, headers: extra, body: msg.body)

    Transport.send_raw(Message.serialize(resp), tx.src)

    if code >= 200 do
      if tx.method == "INVITE" do
        lt = Map.fetch!(st, tx.to)
        branch = if code < 300, do: new_branch(), else: tx.branch
        Transport.send_raw(Message.serialize(build_request(lt, "ACK", tx.cseq, [], "", branch)), lt.dest)
      end

      %{st | txs: Map.delete(st.txs, tx.branch)}
    else
      st
    end
  end

  ## ------------------------------------------------------------------
  ## Sending helpers

  defp bye(st, side) do
    case Map.get(st, side) do
      nil ->
        st

      l ->
        n = l.cseq_out + 1
        Transport.send_raw(Message.serialize(build_request(l, "BYE", n, [], "", new_branch())), l.dest)
        Map.put(st, side, %{l | cseq_out: n})
    end
  end

  defp build_request(l, method, cseq, extra, body, branch) do
    host = Transport.host_for(elem(l.dest, 0))

    headers =
      [
        {"via", via(host, branch)},
        {"max-forwards", "70"},
        {"from", l.local_hdr},
        {"to", l.remote_hdr},
        {"call-id", l.call_id},
        {"cseq", "#{cseq} #{method}"}
      ] ++ extra

    Message.request(method, l.remote_uri, headers, body)
  end

  defp send_a(st, code, reason, headers \\ [], body \\ "") do
    resp =
      Message.response(st.a_req, code, reason, to_tag: st.a.local_tag, src: st.a_src, headers: headers, body: body)

    bin = Message.serialize(resp)
    Transport.send_raw(bin, st.a_src)
    %{st | last_resp: bin}
  end

  # A final response to the caller's INVITE; retransmitted until the ACK arrives.
  defp final_a(st, code, reason, headers, body) do
    st = send_a(st, code, reason, headers, body)
    Process.send_after(self(), {:final_retx, @t1, 0}, @t1)
    %{st | final_tx: %{bin: st.last_resp, code: code}}
  end

  defp contact_a(st), do: [{"contact", contact(Transport.host_for(elem(st.a_src, 0)))}]

  defp contact(host), do: "<sip:pbx@#{host}:#{Transport.port()}>"
  defp via(host, branch), do: "SIP/2.0/UDP #{host}:#{Transport.port()};branch=#{branch};rport"

  defp ct_headers(msg) do
    case Message.header(msg, "content-type") do
      nil -> []
      ct -> if msg.body == "", do: [], else: [{"content-type", ct}]
    end
  end

  defp tagged(msg, old), do: if(Message.to_tag(msg) != nil, do: Message.header(msg, "to"), else: old)

  defp other(:a), do: :b
  defp other(:b), do: :a

  defp new_branch, do: "z9hG4bK" <> rand(8)
  defp rand(n), do: Base.encode16(:crypto.strong_rand_bytes(n), case: :lower)

  ## ------------------------------------------------------------------
  ## End of call, CDR, live view

  defp finish(%{status: :ended} = st, _disp, _why), do: st

  defp finish(st, disp, why) do
    now = DateTime.utc_now()
    answered = st.answered_at
    {ip, _} = st.a_src

    Cdr.add(%{
      "id" => st.id,
      "start" => iso(st.t_start),
      "answer" => answered && iso(answered),
      "end" => iso(now),
      "caller" => st.caller,
      "caller_name" => st.caller_name,
      "callee" => st.dialed,
      "target" => st.target || "",
      "disposition" => disp,
      "duration" => DateTime.diff(now, st.t_start),
      "billsec" => if(answered, do: DateTime.diff(now, answered), else: 0),
      "route" => Enum.join(st.trail, " > "),
      "reason" => why,
      "src" => ip |> :inet.ntoa() |> to_string()
    })

    for n <- st.claimed, do: Registry.unregister(MiniPbx.CallReg, {:busy, n})
    Registry.unregister(MiniPbx.CallReg, {:active, st.id})
    Events.broadcast(%{type: "dirty", what: "calls"})
    Process.send_after(self(), :stop, if(st.final_tx, do: @tx_timeout + 2_000, else: @linger))
    %{st | status: :ended, claimed: []}
  end

  defp iso(dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp publish(st) do
    Registry.update_value(MiniPbx.CallReg, {:active, st.id}, fn _ -> active_info(st) end)
    Events.broadcast(%{type: "dirty", what: "calls"})
    st
  end

  defp active_info(st) do
    %{
      "id" => st.id,
      "caller" => st.caller,
      "caller_name" => st.caller_name,
      "callee" => st.dialed,
      "target" => st.target || "",
      "state" => state_name(st.status),
      "started" => iso(st.t_start),
      "answered" => st.answered_at && iso(st.answered_at)
    }
  end

  defp state_name(:answered), do: "talking"
  defp state_name(s), do: Atom.to_string(s)
end
