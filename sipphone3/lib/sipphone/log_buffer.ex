defmodule SipPhone.LogBuffer do
  @moduledoc """
  Keeps the last #{500} Elixir `Logger` lines in memory for the "Elixir log" panel and pushes new ones to the browser.

  It is an Erlang `:logger` handler (`log/2`) that only forwards the formatted line to this process, so logging never
  blocks or crashes the caller. Lines are redacted: values of password / secret / token keys (for example in a crash
  report that prints a GenServer state) are replaced by `***`.
  """
  use GenServer

  alias SipPhone.Events

  @max 500
  @max_len 4_000
  @handler :sipphone_ui_log
  @secret ~r/(password|passwd|secret|token)(["']?\s*(?:=>|:|=)\s*)("[^"]*"|'[^']*'|[^\s,}\]]+)/i

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Lines, oldest first."
  def lines, do: GenServer.call(__MODULE__, :lines)

  def clear, do: GenServer.call(__MODULE__, :clear)

  @doc "Redact secrets in a log line."
  def redact(text), do: Regex.replace(@secret, text, "\\1\\2\"***\"")

  ## :logger handler callback (runs in the logging process)

  def log(event, _config) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        try do
          send(pid, {:log, build(event)})
        rescue
          _ -> :ok
        end

        :ok
    end
  end

  defp build(%{level: level, msg: msg, meta: meta}) do
    ms =
      case meta do
        %{time: t} -> div(t, 1000)
        _ -> System.os_time(:millisecond)
      end

    text =
      msg
      |> format_msg()
      |> redact()
      |> String.slice(0, @max_len)

    %{"ts" => ms, "level" => Atom.to_string(level), "text" => text}
  end

  defp format_msg({:string, s}), do: IO.chardata_to_string(s)
  defp format_msg({:report, r}), do: inspect(r, limit: 50, printable_limit: 500)

  defp format_msg({fmt, args}) do
    fmt |> :io_lib.format(args) |> IO.chardata_to_string()
  rescue
    _ -> inspect({fmt, args})
  end

  ## Server

  @impl true
  def init(_) do
    :logger.remove_handler(@handler)
    :logger.add_handler(@handler, __MODULE__, %{level: :all})
    {:ok, []}
  end

  @impl true
  def handle_call(:lines, _from, st), do: {:reply, Enum.reverse(st), st}
  def handle_call(:clear, _from, _st), do: {:reply, :ok, []}

  @impl true
  def handle_info({:log, line}, st) do
    Events.broadcast(%{type: "applog", line: line})
    {:noreply, Enum.take([line | st], @max)}
  end

  def handle_info(_, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, _st) do
    :logger.remove_handler(@handler)
    :ok
  end
end
