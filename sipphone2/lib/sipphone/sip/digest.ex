defmodule SipPhone.SIP.Digest do
  @moduledoc "HTTP Digest authentication (MD5, qop=auth) as used by SIP (RFC 3261 section 22, RFC 2617)."

  @doc "Parse a WWW-Authenticate / Proxy-Authenticate value into a map, or nil."
  def parse_challenge(value) when is_binary(value) do
    case Regex.run(~r/^\s*digest\s+(.*)$/is, value) do
      [_, rest] ->
        ~r/(\w+)\s*=\s*(?:"([^"]*)"|([^\s,]+))/
        |> Regex.scan(rest)
        |> Map.new(fn [_, key, quoted, unquoted] ->
          {String.downcase(key), if(quoted == "", do: unquoted, else: quoted)}
        end)

      _ ->
        nil
    end
  end

  def parse_challenge(_), do: nil

  @doc "True if the challenge is one we can answer (MD5 with a nonce)."
  def usable?(nil), do: false

  def usable?(params) do
    Map.has_key?(params, "nonce") and
      String.downcase(Map.get(params, "algorithm", "md5")) == "md5"
  end

  @doc "Build the value of an Authorization / Proxy-Authorization header."
  def authorization(params, user, pass, method, uri, cnonce \\ nil) do
    realm = Map.get(params, "realm", "")
    nonce = Map.fetch!(params, "nonce")

    qops =
      params |> Map.get("qop", "") |> String.split(",") |> Enum.map(&String.trim/1)

    ha1 = md5("#{user}:#{realm}:#{pass}")
    ha2 = md5("#{method}:#{uri}")

    {response, extra} =
      if "auth" in qops do
        cn = cnonce || Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
        nc = "00000001"

        {md5("#{ha1}:#{nonce}:#{nc}:#{cn}:auth:#{ha2}"),
         ", qop=auth, nc=#{nc}, cnonce=\"#{cn}\""}
      else
        {md5("#{ha1}:#{nonce}:#{ha2}"), ""}
      end

    opaque =
      case Map.get(params, "opaque") do
        nil -> ""
        o -> ", opaque=\"#{o}\""
      end

    "Digest username=\"#{user}\", realm=\"#{realm}\", nonce=\"#{nonce}\", uri=\"#{uri}\", " <>
      "response=\"#{response}\", algorithm=MD5" <> extra <> opaque
  end

  defp md5(s), do: :crypto.hash(:md5, s) |> Base.encode16(case: :lower)
end
