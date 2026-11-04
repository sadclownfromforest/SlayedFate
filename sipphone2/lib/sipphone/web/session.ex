defmodule SipPhone.Web.Session do
  @moduledoc """
  One browser WebSocket session. Text frames carry JSON commands/events;
  binary frames carry 8 kHz s16le PCM for the call the browser has focused.
  """
  require Logger

  alias SipPhone.{Account, Accounts}
  alias SipPhone.Web.Frame

  def run(sock, initial) do
    Registry.register(SipPhone.Clients, :ui, nil)
    st = %{sock: sock, buf: initial, focus: nil, frag: nil}
    send_json(st, %{type: "snapshot", accounts: Accounts.views(), calls: Accounts.calls()})

    case process_buffer(st) do
      {:ok, st} -> loop(st)
      :close -> :gen_tcp.close(sock)
    end
  end

  defp loop(st) do
    :inet.setopts(st.sock, active: :once)

    receive do
      {:tcp, _, data} ->
        case process_buffer(%{st | buf: st.buf <> data}) do
          {:ok, st2} -> loop(st2)
          :close -> :gen_tcp.close(st.sock)
        end

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :gen_tcp.close(st.sock)

      {:event, ev} ->
        send_json(st, ev)
        loop(st)

      {:audio, cid, pcm} ->
        if cid == st.focus, do: Frame.send(st.sock, :binary, pcm)
        loop(st)
    after
      120_000 -> :gen_tcp.close(st.sock)
    end
  end

  defp process_buffer(st) do
    case Frame.decode(st.buf) do
      :more ->
        {:ok, st}

      :error ->
        :close

      {:ok, {fin, op, payload}, tail} ->
        case handle_frame(%{st | buf: tail}, fin, op, payload) do
          {:ok, st2} -> process_buffer(st2)
          :close -> :close
        end
    end
  end

  defp handle_frame(st, fin, op, payload) do
    case {op, fin} do
      {8, _} ->
        Frame.send(st.sock, :close, <<>>)
        :close

      {9, _} ->
        Frame.send(st.sock, :pong, payload)
        {:ok, st}

      {10, _} ->
        {:ok, st}

      {0, 1} ->
        case st.frag do
          {fop, acc} -> dispatch(%{st | frag: nil}, fop, acc <> payload)
          nil -> :close
        end

      {0, 0} ->
        case st.frag do
          {fop, acc} -> {:ok, %{st | frag: {fop, acc <> payload}}}
          nil -> :close
        end

      {o, 0} when o in [1, 2] ->
        {:ok, %{st | frag: {o, payload}}}

      {o, 1} when o in [1, 2] ->
        dispatch(st, o, payload)

      _ ->
        :close
    end
  end

  defp dispatch(st, 2, pcm) do
    if st.focus != nil, do: SipPhone.Media.push_pcm(st.focus, pcm)
    {:ok, st}
  end

  defp dispatch(st, 1, text) do
    case JSON.decode(text) do
      {:ok, %{} = cmd} ->
        try do
          {:ok, handle_cmd(st, cmd)}
        rescue
          e ->
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            send_json(st, %{type: "error", message: "Internal error (see Elixir Errors panel)"})
            {:ok, st}
        end

      _ ->
        {:ok, st}
    end
  end

  ## ------------------------------------------------------------------
  ## Commands

  defp handle_cmd(st, %{"type" => "ping"}), do: st

  defp handle_cmd(st, %{"type" => "save_account", "account" => params}) do
    case Accounts.save(params) do
      {:ok, _id} -> send_json(st, %{type: "saved"})
      {:error, msg} -> send_json(st, %{type: "error", message: msg})
    end

    st
  end

  defp handle_cmd(st, %{"type" => "delete_account", "id" => id}) when is_binary(id) do
    Accounts.delete(id)
    send_json(st, %{type: "saved"})
    st
  end

  defp handle_cmd(st, %{"type" => "call", "account_id" => id, "target" => target})
       when is_binary(id) and is_binary(target) do
    report(st, Account.call(id, target))
  end

  defp handle_cmd(st, %{"type" => "answer", "account_id" => id, "call_id" => cid})
       when is_binary(id) and is_binary(cid) do
    report(st, Account.answer(id, cid))
  end

  defp handle_cmd(st, %{"type" => "hangup", "account_id" => id, "call_id" => cid})
       when is_binary(id) and is_binary(cid) do
    report(st, Account.hangup(id, cid))
  end

  defp handle_cmd(st, %{"type" => "dtmf", "account_id" => id, "call_id" => cid, "digit" => d})
       when is_binary(id) and is_binary(cid) and is_binary(d) do
    report(st, Account.dtmf(id, cid, d))
  end

  defp handle_cmd(st, %{"type" => "reregister", "account_id" => id}) when is_binary(id) do
    report(st, Account.reregister(id))
  end

  defp handle_cmd(st, %{"type" => "focus", "call_id" => cid}) when is_binary(cid) or is_nil(cid),
    do: %{st | focus: cid}

  defp handle_cmd(st, %{"type" => "list_files"}) do
    send_json(st, %{type: "files", files: SipPhone.Files.list()})
    st
  end

  defp handle_cmd(st, %{"type" => "read_file", "path" => path}) do
    case SipPhone.Files.read(path) do
      {:ok, content} -> send_json(st, %{type: "file", path: path, content: content})
      {:error, msg} -> send_json(st, %{type: "error", message: msg})
    end

    st
  end

  defp handle_cmd(st, _), do: st

  defp report(st, {:error, msg}) do
    send_json(st, %{type: "error", message: msg})
    st
  end

  defp report(st, _), do: st

  defp send_json(st, map), do: Frame.send(st.sock, :text, JSON.encode!(map))
end
