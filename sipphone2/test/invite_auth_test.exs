defmodule SipPhone.InviteAuthTest do
  use ExUnit.Case, async: false

  alias SipPhone.{Account, Accounts}
  alias SipPhone.SIP.Message

  test "401 response is ACKed and generates a new authenticated INVITE" do
    {:ok, server} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, server_port}} = :inet.sockname(server)
    {:ok, client} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, client_port}} = :inet.sockname(client)
    :gen_udp.close(client)

    {:ok, id} = Accounts.save(%{
      "username" => "auth-test",
      "password" => "secret",
      "local_port" => client_port,
      "registrar" => ""
    })

    try do
      assert {:ok, _} = Account.call(id, "127.0.0.1:#{server_port}")
      assert {:ok, {ip, port, data}} = :gen_udp.recv(server, 0, 3_000)
      assert {:ok, invite} = Message.parse(data)
      assert invite.method == "INVITE"

      challenge = Message.response(invite, 401, "Unauthorized",
        to_tag: "pbx-tag",
        headers: [{"www-authenticate", ~s(Digest realm="pbx", nonce="challenge123", algorithm=MD5, qop="auth")}]
      )

      :ok = :gen_udp.send(server, ip, port, Message.serialize(challenge))

      assert {:ok, {_, _, ack_data}} = :gen_udp.recv(server, 0, 3_000)
      assert {:ok, ack} = Message.parse(ack_data)
      assert ack.method == "ACK"
      assert Message.header(ack, "cseq") == "1 ACK"

      assert {:ok, {_, _, auth_data}} = :gen_udp.recv(server, 0, 3_000)
      assert {:ok, authed} = Message.parse(auth_data)
      assert authed.method == "INVITE"
      assert Message.header(authed, "cseq") == "2 INVITE"
      assert Message.header(authed, "call-id") == Message.header(invite, "call-id")
      assert Message.header(authed, "via") != Message.header(invite, "via")
      assert Message.header(authed, "authorization") =~ ~s(realm="pbx")
      assert Message.header(authed, "authorization") =~ ~s(nonce="challenge123")
    after
      Accounts.delete(id)
      :gen_udp.close(server)
    end
  end
end
