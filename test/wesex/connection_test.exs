defmodule Wesex.ConnectionTest do
  use ExUnit.Case, async: true
  alias Wesex.Connection

  defmodule MockCallbacks do
    @behaviour Connection
    def init, do: []
    @impl true
    def handle_connected(state), do: {:ok, [:connected | state], []}
    @impl true
    def handle_message({:text, "reply to this twice"} = msg, callback_state, status) do
      replies = [
        {:text, "reply 1", make_ref()},
        {:text, "reply 2 bad", make_ref()}
      ]

      {:ok, [{:received, msg, status} | callback_state], replies}
    end

    def handle_message({:binary, "do stop 1001"} = msg, callback_state, status) do
      {{:stop, 1001, nil}, [{:received, msg, status} | callback_state], []}
    end

    def handle_message(msg, callback_state, status) do
      {:ok, [{:received, msg, status} | callback_state], []}
    end

    @impl true
    def handle_message_sent({:sent, ref}, callback_state, open_state) do
      {:ok, [{:message_confirm, ref, open_state} | callback_state], []}
    end

    def handle_message_sent({:send_error, ref, reason}, callback_state, open_state) do
      {:ok, [{:message_error, ref, reason, open_state} | callback_state], []}
    end
  end

  defmodule MockAdapter do
    @behaviour Wesex.Adapter
    def init, do: []
    @impl true
    def connect(url, _headers, _opts) do
      {:ok, [{:connected, url}]}
    end

    @impl true
    def event(_state, _raw_event) do
      raise "not implemented"
    end

    @impl true
    def send(state, {:text, "reply 2 bad"} = msg) do
      {:error, [{:sent, msg} | state], [], :mock_reason}
    end

    def send(state, msg) do
      {:ok, [{:sent, msg} | state], []}
    end

    @impl true
    def abort(state) do
      {[:tcp_closed | state], [:tcp_close]}
    end

    @impl true
    def send_ping(state) do
      {[:sent_ping | state], []}
    end

    @impl true
    def send_pong(state, data) do
      {[{:sent_pong, data} | state], []}
    end

    @impl true
    def local_close(state, {code, reason}) do
      {[{:sent_close, code, reason} | state], []}
    end
  end

  @mock_callbacks MockCallbacks
  @mock_adapter MockAdapter

  # [*] --> handshaking: connect/4
  # 1) handshaking --> closed: handshake timeout
  # 2) handshaking --> open
  # 3) open --> closing: ping timeout
  # 4) open --> closing: remote close
  # 5) open --> closing: close/3
  # 6) handshaking --> closing: close/3
  # 7) handshaking --> closed: tcp close
  # 8) open --> closed: tcp close
  # 9) closing --> closed: tcp close
  # 10) closing --> closed: close timeout

  setup do
    connection = %Connection{
      callbacks: @mock_callbacks,
      callback_state: @mock_callbacks.init(),
      status: :handshaking,
      adapter: @mock_adapter,
      adapter_state: @mock_adapter.init(),
      # timer: nil,
      ref: make_ref(),
      remote_stop_code_reason: nil
    }

    %{connection: connection}
  end

  defp add_timer(connection, timer_type, time \\ 5_000) do
    timer = Process.send_after(self(), {connection.ref, timer_type}, time)
    %Connection{connection | timer: {timer, timer_type}}
  end

  test "connect/5" do
    assert {:ok, connection} =
             Connection.connect(
               @mock_adapter,
               {@mock_callbacks, @mock_callbacks.init()},
               "wss://foo.test/bar?baz=123",
               [],
               []
             )

    uri = URI.new!("wss://foo.test/bar?baz=123")

    assert %Connection{
             adapter: @mock_adapter,
             adapter_state: [{:connected, ^uri}],
             callbacks: @mock_callbacks,
             callback_state: [],
             ref: ref,
             status: :handshaking,
             timer: {timer, :handshake_timeout}
           } = connection

    assert is_reference(ref)
    assert_in_delta Process.read_timer(timer), 4000, 10
  end

  test "send/2", %{connection: connection} do
    connection =
      %Connection{connection | status: {:open, :unponged}}
      |> add_timer(:ping_timer)

    assert {:ok, connection} =
             Connection.send(
               connection,
               {:binary, "foo"}
             )

    assert connection.status == {:open, :unponged}
    assert connection.callback_state == []
    assert connection.adapter_state == [{:sent, {:binary, "foo"}}]
  end

  describe "do_events/2" do
    # 2
    test "transitions from handshaking to open on :handshake_complete", %{connection: connection} do
      connection = add_timer(connection, :handshake_timeout)

      connection = Connection.do_events(connection, [:handshake_complete])
      assert connection.status == {:open, :ponged}
      assert {_ping_timer, :ping_timer} = connection.timer
      ref = connection.ref
      assert_receive {^ref, :ping_timer}, 10
      assert connection.callback_state == [:connected]
    end

    # 1
    test "transitions to closed on handshake timeout", %{connection: connection} do
      connection = add_timer(connection, :handshake_timeout)
      connection = Connection.do_events(connection, [:handshake_timeout])

      assert connection.status == :closed
      assert connection.timer == nil
      assert connection.callback_state == []
      assert connection.adapter_state == [:tcp_closed]
    end

    # 3
    test "transitions from unponged to local_closing on ping timeout", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :unponged}}
        |> add_timer(:ping_timer)

      # Timer is sent
      _ = connection.timer |> elem(0) |> Process.cancel_timer()

      connection = Connection.do_events(connection, [:ping_timer])
      assert connection.status == :local_closing
      assert connection.callback_state == []
      assert connection.adapter_state == [{:sent_close, 1002, "ping timeout"}]
    end

    # 4
    for ponged <- [:ponged, :unponged] do
      @ponged ponged
      test "transitions from open,#{@ponged} to waiting_tcp_close on remote close",
           %{connection: connection} do
        connection =
          %Connection{connection | status: {:open, @ponged}}
          |> add_timer(:ping_timer)

        connection = Connection.do_events(connection, [{:close, 1000, "normal closure"}])
        assert connection.status == :waiting_tcp_close
        assert connection.adapter_state == [{:sent_close, 1000, nil}]
        assert connection.callback_state == []
      end

      test "handles message event in open,#{@ponged} state", %{connection: connection} do
        connection = %Connection{connection | status: {:open, @ponged}}
        connection = Connection.do_events(connection, [{:text, "foo"}])
        assert connection.status == {:open, @ponged}
        assert connection.callback_state == [{:received, {:text, "foo"}, :open}]
      end
    end

    test "handles stop response from msg in open state", %{connection: connection} do
      connection = %Connection{connection | status: {:open, :ponged}} |> add_timer(:ping_timer)
      {old_timer, :ping_timer} = connection.timer
      connection = Connection.do_events(connection, [{:binary, "do stop 1001"}])
      assert connection.status == :local_closing
      assert {timer, :close_timeout} = connection.timer
      assert_in_delta Process.read_timer(timer), 4_000, 100
      assert not Process.read_timer(old_timer)
      assert connection.adapter_state == [{:sent_close, 1001, nil}]
    end

    test "handles message event in closing state", %{connection: connection} do
      connection =
        %Connection{connection | status: :local_closing}
        |> add_timer(:close_timeout)

      connection = Connection.do_events(connection, [{:text, "foo"}])
      assert connection.status == :local_closing
      assert connection.callback_state == [{:received, {:text, "foo"}, :closing}]
    end

    test "handles reply return to message event in open state", %{connection: connection} do
      connection = %Connection{connection | status: {:open, :ponged}}
      connection = Connection.do_events(connection, [{:text, "reply to this twice"}])
      assert connection.status == {:open, :ponged}

      assert connection.adapter_state == [
               {:sent, {:text, "reply 2 bad"}},
               {:sent, {:text, "reply 1"}}
             ]

      assert [
               {:message_error, ref2, :mock_reason, :open},
               {:message_confirm, ref1, :open},
               {:received, {:text, "reply to this twice"}, :open}
             ] =
               connection.callback_state

      assert is_reference(ref2) and is_reference(ref1)
    end

    #
    test "transitions from unponged to ponged on pong", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :unponged}}
        |> add_timer(:ping_timer)

      timer = connection.timer
      connection = Connection.do_events(connection, [:pong])
      assert connection.status == {:open, :ponged}
      assert connection.timer == timer
      assert connection.callback_state == []
      assert connection.adapter_state == []
    end

    test "ignores pong when ponged ", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :ponged}}
        |> add_timer(:ping_timer)

      timer = connection.timer
      connection = Connection.do_events(connection, [:pong])
      assert connection.status == {:open, :ponged}
      assert connection.timer == timer
      assert connection.callback_state == []
      assert connection.adapter_state == []
    end

    #
    test "replies to ping", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :unponged}}
        |> add_timer(:ping_timer)

      timer = connection.timer
      connection = Connection.do_events(connection, [{:ping, "bar"}])
      assert connection.status == {:open, :unponged}
      assert connection.timer == timer
      assert connection.callback_state == []
      assert connection.adapter_state == [{:sent_pong, "bar"}]
    end

    # 7
    test "handles unexpected :tcp_close in handshaking state", %{connection: connection} do
      connection = add_timer(connection, :ping_timer)
      connection = Connection.do_events(connection, [:tcp_close])
      assert connection.status == :closed
      assert connection.callback_state == []
    end

    # 8
    test "handles unexpected :tcp_close in open state", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :ponged}}
        |> add_timer(:ping_timer)

      {timer, _} = connection.timer
      connection = Connection.do_events(connection, [:tcp_close])

      assert connection.status == :closed
      assert connection.callback_state == []
      assert connection.timer == nil
      assert not Process.read_timer(timer)
    end

    #
    test "transitions from local_closing to tcp-closing on remote close", %{
      connection: connection
    } do
      connection =
        %Connection{connection | status: :local_closing}
        |> add_timer(:close_timeout)

      {timer, _} = connection.timer

      connection = Connection.do_events(connection, [{:close, 1000, nil}])
      assert connection.status == :waiting_tcp_close
      assert connection.timer == {timer, :close_timeout}
      assert connection.callback_state == []
    end

    # 9
    test "transitions from closing to closed on tcp_close", %{connection: connection} do
      connection =
        %Connection{connection | status: :waiting_tcp_close}
        |> add_timer(:close_timeout)

      {timer, _} = connection.timer

      connection = Connection.do_events(connection, [:tcp_close])
      assert connection.status == :closed
      assert connection.timer == nil
      assert connection.callback_state == []
      assert not Process.read_timer(timer)
    end

    # 10
    test "transitions from local_closing to closed on close timeout",
         %{connection: connection} do
      connection =
        %Connection{connection | status: :local_closing}
        |> add_timer(:close_timeout, 0)

      Process.sleep(1)

      connection = Connection.do_events(connection, [:close_timeout])
      assert connection.status == :closed
      assert connection.timer == nil
      assert connection.callback_state == []
      assert connection.adapter_state == [:tcp_closed]
    end

    test "transitions from waiting_tcp_close to closed on close timeout",
         %{connection: connection} do
      connection =
        %Connection{connection | status: :waiting_tcp_close}
        |> add_timer(:close_timeout, 0)

      Process.sleep(1)

      connection = Connection.do_events(connection, [:close_timeout])
      assert connection.status == :closed
      assert connection.timer == nil
      assert connection.callback_state == []
      assert connection.adapter_state == [:tcp_closed]
    end

    #
    test "transitions from ponged to unponged on ping timer", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :ponged}}
        |> add_timer(:ping_timer)

      {old_timer, :ping_timer} = connection.timer

      # Timer is sent
      _ = Process.cancel_timer(old_timer)

      connection = Connection.do_events(connection, [:ping_timer])
      assert connection.status == {:open, :unponged}
      assert {new_timer, :ping_timer} = connection.timer
      assert old_timer != new_timer
      assert_in_delta Process.read_timer(new_timer), 10_000, 100
      assert connection.callback_state == []
      assert connection.adapter_state == [:sent_ping]
    end

    test "ignores ping event in local_closing state", %{connection: connection} do
      connection = %Connection{connection | status: :local_closing}
      connection = Connection.do_events(connection, [{:ping, nil}])
      assert connection.status == :local_closing
      assert connection.adapter_state == []
    end

    test "ignores pong event in local_closing state", %{connection: connection} do
      connection = %Connection{connection | status: :local_closing}
      connection = Connection.do_events(connection, [:pong])
      assert connection.status == :local_closing
      assert connection.adapter_state == []
    end
  end
end
