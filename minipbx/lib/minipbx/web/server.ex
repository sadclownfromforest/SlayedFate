defmodule MiniPbx.Web.Server do
  @moduledoc "TCP listener for the web UI. Connections are served by `MiniPbx.Web.Conn`."
  use GenServer
  require Logger

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    ip = MiniPbx.Config.web_bind()
    port = MiniPbx.Config.web_port()

    opts = [
      :binary,
      active: false,
      reuseaddr: true,
      ip: ip,
      backlog: 64,
      send_timeout: 5_000,
      send_timeout_close: true
    ]

    case :gen_tcp.listen(port, opts) do
      {:ok, lsock} ->
        Logger.info("MiniPbx web UI: http://#{:inet.ntoa(ip)}:#{port}")
        {:ok, _} = Task.start_link(fn -> accept_loop(lsock) end)
        {:ok, %{lsock: lsock}}

      {:error, reason} ->
        {:stop, {:listen_failed, port, reason}}
    end
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        starter =
          Task.Supervisor.start_child(MiniPbx.ConnSup, fn ->
            receive do
              :go -> MiniPbx.Web.Conn.serve(sock)
            after
              5_000 -> :gen_tcp.close(sock)
            end
          end)

        case starter do
          {:ok, pid} ->
            :gen_tcp.controlling_process(sock, pid)
            send(pid, :go)

          _ ->
            :gen_tcp.close(sock)
        end

        accept_loop(lsock)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        Process.sleep(100)
        accept_loop(lsock)
    end
  end
end
