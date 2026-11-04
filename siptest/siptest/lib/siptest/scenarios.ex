defmodule SipTest.Scenarios do
  @moduledoc "Built-in scenario catalog. Every scenario is plain script text (see SipTest.Script)."

  @phone "Phone / SIP endpoint"
  @pbx "Registrar / PBX"

  def all do
    [
      %{
        id: "options-ping",
        group: @phone,
        title: "OPTIONS ping",
        description: "Phone answers OPTIONS with 200 and advertises INVITE in Allow.",
        script: """
        send OPTIONS
        expect 200
        assert-header allow contains INVITE
        """
      },
      %{
        id: "options-max-forwards-0",
        group: @phone,
        title: "Max-Forwards: 0",
        description: "RFC 3261 16.3: a request that arrives with Max-Forwards 0 must not be processed; expect 483 (an endpoint may also answer 200).",
        script: """
        send OPTIONS max-forwards=0
        expect 483 200
        """
      },
      %{
        id: "unsupported-method",
        group: @phone,
        title: "Unknown method",
        description: "RFC 3261 8.2.1: unknown method must get 501 (or 405).",
        script: """
        send XYZZY
        expect 501 405
        """
      },
      %{
        id: "bye-unknown-dialog",
        group: @phone,
        title: "BYE outside any dialog",
        description: "RFC 3261 15.1.2: BYE for a dialog that does not exist gets 481.",
        script: """
        send BYE
        expect 481
        """
      },
      %{
        id: "invite-unknown-user",
        group: @phone,
        title: "INVITE to unknown user",
        description: "A call to a user the target does not know is rejected (404 / 480 / 484 / 603).",
        script: """
        send INVITE to=no-such-user-9
        expect 404 480 484 603 604
        """
      },
      %{
        id: "invite-bad-sdp",
        group: @phone,
        title: "INVITE with broken SDP",
        description: "Malformed SDP must be rejected (400 / 488 / 606), not answered with 200.",
        script: """
        send INVITE sdp=bad
        expect 400 488 606 415
        """
      },
      %{
        id: "invite-ringing-cancel",
        group: @phone,
        title: "INVITE -> ringing -> CANCEL",
        description: "Phone rings (180/183), accepts CANCEL with 200 and ends the INVITE with 487.",
        script: """
        send INVITE
        expect 180 183 timeout=ring
        send CANCEL
        expect 200 CANCEL
        expect 487 INVITE
        """
      },
      %{
        id: "invite-answer-bye",
        group: @phone,
        title: "Answered call, then BYE",
        description: "Answer the ringing phone (or enable auto-answer): 200 with SDP, ACK, hang up with BYE -> 200.",
        script: """
        send INVITE
        expect 200 timeout=ring
        assert-body contains m=audio
        ack
        wait 1000
        send BYE
        expect 200
        """
      },
      %{
        id: "invite-reject",
        group: @phone,
        title: "Rejected call",
        description: "Decline the call on the phone: any final 4xx/6xx answer is accepted.",
        script: """
        send INVITE
        expect 480 486 487 600 603 timeout=ring
        """
      },
      %{
        id: "phone-hangs-up",
        group: @phone,
        title: "Phone hangs up (BYE from phone)",
        description: "Answer the call, then hang up on the phone within 60 s: the tool receives BYE and answers 200.",
        script: """
        send INVITE
        expect 200 timeout=ring
        ack
        expect-request BYE timeout=60000
        """
      },
      %{
        id: "register-auth",
        group: @pbx,
        title: "REGISTER with digest auth",
        description: "REGISTER, answer the 401/407 challenge, expect 200. Needs a password (Advanced).",
        script: """
        send REGISTER
        expect 401 407 200
        auth
        expect 200
        """
      },
      %{
        id: "register-wrong-password",
        group: @pbx,
        title: "REGISTER with wrong password",
        description: "A wrong digest response must be rejected again (401/403/407).",
        script: """
        send REGISTER
        expect 401 407
        auth wrong
        expect 401 403 407
        """
      },
      %{
        id: "register-unregister",
        group: @pbx,
        title: "REGISTER then unregister",
        description: "Register, then remove the binding with Expires: 0.",
        script: """
        send REGISTER
        expect 401 407 200
        auth
        expect 200
        send REGISTER expires=0
        expect 401 407 200
        auth
        expect 200
        """
      },
      %{
        id: "pbx-call-cancel",
        group: @pbx,
        title: "Authenticated call, CANCEL while ringing",
        description: "INVITE through the PBX (answers the challenge), wait for ringing, then CANCEL.",
        script: """
        send INVITE
        expect 401 407 180 183 200 timeout=ring
        auth
        expect 180 183 timeout=ring
        send CANCEL
        expect 200 CANCEL
        expect 487 INVITE
        """
      }
    ]
  end

  def get(id), do: Enum.find(all(), fn s -> s.id == id end)

  @doc "Scenario with its parsed steps, or {:error, message}."
  def with_steps(%{script: script} = sc) do
    case SipTest.Script.parse(script) do
      {:ok, steps} -> {:ok, Map.put(sc, :steps, steps)}
      {:error, msg} -> {:error, "#{sc.id}: #{msg}"}
    end
  end

  @doc "Public view sent to the browser."
  def view(sc), do: Map.take(sc, [:id, :group, :title, :description, :script])
end
