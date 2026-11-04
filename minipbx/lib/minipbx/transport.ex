defmodule MiniPbx.Transport do
  @moduledoc """
  The one SIP UDP socket. Parses incoming datagrams and hands them on: REGISTER to the registrar,
  new INVITEs to a `MiniPbx.Call` process, everything else to the call that owns the Call-ID / Via branch.
  """
  use GenServer
  require Logger

  alias MiniPbx.{Auth, Call, Message, Registrar, Store}

  @allow "INVITE, ACK, CANCEL, BYE, OPTIONS, REGISTER, INFO, UPDATE"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "UDP port the PBX really listens on (useful with SIP_PORT=0)."
  def port, do: :persistent_term.get({__MODULE__, :port})

  def send_raw(bin, {ip, port}) do
    :gen_udp.send(:persistent_term.get({__MODULE__, :socket}), ip, port, bin)
  end

  @doc "Reply statelessly to `req` (sent to `src`). Options as in `Message.response/4`."
  def reply(req, src, code, reason, opts \\ []) do
    resp = Message.response(req, code, reason, Keyword.put(opts, :src, src))
    send_raw(Message.serialize(resp), src)
  end

  @doc "Address we put in Via/Contact when talking to `ip`: the configured public host or the local interface address."
  def host_for(ip) do
    case Store.settings()["public_host"] do
      h when is_binary(h) and h != "" -> h
      _ -> local_ip(ip)
    end
  end

  defp local_ip(ip) do
    with {:ok, s} <- :gen_udp.open(0, [:binary]),
         :ok <- :gen_udp.connect(s, ip, 9),
         {:ok, {local, _}} <- :inet.sockname(s) do
      :gen_udp.close(s)
      local |> :inet.ntoa() |> to_string()
    else
      _ -> "127.0.0.1"
    end
  end

  @impl true
  def init(_) do
    opts = [:binary, active: true, ip: MiniPbx.Config.sip_bind(), reuseaddr: true, recbuf: 262_144]

    case :gen_udp.open(MiniPbx.Config.sip_port(), opts) do
      {:ok, sock} ->
        {:ok, port} = :inet.port(sock)
        :persistent_term.put({__MODULE__, :socket}, sock)
        :persistent_term.put({__MODULE__, :port}, port)
        Logger.info("SIP listening on UDP #{port}")
        {:ok, %{sock: sock}}

      {:error, reason} ->
        {:stop, {:sip_listen_failed, MiniPbx.Config.sip_port(), reason}}
    end
  end

  @impl true
  def handle_info({:udp, _sock, ip, port, data}, st) do
    if byte_size(data) > 8, do: dispatch(data, {ip, port})
    {:noreply, st}
  end

  def handle_info(_, st), do: {:noreply, st}

  ## Dispatch

  defp dispatch(data, src) do
    case Message.parse(data) do
      {:ok, %{type: :response} = msg} -> to_branch(msg)
      {:ok, %{type: :request} = req} -> request(req, src)
      _ -> :ok
    end
  rescue
    e -> Logger.warning("bad SIP datagram: #{Exception.message(e)}")
  end

  defp to_branch(msg) do
    via = Message.parse_via(Message.header(msg, "via"))

    with %{branch: b} when is_binary(b) <- via,
         [{pid, _}] <- Registry.lookup(MiniPbx.CallReg, {:branch, b}) do
      send(pid, {:sip_response, msg, nil})
    end

    :ok
  end

  defp request(req, src) do
    cond do
      req.method == "REGISTER" ->
        Task.Supervisor.start_child(MiniPbx.SipSup, fn -> Registrar.handle(req, src) end)

      req.method == "OPTIONS" and Message.to_tag(req) == nil ->
        reply(req, src, 200, "OK", headers: [{"allow", @allow}])

      true ->
        call_id = Message.header(req, "call-id")

        case Registry.lookup(MiniPbx.CallReg, {:call, call_id}) do
          [{pid, _}] -> send(pid, {:sip_request, req, src})
          [] -> no_call(req, src)
        end
    end

    :ok
  end

  defp no_call(%{method: "ACK"}, _src), do: :ok

  defp no_call(%{method: "INVITE"} = req, src) do
    if Message.to_tag(req) != nil do
      reply(req, src, 481, "Call/Transaction Does Not Exist")
    else
      Task.Supervisor.start_child(MiniPbx.SipSup, fn -> admit(req, src) end)
    end
  end

  defp no_call(%{method: m} = req, src) when m in ["BYE", "CANCEL", "INFO", "UPDATE", "PRACK"],
    do: reply(req, src, 481, "Call/Transaction Does Not Exist")

  defp no_call(req, src), do: reply(req, src, 405, "Method Not Allowed", headers: [{"allow", @allow}])

  # A new INVITE: identify and authenticate the caller, then start the call process.
  defp admit(req, src) do
    {ip, _} = src
    from = Message.parse_uri(Message.addr_uri(Message.header(req, "from")))
    claimed = from && from.user

    if Store.settings()["auth_calls"] do
      ext = claimed && Store.extension(claimed)

      case Auth.check(req, "proxy-authorization", ext, ip) do
        :ok -> start_call(req, src, claimed)
        :forbidden -> reply(req, src, 403, "Forbidden", to_tag: tag())
        {:challenge, stale} ->
          reply(req, src, 407, "Proxy Authentication Required",
            to_tag: tag(),
            headers: [Auth.challenge_header(:proxy, stale)]
          )
      end
    else
      start_call(req, src, claimed || "anonymous")
    end
  end

  defp start_call(req, src, caller) do
    case DynamicSupervisor.start_child(MiniPbx.CallSup, {Call, {req, src, caller}}) do
      {:ok, _} -> :ok
      :ignore -> :ok
      {:error, _} -> reply(req, src, 500, "Server Internal Error")
    end
  end

  defp tag, do: Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)
end
