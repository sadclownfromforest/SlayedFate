defmodule SipTest.Params do
  @moduledoc "Validation and defaults for the parameters entered in the UI."

  @doc "Turn the raw (string-keyed) UI map into a validated map with atom keys."
  def normalize(m) when is_map(m) do
    {host, host_port} = split_host(text(m["host"]))
    port = int(m["port"], host_port || 5060)

    cond do
      host == "" ->
        {:error, "Enter the IP address or host name of the phone / server under test"}

      port < 1 or port > 65_535 ->
        {:error, "Port must be between 1 and 65535"}

      true ->
        {:ok,
         %{
           host: host,
           port: port,
           local_port: clamp(int(m["local_port"], 0), 0, 65_535),
           local_host: host_text(m["local_host"]),
           domain: host_text(m["domain"]),
           from_user: user(m["from_user"], "tester"),
           to_user: user(m["to_user"], "1000"),
           display: m["display"] |> text() |> String.replace(~r/["<>\\]/, ""),
           auth_user: user(m["auth_user"], ""),
           password: if(is_binary(m["password"]), do: m["password"], else: ""),
           timeout: clamp(int(m["timeout"], 5_000), 200, 120_000),
           ring_timeout: clamp(int(m["ring_timeout"], 30_000), 1_000, 300_000),
           rtp_port: clamp(int(m["rtp_port"], 40_000), 1_024, 65_534)
         }}
    end
  end

  def normalize(_), do: {:error, "Invalid parameters"}

  # "10.0.0.5:5070" typed into the host field is accepted
  defp split_host(h) do
    case Regex.run(~r/^([^:]+):(\d+)$/, h) do
      [_, host, port] -> {host_text(host), String.to_integer(port)}
      _ -> {host_text(h), nil}
    end
  end

  defp host_text(v), do: v |> text() |> String.replace(~r/[^A-Za-z0-9.\-_]/, "")
  defp user(v, default), do: v |> text() |> String.replace(~r/[\s<>";@,\\\/?]/, "") |> blank(default)
  defp blank("", default), do: default
  defp blank(v, _), do: v

  defp text(v) when is_binary(v), do: String.trim(v)
  defp text(v) when is_integer(v), do: Integer.to_string(v)
  defp text(_), do: ""

  defp int(v, default) when is_integer(v) and not is_nil(default), do: v

  defp int(v, default) do
    case Integer.parse(text(v)) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)
end
