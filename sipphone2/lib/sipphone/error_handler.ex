defmodule SipPhone.ErrorHandler do
  @moduledoc """
  Erlang/Elixir Logger handler for the browser's separate runtime-error panel.
  Only error-level events are forwarded, not routine SIP traffic.
  """

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  def log(event, _config) do
    detail =
      try do
        event
        |> :logger_formatter.format(%{single_line: false, max_size: 12_000})
        |> IO.iodata_to_binary()
      rescue
        _ -> inspect(Map.get(event, :msg), limit: 30, printable_limit: 12_000)
      end

    SipPhone.Events.broadcast(%{
      type: "elixir_error",
      entry: %{ts: System.system_time(:millisecond), message: detail}
    })
  rescue
    _ -> :ok
  end
end
