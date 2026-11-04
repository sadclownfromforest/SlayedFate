defmodule MiniPbx.DialplanTest do
  use ExUnit.Case, async: true

  alias MiniPbx.Dialplan

  defp route(pattern, target, extra \\ %{}), do: Map.merge(%{"pattern" => pattern, "target" => target}, extra)

  test "patterns" do
    assert Dialplan.matches?("100", "100")
    refute Dialplan.matches?("100", "1000")
    assert Dialplan.matches?("_1XX", "123")
    refute Dialplan.matches?("_1XX", "12")
    refute Dialplan.matches?("_1XX", "1234")
    assert Dialplan.matches?("1XX", "199")
    assert Dialplan.matches?("_ZXX", "999")
    refute Dialplan.matches?("_ZXX", "099")
    assert Dialplan.matches?("_N1", "21")
    refute Dialplan.matches?("_N1", "11")
    assert Dialplan.matches?("_9.", "95551234")
    refute Dialplan.matches?("_9.", "9")
    refute Dialplan.matches?("", "1")
    refute Dialplan.matches?(nil, "1")
  end

  test "no route: number unchanged" do
    assert {:ok, "100", []} = Dialplan.resolve("100", [route("200", "300")])
  end

  test "a route rewrites the number; chains are followed" do
    routes = [route("100", "200"), route("200", "300")]
    assert {:ok, "300", ["200", "300"]} = Dialplan.resolve("100", routes)
  end

  test "first matching enabled route wins, disabled ones are skipped" do
    routes = [route("100", "111", %{"enabled" => false}), route("_1XX", "222"), route("100", "333")]
    assert {:ok, "222", ["222"]} = Dialplan.resolve("100", routes)
  end

  test "${EXTEN} is the dialed number" do
    assert {:ok, "9100", ["9100"]} = Dialplan.resolve("100", [route("_1XX", "9${EXTEN}")])
  end

  test "loops are detected" do
    assert {:error, :loop, _} = Dialplan.resolve("100", [route("100", "200"), route("200", "100")])
  end

  test "a route to itself is a no-op" do
    assert {:ok, "100", []} = Dialplan.resolve("100", [route("100", "100")])
  end
end

defmodule MiniPbx.AuthUnitTest do
  use ExUnit.Case, async: true

  alias MiniPbx.{Auth, Digest}

  test "digest: the response we compute is accepted against the stored HA1, a wrong password is not" do
    ha1 = Digest.ha1("1001", "minipbx", "secret1")
    ch = Digest.parse_challenge(Digest.challenge("minipbx", "abc123"))
    assert ch["nonce"] == "abc123" and ch["qop"] == "auth"

    good = Digest.parse_challenge(Digest.authorization(ch, "1001", "secret1", "REGISTER", "sip:pbx"))
    assert Digest.verify(good, "REGISTER", ha1)
    refute Digest.verify(good, "INVITE", ha1)

    bad = Digest.parse_challenge(Digest.authorization(ch, "1001", "nope", "REGISTER", "sip:pbx"))
    refute Digest.verify(bad, "REGISTER", ha1)
    refute Digest.verify(%{}, "REGISTER", ha1)
  end

  test "digest: a challenge can be marked stale" do
    assert Digest.challenge("r", "n", true) =~ "stale=true"
    refute Digest.challenge("r", "n") =~ "stale"
  end

  test "nonces: ours are accepted, invented ones are not" do
    n = Auth.new_nonce()
    assert Auth.nonce_state(n) == :ok
    assert Auth.nonce_state("deadbeef") == :unknown
  end

  test "too many failures from one address block it; success clears the counter" do
    ip = {10, 99, 99, 1}
    refute Auth.blocked?(ip)
    for _ <- 1..9, do: Auth.record_failure(ip)
    refute Auth.blocked?(ip)
    Auth.record_failure(ip)
    assert Auth.blocked?(ip)
    Auth.clear_failures(ip)
    refute Auth.blocked?(ip)
  end
end

defmodule MiniPbx.CdrTest do
  use ExUnit.Case, async: false

  alias MiniPbx.Cdr

  setup do
    Cdr.clear()
    :ok
  end

  test "newest first, filter and CSV with formula guard" do
    base = %{"start" => "2026-01-01T10:00:00Z", "caller" => "1001", "callee" => "1002", "target" => "1002", "disposition" => "ANSWERED", "duration" => 5, "billsec" => 3, "reason" => "x", "route" => "", "src" => "127.0.0.1"}
    Cdr.add(Map.put(base, "id", "a"))
    Cdr.add(Map.merge(base, %{"id" => "b", "caller" => "=cmd|' /C calc'!A0", "reason" => "has, comma"}))

    assert [%{"id" => "b"}, %{"id" => "a"}] = Cdr.list()
    assert [%{"id" => "a"}] = Cdr.list(q: "1001")
    assert [] = Cdr.list(q: "zzz")

    csv = Cdr.csv()
    [header | rows] = String.split(csv, "\r\n", trim: true)
    assert header =~ "start,answer,end,caller"
    assert length(rows) == 2
    assert csv =~ "'=cmd"
    assert csv =~ ~s("has, comma")
  end
end
