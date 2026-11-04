defmodule MiniPbx.Web.Session do
  @moduledoc "One browser WebSocket session: JSON commands in, JSON run events out."
  require Logger

  alias MiniPbx.{Calls, Cdr, Registrar, Store, Views}
  alias MiniPbx.Web.Frame

  def run(sock, initial) do
    Registry.register(MiniPbx.Clients, :ui, nil)
    st = %{sock: sock, buf: initial, frag: nil}

    send_json(st, %{type: "hello", data: Views.all()})

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

      {:event, %{type: "dirty", what: what}} ->
        if what in Views.areas(), do: send_json(st, %{type: "data", what: what, data: Views.snapshot(what)})
        loop(st)

      {:event, ev} ->
        send_json(st, ev)
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
          {_fop, acc} -> dispatch(%{st | frag: nil}, acc <> payload)
          nil -> :close
        end

      {0, 0} ->
        case st.frag do
          {fop, acc} -> {:ok, %{st | frag: {fop, acc <> payload}}}
          nil -> :close
        end

      {1, 0} ->
        {:ok, %{st | frag: {1, payload}}}

      {1, 1} ->
        dispatch(st, payload)

      _ ->
        :close
    end
  end

  defp dispatch(st, text) do
    case JSON.decode(text) do
      {:ok, %{} = cmd} ->
        try do
          handle_cmd(st, cmd)
        rescue
          e ->
            Logger.error(Exception.format(:error, e, __STACKTRACE__))
            send_json(st, %{type: "error", message: "Internal error"})
        end

        {:ok, st}

      _ ->
        {:ok, st}
    end
  end

  defp handle_cmd(_st, %{"type" => "ping"}), do: :ok

  defp handle_cmd(st, %{"type" => "save_extension", "ext" => %{} = ext}), do: result(st, Store.save_extension(ext), "Extension saved")

  defp handle_cmd(st, %{"type" => "delete_extension", "number" => n}) when is_binary(n) do
    result(st, Store.delete_extension(n), "Extension deleted")
    Registrar.remove(n)
  end

  defp handle_cmd(st, %{"type" => "save_route", "route" => %{} = r}), do: result(st, Store.save_route(r), "Route saved")
  defp handle_cmd(st, %{"type" => "delete_route", "id" => id}) when is_binary(id), do: result(st, Store.delete_route(id), "Route deleted")

  defp handle_cmd(st, %{"type" => "move_route", "id" => id, "dir" => dir}) when is_binary(id) and dir in ["up", "down"],
    do: result(st, Store.move_route(id, dir), nil)

  defp handle_cmd(st, %{"type" => "save_settings", "settings" => %{} = s}), do: result(st, Store.save_settings(s), "Settings saved")

  defp handle_cmd(st, %{"type" => "hangup", "id" => id}) when is_binary(id) do
    case Calls.hangup(id) do
      :ok -> :ok
      _ -> send_json(st, %{type: "error", message: "That call has already ended."})
    end
  end

  defp handle_cmd(st, %{"type" => "unregister", "number" => n}) when is_binary(n), do: result(st, Registrar.remove(n), "Phone unregistered")
  defp handle_cmd(st, %{"type" => "clear_cdr"}), do: result(st, Cdr.clear(), "Call log cleared")
  defp handle_cmd(_st, _), do: :ok

  defp result(st, {:error, msg}, _ok), do: send_json(st, %{type: "error", message: msg})
  defp result(_st, _ok, nil), do: :ok
  defp result(st, _ok, msg), do: send_json(st, %{type: "ok", message: msg})

  defp send_json(st, map), do: Frame.send(st.sock, :text, JSON.encode!(map))
end
