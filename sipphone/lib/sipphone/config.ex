defmodule SipPhone.Config do
  @moduledoc "Runtime configuration read from environment variables."

  def web_port, do: env_int("WEB_PORT", 4000)

  def web_bind do
    case System.get_env("WEB_BIND") do
      nil ->
        {127, 0, 0, 1}

      "" ->
        {127, 0, 0, 1}

      s ->
        case :inet.parse_address(String.to_charlist(s)) do
          {:ok, ip} -> ip
          _ -> {127, 0, 0, 1}
        end
    end
  end

  def data_dir, do: System.get_env("SIPPHONE_DATA") || "/data"

  def rtp_range, do: {env_int("RTP_PORT_MIN", 40000), env_int("RTP_PORT_MAX", 40039)}

  @doc "Host names the web UI answers to (DNS-rebinding / cross-site protection)."
  def allowed_hosts do
    extra =
      (System.get_env("ALLOWED_HOSTS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    ["localhost", "127.0.0.1", "[::1]"] ++ extra
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      v ->
        case Integer.parse(v) do
          {n, ""} -> n
          _ -> default
        end
    end
  end
end
