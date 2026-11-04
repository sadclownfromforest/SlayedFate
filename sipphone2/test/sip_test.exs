defmodule SipPhone.SipTest do
  use ExUnit.Case, async: true

  alias SipPhone.G711
  alias SipPhone.SIP.{Digest, Message, SDP}

  @invite "INVITE sip:bob@example.com:5070 SIP/2.0\r\n" <>
            "Via: SIP/2.0/UDP 10.0.0.1:5060;rport;branch=z9hG4bKabc, SIP/2.0/UDP 10.0.0.9;branch=z9hG4bKdef\r\n" <>
            "Max-Forwards: 70\r\n" <>
            "From: \"Alice A\" <sip:alice@example.com>;tag=1928\r\n" <>
            "To: <sip:bob@example.com>\r\n" <>
            "i: call-1@10.0.0.1\r\n" <>
            "CSeq: 7 INVITE\r\n" <>
            "Contact: <sip:alice@10.0.0.1:5060>\r\n" <>
            "Content-Length: 4\r\n\r\nv=0\n"

  test "parses a request and splits multi-value Via headers" do
    assert {:ok, m} = Message.parse(@invite)
    assert m.type == :request
    assert m.method == "INVITE"
    assert m.uri == "sip:bob@example.com:5070"
    assert Message.headers(m, "via") |> length() == 2
    assert Message.header(m, "call-id") == "call-1@10.0.0.1"
    assert Message.from_tag(m) == "1928"
    assert Message.to_tag(m) == nil
    assert Message.display_name(Message.header(m, "from")) == "Alice A"
    assert Message.parse_cseq(Message.header(m, "cseq")) == {7, "INVITE"}
    assert m.body == "v=0\n"
  end

  test "parses a response and round-trips through serialize" do
    raw =
      "SIP/2.0 401 Unauthorized\r\nVia: SIP/2.0/UDP h:5070;branch=z9hG4bK1\r\n" <>
        "From: <sip:a@b>;tag=x\r\nTo: <sip:a@b>;tag=y\r\nCall-ID: c1\r\nCSeq: 2 REGISTER\r\n" <>
        "WWW-Authenticate: Digest realm=\"asterisk\", nonce=\"abc\"\r\nContent-Length: 0\r\n\r\n"

    assert {:ok, m} = Message.parse(raw)
    assert m.status == 401
    assert m.reason == "Unauthorized"
    assert {:ok, again} = m |> Message.serialize() |> Message.parse()
    assert again.status == 401
    assert Message.header(again, "www-authenticate") == Message.header(m, "www-authenticate")
  end

  test "rejects garbage and keepalives" do
    assert Message.parse("\r\n\r\n") == :error
    assert Message.parse("hello") == :error
  end

  test "builds a response with To tag and rport/received" do
    {:ok, req} = Message.parse(@invite)
    resp = Message.response(req, 180, "Ringing", to_tag: "abcd", src: {{10, 0, 0, 7}, 5099})
    assert Message.to_tag(resp) == "abcd"
    [top | _] = Message.headers(resp, "via")
    assert top =~ "rport=5099"
    assert top =~ "received=10.0.0.7"
    assert Message.header(resp, "call-id") == "call-1@10.0.0.1"
  end

  test "parse_uri" do
    assert %{user: "bob", host: "example.com", port: 5070} = Message.parse_uri("sip:bob@example.com:5070;transport=udp")
    assert %{user: nil, host: "127.0.0.1", port: 5071} = Message.parse_uri("sip:127.0.0.1:5071")
  end

  test "digest matches the RFC 2617 example" do
    params = %{
      "realm" => "testrealm@host.com",
      "nonce" => "dcd98b7102dd2f0e8b11d0f600bfb0c093",
      "qop" => "auth"
    }

    hdr = Digest.authorization(params, "Mufasa", "Circle Of Life", "GET", "/dir/index.html", "0a4f113b")
    assert hdr =~ "response=\"6629fae49393a05397450978507c4ef1\""
  end

  test "digest challenge parsing" do
    c = Digest.parse_challenge("Digest realm=\"asterisk\",nonce=\"1234\",algorithm=MD5,qop=\"auth\"")
    assert c["realm"] == "asterisk"
    assert Digest.usable?(c)
    refute Digest.usable?(Digest.parse_challenge("Digest realm=\"x\", nonce=\"1\", algorithm=SHA-256"))
  end

  test "PBX 401 challenge extracts quoted nonce, realm, and qop" do
    challenge = ~s(Digest realm="asterisk", nonce="abc123", algorithm=MD5, qop="auth,auth-int", opaque="xyz")
    params = Digest.parse_challenge(challenge)
    assert params["realm"] == "asterisk"
    assert params["nonce"] == "abc123"
    assert params["qop"] == "auth,auth-int"
    assert Digest.usable?(params)
    auth = Digest.authorization(params, "100", "secret", "INVITE", "sip:200@pbx.example")
    assert auth =~ ~s(realm="asterisk")
    assert auth =~ ~s(nonce="abc123")
    assert auth =~ "qop=auth"
    assert auth =~ ~s(uri="sip:200@pbx.example")
  end

  test "PBX 407 proxy challenge parses unquoted values" do
    params = Digest.parse_challenge("Digest realm=pbx,nonce=12345,algorithm=MD5")
    assert params == %{"realm" => "pbx", "nonce" => "12345", "algorithm" => "MD5"}
  end

  test "SDP build/parse round trip and codec choice" do
    sdp = SDP.build(%{ip: "10.1.2.3", port: 40010, payloads: [8, 0], te_pt: 101, sess_id: 42})
    parsed = SDP.parse(sdp)
    assert parsed.ip == {10, 1, 2, 3}
    assert parsed.port == 40010
    assert parsed.payloads == [8, 0]
    assert parsed.te_pt == 101
    assert SDP.choose_codec(parsed, "pcmu") == 0
    assert SDP.choose_codec(parsed, "pcma") == 8
  end

  test "G.711 round trip stays within quantisation error" do
    for codec <- [0, 8], s <- [0, 1, -1, 100, -100, 1000, -1000, 8000, -8000, 30000, -30000] do
      pcm = <<s::signed-little-16>>
      <<back::signed-little-16>> = pcm |> then(&G711.encode(codec, &1)) |> then(&G711.decode(codec, &1))
      assert abs(back - s) <= max(64, div(abs(s), 16)), "codec #{codec} sample #{s} -> #{back}"
    end
  end
end
