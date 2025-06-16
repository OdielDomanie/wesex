defmodule Wesex.ConnectionTest do
  use ExUnit.Case, async: true
  alias Wesex.Connection

  defmodule MockAdapter do
    @behaviour Wesex.Adapter
    def init, do: []
    @impl true
    def connect(url, _headers, _opts) do
      {:ok, [{:connected, url}]}
    end

    @impl true
    def event(raw_event, state) do
      {raw_event, state}
    end

    @impl true
    def send({:text, "reply 2 bad"} = msg, state) do
      {:error, [], [{:sent, msg} | state], :mock_reason}
    end

    def send(msg, state) do
      {:ok, [], [{:sent, msg} | state]}
    end

    @impl true
    def abort(state) do
      {[:tcp_close], [:tcp_closed | state]}
    end

    @impl true
    def send_ping(state) do
      {[], [:sent_ping | state]}
    end

    @impl true
    def send_pong(data, state) do
      {[], [{:sent_pong, data} | state]}
    end

    @impl true
    def local_close({code, reason}, state) do
      {[], [{:sent_close, code, reason} | state]}
    end
  end

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
      status: :handshaking,
      adapter: @mock_adapter,
      adapter_state: @mock_adapter.init(),
      ref: make_ref(),
      remote_stop_code_reason: nil
    }

    %{connection: connection}
  end

  test "connect/4" do
    assert {:ok, connection} =
             Connection.connect(
               "wss://foo.test/bar?baz=123",
               [],
               @mock_adapter,
               []
             )

    uri = URI.new!("wss://foo.test/bar?baz=123")

    assert %Connection{
             adapter: @mock_adapter,
             adapter_state: [{:connected, ^uri}],
             ref: ref,
             status: :handshaking,
             timer: {:handshake_timeout, timer}
           } = connection

    assert is_reference(ref)
    assert_in_delta Process.read_timer(timer), 4000, 10
  end

  test "send/2", %{connection: connection} do
    connection =
      %Connection{connection | status: {:open, :unponged}}
      |> add_timer(:ping_timer)

    assert {:ok, results, connection} =
             Connection.send(
               connection,
               {:binary, "foo"}
             )

    assert connection.status == {:open, :unponged}
    assert connection.adapter_state == [{:sent, {:binary, "foo"}}]
    assert results == []
  end

  describe "event/2" do
    # 2
    test "transitions from handshaking to open on :handshake_complete", %{connection: connection} do
      connection = add_timer(connection, :handshake_timeout)

      {results, connection} = Connection.event(connection, [:handshake_complete])
      assert connection.status == {:open, :ponged}
      assert {:ping_timer, _timer} = connection.timer
      ref = connection.ref
      assert_receive {^ref, :wesex_timer, :ping_timer}, 10
      assert results == [:open]
    end

    # 1
    test "transitions to closed on handshake timeout", %{connection: connection} do
      connection = add_timer(connection, :handshake_timeout)

      {results, connection} =
        Connection.event(connection, {connection.ref, :wesex_timer, :handshake_timeout})

      assert connection.status == :closed
      assert connection.timer == nil
      assert results == [closed: {:error, :closed_in_handshake}]
    end

    # 3
    test "transitions from unponged to local_closing on ping timeout", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :unponged}}
        |> add_timer(:ping_timer)

      # Timer is sent
      _ = connection.timer |> elem(1) |> Process.cancel_timer()

      {results, connection} =
        Connection.event(connection, {connection.ref, :wesex_timer, :ping_timer})

      assert connection.status == :local_closing
      assert results == [{:closing, {:local, {1002, "ping timeout"}}}]
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

        {results, connection} = Connection.event(connection, [{:close, 1000, "normal closure"}])
        assert connection.status == :waiting_tcp_close
        assert connection.adapter_state == [{:sent_close, 1000, nil}]
        assert results == [{:closing, {:remote, {1000, "normal closure"}}}]
      end

      test "handles message event in open,#{@ponged} state", %{connection: connection} do
        connection = %Connection{connection | status: {:open, @ponged}}
        {results, connection} = Connection.event(connection, [{:text, "foo"}])
        assert connection.status == {:open, @ponged}
        assert results == [{:received, {:text, "foo"}}]
      end
    end

    test "handles message event in closing state", %{connection: connection} do
      connection =
        %Connection{connection | status: :local_closing}
        |> add_timer(:close_timeout)

      {results, connection} = Connection.event(connection, [{:text, "foo"}])
      assert connection.status == :local_closing
      assert results == [{:received, {:text, "foo"}}]
    end

    test "transitions from unponged to ponged on pong", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :unponged}}
        |> add_timer(:ping_timer)

      timer = connection.timer
      {results, connection} = Connection.event(connection, [{:pong, nil}])
      assert connection.status == {:open, :ponged}
      assert connection.timer == timer
      assert results == []
    end

    test "ignores pong when ponged ", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :ponged}}
        |> add_timer(:ping_timer)

      timer = connection.timer
      {results, connection} = Connection.event(connection, [{:pong, nil}])
      assert connection.status == {:open, :ponged}
      assert connection.timer == timer
      assert results == []
    end

    test "replies to ping", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :unponged}}
        |> add_timer(:ping_timer)

      timer = connection.timer
      {results, connection} = Connection.event(connection, [{:ping, "bar"}])
      assert connection.status == {:open, :unponged}
      assert connection.timer == timer
      assert results == []
      assert connection.adapter_state == [{:sent_pong, "bar"}]
    end

    # 7
    test "handles unexpected :tcp_close in handshaking state", %{connection: connection} do
      connection = add_timer(connection, :ping_timer)
      {results, connection} = Connection.event(connection, [:tcp_close])
      assert connection.status == :closed
      assert results == [{:closed, {:error, :unexpected_tcp_close}}]
    end

    # 8
    test "handles unexpected :tcp_close in open state", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :ponged}}
        |> add_timer(:ping_timer)

      {_, timer} = connection.timer
      {results, connection} = Connection.event(connection, [:tcp_close])

      assert connection.status == :closed
      assert results == [{:closed, {:error, :unexpected_tcp_close}}]
      assert connection.timer == nil
      assert not Process.read_timer(timer)
    end

    test "transitions from local_closing to tcp-closing on remote close", %{
      connection: connection
    } do
      connection =
        %Connection{connection | status: :local_closing}
        |> add_timer(:close_timeout)

      {_, timer} = connection.timer

      {results, connection} = Connection.event(connection, [{:close, 1000, nil}])
      assert connection.status == :waiting_tcp_close
      assert connection.timer == {:close_timeout, timer}
      assert results == []
    end

    # 9
    test "transitions from closing to closed on tcp_close", %{connection: connection} do
      connection =
        %Connection{connection | status: :waiting_tcp_close}
        |> add_timer(:close_timeout)

      {_, timer} = connection.timer

      {results, connection} = Connection.event(connection, [:tcp_close])
      assert connection.status == :closed
      assert connection.timer == nil
      assert results == [{:closed, {:remote, connection.remote_stop_code_reason}}]
      assert not Process.read_timer(timer)
    end

    # 10
    test "transitions from local_closing to closed on close timeout",
         %{connection: connection} do
      connection =
        %Connection{connection | status: :local_closing}
        |> add_timer(:close_timeout, 0)

      Process.sleep(1)

      {results, connection} =
        Connection.event(connection, {connection.ref, :wesex_timer, :close_timeout})

      assert connection.status == :closed
      assert connection.timer == nil
      assert results == [closed: {:error, :timeout}]
      assert connection.adapter_state == [:tcp_closed]
    end

    test "transitions from waiting_tcp_close to closed on close timeout",
         %{connection: connection} do
      connection =
        %Connection{connection | status: :waiting_tcp_close}
        |> add_timer(:close_timeout, 0)

      Process.sleep(1)

      {results, connection} =
        Connection.event(connection, {connection.ref, :wesex_timer, :close_timeout})

      assert connection.status == :closed
      assert connection.timer == nil
      assert results == [closed: {:error, :timeout}]
      assert connection.adapter_state == [:tcp_closed]
    end

    test "transitions from ponged to unponged on ping timer", %{connection: connection} do
      connection =
        %Connection{connection | status: {:open, :ponged}}
        |> add_timer(:ping_timer)

      {:ping_timer, old_timer} = connection.timer

      # Timer is sent
      _ = Process.cancel_timer(old_timer)

      {results, connection} =
        Connection.event(connection, {connection.ref, :wesex_timer, :ping_timer})

      assert connection.status == {:open, :unponged}
      assert {:ping_timer, new_timer} = connection.timer
      assert old_timer != new_timer
      assert_in_delta Process.read_timer(new_timer), 10_000, 100
      assert results == []
      assert connection.adapter_state == [:sent_ping]
    end

    test "ignores ping event in local_closing state", %{connection: connection} do
      connection = %Connection{connection | status: :local_closing}
      {results, connection} = Connection.event(connection, [{:ping, nil}])
      assert connection.status == :local_closing
      assert results == []
      assert connection.adapter_state == []
    end

    test "ignores pong event in local_closing state", %{connection: connection} do
      connection = %Connection{connection | status: :local_closing}
      {results, connection} = Connection.event(connection, [{:pong, nil}])
      assert connection.status == :local_closing
      assert results == []
      assert connection.adapter_state == []
    end
  end

  defp add_timer(connection, timer_type, time \\ 5_000) do
    timer = Process.send_after(self(), {connection.ref, :wesex_timer, timer_type}, time)
    %Connection{connection | timer: {timer_type, timer}}
  end
end
